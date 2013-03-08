#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-01 09:53:53Z
#
# $Id$
#

package PMon::Daemon::Db;

use strict;
use warnings;

use POE;
use DBI;


use constant
{
    DELAY_CONNECT_RETRY => 10,
    MAX_KEY_LENGTH      => 255,
    MAX_VALUE_LENGTH    => 255,

    # mysql error codes
    MYSQLERR_SERVER_GONE_ERROR => 2006,  # CR_SERVER_GONE_ERROR
    #MYSQLERR_SERVER_LOST       => 2013,  # CR_SERVER_LOST
};



#-------------------------------------------------------------------------------
sub new
{
    my $class = shift;
    my %args  = @_;
    my $self  = bless { }, $class;

    foreach (qw( source user pass ))
    {
        die "Parameter '$_' not defined!"
            unless exists($args{$_}) and defined($args{$_});
        $self->{$_} = $args{$_};
    }

    $self->{'dbh'}      = undef;
    $self->{'sth'}      = { };
    $self->{'machines'} = undef;
    $self->{'inqueue'}  = [ ];

    # register poe handlers
    $poe_kernel->state('db_connect', $self, 'on_connect');
    $poe_kernel->state('db_disconnect', $self, 'on_disconnect');

    # connect
    $poe_kernel->yield('db_connect');

    return $self;
}

#-------------------------------------------------------------------------------
sub shutdown
{
    my $self = shift;
    my $poe_session = $poe_kernel->get_active_session;

    # kill timer
    $poe_kernel->delay('db_connect');

    # smooth disconnect
    $poe_kernel->post($poe_session, 'db_disconnect', 1);
}



#-------------------------------------------------------------------------------
sub is_connected
{
    my $dbh = shift()->{'dbh'};
    return defined($dbh); # and $dbh->ping;
}

#-------------------------------------------------------------------------------
sub q
{
    my ($self, $value) = @_;
    return unless defined $self->{'dbh'};
    return $self->{'dbh'}->quote($value);
}

#-------------------------------------------------------------------------------
sub qi
{
    my ($self, $value) = @_;
    return unless defined $self->{'dbh'};
    return $self->{'dbh'}->quote_identifier($value);
}

#-------------------------------------------------------------------------------
sub commit_uptime
{
    my ($self, $machine_name, $unix, $uptime) = @_;
    my $machine_id = $self->_machine_id($machine_name);

    return unless defined $machine_id;
    return unless $uptime =~ /^\d+$/;

    my $sth = $self->{'sth'}{'up_machine'};
    my $res = $sth->execute($unix, $uptime, $machine_id);
    unless ($res > 0)
    {
        warn "Failed to update machine uptime (", $sth->err, ")! ", $sth->errstr, "\n";
        if ($sth->err == MYSQLERR_SERVER_GONE_ERROR)
        {
            warn "Reconnecting to database...\n";
            $poe_kernel->yield('db_disconnect', 0);
            $poe_kernel->yield('db_connect');
        }
        return 0;
    }

    return 1;
}

