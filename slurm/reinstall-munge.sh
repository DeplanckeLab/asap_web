#!/bin/bash
# Script to cleanly reinstall munge

set -e

echo "=== Clean MUNGE Reinstallation ==="
echo ""

# Step 1: Stop all SLURM services
echo "Step 1: Stopping SLURM services..."
sudo systemctl stop slurmctld slurmdbd slurmd 2>/dev/null || true
sleep 2

# Step 2: Stop munge
echo "Step 2: Stopping munge..."
sudo systemctl stop munge 2>/dev/null || true
sleep 1

# Step 3: Kill any remaining munged processes
echo "Step 3: Killing any remaining munged processes..."
sudo pkill -9 munged 2>/dev/null || true
sleep 1

# Step 4: Backup munge key
echo "Step 4: Backing up munge key..."
if [ -f /etc/munge/munge.key ]; then
    sudo cp /etc/munge/munge.key /etc/munge/munge.key.backup
    echo "✓ munge key backed up"
else
    echo "WARNING: /etc/munge/munge.key not found!"
fi

# Step 5: Remove munge package
echo "Step 5: Removing munge package..."
sudo dnf remove -y munge 2>/dev/null || true

# Step 6: Clean up munge directories (but keep the key backup)
echo "Step 6: Cleaning up munge directories..."
sudo rm -rf /var/lib/munge/*
sudo rm -rf /var/log/munge/*
sudo rm -rf /run/munge/*
sudo rm -rf /etc/munge/*
# Restore key backup
if [ -f /etc/munge.key.back.backup ]; then
    sudo mkdir -p /etc/munge
    sudo cp /etc/munge.key.back.backup /etc/munge/munge.key
    echo "✓ munge key restored"
fi

# Step 7: Reinstall munge
echo "Step 7: Reinstalling munge..."
sudo dnf install -y munge

# Step 8: Set up munge key
echo "Step 8: Setting up munge key..."
if [ ! -f /etc/munge/munge.key ]; then
    echo "munge.key not found. Generating new key..."
    sudo mkdir -p /etc/munge
    sudo /usr/sbin/create-munge-key 2>/dev/null || sudo dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
    echo "✓ New munge key generated"
fi

sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key
echo "✓ munge key permissions set"

# Step 9: Create and configure munge directories
echo "Step 9: Creating munge directories..."
sudo mkdir -p /var/lib/munge /var/log/munge /run/munge /etc/munge
sudo chown -R munge:munge /var/lib/munge /var/log/munge /run/munge /etc/munge
sudo chmod 700 /var/lib/munge /var/log/munge
sudo chmod 755 /run/munge /etc/munge

# Create log file
sudo touch /var/log/munge/munged.log
sudo chown munge:munge /var/log/munge/munged.log
sudo chmod 600 /var/log/munge/munged.log

# Step 10: Configure munge systemd service
echo "Step 10: Configuring munge systemd service..."
sudo mkdir -p /etc/systemd/system/munge.service.d
echo -e "[Service]\nExecStart=\nExecStart=/usr/sbin/munged --num-threads=10" | sudo tee /etc/systemd/system/munge.service.d/override.conf

# Step 11: Start munge
echo "Step 11: Starting munge..."
sudo systemctl daemon-reload
sudo systemctl start munge
sudo systemctl enable munge
sleep 2

if ! sudo systemctl is-active --quiet munge; then
    echo "ERROR: munge failed to start"
    sudo systemctl status munge --no-pager -l | head -20
    exit 1
fi
echo "✓ munge is running"

# Step 12: Test munge functionality
echo "Step 12: Testing munge functionality..."
if echo "test" | munge | unmunge > /dev/null 2>&1; then
    echo "✓ munge encode/decode test passed"
else
    echo "ERROR: munge encode/decode test failed"
    exit 1
fi

# Step 13: Test as slurm user
echo "Step 13: Testing munge as slurm user..."
if sudo -u slurm bash -c "munge -n | unmunge" > /dev/null 2>&1; then
    echo "✓ slurm user can use munge"
else
    echo "WARNING: slurm user cannot use munge"
    echo "Checking if slurm is in munge group..."
    if groups slurm | grep -q munge; then
        echo "✓ slurm is in munge group"
    else
        echo "Adding slurm to munge group..."
        sudo usermod -aG munge slurm
        echo "✓ slurm added to munge group (may need to restart services)"
    fi
fi

# Step 14: Verify munge socket
echo "Step 14: Verifying munge socket..."
if [ -S /run/munge/munge.socket.2 ]; then
    SOCKET_PERMS=$(stat -c "%a %U:%G" /run/munge/munge.socket.2)
    echo "✓ munge socket exists: $SOCKET_PERMS"
else
    echo "WARNING: munge socket not found"
    ls -la /run/munge/
fi

echo ""
echo "=== MUNGE Reinstallation Complete ==="
echo ""
echo "Next steps:"
echo "1. Restart SLURM services:"
echo "   sudo systemctl restart slurmdbd"
echo "   sudo systemctl restart slurmctld"
echo "   sudo systemctl restart slurmd"
echo ""
echo "2. Verify everything works:"
echo "   sinfo"
echo "   squeue"

