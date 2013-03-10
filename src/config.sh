#!/usr/bin/env bash
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-02-27 10:14:17Z
#
# $Id$
#

# configuration
SVN_REPOSITORY_URL="https://svn.jcl.io/pmon/trunk/src/"


#-------------------------------------------------------------------------------
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

# global parameters
ACTION=""
REVISION=""
INSTALL_DIR=""
INSTALL_AGENT=0
INSTALL_DAEMON=0

# global variables
TMP_DIR=""
TMP_DIR_SVNCOPY=""
TMP_FILE=""


#-------------------------------------------------------------------------------
function usage()
{
    echo "Usage:"
    echo ""
    echo "* $THIS_SCRIPT_NAME install-all [install_dir] [revision]"
    echo "  To install or update the PMon Daemon (server) and the PMon Agent"
    echo "  altogether in the specified directory or, by default, in the same"
    echo "  directory than this scripts."
    echo ""
    echo "* $THIS_SCRIPT_NAME install-agent [install_dir] [revision]"
    echo "  To install or update the PMon Agent in the specified directory or,"
    echo "  by default, in the same directory than this script."
    echo ""
    echo "* $THIS_SCRIPT_NAME install-daemon [install_dir] [revision]"
    echo "  To install or update the PMon Daemon (server) in the specified"
    echo "  directory or, by default, in the same directory than this script."
    echo ""
}

