#!/bin/bash
# Script to initialize SLURM database for fair-share scheduling with accounting

set -e

echo "=== Initializing SLURM Database for Fair-Share Scheduling ==="
echo ""

# Step 1: Ensure slurmdbd is running
echo "Step 1: Checking slurmdbd status..."
if ! sudo systemctl is-active --quiet slurmdbd; then
    echo "ERROR: slurmdbd is not running. Please start it first."
    exit 1
fi
echo "✓ slurmdbd is running"

# Step 2: Enable accounting storage BEFORE starting slurmctld
echo "Step 2: Enabling accounting storage in slurm.conf..."
sudo sed -i 's/^AccountingStorageType=.*/AccountingStorageType=accounting_storage\/slurmdbd/' /etc/slurm/slurm.conf
echo "✓ Accounting storage enabled"

# Step 3: Stop slurmctld
echo "Step 3: Stopping slurmctld..."
sudo systemctl stop slurmctld
sleep 2

# Step 4: Start slurmctld with -i flag (ignore state) in background
echo "Step 4: Starting slurmctld with -i flag (ignore state)..."
sudo -u slurm /usr/sbin/slurmctld -D -i > /tmp/slurmctld-init.log 2>&1 &
SLURMCTLD_PID=$!
echo "slurmctld started with PID: $SLURMCTLD_PID"

# Wait for slurmctld to be ready
echo "Waiting for slurmctld to initialize..."
sleep 5

# Check if slurmctld is still running
if ! kill -0 $SLURMCTLD_PID 2>/dev/null; then
    echo "ERROR: slurmctld failed to start"
    cat /tmp/slurmctld-init.log
    exit 1
fi

# Step 5: Test connectivity
echo "Step 5: Testing SLURM connectivity..."
if ! sinfo > /dev/null 2>&1; then
    echo "WARNING: sinfo failed, but continuing..."
else
    echo "✓ SLURM is accessible"
fi

# Step 6: Initialize cluster in database
echo "Step 6: Initializing cluster in database..."
if sacctmgr show cluster asap_cluster > /dev/null 2>&1; then
    echo "Cluster 'asap_cluster' already exists in database"
else
    echo "Adding cluster 'asap_cluster' to database..."
    sacctmgr -i add cluster asap_cluster || {
        echo "ERROR: Failed to add cluster"
        kill $SLURMCTLD_PID 2>/dev/null || true
        exit 1
    }
    echo "✓ Cluster added to database"
fi

# Step 7: Create root account and association
echo "Step 7: Creating root account and association..."
if sacctmgr show account root > /dev/null 2>&1; then
    echo "Root account already exists"
else
    echo "Adding root account..."
    sacctmgr -i add account root || {
        echo "WARNING: Failed to add root account (may already exist)"
    }
fi

# Create association for root user with root account
echo "Creating association for root user..."
sacctmgr -i add user root account=root cluster=asap_cluster || {
    echo "WARNING: Failed to add root association (may already exist)"
}

# Step 8: Verify database setup
echo "Step 8: Verifying database setup..."
echo "Clusters in database:"
sacctmgr show cluster
echo ""
echo "Accounts in database:"
sacctmgr show account
echo ""
echo "Associations in database:"
sacctmgr show association

# Step 9: Stop temporary slurmctld
echo "Step 9: Stopping temporary slurmctld..."
kill $SLURMCTLD_PID 2>/dev/null || true
sleep 2

# Step 10: Start slurmctld normally (accounting storage already enabled)
echo "Step 10: Starting slurmctld normally..."
sudo systemctl start slurmctld
sleep 3

if sudo systemctl is-active --quiet slurmctld; then
    echo "✓ slurmctld is running"
else
    echo "ERROR: slurmctld failed to start"
    sudo systemctl status slurmctld --no-pager -l | head -20
    exit 1
fi

# Step 11: Verify everything works
echo "Step 11: Verifying cluster status..."
sleep 2
sinfo
echo ""
squeue

echo ""
echo "=== Database Initialization Complete ==="
echo ""
echo "Fair-share scheduling is now enabled with accounting storage."
echo "You can now create user accounts using:"
echo "  sacctmgr add account <account_name>"
echo "  sacctmgr add user <username> account=<account_name> cluster=asap_cluster"

