#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-03-08 17:04:50Z
#
# $Id$
#

package PMon::Daemon::NetDriverIn;

use strict;
use warnings;

use Socket;


sub BLOCK_SIZE () { 0 }

sub new
{
    my $class = shift;
    my $self = bless [
        2048,  # block size
    ], $class;

    if (@_)
    {
        my %args = @_;

        $self->[BLOCK_SIZE] = $args{'BlockSize'}
            if exists($args{'BlockSize'})
            and defined($args{'BlockSize'})
            and $args{'BlockSize'} > 0;
    }

    return $self;
}

sub put   { die }
sub flush { die }

sub get
{
    my ($self, $fh) = @_;
    my @ret;

    while (1)
    {
        my $buffer = '';
        my $from = recv $fh, $buffer, $self->[BLOCK_SIZE], 0;
        last unless $from;
        push @ret, [ $from, $buffer ];
    }

    return if @ret == 0;
    return \@ret;
}


1;
