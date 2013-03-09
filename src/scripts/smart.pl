#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-09 14:19:15Z
#
# $Id$
#

use strict;
use warnings;

my %info;
my @hdd;


sub init_hdd_list
{
    open(my $fh, '</proc/partitions')
        or die "Failed to open /proc/partitions! $!\n";
    while (<$fh>)
    {
        chomp;
        if (/^\s*(\d+)\s+(\d+)\s+(\d+)\s+([hs]d\D+)$/)
        {
            die "Could not find /dev/$4!" unless -e "/dev/$4";
            push @hdd, $4;
        }
    }
    close $fh;
}

sub smart_info
{
    my %monitored_ids = (
        1   => 1, # Raw Read Error Rate
        3   => 1, # Spin Up Time
        5   => 1, # Reallocated Sectors Count
        7   => 1, # Seek Error Rate
        8   => 1, # Seek Time Performance
        10  => 1, # Spin Retry Count
        190 => 1, # Airflow Temperature (Celsius)
        194 => 1, # HDD Temperature (Celsius)
        196 => 1, # Reallocation Event Count
        197 => 1, # Current Pending Sector Count
        198 => 1, # Off-Line Uncorrectable Sector Count
        199 => 1, # Ultra ATA CRC Error Count
        200 => 1, # Write Error Rate
        209 => 1, # Offline Seek Performance
    );

    foreach my $devname (@hdd)
    {
        my $cmd   = "smartctl -a /dev/$devname";
        my @lines = qx/$cmd/;
        my $code  = $? >> 8;
        die "Failed to run command '$cmd' (code $code)!"
            unless $code == 0;

        chomp(@lines);

        my $smart_available;
        my $smart_enabled;
        my $smart_other_errors = 0;
        my @smart_failures = ( );

        foreach (@lines)
        {
            if (/^SMART\s+support\s+is:\s+(A|E)(vailable|nabled)/i)
            {
                $smart_available = 1 if uc($1) eq 'A';
                $smart_enabled = 1 if uc($1) eq 'E';
                last if $smart_available and $smart_enabled;
            }
        }

        die "SMART is not available on /dev/$devname!\n"
            unless $smart_available;
        die "SMART is not enabled on /dev/$devname!\n"
            unless $smart_enabled;

        my $inside_attributes_list = 0;
        foreach my $line (@lines)
        {
            if (!$inside_attributes_list and $line =~ /^ID\#\s+ATTRIBUTE_NAME\s+FLAG\s+/i)
            {
                $inside_attributes_list = 1;
            }
            elsif ($inside_attributes_list)
            {
                if ($line eq '')
                {
                    $inside_attributes_list = 0;
                }
                elsif ($line =~ /^\s*(\d+)\s+([\w\-\_]+)\s+(0x[0-9a-f]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)(\s+.*)?$/)
                {
                    # SMART value
                    my ( $id, $when_failed, $raw_value ) =
                        ( int($1), $9, int($10) );

                    if ($id == 194)
                    {
                        # this value is already sent by usage.pl so just update it
                        # instead of creating a new dedicated 'smart' key
                        $info{"hdd.$devname.temp"} = $raw_value;
                    }
                    elsif (exists $monitored_ids{$id})
                    {
                        $info{"hdd.$devname.smart.$id.raw"} = $raw_value;
                        push @smart_failures, $id
                            if $when_failed ne '-';
                    }
                }
                else
                {
                    die "Unrecognized line format inside SMART attributes list (line: \"$line\")!";
                }
            }
            elsif ($line =~ /^Device\s+Model:\s+(\S+.*)$/i)
            {
                $info{"hdd.$devname.model"} = $1;
            }
            elsif ($line =~ /^Serial\s+Number:\s+(\S+.*)$/i)
            {
                $info{"hdd.$devname.serial"} = $1;
            }
            elsif ($line =~ /^Firmware\s+Version:\s+(\S+.*)$/i)
            {
                $info{"hdd.$devname.fwver"} = $1;
            }
            elsif ($line =~ /^User\s+Capacity:\s+([\d\,\.]+)\s+bytes$/i)
            {
                my $capacity = $1;
                $capacity =~ s%[\,\.]+%%g;
                $info{"hdd.$devname.capacity"} = $capacity;
            }
            elsif ($line =~ /Error \d+ (occurred )?at /)
            {
                ++$smart_other_errors;
            }
        }

        $info{"hdd.$devname.smart.failed"} = scalar @smart_failures;
        $info{"hdd.$devname.smart.failed"} .= ' '.join(' ', @smart_failures)
            if @smart_failures > 0;

        $info{"hdd.$devname.smart.other_errors"} = $smart_other_errors;
    }
}



BEGIN { $ENV{'LC_ALL'} = 'POSIX'; }
init_hdd_list;
smart_info;
END
{
    my $out = '';
    $out .= "$_ ".$info{$_}."\n" foreach (sort keys(%info));
    print $out if length($out);
}
