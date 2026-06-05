#!/bin/bash
# Script to fix high load caused by stuck CIFS kernel workers

echo "Current load average:"
uptime

echo ""
echo "Processes in D state (uninterruptible sleep):"
ps -eo stat | grep -c "^D" || echo "0"

echo ""
echo "Attempting to remount CIFS filesystem to clear stuck operations..."

# Check if anything is using the mount
echo "Checking for processes using /mnt/asap-old..."
lsof /mnt/asap-old 2>/dev/null | head -10

echo ""
echo "Remounting CIFS filesystem..."
# Remount with same options to clear stuck operations
mount -o remount /mnt/asap-old

if [ $? -eq 0 ]; then
    echo "Remount successful"
else
    echo "Remount failed. You may need to unmount and remount manually:"
    echo "  umount /mnt/asap-old"
    echo "  mount -t cifs //updeplanas2.epfl.ch/DeplanckeNAS2/asap-old /mnt/asap-old -o username=asapold,domain=SAMBA,uid=1006,gid=1006,file_mode=0755,dir_mode=0755,soft,cache=strict,vers=3.0"
fi

echo ""
echo "Waiting 10 seconds for kernel workers to clear..."
sleep 10

echo ""
echo "New load average:"
uptime

echo ""
echo "Processes in D state after remount:"
ps -eo stat | grep -c "^D" || echo "0"





