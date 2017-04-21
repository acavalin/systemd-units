# My collection of systemd unit files

## sys-setup.service
SysV-init /etc/rc.local semi-equivalent for SystemD.
It does not run as the last service but it can count on a good system initialization.

## vc-mounter.service / vc-mounter.rb
Mounts VeraCrypt volumes as a specified user (with sudo), runs fsck on them,
and executes an optional per volume custom ruby script.

## tc-mounter.service / tc-mounter.rb
Mounts TrueCrypt volumes as a specified user (with sudo), runs fsck on them,
and executes an optional per volume custom ruby script.

## tmpfs-folders.service
A big step towards read only root file system to save preciuos disk read/writes.
Mounts /var/log and user homes directories on tmpfs.
SETUP: create directory skeletons (see instructions in tmpfs-folders.sh)
