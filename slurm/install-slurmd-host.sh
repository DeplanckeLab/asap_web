#!/bin/bash
# Script to install and configure slurmd on the host

# Don't exit on error - we want to try manual startup if systemd fails
set +e

echo "Installing SLURM and munge packages..."
# Note: on RHEL9 the packages are slurm, slurm-slurmd, munge, munge-libs
sudo dnf install -y slurm slurm-slurmd munge munge-libs

echo "Creating SLURM config directory and spool directories..."
sudo mkdir -p /etc/slurm
sudo mkdir -p /var/spool/slurmd
sudo chown slurm:slurm /var/spool/slurmd 2>/dev/null || sudo chown root:root /var/spool/slurmd

echo "Copying slurm.conf from container..."
docker exec slurmctld cat /etc/slurm/slurm.conf > /tmp/slurm.conf

echo "Updating slurm.conf for host..."
HOST_IP=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname)
SLURMCTLD_IP=$(docker inspect slurmctld --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "slurmctld")

# Update node definition to use host
sed -i "s/NodeName=slurmd NodeAddr=slurmd/NodeName=${HOSTNAME} NodeAddr=${HOST_IP}/" /tmp/slurm.conf
# Fix PluginDir for RHEL9 (uses /usr/lib64/slurm instead of /usr/lib/slurm)
sed -i "s|PluginDir=/usr/lib/slurm|PluginDir=/usr/lib64/slurm|" /tmp/slurm.conf
# Check if auth/none plugin exists, if not use auth/munge (default for RHEL9)
if [ ! -f /usr/lib64/slurm/auth_none.so ]; then
    echo "auth/none plugin not found, using auth/munge instead"
    sed -i "s/AuthType=auth\/none/AuthType=auth\/munge/" /tmp/slurm.conf
fi

# Add slurmctld to /etc/hosts if using container hostname
if [ "$SLURMCTLD_IP" != "slurmctld" ] && ! grep -q "^${SLURMCTLD_IP}.*slurmctld" /etc/hosts; then
    echo "Adding slurmctld to /etc/hosts..."
    echo "${SLURMCTLD_IP} slurmctld" | sudo tee -a /etc/hosts
fi

echo "Installing slurm.conf..."
sudo cp /tmp/slurm.conf /etc/slurm/slurm.conf
sudo chmod 644 /etc/slurm/slurm.conf

echo "Setting up munge key..."
sudo mkdir -p /etc/munge
docker exec slurmctld cat /etc/munge/munge.key | sudo tee /etc/munge/munge.key > /dev/null
sudo chmod 400 /etc/munge/munge.key
sudo chown munge:munge /etc/munge/munge.key

echo "Starting munge..."
# Try systemctl first, fall back to manual start if systemd is unavailable
if sudo systemctl start munge 2>/dev/null; then
    echo "Munge started via systemctl"
    sudo systemctl enable munge 2>/dev/null || echo "Warning: Could not enable munge (systemd issue)"
else
    echo "Systemd unavailable, starting munge manually..."
    sudo /usr/sbin/munged --force || echo "Warning: munge may already be running"
fi

echo "Starting slurmd..."
# Try systemctl first, fall back to manual start if systemd is unavailable
if sudo systemctl start slurmd 2>/dev/null; then
    echo "Slurmd started via systemctl"
    sudo systemctl enable slurmd 2>/dev/null || echo "Warning: Could not enable slurmd (systemd issue)"
else
    echo "Systemd unavailable, starting slurmd manually..."
    sudo /usr/sbin/slurmd -D &
    echo "Slurmd started in background (PID: $!)"
fi

echo "Checking status..."
# Check if processes are running
if pgrep -x munged > /dev/null; then
    echo "Munge is running"
else
    echo "Warning: Munge does not appear to be running"
fi

if pgrep -x slurmd > /dev/null; then
    echo "Slurmd is running"
    ps aux | grep slurmd | grep -v grep
else
    echo "Warning: Slurmd does not appear to be running"
fi

echo "Done! Check with: docker exec slurmctld sinfo"

