#!/usr/bin/env bash
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
