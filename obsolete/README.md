# My collection of systemd unit files

## sys-setup.service
SysV-init /etc/rc.local semi-equivalent for SystemD.
It does not run as the last service but it can count on a good system initialization.

You can also use the drop-in replacement by systemd, put in `/etc/rc.local`:

~~~shell
#!/bin/sh -e
# https://stackoverflow.com/questions/44797694/where-is-rc-local-in-debian-9-debian-stretch

...# your commands

exit 0
~~~

and make it executable: `chmod 755 /etc/rc.local`.


## tc-mounter.service / tc-mounter.rb
Mounts TrueCrypt volumes as a specified user (with sudo), runs fsck on them,
and executes an optional per volume custom ruby script.
