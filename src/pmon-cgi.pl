#!/usr/bin/env perl
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-18 15:38:52Z
#
# $Id$
#

use strict;
use warnings;

use FindBin ();
use File::Basename ();
use CGI ();
use DBI;

use constant
{
    # default paths
    DEFAULT_BASE_DIR      => $FindBin::RealBin.'/../..',
    DEFAULT_CONFIG_FILE   => $FindBin::RealBin.'/../../etc/pmon-daemon.conf',
    DEFAULT_REVISION_FILE => $FindBin::RealBin.'/revision',
    DEFAULT_HTDOCS_DIR    => $FindBin::RealBin,

    # html content
    TITLE         => 'PMon',
    TITLE_CAPTION => 'Personal Monitoring',
    AUTHOR_LABEL  => 'jcl.io',
    AUTHOR_WWW    => 'www.jcl.io',

    # html pages
    # in order of appearance in the menu, the first one is the default one
    PAGES_ORDER => [ 'home', 'machine' ],
    PAGES => {
        home => {
            visible => 1,
            title   => 'Overview',
            desc    => 'Overview of your monitored machines',
        },
        machine => {
            visible => 1,
            title   => '%s',
            desc    => 'Status of %s',
        },
    },

    ARGNAME_PAGE       => 'p',
    ARGNAME_MACHINE_ID => 'm',
};


#-------------------------------------------------------------------------------
sub url_encode
{
    # imitate the behavior of php's rawurlencode()
    my $url = shift;
    $url =~ s/([^A-Za-z0-9_\.~-])/sprintf('%%%02X', ord($1))/seg;
    return $url;
}

#-------------------------------------------------------------------------------
sub url_decode
{
    my $url = shift;
    $url =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
    return $url;
}

#-------------------------------------------------------------------------------
sub url_addparams
{
    my $url = shift;
    my $sep;

    return $url unless @_ > 0;
    die unless (@_ % 2) == 0;

    $sep = ($url =~ /\?/) ? '&' : '?';
    while (@_ > 0)
    {
        my ($key, $value) = splice @_, 0, 2;
        $url .= $sep.url_encode($key).'='.url_encode($value);
        $sep = '&' if $sep eq '?';
    }

    return $url;
}

#-------------------------------------------------------------------------------
sub url_page_machine
{
    my ($ctx, $machine_id) = @_;

    return url_addparams
        $ctx->{root_url},
        ARGNAME_PAGE()       => 'machine',
        ARGNAME_MACHINE_ID() => $machine_id;
}

