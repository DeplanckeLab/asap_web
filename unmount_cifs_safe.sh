#!/bin/bash
# Safe CIFS unmount procedure

echo "=== Safe CIFS Unmount Procedure ==="
echo ""

echo "Current load average:"
uptime

echo ""
echo "Processes in D state:"
ps -eo stat | grep -c "^D" || echo "0"

echo ""
echo "=== Step 1: Lazy Unmount ==="
echo "This disconnects the mount but keeps it visible until processes release it."
echo "Run: sudo umount -l /mnt/asap-old"
echo ""

echo "=== Step 2: Wait for processes to release ==="
echo "After lazy unmount, wait 30-60 seconds, then check:"
echo "  ps -eo stat | grep -c '^D'"
echo ""

echo "=== Step 3: Remount with improved options ==="
cat << 'EOF'
sudo mount -t cifs //updeplanas2.epfl.ch/DeplanckeNAS2/asap-old /mnt/asap-old \
  -o username=asapold,domain=SAMBA,uid=1006,gid=1006,file_mode=0755,dir_mode=0755,soft,cache=strict,vers=3.0,timeo=30,retrans=3
EOF

echo ""
echo "=== If lazy unmount fails ==="
echo "Check what's using the mount:"
echo "  sudo lsof /mnt/asap-old"
echo "  sudo fuser -v /mnt/asap-old"
echo ""
echo "If you see many processes, you may need to:"
echo "  1. Kill specific processes (if safe)"
echo "  2. Use force unmount (risky): sudo umount -f /mnt/asap-old"
echo "  3. Reboot the system (last resort)"

