#!/bin/bash
# Script to perform a fresh installation of SLURM components on the host machine

set -e

echo "=== Fresh SLURM Installation on Host ==="
echo ""

# Step 1: Stop and disable existing services
echo "Step 1: Stopping existing SLURM services..."
sudo systemctl stop slurmctld slurmdbd slurmd 2>/dev/null || true
sudo systemctl disable slurmctld slurmdbd slurmd 2>/dev/null || true

# Step 2: Remove existing packages (optional - comment out if you want to keep packages)
echo "Step 2: Removing existing SLURM packages..."
sudo dnf remove -y slurm-slurmctld slurm-slurmdbd slurm-slurmd 2>/dev/null || true

# Step 3: Clean up state files and configs
echo "Step 3: Cleaning up state files and configurations..."
sudo rm -rf /var/spool/slurmctld/*
sudo rm -rf /var/spool/slurmdbd/*
sudo rm -rf /var/spool/slurmd/*
sudo rm -rf /var/log/slurm/*
sudo rm -f /etc/slurm/slurm.conf /etc/slurm/slurmdbd.conf
sudo rm -rf /etc/systemd/system/slurmctld.service.d
sudo rm -rf /etc/systemd/system/slurmdbd.service.d

# Step 4: Install SLURM packages
echo "Step 4: Installing SLURM packages..."
sudo dnf install -y slurm-slurmctld slurm-slurmdbd slurm-slurmd

# Step 5: Create slurm user if it doesn't exist
echo "Step 5: Creating slurm user..."
if ! getent passwd slurm > /dev/null 2>&1; then
    sudo useradd -r -s /bin/bash -d /var/lib/slurm slurm
else
    echo "slurm user already exists"
fi

# Step 6: Create necessary directories
echo "Step 6: Creating SLURM directories..."
sudo mkdir -p /etc/slurm
sudo mkdir -p /var/spool/slurmctld
sudo mkdir -p /var/spool/slurmdbd
sudo mkdir -p /var/spool/slurmd
sudo mkdir -p /var/log/slurm

# Step 7: Set ownership
echo "Step 7: Setting directory ownership..."
sudo chown slurm:slurm /var/spool/slurmctld /var/spool/slurmdbd /var/log/slurm
sudo chown root:root /var/spool/slurmd
sudo chmod 755 /var/spool/slurmctld /var/spool/slurmdbd /var/spool/slurmd
sudo chmod 755 /var/log/slurm

# Step 8: Add slurm user to necessary groups
echo "Step 8: Adding slurm user to groups..."
sudo usermod -aG munge slurm
sudo usermod -aG docker slurm

# Step 9: Copy and configure slurm.conf
echo "Step 9: Configuring slurm.conf..."
cp /srv/asap2_test/slurm/slurm.conf /tmp/slurm.conf

HOST_IP=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname)

# Update slurm.conf for host
sed -i "s/NodeName=.*NodeAddr=.*CPUs=/NodeName=${HOSTNAME} NodeAddr=${HOST_IP} CPUs=/" /tmp/slurm.conf
sed -i 's|PluginDir=/usr/lib/slurm|PluginDir=/usr/lib64/slurm|' /tmp/slurm.conf
sed -i 's/^SlurmUser=.*/SlurmUser=slurm/' /tmp/slurm.conf
sed -i 's/^SlurmdUser=.*/SlurmdUser=slurm/' /tmp/slurm.conf
sed -i "s/^ControlMachine=.*/ControlMachine=${HOSTNAME}/" /tmp/slurm.conf
sed -i "s/^AccountingStorageHost=.*/AccountingStorageHost=localhost/" /tmp/slurm.conf

# Temporarily disable accounting storage to get slurmctld running first
sed -i 's/^AccountingStorageType=.*/AccountingStorageType=accounting_storage\/none/' /tmp/slurm.conf

sudo cp /tmp/slurm.conf /etc/slurm/slurm.conf
sudo chmod 644 /etc/slurm/slurm.conf
sudo chown root:root /etc/slurm/slurm.conf

# Step 10: Copy and configure slurmdbd.conf
echo "Step 10: Configuring slurmdbd.conf..."
cp /srv/asap2_test/slurm/slurmdbd.conf /tmp/slurmdbd.conf

# Update slurmdbd.conf for host
sed -i "s/^DbdHost=.*/DbdHost=localhost/" /tmp/slurmdbd.conf

