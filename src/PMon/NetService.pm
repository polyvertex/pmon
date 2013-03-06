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
    my %opt   = @_;
    my $self  = bless { }, $class;

    foreach (qw( bind_addr bind_port ))
    {
        die "Parameter '$_' not defined!"
            unless exists($opt{$_}) and defined($opt{$_});
        $self->{$_} = $opt{$_};
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
        Handle     => $socket,
        Filter     => POE::Filter::Line->new(),
        InputEvent => 'udpsvc_listener_read',
        ErrorEvent => 'udpsvc_listener_error',
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

    return unless length($input) > 0;
    return unless exists $self->{'listeners'}{$wheel_id};

    chomp $input;
    warn "NetInput [$input]\n";
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


1;
