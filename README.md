# proxmox-homelab

Shared infrastructure for Proxmox homeserver services.

## Docker Host LXC

All lightweight services (bots, tools) run as Docker containers inside a single LXC.

### One-time setup

Run on the Proxmox host:

```bash
bash create-docker-host.sh
```

This creates a Debian 12 LXC with Docker + Docker Compose, ready to host services.

### Deploying services

Each service has its own repo with a `Dockerfile` and `scripts/deploy.sh`. Run the deploy one-liner from the Docker host LXC console and it handles the rest.

### Services

| Service | Repo | Description |
|---|---|---|
| magic-files | [drive-bot](../drive-bot) | Telegram bot that files scanned PDFs into Google Drive |

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
