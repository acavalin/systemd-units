#!/bin/sh

# ------------------------------------------------------------------------------
# create tgz directory skeleton:
#   find /var/log -path /var/log/installer -prune -o -type f -exec dd if=/dev/null of="{}" \;
#   find /var/log -name "*.[0-9].gz" -exec rm -f "{}" \;
#   cd /var && find log -type d | tar -czvf /tmp/var.tgz --no-recursion --files-from -
#
#   cd /root && tar -czvf /opt/systemd-units/tmpfs-folders/root_home.tgz .
#   cd /home && tar -czvf /opt/systemd-units/tmpfs-folders/homes.tgz .
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

  # /etc/fstab:
  #   none  /tmp       tmpfs  defaults,user,size=512M,exec 0 0
  #   none  /mnt/ramd  tmpfs  defaults,user,size=512M,exec 0 0

  # /var/log
  mkdir -p $RAM_DIR/var
  tar   -C $RAM_DIR/var -xzf "$DATA_DIR/var.tgz" || exit 11
  mount --bind $RAM_DIR/var/log /var/log         || exit 12

  # /home -> $RAM_DIR/home
  mkdir -m 775 -p     $RAM_DIR/home
  chown -R root.users $RAM_DIR/home
  # drop old dir and make a link to the new one
  [ -d $RAM_DIR ] && rm -rf /home
  ln -sf $RAM_DIR/home/ /home
  # extract the archive of /home
  tar -C $RAM_DIR/home -xzf "$DATA_DIR/homes.tgz" || exit 21

  # /root => $RAM_DIR/root_home
  mkdir -m 755 -p $RAM_DIR/root_home       || exit 31
  mount --bind    $RAM_DIR/root_home /root || exit 32
  tar -C $RAM_DIR/root_home -xzf "$DATA_DIR/root_home.tgz" || exit 33

  exit 0
else
  exit 2
fi
