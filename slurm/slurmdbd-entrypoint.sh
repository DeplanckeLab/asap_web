#!/bin/bash
# Copy config file and set correct ownership
cp /etc/slurm/slurmdbd.conf /tmp/slurmdbd.conf
chown slurm:slurm /tmp/slurmdbd.conf
chmod 600 /tmp/slurmdbd.conf

# Start slurmdbd with the copied config
exec /usr/sbin/slurmdbd -D -f /tmp/slurmdbd.conf

