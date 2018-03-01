#!/bin/bash

log=/opt/systemd-units/vc-mounter.log

echo "--- `date` ----------------------------------" >> $log

echo '---------- mount + df' >> $log
echo >> $log; mount | grep loop >> $log
echo >> $log; df -h | grep loop >> $log
echo '---------- mount all' >> $log
mount >> $log
echo '---------- veracrypt -l' >> $log
/opt/bin/veracrypt -t -l >> $log
echo '---------- losetup' >> $log
losetup -l >> $log

echo '---------- try-umount' >> $log
/opt/systemd-units/vc-mounter.rb try-umount >> $log 2>&1

echo '----------------------------------------------' >> $log

echo '---------- mount + df' >> $log
echo >> $log; mount | grep loop >> $log
echo >> $log; df -h | grep loop >> $log
echo '---------- mount all' >> $log
mount >> $log
echo '---------- veracrypt -l' >> $log
/opt/bin/veracrypt -t -l >> $log
echo '---------- losetup' >> $log
losetup -l >> $log

echo '----------------------------------------------' >> $log

echo '---------- ls /dev*' >> $log
ls -l /dev/shm/vc-mounter/ >> $log
ls -l /dev/sd[ab]* >> $log

echo '---------- ps ax' >> $log
ps ax >> $log

sync