# Get MySQL container IP
MYSQL_IP=$(docker inspect slurmdb --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
if [ -n "$MYSQL_IP" ] && [ "$MYSQL_IP" != "localhost" ]; then
    sed -i "s/^StorageHost=.*/StorageHost=${MYSQL_IP}/" /tmp/slurmdbd.conf
else
    # Try using Docker bridge IP
    sed -i "s/^StorageHost=.*/StorageHost=172.17.0.1/" /tmp/slurmdbd.conf
fi

sudo cp /tmp/slurmdbd.conf /etc/slurm/slurmdbd.conf
sudo chmod 600 /etc/slurm/slurmdbd.conf
sudo chown slurm:slurm /etc/slurm/slurmdbd.conf

# Step 11: Configure munge
echo "Step 11: Configuring munge..."
sudo mkdir -p /var/log/munge /run/munge /var/lib/munge
sudo chown munge:munge /var/log/munge /run/munge /var/lib/munge
sudo chmod 700 /var/log/munge /var/lib/munge
sudo chmod 755 /run/munge

# Ensure munge key exists and has correct permissions
if [ ! -f /etc/munge/munge.key ]; then
    echo "ERROR: /etc/munge/munge.key not found. Please create it first."
    exit 1
fi
sudo chmod 400 /etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key

# Create munge log file if it doesn't exist
sudo touch /var/log/munge/munged.log
sudo chown munge:munge /var/log/munge/munged.log
sudo chmod 600 /var/log/munge/munged.log

# Configure munge to use --num-threads=10
sudo mkdir -p /etc/systemd/system/munge.service.d
echo -e "[Service]\nExecStart=\nExecStart=/usr/sbin/munged --num-threads=10" | sudo tee /etc/systemd/system/munge.service.d/override.conf

# Step 12: Start munge
echo "Step 12: Starting munge..."
sudo systemctl daemon-reload
sudo systemctl restart munge
sudo systemctl enable munge

if ! sudo systemctl is-active --quiet munge; then
    echo "ERROR: munge failed to start"
    sudo systemctl status munge --no-pager -l | head -20
    exit 1
fi
echo "✓ Munge is running"

# Step 13: Start slurmdbd
echo "Step 13: Starting slurmdbd..."
sudo systemctl start slurmdbd
sudo systemctl enable slurmdbd

sleep 3
if ! sudo systemctl is-active --quiet slurmdbd; then
    echo "WARNING: slurmdbd may have failed to start"
    sudo systemctl status slurmdbd --no-pager -l | head -20
else
    echo "✓ slurmdbd is running"
fi

# Step 14: Start slurmctld (without accounting storage first)
echo "Step 14: Starting slurmctld (without accounting storage)..."
sudo systemctl start slurmctld
sudo systemctl enable slurmctld

sleep 3
if ! sudo systemctl is-active --quiet slurmctld; then
    echo "ERROR: slurmctld failed to start"
    sudo systemctl status slurmctld --no-pager -l | head -20
    sudo journalctl -u slurmctld --no-pager -n 30 | tail -20
    exit 1
fi
echo "✓ slurmctld is running"

# Step 15: Restart slurmd
echo "Step 15: Restarting slurmd..."
sudo systemctl restart slurmd
sudo systemctl enable slurmd

sleep 2
if ! sudo systemctl is-active --quiet slurmd; then
    echo "WARNING: slurmd may have issues"
    sudo systemctl status slurmd --no-pager -l | head -20
else
    echo "✓ slurmd is running"
fi

# Step 16: Test cluster connectivity
echo "Step 16: Testing cluster connectivity..."
sleep 2
if sinfo > /dev/null 2>&1; then
    echo "✓ Cluster is accessible"
    sinfo
    echo ""
    squeue
else
    echo "WARNING: sinfo failed, but services are running"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Verify cluster status: sinfo && squeue"
echo "2. To enable accounting storage, edit /etc/slurm/slurm.conf:"
echo "   Change: AccountingStorageType=accounting_storage/none"
echo "   To:     AccountingStorageType=accounting_storage/slurmdbd"
echo "3. Restart slurmctld: sudo systemctl restart slurmctld"
echo "4. Initialize cluster in database: sudo sacctmgr add cluster asap_cluster"
echo ""
echo "All services should now be running on the host machine."

