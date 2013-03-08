#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-08 17:04:55Z
#
# $Id$
#

package PMon::Daemon::NetFilterIn;
use base qw(POE::Filter);

use strict;
use warnings;

use PMon::InfoLine ();


sub new { bless { }, shift }
sub put { die }

sub get
{
    my ($self, $data) = @_;
    my @addr_order;
    my %addr_seen;
    my @infos;

    # group every received chunks by peer address and
    # order them by time of arrival (keep up the fifo spirit!)
    foreach my $d (@$data)
    {
        if (exists $self->{$d->[0]})
        {
            $self->{$d->[0]} .= $d->[1];
        }
        else
        {
            $self->{$d->[0]} = $d->[1];
        }

        unless (exists $addr_seen{$d->[0]})
        {
            push @addr_order, $d->[0];
            $addr_seen{$d->[0]} = 1;
        }
    }

    # process as much data as we can
    foreach my $addr (@addr_order)
    {
        next unless exists $self->{$addr};
        while (1)
        {
            last unless $self->{$addr} =~ s/^(.*?)(\x0D\x0A?|\x0A\x0D?)//s;
            next unless length($1) > 0; # can happen
            push @infos, PMon::InfoLine->new(
                addr_packed => $addr,
                is_received => 1,
                line        => $1
            );
        }
        delete $self->{$addr} if $self->{$addr} eq '';
    }

    return \@infos;
}


1;