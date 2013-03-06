#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-01 09:51:18Z
#
# $Id$
#

package PMon::Daemon;

use strict;
use warnings;

use POE;

use PMon::Config;
use PMon::Db;
use PMon::NetService;


# singleton
our $SELF;



#-------------------------------------------------------------------------------
sub new
{
    my $class = shift;
    my %opt   = @_;
    my $self  = bless { }, $class;

    die if defined $SELF;
    $SELF = $self;

    foreach (qw( configfile ))
    {
        die "Parameter '$_' not defined!"
            unless exists($opt{$_}) and defined($opt{$_});
    }

    $self->{'config'} = PMon::Config->new(
        file   => $opt{'configfile'},
        strict => 1);

    $self->{'db'}  = undef;
    $self->{'net'} = undef;

    # init main poe session
    POE::Session->create(
        options => {
            trace   => 0,
            debug   => 0,
            default => 0,
        },
        object_states => [
            $self => {
                _start  => 'on_start',
                _stop   => 'on_stop',
                sigtrap => 'on_signal',
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
    if (defined $self->{'net'})
    {
        $self->{'net'}->shutdown;
        $self->{'net'} = undef;
    }
    if (defined $self->{'db'})
    {
        $self->{'db'}->shutdown;
        $self->{'db'} = undef;
    }
}



#-------------------------------------------------------------------------------
sub on_start
{
    my ($self, $poe_session) = @_[OBJECT, SESSION];
    my $fh;

    # register signal handlers
    $poe_kernel->sig(INT  => 'sigtrap');
    $poe_kernel->sig(TERM => 'sigtrap');
    $poe_kernel->sig(QUIT => 'sigtrap');
    #$poe_kernel->sig(HUP  => 'sigtrap');
    #$poe_kernel->sig(USR1 => 'sigtrap');
    #$poe_kernel->sig(USR2 => 'sigtrap');

    # connect to db
    $self->{'db'} = PMon::Db->new(
        source => $self->{'config'}->get_str('db_source'),
        user   => $self->{'config'}->get_str('db_user'),
        pass   => $self->{'config'}->get_str('db_pass') );

    # start network service
    $self->{'net'} = PMon::NetService->new(
        bind_addr => $self->{'config'}->get_str('service_bind_addr'),
        bind_port => $self->{'config'}->get_int('service_port') );
}

#----------------------------------------------------------------------------
sub on_stop
{
  warn "Stopped.\n";
}

#----------------------------------------------------------------------------
sub on_signal
{
    my ($self, $poe_session, $sig, $ex) = @_[OBJECT, SESSION, ARG0, ARG1];

    # is this test really needed?
    return unless defined $self;

    if ($sig =~ /^(INT|TERM|QUIT)$/)
    {
        warn "PMon Daemon caught $sig signal!\n";
        $self->_shutdown;
        $poe_kernel->sig_handled;
    }
}


1;
