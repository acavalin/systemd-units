#!/bin/sh

PATH=/sbin:/bin
export PATH
# -----------------------------------------------------------------------------
echo "Mplayer/Alsa RTC fine tuning"
echo 1024 > /sys/class/rtc/rtc0/max_user_freq
# -----------------------------------------------------------------------------
echo "Restore custom alsa volumes"
/opt/myapps/bin/setmixer "defaults"
# -----------------------------------------------------------------------------
echo "Turn OFF Nvidia GPU"
/opt/myapps/lnx/acpi_call/turn_off.sh
# -----------------------------------------------------------------------------
echo "Reset wifi/wcdma/bt switches"
/opt/myapps/bin/setnet all_off
# -----------------------------------------------------------------------------
echo "Rescan sdhci pci bus"
# fix "SD card reader only present when card insert at boot time"
#   hal-device | grep mmc
#   udevadm info -a -p $(udevadm info -q path -n /dev/mmcblk0p1)
echo 1 > "/sys/devices/pci0000:00/0000:00:1c.4/rescan"
# -----------------------------------------------------------------------------
echo "Setup LCD brightness"
echo 0 > /sys/class/backlight/acpi_video0/brightness
# -----------------------------------------------------------------------------
echo "Restore default dns servers"
cat /etc/resolv.conf.OK > /etc/resolv.conf

# ----- wine config -----------------------------------------------------------
#print "Registering misc binary format handler"
#/sbin/modprobe binfmt_misc
#/bin/mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
#echo ':windows:M::MZ::/usr/bin/wine:'   > /proc/sys/fs/binfmt_misc/register
#echo ':windowsPE:M::PE::/usr/bin/wine:' > /proc/sys/fs/binfmt_misc/register

# ----- turn on num-lock ------------------------------------------------------
#print "Turning on num-lock for every getty"
#INITTY=/dev/tty[1-6]
#for tty in $INITTY; do
#  setleds -D +num < $tty
#done

# ----- setting keyboard scancodes --------------------------------------------
#print "Setting up keyboard scancodes"
#setkeycodes e0f8 120 # vol-
#setkeycodes e0f9 121 # vol+
#setkeycodes e0f7 122 # mute
#setkeycodes e025 123 # X
#setkeycodes e026 124 # W

# ----- turning on sysrq magic keys -------------------------------------------
# NB: fatto in /etc/sysctl.d/local.conf
#print "Turn on sys-req magic keys"
#echo 1 > /proc/sys/kernel/sysrq

# ----- loading dump kernel ---------------------------------------------------
#print "Loading dump kernel"
#if [ "`runlevel | cut -f 2 -d " "`" = "4" ]; then
# KERN="`/usr/bin/uname -r`"
# if [ $KERN = "2.6.23.12-ken" ]; then
#   touch /loaded
#   echo "Loading dump kernel..."
#   /usr/sbin/kexec -p /boot/vmlinuz-$KERN \
#     --initrd=/boot/initrd-$KERN.gz \
#     --append="root=/dev/hda3 init 1 irqpoll maxcpus=1" \
#     --elf32-core-headers
# fi
#fi

# ----- load modules in the correct order -------------------------------------
# NB: see /etc/modprobe.d/blacklist for these blacklisted modules
#print "Loading extra modules"
#for m in gspca_pac207; do
#  /sbin/modprobe $m;
#done

# NB: managed by laptop-mode tools
#print "Setting CPUs freq"
# set cpus:             n.cpus  governor   max freq.
#/opt/myapps/bin/setcpu 8       powersave  2GHz
#/opt/myapps/bin/setcpu 2       powersave  800MHz

# caching files
#tar -cf /dev/null /opt/myapps/lnx/firefox 2> /dev/null &

exit 0