#-------------------------------------------------------------------------------
sub commit_info
{
    my ($self, $machine_name, $unix, $key, $value) = @_;
    my $machine_id = $self->_machine_id($machine_name);
    my $err;
    my $return = 1;

    return unless defined $machine_id;
    chomp $value;
    return unless length($value) > 0;

    $unix = 0 if $unix < 1 or $unix > 0xffffffff;
    $key = substr($key, 0, MAX_VALUE_LENGTH)
        if length($key) > MAX_KEY_LENGTH;
    $value = substr($value, 0, MAX_VALUE_LENGTH)
        if length($value) > MAX_VALUE_LENGTH;

    # start transaction mode
    $self->{'dbh'}{'AutoCommit'} = 0;
    eval
    {
        my ($sth, $res, $row);

        # insert info into the normal 'log' table
        $sth = $self->{'sth'}{'ins_info'};
        $res = $sth->execute($unix, $machine_id, $key, $value);
        unless ($res > 0)
        {
            $err = $sth->err;
            die "Failed to insert info log ($res; $err)! ", $sth->errstr, "\n";
        }

        # insert info into the 'logatom' table
        {
            # do we already have this info?
            $sth = $self->{'sth'}{'sel_last_atominfo'};
            $res = $sth->execute($machine_id, $key);
            unless ($res)
            {
                $err = $sth->err;
                die "Failed to insert atomic info ($err)! ", $sth->errstr, "\n";
            }
            $row = $sth->fetchrow_hashref;
            $sth->finish;

            # if the key-value pair was found and if the value didn't change
            # yet, just update the 'unix_last' column of this row to mark the
            # change. otherwise, insert a new log line.
            if (defined($row) and $row->{'value'} eq $value)
            {
                # same value, just update the row
                $sth = $self->{'sth'}{'up_atominfo'};
                $res = $sth->execute($unix, $row->{'id'});
                unless ($res > 0)
                {
                    $err = $sth->err;
                    die "Failed to update atomic info ($err)! ", $sth->errstr, "\n";
                }
            }
            else
            {
                # insert a new row
                $sth = $self->{'sth'}{'ins_atominfo'};
                $res = $sth->execute($machine_id, $key, $unix, $unix, $value);
                unless ($res > 0)
                {
                    $err = $sth->err;
                    die "Failed to insert info log ($res; $err)! ", $sth->errstr, "\n";
                }
            }
        }

        # finally, commit transaction
        unless ($self->{'dbh'}->commit)
        {
            $err = $self->{'dbh'}->err;
            die "Failed to commit info's transaction ($err)! ", $self->{'dbh'}->errstr, "\n";
        }
    };
    if ($@)
    {
        $return = 0;
        warn $@;
        $self->{'dbh'}->rollback
            or warn "Failed to rollback transaction after errors (", $self->{'dbh'}->err, ")! ", $self->{'dbh'}->errstr, "\n";
        if (defined($err) and $err == MYSQLERR_SERVER_GONE_ERROR)
        {
            warn "Reconnecting to database...\n";
            $poe_kernel->yield('db_disconnect', 0);
            $poe_kernel->yield('db_connect');
        }
    }

    # restore default mode
    $self->{'dbh'}{'AutoCommit'} = 1;

    return $return;
}



#-------------------------------------------------------------------------------
sub on_connect
{
    my ($self, $poe_session) = @_[OBJECT, SESSION];
    my $db_uri  = $self->{'source'};
    my $db_user = $self->{'user'};
    my $db_pass = $self->{'pass'};

    $poe_kernel->delay('db_connect'); # kill timer
    return if defined $self->{'dbh'};

    $self->{'dbh'} = DBI->connect(
        $db_uri, $db_user, $db_pass, {
            AutoCommit => 1,
            RaiseError => 0,
            PrintWarn  => 1,
            PrintError => 0,
        } );
    unless (defined $self->{'dbh'})
    {
        warn "Failed to connect DBI (", $DBI::err, ")! ", $DBI::errstr, "\n";
        $poe_kernel->delay('db_connect', DELAY_CONNECT_RETRY);
        return;
    }

    # prepare statements
    my $step = 0;
    $self->{'dbh'}{'RaiseError'} = 1;
    eval
    {
        $self->{'sth'} = { };

        $self->{'sth'}{'ins_machine'} = $self->{'dbh'}->prepare(
            'INSERT INTO machine (name) VALUES (?)');
        $step++;

        $self->{'sth'}{'up_machine'} = $self->{'dbh'}->prepare(qq{
            UPDATE machine SET unix = ?, uptime = ?
            WHERE id = ?
            LIMIT 1 });
        $step++;

        $self->{'sth'}{'ins_info'} = $self->{'dbh'}->prepare(
            'INSERT INTO '.$self->qi('log').' ('.
            $self->qi('unix').', '.
            $self->qi('machine_id').', '.
            $self->qi('key').', '.
            $self->qi('value').') '.
            'VALUES (?, ?, ?, ?)');
        $step++;

        $self->{'sth'}{'sel_last_atominfo'} = $self->{'dbh'}->prepare(
            'SELECT id, '.$self->qi('value').' '.
            'FROM logatom '.
            'WHERE machine_id = ? '.
            'AND '.$self->qi('key').' = ? '.
            'ORDER BY id DESC '.
            'LIMIT 1');
        $step++;

        $self->{'sth'}{'up_atominfo'} = $self->{'dbh'}->prepare(qq{
            UPDATE logatom SET unix_last = ?
            WHERE id = ?
            LIMIT 1 });
        $step++;

        $self->{'sth'}{'ins_atominfo'} = $self->{'dbh'}->prepare(
            'INSERT INTO logatom ('.
            $self->qi('machine_id').', '.
            $self->qi('key').', '.
            $self->qi('unix_first').', '.
            $self->qi('unix_last').', '.
            $self->qi('value').') '.
            'VALUES (?, ?, ?, ?, ?)');
        $step++;
    };
    die "Failed to prepare DB statements (step $step)! $@\n" if $@;
    $self->{'dbh'}{'RaiseError'} = 0;

    # commit enqueued data if needed
    #$self->commit;

    warn "Connected to DB.\n";
}

