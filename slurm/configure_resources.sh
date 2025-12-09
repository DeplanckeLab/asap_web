#!/bin/bash
# Script to configure SLURM resources based on available system resources
# Uses 90% of CPU and RAM for SLURM, leaving 10% for database and web app

# Get total CPUs and RAM
TOTAL_CPUS=$(nproc)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

# Calculate 90% of resources (round down)
SLURM_CPUS=$((TOTAL_CPUS * 90 / 100))
SLURM_RAM_MB=$((TOTAL_RAM_MB * 90 / 100))

# Ensure minimum values
if [ $SLURM_CPUS -lt 1 ]; then
  SLURM_CPUS=1
fi
if [ $SLURM_RAM_MB -lt 1024 ]; then
  SLURM_RAM_MB=1024
fi

echo "System Resources:"
echo "  Total CPUs: $TOTAL_CPUS"
echo "  Total RAM: ${TOTAL_RAM_MB}MB"
echo ""
echo "SLURM Resources (90%):"
echo "  CPUs: $SLURM_CPUS"
echo "  RAM: ${SLURM_RAM_MB}MB"
echo ""

# Update slurm.conf
CONF_FILE="slurm/slurm.conf"
if [ ! -f "$CONF_FILE" ]; then
  echo "Error: $CONF_FILE not found"
  exit 1
fi

# Backup original
cp "$CONF_FILE" "${CONF_FILE}.bak"

# Update NodeName line with new resources
sed -i "s/^NodeName=slurmd.*/NodeName=slurmd NodeAddr=slurmd CPUs=$SLURM_CPUS RealMemory=$SLURM_RAM_MB State=UNKNOWN/" "$CONF_FILE"

echo "Updated $CONF_FILE with new resource limits"
echo "Backup saved to ${CONF_FILE}.bak"

