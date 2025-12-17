#!/bin/bash
# Script to diagnose CIFS mount issues

echo "=== CIFS Mount Diagnosis ==="
echo ""

echo "1. Checking processes using /mnt/asap-old:"
lsof /mnt/asap-old 2>/dev/null | head -20 || echo "No processes found (or need sudo)"

echo ""
echo "2. Checking kernel workers in D state:"
ps -eo pid,stat,comm | awk '$2 ~ /D/ {print}' | head -20

echo ""
echo "3. Count of processes in D state:"
ps -eo stat | grep -c "^D" || echo "0"

echo ""
echo "4. CIFS statistics:"
cat /proc/fs/cifs/Stats 2>/dev/null | head -30 || echo "Cannot read CIFS stats (need root)"

echo ""
echo "5. Checking mount status:"
mount | grep cifs

echo ""
echo "6. Load average:"
uptime


