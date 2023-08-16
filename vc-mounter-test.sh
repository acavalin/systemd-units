#!/bin/bash

log=/opt/systemd-units/vc-mounter.log

echo "--- `date` ----------------------------------" > $log
echo '---------- mount + df' >> $log
echo >> $log; mount | grep loop >> $log
echo >> $log; df -h | grep loop >> $log
echo '---------- veracrypt -l' >> $log
/opt/bin/veracrypt -l >> $log
echo '---------- losetup' >> $log
losetup -l >> $log

echo '---------- try-umount' >> $log
/opt/systemd-units/vc-mounter.rb try-umount >> $log 2>&1

echo '---------- mount + df' >> $log
echo >> $log; mount | grep loop >> $log
echo >> $log; df -h | grep loop >> $log
echo '---------- veracrypt -l' >> $log
/opt/bin/veracrypt -l >> $log
echo '---------- losetup' >> $log
losetup -l >> $log

echo '---------- ls /dev*' >> $log
ls -l /dev/shm/vc-mounter/ >> $log
ls -l /dev/sda* >> $log

echo '---------- ps ax' >> $log
ps ax >> $log

sync
