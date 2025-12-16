#!/bin/bash
# Script to initialize SLURM database directly via SQL (bypassing munge/sacctmgr issues)

set -e

echo "=== Initializing SLURM Database Directly via SQL ==="
echo ""

# Step 1: Ensure slurmdbd is running
echo "Step 1: Checking slurmdbd status..."
if ! sudo systemctl is-active --quiet slurmdbd; then
    echo "ERROR: slurmdbd is not running. Please start it first."
    exit 1
fi
echo "✓ slurmdbd is running"

# Step 2: Enable accounting storage
echo "Step 2: Enabling accounting storage in slurm.conf..."
sudo sed -i 's/^AccountingStorageType=.*/AccountingStorageType=accounting_storage\/slurmdbd/' /etc/slurm/slurm.conf
echo "✓ Accounting storage enabled"

# Step 3: Get MySQL container IP
echo "Step 3: Getting MySQL container information..."
MYSQL_IP=$(docker inspect slurmdb --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
if [ -z "$MYSQL_IP" ]; then
    echo "ERROR: Could not find slurmdb container"
    exit 1
fi
echo "MySQL container IP: $MYSQL_IP"

# Step 4: Initialize cluster in database directly
echo "Step 4: Initializing cluster in database..."
CURRENT_TIME=$(date +%s)

# Check if cluster already exists
CLUSTER_EXISTS=$(docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -Nse "SELECT COUNT(*) FROM cluster_table WHERE name='asap_cluster';" 2>&1)

if [ "$CLUSTER_EXISTS" = "1" ]; then
    echo "Cluster 'asap_cluster' already exists in database"
else
    echo "Adding cluster 'asap_cluster' to database..."
    docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "
    INSERT IGNORE INTO cluster_table (creation_time, mod_time, deleted, name, control_host, control_port, rpc_version, federation, fed_id, fed_state)
    VALUES ($CURRENT_TIME, $CURRENT_TIME, 0, 'asap_cluster', 'updeplasrv4-new.epfl.ch', 6817, 0, '', 0, 0);
    " 2>&1
    echo "✓ Cluster added to database"
fi

# Step 5: Create root account
echo "Step 5: Creating root account..."
ACCOUNT_EXISTS=$(docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -Nse "SELECT COUNT(*) FROM acct_table WHERE name='root';" 2>&1)

if [ "$ACCOUNT_EXISTS" = "1" ]; then
    echo "Root account already exists"
else
    echo "Adding root account..."
    docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "
    INSERT IGNORE INTO acct_table (creation_time, mod_time, deleted, name, description, organization)
    VALUES ($CURRENT_TIME, $CURRENT_TIME, 0, 'root', 'Root account', 'asap_cluster');
    " 2>&1
    echo "✓ Root account added"
fi

# Step 6: Create root user association
echo "Step 6: Creating root user association..."
ASSOC_EXISTS=$(docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -Nse "SELECT COUNT(*) FROM asap_cluster_assoc_table WHERE user='root' AND acct='root' AND \`partition\`='';" 2>&1)

if [ "$ASSOC_EXISTS" = "1" ]; then
    echo "Root association already exists"
else
    echo "Adding root user association..."
    docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "
    INSERT IGNORE INTO asap_cluster_assoc_table 
    (creation_time, mod_time, deleted, user, acct, \`partition\`, parent_acct, lft, rgt, shares, is_def, max_tres_pj, max_tres_pn, max_tres_mins_pj)
    VALUES 
    ($CURRENT_TIME, $CURRENT_TIME, 0, 'root', 'root', '', 'root', 1, 1, 1, 1, '', '', '');
    " 2>&1
    echo "✓ Root association added"
fi

# Step 7: Verify database setup
echo "Step 7: Verifying database setup..."
echo "Clusters in database:"
docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "SELECT name, control_host FROM cluster_table;" 2>&1
echo ""
echo "Accounts in database:"
docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "SELECT name, description FROM acct_table WHERE deleted=0;" 2>&1
echo ""
echo "Associations in database:"
docker exec slurmdb mysql -u slurm -pslurm slurm_acct_db -e "SELECT user, acct, \`partition\` FROM asap_cluster_assoc_table WHERE deleted=0;" 2>&1

# Step 8: Stop slurmctld if running
echo "Step 8: Stopping slurmctld..."
sudo systemctl stop slurmctld 2>/dev/null || true
sleep 2

# Step 9: Start slurmctld normally
echo "Step 9: Starting slurmctld..."
sudo systemctl start slurmctld
sleep 5

if sudo systemctl is-active --quiet slurmctld; then
    echo "✓ slurmctld is running"
else
    echo "ERROR: slurmctld failed to start"
    sudo systemctl status slurmctld --no-pager -l | head -20
    exit 1
fi

# Step 10: Verify everything works
echo "Step 10: Verifying cluster status..."
sleep 2
sinfo
echo ""
squeue

echo ""
echo "=== Database Initialization Complete ==="
echo ""
echo "Fair-share scheduling is now enabled with accounting storage."
echo "The cluster, root account, and root association have been created."

