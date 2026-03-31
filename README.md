# proxmox-homelab

Shared infrastructure for Proxmox homeserver services. All lightweight services (bots, tools) run as Docker containers inside a single LXC, managed by the `homelab` CLI.

## Architecture

```
Proxmox Host
 └─ create-docker-host.sh          # one-time LXC setup
      └─ Docker Host LXC
           ├─ /usr/local/bin/homelab   # CLI (installed automatically)
           ├─ /opt/services/
           │    ├─ nanit-bridge/
           │    │    ├─ docker-compose.yml
           │    │    ├─ .env
           │    │    └─ .env.example
           │    └─ magic-files/
           │         ├─ docker-compose.yml
           │         ├─ .env
           │         ├─ .env.example
           │         └─ scripts/
           │              └─ post-install.sh
           └─ /opt/backups/
                └─ nanit-bridge/
                     └─ data_20260331-120000.tar.gz
```

Each service lives in its own directory under `/opt/services/`, cloned from its GitHub repo.

## Quick start

### 1. Create the Docker host LXC (one-time)

Run on the **Proxmox host** shell (web UI or SSH):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/eyalmichon/proxmox-homelab/main/create-docker-host.sh)"
```

This creates a Debian 12 LXC with Docker, Compose, and the `homelab` CLI pre-installed.

### 2. Install services

Open the container's **Shell** in Proxmox (auto-logs in as root):

```bash
homelab install nanit-bridge
homelab install magic-files
```

The CLI clones the repo, walks you through `.env` configuration, runs any setup hooks, and starts the containers.

## CLI reference

| Command | Description |
|---|---|
| `homelab install <service>` | Clone, configure `.env`, run hooks, and start |
| `homelab update [service]` | Pull latest and rebuild (all services if omitted) |
| `homelab remove <service>` | Stop and optionally delete a service |
| `homelab status` | Show all services: state, health, uptime, ports |
| `homelab logs <service> [-f]` | Tail service logs |
| `homelab restart <service>` | Restart a service |
| `homelab backup [service]` | Snapshot named volumes to `/opt/backups/` |
| `homelab list` | List installed services with repo URLs |
| `homelab self-update` | Update the homelab CLI itself |
| `homelab help` | Show help and available services |

## Available services

| Service | Repo | Description |
|---|---|---|
| nanit-bridge | [eyalmichon/nanit-bridge](https://github.com/eyalmichon/nanit-bridge) | Nanit baby monitor bridge |
| magic-files | [eyalmichon/magic-files](https://github.com/eyalmichon/magic-files) | Telegram PDF-to-Drive bot |

## Adding a new service

### Service contract

Every compatible service repo must have at its root:

| File | Required | Purpose |
|---|---|---|
| `docker-compose.yml` | Yes | Defines the service containers |
| `.env.example` | Yes | Template used by `homelab install` to generate `.env` |
| `scripts/post-install.sh` | No | Runs after `.env` creation, before first `docker compose up` |
| `scripts/post-update.sh` | No | Runs after `git pull`, before rebuild |
| `scripts/pre-remove.sh` | No | Runs before `docker compose down` |

### `.env.example` format

The CLI parses `.env.example` to generate interactive prompts:

```bash
# Required
BOT_TOKEN=               # Telegram bot token
CHAT_ID=                 # Telegram chat ID

# Optional
LOG_LEVEL=info           # Log verbosity
DB_PASSWORD=             # database password (hidden input)
# FEATURE_FLAG=false     # commented-out = optional, shown with default
```

Rules:
- Lines under `# Required` are prompted and cannot be left empty
- Lines under `# Optional` (or commented-out `# VAR=val`) can be skipped
- Inline comments (`# description`) become the prompt text
- Variables with `password`, `secret`, `token`, or `api key` in the description use hidden input

### Registering the service

Add the service to the `REGISTRY` associative array in the [`homelab`](homelab) script and push to `main`:

```bash
declare -A REGISTRY=(
  [nanit-bridge]="https://github.com/eyalmichon/nanit-bridge.git"
  [magic-files]="https://github.com/eyalmichon/magic-files.git"
  [your-service]="https://github.com/you/your-service.git"   # add here
)
```

Existing installs pick up the updated registry the next time `homelab` is re-downloaded or the LXC is recreated.

## Manual commands

If you need to work with Docker directly:

```bash
cd /opt/services/<service>

docker compose ps                        # list containers
docker compose logs -f                   # tail logs
docker compose restart                   # restart
docker compose up -d --build             # rebuild and restart
docker compose down                      # stop and remove containers
```
