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
INSTALL_STAGE=0
TMP_DIR=""
TMP_DIR_INSTALLSRC=""
TMP_FILE=""
TMP="" # no special purpose, a unique swap variable used thorough this script


#-------------------------------------------------------------------------------
function usage()
{
    echo "Usage:"
    echo ""
    echo "* $THIS_SCRIPT_NAME install-all [install_dir] [revision]"
    echo "  To install or update the PMon Daemon (server) and the PMon Agent"
    echo "  altogether in the specified directory or, by default, in the same"
    echo "  directory than this script."
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
    [ -n "$TMP_FILE" -a  -e "$TMP_FILE" ] && rm -f "$TMP_FILE"
    [ -n "$TMP_DIR_INSTALLSRC" -a  -e "$TMP_DIR_INSTALLSRC" ] && rm -rf "$TMP_DIR_INSTALLSRC"
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

    if [ -n "$TMP_DIR" -a -e "$TMP_DIR" ]; then
        echo
        echo "Note: You will have to remove the temp dir manually ($TMP_DIR)."
        echo "      Sorry for the inconvenience."
        echo "      You can run the following command to do that:"
        echo "      rm -rf \"$TMP_DIR\""
    fi

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
#    type cmp &> /dev/null
#    if [ $? -eq 0 ]; then
#        cmp --quiet "$a" "$b"
#        return $?
#    else
#        type md5sum &> /dev/null
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

    TMP_DIR_INSTALLSRC="$TMP_DIR/installsource"
}

#-------------------------------------------------------------------------------
function fetch_install_files()
{
    local configscript="$1"

    [ -e "$TMP_DIR_INSTALLSRC" ] || mkdir -p "$TMP_DIR_INSTALLSRC"

    # export content of the svn repository
    echo "Fecthing SVN copy from $SVN_REPOSITORY_URL (rev $REVISION)..."
    #while [ -z "$SVNUSER" ]; do read -p "SVN username? " SVNUSER; done
    #--username "$SVNUSER" --no-auth-cache \
    svn export \
        --force \
        --revision $REVISION \
        "$SVN_REPOSITORY_URL" "$TMP_DIR_INSTALLSRC" > "$TMP_FILE"
    [ $? -eq 0 ] || die 1 "Failed to fetch SVN copy!"
    echo

    # extract revision number
    REVISION=$(grep '^Exported revision' "$TMP_FILE" | cut -d' ' -f3 | tr -d '.')
    #rm -f "$TMP_FILE"
    [ -z "$REVISION" ] && die 1 "Failed to get SVN revision number!"
    echo "Downloaded revision $REVISION."

    # keep trace of the revision number
    echo "$REVISION" > "$TMP_DIR_INSTALLSRC/.revision"
    date '+%Y-%m-%d %H:%M:%S' > "$TMP_DIR_INSTALLSRC/.timestamp"

    # ensure the config script exists and is executable
    [ -e "$configscript" ] || die 1 "Updated install script does not exist \"$configscript\"!"
    chmod 0750 "$configscript"
    [ -x "$configscript" ] || die 1 "Updated install script is not executable \"$configscript\"!"
}

#-------------------------------------------------------------------------------
function install_stage_1()
{
    # check destination directory (first pass)
    if [ ! -e "$INSTALL_DIR" ]; then
        if [ -e "$(dirname "$INSTALL_DIR")" ]; then
            echo "Creating destination directory: $INSTALL_DIR"
            mkdir "$INSTALL_DIR"
        else
            # safer not to use 'mkdir -p' here...
            die 1 "Parent directory of $INSTALL_DIR does not exist! Please create it first."
        fi
    fi

    # check destination directory (second pass)
    [ -e "$INSTALL_DIR" -a -w "$INSTALL_DIR" ] || \
        die 1 "Destination directory '$INSTALL_DIR' does not exist!"

    # die if destination dir is a local copy of a repository
    [ -d "$INSTALL_DIR/.svn" -o -d "$INSTALL_DIR/.git" ] && \
        die 1 "Cannot install over a local copy of an SVN repository!"

    # copy this script into the install dir
    cp -f "$THIS_SCRIPT" "$INSTALL_DIR/$THIS_SCRIPT_NAME"
    chmod 0750 "$INSTALL_DIR/$THIS_SCRIPT_NAME"
    [ -e "$INSTALL_DIR/$THIS_SCRIPT_NAME" -a -x "$INSTALL_DIR/$THIS_SCRIPT_NAME" ] || \
        die 1 "$INSTALL_DIR/$THIS_SCRIPT_NAME does not exist or is not executable (stage $INSTALL_STAGE)!"
}

