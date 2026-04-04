# Deployment Permissions Guide

## Container User Configuration

The application runs as **non-root user** (`rvmuser`, UID 1006) for security and portability.

## Requirements for Deployment

### 1. Docker Socket Access
- Container must have access to Docker socket (`/var/run/docker.sock`)
- Docker group GID must match host (typically 985)
- Configured in `Dockerfile` and `docker-compose.test.yml`

### 2. Directory Permissions
- Data directories must be writable by UID 1006 (rvmuser)
- Application creates directories with `chmod 0777` for cross-container access
- Key directories:
  - `/data/asap2_test/users/*` - User project data
  - `/data/asap2_test/fus/*` - File uploads
  - `/data/asap2_test/parsing/*` - Parsing output

### 3. SLURM Authentication
- Container needs access to munge key or munge socket
- Configured via mounted `/run/munge` from host
- Munge group GID 106

### 4. Group Configuration
Container user needs membership in:
- `docker` group (GID 985) - for Docker socket access
- `munge` group (GID 106) - for SLURM authentication

## Docker Compose Configuration

```yaml
user: "1006:985"  # rvmuser:docker (primary group is docker for socket access)
group_add:
  - 985  # docker group
  - 106   # munge group
```

## Kubernetes Deployment

For Kubernetes, use a SecurityContext:

```yaml
securityContext:
  runAsUser: 1006
  runAsGroup: 985
  supplementalGroups:
    - 985  # docker (if using Docker-in-Docker)
    - 106  # munge
  fsGroup: 985
```

Note: For Kubernetes, consider using a service account with appropriate permissions instead of Docker socket access.

## Cloud Platform Considerations

### AWS ECS/Fargate
- Non-root containers are recommended
- Use task execution role for permissions
- May need to adjust GIDs based on platform defaults

### Google Cloud Run
- Containers run as non-root by default
- No Docker socket access (use Cloud Build or other services)
- Adjust architecture to use Cloud-native services

### Azure Container Instances
- Supports non-root containers
- May need custom user configuration

## Migration from Root to Non-Root

If migrating from root to non-root:

1. **Fix existing file permissions:**
   ```bash
   sudo chown -R 1006:985 /data/asap2_test
   sudo find /data/asap2_test -type d -exec chmod 775 {} \;
   sudo find /data/asap2_test -type f -exec chmod 664 {} \;
   ```

2. **Update docker-compose.yml:**
   - Add `user: "1006:985"`
   - Add `group_add: [985, 106]`

3. **Rebuild container:**
   ```bash
   docker-compose build website
   docker-compose up -d website
   ```

## Troubleshooting

### Permission Denied Errors
- Check directory ownership: `ls -ld /path/to/directory`
- Ensure rvmuser (1006) can write: `sudo -u rvmuser touch /path/to/directory/test`
- Fix permissions: `sudo chmod 775 /path/to/directory`

### Docker Socket Access
- Verify docker group GID: `getent group docker`
- Check container groups: `docker exec website id`
- Ensure socket permissions: `ls -l /var/run/docker.sock`

### SLURM Authentication
- Verify munge socket: `ls -l /run/munge/munge.socket.2`
- Check munge group: `getent group munge`
- Test connection: `docker exec website sinfo`

## Security Best Practices

1. **Principle of Least Privilege**: Container runs with minimal required permissions
2. **Read-only mounts**: Mount sensitive files (munge.key) as read-only
3. **Group-based access**: Use groups for shared resources (docker, munge)
4. **Audit trail**: Non-root containers provide better audit capabilities
5. **Compliance**: Meets security standards for production deployments

