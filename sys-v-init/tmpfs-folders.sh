#! /bin/sh
### BEGIN INIT INFO
# Provides:          tmpfs-folders
# Required-Start:    mountall
# Required-Stop:     
# Should-Start:      
# Should-Stop:       
# X-Start-Before:    mountall-bootclean networking $network rsyslog $syslog
# X-Stop-After:      
# X-Interactive:     true
# Default-Start:     S
# Default-Stop:      0 6
# Short-Description: TMPfs directory mounter
# Description:       This initscript can bind directories in a tmpfs ramdisk, the
#                    primary goal is to allow laptop users to let the hard-disk
#                    drive spin up most of the time, it can also be used by people
#                    having their system on a USB disk or a CF card.
### END INIT INFO

# Author: Alberto Cavalin <root@localhost>

# ----- HOWTO ------------------------------------------------------------------
# http://wiki.debian.org/LSBInitScripts
# http://wiki.debian.org/LSBInitScripts/DependencyBasedBoot
# http://en.wikipedia.org/wiki/Runlevel
#
# install service:
#   insserv tmpfs-folders
#
# /usr/share/insserv/check-initd-order -g    | dot -Tpng -oboot.png
# /usr/share/insserv/check-initd-order -g -k | dot -Tpng -oreboot.png
# ------------------------------------------------------------------------------
# source:
#   http://forums.debian.net/viewtopic.php?t=16450
#
# directory skeleton:
#   find /var/log -path /var/log/installer -prune -o -type f -exec dd if=/dev/null of="{}" \;
#   find /var/log -name "*.[0-9].gz" -exec rm -f "{}" \;
#   cd /var && find log -type d | tar -czvf /tmp/var.tgz --no-recursion --files-from -
# ------------------------------------------------------------------------------

# Do NOT "set -e"

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/bin
DESC="TMPfs directory mounter"
NAME=tmpfs-folders
SCRIPTNAME=/etc/init.d/$NAME

RAM_ROOT=/run/shm
RAM_DIR=$RAM_ROOT/$NAME
DATA_DIR=/opt/myapps/lnx/$NAME

# Read configuration variable file if it is present
[ -r /etc/default/$NAME ] && . /etc/default/$NAME

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.2-14) to ensure that this file is present
# and status_of_proc is working.
. /lib/lsb/init-functions

#
# Function that starts the daemon/service
#
do_start()
{
  # Return
  #   0 if daemon has been started
  #   1 if daemon was already running
  #   2 if daemon could not be started

  if grep -qs $RAM_ROOT /proc/mounts; then
    [ -d $RAM_DIR ] && return 1

    mkdir -p $RAM_DIR

    # /tmp gia' in RAM via /etc/default/tmpfs
    #mkdir -m 777 -p $RAM_DIR/temp
    #mount --bind    $RAM_DIR/temp /tmp || return 2

    # /var/(log|run|lock)
    mkdir -p $RAM_DIR/var
    tar   -C $RAM_DIR/var -xzf "$DATA_DIR/var.tgz" || return 2
    mount --bind $RAM_DIR/var/log  /var/log        || return 2
    # run e lock son gia' in RAM via /etc/default/tmpfs
    #mount --bind $RAM_DIR/var/run  /var/run        || return 2
    #mount --bind $RAM_DIR/var/lock /var/lock       || return 2

    # /home -> $RAM_DIR/home
    mkdir -m 775 -p     $RAM_DIR/home
    chown -R root.users $RAM_DIR/home

    # /home/cloud
    (
      cp -ra /etc/skel              $RAM_DIR/home/cloud         && \
      ln -sf /opt/myapps/bin        $RAM_DIR/home/cloud/bin     && \
      echo ". /opt/bash_profile" >> $RAM_DIR/home/cloud/.bashrc && \
      chmod 750                     $RAM_DIR/home/cloud         && \
      chown -R cloud.cloud          $RAM_DIR/home/cloud
    ) || return 2
    
    # /root -> $RAM_DIR/root_home
    mkdir -m 755 -p $RAM_DIR/root_home       || return 2
    mount --bind    $RAM_DIR/root_home /root || return 2
    tar          -C $RAM_DIR/root_home       \
        -xzf /opt/myapps/lnx/tmpfs-folders/root_home.tgz || return 2

    # /mnt/ramd
    mkdir -m 777 -p $RAM_DIR/ramd         || return 2
    mount --bind  $RAM_DIR/ramd /mnt/ramd || return 2
    mount -o remount,suid,exec /mnt/ramd/ 2> /dev/null

    # extra ramdisk
    #mkdir -m 777 -p $RAM_DIR/extra          || return 2

    return 0
  else
    return 2
  fi
}

case "$1" in
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
    true
    ;;
  *)
    echo "Usage: $SCRIPTNAME {start|stop}" >&2
    exit 3
    ;;
esac

:
