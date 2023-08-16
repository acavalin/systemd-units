#!/bin/sh
for i in /dev/sd?; do /sbin/hdparm -Y $i; done
sleep 3
