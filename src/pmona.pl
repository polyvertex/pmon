#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-02-23 16:10:05Z
#
# $Id$
#

use strict;
use warnings;

use Time::Local ();
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
    SCRIPTS_DIR_BASE   => $MY_DIR.'/../etc/scripts-',
    CONFIG_FILE        => $MY_DIR.'/../etc/pmona.conf',
    PID_FILE           => $MY_DIR.'/../var/pmona.pid',
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
my %config;
my $now = time;
my $tzoffset = Time::Local::timegm(localtime $now) - $now; # timezone offset in seconds
my $uptime;
my $pidfile_installed;
my $server_buffer = '';
my @errors;
my @scripts;
my %children;


#-------------------------------------------------------------------------------
sub script_label
{
    my $path = shift;
    return defined($2) ? "$2/$3" : $3
        if $path =~ m%(([^/]+)/+)?([^/]+)$%;
    return $path;
}

#-------------------------------------------------------------------------------
sub flush_info
{
    return unless length($server_buffer) > 0;
    my $res = eval {
        local $SIG{'ALRM'} = sub { die "flush_info() timeout!\n"; };
        alarm SEND_TIMEOUT;

        my $proto = getprotobyname 'udp';
        my $iaddr = gethostbyname $config{'server_host'};
        my $sin   = sockaddr_in $config{'server_port'}, $iaddr;
        my $sock;

        socket $sock, PF_INET, SOCK_DGRAM, $proto;
        my $sent = send $sock, $server_buffer, 0, $sin;
        print $server_buffer;

        if ($sent != length $server_buffer)
        {
            my $err = "Incomplete send() to ".$config{'server_host'}.":".
                $config{'server_port'}." ($sent/".length($server_buffer).
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

    my $message = "pmon1 ".$config{'machine_uniq'}." $now $info\n";

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

# read configuration file
{
    # setup accepted values
    %config = (
        machine_uniq => undef,
        server_host  => undef,
        server_port  => 7666,
        busy_uptime  => 900,
        daily_hour   => 2,
        #cmd_ls       => '/bin/ls',
    );

    # read file
    open(my $fh, '<', CONFIG_FILE)
        or die "Failed to open ", CONFIG_FILE, "! $!\n";
    while (<$fh>)
    {
        chomp; s/^\s+//; s/^#.*//; s/\s+$//;
        next unless length; # skip comment and empty lines
        die "Wrong key-value pair format in ", CONFIG_FILE, " at line $.!"
            unless /^(\w+)\s*=\s*(.*)$/;
        die "Unknown value name '$1' in ", CONFIG_FILE, " at line $.!"
            unless exists $config{$1};
        $config{$1} = $2 // '';
    }
    close $fh;

    # check machine name
    die "Setting 'machine_uniq' not found or have incorrect format in ", CONFIG_FILE, "!\n"
        unless defined($config{'machine_uniq'})
        and $config{'machine_uniq'} =~ /^\w+$/;

    # server host
    die "Setting 'server_host' not found or have incorrect format in ", CONFIG_FILE, "!\n"
        unless defined($config{'server_host'})
        and $config{'server_host'} =~ /^[0-9A-Za-z\.\-_]+$/;

    # server port
    die "Incorrect value of 'server_port' in ", CONFIG_FILE, "!\n"
        unless $config{'server_port'} =~ /^\d+$/
        and $config{'server_port'} >= 1
        and $config{'server_port'} <= 65535;

    # busy uptime
    die "Incorrect value of 'busy_uptime' in ", CONFIG_FILE, "!\n"
        unless $config{'busy_uptime'} =~ /^\d+$/
        and $config{'busy_uptime'} >= 60
        and $config{'busy_uptime'} <= 3600;

    # daily hour
    die "Incorrect value of 'daily_hour' in ", CONFIG_FILE, "!\n"
        unless $config{'daily_hour'} =~ /^\d+$/
        and $config{'daily_hour'} >= 0
        and $config{'daily_hour'} <= 23;

    # ls command
    $config{'cmd_ls'} = '/bin/ls';
    $config{'cmd_ls'} = 'ls' unless -x $config{'cmd_ls'};
}

# collect scripts to run
{
    my @groups = qw( minute );
    my @collected_scripts;
    my @anow      = localtime $now;
    my $now_hour  = $anow[2];
    my $now_min   = $anow[1];
    my $force_all = (@ARGV > 0 and $ARGV[0] eq '--forceall') ? 1 : 0;

    # launch all scripts if it is the first time the agent is launched since
    # last install
    if (-e FRESH_INSTALL_FILE)
    {
        $force_all = 1;
        unlink FRESH_INSTALL_FILE;
    }

    warn "All scripts forced.\n" if $force_all;

    # select scripts to run
    push(@groups, 'hourly')
        if $force_all
        or $uptime < $config{'busy_uptime'}
        or ($now_min >= 0 and $now_min <= 5);
    push(@groups, 'daily')
        if $force_all
        or ( ($now_hour == $config{'daily_hour'} or $uptime < $config{'busy_uptime'})
        and $now_min % 10 == 0 );

    # collect scripts
    my $ls = $config{'cmd_ls'}.' -1';
    foreach my $group (@groups)
    {
        my $d = SCRIPTS_DIR_BASE."$group";
        my @fnames = qx/$ls "$d"/;
        die "Failed to collect scripts from $d!\n"
            unless ($? >> 8) == 0;
        chomp @fnames;
        push @scripts, map { "$d/$_" } @fnames;
    }
}

# send info we've got
send_info "sys.tzoffset $tzoffset";
send_info "sys.uptime $uptime";

# launch scripts in separate processes
my $read_set = IO::Select->new();
foreach my $script (@scripts)
{
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
            system $script;
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
            die script_label($script), ': ', $err, "\n";
        }
        exit $code;
    }

    close $p_stdout_write;
    close $p_stderr_write;
    $read_set->add($p_stdout_read);
    $read_set->add($p_stderr_read);
    $children{$child_pid} = {
        script => $script,
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
            if ($fd == $s->{'stdout'} or $fd == $s->{'stderr'})
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
        if (!$line)
        {
            $read_set->remove($fd);
            close $fd;
            next;
        }
        chomp $line;
        if ($fd == $slot->{'stderr'})
        {
            push @{$slot->{'errout'}}, $line;
            #warn $line, "\n";
        }
        else
        {
            send_info $line;
        }
    }
}

# wait for every scripts to complete and check if they are in error
while (1)
{
    my $pid = waitpid -1, 0;
    last unless $pid > 0;
    $children{$pid}->{'status'} = $? >> 8;
    if ($children{$pid}->{'status'} != 0)
    {
        my $label = script_label $children{$pid}{'script'};
        my $err = join ' ', map { chomp; $_ } @{$children{$pid}{'errout'}};
        chomp $err;
        $err = "$label: $err";
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
