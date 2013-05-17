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
# Created On: 2013-02-23 16:10:03Z
#
# $Id$
#

use strict;
use warnings;

use FindBin ();
use Getopt::Long ();
use POE;

use lib "$FindBin::RealBin";
use PMon::Daemon;

use constant
{
    FRESH_INSTALL_FILE => $FindBin::RealBin.'/../var/.installed-daemon',
};


#-------------------------------------------------------------------------------
sub IS_WINDOWS () { $^O =~ /^MSWin/i }

#-------------------------------------------------------------------------------
sub usage
{
  die <<USAGE;
Usage:
    $0 {--config} {--log} {--pid} [--foreground]

Parameters:
    --help, -h
        Print this message and leave.
    --config={config_file}
        Specify the path of the configuration file.
    --foreground
        Do not run in background.
    --log={log_file}
        Specify the path of the log file.
    --pid={pid_file}
        Specify the path of the PID file.

USAGE
}

#-------------------------------------------------------------------------------
my %options = (
    configfile => undef,
    logfile    => undef,
    pidfile    => undef,
    foreground => undef,
);
my $exitcode = 0;
my $hlog;


BEGIN { $| = 1; }

# parse parameters
my $res = Getopt::Long::GetOptions(
    'help|h'     => \$options{help},
    'config=s'   => \$options{configfile},
    'foreground' => \$options{foreground},
    'logfile=s'  => \$options{logfile},
    'pid=s'      => \$options{pidfile},
);
usage unless $res and not $options{help};
usage unless defined $options{configfile};
usage unless defined $options{logfile};
usage unless defined $options{pidfile};

# right we do nothing specific when we just have been (re)installed
unlink FRESH_INSTALL_FILE if -e FRESH_INSTALL_FILE;

# daemonize if wanted
unless (IS_WINDOWS() or $options{foreground})
{
    require POSIX;

    warn "Going background...\n";

    my $pid = fork;
    die "Failed to fork! $!\n" unless defined $pid;
    exit 0 if $pid != 0; # exit parent process

    # detach ourselves from the terminal
    POSIX::setsid() != -1
        or die "Failed to detach from terminal! $!";

    # reopen stderr, stdout, stdin to /dev/null
    open STDIN,  "+>/dev/null";
    open STDOUT, "+>/dev/null";
    open STDERR, "+>&STDOUT";

    # enable autoflush
    $| = 1;
}

# open log file and enable autoflush
# http://perl.plover.com/FAQs/Buffering.html
open($hlog, '>>', $options{logfile})
    or die "Failed to open log file ", $options{logfile}, "! $!\n";
select((select($hlog), $|=1)[0]);
#print $hlog "\n";

# open syslog
unless (IS_WINDOWS)
{
    require Sys::Syslog;
    Sys::Syslog::openlog('pmond', 'pid', 'user');
}

# create pid file
{
    open(my $fh, '>', $options{pidfile})
        or die "Failed to create PID file ", $options{pidfile}, "!\n";
    print $fh "$$\n";
    close $fh;
}

# define our trap for warns
$SIG{'__WARN__'} = sub
{
    my $msg = shift;
    my @a = localtime;

    unless ($msg =~ /\n\z/)
    {
        my ($packname, $file, $line) = caller;
        $msg .= " at $file line $line.\n";
    }

    if (-t STDERR)
    {
        print STDERR sprintf('%02u:%02u:%02u ', $a[2], $a[1], $a[0]), $msg;
    }
    else
    {
        my $datetime = sprintf '%04u-%02u-%02u %02u:%02u:%02u ',
            $a[5] + 1900, $a[4] + 1, $a[3],
            $a[2], $a[1], $a[0];
        print $hlog $datetime, $msg;

        unless (IS_WINDOWS)
        {
            $msg = substr($msg, 0, 150).' ...' if length($msg) > 150;
            Sys::Syslog::syslog(Sys::Syslog::LOG_WARNING(), $msg);
        }
    }
};

# launch service
{
    $poe_kernel->has_forked;
    PMon::Daemon->new(
        rootdir    => $FindBin::RealBin.'/..',
        configfile => $options{configfile},
    );
    eval { POE::Kernel->run };
    if ($@)
    {
        chomp(my $errstr = $@);
        warn "APPLICATION CRASHED! $errstr\n";
        $exitcode = 1;
    }
}

# close syslog and log file and delete pid file
unless (IS_WINDOWS)
{
    require Sys::Syslog;
    Sys::Syslog::closelog();
}
if (defined $hlog)
{
    print $hlog "\n";
    close $hlog;
}
unlink $options{pidfile}
    if defined($options{pidfile}) and -e $options{pidfile};

exit $exitcode;
