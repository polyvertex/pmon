#!/usr/bin/env perl
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
# Created On: 2013-02-23 16:10:05Z
#
# $Id$
#

use strict;
use warnings;

use Time::Local ();
use Storable ();
use Symbol qw(gensym);
use POSIX qw(dup2);
use Socket;
use IO::Select ();


# enforce POSIX locale
BEGIN { $ENV{'LC_ALL'} = 'POSIX'; }

# get our location
my $MY_DIR;
BEGIN { $MY_DIR = (__FILE__ =~ /(.*)[\\\/]/) ? $1 : '.'; }

# configuration
use constant
{
    # paths
    REVISION_FILE      => $MY_DIR.'/../.revision',
    SCRIPTS_DIR        => $MY_DIR.'/../etc/scripts',
    CONFIG_FILE        => $MY_DIR.'/../etc/pmon-agent.conf',
    BINCONFIG_FILE     => $MY_DIR.'/../var/pmon-agent.conf.bin',
    PID_FILE           => $MY_DIR.'/../var/pmon-agent.pid',
    FRESH_INSTALL_FILE => $MY_DIR.'/../var/.installed-agent',

    # maximum running time for a script
    CHILDREN_TIMEOUT => 45, # seconds

    # timeout value for a send() operation
    SEND_TIMEOUT => 10, # seconds

    # the maximum supported length of a info line
    MAX_INFO_LENGTH => 255,

    # the maximum number of bytes to accumulate before actually sending content
    # to the server
    MAX_UDP_BUFFER_LENGTH => 200,
};

# global variables
my $ref_config = { };
my $now = time;
my $revision = 0;
my $tzoffset = Time::Local::timegm(localtime $now) - $now; # timezone offset in seconds
my $uptime;
my $pidfile_installed;
my $server_buffer = '';
my %accepted_freq;
my @errors;
my %children;


#-------------------------------------------------------------------------------
sub flush_info
{
    return unless length($server_buffer) > 0;
    my $res = eval {
        local $SIG{'ALRM'} = sub { die "flush_info() timeout!\n"; };
        alarm SEND_TIMEOUT;

        my $proto = getprotobyname 'udp';
        my $iaddr = gethostbyname $ref_config->{server_host};
        my $sin   = sockaddr_in $ref_config->{server_port}, $iaddr;
        my $sock;

        socket $sock, PF_INET, SOCK_DGRAM, $proto;
        my $sent = send $sock, $server_buffer, 0, $sin;

        if ($sent != length $server_buffer)
        {
            my $err = "Incomplete send() to ".$ref_config->{server_host}.":".
                $ref_config->{server_port}." ($sent/".length($server_buffer).
                " bytes)!";
            push @errors, $err;
            warn $err, "\n";
        }

        alarm 0;
    };
    unless (defined $res)
    {
        my $err = "flush_info() failed! $@";
        chomp $err;
        push @errors, $err;
        warn $err, "\n";
    }
    $server_buffer = '';
}

#-------------------------------------------------------------------------------
sub send_info
{
    my $info = shift;

    chomp $info;
    return unless defined($info) and length($info) > 0;
    if (length($info) > MAX_INFO_LENGTH)
    {
        my $err = "Info too big to be sent: $info";
        push @errors, $err;
        warn $err, "\n";
        return;
    }

    my $message = "pmon1 ".$ref_config->{machine_uniq}." $info\n";

    if (length($message) >= MAX_UDP_BUFFER_LENGTH and !length($server_buffer))
    {
        $server_buffer = $message;
        flush_info;
    }
    elsif (length($message) + length($server_buffer) >= MAX_UDP_BUFFER_LENGTH)
    {
        flush_info;
        $server_buffer = $message;
    }
    else
    {
        $server_buffer .= $message;
    }
}

#-------------------------------------------------------------------------------
sub drop_priv
{
    my ($uid, $gid) = @_;
    $) = "$gid $gid"; # set EGID
    $> = $uid + 0;    # set EUID
    die "Can't drop EUID.\n" if $> != $uid;
}



#-------------------------------------------------------------------------------
BEGIN { $| = 1; }
END { unlink(PID_FILE) if $pidfile_installed and -e PID_FILE; }

# check user id
#die "You must be root to run PMon Agent!\n"
#    unless $) != 0;

# get system's uptime
{
    open(my $fh, '<', '/proc/uptime')
        or die "Failed to open /proc/uptime! $!\n";
    $uptime = <$fh>;
    die "Failed to read /proc/uptime format!\n"
        unless defined($uptime)
        and $uptime =~ /^(\d+)/;
    $uptime = $1;
    close $fh;
}

