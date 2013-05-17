#!/usr/bin/env bash
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
# Created On: 2013-02-26 17:57:13Z
#
# $Id$
#

LC_ALL=POSIX

# os.kernel
res=$(uname -a)
[ $? -ne 0 -o -z "$res" ] && echo "Failed to call uname command!" && exit 1
echo "os.kernel.label $res"
echo "os.kernel.name $(uname -s)"
echo "os.kernel.release $(uname -r)"
echo "os.kernel.version $(uname -v)"

# os.distro
[ -f /etc/redhat-release ] && res=$(cat /etc/redhat-release)
[ -f /etc/gentoo-release ] && res=$(cat /etc/gentoo-release)
[ -f /etc/debian_version ] && res="Debian "$(cat /etc/debian_version)
[ -f /etc/SuSE-release ] && res=$(cat /etc/SuSE-release)
[ -f /etc/slackware-version ] && res=$(cat /etc/slackware-version)
[ -f /etc/lsb-release ] && \
    [ -n "$(grep -i ubuntu /etc/lsb-release)" ] && \
    [ -f /etc/lsb-release ] && \
    uv=$(grep DISTRIB_DESCRIPTION /etc/lsb-release | cut -d\= -f2) && \
    [ -n "$uv" ] && \
    res=$uv
[ -z "$res" ] && echo "Cannot find distro info!" && exit 1
echo "os.distro.label $res"
