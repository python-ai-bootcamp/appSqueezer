# Rootless Edge Router & Database Gateway (`appRouter`)

A secure, unprivileged (rootless), and dynamic infrastructure gateway template for Debian/Ubuntu virtual machines, powered by **Traefik v2** and **Podman**.

This repository provides an automated wrapper package to configure a production-ready edge router and shared MongoDB instance, enabling developers to deploy multiple containerized web applications dynamically with zero-downtime and zero manual configurations.

---

## 📂 Project Structure

```text
├── README.md                           # Main project overview
├── appRouter.sh                        # Automation wrapper utility (Setup / Teardown / App Creation)
├── docs/
│   ├── deploymentSpec.md               # Detailed system design, security features & architecture
│   ├── app_router_guide__github_ghcr_app_deployment_guide.md # Workstation -> GHCR -> VM lifecycle
│   └── app_router_guide__developing_app_router_compatible_application.md # Developer guide (port/secrets)
├── templates/
│   └── docker-compose_infra.yaml.template # Parametrized template config for Traefik & MongoDB
└── sampleApps/
    ├── sampleNodeApp/                  # Reference Node.js application using Express & Mongo Secret
    └── samplePythonApp/                # Reference Python application using FastAPI & Mongo Secret
```

---

## ⚡ Quick Start

### 1. One-Time Infrastructure Setup
To initialize the edge router (Traefik) and shared MongoDB database on a clean, vanilla Debian/Ubuntu virtual machine:

```bash
# Clone the repository onto the VM, navigate to directory, then run:
./appRouter.sh install -d api.yourdomain.com -e your-email@domain.com
```

* **`-d` / `--domain`**: The central domain under which all applications will be routed.
* **`-e` / `--email`**: Let's Encrypt renewal notification email.
* MongoDB credentials will be securely auto-generated and saved inside `/opt/web-infrastructure/.env`.

### 2. Deploy an Application (Phase 2)
Once the infrastructure is live, you can deploy containerized applications on-the-fly. The script performs pre-flight contract checks (`--show-spec` query inside the container) to verify that all required options are supplied, provisions an isolated database user via `podman exec`, registers sensitive variables inside Podman Secrets, and runs the container securely:

```bash
# General deployment
./appRouter.sh create-app ghcr.io/username/my-backend-service:latest

# Deployment passing custom app-specific parameters, secrets, and CPU/Memory limits
./appRouter.sh create-app ghcr.io/username/my-backend-service:latest \
  --app-parameter "multiplication_factor=5" \
  --app-secret "ADMIN_PASSWORD=my_secure_prod_password" \
  --cpu "0.5" --memory "512M"
```
* The application will immediately be routed under: `https://api.yourdomain.com/my-backend-service`
* Secrets are mounted dynamically in-memory under `/run/secrets/` (e.g. `MONGO_URI` and `ADMIN_PASSWORD`), protecting sensitive credentials from leaking to disk or environment dumps.
* Container resource allocation is limited strictly to configured limits (e.g. 50% CPU core and 512MB RAM).
* SSL/TLS certificates are requested and renewed **automatically** by Traefik.

### 3. Application Management & Monitoring
Once apps are deployed, you can monitor, restart, reconfigure, update, or safely destroy them through dedicated subcommands:

```bash
# List all deployed apps and check if they are running/stopped
./appRouter.sh list

# View/Stream container logs
./appRouter.sh logs my-backend-service -f --tail 100

# Stop / Start / Restart apps
./appRouter.sh stop my-backend-service
./appRouter.sh start my-backend-service
./appRouter.sh restart my-backend-service

# Reconfigure parameters/limits (retains other settings, merges changes)
./appRouter.sh configure my-backend-service --app-parameter "multiplication_factor=10" --cpu "1.0"
# Cleans up parameters/limits slate before writing new ones
./appRouter.sh configure my-backend-service --clear-app-parameters --clear-app-limits --memory "256M"

# Pull the latest image layers and recreate container in-place
./appRouter.sh update my-backend-service
# Switch app to a different image tag/url, verifying contract requirements
./appRouter.sh update my-backend-service --image ghcr.io/username/my-backend-service:v2.0

# Database Backup & Restore operations
# Take a backup of a single app's database with a suffix description
./appRouter.sh backup --app-name=my-backend-service --description=pre_upgrade
# Take individual backups for ALL deployed apps
./appRouter.sh backup --all

# Restore an app from a specific backup file (purges current collection data first)
./appRouter.sh restore --app-name=my-backend-service --backup-name=2026_06_27__21_46_26__pre_upgrade.gzip
# Restore all apps to their respective latest available backups
./appRouter.sh restore --all

# Completely wipe everything (secrets, parameters, backups, and database data):
./appRouter.sh destroy-app my-backend-service --delete-secrets --delete-parameters --delete-data --delete-backups

# Delete the container & configs, but keep the database backups and secrets intact:
./appRouter.sh destroy-app my-backend-service --keep-secrets --delete-parameters --keep-data --keep-backups
```

---

## 🧹 Teardown

To stop and remove all routing infrastructure, networks, and services:

```bash
# Prompts for confirmation
./appRouter.sh uninstall

# Non-interactive mode (fully automated cleanup for CI/CD)
./appRouter.sh uninstall -y
```

---

## 📖 In-Depth Guides

* See [deploymentSpec.md](file:///c:/code/appRouterProject/appRouter/docs/deploymentSpec.md) for full architectural diagrams, prerequisite specifications, security controls, and auto-restart policies.
* See [app_router_guide__github_ghcr_app_deployment_guide.md](file:///c:/code/appRouterProject/appRouter/docs/app_router_guide__github_ghcr_app_deployment_guide.md) for the complete developer packaging guide (Personal Access Tokens, tagging, pushing to GitHub Container Registry, and production pulls).
* See [app_router_guide__developing_app_router_compatible_application.md](file:///c:/code/appRouterProject/appRouter/docs/app_router_guide__developing_app_router_compatible_application.md) for standards on structuring applications to naturally support dynamic port binding and container secret file reads.
