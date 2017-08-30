#!/bin/bash

# truncate all log files
find /var/log \
  -path /var/log/installer -prune -o -type f \
  -exec dd if=/dev/null of="{}" \;

# delete *.[1-9] backups
find /var/log -name "*.[0-9]"    -exec rm -f "{}" \;
find /var/log -name "*.[0-9].gz" -exec rm -f "{}" \;
