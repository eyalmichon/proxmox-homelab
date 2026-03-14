# proxmox-homelab

Shared infrastructure for Proxmox homeserver services.

## Docker Host LXC

All lightweight services (bots, tools) run as Docker containers inside a single LXC.

### One-time setup

Run on the **Proxmox host** shell (web UI or SSH):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/eyalmichon/proxmox-homelab/main/create-docker-host.sh)"
```

This creates a Debian 12 LXC with Docker + Compose, ready to host services.

### Deploying services

Open the container's **Shell** in Proxmox (auto-logs in as root) and run the service one-liner:

| Service | One-liner | Description |
|---|---|---|
| [magic-files](https://github.com/eyalmichon/magic-files) | `bash -c "$(wget -qLO - https://raw.githubusercontent.com/eyalmichon/magic-files/main/scripts/deploy.sh)"` | Telegram PDF-to-Drive bot |

### Useful commands

SSH into the Docker host, then:

```bash
cd /opt/services

docker compose ps                        # list all services
docker compose logs -f <service>         # tail logs
docker compose restart <service>         # restart one service
docker compose up -d                     # start everything
docker compose down <service>            # stop one service
docker compose up -d --build <service>   # rebuild and restart
```