#-------------------------------------------------------------------------------
function install_stage_2()
{
    local first_install_daemon=1
    local first_install_agent=1
    local restart_daemon=0
    local tmp


    # some third-party commands will be used by the agent
    # hope we won't fail to keep this list actualized...
    if [ $INSTALL_AGENT -ne 0 ]; then
        for cmd in cat df free grep hddtemp head ls ps smartctl uname; do
            type $cmd &> /dev/null
            [ $? -eq 0 ] || die 1 "Command '$cmd' not found! It is used by the Agent."
        done
    fi

    # wait for agent to finish before we go further
    if [ $INSTALL_AGENT -ne 0 -a -e "$INSTALL_DIR/var/pmona.pid" ]; then
        tmp=$(< "$INSTALL_DIR/var/pmona.pid")
        echo -n "Waiting for running agent to finish before continuing (pid $tmp)..."
        while [ -e "/proc/$tmp" ]; do echo -n "." && sleep 1; done
        echo
    fi

    # delete agent's binary config file
    [ $INSTALL_AGENT -ne 0 -a -e "$INSTALL_DIR/var/pmona.conf.bin" ] && \
        rm -f "$INSTALL_DIR/var/pmona.conf.bin"

    # shutdown daemon in case we want to reinstall it
    if [ $INSTALL_DAEMON -ne 0 -a -e "$INSTALL_DIR/bin/pmond.sh" -a -e "$INSTALL_DIR/var/pmond.pid" ]; then
        tmp=$(< "$INSTALL_DIR/var/pmond.pid")
        if [ -e "/proc/$tmp" ]; then
            restart_daemon=1
            echo "Try to stop daemon before upgrading it (pid $tmp)..."
            "$INSTALL_DIR/bin/pmond.sh" stop
        fi
    fi

    # first install?
    [ -e "$INSTALL_DIR/bin/pmond.pl" ] && first_install_daemon=0
    [ -e "$INSTALL_DIR/bin/pmona.pl" ] && first_install_agent=0

    # cleanup destination directory (do not 'set -e' here!)
    rm -f "$INSTALL_DIR/etc/*.dist" &> /dev/null
    rm -f "$INSTALL_DIR/var/*.pid" &> /dev/null
    mv -f "$INSTALL_DIR/var/pmond.log" "$INSTALL_DIR/var/pmond.log.1" &> /dev/null
    [ $INSTALL_AGENT -ne 0 -a $INSTALL_DAEMON -ne 0 ] && \
        rm -rf "$INSTALL_DIR/bin" &> /dev/null

    # install revision files
    mv -f "$TMP_DIR_INSTALLSRC/.revision" "$INSTALL_DIR/"
    mv -f "$TMP_DIR_INSTALLSRC/.timestamp" "$INSTALL_DIR/"

    # create directories structure
    [ -e "$INSTALL_DIR/bin" ] || mkdir "$INSTALL_DIR/bin"
    [ -e "$INSTALL_DIR/bin" ] || die 1 "Failed to create main directories structure in $INSTALL_DIR!"
    [ -e "$INSTALL_DIR/etc" ] || mkdir "$INSTALL_DIR/etc"
    [ -e "$INSTALL_DIR/var" ] || mkdir "$INSTALL_DIR/var"
    if [ $INSTALL_AGENT -ne 0 ]; then
        [ -e "$INSTALL_DIR/etc/scripts" ] || mkdir "$INSTALL_DIR/etc/scripts"
    fi

    # install config files
    tmp=""
    [ $INSTALL_AGENT -ne 0 ] && tmp="$tmp pmona"
    [ $INSTALL_DAEMON -ne 0 ] && tmp="$tmp pmond"
    if [ -n "$tmp" ]; then
        for name in $tmp; do
            local srcfile="$TMP_DIR_INSTALLSRC/$name.sample.conf"
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
        for srcfile in $TMP_DIR_INSTALLSRC/scripts/*; do
            local destfile="$INSTALL_DIR/etc/scripts/$(basename "$srcfile")"
            mv -f "$srcfile" "$destfile"
            chmod 0750 "$destfile"
        done
    fi

    # install agent's binary files
    if [ $INSTALL_AGENT -ne 0 ]; then
        for fname in pmona.pl; do
            mv -f "$TMP_DIR_INSTALLSRC/$fname" "$INSTALL_DIR/bin/"
        done
        chmod 0750 "$INSTALL_DIR/bin/pmona.pl"

        # embed the Config module into the main script
        echo >> "$INSTALL_DIR/bin/pmona.pl"
        cat "$TMP_DIR_INSTALLSRC/PMon/Config.pm" >> "$INSTALL_DIR/bin/pmona.pl"
        [ $? -eq 0 ] || die 1 "Failed to embed Config module into pmona.pl!"
    fi

    # install daemon's binary files
    if [ $INSTALL_DAEMON -ne 0 ]; then
        for fname in PMon pmond.pl pmond.sh; do
            [ -d "$INSTALL_DIR/bin/$fname" ] && rm -rf "$INSTALL_DIR/bin/$fname"
            mv -f "$TMP_DIR_INSTALLSRC/$fname" "$INSTALL_DIR/bin/"
        done
        chmod 0750 "$INSTALL_DIR/bin/pmond.pl"
        chmod 0750 "$INSTALL_DIR/bin/pmond.sh"
    fi

    # daemon: try to create the /etc/init.d symlink
    if [ $INSTALL_DAEMON -ne 0 -a -d "/etc/init.d" ]; then
        echo "Creating /etc/init.d/pmond symlink..."
        ln -sf "$INSTALL_DIR/bin/pmond.sh" "/etc/init.d/pmond"
    fi

    # touch flag files to notify daemon/agent that this is a fresh install
    [ $INSTALL_AGENT -ne 0 ] && touch "$INSTALL_DIR/var/.installed-agent"
    [ $INSTALL_DAEMON -ne 0 ] && touch "$INSTALL_DIR/var/.installed-daemon"

    # adjust access rights
    chmod -R o-rwx "$INSTALL_DIR"

    # try to restart daemon if needed
    if [ $restart_daemon -ne 0 ]; then
        echo "Try to restart daemon..."
        "$INSTALL_DIR/bin/pmond.sh" start
    fi

    echo
    echo "Installation done."
    echo
    if [ $INSTALL_DAEMON -ne 0 -o $INSTALL_AGENT -ne 0 ]; then
        echo "You may have to perform the following steps manually to finish your installation:"
        if [ $INSTALL_DAEMON -ne 0 ]; then
            echo "* Check daemon's config:"
            echo "    $INSTALL_DIR/etc/pmond.conf"
            echo "* Launch daemon if not done already:"
            echo "    $INSTALL_DIR/bin/pmond.sh restart"
            echo "* Configure your system to ensure daemon will be launched after reboot"
            echo "  The details depend on your distro"
        fi
        if [ $INSTALL_AGENT -ne 0 ]; then
            echo "* Check agent's config:"
            echo "    $INSTALL_DIR/etc/pmona.conf"
            echo "* Configure root's cron to run the agent every minutes:"
            echo "    */1 * * * * $INSTALL_DIR/bin/pmona.pl > /dev/null"
        fi
        echo
    fi
}



