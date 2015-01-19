#!/usr/bin/env perl
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
# Created On: 2013-03-11 15:16:59Z
#

use strict;
use warnings;

my %info;
my %netifs;


sub net_stats
{
    my $count = 0;
    my $size = scalar(keys %netifs);

    open(my $fh, '</proc/net/dev')
        or die "Failed to open /proc/net/dev! $!\n";
    while (<$fh>)
    {
        chomp;
        if (/^\s*(\w+):\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$/)
        {
            my $netif = $1;

            next unless exists $netifs{$netif};
            $netifs{$netif} = 1;
            ++$count;

            $info{"net.$netif.bytes.in"}    = $2;
            $info{"net.$netif.bytes.out"}   = $10;
            $info{"net.$netif.packets.in"}  = $3;
            $info{"net.$netif.packets.out"} = $11;

            last if $count >= $size;
        }
    }
    close $fh;

    foreach (keys %netifs)
    {
        warn "Did not get any statistics for netif \"$_\"!\n"
            unless $netifs{$_};
    }
}


BEGIN { $ENV{'LC_ALL'} = 'POSIX'; }
die "No network interface specified in parameters!\n" unless @ARGV > 0;
$netifs{$_} = undef foreach (@ARGV);
net_stats;
END
{
    my $out = '';
    $out .= "$_ ".$info{$_}."\n" foreach (sort keys(%info));
    print $out if length($out);
}
