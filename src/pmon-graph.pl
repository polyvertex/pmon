#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-14 14:09:12Z
#
# $Id$
#

use strict;
use warnings;

use FindBin ();
use Cwd ();
use File::Basename ();
use List::Util ();
use Getopt::Long ();
use DBI;

use lib "$FindBin::RealBin";
use PMon::Config;


use constant
{
    MAX_CMDLINE_LENGTH => ($^O =~ /^MSWin/i) ? 8191 : 32767,

    # default paths
    DEFAULT_CONFIG_FILE => $FindBin::RealBin.'/../etc/pmon-daemon.conf',
    DEFAULT_RRD_DIR     => $FindBin::RealBin.'/../var/rrd',
    DEFAULT_HTDOCS_DIR  => $FindBin::RealBin.'/../var/htdocs',

    # enum: graphic definition types
    # * static: values are statically defined
    # * dynamic: values keys are defined using a regex to match available info
    #   keys from the database
    # * dynamic in one graphic: same as 'dynamic' but every 'vnames' matched by
    #   the regex will be rendered into a single graph (typically using a random
    #   color)
    GRAPHDEFINITION_STATIC           => 'static',
    GRAPHDEFINITION_DYNAMIC          => 'dynamic',
    GRAPHDEFINITION_DYNAMIC_ONEGRAPH => 'dynamic_onegraph',

    # enum: rrd profiles
    RRD_PROFILE_PERCENTAGE => 0,
    RRD_PROFILE_ABSVALUE   => 1,
    RRD_PROFILE_ABSCOUNTER => 2,
    RRD_PROFILE_VALUE      => 3,

    # enum: rra profiles
    RRA_PROFILE_MINUTE => 0, # value is updated every minutes
    RRA_PROFILE_HOUR   => 1, # value is updated every hours
};

use constant
{
    RRD_PROFILES => {
        RRD_PROFILE_PERCENTAGE() => 'DS:%s:GAUGE:%i:0:100',
        RRD_PROFILE_ABSVALUE()   => 'DS:%s:GAUGE:%i:0:U',
        RRD_PROFILE_ABSCOUNTER() => 'DS:%s:COUNTER:%i:0:U',
        RRD_PROFILE_VALUE()      => 'DS:%s:GAUGE:%i:U:U',
    },

    RRA_PROFILES => {
        RRA_PROFILE_MINUTE() => {           # if value is updated every minutes
            step        => 60,              # seconds
            heartbeat   => 90,              # seconds
            definitions => [
                'RRA:AVERAGE:0.5:1:1440',   # no avg, 24 hours of data
                'RRA:AVERAGE:0.5:10:1008',  # avg every 10 minutes, 7 days of data
                'RRA:AVERAGE:0.5:30:1440',  # avg every 30 minutes, 30 days of data
                'RRA:AVERAGE:0.5:360:1460', # avg every 6 hours, 365 days of data
                'RRA:MAX:0.5:1:1440',
                'RRA:MAX:0.5:10:1008',
                'RRA:MAX:0.5:30:1440',
                'RRA:MAX:0.5:360:1460',
                #'RRA:MIN:0.5:1:1440',
                #'RRA:MIN:0.5:10:1008',
                #'RRA:MIN:0.5:30:1440',
                #'RRA:MIN:0.5:360:1460',
            ],
        },
        RRA_PROFILE_HOUR() => {           # if value is updated every minutes
            step        => 3600,          # seconds
            heartbeat   => 3900,          # seconds
            definitions => [
                'RRA:AVERAGE:0.5:1:720',  # no avg, 30 days of data
                'RRA:AVERAGE:0.5:3:2920', # avg every 3 hours, 365 days of data
                'RRA:MAX:0.5:1:720',
                'RRA:MAX:0.5:3:2920',
                #'RRA:MIN:0.5:1:720',
                #'RRA:MIN:0.5:3:2920',
            ],
        },
    },

    PERIODS => {
        1 => {
            days         => 1,
            name         => 'day',
            label        => "Today",
            graph_width  => 450,
            graph_height => 180,
        },
        7 => {
            days         => 7,
            name         => 'week',
            label        => "Week",
            graph_width  => 450,
            graph_height => 180,
        },
        30 => {
            days         => 30,
            name         => 'month',
            label        => "Month",
            graph_width  => 900,
            graph_height => 150,
        },
        365 => {
            days         => 365,
            name         => 'year',
            label        => "Year",
            graph_width  => 900,
            graph_height => 150,
        },
    },
};



