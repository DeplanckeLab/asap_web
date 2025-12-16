#!/bin/bash
# Script to diagnose and fix munge authentication issues

set -e

echo "=== MUNGE Authentication Diagnostic and Fix Script ==="
echo ""

# Step 1: Check munge key consistency and permissions
echo "Step 1: Checking munge key..."
if [ ! -f /etc/munge/munge.key ]; then
    echo "ERROR: /etc/munge/munge.key not found!"
    exit 1
fi

echo "Checking munge key permissions..."
KEY_PERMS=$(stat -c "%a %U:%G" /etc/munge/munge.key)
echo "Current permissions: $KEY_PERMS"

if [ "$KEY_PERMS" != "400 munge:munge" ]; then
    echo "Fixing munge key permissions..."
    sudo chown munge:munge /etc/munge/munge.key
    sudo chmod 400 /etc/munge/munge.key
    echo "✓ Fixed munge key permissions"
else
    echo "✓ munge key permissions are correct"
fi

# Step 2: Check munge directories
echo ""
echo "Step 2: Checking munge directories..."
for DIR in /etc/munge /var/lib/munge /var/log/munge /run/munge; do
    if [ ! -d "$DIR" ]; then
        echo "Creating $DIR..."
        sudo mkdir -p "$DIR"
    fi
    
    OWNER=$(stat -c "%U:%G" "$DIR" 2>/dev/null || echo "unknown")
    echo "  $DIR: $OWNER"
done

# Fix ownership
echo "Fixing directory ownership..."
sudo chown -R munge:munge /etc/munge /var/lib/munge /var/log/munge /run/munge 2>/dev/null || true
sudo chmod 700 /var/lib/munge /var/log/munge 2>/dev/null || true
sudo chmod 755 /etc/munge /run/munge 2>/dev/null || true

# Step 3: Check munge log file
echo ""
echo "Step 3: Checking munge log file..."
if [ ! -f /var/log/munge/munged.log ]; then
    sudo touch /var/log/munge/munged.log
fi
sudo chown munge:munge /var/log/munge/munged.log
sudo chmod 600 /var/log/munge/munged.log
echo "✓ munge log file configured"

# Step 4: Verify munge user and group IDs
echo ""
echo "Step 4: Checking munge user/group IDs..."
MUNGE_UID=$(id -u munge 2>/dev/null || echo "not found")
MUNGE_GID=$(id -g munge 2>/dev/null || echo "not found")
echo "munge user UID: $MUNGE_UID"
echo "munge group GID: $MUNGE_GID"

if [ "$MUNGE_UID" = "not found" ] || [ "$MUNGE_GID" = "not found" ]; then
    echo "ERROR: munge user or group not found!"
    exit 1
fi

# Step 5: Check time synchronization
echo ""
echo "Step 5: Checking time synchronization..."
CURRENT_TIME=$(date +%s)
echo "Current system time: $(date)"
if command -v chronyd >/dev/null 2>&1 || command -v ntpd >/dev/null 2>&1; then
    echo "✓ NTP service appears to be configured"
else
    echo "WARNING: No NTP service detected. Time synchronization is important for munge."
fi

# Step 6: Restart munge with proper configuration
echo ""
echo "Step 6: Restarting munge..."
sudo systemctl stop munge 2>/dev/null || true
sleep 1

# Ensure munge override exists for --num-threads=10
sudo mkdir -p /etc/systemd/system/munge.service.d
if [ ! -f /etc/systemd/system/munge.service.d/override.conf ]; then
    echo "Creating munge systemd override..."
    echo -e "[Service]\nExecStart=\nExecStart=/usr/sbin/munged --num-threads=10" | sudo tee /etc/systemd/system/munge.service.d/override.conf
fi

sudo systemctl daemon-reload
sudo systemctl start munge
sleep 2

if sudo systemctl is-active --quiet munge; then
    echo "✓ munge is running"
else
    echo "ERROR: munge failed to start"
    sudo systemctl status munge --no-pager -l | head -20
    exit 1
fi

# Step 7: Test munge functionality
echo ""
echo "Step 7: Testing munge functionality..."
if echo "test" | munge | unmunge > /dev/null 2>&1; then
    echo "✓ munge encode/decode test passed"
else
    echo "ERROR: munge encode/decode test failed"
    echo "test" | munge | unmunge
    exit 1
fi

# Step 8: Check munge socket
echo ""
echo "Step 8: Checking munge socket..."
if [ -S /run/munge/munge.socket.2 ]; then
    SOCKET_PERMS=$(stat -c "%a %U:%G" /run/munge/munge.socket.2)
    echo "✓ munge socket exists: $SOCKET_PERMS"
else
    echo "WARNING: munge socket not found at /run/munge/munge.socket.2"
    ls -la /run/munge/ || echo "  /run/munge directory not accessible"
fi

# Step 9: Verify slurm user can access munge
echo ""
echo "Step 9: Verifying slurm user can access munge..."
if sudo -u slurm munge -n > /dev/null 2>&1; then
    echo "✓ slurm user can encode with munge"
else
    echo "WARNING: slurm user cannot encode with munge"
    echo "Checking if slurm is in munge group..."
    groups slurm | grep -q munge && echo "✓ slurm is in munge group" || echo "✗ slurm is NOT in munge group"
fi

# Step 10: Test munge between slurmctld and slurmdbd users
echo ""
echo "Step 10: Testing munge authentication as slurm user..."
if sudo -u slurm bash -c "munge -n | unmunge" > /dev/null 2>&1; then
    echo "✓ slurm user can encode and decode"
else
    echo "ERROR: slurm user cannot encode/decode"
    sudo -u slurm bash -c "munge -n | unmunge"
fi

echo ""
echo "=== Diagnostic Complete ==="
echo ""
echo "If munge is working correctly, try restarting slurmctld and slurmdbd:"
echo "  sudo systemctl restart slurmdbd"
echo "  sudo systemctl restart slurmctld"
echo ""
echo "Check munge logs if issues persist:"
echo "  sudo tail -50 /var/log/munge/munged.log"

