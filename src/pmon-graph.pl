#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-14 14:09:12Z
#
# $Id$
#

use strict;
use warnings;

use File::Basename ();
use Getopt::Long ();
use DBI;

# declare our own local "lib" directory
my $MY_DIR;
BEGIN
{
    $MY_DIR = (__FILE__ =~ /(.*)[\\\/]/) ? $1 : '.';
    unshift @INC, $MY_DIR;
}

use PMon::Config;


use constant
{
    # default paths
    DEFAULT_CONFIG_FILE => $MY_DIR.'/../etc/pmond.conf',
    DEFAULT_RRD_DIR     => $MY_DIR.'/../var',
    DEFAULT_HTDOCS_DIR  => $MY_DIR.'/../var/htdocs',

    MAX_CMDLINE_LENGTH => ($^O =~ /^MSWin/i) ? 8191 : 32768,
};

my %RRD_TEMPLATES = (
    percentage_per_minute => {
        step  => 60,
        dsfmt => 'DS:%s:GAUGE:100:0:100',
        rra   => [
            'RRA:AVERAGE:0.5:1:1440',   # no avg, 24 hours of data
            'RRA:AVERAGE:0.5:10:1008',  # avg every 10 minutes, 7 days of data
            'RRA:AVERAGE:0.5:30:1440',  # avg every 30 minutes, 30 days of data
            'RRA:AVERAGE:0.5:360:1460', # avg every 6 hours, 365 days of data
        ],
    },
    absvalue_per_minute => {
        step  => 60,
        dsfmt => 'DS:%s:GAUGE:100:0:U',
        rra   => [
            'RRA:AVERAGE:0.5:1:1440',   # no avg, 24 hours of data
            'RRA:AVERAGE:0.5:10:1008',  # avg every 10 minutes, 7 days of data
            'RRA:AVERAGE:0.5:30:1440',  # avg every 30 minutes, 30 days of data
            'RRA:AVERAGE:0.5:360:1460', # avg every 6 hours, 365 days of data
        ],
    },
    abscounter_per_minute => {
        step  => 60,
        dsfmt => 'DS:%s:COUNTER:100:0:U',
        rra   => [
            'RRA:AVERAGE:0.5:1:1440',   # no avg, 24 hours of data
            'RRA:AVERAGE:0.5:10:1008',  # avg every 10 minutes, 7 days of data
            'RRA:AVERAGE:0.5:30:1440',  # avg every 30 minutes, 30 days of data
            'RRA:AVERAGE:0.5:360:1460', # avg every 6 hours, 365 days of data
        ],
    },
    abscounter_per_hour => {
        step  => 3600,
        dsfmt => 'DS:%s:COUNTER:3900:0:U',
        rra   => [
            'RRA:AVERAGE:0.5:1:720',  # no avg, 30 days of data
            'RRA:AVERAGE:0.5:3:2920', # avg every 3 hours, 365 days of data
        ],
    },
);


#-------------------------------------------------------------------------------
sub usage
{
    my $name = File::Basename::basename($0);
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

USAGE
}

#-------------------------------------------------------------------------------
sub dbg_dump
{
    require Data::Dumper;
    warn Data::Dumper::Dumper(shift()), "\n";
}

#-------------------------------------------------------------------------------
sub today_str
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
sub rrd_build_path
{
    my ($dir, $machine_id, $rrd_name, $opt_rrd_subname) = @_;

    die unless $machine_id =~ /^\d+$/;
    die unless $rrd_name =~ /^[\w\_]+$/;

    if (defined $opt_rrd_subname)
    {
        $opt_rrd_subname = undef
            unless length($opt_rrd_subname) > 0;
        $opt_rrd_subname =~ s%[^\w\_]%_%g
            if defined $opt_rrd_subname;
    }

    my $file = "$dir/rrd-$machine_id-$rrd_name";
    $file .= '-'.$opt_rrd_subname if defined $opt_rrd_subname;
    $file .= '.rrd';

    return $file;
}

#-------------------------------------------------------------------------------
sub rrd_update_cmd
{
    my ($rrd_file, $ds_name, $ref_cmdline, $args_to_append) = @_;
    my $cmdline_prefix = qq{rrdtool update "$rrd_file" -t "$ds_name" };
    my $cmdline_suffix = ' 2>&1';

    cmdline_accumulate
        $ref_cmdline, $cmdline_prefix, $cmdline_suffix, $args_to_append;
}