#-------------------------------------------------------------------------------
for cmd in basename bash cat chmod chown cp cut date dirname head grep ln mktemp mv readlink rm stat svn touch tr; do
    type $cmd &> /dev/null
    [ $? -eq 0 ] || die 1 "Required command '$cmd' not found!"
done

# special running cases to perform minimalistic actions
# if you modify this section, it is more likely that the user will have to
# download and overwrite his own local copy of this script before being able
# to install/upgrade whithout any trouble...
if [ "$1" == "priv-install-stage1" ]; then
    INSTALL_STAGE=1
    echo "Entered stage $INSTALL_STAGE ($THIS_SCRIPT)..."
    TMP_DIR="$2"
    TMP="$3" # the original calling script (we want to delete it)
    rm -f "$TMP" &> /dev/null
    [ -d "$TMP_DIR" ] || die 1 "Given temp dir does not exists (stage $INSTALL_STAGE; $TMP_DIR)!"
    shift 3
elif [ "$1" == "priv-install-stage2" ]; then
    INSTALL_STAGE=2
    echo "Entered stage $INSTALL_STAGE ($THIS_SCRIPT)..."
    TMP_DIR="$2"
    [ -d "$TMP_DIR" ] || die 1 "Given temp dir does not exists (stage $INSTALL_STAGE; $TMP_DIR)!"
    shift 2
