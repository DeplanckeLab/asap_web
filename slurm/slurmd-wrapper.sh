#!/bin/bash
# Wrapper script to run slurmd without cgroup detection
# Since /sys/fs/cgroup is not mounted, slurmd won't detect cgroup v2

exec /usr/sbin/slurmd -D