#-------------------------------------------------------------------------------
sub rrd_create_and_update
{
    my ($ctx, $ref_available_info_keys, $machine_id, $ref_infokeys2rrd) = @_;

    # check if we've got all the info keys necessary to build this graph
    foreach my $required_key (sort keys(%$ref_infokeys2rrd))
    {
        unless ($required_key ~~ @$ref_available_info_keys)
        {
            # here, the database does not have all the values we need...
            foreach (sort keys(%$ref_infokeys2rrd))
            {
                unlink($ref_infokeys2rrd->{$_}{rrd_file})
                    if -e $ref_infokeys2rrd->{$_}{rrd_file};
            }
            # TODO: delete graph files
            return;
        }
    }

    # build/update rrd files
    foreach my $info_key (sort keys(%$ref_infokeys2rrd))
    {
        my $ref_key2rrd = $ref_infokeys2rrd->{$info_key};
        my $rrd_name    = $ref_key2rrd->{rrd_name};
        my $rrd_file    = $ref_key2rrd->{rrd_file};
        my $rrd_step    = $ref_key2rrd->{rrd_tmpl}{step};

        # create rrd file or just update it?
        unless (-e $rrd_file)
        {
            my $cmd =
                'rrdtool create "'.$rrd_file.'" '.
                '--start '.$ref_key2rrd->{rrd_start}.' '.
                '--step '.$rrd_step.' ';
            $cmd .= sprintf
                $ref_key2rrd->{rrd_tmpl}{dsfmt}.' ',
                $ref_key2rrd->{rrd_name};
            $cmd .= "$_ "
                foreach (@{$ref_key2rrd->{rrd_tmpl}{rra}});
            $cmd .= '2>&1';
            chomp(my @lines = qx/$cmd/);
            die "Failed to create $rrd_file! Command:\n  ",
                "$cmd\nOutput:\n  ", join("\n  ", @lines), "\n"
                unless $? == 0;
        }
        else
        {
            # the file exists so get the last update timestamp to know
            # from when we have to update it
            my $cmd = qq{rrdtool last "$rrd_file" 2>&1};
            chomp(my @lines = qx/$cmd/);
            die "Failed to get last update from $rrd_file! Output:\n  ",
                join("\n  ", @lines), "\n"
                unless $? == 0 and @lines >= 1 and $lines[0] =~ /^\d+$/;
            $ref_key2rrd->{rrd_start} = 1 + $lines[0];
        }

        # fetch just enough data from the database and update the rrd file
        {
            my @columns = qw( id unix_first unix_last value );
            my $sth = $ctx->{dbh}->prepare(
                "SELECT la.id, la.unix_first, la.unix_last, la.value ".
                "FROM logatom AS la ".
                "WHERE la.machine_id = $machine_id ".
                "AND ( la.unix_first >= $ref_key2rrd->{rrd_start} OR la.unix_last >= $ref_key2rrd->{rrd_start} ) ".
                "AND ( la.unix_first <= $ctx->{now} OR la.unix_last <= $ctx->{now} ) ".
                "AND la.key = ? ".
                "ORDER BY la.id ASC ")
                or die $ctx->{dbh}->errstr;
            my $rows;
            my $cmdline;
            my $ref_lastrow;

            $sth->bind_param(1, $info_key);
            $sth->execute or die $sth->errstr;

            while (1)
            {
                $rows = $sth->fetchall_arrayref(undef, $ctx->{db_maxrows});
                last
                    unless (defined($rows) and @$rows > 0)
                    or defined $ref_lastrow;

                if (defined $ref_lastrow)
                {
                    unshift @$rows, $ref_lastrow;
                    $ref_lastrow = undef;
                }
                die if scalar(@columns) != scalar(@{$rows->[0]});

                # is it the very last row we will have to deal with from this request?
                if (@$rows == 1)
                {
                    my %curr = map { $columns[$_] => $rows->[0][$_] } 0..$#columns;

                    $ref_key2rrd->{rrd_start} = $curr{unix_first}
                        if $ref_key2rrd->{rrd_start} < $curr{unix_first};

                    while ($ref_key2rrd->{rrd_start} < $curr{unix_last}
                        and $ref_key2rrd->{rrd_start} < $ctx->{now})
                    {
                        rrd_update_cmd $rrd_file, $rrd_name, \$cmdline,
                            $ref_key2rrd->{rrd_start}.':'.$curr{value};
                        $ref_key2rrd->{rrd_start} += $rrd_step;
                    }

                    $ref_key2rrd->{rrd_start} =
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
                            or $ref_key2rrd->{rrd_start} >= $next{unix_first};

                        $ref_key2rrd->{rrd_start} = $curr{unix_first}
                            if $ref_key2rrd->{rrd_start} < $curr{unix_first};

                        while ($ref_key2rrd->{rrd_start} < $next{unix_first})
                        {
                            rrd_update_cmd $rrd_file, $rrd_name, \$cmdline,
                                $ref_key2rrd->{rrd_start}.':'.$curr{value};
                            $ref_key2rrd->{rrd_start} += $rrd_step;
                        }

                        $ref_key2rrd->{rrd_start} = $next{unix_first};
                    }

                    $ref_lastrow = (@$rows > 0) ? $rows->[0] : undef;
                }
            }

            # flush data remained in the command line
            rrd_update_cmd $rrd_file, $rrd_name, \$cmdline, undef, 0;
        }
    }
}