# check pid file
if (-e PID_FILE)
{
    # extract pid
    open(my $fh, '<', PID_FILE)
        or die "Failed to open ", PID_FILE, "! $!\n";
    my $pid = <$fh>;
    close $fh;

    # check pid
    if (defined($pid) and $pid =~ /^\s*(\d{1-6})\s*$/)
    {
        $pid = $1;
        die "PMon Agent is already running (pid $pid)!\n"
            if -e "/proc/$pid";
        warn "Obsolete PID file found (", PID_FILE, ").\n";
    }
    else
    {
        warn "Incorrect content format found in ", PID_FILE, "!\n";
    }

    unlink PID_FILE;
}

# create pid file
{
    open(my $fh, '>', PID_FILE)
        or die "Failed to create PID file ", PID_FILE, "! $!\n";
    print $fh "$$\n";
    close $fh;
    $pidfile_installed = 1;
}

# try to get agent's revision number
if (-e REVISION_FILE)
{
    if (open my $fh, '<', REVISION_FILE)
    {
        $revision = <$fh>;
        chomp $revision;
        $revision = 0 unless $revision =~ /^\d+$/;
        close $fh;
    }
}

# read configuration file
if (-e CONFIG_FILE and -e BINCONFIG_FILE)
{
    my $mod_self = (stat(__FILE__))[9];
    my $mod_txt  = (stat(CONFIG_FILE))[9];
    my $mod_bin  = (stat(BINCONFIG_FILE))[9];

    goto __read_txt_config
        unless defined($mod_self) and defined($mod_txt) and defined($mod_bin)
        and $mod_bin > $mod_txt   # txt config file has been modified?
        and $mod_bin > $mod_self; # agent has been upgraded?

    $ref_config = Storable::retrieve(BINCONFIG_FILE);
    unless (defined $ref_config)
    {
        warn "Failed to read binary config file ", BINCONFIG_FILE,
            "! Switching back to ", CONFIG_FILE, "...\n";
        goto __read_txt_config;
    }
}
else # read text config file
{
    __read_txt_config:

    # init config
    $ref_config = {
        machine_uniq  => undef,
        server_host   => undef,
        server_port   => 7666,
        busy_uptime   => 900,
        daily_hour    => 2,
        scripts_order => [ ], 
        scripts       => { },
    };

    # open config file
    my $oconf = PMon::Config->new(
        file   => CONFIG_FILE,
        strict => 1,
        #subst  => { '{BASEDIR}' => $MY_DIR.'/..', },
    );
    die "No configured scripts found in ", CONFIG_FILE, "!\n"
        unless @{$oconf->sections_list} > 0;

    # machine name
    $ref_config->{machine_uniq} = $oconf->get_str('machine_uniq');
    die "Setting 'machine_uniq' not found or have incorrect format in ", CONFIG_FILE, "!\n"
        unless defined($ref_config->{machine_uniq})
        and $ref_config->{machine_uniq} =~ /^[\w\-\_\.]+$/;

    # server host
    $ref_config->{server_host} = $oconf->get_str('server_host');
    die "Setting 'server_host' not found or have incorrect format in ", CONFIG_FILE, "!\n"
        unless defined($ref_config->{server_host})
        and $ref_config->{server_host} =~ /^[0-9A-Za-z\.\-_]+$/;

    # server port
    $ref_config->{server_port} = $oconf->get_int(
        'server_port', $ref_config->{server_port}, 1, 65535);

    # busy uptime
    $ref_config->{busy_uptime} = $oconf->get_int(
        'busy_uptime', $ref_config->{busy_uptime}, 60, 3600);

    # daily hour
    $ref_config->{daily_hour} = $oconf->get_int(
        'daily_hour', $ref_config->{daily_hour}, 0, 23);

    # collect all enabled scripts
    foreach my $script_name (@{$oconf->sections_list})
    {
        next unless $oconf->get_bool("$script_name/enabled");

        my $freq = $oconf->get_str("$script_name/freq");
        die "Frequency not defined (correctly) for script $script_name in ", CONFIG_FILE, "!\n"
            unless defined($freq)
            and $freq =~ /^[MHD]$/i;

        my $args = $oconf->get_str("$script_name/args", '');

        push @{$ref_config->{scripts_order}}, $script_name;
        $ref_config->{scripts}{$script_name} = {
            freq => uc $freq,
            args => $args,
        };
    }

    # create binary config file
    Storable::store($ref_config, BINCONFIG_FILE);
}

# select the accepted frequencies
{
    my @anow      = localtime $now;
    my $now_hour  = $anow[2];
    my $now_min   = $anow[1];
    my $force_all = (@ARGV > 0 and $ARGV[0] eq '--forceall') ? 1 : 0;

    # launch all scripts if it is the first time the agent is launched since
    # last install
    if (-e FRESH_INSTALL_FILE)
    {
        $force_all = 1;
        # do not remove the file if we are running from a terminal, that allows
        # user to check everything is ok manually before configuring the cron.
        unlink FRESH_INSTALL_FILE
            unless -t STDOUT;
    }

    warn "All scripts forced.\n" if $force_all and -t STDERR;

    # select accepted frequencies
    $accepted_freq{M} = 1;
    $accepted_freq{H} = 1
        if $force_all
        or $uptime < $ref_config->{busy_uptime}
        or ($now_min >= 0 and $now_min <= 5);
    $accepted_freq{D} = 1
        if $force_all
        or ( ($now_hour == $ref_config->{daily_hour} or $uptime < $ref_config->{busy_uptime})
        and $now_min % 10 == 0 );
}