#-------------------------------------------------------------------------------
sub usage
{
    my $name = File::Basename::basename(__FILE__);
    my $default_config_file = DEFAULT_CONFIG_FILE;

  die <<USAGE;
Usage:
    $name [options]

Parameters:
    --help, -h
        Print this message and leave.
    --config={config_file}
        Specify the path of the daemon's configuration file. Defaults to:
        $default_config_file
    --graphdef={config_file}
        Specify the path of the graphics definitions file.
        Default configuration will be used if none specified.
    --reset
        Restart from scratch every needed RRD databases.
        Used for debugging purpose, you very probably do not need it.

USAGE
}

#-------------------------------------------------------------------------------
sub dbg_dump
{
    require Data::Dumper;
    warn Data::Dumper::Dumper(shift()), "\n";
}

#-------------------------------------------------------------------------------
sub path_title
{
    # returns the basename minux the suffixes
    # example: "/foo/bar/archive.tar.gz" -> "archive"
    my ($title) = File::Basename::fileparse(shift(), qr/\..*$/);
    return $title;
}

#-------------------------------------------------------------------------------
sub date_str
{
    my @t = localtime(shift() // time());
    #return sprintf
    #    '%04u-%02u-%02u %02u:%02u:%02u',
    #    $t[5] + 1900, $t[4] + 1, $t[3],
    #    $t[2], $t[1], $t[0];
    return sprintf
        '%04u-%02u-%02u',
        $t[5] + 1900, $t[4] + 1, $t[3];
}

#-------------------------------------------------------------------------------
sub cmdline_accumulate
{
    my ($ref_cmdline, $cmdline_prefix, $opt_cmdline_suffix, $args_to_append) = @_;

    if (defined $opt_cmdline_suffix)
    {
        $opt_cmdline_suffix = ' '.$opt_cmdline_suffix
            unless $opt_cmdline_suffix =~ /^\s/;
    }
    else
    {
        $opt_cmdline_suffix = '';
    }

    if (defined $$ref_cmdline)
    {
        if (!defined($args_to_append) or # flush
            length($$ref_cmdline) + length($args_to_append) + length($opt_cmdline_suffix) >= MAX_CMDLINE_LENGTH)
        {
            my $cmdline_start = join ' ', (split(/\s+/, $$ref_cmdline, 4))[0..2];
            $$ref_cmdline .= $opt_cmdline_suffix;

            #warn "Flush cmdline (len:", length($$ref_cmdline), "; start: $cmdline_start)\n";
            chomp(my @lines = qx/$$ref_cmdline/);
            die "Failed to run command line (cmdlen: ",
                length($$ref_cmdline), "; begin: $cmdline_start ...)! ",
                "Output:\n  ", join("\n  ", @lines), "\n"
                unless $? == 0;

            $$ref_cmdline = undef;
        }
    }

    if (defined $args_to_append)
    {
        $$ref_cmdline  = $cmdline_prefix unless defined $$ref_cmdline;
        $$ref_cmdline .= "$args_to_append ";
    }
}

#-------------------------------------------------------------------------------
sub rrd_str2name
{
    my $name = shift;
    $name =~ s%[^\w]%_%g;
    return $name;
}

#-------------------------------------------------------------------------------
sub rrd_file_path
{
    my ($dir, $machine_id, $name, $subname) = @_;

    die unless $machine_id =~ /^\d+$/;
    die unless $name       =~ /^[\w\-]+$/;
    die unless $subname    =~ /^[\w\-]+$/;

    return "$dir/rrd-$machine_id-$name-$subname.rrd";
}

#-------------------------------------------------------------------------------
#sub rrd_file_firstupdate
#{
#    my $rrd_file = shift;
#
#    my $cmd = qq{rrdtool first "$rrd_file" 2>&1};
#    chomp(my @lines = qx/$cmd/);
#    die "Failed to get first update from $rrd_file! Output:\n  ",
#        join("\n  ", @lines), "\n"
#        unless $? == 0 and @lines >= 1 and $lines[0] =~ /^\d+$/;
#
#    return int $lines[0];
#}

#-------------------------------------------------------------------------------
sub rrd_file_lastupdate
{
    my $rrd_file = shift;

    my $cmd = qq{rrdtool last "$rrd_file" 2>&1};
    chomp(my @lines = qx/$cmd/);
    die "Failed to get last update from $rrd_file! Output:\n  ",
        join("\n  ", @lines), "\n"
        unless $? == 0 and @lines >= 1 and $lines[0] =~ /^\d+$/;

    return int $lines[0];
}

#-------------------------------------------------------------------------------
sub rrd_file_update
{
    my ($rrd_file, $ds_name, $ref_cmdline, $args_to_append) = @_;
    my $cmdline_prefix = qq{rrdtool update "$rrd_file" -t "$ds_name" };
    my $cmdline_suffix = ' 2>&1';

    cmdline_accumulate
        $ref_cmdline, $cmdline_prefix, $cmdline_suffix, $args_to_append;
}

#-------------------------------------------------------------------------------
sub graphdef_template
{
    my ($ctx, $tmpl, $ref_color_roundrobin_idx, $ref_subst) = @_;

    return unless defined $tmpl;

    while ((my $idx = index($tmpl, '{DEVICE}')) >= $[)
    {
        die unless exists $ref_subst->{DEVICE};
        substr $tmpl, $idx, 8, $ref_subst->{DEVICE};
    }

    while ((my $idx = index($tmpl, '{RRDFILE}')) >= $[)
    {
        die unless exists $ref_subst->{RRDFILE};
        substr $tmpl, $idx, 9, $ref_subst->{RRDFILE};
    }

    while ($tmpl =~ /(\{RRDFILE\:([^\}]+)\})/)
    {
        my $match_str = $1;
        my $name      = $2;

        die unless exists $ref_subst->{rrd_files};
        die "RRD file not found \"$match_str\"!\n"
            unless exists $ref_subst->{rrd_files}{$name};

        while ((my $idx = index($tmpl, $match_str)) >= $[)
        {
            substr $tmpl, $idx, length($match_str),
                $ref_subst->{rrd_files}{$name}{file};
        }
    }

    while ($tmpl =~ /(\{HINT\:([^\}]+)\})/)
    {
        my $match_str = $1;
        my $name      = $2;

        die unless exists $ref_subst->{rrd_files};
        die "RRD file not found for hint \"$match_str\"!\n"
            unless exists $ref_subst->{rrd_files}{$name};
        die unless defined $ref_subst->{rrd_files}{$name}{hint};

        while ((my $idx = index($tmpl, $match_str)) >= $[)
        {
            substr $tmpl, $idx, length($match_str),
                $ref_subst->{rrd_files}{$name}{hint};
        }
    }

    while ((my $idx = index($tmpl, '{HINT}')) >= $[)
    {
        die unless exists $ref_subst->{DEVICE};
        substr $tmpl, $idx, 6, '{HINT:'.$ref_subst->{DEVICE}.'}';
    }

    while ($tmpl =~ /(\{COLOR\:([^\}]+)\})/)
    {
        my $match_str  = $1;
        my $color_name = $2;

        die "Unknown color \"$color_name\" found in graphic definition!\n"
            unless exists $ctx->{colors_byname}{$color_name};

        while ((my $idx = index($tmpl, $match_str)) >= $[)
        {
            substr $tmpl, $idx, length($match_str),
                $ctx->{colors_byname}{$color_name};
        }
    }

    while ((my $idx = index($tmpl, '{RRCOLOR}')) >= $[)
    {
        die unless defined $ref_color_roundrobin_idx;
        my $coloridx =
            ($$ref_color_roundrobin_idx)++ % scalar(@{$ctx->{colors_array}});
        substr $tmpl, $idx, 9, $ctx->{colors_array}[$coloridx];
    }

    return $tmpl;
}


#-------------------------------------------------------------------------------
sub db_available_keys
{
    my ($ctx, $machine_id, $history_start) = @_;

    my $available_dbkeys = $ctx->{dbh}->selectcol_arrayref(
        "SELECT la.key ".
        "FROM logatom AS la ".
        "WHERE la.machine_id = $machine_id ".
        "AND ( la.unix_first >= $history_start OR la.unix_last >= $history_start ) ".
        "AND ( la.unix_first <= $ctx->{now} OR la.unix_last <= $ctx->{now} ) ".
        "GROUP BY la.key ".
        "ORDER BY la.id ASC ",
        { Columns => [ 1 ] });
    #warn "INFO KEYS for machine $machine_id (", scalar(@$available_dbkeys), "):\n", join(', ', sort(@$available_dbkeys)), "\n";

    return $available_dbkeys;
}

#-------------------------------------------------------------------------------
sub db2rrd
{
    my ($ctx, $machine_id, $ref_rrd_files, $ref_available_dbkeys) = @_;

    # check if we've got all the info keys necessary to build this graph
    foreach (sort keys(%$ref_rrd_files))
    {
        return unless $ref_rrd_files->{$_}{dbkey} ~~ @$ref_available_dbkeys;
    }

    # fetch the hint value if necessary
    foreach my $rrd_name (sort keys(%$ref_rrd_files))
    {
        my $ref_rrd = $ref_rrd_files->{$rrd_name};

        next unless defined $ref_rrd->{hintkey};

        my $rows = $ctx->{dbh}->selectcol_arrayref(
            "SELECT la.value ".
            "FROM logatom AS la ".
            "WHERE machine_id = $machine_id ".
            "AND la.key = ".$ctx->{dbh}->quote($ref_rrd->{hintkey})." ".
            "ORDER BY la.id DESC ".
            "LIMIT 1",
            { Columns => [ 1 ] });

        $ref_rrd->{hint} = (defined($rows) and @$rows > 0) ? $rows->[0] : '';

        warn "Could not find hint key \"", $ref_rrd->{hintkey},
            "\" into DB (machine $machine_id; graph $rrd_name)!\n"
            unless defined($rows) and @$rows > 0;
    }

    # create and/or update rrd files
    foreach my $rrd_name (sort keys(%$ref_rrd_files))
    {
        my $ref_rrd = $ref_rrd_files->{$rrd_name};

        # delete existing rrd file if required
        unlink($ref_rrd->{file})
            if $ctx->{reset_rrd} and -e $ref_rrd->{file};

        # create rrd file or just update it?
        unless (-e $ref_rrd->{file})
        {
            my $cmd =
                'rrdtool create "'.$ref_rrd->{file}.'" '.
                '--start '.($ref_rrd->{start} - 1).' '.
                '--step '.$ref_rrd->{step}.' '.
                $ref_rrd->{ds}.' ';
            $cmd .= "$_ " foreach (@{$ref_rrd->{rras}});
            $cmd .= '2>&1';
            chomp(my @lines = qx/$cmd/);
            die "Failed to create $ref_rrd->{file}! Command:\n  ",
                "$cmd\nOutput:\n  ", join("\n  ", @lines), "\n"
                unless $? == 0;
        }
        else
        {
            # the file exists so get the last update timestamp to know
            # from when we have to update it
            $ref_rrd->{start} = 1 + rrd_file_lastupdate($ref_rrd->{file});
        }

        # fetch just enough data from the database and update the rrd file
        {
            my @columns = qw( id unix_first unix_last value );
            my $sth = $ctx->{dbh}->prepare(
                "SELECT la.id, la.unix_first, la.unix_last, la.value ".
                "FROM logatom AS la ".
                "WHERE la.machine_id = $machine_id ".
                "AND ( la.unix_first >= $ref_rrd->{start} OR la.unix_last >= $ref_rrd->{start} ) ".
                "AND la.unix_first <= $ctx->{now} ".
                "AND la.key = ? ".
                "ORDER BY la.id ASC ")
                or die $ctx->{dbh}->errstr;
            my $rows;
            my $cmdline;
            my $ref_lastrow;

            $sth->bind_param(1, $ref_rrd->{dbkey});
            $sth->execute or die $ctx->{dbh}->errstr;

            while (1)
            {
                $rows = $sth->fetchall_arrayref(undef, $ctx->{db_maxrows});
                last
                    unless (defined($rows) and @$rows > 0)
                    or defined $ref_lastrow;

                if (defined $ref_lastrow)
                {
                    $rows = [ ] unless defined $rows;
                    unshift @$rows, $ref_lastrow;
                    $ref_lastrow = undef;
                }
                die if scalar(@columns) != scalar(@{$rows->[0]});

                # is it the very last row from this request?
                if (@$rows == 1)
                {
                    my %curr = map { $columns[$_] => $rows->[0][$_] } 0..$#columns;

                    $ref_rrd->{start} = $curr{unix_first}
                        if $ref_rrd->{start} < $curr{unix_first};

                    while ($ref_rrd->{start} < $curr{unix_last}
                        and $ref_rrd->{start} < $ctx->{now})
                    {
                        rrd_file_update $ref_rrd->{file}, $rrd_name, \$cmdline,
                            $ref_rrd->{start}.':'.$curr{value};
                        $ref_rrd->{start} += $ref_rrd->{step};
                    }

                    $ref_rrd->{start} =
                        ($curr{unix_last} < $ctx->{now}) ?
                        $curr{unix_last} :
                        $ctx->{now};
                }
                else
                {
                    while (@$rows >= 2)
                    {
                        my %curr = map { $columns[$_] => $rows->[0][$_] } 0..$#columns;
                        my %next = map { $columns[$_] => $rows->[1][$_] } 0..$#columns;
                        shift @$rows;

                        next if $curr{unix_first} >= $next{unix_first}
                            or $ref_rrd->{start} >= $next{unix_first};

                        $ref_rrd->{start} = $curr{unix_first}
                            if $ref_rrd->{start} < $curr{unix_first};

                        while ($ref_rrd->{start} < $next{unix_first})
                        {
                            rrd_file_update $ref_rrd->{file}, $rrd_name, \$cmdline,
                                $ref_rrd->{start}.':'.$curr{value};
                            $ref_rrd->{start} += $ref_rrd->{step};
                        }

                        $ref_rrd->{start} = $next{unix_first};
                    }

                    die unless @$rows == 0 or @$rows == 1;
                    $ref_lastrow = (@$rows > 0) ? $rows->[0] : undef;
                }
            }

            # flush data remained in the command line
            rrd_file_update $ref_rrd->{file}, $rrd_name, \$cmdline, undef, 0;
        }
    }
}



#-------------------------------------------------------------------------------
sub generate_graphic_static
{
    my ($ctx, $machine_id, $ref_graphdef, $available_dbkeys) = @_;
    my $max_days      = List::Util::max(@{$ref_graphdef->{periods}});
    my $history_start = $ctx->{now} - ($max_days * 86400);
    my %rrd_files;

    # list all the info keys available within the desired period
    $available_dbkeys = db_available_keys($ctx, $machine_id, $history_start)
        unless defined $available_dbkeys;

    # in order to be able to generate graphics, we first need to create rrd
    # files and we must ensure we have all the required data into the database.
    foreach my $ref_rrd_value (@{$ref_graphdef->{values}})
    {
        my $rrd_name    = $ref_rrd_value->{name};
        my $rrd_file    = rrd_file_path $ctx->{dir_rrd}, $machine_id, $ref_graphdef->{name}, $rrd_name;
        my $rra_profile = RRA_PROFILES()->{$ref_rrd_value->{rra_profile}};
        my $rrd_ds      = sprintf
            RRD_PROFILES()->{$ref_rrd_value->{rrd_profile}},
            $rrd_name, $rra_profile->{heartbeat};

        $rrd_files{$rrd_name} = {
            file    => $rrd_file,
            dbkey   => $ref_rrd_value->{dbkey},
            hintkey => $ref_rrd_value->{dbhint},
            hint    => undef,
            step    => $rra_profile->{step},
            ds      => $rrd_ds,
            rras    => $rra_profile->{definitions},
            start   => $history_start,
        };
    }
    db2rrd $ctx, $machine_id, \%rrd_files, $available_dbkeys;

    # do not render graphics if at least one of the rrd files is not up-to-date
    foreach (sort keys(%rrd_files))
    {
        my $f = $rrd_files{$_}{file};
        return unless -e $f and rrd_file_lastupdate($f) > $history_start;
    }

    # create graph for each period
    foreach my $days (@{$ref_graphdef->{periods}})
    {
        $ref_graphdef->{graph_name} = $ref_graphdef->{name}
            unless defined $ref_graphdef->{graph_name};

        my $ref_period  = PERIODS()->{$days};
        my $graph_file  = $ctx->{dir_htdocs}."/graph-$machine_id-$ref_graphdef->{graph_name}-$ref_period->{name}.png";
        my $graph_title = sprintf '%s / %s / %s (%s)',
            $ctx->{machines}{$machine_id}{name}, $ref_graphdef->{label},
            $ctx->{today_str}, $ref_period->{label};
        my $color_roundrobin_idx = 0;

        my $cmd =
            "rrdtool graph \"$graph_file\" ".
            "--start ".($ctx->{now} - ($days * 86400))." ".
            "--end $ctx->{now} ".
            "--title \"$graph_title\" ".
            "--width $ref_period->{graph_width} ".
            "--height $ref_period->{graph_height} ".
            "--full-size-mode ";

        $cmd .= /^([^\s]+)\s(.*)$/ ? "$1 \"$2\" " : "$_ "
            foreach (@{$ref_graphdef->{rrd_graph_options}});

        foreach my $arg (@{$ref_graphdef->{rrd_graph_def}}, @{$ref_graphdef->{rrd_graph_draw}})
        {
            $arg = graphdef_template $ctx, $arg, \$color_roundrobin_idx,
                { rrd_files => \%rrd_files };
            $cmd .= "\"$arg\" ";
        }

        chomp(my @lines = qx/$cmd 2>&1/);
        die "Failed to generate $graph_file! Command: $cmd\n",
            "Output:\n  ", join("\n  ", @lines), "\n"
            unless $? == 0;

        # register this new graphic into the database
        $ctx->{dbh}->do(
            "INSERT INTO graph ".
            "(uniqname, machine_id, unix, days, defname, graphname, title, file) ".
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            undef,
            path_title($graph_file), $machine_id, $ctx->{now}, $days,
            $ref_graphdef->{name}, $ref_graphdef->{graph_name},
            $ref_graphdef->{label}, Cwd::realpath($graph_file))
            or die $ctx->{dbh}->errstr;
    }
}

#-------------------------------------------------------------------------------
sub generate_graphic_dynamic
{
    my ($ctx, $machine_id, $ref_graphdef, $available_dbkeys) = @_;
    my $max_days      = List::Util::max(@{$ref_graphdef->{periods}});
    my $history_start = $ctx->{now} - ($max_days * 86400);
    my @devices;

    # list all the info keys available within the desired period
    $available_dbkeys = db_available_keys($ctx, $machine_id, $history_start)
        unless defined $available_dbkeys;

    # list available devices
    {
        # perl rulez!
        my $regex   = $ref_graphdef->{vname};
        my %matches = map { /$regex/; $1 => 1 } grep(/$regex/, @$available_dbkeys);
        @devices    = sort keys(%matches);
    }

    # generate the desired graph for each device found
    foreach my $device (@devices)
    {
        my $color_roundrobin_idx = 0;
        my %static_graphdef = (
            name              => $ref_graphdef->{name},
            graph_name        => $ref_graphdef->{name}.'-'.$device,
            type              => GRAPHDEFINITION_STATIC,
            periods           => [ @{$ref_graphdef->{periods}} ],
            label             => graphdef_template($ctx, $ref_graphdef->{label}, undef, { DEVICE => $device }),
            values            => [ ],
            rrd_graph_options => [ @{$ref_graphdef->{rrd_graph_options}} ],
            rrd_graph_def     => [ @{$ref_graphdef->{rrd_graph_def}} ],
            rrd_graph_draw    => [ @{$ref_graphdef->{rrd_graph_draw}} ],
        );

        foreach my $ref_valdef (@{$ref_graphdef->{values}})
        {
            my $ref_static_valdef = {
                rrd_profile => $ref_valdef->{rrd_profile},
                rra_profile => $ref_valdef->{rra_profile},
            };
            my $rrd_file;

            foreach my $k (qw( name dbkey dbhint ))
            {
                $ref_static_valdef->{$k} = graphdef_template
                    $ctx, $ref_valdef->{$k}, \$color_roundrobin_idx,
                    { DEVICE => $device };
            }
            $rrd_file = rrd_file_path $ctx->{dir_rrd}, $machine_id, $ref_graphdef->{name}, $ref_static_valdef->{name};

            my %hmap = (
                rrg_def  => 'rrd_graph_def',
                rrg_draw => 'rrd_graph_draw',
            );
            while (my ($srck, $dstk) = each %hmap)
            {
                foreach my $def (@{$ref_valdef->{$srck}})
                {
                    push @{$static_graphdef{$dstk}}, graphdef_template(
                        $ctx, $def, \$color_roundrobin_idx, {
                            DEVICE  => $device,
                            RRDFILE => $rrd_file,
                        });
                }
            }

            push @{$static_graphdef{values}}, $ref_static_valdef;
        }

        generate_graphic_static $ctx, $machine_id, \%static_graphdef, $available_dbkeys;
    }
}

#-------------------------------------------------------------------------------
sub generate_graphic_dynamic_onegraph
{
    my ($ctx, $machine_id, $ref_graphdef, $available_dbkeys) = @_;
    my $max_days      = List::Util::max(@{$ref_graphdef->{periods}});
    my $history_start = $ctx->{now} - ($max_days * 86400);
    my @devices;
    my %static_graphdef;
    my $color_roundrobin_idx = 0;

    # list all the info keys available within the desired period
    $available_dbkeys = db_available_keys($ctx, $machine_id, $history_start)
        unless defined $available_dbkeys;

    # list available devices
    {
        # perl rulez!
        my $regex   = $ref_graphdef->{vname};
        my %matches = map { /$regex/; $1 => 1 } grep(/$regex/, @$available_dbkeys);
        @devices    = sort keys(%matches);
    }

    # prepare the static definition to generate only one graphic for every devices
    %static_graphdef = (
        name              => $ref_graphdef->{name},
        type              => GRAPHDEFINITION_STATIC,
        periods           => [ @{$ref_graphdef->{periods}} ],
        label             => $ref_graphdef->{label},
        values            => [ ],
        rrd_graph_options => [ @{$ref_graphdef->{rrd_graph_options}} ],
        rrd_graph_def     => [ @{$ref_graphdef->{rrd_graph_def}} ],
        rrd_graph_draw    => [ @{$ref_graphdef->{rrd_graph_draw}} ],
    );
    foreach my $device (@devices)
    {
        foreach my $ref_valdef (@{$ref_graphdef->{values}})
        {
            my $ref_static_valdef = {
                rrd_profile => $ref_valdef->{rrd_profile},
                rra_profile => $ref_valdef->{rra_profile},
            };
            my $rrd_file;

            foreach my $k (qw( name dbkey dbhint ))
            {
                $ref_static_valdef->{$k} = graphdef_template
                    $ctx, $ref_valdef->{$k}, \$color_roundrobin_idx,
                    { DEVICE => $device };
            }
            $rrd_file = rrd_file_path $ctx->{dir_rrd}, $machine_id, $ref_graphdef->{name}, $ref_static_valdef->{name};

            my %hmap = (
                rrg_def  => 'rrd_graph_def',
                rrg_draw => 'rrd_graph_draw',
            );
            while (my ($srck, $dstk) = each %hmap)
            {
                foreach my $def (@{$ref_valdef->{$srck}})
                {
                    push @{$static_graphdef{$dstk}}, graphdef_template(
                        $ctx, $def, \$color_roundrobin_idx, {
                            DEVICE  => $device,
                            RRDFILE => $rrd_file,
                        });
                }
            }

            push @{$static_graphdef{values}}, $ref_static_valdef;
        }
    }

    generate_graphic_static $ctx, $machine_id, \%static_graphdef, $available_dbkeys;
}



#-------------------------------------------------------------------------------
sub generate_machine_graphics
{
    my ($ctx, $machine_id) = @_;

    foreach my $ref_graphdef (@{$ctx->{graphdef}{GRAPHICS}})
    {
        my $func_gengraph = main->can('generate_graphic_'.$ref_graphdef->{type});
        die unless defined $func_gengraph;
        $func_gengraph->($ctx, $machine_id, $ref_graphdef);
    }
}

#-------------------------------------------------------------------------------
my %ctx = ( # global context
    help         => undef,
    configfile   => DEFAULT_CONFIG_FILE,
    graphdeffile => undef,
    reset_rrd    => undef,

    db_source  => undef,
    db_user    => undef,
    db_pass    => undef,
    db_maxrows => 10_000, # max number of rows fetched at time

    dir_rrd    => DEFAULT_RRD_DIR,
    dir_htdocs => DEFAULT_HTDOCS_DIR,

    now       => time,
    today_str => undef,
    dbh       => undef,
    machines  => { },

    graphdef      => { },
    colors_byname => { },
    colors_array  => [ ],
);
my $res;

BEGIN { $| = 1; }

$ctx{today_str} = date_str $ctx{now};

# parse parameters
$res = Getopt::Long::GetOptions(
    'help|h|?'   => \$ctx{help},
    'config=s'   => \$ctx{configfile},
    'graphdef=s' => \$ctx{graphdeffile},
    'reset'      => \$ctx{reset_rrd},
);
usage unless $res and not $ctx{help};
delete $ctx{help};

# read config file
{
    my $oconf = PMon::Config->new(
        file   => $ctx{configfile},
        strict => 1,
        subst  => { '{BASEDIR}' => $FindBin::RealBin.'/..', },
    );

    $ctx{db_source}  = $oconf->get_str('db_source');
    $ctx{db_user}    = $oconf->get_str('db_user');
    $ctx{db_pass}    = $oconf->get_str('db_pass');
    $ctx{dir_rrd}    = $oconf->get_subst_str('dir_rrd', DEFAULT_RRD_DIR);
    $ctx{dir_htdocs} = $oconf->get_subst_str('dir_htdocs', DEFAULT_HTDOCS_DIR);
    die "Please check database access credentials in ", $ctx{configfile}, "!\n"
        unless defined($ctx{db_source})
        and defined($ctx{db_user})
        and defined($ctx{db_pass});
}

# load graphics definitions
if (defined $ctx{graphdeffile})
{
    no strict 'refs';

    die "Graphics definitions file is not readable \"$ctx{graphdeffile}\"!\n"
      unless -r $ctx{graphdeffile} and -f $ctx{graphdeffile};

    eval "require '$ctx{graphdeffile}';";
    $@ and $_=$@, s/Compilation failed.*//s, die $_;

    die "Invalid graphics definitions file \"$ctx{graphdeffile}\"!"
      unless keys(%{__PACKAGE__.'::USER_GRAPHICS_DEFINITIONS'}) > 0;

    $ctx{graphdef} = { %{__PACKAGE__.'::USER_GRAPHICS_DEFINITIONS'} };

    # 'unload' module
    %{__PACKAGE__.'::USER_GRAPHICS_DEFINITIONS'} = ( );
    delete $INC{$ctx{graphdeffile}};
}
else
{
    no strict 'refs';

    eval "require PMon::GraphDefConf;";
    die $@ if $@;
    $ctx{graphdef} = { %{__PACKAGE__.'::USER_GRAPHICS_DEFINITIONS'} };

    %{__PACKAGE__.'::USER_GRAPHICS_DEFINITIONS'} = ( );
    delete $INC{'PMon/GraphDefConf.pm'};
}

# populate colors hash and array
# * we will need to access color values by name, but also by index (RRCOLOR).
# * because of this, it is important to keep track of the order the colors have
#   been defined by the user. we cannot do that using only a hash since keys'
#   ordering is unpredictible.
# * this is why $ctx{graphdef}{COLORS} is a reference to an ARRAY, but has been
#   defined like a HASH (key=>value pairs).
$ctx{colors_byname} = { @{$ctx{graphdef}{COLORS}} };
for ($res = 1; $res < scalar(@{$ctx{graphdef}{COLORS}}); $res += 2)
{
    push @{$ctx{colors_array}}, $ctx{graphdef}{COLORS}[$res];
}
delete $ctx{graphdef}{COLORS}; # we have our own hash and array, we don't need this anymore

# connect to database
$ctx{dbh} = DBI->connect(
    $ctx{db_source}, $ctx{db_user}, $ctx{db_pass}, {
        AutoCommit => 1,
        RaiseError => 1,
        PrintWarn  => 1,
        PrintError => 0,
    } );
die "Failed to connect DBI (", $DBI::err, ")! ", $DBI::errstr, "\n"
    unless defined $ctx{dbh};

# list machines
$ctx{machines} = $ctx{dbh}->selectall_hashref(
    'SELECT id, name, unix, uptime FROM machine', 'id');
die "No machine found in DB!\n" unless keys(%{$ctx{machines}}) > 0;

# delete all graphics references from the database
$ctx{dbh}->do('TRUNCATE TABLE graph') or die $ctx{dbh}->errstr;

# generate as much graphs as we can for every machines
generate_machine_graphics(\%ctx, $_)
    foreach (sort keys(%{$ctx{machines}}));

# free and quit
$ctx{dbh}->disconnect;
exit 0;