#-------------------------------------------------------------------------------
sub graph_usage
{
    my ($ctx, $ref_available_info_keys, $machine_id, $history_start, $ref_periods) = @_;
    my $graph_name    = 'usage';
    my $graph_title   = 'Usage';
    my $rrd_file_cpu  = rrd_build_path $ctx->{dir_rrd}, $machine_id, 'cpu';
    my $rrd_file_mem  = rrd_build_path $ctx->{dir_rrd}, $machine_id, 'mem';
    my $rrd_file_swap = rrd_build_path $ctx->{dir_rrd}, $machine_id, 'swap';
    my %infokeys2rrd = (
        'cpu.usage' => {
            rrd_name  => 'cpu',
            rrd_file  => $rrd_file_cpu,
            rrd_tmpl  => $RRD_TEMPLATES{percentage_per_minute},
            rrd_start => $history_start,
        },
        'mem.usage' => {
            rrd_name  => 'mem',
            rrd_file  => $rrd_file_mem,
            rrd_tmpl  => $RRD_TEMPLATES{percentage_per_minute},
            rrd_start => $history_start,
        },
        'swap.usage' => {
            rrd_name  => 'swap',
            rrd_file  => $rrd_file_swap,
            rrd_tmpl  => $RRD_TEMPLATES{percentage_per_minute},
            rrd_start => $history_start,
        },
    );

    # create and/or update all the necessary rrd file(s)
    rrd_create_and_update $ctx, $ref_available_info_keys, $machine_id, \%infokeys2rrd;

    # create graph for each period
    foreach my $ref_period (@$ref_periods)
    {
        my $file  = $ctx->{dir_htdocs}."/graph-$machine_id-$graph_name-$ref_period->{name}.png";
        my $title = "$graph_title / $ref_period->{title}";

        my $cmd =
            "rrdtool graph \"$file\" ".
            "--start now-".$ref_period->{days}."d ".
            "--end now ".
            "--title \"$title\" ".
            "--vertical-label \"usage\" ".
            "--width ".$ref_period->{graph_width}." ".
            "--height ".$ref_period->{graph_height}." ".
            "--lower-limit 0 ".
            "--upper-limit 100 ".
            #"--rigid ".
            "--units-exponent 0 ".
            "\"DEF:mem=$rrd_file_mem:mem:AVERAGE\" ".
            "\"DEF:swap=$rrd_file_swap:swap:AVERAGE\" ".
            "\"DEF:cpu=$rrd_file_cpu:cpu:AVERAGE\" ".
            "\"AREA:mem#00FFFF:Memory\" ".
            "\"LINE1:swap#00A0FF:Swap\" ".
            "\"LINE1:cpu#DC2F2F:CPU\" ";
        chomp(my @lines = qx/$cmd 2>&1/);
        die "Failed to generate $file! Command: $cmd\n",
            "Output:\n  ", join("\n  ", @lines), "\n"
            unless $? == 0;
    }
}

