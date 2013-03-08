#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-05 07:55:23Z
#
# $Id$
#

package PMon::NetService;

use strict;
use warnings;

use Socket;
use POE qw( Wheel::ReadWrite Wheel::SocketFactory );


use constant
{
    MAX_LISTENERS => 5,
};


#-------------------------------------------------------------------------------
sub new
{
    my $class = shift;
    my %args  = @_;
    my $self  = bless { }, $class;

    foreach (qw( bind_addr bind_port ))
    {
        die "Parameter '$_' not defined!"
            unless exists($args{$_}) and defined($args{$_});
        $self->{$_} = $args{$_};
    }

    $self->{'factories'} = { };
    $self->{'listeners'} = { };

    # split bind addresses
    {
        my @bind_addr = split /\s+/, $self->{'bind_addr'};
        die "Too much bind addresses specified (", scalar(@bind_addr), "/", MAX_LISTENERS, ")!\n"
            if @bind_addr > MAX_LISTENERS;
        $self->{'bind_addr'} = [ @bind_addr ];
    }

    # register poe handlers
    $poe_kernel->state('udpsvc_factory_success', $self, 'on_factory_success');
    $poe_kernel->state('udpsvc_factory_error', $self, 'on_factory_error');
    $poe_kernel->state('udpsvc_listener_read', $self, 'on_listener_read');
    $poe_kernel->state('udpsvc_listener_error', $self, 'on_listener_error');

    # start listening
    foreach my $addr (@{$self->{'bind_addr'}})
    {
        my $factory = POE::Wheel::SocketFactory->new(
            SocketDomain   => AF_INET,
            SocketType     => SOCK_DGRAM,
            SocketProtocol => 'udp',
            BindAddress    => $addr,
            BindPort       => $self->{'bind_port'},
            Reuse          => 'yes',
            SuccessEvent   => 'udpsvc_factory_success',
            FailureEvent   => 'udpsvc_factory_error',
        );

        $self->{'factories'}{$factory->ID} = {
            factory => $factory,
            label   => "$addr:".$self->{'bind_port'},
        };
    }

    return $self;
}

#-------------------------------------------------------------------------------
sub shutdown
{
    my $self = shift;

    # TODO: check if something remains into the Filter AND Driver!

    # destroy wheels
    $self->{'factories'} = { };
    $self->{'listeners'} = { };
}



#-------------------------------------------------------------------------------
sub on_factory_success
{
    my ($self, $socket, $factory_id) = @_[OBJECT, ARG0, ARG3];

    return unless exists $self->{'factories'}{$factory_id};

    my $wheel = POE::Wheel::ReadWrite->new(
        Handle      => $socket,
        Driver      => PMon::NetService::DriverIn->new,
        InputFilter => PMon::NetService::FilterIn->new,
        InputEvent  => 'udpsvc_listener_read',
        ErrorEvent  => 'udpsvc_listener_error',
    );

    $self->{'listeners'}{$wheel->ID} = {
        label => $self->{'factories'}{'label'},
        wheel => $wheel,
    };
    delete $self->{'factories'}{$factory_id};
}

#-------------------------------------------------------------------------------
sub on_factory_error
{
    my ($self, $syscall, $errno, $errstr, $factory_id) = @_[OBJECT, ARG0 .. ARG3];

    return unless exists $self->{'factories'}{$factory_id};
    die "Failed to create listener on ", $self->{'factories'}{$factory_id}{'label'},
        " while calling $syscall()! Error $errno: $errstr\n";
}

#-------------------------------------------------------------------------------
sub on_listener_read
{
    my ($self, $input, $wheel_id) = @_[OBJECT, ARG0, ARG1];

    return unless exists $self->{'listeners'}{$wheel_id};
    $poe_kernel->yield('agent_info', $input);
}

#-------------------------------------------------------------------------------
sub on_listener_error
{
    my ($self, $syscall, $errno, $errstr, $wheel_id) = @_[OBJECT, ARG0 .. ARG3];

    return unless exists $self->{'listeners'}{$wheel_id};
    warn "Error on UDP socket ", $self->{'listeners'}{$wheel_id}{'label'},
        " while calling $syscall()! Error $errno: $errstr\n";
    delete $self->{'listeners'}{$wheel_id};
}



#*******************************************************************************
package PMon::NetService::Info;

use strict;
use warnings;
use Socket;

