#
# PMon
# A small monitoring system for Linux written in Perl.
#
# Copyright (C) 2013-2015 Jean-Charles Lefebvre <polyvertex@gmail.com>
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
# Created On: 2013-03-08 17:04:50Z
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

        $self->[BLOCK_SIZE] = $args{BlockSize}
            if exists($args{BlockSize})
            and defined($args{BlockSize})
            and $args{BlockSize} > 0;
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
