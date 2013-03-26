#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-26 10:37:18Z
#
# $Id$
#

use strict;
use warnings;

use FindBin ();
use File::Basename ();
use Getopt::Long ();
use Socket;
use DBI;

use lib "$FindBin::RealBin";
use PMon::Config;


use constant
{
    # default paths
    DEFAULT_PMOND_CONFIG_FILE => $FindBin::RealBin.'/../etc/pmond.conf',
    DEFAULT_PMONA_CONFIG_FILE => $FindBin::RealBin.'/../etc/pmona.conf',

    # timeout value for a send() operation
    SEND_TIMEOUT => 10, # seconds

    # the maximum number of bytes to accumulate before actually sending content
    # to the server
    MAX_UDP_BUFFER_LENGTH => 200,
};



#-------------------------------------------------------------------------------
sub usage
{
    my $name = File::Basename::basename(__FILE__);
    my $default_pmond_configfile = DEFAULT_PMOND_CONFIG_FILE;
    my $default_pmona_configfile = DEFAULT_PMONA_CONFIG_FILE;

  die <<USAGE;
Usage:
    $name [options]

    This script allows to recreate from scratch the content of the 'logatom'
    database table from the 'log' table, in case it has been corrupted up by a
    bug found into the code of the daemon or the agent.

    CAUTION: During its process, all the connected agent's (installed locally or
    onto other machines) MUST NOT try to send new data as it may corrupt the
    'logatom' table again.
    Please ensure you downloaded the latest version of this script AND the
    daemon!
    Please also ensure that the configuration files of the local agent and
    daemon are up-to-date.

    It acts like a regular agent except that it does not read values from
    physical sensors but from the 'log' table of the PMon's database.
    It also use a special protocol to communicate with the daemon so the
    timestamp of the gathered value can be sent as well (by default, tfor the
    sake of safety and coherence, the timestamp inserted into the database comes
    from the daemon, not the agent).

Parameters:
    --help, -h
        Print this message and quit.
    --config-daemon={config_file}
        Specify the path of the daemon's configuration file. Defaults to:
        $default_pmond_configfile
    --config-agent={config_file}
        Specify the path of the agent's configuration file. Defaults to:
        $default_pmona_configfile

USAGE
}

#-------------------------------------------------------------------------------
sub flush_info
{
    my $ctx = shift;

    return unless length($ctx->{server_buffer}) > 0;

    my $res = eval {
        local $SIG{'ALRM'} = sub { die "flush_info() timeout!\n"; };
        alarm SEND_TIMEOUT;

        my $proto = getprotobyname 'udp';
        my $iaddr = gethostbyname $ctx->{server_host};
        my $sin   = sockaddr_in $ctx->{server_port}, $iaddr;
        my $sock;

        socket $sock, PF_INET, SOCK_DGRAM, $proto;
        my $sent = send $sock, $ctx->{server_buffer}, 0, $sin;

        die "Incomplete send() to ", $ctx->{server_host}, ":",
            $ctx->{server_port}, " ($sent/", length($ctx->{server_buffer}),
            " bytes)!\n"
            if $sent != length $ctx->{server_buffer};

        alarm 0;
    };
    die "flush_info() failed! $@\n"
        unless defined $res;

    $ctx->{server_buffer} = '';
}

#-------------------------------------------------------------------------------
sub send_info
{
    my ($ctx, $unix, $machine_name, $info_name, $info_value) = @_;
    my $message = sprintf
        "pmon0 %s %s %s %s\n",
        $unix, $machine_name, $info_name, $info_value;

    if (length($message) >= MAX_UDP_BUFFER_LENGTH and !length($ctx->{server_buffer}))
    {
        $ctx->{server_buffer} = $message;
        flush_info $ctx;
    }
    elsif (length($message) + length($ctx->{server_buffer}) >= MAX_UDP_BUFFER_LENGTH)
    {
        flush_info $ctx;
        $ctx->{server_buffer} = $message;
    }
    else
    {
        $ctx->{server_buffer} .= $message;
    }
}