#-------------------------------------------------------------------------------
function cleanup()
{
    [ -n "$TMP_DIR" -a  -e "$TMP_DIR" ] && rm -rf "$TMP_DIR"
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
#function cmp_files()
#{
#    # returns 0 when files are equal or a non null value otherwise
#
#    local a=$1
#    local b=$2
#    local tmpa
#    local tmpb
#
#    # check size
#    tmpa=$(stat -c%s "$a")
#    tmpb=$(stat -c%s "$b")
#    [ "$tmpa" != "$tmpb" ] && return 1
#
#    # check content byte-per-byte
#    which cmp &> /dev/null
#    if [ $? -eq 0 ]; then
#        cmp --quiet "$a" "$b"
#        return $?
#    else
#        which md5sum &> /dev/null
#        [ $? -eq 0 ] || die 1 "Could not find a way to compare files on a byte-per-byte basis. Please install either 'cmp' or 'md5sum' command!"
#        tmpa=$(md5sum "$a" | cut -d' ' -f1)
#        tmpb=$(md5sum "$b" | cut -d' ' -f1)
#        [ "$tmpa" == "$tmpb" ] && return 0
#        return 1
#    fi
#}

#-------------------------------------------------------------------------------
function init_vars()
{
    [ -z "$TMP_DIR" ] && TMP_DIR=$(mktemp -d)
    [ -n "$TMP_DIR" -a -d "$TMP_DIR" ] || \
        die 1 "Failed to create temp directory!"

    TMP_FILE="$TMP_DIR/tmp"
    touch "$TMP_FILE" || die 1 "Failed to create temp file!"
    rm "$TMP_FILE"

    TMP_DIR_SVNCOPY="$TMP_DIR/svncopy"
}

#-------------------------------------------------------------------------------
function svn_get()
{
    [ -e "$TMP_DIR_SVNCOPY" ] || mkdir -p "$TMP_DIR_SVNCOPY"

    # export content of the svn repository
    echo "Fecthing SVN copy from $SVN_REPOSITORY_URL (rev $REVISION)..."
    #while [ -z "$SVNUSER" ]; do read -p "SVN username? " SVNUSER; done
    #--username "$SVNUSER" --no-auth-cache \
    svn export \
        --force \
        --revision $REVISION \
        "$SVN_REPOSITORY_URL" "$TMP_DIR_SVNCOPY" > "$TMP_FILE"
    [ $? -eq 0 ] || die 1 "Failed to fetch SVN copy!"
    echo

    # extract revision number
    REVISION=$(grep '^Exported revision' "$TMP_FILE" | cut -d' ' -f3 | tr -d '.')
    #rm -f "$TMP_FILE"
    [ -z "$REVISION" ] && die 1 "Failed to get SVN revision number!"
    echo "Exported revision $REVISION."

    # keep trace of the revision number
    echo "$REVISION" > "$TMP_DIR_SVNCOPY/.revision"
    date '+%Y-%m-%d %H:%M:%S' > "$TMP_DIR_SVNCOPY/.timestamp"

    echo
}

#-------------------------------------------------------------------------------
#function fork_install()
#{
#    local configscript="$TMP_DIR_SVNCOPY/config.sh"
#
#    [ -e "$configscript" ] || die 1 "Install script not found in \"$configscript\"!"
#    [ -x "$configscript" ] || die 1 "Install script is not executable \"$configscript\"!"
#    #touch "$FORKED_FILE"
#    #[ -e "$FORKED_FILE" ] || die 1 "Could not create the 'forked' file at \"$FORKED_FILE\"!"
#
#    exec "$configscript" "$ACTION" "$INSTALL_DIR" "$REVISION"
#    exit 0
#}

#-------------------------------------------------------------------------------
function pre_install()
{
    # check destination directory
    if [ ! -e "$INSTALL_DIR" ]; then
        if [ -e "$(dirname "$INSTALL_DIR")" ]; then
            echo "Creating destination directory: $INSTALL_DIR..."
            mkdir "$INSTALL_DIR"
        else
            # safer not to use 'mkdir -p' here...
            die 1 "Parent directory of $INSTALL_DIR does not exist! Please create it first."
        fi
    fi
    [ -e "$INSTALL_DIR" ] || \
        die 1 "Destination directory '$INSTALL_DIR' does not exist!"

    # die if destination dir is a local copy of a repository
    [ -d "$INSTALL_DIR/.svn" -o -d "$INSTALL_DIR/.git" ] && \
        die 1 "Cannot install over a local copy of an SVN repository!"

    # some third-party commands will be used by the agent
    # hope we won't fail to keep this list actualized...
    if [ $INSTALL_AGENT -ne 0 ]; then
        for cmd in cat df free grep hddtemp head ls ps smartctl uname; do
            which $cmd &> /dev/null
            [ $? -eq 0 ] || die 1 "Command '$cmd' not found! It is used by the Agent."
        done
    fi

    # shutdown daemon in case we want to reinstall it
    if [ $INSTALL_DAEMON -ne 0 -a -e "$INSTALL_DIR/bin/pmond.sh" ]; then
        echo "Try to stop daemon before upgrading it..."
        "$INSTALL_DIR/bin/pmond.sh" stop
    fi
}

#-------------------------------------------------------------------------------
function do_install()
{
    local first_install_daemon=1
    local first_install_agent=1
    local tmp
    local dir_scripts_avail="$INSTALL_DIR/etc/scripts-available"
    local dir_scripts_daily="$INSTALL_DIR/etc/scripts-daily"
    local dir_scripts_hourly="$INSTALL_DIR/etc/scripts-hourly"
    local dir_scripts_minute="$INSTALL_DIR/etc/scripts-minute"

    # can we overwrite install dir?
    [ -d "$INSTALL_DIR" -a -w "$INSTALL_DIR" ] || \
        die 1 "Cannot write into \"$INSTALL_DIR\"!"

    # first install?
    [ -e "$INSTALL_DIR/bin/pmond.pl" ] && first_install_daemon=0
    [ -e "$INSTALL_DIR/bin/pmona.pl" ] && first_install_agent=0

    # cleanup destination directory (do not 'set -e' here!)
    rm -f "$INSTALL_DIR/etc/*.dist" &> /dev/null
    rm -f "$INSTALL_DIR/var/*.pid" &> /dev/null
    mv -f "$INSTALL_DIR/var/pmond.log" "$INSTALL_DIR/var/pmond.log.1" &> /dev/null
    rm -rf "$INSTALL_DIR/bin" &> /dev/null

    # install config script
    #mv -f "$TMP_DIR_SVNCOPY/config.sh" "$INSTALL_DIR/"

    # install revision files
    mv -f "$TMP_DIR_SVNCOPY/.revision" "$INSTALL_DIR/"
    mv -f "$TMP_DIR_SVNCOPY/.timestamp" "$INSTALL_DIR/"

    # create directories structure
    [ -e "$INSTALL_DIR/bin" ] || mkdir -p "$INSTALL_DIR/bin"
    [ -e "$INSTALL_DIR/etc" ] || mkdir -p "$INSTALL_DIR/etc"
    [ -e "$INSTALL_DIR/var" ] || mkdir -p "$INSTALL_DIR/var"
    [ -e "$INSTALL_DIR/bin" ] || die 1 "Failed to create main directories structure in $INSTALL_DIR!"
    if [ $INSTALL_AGENT -ne 0 ]; then
        [ -e "$dir_scripts_avail" ] || mkdir "$dir_scripts_avail"
        [ -e "$dir_scripts_daily" ] || mkdir "$dir_scripts_daily"
        [ -e "$dir_scripts_hourly" ] || mkdir "$dir_scripts_hourly"
        [ -e "$dir_scripts_minute" ] || mkdir "$dir_scripts_minute"
        [ -e "$dir_scripts_minute" ] || die 1 "Failed to create directories in $INSTALL_DIR/etc!"
    fi

    # install config files
    tmp=""
    [ $INSTALL_AGENT -ne 0 ] && tmp="$tmp pmona"
    [ $INSTALL_DAEMON -ne 0 ] && tmp="$tmp pmond"
    if [ -n "$tmp" ]; then
        for name in $tmp; do
            local srcfile="$TMP_DIR_SVNCOPY/$name.sample.conf"
            local destfile="$INSTALL_DIR/etc/$name.conf"

            if [ -e "$destfile" ]; then
                mv -f "$srcfile" "${destfile}.dist"
            else
                mv "$srcfile" "$destfile"
                [ -e "${destfile}.dist" ] && rm -f "${destfile}.dist"
            fi
        done
    fi

    # install agent's scripts
    if [ $INSTALL_AGENT -ne 0 ]; then
        for srcfile in $TMP_DIR_SVNCOPY/scripts/*; do
            local destfile="$dir_scripts_avail/$(basename "$srcfile")"
            mv -f "$srcfile" "$destfile"
            chmod 0750 "$destfile"
        done

        pushd "$dir_scripts_daily" > /dev/null || die 1 "Failed to cd to \"$dir_scripts_daily\"!"
        for name in system.sh; do
            ln -sf "../scripts-available/$name" "$name"
        done
        popd > /dev/null

        pushd "$dir_scripts_hourly" > /dev/null || die 1 "Failed to cd to \"$dir_scripts_hourly\"!"
        for name in smart.pl; do
            ln -sf "../scripts-available/$name" "$name"
        done
        popd > /dev/null

        pushd "$dir_scripts_minute" > /dev/null || die 1 "Failed to cd to \"$dir_scripts_minute\"!"
        for name in usage.pl; do
            ln -sf "../scripts-available/$name" "$name"
        done
        popd > /dev/null
    fi

    # install agent's binary files
    if [ $INSTALL_AGENT -ne 0 ]; then
        for fname in pmona.pl; do
            mv -f "$TMP_DIR_SVNCOPY/$fname" "$INSTALL_DIR/bin/"
        done
        chmod 0750 "$INSTALL_DIR/bin/pmona.pl"
    fi

    # install daemon's binary files
    if [ $INSTALL_DAEMON -ne 0 ]; then
        for fname in PMon pmond.pl pmond.sh; do
            [ -d "$INSTALL_DIR/bin/$fname" ] && rm -rf "$INSTALL_DIR/bin/$fname"
            mv -f "$TMP_DIR_SVNCOPY/$fname" "$INSTALL_DIR/bin/"
        done
        chmod 0750 "$INSTALL_DIR/bin/pmond.pl"
        chmod 0750 "$INSTALL_DIR/bin/pmond.sh"
    fi

    # touch flag files to notify daemon/agent that this is a fresh install
    [ $INSTALL_AGENT -ne 0 ] && touch "$INSTALL_DIR/var/.installed-agent"
    [ $INSTALL_DAEMON -ne 0 ] && touch "$INSTALL_DIR/var/.installed-daemon"

    # adjust access rights
    chmod -R o-rwx "$INSTALL_DIR"

    echo
    echo "Installation done."
    echo "Please do not forget to check your configuration files located in:"
    echo "$INSTALL_DIR/etc"
    echo
}



#-------------------------------------------------------------------------------
for cmd in which basename bash cat chmod chown cut date dirname head grep ln mktemp mv readlink rm stat svn touch tr; do
    which $cmd &> /dev/null
    [ $? -eq 0 ] || die 1 "Required command '$cmd' not found!"
done

# do not forget to modify the fork_install() function according to your
# changes on global parameters here!
ACTION="$1"
INSTALL_DIR="$2"
REVISION="$3"

[ -z "$ACTION" ] && usage && exit 1
[ -z "$INSTALL_DIR" ] && INSTALL_DIR="$THIS_SCRIPT_DIR"
[ -z "$REVISION" ] && REVISION="HEAD"

case "$ACTION" in
    install-all)
        INSTALL_AGENT=1
        INSTALL_DAEMON=1
        init_vars
        svn_get
        pre_install
        do_install
        ;;
    install-agent)
        INSTALL_AGENT=1
        init_vars
        svn_get
        pre_install
        do_install
        ;;
    install-daemon)
        INSTALL_DAEMON=1
        init_vars
        svn_get
        pre_install
        do_install
        ;;
    *)
        die 1 "Unknown action \"$ACTION\"!"
        ;;
esac

cleanup
exit 0
