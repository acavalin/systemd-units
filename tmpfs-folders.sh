#!/bin/sh

# SETUP INSTRUCTIONS
# ------------------------------------------------------------------------------
# /etc/fstab:
#   none  /tmp       tmpfs  defaults,user,size=512M,exec 0 0
#   none  /mnt/ramd  tmpfs  defaults,user,size=512M,exec 0 0
#
# If you get this error in your syslog at boot time:
#   systemd[1]: tmp.mount: Directory /tmp to mount over is not empty, mounting anyway.
# then add "-E PULSE_RUNTIME_PATH=/run/alsa/runtime" to /lib/udev/rules.d/90-alsa-restore.rules file.
# See also: "pulseaudio: leaves empty /tmp/pulse-* directory behind"
#   https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=561777
# ------------------------------------------------------------------------------
# If using systemd then make sure to set RemoveIPC=no in /etc/systemd/logind.conf
# see https://superuser.com/questions/1117764/why-are-the-contents-of-dev-shm-is-being-removed-automatically/1179962#1179962
# ------------------------------------------------------------------------------
# create tgz directory skeleton:
#   # see also clear_var_log.sh for crontab usage
#   ./clear_var_log.sh
#   cd /var && find log -type d | tar -czvf /opt/systemd-units/tmpfs-folders/var-empty.tgz --no-recursion --files-from -
#   cd /var && tar -czvf /opt/systemd-units/tmpfs-folders/var-full.tgz log
#   cd /opt/systemd-units/tmpfs-folders ; ln -sf var-xxxx.tgz var.tgz # choose one
#
#   cd /root && tar -czvf /opt/systemd-units/tmpfs-folders/root_home.tgz .
#   cd /home && tar -czvf /opt/systemd-units/tmpfs-folders/homes.tgz .
#
#   mkdir munin
#   cp -ra /var/lib/munin       munin/db
#   cp -ra /var/cache/munin/www munin/www
#   cp -ra /var/log/munin       munin/log
#   cp -ra /var/run/munin       munin/run
#   tar -czvf /opt/systemd-units/tmpfs-folders/munin.tgz munin
# ------------------------------------------------------------------------------

PATH=/sbin:/bin
export PATH

NAME=tmpfs-folders
RAM_ROOT=/run/shm
[ ! -d $RAM_ROOT ] && RAM_ROOT=/dev/shm
[ ! -d $RAM_ROOT ] && RAM_ROOT=/tmp
RAM_DIR=$RAM_ROOT/$NAME
DATA_DIR=/opt/systemd-units/$NAME

if grep -qs /dev/shm /proc/mounts && [ -d $RAM_ROOT ]; then
  [ -d $RAM_DIR ] && exit 1

  mkdir -p $RAM_DIR

  # /var/log
  if [ -f "$DATA_DIR/var.tgz" ]; then
    mv -f /var/log/boot.log /tmp 2> /dev/null

    # unzip skeleton
    mkdir -p $RAM_DIR/var
    tar   -C $RAM_DIR/var -xzf "$DATA_DIR/var.tgz" || exit 11
    mount --bind $RAM_DIR/var/log /var/log         || exit 12

    mv -f /tmp/boot.log /var/log/ 2> /dev/null
  fi

  # /home -> $RAM_DIR/home
  if [ -f "$DATA_DIR/homes.tgz" ]; then
    mkdir -m 775 -p     $RAM_DIR/home
    chown -R root.users $RAM_DIR/home
    # drop old dir and make a link to the new one
    rm -rf /home
    ln -sf $RAM_DIR/home/ /home
    # extract the archive of /home
    tar -C $RAM_DIR/home -xzf "$DATA_DIR/homes.tgz" || exit 21
  fi

  # /root => $RAM_DIR/root_home
  if [ -f "$DATA_DIR/root_home.tgz" ]; then
    mkdir -m 755 -p $RAM_DIR/root_home       || exit 31
    mount --bind    $RAM_DIR/root_home /root || exit 32
    tar -C $RAM_DIR/root_home -xzf "$DATA_DIR/root_home.tgz" || exit 33
  fi

  if [ -f "$DATA_DIR/munin.tgz" ]; then
    tar -C $RAM_DIR -xzf "$DATA_DIR/munin.tgz" || exit 33
  fi

  exit 0
else
  exit 2
fi
