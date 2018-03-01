# My collection of systemd unit files

## vc-mounter.service / vc-mounter.rb
Mounts VeraCrypt volumes as a specified user (with sudo), runs fsck on them,
and executes an optional per volume custom ruby script.

## tmpfs-folders.service
A big step towards read only root file system to save preciuos disk read/writes.
Mounts /var/log and user homes directories on tmpfs.
SETUP: create directory skeletons (see instructions in tmpfs-folders.sh)
