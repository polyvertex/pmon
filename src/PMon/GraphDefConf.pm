#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-21 07:58:49Z
#
# $Id$
#

%USER_GRAPHICS_DEFINITIONS = (

    COLORS => [
        blue_light  => '00FFFF',
        blue        => '00A0FF',
        blue_dark   => '0019A6',
        green_light => 'B2E0C2',
        green       => '33AD5C',
        green_dark  => '008A2E',
        red_light   => 'FF6464',
        red         => 'DC2F2F',
        red_dark    => '821B1B',
        orange      => 'FF6600',
        purple      => '4024B2',
    ],

    GRAPHICS => [
        {
            name    => 'usage',
            type    => GRAPHDEFINITION_STATIC,
            periods => [ 1, 7 ],
            label   => "Usage",
            values  => [
                {
                    name        => 'cpu',
                    dbkey       => 'cpu.usage',
                    rrd_profile => RRD_PROFILE_PERCENTAGE,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
                {
                    name        => 'mem',
                    dbkey       => 'mem.usage',
                    rrd_profile => RRD_PROFILE_PERCENTAGE,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
                {
                    name        => 'swap',
                    dbkey       => 'swap.usage',
                    rrd_profile => RRD_PROFILE_PERCENTAGE,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
            ],
            rrd_graph_options => [
                '--vertical-label usage',
                '--lower-limit 0',
                '--upper-limit 100',
                #'--rigid',
                '--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [
                'DEF:cpu={RRDFILE:cpu}:cpu:AVERAGE',
                'DEF:mem={RRDFILE:mem}:mem:AVERAGE',
                'DEF:swap={RRDFILE:swap}:swap:AVERAGE',
            ],
            rrd_graph_draw => [
                'AREA:mem#{COLOR:blue_light}:Memory',
                'LINE1:swap#{COLOR:blue}:Swap',
                'LINE1:cpu#{COLOR:red}:CPU',
            ],
        },

        {
            name    => 'load',
            type    => GRAPHDEFINITION_STATIC,
            periods => [ 1, 7 ],
            label   => "Load",
            values  => [
                {
                    name        => 'loadavg1',
                    dbkey       => 'ps.loadavg1',
                    rrd_profile => RRD_PROFILE_ABSVALUE,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
                {
                    name        => 'loadavg5',
                    dbkey       => 'ps.loadavg5',
                    rrd_profile => RRD_PROFILE_ABSVALUE,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
                {
                    name        => 'loadavg15',
                    dbkey       => 'ps.loadavg15',
                    rrd_profile => RRD_PROFILE_ABSVALUE,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
            ],
            rrd_graph_options => [
                '--vertical-label load',
                '--lower-limit 0',
                #'--upper-limit 100',
                #'--rigid',
                '--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [
                'DEF:loadavg1={RRDFILE:loadavg1}:loadavg1:AVERAGE',
                'DEF:loadavg5={RRDFILE:loadavg5}:loadavg5:AVERAGE',
                'DEF:loadavg15={RRDFILE:loadavg15}:loadavg15:AVERAGE',
            ],
            rrd_graph_draw => [
                'AREA:loadavg15#{COLOR:blue_light}:Average 15min',
                'LINE1:loadavg5#{COLOR:blue}:Average 5min',
                'LINE1:loadavg1#{COLOR:blue_dark}:Average 1min',
            ],
        },
 
        {
            name    => 'net',
            type    => GRAPHDEFINITION_DYNAMIC,
            periods => [ 1, 7 ],
            label   => "{DEVICE} throughput",
            vname   => qr/^net\.([^\.]+)\.bytes\.(in|out)$/, # {DEVICE}=$1
            values  => [
                {
                    name        => '{DEVICE}bytesin',
                    dbkey       => 'net.{DEVICE}.bytes.in',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                    rrg_def     => [ 'DEF:{DEVICE}bytesin={RRDFILE}:{DEVICE}bytesin:AVERAGE', ],
                    rrg_draw    => [ 'AREA:{DEVICE}bytesin#{COLOR:green_light}:In', ],
                },
                {
                    name        => '{DEVICE}bytesout',
                    dbkey       => 'net.{DEVICE}.bytes.out',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                    rrg_def     => [ 'DEF:{DEVICE}bytesout={RRDFILE}:{DEVICE}bytesout:AVERAGE', ],
                    rrg_draw    => [ 'LINE1:{DEVICE}bytesout#{COLOR:red}:Out', ],
                },
            ],
            rrd_graph_options => [
                '--vertical-label bytes/s',
                '--lower-limit 0',
                #'--upper-limit 100',
                #'--rigid',
                #'--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [ ],
            rrd_graph_draw => [ ],
        },
        
        {
            name    => 'storaccess',
            type    => GRAPHDEFINITION_DYNAMIC,
            periods => [ 1, 7 ],
            label   => "{DEVICE} throughput",
            vname   => qr/^hdd\.([^\.]+)\.bytes\.[rw]$/, # {DEVICE}=$1
            values  => [
                {
                    name        => '{DEVICE}read',
                    dbkey       => 'hdd.{DEVICE}.bytes.r',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                    rrg_def     => [ 'DEF:{DEVICE}read={RRDFILE}:{DEVICE}read:AVERAGE', ],
                    rrg_draw    => [ 'AREA:{DEVICE}read#{COLOR:green_light}:Read', ],
                },
                {
                    name        => '{DEVICE}write',
                    dbkey       => 'hdd.{DEVICE}.bytes.r',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                    rrg_def     => [ 'DEF:{DEVICE}write={RRDFILE}:{DEVICE}write:AVERAGE', ],
                    rrg_draw    => [ 'LINE1:{DEVICE}write#{COLOR:red}:Write', ],
                },
            ],
            rrd_graph_options => [
                '--vertical-label bytes/s',
                '--lower-limit 0',
                #'--upper-limit 100',
                #'--rigid',
                #'--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [ ],
            rrd_graph_draw => [ ],
        },

        {
            name    => 'stortemp',
            type    => GRAPHDEFINITION_DYNAMIC_ONEGRAPH,
            periods => [ 1, 7 ],
            label   => "HDD Temperature",
            vname   => qr/^hdd\.([^\.]+)\.temp$/, # {DEVICE}=$1
            values  => [
                {
                    name        => '{DEVICE}',
                    dbkey       => 'hdd.{DEVICE}.temp',
                    rrd_profile => RRD_PROFILE_PERCENTAGE,
                    rra_profile => RRA_PROFILE_MINUTE,
                    rrg_def     => [ 'DEF:{DEVICE}temp={RRDFILE}:{DEVICE}:AVERAGE', ],
                    rrg_draw    => [ 'LINE1:{DEVICE}temp#{RRCOLOR}:{DEVICE}', ],
                },
            ],
            rrd_graph_options => [
                '--vertical-label C',
                '--lower-limit 0',
                #'--upper-limit 100',
                #'--rigid',
                '--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [ ],
            rrd_graph_draw => [ ],
        },

        {
            name    => 'named',
            type    => GRAPHDEFINITION_STATIC,
            periods => [ 1, 7 ],
            label   => "Bind9",
            values  => [
                {
                    name        => 'reqin',
                    dbkey       => 'named.req.in',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
                {
                    name        => 'reqout',
                    dbkey       => 'named.req.out',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
            ],
            rrd_graph_options => [
                '--vertical-label requests/s',
                '--lower-limit 0',
                #'--upper-limit 100',
                #'--rigid',
                #'--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [
                'DEF:reqin={RRDFILE:reqin}:reqin:AVERAGE',
                'DEF:reqout={RRDFILE:reqout}:reqout:AVERAGE',
            ],
            rrd_graph_draw => [
                'AREA:reqin#{COLOR:blue}:Incoming Requests',
                'LINE1:reqout#{COLOR:red}:Outgoing Queries',
            ],
        },

        {
            name    => 'apache',
            type    => GRAPHDEFINITION_STATIC,
            periods => [ 1, 7 ],
            label   => "Apache",
            values  => [
                {
                    name        => 'bytes',
                    dbkey       => 'apache.bytes',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
                {
                    name        => 'hits',
                    dbkey       => 'apache.hits',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
            ],
            rrd_graph_options => [
                #'--vertical-label requests/s',
                '--lower-limit 0',
                #'--upper-limit 100',
                #'--rigid',
                #'--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [
                'DEF:bytes={RRDFILE:bytes}:bytes:AVERAGE',
                'DEF:hits={RRDFILE:hits}:hits:AVERAGE',
            ],
            rrd_graph_draw => [
                'AREA:bytes#{COLOR:blue_light}:Bytes/s',
                'LINE1:hits#{COLOR:blue}:Hits/s',
            ],
        },

        {
            name    => 'lighttpd',
            type    => GRAPHDEFINITION_STATIC,
            periods => [ 1, 7 ],
            label   => "Lighttpd",
            values  => [
                {
                    name        => 'bytes',
                    dbkey       => 'lighttpd.bytes',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
                {
                    name        => 'hits',
                    dbkey       => 'lighttpd.hits',
                    rrd_profile => RRD_PROFILE_ABSCOUNTER,
                    rra_profile => RRA_PROFILE_MINUTE,
                },
            ],
            rrd_graph_options => [
                #'--vertical-label requests/s',
                '--lower-limit 0',
                #'--upper-limit 100',
                #'--rigid',
                #'--units-exponent 0',
                #'--base 1024',
            ],
            rrd_graph_def => [
                'DEF:bytes={RRDFILE:bytes}:bytes:AVERAGE',
                'DEF:hits={RRDFILE:hits}:hits:AVERAGE',
            ],
            rrd_graph_draw => [
                'AREA:bytes#{COLOR:blue_light}:Bytes/s',
                'LINE1:hits#{COLOR:blue}:Hits/s',
            ],
        },
    ],

);


1;
