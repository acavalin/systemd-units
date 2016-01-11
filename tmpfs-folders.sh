#!/bin/sh

# ------------------------------------------------------------------------------
# create tgz directory skeleton:
#   find /var/log -path /var/log/installer -prune -o -type f -exec dd if=/dev/null of="{}" \;
#   find /var/log -name "*.[0-9].gz" -exec rm -f "{}" \;
#   cd /var && find log -type d | tar -czvf /tmp/var.tgz --no-recursion --files-from -
# ------------------------------------------------------------------------------

PATH=/sbin:/bin
export PATH

NAME=tmpfs-folders
RAM_ROOT=/run/shm
RAM_DIR=$RAM_ROOT/$NAME
DATA_DIR=/opt/myapps/lnx/systemd-units/$NAME

if grep -qs /dev/shm /proc/mounts && [ -d $RAM_ROOT ]; then
  [ -d $RAM_DIR ] && exit 1

  mkdir -p $RAM_DIR

  # /tmp already on RAM in /etc/default/tmpfs
  #mkdir -m 777 -p $RAM_DIR/temp
  #mount --bind    $RAM_DIR/temp /tmp || exit 2

  # /var/(log|run|lock)
  mkdir -p $RAM_DIR/var
  tar   -C $RAM_DIR/var -xzf "$DATA_DIR/var.tgz" || exit 31
  mount --bind $RAM_DIR/var/log  /var/log        || exit 32
  # run and lock already on RAM in /etc/default/tmpfs
  #mount --bind $RAM_DIR/var/run  /var/run        || exit 2
  #mount --bind $RAM_DIR/var/lock /var/lock       || exit 2

  # /home -> $RAM_DIR/home
  mkdir -m 775 -p     $RAM_DIR/home
  chown -R root.users $RAM_DIR/home
  # drop old dir and make a link to the new one
  [ -d $RAM_DIR ] && rm -rf /home
  ln -sf $RAM_DIR/home/ /home

  # /home/cloud
  (
    cp -ra /etc/skel              $RAM_DIR/home/cloud         && \
    ln -sf /opt/myapps/bin        $RAM_DIR/home/cloud/bin     && \
    echo ". /opt/bash_profile" >> $RAM_DIR/home/cloud/.bashrc && \
    chmod 750                     $RAM_DIR/home/cloud         && \
    chown -R cloud.cloud          $RAM_DIR/home/cloud
  ) || exit 4

  # /root => $RAM_DIR/root_home
  mkdir -m 755 -p $RAM_DIR/root_home       || exit 51
  mount --bind    $RAM_DIR/root_home /root || exit 52
  tar          -C $RAM_DIR/root_home       \
    -xzf "$DATA_DIR/root_home.tgz"         || exit 53

  # /mnt/ramd => NB: managed by /etc/fstab, it is more simple
  # https://wiki.debian.org/systemd
  # => --make-rslave will propagate mount changes from parent to child but not viceversa
  #mkdir -m 777 -p $RAM_DIR/ramd                      || exit 61
  #mount --bind --make-rslave $RAM_DIR/ramd /mnt/ramd || exit 62
  #mount -o remount,suid,exec /mnt/ramd/ 2> /dev/null || exit 63

  # extra ramdisk
  #mkdir -m 777 -p $RAM_DIR/extra          || exit 2

  exit 0
else
  exit 2
fi
