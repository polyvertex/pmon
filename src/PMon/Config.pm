#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-01 17:23:26Z
#
# $Id$
#

package PMon::Config;

use strict;
use warnings;



#-------------------------------------------------------------------------------
sub new
{
    my $class = shift;
    my $self  = bless { }, $class;
    my %opt   = @_;

    $self->{'file'} =
        (exists($opt{'file'}) and defined($opt{'file'})) ?
        $opt{'file'} :
        undef;

    $self->{'strict'} = # type strictness
        (exists($opt{'strict'}) and defined($opt{'strict'})) ?
        $opt{'strict'} :
        1;

    $self->{'subst'} =
        (exists($opt{'subst'}) and defined($opt{'subst'})) ?
        $opt{'subst'} :
        { };

    $self->{'settings'} = { };

    $self->load if defined $self->{'file'};

    return $self;
}

#-------------------------------------------------------------------------------
sub set_strict
{
    my ($self, $be_strict) = @_;
    $self->{'strict'} = $be_strict ? 1 : 0;
}

#-------------------------------------------------------------------------------
sub set_subst
{
    my ($self, $key, $value) = @_;
    $self->{'subst'}{$key} = $value;
}

#-------------------------------------------------------------------------------
sub reset_subst
{
    shift()->{'subst'} = { };
}

#-------------------------------------------------------------------------------
sub load
{
    my ($self, $opt_file) = @_;
    my $fh;

    $self->{'settings'} = { };

    die "Configuration file path not specified!"
        unless defined($opt_file) or defined($self->{'file'});
    $self->{'file'} = $opt_file if defined $opt_file;

    open($fh, '<', $self->{'file'})
        or die "Failed to open ", $self->{'file'}, "! $!\n";

    while (<$fh>)
    {
        chomp; s/^\s+//; s/^#.*//; s/\s+$//;
        next unless length; # skip comment and empty lines

        die "Wrong key-value pair format in ", $self->{'file'}, " at line $.!\n"
            unless /^(\w+)\s*=\s*(.*)$/;
        #die "Unknown value name '$1' in ", $self->{'file'}, " at line $.!\n"
        #    unless exists $self->{'accepted'}{$1};

        $self->{'settings'}{$1} = $2 // '';
    }

    close $fh;
}

#-------------------------------------------------------------------------------
sub get_bool
{
    my ($self, $key, $opt_default) = @_;

    return $opt_default unless exists $self->{'settings'}{$key};

    if ($self->{'settings'}{$key} =~ /^(1|on|yes|true)$/i)
    {
        return 1;
    }
    elsif ($self->{'settings'}{$key} =~ /^(0|off|no|false)$/i)
    {
        return 0;
    }
    elsif ($self->{'strict'})
    {
        die "Wrong format of value '$key' in ", $self->{'file'}, "!\n";
    }

    return $opt_default;
}

#-------------------------------------------------------------------------------
sub get_int
{
    my ($self, $key, $opt_default, $opt_value_min, $opt_value_max) = @_;
    my $value = $opt_default;

    if (exists($self->{'settings'}{$key}) and defined($self->{'settings'}{$key}))
    {
        if ($self->{'settings'}{$key} =~ /^0x[0-9A-F]+$/i)
        {
            $value = hex $self->{'settings'}{$key};
        }
        elsif ($self->{'settings'}{$key} =~ /^[+-]?\d+$/)
        {
            $value = +($self->{'settings'}{$key});
        }
        elsif ($self->{'strict'})
        {
            die "Wrong format of value '$key' in ", $self->{'file'}, "!\n";
        }

        if (defined $value)
        {
            die "Wrong format of value '$key' in ", $self->{'file'}, "!\n"
                if $self->{'strict'}
                and ( (defined($opt_value_min) and $value < $opt_value_min)
                or (defined($opt_value_max) and $value > $opt_value_max) );

            $value = $opt_value_min
                if defined($opt_value_min) and $value < $opt_value_min;
            $value = $opt_value_max
                if defined($opt_value_max) and $value > $opt_value_max;
        }
    }

    return $value;
}

#-------------------------------------------------------------------------------
sub get_str
{
    my ($self, $key, $opt_default) = @_;

    return $opt_default unless exists $self->{'settings'}{$key};

    my $value = $self->{'settings'}{$key};
    while (my ($key, $subst) = each %{$self->{'subst'}})
    {
        while ((my $idx = index($value, $key)) >= $[)
        {
            $value = substr $value, $idx, length($key), $subst;
        }
    }

    return $value;
}


1;
