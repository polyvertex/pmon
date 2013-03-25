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
use CGI ();
use DBI;

use lib "$FindBin::RealBin";
use PMon::Config;

use constant
{
    # default paths
    DEFAULT_REVISION_FILE => $FindBin::RealBin.'/revision',
    DEFAULT_CONFIG_FILE   => $FindBin::RealBin.'/../../etc/pmond.conf',
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
            visible => 0,
            title   => '%s',
            desc    => 'Status of %s',
        },
    },

    ARGNAME_PAGE       => 'p',
    ARGNAME_MACHINE_ID => 'mid',
};


#----------------------------------------------------------------------------
sub url_encode
{
    # imitate the behavior of php's rawurlencode()
    my $url = shift;
    $url =~ s/([^A-Za-z0-9_\.~-])/sprintf('%%%02X', ord($1))/seg;
    return $url;
}

#----------------------------------------------------------------------------
sub url_decode
{
    my $url = shift;
    $url =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
    return $url;
}

#----------------------------------------------------------------------------
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
    my $html_title  = TITLE;
    my $page_title1 = lc TITLE;
    my $page_title2 = lc page_property($ctx, 'name');
    my $desc        = lc page_property($ctx, 'desc');
    my $menu        = '';

    # preparing the menu line
    foreach my $pname (@{PAGES_ORDER()})
    {
        next unless PAGES()->{$pname}{visible};
        next if $pname eq $self->{page_name};
        $menu .= $ctx->{cgi}->a({
                href  => url_addparams($ctx->{root_url}, ARGNAME_PAGE() => $pname),
                title => PAGES()->{$pname}{desc},
            },
            PAGES()->{$pname}{title});
        $menu .= ', ';
    }
    $menu =~ s%,\s+$%%g;
    $menu = "<strong>see also &raquo</strong> $menu"
        if length($menu) > 0;

return <<EOV;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
  <title>$html_title</title>
  <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">
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

#----------------------------------------------------------------------------
sub tmpl_footer
{
    my $ctx = shift;
    my $desc = lc TITLE.' '.TITLE_CAPTION.' v'.$ctx->{revision};
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
my %ctx = ( # global context
    revision => 0,

    db_source  => undef,
    db_user    => undef,
    db_pass    => undef,
    dir_htdocs => undef,

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
        subst  => { '{BASEDIR}' => $FindBin::RealBin.'/..', },
    );

    $ctx{db_source}  = $oconf->get_str('db_source');
    $ctx{db_user}    = $oconf->get_str('db_user');
    $ctx{db_pass}    = $oconf->get_str('db_pass');
    $ctx{dir_htdocs} = $oconf->get_subst_str('dir_htdocs', DEFAULT_HTDOCS_DIR);
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
    unless $ctx{machine_id} =~ /^\d+$/
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

# free and quit
$ctx{dbh}->disconnect;
