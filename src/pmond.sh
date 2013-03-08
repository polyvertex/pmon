#!/bin/bash
#
# Author:     Jean-Charles Lefebvre
# Created On: 2013-02-23 15:41:21Z
#
# $Id$
#
### BEGIN INIT INFO
# Provides:          pmon
# Required-Start:
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: PMon
# Description:       Start/Stop PMon daemon.
### END INIT INFO

# get the real path of __FILE__
# BEWARE: don't call 'cd' before running this code or the result may be incorrect
SOURCE=${BASH_SOURCE[0]}
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
    DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
    SOURCE=$(readlink "$SOURCE")
    # if $SOURCE was a relative symlink, we need to resolve it relative to the
    # path where the symlink file was located
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
ROOT_DIR=$(cd -P "$(dirname "$DIR")" && pwd)

# name of the daemon
NAME=pmond
#NAME=$(basename "$0")
#NAME=${NAME%.*}

# configuration
CONFIG_FILE="$ROOT_DIR/etc/${NAME}.conf"
PID_FILE="$ROOT_DIR/var/${NAME}.pid"
LOG_FILE="$ROOT_DIR/var/${NAME}.log"
RELOADCONF_SIGNAL=USR1


#-------------------------------------------------------------------------------
read_pid()
{
    local pid=0

    if [ -f "$PID_FILE" -a -r "$PID_FILE" ]; then
        read -r FIRSTLINE < "$PID_FILE"
        [[ "$FIRSTLINE" =~ ^[0-9]+$ ]] && pid=$FIRSTLINE
    fi

    echo -n $pid
}

#-------------------------------------------------------------------------------
status()
{
    local pid=$(read_pid)

    if [ -e "/proc/$pid" ]; then
        echo "The '$NAME' daemon is running (pid $pid)."
    else
        echo "Daemon is not running."
        if [ -e "$PID_FILE" ]; then
            echo "Removing obsolete pid file $PID_FILE."
            rm "$PID_FILE"
        fi
    fi
}

#-------------------------------------------------------------------------------
stop()
{
    local pid=$(read_pid)

    if [ "$pid" != "0" ]; then
        echo -n "Shutting down '$NAME' (pid $pid)"
        while [ -e "/proc/$pid" ]; do
            echo -n "."
            kill -TERM "$pid"
            sleep 1
        done
        echo
        [ -e "$PID_FILE" ] && rm "$PID_FILE"
    fi

    return 0
}

#-------------------------------------------------------------------------------
start()
{
    local pid=$(read_pid)

    if [ -e "/proc/$pid" ]; then
        echo "The '$NAME' daemon is already running (pid $pid) !"
        return 1
    fi

    perl "${DIR}/${NAME}.pl" \
        --config "$CONFIG_FILE" \
        --log "$LOG_FILE" \
        --pid "$PID_FILE" \
        $*
    return $?
}

#-------------------------------------------------------------------------------
reload()
{
    local pid=$(read_pid)

    if [ -e "/proc/$pid" ]; then
        kill -$RELOADCONF_SIGNAL $pid
    else
        start
        return $?
    fi
}

#-------------------------------------------------------------------------------
ACTION=$1
shift

case "$ACTION" in
    start)
        start $*
        ;;
    stop)
        stop
        ;;
    reload)
        reload
        ;;
    restart)
        stop
        start $*
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {start|stop|reload|restart|status} [daemon start parameters]"
        ;;
esac

exit 0
