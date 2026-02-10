# Dokploy Deployment for Azure VM

Automated deployment of Dokploy on Azure VM (Ubuntu 24.04) with Tailscale-only access, security hardening, and reproducible per-environment configs.

## Folder Structure

```
dokploy-cloud-init/
├── README.md
├── cloud-init/
│   ├── cloud-init.template.yaml          # Master template (envsubst placeholders)
│   ├── generate.sh                       # Generates per-env cloud-init from template
│   ├── test-local.sh                     # Local VM testing (Multipass/libvirt)
│   ├── deploy-azure.sh                   # Deploy to Azure VM (cloud-init clean + reboot)
│   ├── Makefile                          # Make targets for all operations
│   ├── .gitignore                        # Ignores secrets/ and generated files
│   └── secrets/
│       └── dev.env.example               # Example env file (copy to dev.env)
├── scripts/
│   └── health-check.sh                   # Post-deployment verification
└── LICENSE
```

## Quick Start

### 1. Prepare Secrets

```bash
cd cloud-init/secrets
cp dev.env.example dev.env
```

Edit `dev.env` with real values:

| Variable | Description |
|----------|-------------|
| `ENVIRONMENT` | Environment name (`dev`, `test`, `prod`) |
| `TAILSCALE_AUTH_KEY` | Tailscale auth key ([admin console](https://login.tailscale.com/admin/settings/keys)) |
| `DOCKER_SWARM_ADDR_POOL` | Swarm overlay CIDR — avoid Azure VNet overlap (e.g. `172.20.0.0/16`) |

### 2. Generate Cloud-Init

```bash
cd cloud-init
./generate.sh secrets/dev.env
# → Generates cloud-init-dev.yaml
```

### 3. Deploy to Azure VM

#### Azure CLI (New VM)

```bash
az vm create \
  --resource-group <resource-group> \
  --name dokploy-dev \
  --image Canonical:ubuntu-24_04-lts:server:latest \
  --size Standard_B2s \
  --admin-username azureuser \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --custom-data @cloud-init/cloud-init-dev.yaml \
  --public-ip-sku Standard
```

#### Azure CLI (Reimage Existing VM)

```bash
az vm reimage \
  --resource-group <resource-group> \
  --name <vm-name> \
  --custom-data @cloud-init/cloud-init-dev.yaml
```

#### Azure Portal

1. Virtual Machines > Create (or Redeploy + Reimage)
2. Select Ubuntu 24.04 LTS
3. In **Advanced** > **Custom data**, paste contents of `cloud-init-dev.yaml`
4. Create / Apply

### 4. Verify Installation

```bash
# Connect via Tailscale (NOT public IP)
ssh azureuser@<TAILSCALE_IP>

# Wait for cloud-init
cloud-init status --wait

# Run health check
sudo /opt/scripts/health-check.sh
```

### 5. Access Dokploy UI

Open `http://<TAILSCALE_IP>:3000` in your browser (requires Tailscale network access).

Create the admin account on first visit, then deploy your application using the Dokploy UI.

## Access Model

SSH and Dokploy UI are **only reachable via Tailscale**. Public internet access is limited to HTTP/HTTPS for Traefik.

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 22 | TCP | Tailscale only | SSH |
| 3000 | TCP | Tailscale only | Dokploy UI |
| 80 | TCP | Public | HTTP (Traefik / Let's Encrypt) |
| 443 | TCP+UDP | Public | HTTPS + HTTP/3 (Traefik) |

```
┌──────────────────────────────────────────────────────────────────┐
│                     Azure VM (Ubuntu 24.04)                      │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Tailscale ──────┐                                               │
│  (tailscale0)    │                                               │
│    SSH :22 ◄─────┤                                               │
│    Dokploy ◄─────┘                                               │
│    UI :3000                                                      │
│                                                                  │
│  Public ─────────┐                                               │
│  (eth0)          │                                               │
│    :80/:443 ◄────┘──► Traefik ──► App Services                   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐      │
│  │                    Docker Swarm                        │      │
│  │  ┌──────────────────────────────────────────────────┐  │      │
│  │  │         Dokploy Infrastructure                   │  │      │
│  │  │  dokploy-postgres · dokploy-redis · dokploy      │  │      │
│  │  └──────────────────────────────────────────────────┘  │      │
│  │  ┌──────────────────────────────────────────────────┐  │      │
│  │  │         Your Application Stack                   │  │      │
│  │  │  (deployed via Dokploy UI)                       │  │      │
│  │  └──────────────────────────────────────────────────┘  │      │
│  └────────────────────────────────────────────────────────┘      │
│                                                                  │
│  UFW: deny incoming (except tailscale0 + 80/443)                 │
│  fail2ban: SSH brute-force protection                            │
│  unattended-upgrades: automatic security patches                 │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Security Hardening

The cloud-init template applies the following automatically:

| Layer | Measure |
|-------|---------|
| **SSH** | Root login disabled, password auth disabled, max 3 attempts |
| **Firewall** | UFW deny-all except Tailscale interface + ports 80/443 |
| **Brute-force** | Fail2ban on SSH (ban after 3 failures, 1h ban) |
| **Patching** | Unattended-upgrades for security updates |
| **VPN** | Tailscale mesh — SSH and Dokploy UI only via Tailscale |
| **Docker** | Log rotation (10MB x 3 files), weekly prune cron, overlay2 driver |
| **System** | 2GB swap, journald size limits, sysctl tuning for Docker networking |

## Cloud-Init Execution Order

1. **write_files** — all config files written before services start
2. **sysctl + journald** — system tuning
3. **Swap** — 2GB memory safety net
4. **SSH restart** — apply hardening config
5. **Zsh + plugins** — install zsh-autosuggestions/syntax-highlighting, set as default shell, disable default MOTD
6. **Fail2ban** — start monitoring before opening network
7. **Tailscale** — establish VPN tunnel
8. **UFW** — lock firewall after Tailscale is up
9. **Dokploy** — official install script (installs Docker, Swarm, Traefik, Dokploy)
10. **Dokploy timezone** — `docker service update --env-add TZ=Europe/Paris`

## Resetting a VM

Use this procedure to wipe the OS and re-provision from scratch with cloud-init. The approach depends on whether the cloud-init config has changed.

### Pre-reset checklist

Before resetting, collect the information you'll need to recreate or verify:

```bash
# Note the VM metadata (resource group, size, IP, etc.)
az vm show --resource-group <resource-group> --name <vm-name> \
  --query '{name:name, size:hardwareProfile.vmSize, rg:resourceGroup, publicIp:publicIps}' -o table

# If you have Dokploy projects to preserve, export their compose/env configs
# from the Dokploy UI before resetting — everything on the OS disk is lost.
```

Also decide whether the Tailscale auth key is **reusable** or **single-use**:
- **Reusable key**: the device will re-register automatically after reset.
- **Single-use key**: you need to remove the old device from [Tailscale admin](https://login.tailscale.com/admin/machines) and generate a new key. Update your `.env` file and regenerate the cloud-init before proceeding.

### Option A: Same cloud-init config (re-run in place)

If the cloud-init template and variables haven't changed, you can re-run it without recreating the VM. This resets the OS state but keeps the same disk and public IP.

```bash
# SSH into the VM (via Tailscale)
ssh azureuser@<TAILSCALE_IP>

# Wipe cloud-init state and reboot — this re-runs ALL cloud-init modules
sudo cloud-init clean --logs
sudo reboot
```

After reboot, wait for cloud-init to finish:

```bash
ssh azureuser@<TAILSCALE_IP>
cloud-init status --wait
sudo /opt/scripts/health-check.sh
```

> **Warning**: `cloud-init clean` only resets cloud-init's internal state. It does **not** reinstall the OS. Packages installed by previous runs remain, Docker volumes persist, etc. For a fully clean slate, use Option B.

### Option B: Updated cloud-init config (delete + recreate)

Azure [does not allow changing custom-data on standalone VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/custom-data). If you've updated the template or env variables, you must delete and recreate the VM.

#### 1. Regenerate cloud-init

```bash
cd cloud-init
# Edit secrets/<env>.env if variables changed (new Tailscale key, etc.)
./generate.sh secrets/<env>.env
```

#### 2. Remove old Tailscale device

Go to [Tailscale admin](https://login.tailscale.com/admin/machines), find `dokploy-<env>`, and remove it. This prevents hostname conflicts when the new VM registers.

#### 3. Delete the VM

```bash
# Delete VM but keep the resource group, NSG, VNet, etc.
az vm delete \
  --resource-group <resource-group> \
  --name <vm-name> \
  --yes

# Optionally clean up the OS disk (listed after deletion)
az disk delete \
  --resource-group <resource-group> \
  --name <os-disk-name> \
  --yes
```

> **Note**: By default `az vm delete` does **not** delete the NIC, public IP, or OS disk. You can add `--force-deletion none` to keep them, or delete them separately if you want a full cleanup.

#### 4. Recreate the VM

```bash
az vm create \
  --resource-group <resource-group> \
  --name dokploy-<env> \
  --image Canonical:ubuntu-24_04-lts:server:latest \
  --size Standard_B2s \
  --admin-username azureuser \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --custom-data @cloud-init/cloud-init-<env>.yaml \
  --public-ip-sku Standard
```

#### 5. Verify

```bash
# Wait for Tailscale to register (check admin console for the new IP)
ssh azureuser@<TAILSCALE_IP>
cloud-init status --wait
sudo /opt/scripts/health-check.sh
```

#### 6. Re-deploy application

The Dokploy admin account and all projects are gone after a full reset. Open `http://<TAILSCALE_IP>:3000`, create the admin account, and deploy your application via the Dokploy UI.

### Option C: Reimage (fresh OS, same cloud-init)

If you want a clean OS disk (not just a cloud-init re-run) but the cloud-init config is unchanged:

```bash
az vm reimage \
  --resource-group <resource-group> \
  --name <vm-name>
```

This replaces the OS disk with a fresh marketplace image and re-runs the **original** custom-data that was provided at VM creation. You cannot supply different custom-data — Azure [rejects mismatches](https://github.com/Azure/azure-cli/issues/26303).

After reimage, remove the stale Tailscale device from the admin console (the machine ID changes), then verify as above.

## Deploy to Azure VM (Automated)

Deploy cloud-init config to an already-running Azure Ubuntu 24.04 VM. The script uploads the config, resets cloud-init state, reboots, and monitors the full provisioning process.

### Usage

```bash
cd cloud-init

# 1. Generate config
make generate ENV=dev

# 2. Deploy with Tailscale (production mode — SSH blocked on public IP)
make deploy AZURE_HOST=<public-ip> ENV=dev

# 3. Or deploy without Tailscale (quick testing — SSH open publicly)
make deploy-no-tailscale AZURE_HOST=<public-ip> ENV=dev
```

### Options

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_HOST` | *(required)* | Azure VM public IP or hostname |
| `ENV` | `dev` | Environment name (matches secrets file) |
| `AZURE_USER` | `azureuser` | SSH user on the VM |
| `AZURE_IDENTITY` | *(default key)* | Path to SSH private key |

Custom SSH user and identity:

```bash
make deploy AZURE_HOST=10.0.0.4 ENV=prod AZURE_USER=ubuntu AZURE_IDENTITY=~/.ssh/azure-key
```

### What the Script Does

1. Verifies SSH connectivity to the VM
2. Checks if the VM was previously provisioned (prompts for confirmation)
3. Uploads the cloud-init config via SCP
4. Places it in `/etc/cloud/cloud.cfg.d/99-dokploy.cfg`
5. Runs `cloud-init clean --logs` to reset state
6. Reboots the VM (SSH disconnects — expected)
7. Waits for SSH on public IP (available before UFW blocks it)
8. Streams the install log as cloud-init runs (10-min timeout)
   - **Tailscale mode**: discovers the Tailscale IP from the VM via `tailscale ip -4`, then switches to it before UFW blocks public SSH. Falls back to local peer discovery if public SSH drops first.
9. Runs the health check script
10. Prints access info (SSH command, Dokploy URL)

### Notes

- In Tailscale mode, UFW blocks SSH on the public IP after provisioning. Use the Tailscale IP shown at the end.
- `cloud-init clean` only resets cloud-init state — it does **not** reinstall the OS. Existing packages and Docker volumes persist.
- For a fully clean slate, use `az vm reimage` or delete + recreate the VM (see [Resetting a VM](#resetting-a-vm)).
- The `--force` flag (via `./deploy-azure.sh --force ...`) skips the re-deployment confirmation prompt.

## Local Testing

Test cloud-init locally before deploying to Azure. The test script auto-detects available backends.

### Supported Backends

| Backend | Best For | Install |
|---------|----------|---------|
| **Multipass** | Ubuntu | `sudo snap install multipass` |
| **libvirt/QEMU** | Arch, Fedora | `sudo pacman -S libvirt qemu-full virt-manager cloud-image-utils` |

### Prerequisites

**Arch Linux (libvirt):**
```bash
sudo pacman -S libvirt qemu-full virt-manager cloud-image-utils
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER  # then re-login
```

**Ubuntu (Multipass):**
```bash
sudo snap install multipass
```

Check your setup with:
```bash
cd cloud-init
make deps
```

### Workflow

```bash
cd cloud-init

# 1. Generate config from template (if not already done)
make generate ENV=dev

# 2. Quick syntax validation (seconds, no VM)
make validate ENV=dev

# 3. Full test with VM (auto-detects backend)
make test ENV=dev

# 4. Or test without Tailscale for faster iteration
make test-no-tailscale ENV=dev

# 5. Debug if needed
make logs
make shell

# 6. Cleanup
make clean
```

Force a specific backend:
```bash
make test ENV=dev BACKEND=libvirt
make test ENV=dev BACKEND=multipass
```

### Available Make Targets

| Target | Description |
|--------|-------------|
| `make deps` | Check installed backends |
| `make generate ENV=dev` | Generate cloud-init from template |
| `make validate ENV=dev` | Validate cloud-init syntax (fast, no VM) |
| `make test ENV=dev` | Full test with VM (auto-detect backend) |
| `make test-no-tailscale` | Test without Tailscale (faster) |
| `make deploy AZURE_HOST=<ip>` | Deploy to an Azure VM |
| `make deploy-no-tailscale AZURE_HOST=<ip>` | Deploy without Tailscale |
| `make clean` | Delete test VM |
| `make status` | Show VM status |
| `make shell` | Shell into test VM |
| `make logs` | View install logs |
| `make logs-full` | View full cloud-init output |

### Testing Considerations

| Component | Testable Locally? | Notes |
|-----------|-------------------|-------|
| Package installation | Yes | Full apt support |
| write_files | Yes | All files written |
| SSH hardening | Yes | sshd restarts work |
| Fail2ban | Yes | Full systemd support |
| UFW firewall | Yes | Kernel support present |
| Swap | Yes | Real VM with kernel |
| Docker + Swarm | Yes | Full Docker support |
| Dokploy install | Yes | Services start normally |
| Tailscale | Partial | Works but joins real tailnet |
| Health check script | Yes | All checks run |

### Tailscale Testing Options

1. **Skip Tailscale** (`--skip-tailscale`): Fastest iteration, tests everything else
2. **Use ephemeral key**: Generate a short-lived auth key in Tailscale admin
3. **Use test tailnet**: Separate tailnet for testing (requires Tailscale Teams)

## Troubleshooting

### Cloud-init failed or stuck

```bash
sudo cat /var/log/cloud-init-output.log
sudo cat /var/log/dokploy-install.log

# Re-run (caution: resets VM state)
sudo cloud-init clean && sudo reboot
```

### Cannot SSH via Tailscale

```bash
# On the VM (if you still have access)
tailscale status
sudo ufw status verbose

# Verify Tailscale interface exists
ip addr show tailscale0
```

### Dokploy UI not accessible

```bash
docker service logs dokploy
sudo ss -tlnp | grep 3000
docker service update --force dokploy
```

### Verify Tailscale-only access

From outside Tailscale network, these should **timeout**:

```bash
ssh azureuser@<PUBLIC_IP>        # → timeout
curl http://<PUBLIC_IP>:3000     # → timeout
```

From Tailscale network, these should **work**:

```bash
ssh azureuser@<TAILSCALE_IP>     # → connected
curl http://<TAILSCALE_IP>:3000  # → Dokploy UI
```

Public HTTP/HTTPS should always work (Traefik):

```bash
curl http://<PUBLIC_IP>           # → Traefik response
```

## License

MIT License. See [LICENSE](LICENSE) for details.
