#
# PMon
# A personal monitoring system for Linux based on a service/node architecture.
#
# Copyright (C) 2013 Jean-Charles Lefebvre <jcl [AT] jcl [DOT] io>
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
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-05 07:55:23Z
#
# $Id$
#

package PMon::Daemon::Net;

use strict;
use warnings;

use Socket;
use POE qw( Wheel::ReadWrite Wheel::SocketFactory );

use PMon::Daemon::NetFilterIn ();
use PMon::Daemon::NetDriverIn ();


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

    $self->{factories} = { };
    $self->{listeners} = { };

    # split bind addresses
    {
        my @bind_addr = split /\s+/, $self->{bind_addr};
        die "Too much bind addresses specified (", scalar(@bind_addr), "/", MAX_LISTENERS, ")!\n"
            if @bind_addr > MAX_LISTENERS;
        $self->{bind_addr} = [ @bind_addr ];
    }

    # register poe handlers
    $poe_kernel->state('udpsvc_factory_success', $self, 'on_factory_success');
    $poe_kernel->state('udpsvc_factory_error', $self, 'on_factory_error');
    $poe_kernel->state('udpsvc_listener_read', $self, 'on_listener_read');
    $poe_kernel->state('udpsvc_listener_error', $self, 'on_listener_error');

    return $self;
}

#-------------------------------------------------------------------------------
sub start
{
    my $self = shift;

    die if keys(%{$self->{factories}}) > 0;
    die if keys(%{$self->{listeners}}) > 0;

    foreach my $addr (@{$self->{bind_addr}})
    {
        my $factory = POE::Wheel::SocketFactory->new(
            SocketDomain   => AF_INET,
            SocketType     => SOCK_DGRAM,
            SocketProtocol => 'udp',
            BindAddress    => $addr,
            BindPort       => $self->{bind_port},
            Reuse          => 'yes',
            SuccessEvent   => 'udpsvc_factory_success',
            FailureEvent   => 'udpsvc_factory_error',
        );

        $self->{factories}{$factory->ID} = {
            factory => $factory,
            label   => "$addr:".$self->{bind_port},
        };
    }
}

#-------------------------------------------------------------------------------
sub shutdown
{
    my $self = shift;

    # TODO: check if something remains into the Filter AND Driver!

    # destroy wheels
    $self->{factories} = { };
    $self->{listeners} = { };
}



#-------------------------------------------------------------------------------
sub on_factory_success
{
    my ($self, $socket, $factory_id) = @_[OBJECT, ARG0, ARG3];

    return unless exists $self->{factories}{$factory_id};

    my $wheel = POE::Wheel::ReadWrite->new(
        Handle      => $socket,
        Driver      => PMon::Daemon::NetDriverIn->new,
        InputFilter => PMon::Daemon::NetFilterIn->new,
        InputEvent  => 'udpsvc_listener_read',
        ErrorEvent  => 'udpsvc_listener_error',
    );

    $self->{listeners}{$wheel->ID} = {
        label => $self->{factories}{$factory_id}{label},
        wheel => $wheel,
    };
    delete $self->{factories}{$factory_id};

    warn "Listening on ", $self->{listeners}{$wheel->ID}{label}, ".\n";
}

#-------------------------------------------------------------------------------
sub on_factory_error
{
    my ($self, $syscall, $errno, $errstr, $factory_id) = @_[OBJECT, ARG0 .. ARG3];

    return unless exists $self->{factories}{$factory_id};
    die "Failed to create listener on ", $self->{factories}{$factory_id}{label},
        " while calling $syscall()! Error $errno: $errstr\n";
}

#-------------------------------------------------------------------------------
sub on_listener_read
{
    my ($self, $input, $wheel_id) = @_[OBJECT, ARG0, ARG1];

    return unless exists $self->{listeners}{$wheel_id};
    $poe_kernel->yield('agent_info', $input);
}

#-------------------------------------------------------------------------------
sub on_listener_error
{
    my ($self, $syscall, $errno, $errstr, $wheel_id) = @_[OBJECT, ARG0 .. ARG3];

    return unless exists $self->{listeners}{$wheel_id};
    warn "Error on UDP socket ", $self->{listeners}{$wheel_id}{label},
        " while calling $syscall()! Error $errno: $errstr\n";
    delete $self->{listeners}{$wheel_id};

    if (keys %{$self->{listeners}} <= 0)
    {
        warn "All network listeners went down! Trying to restart...\n";
        $self->start;
    }
}


1;