sub new
{
    my $class = shift;
    my $self  = bless {
        addr_packed => undef,
        addr_ip     => undef,
        addr_port   => undef,
        is_received => undef,
        line        => undef,
        magic       => undef,
        machine     => undef,
        time        => undef,
        key         => undef,
        value       => undef,
    }, $class;
    my %args = @_;

    $self->{'addr_packed'} = $args{'addr_packed'}
        if exists $args{'addr_packed'};
    $self->{'is_received'} = 1
        if exists($args{'is_received'}) and $args{'is_received'};
    $self->{'line'} = $args{'line'}
        if exists $args{'line'};

    if (defined $self->{'line'})
    {
        chomp $self->{'line'};

        my ($magic, $machine, $time, $key, $value) =
            split /\s+/, $self->{'line'}, 5;

        if (defined($value) and
            $magic eq 'pmon1' and
            $machine =~ /^[\w\-\_\.]+$/ and
            $time =~ /^\d+$/ and
            $key =~ /^[\w\-\_\.]+$/)
        {
            $self->{'magic'}   = $magic;
            $self->{'machine'} = $machine;
            $self->{'time'}    = $time;
            $self->{'key'}     = $key;
            $self->{'value'}   = $value;
        }
        elsif (defined $self->{'addr_packed'})
        {
            warn "Malformed info line to/from ", $self->addr_str, "! Line: ", $self->{'line'}, "\n";
        }
        else
        {
            warn "Malformed info line: ", $self->{'line'}, "\n";
        }
    }

    return $self;
}

sub is_valid
{
    my $self = shift;
    return defined($self->{'line'}) and defined($self->{'magic'});
}

sub addr_str
{
    my $self = shift;
    return unless defined $self->{'addr_packed'};
    unless (defined $self->{'addr_str'})
    {
        ($self->{'addr_port'}, my $inet) = sockaddr_in $self->{'addr_packed'};
        $self->{'addr_ip'}   = inet_ntoa $inet;
        $self->{'addr_port'} = +$self->{'addr_port'};
        $self->{'addr_str'}  = $self->{'addr_ip'}.':'.$self->{'addr_port'};
    }
    return $self->{'addr_str'};
}

sub addr_ip
{
    my $self = shift;
    return unless defined $self->{'addr_packed'};
    $self->addr_str unless defined $self->{'addr_ip'};
    return $self->{'addr_ip'};
}

sub addr_port
{
    my $self = shift;
    return unless defined $self->{'addr_packed'};
    $self->addr_str unless defined $self->{'addr_port'};
    return $self->{'addr_port'};
}

sub addr_packed { shift()->{'addr_packed'} }
sub is_received { shift()->{'is_received'} }
sub line        { shift()->{'line'} }
sub magic       { shift()->{'magic'} }
sub machine     { shift()->{'machine'} }
sub time        { shift()->{'time'} }
sub key         { shift()->{'key'} }
sub value       { shift()->{'value'} }



#*******************************************************************************
package PMon::NetService::FilterIn;
use base qw(POE::Filter);

use strict;
use warnings;

sub new { bless { }, shift }
sub put { die }

sub get
{
    my ($self, $data) = @_;
    my @addr_order;
    my %addr_seen;
    my @infos;

    # group every received chunks by peer address and
    # order them by time of arrival (keep up the fifo spirit!)
    foreach my $d (@$data)
    {
        if (exists $self->{$d->[0]})
        {
            $self->{$d->[0]} .= $d->[1];
        }
        else
        {
            $self->{$d->[0]} = $d->[1];
        }

        unless (exists $addr_seen{$d->[0]})
        {
            push @addr_order, $d->[0];
            $addr_seen{$d->[0]} = 1;
        }
    }

    # process as much data as we can
    foreach my $addr (@addr_order)
    {
        next unless exists $self->{$addr};
        while (1)
        {
            last unless $self->{$addr} =~ s/^(.*?)(\x0D\x0A?|\x0A\x0D?)//s;
            next unless length($1) > 0; # can happen
            push @infos, PMon::NetService::Info->new(
                addr_packed => $addr,
                is_received => 1,
                line        => $1
            );
        }
        delete $self->{$addr} if $self->{$addr} eq '';
    }

    return \@infos;
}



#*******************************************************************************
package PMon::NetService::DriverIn;

use strict;
use warnings;
use Socket;

sub BLOCK_SIZE () { 0 }

sub new
{
    my $class = shift;
    my $self = bless [
        2048,  # block size
    ], $class;

    if (@_)
    {
        my %args = @_;

        $self->[BLOCK_SIZE] = $args{'BlockSize'}
            if exists($args{'BlockSize'})
            and defined($args{'BlockSize'})
            and $args{'BlockSize'} > 0;
    }

    return $self;
}

sub put   { die }
sub flush { die }

sub get
{
    my ($self, $fh) = @_;
    my @ret;

    while (1)
    {
        my $buffer = '';
        my $from = recv $fh, $buffer, $self->[BLOCK_SIZE], 0;
        last unless $from;
        push @ret, [ $from, $buffer ];
    }

    return if @ret == 0;
    return \@ret;
}


1;