#-------------------------------------------------------------------------------
sub graph_load
{
    my ($ctx, $ref_available_info_keys, $machine_id, $history_start, $ref_periods) = @_;
    my $graph_name         = 'load';
    my $graph_title        = 'Load';
    my $rrd_file_loadavg1  = rrd_build_path $ctx->{dir_rrd}, $machine_id, 'loadavg1';
    my $rrd_file_loadavg5  = rrd_build_path $ctx->{dir_rrd}, $machine_id, 'loadavg5';
    my $rrd_file_loadavg15 = rrd_build_path $ctx->{dir_rrd}, $machine_id, 'loadavg15';
    my %infokeys2rrd = (
        'ps.loadavg1' => {
            rrd_name  => 'loadavg1',
            rrd_file  => $rrd_file_loadavg1,
            rrd_tmpl  => $RRD_TEMPLATES{absvalue_per_minute},
            rrd_start => $history_start,
        },
        'ps.loadavg5' => {
            rrd_name  => 'loadavg5',
            rrd_file  => $rrd_file_loadavg5,
            rrd_tmpl  => $RRD_TEMPLATES{absvalue_per_minute},
            rrd_start => $history_start,
        },
        'ps.loadavg15' => {
            rrd_name  => 'loadavg15',
            rrd_file  => $rrd_file_loadavg15,
            rrd_tmpl  => $RRD_TEMPLATES{absvalue_per_minute},
            rrd_start => $history_start,
        },
    );

    # create and/or update all the necessary rrd file(s)
    rrd_create_and_update $ctx, $ref_available_info_keys, $machine_id, \%infokeys2rrd;

    # create graph for each period
    foreach my $ref_period (@$ref_periods)
    {
        my $file  = $ctx->{dir_htdocs}."/graph-$machine_id-$graph_name-$ref_period->{name}.png";
        my $title = "$graph_title / $ref_period->{title}";

        my $cmd =
            "rrdtool graph \"$file\" ".
            "--start now-".$ref_period->{days}."d ".
            "--end now ".
            "--title \"$title\" ".
            "--vertical-label \"usage\" ".
            "--width ".$ref_period->{graph_width}." ".
            "--height ".$ref_period->{graph_height}." ".
            "--lower-limit 0 ".
            #"--upper-limit 100 ".
            #"--rigid ".
            "--units-exponent 0 ".
            "\"DEF:loadavg15=$rrd_file_loadavg15:loadavg15:AVERAGE\" ".
            "\"DEF:loadavg5=$rrd_file_loadavg5:loadavg5:AVERAGE\" ".
            "\"DEF:loadavg1=$rrd_file_loadavg1:loadavg1:AVERAGE\" ".
            "\"AREA:loadavg15#00FFFF:Average 15min\" ".
            "\"LINE1:loadavg5#00A0FF:Average 5min\" ".
            "\"LINE1:loadavg1#0019A6:Average 1min\" ";
        chomp(my @lines = qx/$cmd 2>&1/);
        die "Failed to generate $file! Command: $cmd\n",
            "Output:\n  ", join("\n  ", @lines), "\n"
            unless $? == 0;
    }
}

#-------------------------------------------------------------------------------
sub graph_net
{
    my ($ctx, $ref_available_info_keys, $machine_id, $history_start, $ref_periods) = @_;
    my @netifs;
    my %infokeys2rrd;

    sub _netif2rrdname { my $n = shift(); $n =~ s%[\:\-]%_%g; $n; }
    sub _netif2rrdfile {
        my ($dir, $mid, $netif_name, $inout) = @_;
        rrd_build_path $dir, $mid, 'net', $netif_name.$inout;
    }

    # list available network interfaces
    {
        # perl *rulez*!
        my $regex = qr/net\.([^\.]+)\.bytes\.(in|out)$/;
        my %matches =
            map { /$regex/; $1 => 1 }
            grep(/$regex/, @$ref_available_info_keys);
        @netifs = sort keys(%matches);
    }

    # populate %infokeys2rrd
    foreach my $netif (@netifs)
    {
        my $netif_name = _netif2rrdname $netif;
        foreach my $inout (qw( in out ))
        {
            $infokeys2rrd{"net.$netif.bytes.$inout"} = {
                rrd_name  => $netif_name.$inout,
                rrd_file  => _netif2rrdfile($ctx->{dir_rrd}, $machine_id, $netif_name, $inout),
                rrd_tmpl  => $RRD_TEMPLATES{abscounter_per_hour},
                rrd_start => $history_start,
            };
        }
    }

    # create and/or update all the necessary rrd file(s)
    rrd_create_and_update $ctx, $ref_available_info_keys, $machine_id, \%infokeys2rrd;

    # create graph for each interface and each period
    foreach my $netif (@netifs)
    {
        my $netif_name  = _netif2rrdname $netif;
        my $rrdfile_in  = _netif2rrdfile($ctx->{dir_rrd}, $machine_id, $netif_name, 'in');
        my $rrdfile_out = _netif2rrdfile($ctx->{dir_rrd}, $machine_id, $netif_name, 'out');

        foreach my $ref_period (@$ref_periods)
        {
            my $file  = $ctx->{dir_htdocs}."/graph-$machine_id-net$netif_name-$ref_period->{name}.png";
            my $title = "Traffic on $netif / $ref_period->{title}";

            my $cmd =
                "rrdtool graph \"$file\" ".
                "--start now-".$ref_period->{days}."d ".
                "--end now ".
                "--title \"$title\" ".
                "--vertical-label \"bytes/s\" ".
                "--width ".$ref_period->{graph_width}." ".
                "--height ".$ref_period->{graph_height}." ".
                "--lower-limit 0 ".
                #"--upper-limit 100 ".
                #"--rigid ".
                #"--units-exponent 0 ".
                #"--base 1024 ".
                "\"DEF:in=$rrdfile_in:${netif_name}in:AVERAGE\" ".
                "\"DEF:out=$rrdfile_out:${netif_name}out:AVERAGE\" ".
                "\"LINE1:in#AEE39E:In\" ".
                "\"LINE1:out#DC2F2F:Out\" ";
            chomp(my @lines = qx/$cmd 2>&1/);
            die "Failed to generate $file! Command: $cmd\n",
                "Output:\n  ", join("\n  ", @lines), "\n"
                unless $? == 0;
        }
    }
}



