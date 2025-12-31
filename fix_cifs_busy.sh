#!/bin/bash
# Script to fix busy CIFS mount

echo "=== Fixing Busy CIFS Mount ==="
echo ""

# Step 1: Try to identify what's using it
echo "Step 1: Finding processes using /mnt/asap-old..."
echo "Run this command manually: sudo lsof /mnt/asap-old"
echo ""

# Step 2: Try lazy unmount (disconnects but keeps mount until processes release)
echo "Step 2: Attempting lazy unmount..."
echo "This will disconnect the mount but keep it visible until processes release it."
echo ""
echo "Run: sudo umount -l /mnt/asap-old"
echo ""

# Step 3: After lazy unmount, wait and remount
echo "Step 3: After lazy unmount succeeds, wait 30 seconds then remount:"
echo ""
cat << 'EOF'
sudo mount -t cifs //updeplanas2.epfl.ch/DeplanckeNAS2/asap-old /mnt/asap-old \
  -o username=asapold,domain=SAMBA,uid=1006,gid=1006,file_mode=0755,dir_mode=0755,soft,cache=strict,vers=3.0,timeo=30,retrans=3
EOF

echo ""
echo "=== Alternative: Force unmount (DANGEROUS - use only if lazy unmount fails) ==="
echo "WARNING: This can cause data loss if processes are writing!"
echo "Run: sudo umount -f /mnt/asap-old"
echo ""

echo "=== If all else fails ==="
echo "The kernel workers in D state may need a system reboot to clear."
echo "Check with: ps -eo pid,stat,comm | grep -E '^[0-9]+ D' | wc -l"



