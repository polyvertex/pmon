#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-11 15:16:59Z
#
# $Id$
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
