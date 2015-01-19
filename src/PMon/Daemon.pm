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
# Created On: 2013-03-01 09:51:18Z
#

package PMon::Daemon;

use strict;
use warnings;

use POE;

use PMon::Config;
use PMon::Daemon::Db;
use PMon::Daemon::Net;


# singleton
our $SELF;



#-------------------------------------------------------------------------------
sub new
{
    my $class = shift;
    my %args  = @_;
    my $self  = bless { }, $class;

    die if defined $SELF;
    $SELF = $self;

    foreach (qw( rootdir configfile ))
    {
        die "Parameter '$_' not defined!"
            unless exists($args{$_}) and defined($args{$_});
    }

    $self->{config} = PMon::Config->new(
        file   => $args{configfile},
        strict => 1,
        subst  => { '{BASEDIR}' => $args{rootdir}, },
    );

    $self->{db}  = undef;
    $self->{net} = undef;

    # init main poe session
    POE::Session->create(
        options => {
            trace   => 0,
            debug   => 0,
            default => 0,
        },
        object_states => [
            $self => {
                _start     => 'on_start',
                _stop      => 'on_stop',
                sigtrap    => 'on_signal',
                shutdown   => 'on_shutdown',
                agent_info => 'on_agent_info',
            },
        ],
    );

    return $self;
}

#-------------------------------------------------------------------------------
sub _shutdown
{
    my $self = shift;

    # shutdown subsystems
    if (defined $self->{net})
    {
        $self->{net}->shutdown;
        $self->{net} = undef;
    }
    if (defined $self->{db})
    {
        $self->{db}->shutdown;
        $self->{db} = undef;
    }
}



#-------------------------------------------------------------------------------
sub on_start
{
    my ($self, $poe_session) = @_[OBJECT, SESSION];
    my $fh;

    warn "Starting (pid $$)...\n";

    # register signal handlers
    $poe_kernel->sig(INT  => 'sigtrap');
    $poe_kernel->sig(TERM => 'sigtrap');
    $poe_kernel->sig(QUIT => 'sigtrap');
    #$poe_kernel->sig(HUP  => 'sigtrap');
    #$poe_kernel->sig(USR1 => 'sigtrap');
    #$poe_kernel->sig(USR2 => 'sigtrap');

    # connect to db
    $self->{db} = PMon::Daemon::Db->new(
        source    => $self->{config}->get_str('db_source'),
        user      => $self->{config}->get_str('db_user'),
        pass      => $self->{config}->get_str('db_pass'),
        full_log  => $self->{config}->get_bool('db_full_log', 1),
        heartbeat => $self->{config}->get_int('db_heartbeat', 3900, 70, 90_000), );
    $self->{db}->start;

    # start network service
    $self->{net} = PMon::Daemon::Net->new(
        bind_addr => $self->{config}->get_str('service_bind_addr'),
        bind_port => $self->{config}->get_int('service_port') );
    $self->{net}->start;
}

#----------------------------------------------------------------------------
sub on_stop
{
  warn "Stopped.\n";
}

#----------------------------------------------------------------------------
sub on_shutdown
{
    $_[OBJECT]->_shutdown if defined $_[OBJECT];
}

#----------------------------------------------------------------------------
sub on_signal
{
    my ($self, $poe_session, $sig, $ex) = @_[OBJECT, SESSION, ARG0, ARG1];

    # is this test really needed?
    return unless defined $self;

    if ($sig =~ /^(INT|TERM|QUIT)$/)
    {
        warn "Caught $sig signal (pid $$)!\n";
        $self->_shutdown;
        $poe_kernel->sig_handled;
    }
}

#----------------------------------------------------------------------------
sub on_agent_info
{
    my ($self, $info) = @_[OBJECT, ARG0];

    #warn "From ", $info->addr_str, ": ", $info->line, "\n";

    if ($info->key eq 'sys.uptime')
    {
        $self->{db}->commit_uptime($info->machine, $info->time, $info->value);
    }
    else
    {
        $self->{db}->commit_info($info->machine, $info->time, $info->key, $info->value);
    }
}


1;