# send info we've got
send_info "pmona.revision $revision";
send_info "sys.tzoffset $tzoffset";
send_info "sys.uptime $uptime";

# launch scripts in separate processes
my $read_set = IO::Select->new();
foreach my $script_name (@{$ref_config->{scripts_order}})
{
    my $script = SCRIPTS_DIR."/$script_name";
    my $ref_script = $ref_config->{scripts}{$script_name};

    die "Script $script_name is enabled in config file but not found in ", SCRIPTS_DIR, "!\n"
        unless -e SCRIPTS_DIR."/$script_name";
    next unless exists $accepted_freq{$ref_script->{freq}};

    my @stats = stat $script;
    my $uid = $stats[4];

    my $p_stdout_read  = gensym();
    my $p_stdout_write = gensym();
    my $p_stderr_read  = gensym();
    my $p_stderr_write = gensym();

    pipe($p_stdout_read, $p_stdout_write) or die "pipe() failed! $!";
    pipe($p_stderr_read, $p_stderr_write) or die "pipe() failed! $!";

    my $child_pid = fork;
    die "fork() failed! $!" unless defined $child_pid;
    if ($child_pid == 0)
    {
        if ($uid > 0)
        {
            my $gid = $stats[5];
            drop_priv($uid, $gid)
        }

        dup2(fileno($p_stdout_write), 1) or die "dup2() failed! $!";
        dup2(fileno($p_stderr_write), 2) or die "dup2() failed! $!";
        close $p_stdout_read;
        close $p_stderr_read;
        close $p_stdout_write;
        close $p_stderr_write;
        my $code;
        my $err;
        my $res = eval {
            local $SIG{'ALRM'} = sub { $err = 'Timeout!'; die; };
            alarm CHILDREN_TIMEOUT;
            system "$script ".$ref_script->{args};
            if ($? == -1)
            {
                $err = "system() failed! $!";
                die;
            }
            $code = $? >> 8;
        };
        unless (defined $res)
        {
            $code = 1 unless defined $code;
            $err  = 'Unknown error!' unless defined $err;
            chomp $err;
            die "$script_name: $err\n";
        }
        exit $code;
    }

    close $p_stdout_write;
    close $p_stderr_write;
    $read_set->add($p_stdout_read);
    $read_set->add($p_stderr_read);
    $children{$child_pid} = {
        name   => $script_name,
        stdout => $p_stdout_read,
        stderr => $p_stderr_read,
        errout => [ ],
    };
}

# processing children's io events
while (my @fds = $read_set->can_read)
{
    foreach my $fd (@fds)
    {
        my $slot;
        foreach my $s (values %children)
        {
            if ($fd == $s->{stdout} or $fd == $s->{stderr})
            {
                $slot = $s;
                last;
            }
        }
        unless (defined $slot)
        {
            warn "Got IO event from unknown file descriptor!";
            $read_set->remove($fd);
            close $fd;
            next;
        }
        my $line = <$fd>;
        unless (defined $line)
        {
            $read_set->remove($fd);
            close $fd;
            next;
        }
        chomp $line;
        next unless length($line) > 0;
        if ($fd == $slot->{stderr})
        {
            push @{$slot->{errout}}, $line;
            warn $line, "\n" if -t STDERR;
        }
        else
        {
            print $line, "\n" if -t STDOUT;
            send_info $line
                if $line =~ /^([\w\-\_\.]+)\s+(\S+.*)$/;
        }
    }
}

# wait for every scripts to complete and check if they are in error
while (1)
{
    my $pid = waitpid -1, 0;
    last unless $pid > 0;
    $children{$pid}{status} = $? >> 8;
    if ($children{$pid}{status} != 0)
    {
        my $err = join ' ', map { chomp; $_ } @{$children{$pid}{errout}};
        chomp $err;
        $err = $children{$pid}{name}.": $err";
        push @errors, $err;
        warn $err, "\n";
    }
}

if (@errors == 0)
{
    send_info 'agent.status 0';
    flush_info;
    exit 0;
}
else
{
    my $info = 'agent.status '.scalar(@errors).' '.$errors[0];
    if (length($info) > MAX_INFO_LENGTH)
    {
        $info  = substr $info, 0, MAX_INFO_LENGTH - 3;
        $info .= '...';
    }
    send_info $info;
    flush_info;
    exit 1;
}
