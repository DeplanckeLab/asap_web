#!/bin/bash
set -e

# Create munge directories with proper ownership
mkdir -p /run/munge /var/log/munge
# Ensure /var/lib/munge exists and has correct ownership (it may already exist from image)
mkdir -p /var/lib/munge
# Fix ownership - munge user needs to own this directory
chown munge:munge /var/lib/munge 2>/dev/null || true
chmod 700 /var/lib/munge
# Remove any existing files that might have wrong ownership
rm -rf /var/lib/munge/* 2>/dev/null || true
chown munge:munge /run/munge
chmod 755 /run/munge
chown root:root /var/log/munge
chmod 700 /var/log/munge

# Copy munge key to /run/munge with proper permissions
cp /etc/munge/munge.key /run/munge/munge.key
chown munge:munge /run/munge/munge.key
chmod 400 /run/munge/munge.key

# Start munged in background with proper thread count
# Use --force to bypass ownership checks if needed
/usr/sbin/munged --force --key-file=/run/munge/munge.key --num-threads=10 &

# Wait for munge socket to be created
for i in {1..30}; do
  if [ -S /run/munge/munge.socket.2 ]; then
    echo "Munge socket created successfully"
    break
  fi
  sleep 0.1
done

# Verify munged is running
if ! pgrep -x munged > /dev/null; then
  echo "ERROR: munged failed to start"
  exit 1
fi

# Start slurmdbd
exec /usr/sbin/slurmdbd -D