#-------------------------------------------------------------------------------
sub generate_graphs
{
    my ($ctx, $machine_id) = @_;
    my $ref_machine = $ctx->{machines}{$machine_id};
    my $year_ago    = $ctx->{now} - (365 * 86400);
    my $today_str   = today_str $ctx->{now};
    my $available_info_keys;

    # list all the info keys available within the desired period
    $available_info_keys = $ctx->{dbh}->selectcol_arrayref(qq{
        SELECT la.key
        FROM logatom AS la
        WHERE la.machine_id = $machine_id
        AND ( la.unix_first >= $year_ago OR la.unix_last >= $year_ago )
        AND ( la.unix_first <= $ctx->{now} OR la.unix_last <= $ctx->{now} )
        GROUP BY la.key
        ORDER BY la.id ASC },
        { Columns => [ 1 ] });
    #warn "INFO KEYS for machine $machine_id (", scalar(@$available_info_keys), "):\n", join(', ', sort(@$available_info_keys)), "\n";

    # generate graphs
    my @periods = (
        {
            name         => 'day',
            days         => 1,
            title        => "$ref_machine->{name} / $today_str",
            graph_width  => 500,
            graph_height => 100,
        },
        {
            name         => 'week',
            days         => 7,
            title        => "$ref_machine->{name} / $today_str",
            graph_width  => 500,
            graph_height => 100,
        },
        {
            name         => 'month',
            days         => 30,
            title        => "$ref_machine->{name} / $today_str",
            graph_width  => 1000,
            graph_height => 60,
        },
        {
            name         => 'year',
            days         => 365,
            title        => "$ref_machine->{name} / $today_str",
            graph_width  => 1000,
            graph_height => 60,
        },
    );
    main->can("graph_$_")->($ctx, $available_info_keys, $machine_id, $year_ago, \@periods)
        foreach (qw( usage load net )); # storage named apache lighttpd ));
}

#-------------------------------------------------------------------------------
my %ctx = ( # global context
    help       => undef,
    configfile => DEFAULT_CONFIG_FILE,

    db_source  => undef,
    db_user    => undef,
    db_pass    => undef,
    db_maxrows => 10_000,

    dir_rrd    => DEFAULT_RRD_DIR,
    dir_htdocs => DEFAULT_HTDOCS_DIR,

    now      => time,
    dbh      => undef,
    machines => { },
);
my $res;

BEGIN { $| = 1; }

# parse parameters
$res = Getopt::Long::GetOptions(
    'help|h|?' => \$ctx{help},
    'config=s' => \$ctx{configfile},
);
usage unless $res and not $ctx{help};

# read config file
{
    my $oconf = PMon::Config->new(
        file   => $ctx{configfile},
        strict => 1,
        subst  => { '{BASEDIR}' => $MY_DIR.'/..', },
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

# connect to database
$ctx{dbh} = DBI->connect(
    'dbi:mysql:db=pmon;host=localhost',
    'pmon', 'jsVTrpW7NBXXdvjP', {
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
die "No machines found in DB!\n" unless keys(%{$ctx{machines}}) > 0;

# generate as much graphs as we can for every machines
generate_graphs(\%ctx, $_)
    foreach (sort keys(%{$ctx{machines}}));

# free and quit
$ctx{dbh}->disconnect;
exit 0;
