#!/bin/bash
### BEGIN INIT INFO
# Provides:          tc-mounter
# Required-Start:    $local_fs fuse
# Required-Stop:     $local_fs fuse
# X-Start-Before:    apache2
# X-Stop-After:      apache2
# X-Interactive:     true
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: TrueCrypt volumes u/mounter
# Description:       TrueCrypt volumes u/mounter, asks for a
#                    passwd and then mounts all volumes.
#                    NB: Do not export volumes via NFS.
### END INIT INFO

# Author: Alberto Cavalin <root@localhost>

# ----- HOWTO ------------------------------------------------------------------
# http://wiki.debian.org/LSBInitScripts
# http://wiki.debian.org/LSBInitScripts/DependencyBasedBoot
# http://en.wikipedia.org/wiki/Runlevel
#
# rc?.d setup:
#   old: update-rc.d tc-mounter defaults 90 10
#   new: insserv tc-mounter
#
# /usr/share/insserv/check-initd-order -g    | dot -Tpng -oboot.png
# /usr/share/insserv/check-initd-order -g -k | dot -Tpng -oreboot.png
# ------------------------------------------------------------------------------

# Do NOT "set -e"

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="TrueCrypt volumes u/mounter"
NAME=tc-mounter
TCDIR=/opt/myapps/lnx/truecrypt
DAEMON=$TCDIR/$NAME.rb
SCRIPTNAME=/etc/init.d/$NAME

# Exit if the package is not installed
[ -x "$DAEMON" ] || exit 0

# Read configuration variable file if it is present
[ -r /etc/default/$NAME ] && . /etc/default/$NAME

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.0-6) to ensure that this file is present.
. /lib/lsb/init-functions

#
# Function that starts the daemon/service
#
do_start()
{
  # esegui fsck se si e' nella fase di boot
  [ `ps ax | grep getty | wc -l` -le 1 ] && argument="fsck+mount"

  # Return
  #   0 if daemon has been started
  #   1 if daemon was already running
  #   2 if daemon could not be started
  start-stop-daemon --start --quiet --exec $DAEMON --test > /dev/null \
    || return 1
  start-stop-daemon --start --quiet --exec $DAEMON -- $argument \
    || return 2
  # Add code here, if necessary, that waits for the process to be ready
  # to handle requests from services started subsequently which depend
  # on this one.  As a last resort, sleep for some time.
}

#
# Function that stops the daemon/service
#
do_stop()
{
  sync
  # Return
  #   0 if daemon has been stopped
  #   1 if daemon was already stopped
  #   2 if daemon could not be stopped
  #   other if a failure occurred
  $DAEMON umount
  [ "$?" = 0 ] && return 0

  # try forcing umount
  $DAEMON umount force
  [ "$?" = 0 ] && return 0
  
  # drop in shell in case we are unable to umount volumes
  log_failure_msg "Unable to umount TC volumes, spawning maintenance shell."
  if ! sulogin
  then
    log_failure_msg "Attempt to start maintenance shell failed. Will continue in 5 seconds."
    sleep 5
  fi

  return 2
}

case "$1" in
  status)
  $TCDIR/bin/truecrypt -t -l
  ;;
  start)
  [ "$VERBOSE" != no ] && log_daemon_msg "Starting $DESC" "$NAME"
  #do_start
  true
  case "$?" in
    0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
    2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
  esac
  ;;
  stop)
  [ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
  #do_stop
  true
  case "$?" in
    0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
    2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
  esac
  ;;
  restart)
  log_daemon_msg "Restarting $DESC" "$NAME"
  do_stop
  case "$?" in
    0|1)
    sleep 1
    do_start
    case "$?" in
      0) log_end_msg 0 ;;
      1) log_end_msg 1 ;; # Old process is still running
      *) log_end_msg 1 ;; # Failed to start
    esac
    ;;
    *)
      # Failed to stop
    log_end_msg 1
    ;;
  esac
  ;;
  *)
  echo "Usage: $SCRIPTNAME {start|stop|restart|status}" >&2
  exit 3
  ;;
esac

:
