#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-02-26 17:57:49Z
#
# $Id$
#

use strict;
use warnings;

my %info;


sub CPU_STATS_STORAGE_FILE { '/tmp/pmon-cpustats.txt' }

sub hdd_usage
{
    # bytes
    my @df   = qx/df -l/;
    my $code = $? >> 8;
    die "Failed to run 'df -l' command (code $code)!"
      unless $code == 0;
    foreach (@df)
    {
        if (/^\/dev\/(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)/i)
        {
            my $name  = $1;
            my $usage = $5;
            my $mount = $6;

            $name  =~ s%/%-%g;
            $usage =~ s/%//g;

            $info{"mnt.$name.point"} = $mount;
            $info{"mnt.$name.usage"} = $usage;
        }
    }

    # inodes
    @df   = qx/df -li/;
    $code = $? >> 8;
    die "Failed to run 'df -li' command (code $code)!"
      unless $code == 0;
    foreach (@df)
    {
        if (/^\/dev\/(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)/i)
        {
            my $name  = $1;
            my $usage = $5;

            $name  =~ s%/%-%g;
            $usage =~ s/%//g;
            $usage = 0 unless $usage =~ /^\d+$/;

            $info{"mnt.$name.usage_inodes"} = $usage;
        }
    }
}

sub hdd_temp
{
    my @parts;
    my $name;
    my $dev;
    my $cmd;
    my $res;

    open(my $fh, '</proc/partitions')
        or die "Failed to open /proc/partitions! $!\n";
    @parts = <$fh>;
    close $fh;

    foreach (@parts)
    {
        chomp;
        if (/^\s+(\d+)\s+(0)\s+(\d+)\s+(\S+)$/)
        {
            $name = $4;
            $dev  = "/dev/$name";

            die "Unrecognized device name '$name' from /proc/partitions!"
                unless $name =~ /^[a-z]+$/;
            die "Device $dev not found!"
                unless -e $dev;

            $cmd = "hddtemp -uC -n $dev 2> /dev/null";
            $res = qx/$cmd/;
            die "Failed to run '$cmd' (code ", ($? >> 8), ")!"
                unless ($? >> 8) == 0;
            chomp $res;
            $info{"hdd.$name.temp"} = $res
                if $res =~ /^(\d+)$/;
        }
    }
}

sub mem_usage
{
    my @free = qx/free/;
    my $code = $? >> 8;
    die "Failed to run 'free' command (code $code)!"
      unless $code == 0;

    foreach (@free)
    {
        if (/^Swap:\s+(\d+)\s+(\d+)\s+(\d+)/i)
        {
            $info{'swap.total'}   = $1;
            $info{'swap.used'}    = $2;
            $info{'swap.used_pr'} =
                ($1 == 0) ? 0 : sprintf('%d', $2 / $1 * 100);
        }
        elsif (/^Mem:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/i)
        {
            $info{'mem.total'}   = $1;
            $info{'mem.used'}    = $2;
            $info{'mem.free'}    = $3;
            $info{'mem.shared'}  = $4;
            $info{'mem.buffers'} = $5;
            $info{'mem.cached'}  = $6;
            $info{'mem.used_pr'} =
                sprintf('%d', ($2 - $5 - $6) / $1 * 100);
        }
    }
}

sub proc_loadavg
{
    # expected output format from /proc/loadavg:
    # avg1 avg2 avg3 running_threads/total_threads last_running_pid
    my $file = '/proc/loadavg';
    open(my $fh, '<', $file) or die "Failed to open $file! $!\n";
    chomp(my @values = split(/[\s\/]+/, <$fh>));
    close $fh;
    die "Unrecognized output format from $file!\n"
      unless @values == 6;

    $info{'ps.loadavg1'} = $values[0];
    $info{'ps.loadavg2'} = $values[1];
    $info{'ps.loadavg3'} = $values[2];
    $info{'ps.run'}      = $values[3];
    $info{'ps.total'}    = $values[4];
}

sub proc_stat
{
    my $fh;
    my @stats;
    my @cpu_usage1 = ( 0, 0, 0, 0 );
    my @cpu_usage2 = ( 0, 0, 0, 0 );

    open($fh, '</proc/stat') or die "Failed to open /proc/stat! $!\n";
    @stats = <$fh>;
    close $fh;

    foreach (@stats)
    {
        @cpu_usage2 = ( $1, $2, $3, $4 )
            if /^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/i;
        #$info{'sys.boottime'} = $1
        #    if /^btime\s+(\d+)/i;
    }

    # first-time run?
    unless (-e CPU_STATS_STORAGE_FILE)
    {
        open($fh, '>', CPU_STATS_STORAGE_FILE)
          or die "Failed to create ", CPU_STATS_STORAGE_FILE, "! $!\n";
        print $fh @stats;
        close $fh;
    }
    else
    {
        open($fh, '+<', CPU_STATS_STORAGE_FILE)
            or die "Failed to open ", CPU_STATS_STORAGE_FILE, "! $!\n";
        while (<$fh>)
        {
            @cpu_usage1 = ( $1, $2, $3, $4 )
                if /^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/i;
        }
        seek $fh, 0, 0;
        print $fh @stats;
        close $fh;

        my $delta =
            ($cpu_usage2[0] + $cpu_usage2[1] + $cpu_usage2[2] + $cpu_usage2[3]) -
            ($cpu_usage1[0] + $cpu_usage1[1] + $cpu_usage1[2] + $cpu_usage1[3]);
        my $cpu_usage =
            ($delta > 0) ?
            sprintf('%d', 100 - (($cpu_usage2[3] - $cpu_usage1[3]) / $delta * 100)) :
            0;

        $info{'cpu.usage'} = $cpu_usage;
    }
}



BEGIN { $ENV{'LC_ALL'} = 'POSIX'; }
hdd_usage;
hdd_temp;
mem_usage;
proc_loadavg;
proc_stat;
END
{
    my $out = '';
    $out .= "$_ ".$info{$_}."\n" foreach (sort keys(%info));
    print $out if length($out);
}
