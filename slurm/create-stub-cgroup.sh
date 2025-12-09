#!/bin/bash
# Create a minimal stub cgroup_v2.so that slurmd can load but does nothing

cat > /usr/lib/slurm/cgroup_v2.so << 'EOF'
#!/bin/bash
# Stub cgroup plugin - does nothing but allows slurmd to initialize
exit 0
EOF
chmod +x /usr/lib/slurm/cgroup_v2.so