#-------------------------------------------------------------------------------
sub datetime_utcstr
{
    my @t = gmtime(shift() // time());
    return sprintf
        '%04u-%02u-%02u %02u:%02u:%02u',
        $t[5] + 1900, $t[4] + 1, $t[3],
        $t[2], $t[1], $t[0];
}

#-------------------------------------------------------------------------------
sub time_duration2str
{
    my $seconds = shift;
    my $str;

    if ($seconds >= 86400)
    {
        $str .= int($seconds / 86400).'d ';
        $seconds %= 86400;
    }
    if ($seconds >= 3600)
    {
        $str .= int($seconds / 3600).'h ';
        $seconds %= 3600;
    }
    if ($seconds >= 60)
    {
        $str .= int($seconds / 60).'m ';
        $seconds %= 60;
    }
    $str .= $seconds.'s';

    return $str;
}

#-------------------------------------------------------------------------------
sub page_property
{
    my ($ctx, $prop_name) = @_;
    return
        ($ctx->{page_name} eq 'machine') ?
        sprintf($ctx->{page}{$prop_name}, $ctx->{machine}{name}) :
        $ctx->{page}{$prop_name};
}



#-------------------------------------------------------------------------------
sub tmpl_header
{
    my $ctx = shift;
    my $html_title  = page_property($ctx, 'title').' &middot; '.TITLE;
    my $page_title1 = lc TITLE;
    my $page_title2 = lc page_property($ctx, 'title');
    my $desc        = lc page_property($ctx, 'desc');
    my $menu        = '';

    # preparing the menu line
    foreach my $pname (@{PAGES_ORDER()})
    {
        next unless PAGES()->{$pname}{visible};

        if ($pname eq 'machine')
        {
            foreach my $machine_id (sort keys(%{$ctx->{machines}}))
            {
                next
                    if defined($ctx->{machine_id})
                    and $machine_id == $ctx->{machine_id};

                my $machine_name = $ctx->{machines}{$machine_id}{name};

                $menu .= $ctx->{cgi}->a({
                        href  => url_page_machine($ctx, $machine_id),
                        title => sprintf(PAGES()->{$pname}{desc}, $machine_name),
                    },
                    sprintf(PAGES()->{$pname}{title}, $machine_name));
                $menu .= ', ';
            }
        }
        else
        {
            next if $pname eq $ctx->{page_name};
            $menu .= $ctx->{cgi}->a({
                    href  => url_addparams($ctx->{root_url}, ARGNAME_PAGE() => $pname),
                    title => PAGES()->{$pname}{desc},
                },
                PAGES()->{$pname}{title});
            $menu .= ', ';
        }
    }
    $menu =~ s%,\s+$%%g;
    $menu = "<strong>see also &raquo</strong> $menu"
        if length($menu) > 0;

return <<EOV;
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>$html_title</title>
  <meta http-equiv="Pragma" content="no-cache">
  <link rel="stylesheet" type="text/css" media="screen" href="pmon.css">
  <link rel="icon" href="favicon.ico">
</head>
<body>

<div class="main">
<a id="top"></a>

<div class="header">
  <h1>
    $page_title1 <font style="color: gray;">|</font> <font style="color: orange;">$page_title2</font><br />
    <small>$desc</small>
  </h1>
</div>

<div class="menu">$menu</div>
<div class="body">

EOV
}

#-------------------------------------------------------------------------------
sub tmpl_footer
{
    my $ctx = shift;
    my $desc = lc TITLE_CAPTION.' v'.$ctx->{revision};
    my $author_link = $ctx->{cgi}->a({
            href   => 'http://'.AUTHOR_WWW.'/',
            #target => '_blank',
        },
        AUTHOR_LABEL);

return <<EOV;

</div> <!-- div.body -->
</div> <!-- div.main -->

<div style="clear: both;">&nbsp;</div>
<center>
  <small>${desc}&nbsp;&nbsp;-&nbsp;&nbsp;$author_link</small>
  <br /><br /><br />
</center>

<br /><br /><br /><br /><br /><br /><br /><br /><br /><br /><br /><br /><br />
<br /><br /><br /><br /><br /><br /><br /><br /><br /><br /><br /><br /><br />
</body>
</html>
EOV
}



#-------------------------------------------------------------------------------
sub tmpl_body_home__machines
{
    my $ctx = shift;
    my $output = '';

    $output .= <<EOV;
<center>
<table class="machines">
  <tr>
    <th>Machine</th>
    <th>Last update</th>
    <th>Uptime</th>
  </tr>
EOV

    foreach my $machine_id (sort keys(%{$ctx->{machines}}))
    {
        my $ref_machine = $ctx->{machines}{$machine_id};
        my $item_anchor = $ctx->{cgi}->a({ name => $ref_machine->{name} }, '');
        my $item_label = $ctx->{cgi}->a({
                href  => url_page_machine($ctx, $machine_id),
                title => '',
            },
            $ref_machine->{name});
        my $item_lastup_delta = $ctx->{now} - $ref_machine->{unix};
        my $item_lastup = $ctx->{cgi}->abbr(
            { title => datetime_utcstr($ref_machine->{unix}).' (UTC)' },
            time_duration2str($item_lastup_delta)." ago");
        $item_lastup = "<font class=\"hard\">$item_lastup</font>"
            if $item_lastup_delta >= 75;
        my $item_uptime = $ctx->{cgi}->abbr(
            { title => 'Last boot at '.datetime_utcstr($ctx->{now} - $ref_machine->{uptime}).' (UTC), '.$ref_machine->{uptime}.' seconds' },
            time_duration2str($ref_machine->{uptime}));

        $output .=
            "  <tr>\n".
            "    <td>$item_anchor$item_label</td>\n".
            "    <td>$item_lastup</td>\n".
            "    <td>$item_uptime</td>\n".
            "  </tr>\n";
    }

    $output .= <<EOV;
</table>
</center>

EOV

    return $output;
}

#-------------------------------------------------------------------------------
sub tmpl_body_home
{
    my $ctx = shift;

    return
        (keys(%{$ctx->{machines}}) > 0) ?
        tmpl_body_home__machines($ctx) :
        "No machine monitored!\n";
}



#-------------------------------------------------------------------------------
sub tmpl_body_machine__graphgroup
{
    my ($ctx, $rows) = @_;
    my $output = '';

    for (my $i = 0; $i < scalar(@$rows); )
    {
        my $ref_graph     = $rows->[$i];
        my $ref_nextgraph = ($i + 1 < scalar(@$rows)) ? $rows->[$i + 1] : undef;

        # special case: display 'day' and 'week' graphs side by side if we can
        if ($ref_graph->{days} == 1 and
            defined($ref_nextgraph) and
            $ref_nextgraph->{days} == 7)
        {
            my $img1 = $ctx->{cgi}->img({
                src   => File::Basename::basename($ref_graph->{file}),
                title => $ref_graph->{title},
            });
            my $img2 = $ctx->{cgi}->img({
                src   => File::Basename::basename($ref_nextgraph->{file}),
                title => $ref_nextgraph->{title},
            });

            $output .=
                "  <tr>\n".
                "    <td>$img1</td>\n".
                "    <td>$img2</td>\n".
                "  </tr>\n";

            $i += 2;
        }
        else
        {
            my $img = $ctx->{cgi}->img({
                src   => File::Basename::basename($ref_graph->{file}),
                title => $ref_graph->{title},
            });

            $output .=
                "  <tr>\n".
                "    <td colspan=2>$img</td>\n".
                "  </tr>\n";

            ++$i;
        }
    }

    return $output;
}

#-------------------------------------------------------------------------------
sub tmpl_body_machine
{
    my $ctx = shift;
    my $output = '';
    my $rows;
    my %available_defnames;
    my %displayed_defnames;

    $rows = $ctx->{dbh}->selectcol_arrayref(
        'SELECT defname '.
        'FROM graph '.
        'WHERE machine_id = '.$ctx->{machine_id}.' '.
        'ORDER BY defname ASC');
    die unless defined($rows) and @$rows > 0;
    %available_defnames = map { $_ => undef } @$rows;
    $rows = undef;

    $output .= <<EOV;
<center>
<table class="graphs">
EOV

    foreach my $defname (( @{$ctx->{graphs_order}}, sort(keys(%available_defnames)) ))
    {
        next unless exists $available_defnames{$defname};
        next if exists $displayed_defnames{$defname};

        $rows = $ctx->{dbh}->selectall_arrayref(
            'SELECT uniqname, machine_id, unix, days, defname, graphname, title, file '.
            'FROM graph '.
            'WHERE machine_id = '.$ctx->{machine_id}.' '.
            'AND defname = '.$ctx->{dbh}->quote($defname).' '.
            'ORDER BY defname ASC, days ASC, graphname ASC, uniqname ASC ',
            { Slice => { } });

        if (defined($rows) and @$rows > 0)
        {
            if (keys(%displayed_defnames) > 0)
            {
                $output .= "  <tr><td colspan=2>&nbsp;</td></tr>\n";
            }
            else
            {
                $output .=
                    "  <tr><td colspan=2><code>Updated ".
                    time_duration2str($ctx->{now} - $rows->[0]{unix}).
                    " ago at ".datetime_utcstr($rows->[0]{unix}).
                    " (UTC)</code></td></tr>\n".
                    "  <tr><td colspan=2>&nbsp;</td></tr>\n";
            }

            $output .=
                "  <tr>\n".
                "    <th colspan=2>".$rows->[0]{title}."</th>\n".
                "  </tr>\n";
            $output .= tmpl_body_machine__graphgroup $ctx, $rows;
        }
        else
        {
            $output .=
                "  <tr><th colspan=2>Failed to fetch $defname graphs!</th></tr>\n";
        }

        $displayed_defnames{$defname} = 1;
    }


    $output .= <<EOV;
</table>
</center>

EOV

    return $output;
}



#-------------------------------------------------------------------------------
my %ctx = ( # global context
    revision => 0,
    now      => time,

    db_source    => undef,
    db_user      => undef,
    db_pass      => undef,
    dir_htdocs   => undef,
    graphs_order => [ ],

    machines => { },

    cgi      => undef,
    root_url => undef,

    page         => undef,
    page_name    => undef,
    page_content => '',
    machine_id   => undef,
    machine      => undef,
);

BEGIN { $| = 1; }

# try to get agent's revision number
if (-e DEFAULT_REVISION_FILE)
{
    if (open my $fh, '<', DEFAULT_REVISION_FILE)
    {
        $ctx{revision} = <$fh>;
        chomp $ctx{revision};
        $ctx{revision} = 0 unless $ctx{revision} =~ /^\d+$/;
        close $fh;
    }
}

# read config file
{
    my $config_file =
        (exists($ENV{PMOND_CONFIGFILE}) and defined($ENV{PMOND_CONFIGFILE})) ?
        $ENV{PMOND_CONFIGFILE} :
        DEFAULT_CONFIG_FILE;

    die "Configuration file not found at $config_file!\n"
        unless -e $config_file;

    my $oconf = PMon::Config->new(
        file   => $config_file,
        strict => 1,
        subst  => { '{BASEDIR}' => DEFAULT_BASE_DIR, },
    );

    $ctx{db_source}    = $oconf->get_str('db_source');
    $ctx{db_user}      = $oconf->get_str('db_user');
    $ctx{db_pass}      = $oconf->get_str('db_pass');
    $ctx{dir_htdocs}   = $oconf->get_subst_str('dir_htdocs', DEFAULT_HTDOCS_DIR);
    $ctx{graphs_order} = [ split(/\s+/, $oconf->get_str('cgi_graphics_order', '')) ];
    die "Please check database access credentials in $config_file!\n"
        unless defined($ctx{db_source})
        and defined($ctx{db_user})
        and defined($ctx{db_pass});
}

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

# create cgi object
$ctx{cgi} = CGI->new;

# extract root url (url minus script and args parts)
$ctx{root_url} = CGI::url(-full => 1);
$ctx{root_url} =~ s%[^/]+$%%; # remove script part
$ctx{root_url} .= ($ctx{root_url} =~ /\/$/) ? '' : '/';

# cgi param: requested machine id
$ctx{machine_id} = $ctx{cgi}->url_param(ARGNAME_MACHINE_ID());
$ctx{machine_id} = undef
    unless defined($ctx{machine_id})
    and $ctx{machine_id} =~ /^\d+$/
    and exists($ctx{machines}{$ctx{machine_id}});
$ctx{machine} = $ctx{machines}{$ctx{machine_id}}
    if defined $ctx{machine_id};

# cgi param: requested page
$ctx{page_name} = $ctx{cgi}->url_param(ARGNAME_PAGE());
$ctx{page_name} = PAGES_ORDER()->[0]
    unless defined($ctx{page_name})
    and exists(PAGES()->{$ctx{page_name}});
$ctx{page_name} = PAGES_ORDER()->[0] # fallback to the default page if machine id was incorrect or not specified
    if $ctx{page_name} eq 'machine'
    and !defined($ctx{machine_id});
$ctx{page} = PAGES()->{$ctx{page_name}};

# serve
print $ctx{cgi}->header(-type => 'text/html');
print tmpl_header(\%ctx);
print main->can('tmpl_body_'.$ctx{page_name})->(\%ctx);
print tmpl_footer(\%ctx);

# free and quit
$ctx{dbh}->disconnect;
exit 0;