#-------------------------------------------------------------------------------
sub log2atom
{
    my $ctx = shift;
    my @columns = qw( id unix machine_id key value );
    my $offset = 0;
    my %unknown_machine_ids;

    # the big loop
    while (1)
    {
        my $rows = $ctx->{dbh}->selectall_arrayref(
            "SELECT l.".join(', l.', @columns)." ".
            "FROM log AS l ".
            "ORDER BY l.id ASC ".
            "LIMIT $offset, ".($offset + $ctx->{db_maxrows})." ");
        last unless defined($rows) and @$rows > 0;

        while (@$rows > 0)
        {
            my %r = map { $columns[$_] => $rows->[0][$_] } 0..$#columns;

            shift @$rows;
            ++$offset;

            unless (exists $ctx->{machines}{$r{machine_id}})
            {
                $unknown_machine_ids{$r{machine_id}} = undef;
                next;
            }

            send_info $ctx, $r{unix}, $ctx->{machines}{$r{machine_id}}{name},
                $r{key}, $r{value};
        }
    }

    flush_info $ctx;

    warn "Some of the rows in the 'log' table could not be sent to the daemon ",
        "because the following machine's id(s) did not match: ",
        join(', ', sort keys(%unknown_machine_ids)), "\n"
        if keys(%unknown_machine_ids) > 0;
}



#-------------------------------------------------------------------------------
my %ctx = ( # global context
    help => undef,

    configfile_daemon => DEFAULT_PMOND_CONFIG_FILE,
    configfile_agent  => DEFAULT_PMONA_CONFIG_FILE,

    db_source  => undef,
    db_user    => undef,
    db_pass    => undef,
    db_maxrows => 10_000, # max number of rows fetched at time

    server_host => undef,
    server_port => undef,

    dbh           => undef,
    machines      => { },
    server_buffer => '',
);
my $res;

BEGIN { $| = 1; }

# parse parameters
$res = Getopt::Long::GetOptions(
    'help|h|?'        => \$ctx{help},
    'config-daemon=s' => \$ctx{configfile_daemon},
    'config-agent=s'  => \$ctx{configfile_agent},
);
usage unless $res and not $ctx{help};
delete $ctx{help};

# read daemon's config file
{
    my $oconf = PMon::Config->new(
        file   => $ctx{configfile_daemon},
        strict => 1,
    );

    $ctx{db_source} = $oconf->get_str('db_source');
    $ctx{db_user}   = $oconf->get_str('db_user');
    $ctx{db_pass}   = $oconf->get_str('db_pass');
    die "Please check database access credentials in ", $ctx{configfile_daemon}, "!\n"
        unless defined($ctx{db_source})
        and defined($ctx{db_user})
        and defined($ctx{db_pass});
}

# read agent's config file
{
    my $oconf = PMon::Config->new(
        file   => $ctx{configfile_agent},
        strict => 1,
    );

    $ctx{server_host} = $oconf->get_str('server_host');
    $ctx{server_port} = $oconf->get_int('server_port', 7666, 1, 65535);
    die "Please check server's address in ", $ctx{configfile_agent}, "!\n"
        unless defined($ctx{server_host})
        and defined($ctx{server_port});
}

# connect to database
$ctx{dbh} = DBI->connect(
    $ctx{db_source}, $ctx{db_user}, $ctx{db_pass}, {
        AutoCommit => 1,
        RaiseError => 1,
        PrintWarn  => 1,
        PrintError => 1,
    } );
die "Failed to connect DBI (", $DBI::err, ")! ", $DBI::errstr, "\n"
    unless defined $ctx{dbh};

# fetch machines names
$ctx{machines} = $ctx{dbh}->selectall_hashref(
    'SELECT id, name FROM machine', 'id');
die "No machine found in DB!\n" unless keys(%{$ctx{machines}}) > 0;

# empty the log2atom table first
$ctx{dbh}->do('TRUNCATE TABLE logatom') or die $ctx{dbh}->errstr;

# go!
log2atom \%ctx;

exit 0;
