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
# Created On: 2013-03-13 09:41:49Z
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
die "Failed to run \"$cmd\" (code ", sprintf('0x%X', $?), ")!\n"
    unless $? == 0;

my $found = 0;
foreach (@lines)
{
    chomp;
    if (/^Total\s+Accesses\s*:\s+(\d+)$/i) {
        print "lighttpd.hits $1\n";
        ++$found;
    }
    elsif (/^Total\s+kBytes\s*:\s+(\d+)$/i) {
        print "lighttpd.bytes ", ($1 * 1024), "\n";
        ++$found;
    }
    last if $found >= $EXPECTED;
}

die "Could not read every expected values ($found/$EXPECTED) from the output of \"$cmd\"!\n"
    if $found < $EXPECTED;
