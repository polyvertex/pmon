#
# PMon
# A personal monitoring system for Linux based on a service/node architecture.
#
# Copyright (C) 2013 Jean-Charles Lefebvre <jcl [AT] jcl [DOT] io>
#
# This software is provided 'as-is', without any express or implied
# warranty.  In no event will the authors be held liable for any damages
# arising from the use of this software.
#
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it
# freely, subject to the following restrictions :
#
# 1. The origin of this software must not be misrepresented; you must not
#    claim that you wrote the original software. If you use this software
#    in a product, an acknowledgment in the product documentation would be
#    appreciated but is not required.
# 2. Altered source versions must be plainly marked as such, and must not
#    be misrepresented as being the original software.
# 3. This notice may not be removed or altered from any source distribution.
#
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

            my $info = PMon::InfoLine->new(
                addr_packed => $addr,
                is_received => 1,
                line        => $1,
            );
            next unless $info->is_valid;

            push @infos, $info;
        }
        delete $self->{$addr} if $self->{$addr} eq '';
    }

    return \@infos;
}


1;
