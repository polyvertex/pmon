#!/bin/bash
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-02-27 10:14:17Z
#
# $Id$
#

# configuration
SVN_REPOSITORY_URL="https://svn.jcl.io/pmon/trunk/src/"
TMP_FILE="/tmp/pmon_install.tmp"
TMP_DIR="/tmp/pmon_install_dir"


# get the real path of this script
THIS_SCRIPT=${BASH_SOURCE[0]}
while [ -h "$THIS_SCRIPT" ]; do # resolve $THIS_SCRIPT until the file is no longer a symlink
    DIR=$(cd -P "$(dirname "$THIS_SCRIPT")" && pwd)
    THIS_SCRIPT=$(readlink "$THIS_SCRIPT")
    # if $THIS_SCRIPT was a relative symlink, we need to resolve it relative to the
    # path where the symlink file was located
    [[ "$THIS_SCRIPT" != /* ]] && THIS_SCRIPT="$DIR/$THIS_SCRIPT"
done
THIS_SCRIPT_DIR=$(cd -P "$(dirname "$THIS_SCRIPT")" && pwd)
THIS_SCRIPT_NAME=$(basename "$THIS_SCRIPT")

# global variables
ACTION=""
REVISION=""
INSTALL_DIR=""
INSTALL_AGENT=0
INSTALL_DAEMON=0



#-------------------------------------------------------------------------------
function usage()
{
    echo "Usage:"
    echo ""
    echo "* $THIS_SCRIPT_NAME install-all [install_dir] [revision]"
    echo "  To install or reinstall the PMon Daemon (server) and the PMon Agent"
    echo "  altogether in the specified directory or, by default, in the same"
    echo "  directory than this scrips."
    echo ""
    echo "* $THIS_SCRIPT_NAME install-agent [install_dir] [revision]"
    echo "  To install or reinstall the PMon Agent in the specified directory or,"
    echo "  by default, in the same directory than this script."
    echo ""
    echo "* $THIS_SCRIPT_NAME install-daemon [install_dir] [revision]"
    echo "  To install or reinstall the PMon Daemon (server) in the specified"
    echo "  directory or, by default, in the same directory than this script."
    echo ""
}

#-------------------------------------------------------------------------------
function cleanup()
{
    [ -e "$TMP_FILE" ] && rm -f "$TMP_FILE"
    [ -e "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

#-------------------------------------------------------------------------------
function die()
{
    local code=$1
    shift
    local msg=$@

    cleanup

    [ "$code" != "0" ] && msg="*** ERROR: $msg"
    echo "$msg"
    exit $code
}

#-------------------------------------------------------------------------------
function cmp_files()
{
    # returns 0 when files are equal or a non null value otherwise

    local a=$1
    local b=$2
    local tmpa
    local tmpb

    # check size
    tmpa=$(stat -c%s "$a")
    tmpb=$(stat -c%s "$b")
    [ "$tmpa" != "$tmpb" ] && return 1

    # check content byte-per-byte
    if [ which cmp &> /dev/null ]; then
        cmp --quiet "$a" "$b"
        return $?
    elif [ which md5sum &> /dev/null ]; then
        tmpa=$(md5sum "$a" | cut -d' ' -f1)
        tmpb=$(md5sum "$b" | cut -d' ' -f1)
        [ "$tmpa" == "$tmpb" ] && return 0
        return 1
    else
        die 1 "Could not find a way to compare files on a byte-per-byte basis. Please install either 'cmp' or 'md5sum' command!"
    fi
}

#-------------------------------------------------------------------------------
function svn_get()
{
    [ -e "$TMP_DIR/svnexport" ] || mkdir -p "$TMP_DIR/svnexport"

    # export content of the svn repository
    echo "Fecthing SVN copy from $SVN_REPOSITORY_URL (rev $REVISION)..."
    while [ -z "$SVNUSER" ]; do read -p "SVN username? " SVNUSER; done
    svn export \
        --force \
        --revision $REVISION \
        --username "$SVNUSER" \
        --no-auth-cache \
        "$SVN_REPOSITORY_URL" "$TMP_DIR/svnexport" > "$TMP_FILE"
    [ $? -eq 0 ] || die 1 "Failed to fetch SVN copy!"
    echo

    # extract revision number
    REVISION=$(cat "$TMP_FILE" | grep -e "^Exported revision [0-9]\+\.\$" | cut -d' ' -f3 | tr -d '.')
    rm -f "$TMP_FILE"
    [ -z "$REVISION" ] && die 1 "Failed to get SVN revision number!"
    echo "Exported revision $REVISION."

    # keep trace of the revision number
    echo "$REVISION" > "$TMP_DIR/svnexport/.revision"
    date '+%Y-%m-%d %H:%M:%S' > "$TMP_DIR/svnexport/.timestamp"

    echo
}

#-------------------------------------------------------------------------------
function pre_install()
{
    [ -e "$INSTALL_DIR" -a -d "$INSTALL_DIR" -a -w "$INSTALL_DIR" ] || \
        die 1 "Cannot find destination directory $INSTALL_DIR!"

    # leave if we are inside a local copy of a repository
    [ -d "$INSTALL_DIR/.svn" ] && \
        die 1 "Cannot install over a local copy of an SVN repository!"

    # backup user's files
    [ -e "$INSTALL_DIR/etc" ] && mv "$INSTALL_DIR/etc" "$TMP_DIR/"

    # cleanup installation directory
    rm -rf "$INSTALL_DIR/*" "$INSTALL_DIR/.*" || \
        die 1 "Failed to cleanup $INSTALL_DIR!"
}

#-------------------------------------------------------------------------------
function do_install()
{
    local first_install=1
    local tmp

    # install revision files
    mv -f "$TMP_DIR/svnexport/.revision" "$INSTALL_DIR/"
    mv -f "$TMP_DIR/svnexport/.timestamp" "$INSTALL_DIR/"

    # restore user's files that were originally installed if needed
    if [ -e "$TMP_DIR/etc" ]; then
        first_install=0
        mv -f "$TMP_DIR/etc" "$INSTALL_DIR/"
    fi

    # create directories structure
    [ -e "$INSTALL_DIR/etc" ] || mkdir -p "$INSTALL_DIR/etc"
    if [ $INSTALL_AGENT -ne 0 ]; then
        [ -e "$INSTALL_DIR/etc/scrips-available" ] || mkdir "$INSTALL_DIR/etc/scrips-available"
        [ -e "$INSTALL_DIR/etc/scrips-daily" ] || mkdir "$INSTALL_DIR/etc/scrips-daily"
        [ -e "$INSTALL_DIR/etc/scrips-hourly" ] || mkdir "$INSTALL_DIR/etc/scrips-hourly"
        [ -e "$INSTALL_DIR/etc/scrips-minute" ] || mkdir "$INSTALL_DIR/etc/scrips-minute"
        [ -e "$INSTALL_DIR/etc/scrips-minute" ] || die 1 "Failed to create directories in $INSTALL_DIR/etc!"
    fi

    # install config files
    tmp=
    [ $INSTALL_AGENT -ne 0 ] && tmp=$tmp pmona
    [ $INSTALL_DAEMON -ne 0 ] && tmp=$tmp pmond
    if [ -n "$tmp" ]; then
        for name in $tmp; do
            if [ -e "$INSTALL_DIR/etc/$name.conf" ]; then
                mv -f "$TMP_DIR/svnexport/$name.sample.conf" "$INSTALL_DIR/etc/"
            else
                mv "$TMP_DIR/svnexport/$name.sample.conf" "$INSTALL_DIR/etc/$name.conf"
            fi
        done
    fi

    # install scripts in the 'available' directory
    if [ $INSTALL_AGENT -ne 0 ]; then
        for srcfile in $TMP_DIR/svnexport/scripts/*; do
            local destfile="$INSTALL_DIR/etc/scrips-available/$(basename "$srcfile")"
            if [ -e "$destfile" ]; then
                cmp_files "$srcfile" "$destfile"
                [ $? -ne 0 ] && destfile="$destfile.dist"
            fi
            mv -f "$srcfile" "$destfile"
        done

        # if it is the first time we install, create default links to the
        # scripts we want to run
        if [ $first_install -eq 0 ]; then
            # TODO @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            echo > /dev/null
        fi
    fi

    # install agent's perl files
    if [ $INSTALL_AGENT -ne 0 ]; then
        [ -e "$INSTALL_DIR/bin" ] && mkdir -p "$INSTALL_DIR/bin"
        for fname in pmona.pl; do
            mv -f "$TMP_DIR/svnexport/$fname" "$INSTALL_DIR/bin/"
        done
        chmod 0750 "$INSTALL_DIR/bin/pmona.pl"
    fi

    # install daemon's perl files
    if [ $INSTALL_DAEMON -ne 0 ]; then
        [ -e "$INSTALL_DIR/bin" ] && mkdir -p "$INSTALL_DIR/bin"
        for fname in PMon pmond.pl pmond.sh; do
            mv -f "$TMP_DIR/svnexport/$fname" "$INSTALL_DIR/bin/"
        done
        chmod 0750 "$INSTALL_DIR/bin/pmond.pl"
        chmod 0750 "$INSTALL_DIR/bin/pmond.sh"
    fi

    chmod -R o-rwx "$INSTALL_DIR"
}



#-------------------------------------------------------------------------------
ACTION="$1"
INSTALL_DIR="$2"
REVISION="$3"

[ -z "$ACTION" ] && usage && exit 1
[ -z "$INSTALL_DIR" ] && INSTALL_DIR=$THIS_SCRIPT_DIR
[ -z "$REVISION" ] && REVISION="HEAD"

for cmd in which basename bash cat chmod chown cut date dirname head grep mv readlink rm stat svn tr; do
    which $cmd &> /dev/null
    [ $? -eq 0 ] || die 1 "Required command '$cmd' not found!"
done

if [ -z "$PMON_CONFIG_BOOSTRAPPED_FROM" ]; then
    cleanup
    svn_get
    s=$TMP_DIR/svnexport/config.sh
    [ -e "$s" ] || die 1 "Could not find config script $s!"
    chmod 0750 "$s"
    PMON_CONFIG_BOOSTRAPPED_FROM="$THIS_SCRIPT" bash -- "$s" $*
    exit $?
fi

case "$ACTION" in
    uninstall|clean)
        uninstall
        ;;
    install-all)
        INSTALL_AGENT=1
        INSTALL_DAEMON=1
        pre_install
        do_install
        ;;
    install-agent)
        INSTALL_AGENT=1
        pre_install
        do_install
        ;;
    install-daemon)
        INSTALL_DAEMON=1
        pre_install
        do_install
        ;;
    *)
        die 1 "Unknown action \"$ACTION\"!"
        ;;
esac

cleanup
exit 0