#elif [ "$1" == "priv-rm" ]; then
#    shift
#    while [ -n "$1" ]; do
#        [ -e "$1" ] && rm -rf "$1"
#        shift
#    done
#    exit 0
#elif [ "$1" == "priv-waitpid-and-rm" ]; then
#    pid="$2"
#    shift 2
#    while [ -e "/proc/$pid" ]; do sleep 1; done
#    while [ -n "$1" ]; do
#        [ -e "$1" ] && rm -rf "$1"
#        shift
#    done
#    exit 0
fi


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
        ;;
    install-agent)
        INSTALL_AGENT=1
        INSTALL_DAEMON=0
        ;;
    install-daemon)
        INSTALL_AGENT=0
        INSTALL_DAEMON=1
        ;;
esac

case "$ACTION" in
    install-all|install-agent|install-daemon)
        tmp=$(readlink -f "$INSTALL_DIR")
        [ "$tmp" == "/" ] && die 1 "You want to install into '/'?! Sure..."
        init_vars
        if [ $INSTALL_STAGE -eq 0 ]; then
            # init stage: download fresh installable content to TMP_DIR, then
            # fork to the (maybe) new version of THIS_SCRIPT located in the
            # TMP_DIR, passing all the parameters we've got from the user.
            fetch_install_files "$TMP_DIR_INSTALLSRC/config.sh" # safer to hard-code the name of the script here!
            exec "$TMP_DIR_INSTALLSRC/config.sh" \
                "priv-install-stage1" "$TMP_DIR" \
                "$THIS_SCRIPT" "$ACTION" "$INSTALL_DIR" "$REVISION"
        elif [ $INSTALL_STAGE -eq 1 ]; then
            # first stage: THIS_SCRIPT is now running from TMP_DIR. our only
            # goal here is to copy THIS_SCRIPT to the INSTALL_DIR and then
            # run the installed script from the INSTALL_DIR in order to initiate
            # the final stage.
            # we continue to pass original parameters given by the user.
            install_stage_1
            exec "$INSTALL_DIR/$THIS_SCRIPT_NAME" \
                "priv-install-stage2" "$TMP_DIR" \
                "$ACTION" "$INSTALL_DIR" "$REVISION"
        elif [ $INSTALL_STAGE -eq 2 ]; then
            # second stage: we are running from the install dir and we are ready
            # to install... after the install process, since we cannot delete
            # THIS_SCRIPT (we are running it), we ask the installed version of
            # THIS_SCRIPT to do it.
            install_stage_2
            cleanup
        fi
        ;;
    *)
        die 1 "Unknown action \"$ACTION\"!"
        ;;
esac

# do not cleanup() here!
# it is up to each ACTION to decide if we must cleanup() or not.

exit 0
