#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-13 08:21:33Z
#
# $Id$
#

use strict;
use warnings;

$ENV{'LC_ALL'} = 'POSIX';

my $url = (@ARGV >= 1) ? $ARGV[0] : 'http://127.0.0.1:80/server-status?auto';
my $EXPECTED = 2; # number of expected values


my $cmd = "lynx -dump $url";
my @lines = qx/$cmd/;
die "Failed to run \"$cmd\"!\n" unless $? == 0;

my $found = 0;
foreach (@lines)
{
    chomp;
    if (/^Total\s+Accesses\s*:\s+(\d+)$/i) {
        print "apache.hits $1\n";
        ++$found;
    }
    elsif (/^Total\s+kBytes\s*:\s+(\d+)$/i) {
        print "apache.bytes ", ($1 * 1024), "\n";
        ++$found;
    }
    #elsif (/^Uptime\s*:\s+(\d+)$/i) { # update the $EXPECTED value if you (un)comment this !
    #    print "apache.uptime $1\n";
    #    ++$found;
    #}
    #elsif (/^BytesPerReq\s*:\s+(\d+)$/i) { # update the $EXPECTED value if you (un)comment this !
    #    print "apache.bytesperreq $1\n";
    #    ++$found;
    #}
    last if $found >= $EXPECTED;
}

die "Could not read every expected values ($found/$EXPECTED) from the output of \"$cmd\"!\n"
    if $found < $EXPECTED;
