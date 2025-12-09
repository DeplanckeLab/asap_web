#!/bin/bash
# Script to start SLURM services

echo "Starting SLURM services..."
cd /srv/asap2_test

# Start SLURM services in order
echo "1. Starting MySQL database..."
docker-compose up -d slurmdb

echo "Waiting for database to be ready..."
sleep 10

echo "2. Starting SLURM database daemon..."
docker-compose up -d slurmdbd

echo "Waiting for database daemon..."
sleep 5

echo "3. Starting SLURM controller..."
docker-compose up -d slurmctld

echo "Waiting for controller..."
sleep 5

echo "4. Starting SLURM compute node..."
docker-compose up -d slurmd

echo "Waiting for compute node to register..."
sleep 10

echo ""
echo "Checking SLURM status..."
docker exec slurmctld sinfo

echo ""
echo "SLURM services started!"
echo "Use './slurm/check_status.sh' to check job status"

