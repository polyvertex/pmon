#
# PMon
# A small monitoring system for Linux written in Perl.
#
# Copyright (C) 2013-2015 Jean-Charles Lefebvre <polyvertex@gmail.com>
#
# This software is provided 'as-is', without any express or implied
# warranty.  In no event will the authors be held liable for any damages
# arising from the use of this software.
#
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it
# freely, subject to the following restrictions :
#
# 1. The origin of this software must not be misrepresented; you must not
#    claim that you wrote the original software. If you use this software
#    in a product, an acknowledgment in the product documentation would be
#    appreciated but is not required.
# 2. Altered source versions must be plainly marked as such, and must not
#    be misrepresented as being the original software.
# 3. This notice may not be removed or altered from any source distribution.
#
# Created On: 2013-03-08 17:00:52Z
#

package PMon::InfoLine;

use strict;
use warnings;

use Socket;


#-------------------------------------------------------------------------------
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

    $self->{'time'} = time;

    $self->{addr_packed} = $args{addr_packed}
        if exists $args{addr_packed};
    $self->{is_received} = 1
        if exists($args{is_received}) and $args{is_received};
    $self->{line} = $args{line}
        if exists $args{line};

    if (defined $self->{line})
    {
        chomp $self->{line};

        if ($self->{line} =~ /^pmon(0|1)\s+/)
        {
            my $proto_version = int $1;

            if ($proto_version == 0)
            {
                my ($magic, $unix, $machine, $key, $value) =
                    split /\s+/, $self->{line}, 5;

                if (defined($value) and
                    $unix =~ /^\d+$/ and
                    $machine =~ /^[\w\-\_\.]+$/ and
                    $key =~ /^[\w\-\_\.]+$/)
                {
                    $self->{magic}   = $magic;
                    $self->{'time'}  = $unix;
                    $self->{machine} = $machine;
                    $self->{key}     = $key;
                    $self->{value}   = $value;
                }
            }
            elsif ($proto_version == 1)
            {
                my ($magic, $machine, $key, $value) =
                    split /\s+/, $self->{line}, 4;

                if (defined($value) and
                    $machine =~ /^[\w\-\_\.]+$/ and
                    $key =~ /^[\w\-\_\.]+$/)
                {
                    $self->{magic}   = $magic;
                    $self->{machine} = $machine;
                    $self->{key}     = $key;
                    $self->{value}   = $value;
                }
            }
        }

        #unless ($self->is_valid)
        #{
        #    if (defined $self->{addr_packed})
        #    {
        #       warn "Malformed info line to/from ", $self->addr_str,
        #           "! Line: ", $self->{line}, "\n";
        #    }
        #    else
        #    {
        #       warn "Malformed info line: ", $self->{line}, "\n";
        #    }
        #}
    }

    return $self;
}

#-------------------------------------------------------------------------------
sub is_valid
{
    my $self = shift;
    return defined($self->{line}) and defined($self->{magic});
}

#-------------------------------------------------------------------------------
sub addr_str
{
    my $self = shift;
    return unless defined $self->{addr_packed};
    unless (defined $self->{addr_str})
    {
        ($self->{addr_port}, my $inet) = sockaddr_in $self->{addr_packed};
        $self->{addr_ip}   = inet_ntoa $inet;
        $self->{addr_port} = +$self->{addr_port};
        $self->{addr_str}  = $self->{addr_ip}.':'.$self->{addr_port};
    }
    return $self->{addr_str};
}

#-------------------------------------------------------------------------------
sub addr_ip
{
    my $self = shift;
    return unless defined $self->{addr_packed};
    $self->addr_str unless defined $self->{addr_ip};
    return $self->{addr_ip};
}

#-------------------------------------------------------------------------------
sub addr_port
{
    my $self = shift;
    return unless defined $self->{addr_packed};
    $self->addr_str unless defined $self->{addr_port};
    return $self->{addr_port};
}

#-------------------------------------------------------------------------------
sub addr_packed { shift()->{addr_packed} }
sub is_received { shift()->{is_received} }
sub line        { shift()->{line} }
sub magic       { shift()->{magic} }
sub machine     { shift()->{machine} }
sub time        { shift()->{time} }
sub key         { shift()->{key} }
sub value       { shift()->{value} }


1;
