# Monitoring

A collection of server monitoring and maintenance scripts.

## Scripts

### `check_docker_updates.sh`

Checks all running Docker Compose services for available image updates by querying the registry directly — no pulls, no side effects. Optionally updates specific or all outdated services via Compose.

**Usage**

```bash
# Check all running containers for updates
./check_docker_updates.sh

# Update all outdated services
./check_docker_updates.sh --update-all

# Update specific services by Compose service name
./check_docker_updates.sh --update jellyfin homeassistant
```

**Requirements**

- Docker with Compose plugin (`docker compose`)
- `curl`
- All containers must be managed by Docker Compose

**Notes**

- Works with Docker Hub and other registries such as `ghcr.io`
- Private registries with authentication are not currently supported
- Exits with code `1` if any updates are found but not applied (useful for cron/CI)