#-------------------------------------------------------------------------------
sub on_disconnect
{
    my ($self, $poe_session, $commit_first) = @_[OBJECT, SESSION, ARG0];

    if (defined $self->{'dbh'})
    {
        #$self->commit if $commit_first; # flush remaining enqueued data
        warn "Disconnecting from DB...\n" if $commit_first;

        $self->{'sth'} = undef;
        $self->{'dbh'}->disconnect
            or warn "Failed to disconnect DBI (", $self->{'dbh'}->err, ")! ", $self->{'dbh'}->errstr, "\n";
        $self->{'dbh'} = undef;
    }
}



#-------------------------------------------------------------------------------
sub _read_machines
{
    my $self = shift;

    return unless $self->is_connected;

    my $sth = $self->{'dbh'}->prepare('SELECT id, name FROM machine');
    unless (defined $sth->execute)
    {
        warn 'Failed to fetch machines from db ('.$sth->err.')! ', $sth->errstr, "\n";
        return;
    }

    $self->{'machines'} = { };
    while (my $row = $sth->fetchrow_hashref)
    {
        $self->{'machines'}{$row->{'name'}} = $row->{'id'};
    }
}

#-------------------------------------------------------------------------------
sub _machine_id
{
    my ($self, $machine_name) = @_;

    sub _match_machine
    {
        my ($ref_machines, $name) = @_;
        while (my ($k, $v) = each %$ref_machines)
        {
            # case-insensitive test
            if (lc($name) eq lc($k))
            {
                keys %$ref_machines; # reset
                return $v;
            }
        }
        return;
    }

    $self->_read_machines unless defined $self->{'machines'};
    return unless defined $self->{'machines'}; # in case _read_machines() failed

    # if we already know this machine, just return its id...
    my $id = _match_machine $self->{'machines'}, $machine_name;
    return $id if defined $id;

    # ... otherwise, we have to register it
    {
        unless (length($machine_name) > 0 and $machine_name =~ /^\w+$/)
        {
            warn "Invalid characters found in machine name \"$machine_name\"!\n";
            return;
        }

        my $sth = $self->{'sth'}{'ins_machine'};
        my $res = $sth->execute($machine_name);
        if ($res != 1)
        {
            warn "Failed to insert machine \"$machine_name\" into db ($res; ", $sth->err, ")! ", $sth->errstr, "\n";
            return;
        }
    }

    # reload machines listing from db
    $self->_read_machines;

    # check if our machine is there now
    $id = _match_machine $self->{'machines'}, $machine_name;
    return $id if defined $id;

    # still not?!
    warn "Machine \"$machine_name\" still not inserted into db!\n";
    return;
}


1;
