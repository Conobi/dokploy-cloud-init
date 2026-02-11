#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
SSH_USER="azureuser"
SSH_IDENTITY=""
SKIP_TAILSCALE=false
FORCE=false
AZURE_HOST=""
CLOUD_INIT=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step()  { echo -e "${BLUE}[STEP]${NC} $1" >&2; }

usage() {
    cat <<EOF
Usage: $0 [options] <azure-host> <cloud-init-config>

Deploy cloud-init configuration to an already-running Azure VM.
Uploads the config, resets cloud-init state, reboots, and monitors progress.

Options:
    --user USER         SSH user (default: azureuser)
    --identity KEY      SSH private key path (optional, uses default)
    --skip-tailscale    Remove Tailscale from config (opens SSH publicly)
    --force             Skip re-deployment confirmation
    -h, --help          Show this help message

Examples:
    $0 1.2.3.4 cloud-init-dev.yaml
    $0 --skip-tailscale myvm.eastus.cloudapp.azure.com cloud-init-dev.yaml
    $0 --user ubuntu --identity ~/.ssh/azure-key 10.0.0.4 cloud-init-prod.yaml
EOF
    exit 0
}

# ── Argument Parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            SSH_USER="$2"
            shift 2
            ;;
        --identity)
            SSH_IDENTITY="$2"
            shift 2
            ;;
        --skip-tailscale)
            SKIP_TAILSCALE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            error "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$AZURE_HOST" ]]; then
                AZURE_HOST="$1"
            elif [[ -z "$CLOUD_INIT" ]]; then
                CLOUD_INIT="$1"
            else
                error "Unexpected argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$AZURE_HOST" || -z "$CLOUD_INIT" ]]; then
    error "Missing required arguments: <azure-host> <cloud-init-config>"
    echo "" >&2
    usage
fi

# Resolve cloud-init to absolute path
if [[ ! "$CLOUD_INIT" = /* ]]; then
    CLOUD_INIT="$SCRIPT_DIR/$CLOUD_INIT"
fi

if [[ ! -f "$CLOUD_INIT" ]]; then
    error "Cloud-init file not found: $CLOUD_INIT"
    echo "  Generate it first with: make generate ENV=<env>" >&2
    exit 1
fi

# ── Build SSH/SCP Commands ────────────────────────────────────────────────────

KNOWN_HOSTS=$(mktemp)
cleanup() {
    rm -f "$KNOWN_HOSTS"
    # Clean up deploy temp config if created
    rm -f "$SCRIPT_DIR/.cloud-init-deploy-notailscale.yaml"
}
trap cleanup EXIT

# Use StrictHostKeyChecking=no because cloud-init clean + reboot regenerates
# host keys, so the key WILL change. We use a temp known_hosts file anyway.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=10"
if [[ -n "$SSH_IDENTITY" ]]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_IDENTITY"
fi

ssh_cmd() {
    ssh $SSH_OPTS "${SSH_USER}@${AZURE_HOST}" "$@"
}

scp_cmd() {
    scp $SSH_OPTS "$@"
}

# ── Step 1: Verify SSH Connectivity ──────────────────────────────────────────

step "Verifying SSH connectivity to ${SSH_USER}@${AZURE_HOST}..."

if ! ssh_cmd true 2>/dev/null; then
    error "Cannot connect to ${SSH_USER}@${AZURE_HOST}"
    echo "" >&2
    echo "  Troubleshooting:" >&2
    echo "    - Verify the IP/hostname is correct" >&2
    echo "    - Check your SSH key is authorized on the VM" >&2
    echo "    - Ensure Azure NSG allows SSH (port 22) from your IP" >&2
    if [[ -n "$SSH_IDENTITY" ]]; then
        echo "    - Check the identity file exists: $SSH_IDENTITY" >&2
    fi
    exit 1
fi

info "SSH connection successful"

# ── Step 2: Re-deployment Safety Check ───────────────────────────────────────

if [[ "$FORCE" != "true" ]]; then
    if ssh_cmd "test -f /var/log/dokploy-installed" 2>/dev/null; then
        warn "This VM appears to have been provisioned previously"
        echo "  Found /var/log/dokploy-installed on the VM." >&2
        echo "  Re-deploying will reset cloud-init state and reboot." >&2
        echo "" >&2
        read -p "  Continue with re-deployment? [y/N] " -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            info "Aborted"
            exit 0
        fi
    fi
fi

# ── Step 3: Apply skip-tailscale Modifications ───────────────────────────────

DEPLOY_CONFIG="$CLOUD_INIT"

if [[ "$SKIP_TAILSCALE" == "true" ]]; then
    warn "Skipping Tailscale (--skip-tailscale flag)"
    DEPLOY_CONFIG="$SCRIPT_DIR/.cloud-init-deploy-notailscale.yaml"

    # Remove Tailscale, replace tailscale0 rule with direct SSH access
    sed -e '/# --- 6. Tailscale ---/,/log "Tailscale IP:/d' \
        -e 's/ufw allow in on tailscale0.*/ufw allow 22\/tcp/' \
        "$CLOUD_INIT" > "$DEPLOY_CONFIG"

    info "Tailscale removed from config, SSH will be open publicly"
fi

# ── Step 4: Upload Config to VM ──────────────────────────────────────────────

step "Uploading cloud-init config to VM..."

scp_cmd "$DEPLOY_CONFIG" "${SSH_USER}@${AZURE_HOST}:/tmp/cloud-init-deploy.yaml" 2>/dev/null

info "Config uploaded to /tmp/cloud-init-deploy.yaml"

# ── Step 5: Place Config + Clean + Reboot ────────────────────────────────────

step "Installing config, cleaning cloud-init state, and rebooting..."

ssh_cmd "
    # Remove stale NoCloud seeds and datasource overrides from previous deployments
    sudo rm -rf /var/lib/cloud/seed/nocloud/ /var/lib/cloud/seed/nocloud-net/
    sudo rm -f /etc/cloud/cloud.cfg.d/99-local.cfg

    # Place our config and reset cloud-init
    sudo cp /tmp/cloud-init-deploy.yaml /etc/cloud/cloud.cfg.d/99-dokploy.cfg
    sudo rm -f /tmp/cloud-init-deploy.yaml
    sudo cloud-init clean --logs
    sudo reboot
" 2>/dev/null || true
# SSH disconnect on reboot is expected — the above will exit non-zero

info "Reboot initiated (SSH disconnect expected)"

# ── Step 6: Wait for VM to Go Down ──────────────────────────────────────────

step "Waiting for VM to go down..."

local_attempt=0
local_max=15
while ssh_cmd true 2>/dev/null; do
    sleep 2
    local_attempt=$((local_attempt + 1))
    if [[ $local_attempt -ge $local_max ]]; then
        warn "VM still responding after ${local_max} attempts — proceeding anyway"
        break
    fi
done

if [[ $local_attempt -lt $local_max ]]; then
    info "VM is down, waiting for reboot..."
fi
sleep 30

# ── Step 7: Reconnect via SSH ────────────────────────────────────────────────
# After reboot, try the public IP first. In Tailscale mode, UFW from a
# previous deploy may already block the public IP — if so, discover the
# Tailscale peer and switch to it.

# SSH_TARGET tracks which IP we're connecting to — starts as public IP,
# switches to Tailscale IP once discovered.
SSH_TARGET="$AZURE_HOST"
TAILSCALE_IP=""

# Helper: SSH to current target
run_ssh() {
    ssh $SSH_OPTS "${SSH_USER}@${SSH_TARGET}" "$@"
}

step "Waiting for SSH to come back on ${AZURE_HOST}..."

ssh_attempts=0
# Shorter timeout when Tailscale is active — UFW may already block the public IP
if [[ "$SKIP_TAILSCALE" == "true" ]]; then
    ssh_max=60  # 120s
else
    ssh_max=15  # 30s, then fall back to Tailscale
fi

while ! ssh_cmd true 2>/dev/null; do
    sleep 2
    ssh_attempts=$((ssh_attempts + 1))
    if [[ $ssh_attempts -ge $ssh_max ]]; then
        break
    fi
    if [[ $((ssh_attempts % 10)) -eq 0 ]]; then
        echo "  Still waiting for SSH... ($((ssh_attempts * 2))s)" >&2
    fi
done

if [[ $ssh_attempts -lt $ssh_max ]]; then
    info "SSH available on ${AZURE_HOST}"
elif [[ "$SKIP_TAILSCALE" == "true" ]]; then
    error "SSH not available after $((ssh_max * 2))s"
    echo "  The VM may still be booting. Try connecting manually:" >&2
    echo "    ssh ${SSH_USER}@${AZURE_HOST}" >&2
    exit 1
else
    warn "SSH not available on public IP (UFW likely active from previous deploy)"
    info "Falling back to Tailscale peer discovery..."

    if ! command -v tailscale &>/dev/null; then
        error "Tailscale is not installed on this machine and public SSH is blocked"
        echo "  The VM has likely enabled UFW. Install Tailscale locally or" >&2
        echo "  re-deploy with --skip-tailscale" >&2
        exit 1
    fi

    # Extract expected Tailscale hostname from cloud-init config
    ts_hostname=$(grep -oP '(?<=--hostname=)\S+' "$CLOUD_INIT" | head -1 || true)
    if [[ -z "$ts_hostname" ]]; then
        ts_hostname=$(grep "^hostname:" "$CLOUD_INIT" | awk '{print $2}')
    fi
    if [[ -z "$ts_hostname" ]]; then
        ts_hostname="dokploy"
    fi

    step "Looking for Tailscale peer '$ts_hostname'..."
    ts_peer_attempts=0
    ts_peer_max=60  # 2 minutes

    while true; do
        ts_ip=$(tailscale status --json 2>/dev/null | jq -r \
            ".Peer[] | select(.HostName == \"$ts_hostname\") | .TailscaleIPs[0] // empty" 2>/dev/null || true)

        if [[ -n "$ts_ip" ]]; then
            TAILSCALE_IP="$ts_ip"
            SSH_TARGET="$ts_ip"
            info "Tailscale peer found: $ts_hostname ($ts_ip)"
            break
        fi

        ts_peer_attempts=$((ts_peer_attempts + 1))
        if [[ $ts_peer_attempts -ge $ts_peer_max ]]; then
            error "Tailscale peer '$ts_hostname' not found and public SSH is blocked"
            echo "  Possible causes:" >&2
            echo "    - TAILSCALE_AUTH_KEY is expired or already used (single-use)" >&2
            echo "    - Cloud-init failed before reaching the Tailscale step" >&2
            echo "    - The VM cannot reach the Tailscale coordination server" >&2
            echo "" >&2
            echo "  To diagnose, try accessing the VM serial console in Azure Portal" >&2
            exit 1
        fi
        if [[ $((ts_peer_attempts % 15)) -eq 0 ]]; then
            echo "  Still waiting for Tailscale peer... ($((ts_peer_attempts * 2))s)" >&2
        fi

        sleep 2
    done

    # Wait for SSH on Tailscale IP
    step "Waiting for SSH via Tailscale ($TAILSCALE_IP)..."
    ts_ssh_attempts=0
    while ! run_ssh true 2>/dev/null; do
        sleep 2
        ts_ssh_attempts=$((ts_ssh_attempts + 1))
        if [[ $ts_ssh_attempts -ge 30 ]]; then
            error "SSH not available via Tailscale after 60s"
            exit 1
        fi
    done
    info "SSH available via Tailscale ($TAILSCALE_IP)"
fi

# ── Step 8: Poll Cloud-Init Status ──────────────────────────────────────────
# Monitor cloud-init via public IP SSH. In Tailscale mode, also probe
# `tailscale ip -4` on the VM to discover the Tailscale IP and switch
# to it before UFW blocks the public IP.

step "Waiting for cloud-init to complete..."

seen_lines=0
poll_timeout=600  # 10 minutes
poll_start=$SECONDS
consecutive_ssh_failures=0

while true; do
    # Check SSH connectivity separately from cloud-init status.
    # cloud-init status returns exit code 2 when running, which would
    # falsely trigger "ssh_failed" if we checked both in one command.
    if run_ssh true 2>/dev/null; then
        consecutive_ssh_failures=0
        # cloud-init status may return non-zero (exit 2 = running), capture output regardless
        status=$(run_ssh "cloud-init status 2>&1" 2>/dev/null) || true
        if [[ -z "$status" ]]; then
            status="not_ready"
        fi
    else
        status="ssh_failed"
        consecutive_ssh_failures=$((consecutive_ssh_failures + 1))
    fi

    # Stream new lines from install log
    new_lines=$(run_ssh "tail -n +$((seen_lines + 1)) /var/log/dokploy-install.log 2>/dev/null" 2>/dev/null || true)
    if [[ -n "$new_lines" ]]; then
        while IFS= read -r line; do
            echo "  $line" >&2
        done <<< "$new_lines"
        seen_lines=$((seen_lines + $(echo "$new_lines" | wc -l)))
    fi

    # In Tailscale mode: discover Tailscale IP from the VM
    if [[ "$SKIP_TAILSCALE" != "true" && -z "$TAILSCALE_IP" ]]; then
        ts_ip_remote=$(run_ssh "tailscale ip -4 2>/dev/null" 2>/dev/null || true)
        # Tailscale IPs are in the 100.x.x.x CGNAT range
        if [[ -n "$ts_ip_remote" && "$ts_ip_remote" =~ ^100\. ]]; then
            TAILSCALE_IP="$ts_ip_remote"
            info "Tailscale IP discovered: $TAILSCALE_IP"
            # Switch to Tailscale IP for all subsequent SSH
            SSH_TARGET="$TAILSCALE_IP"
            consecutive_ssh_failures=0
            # Verify SSH works on Tailscale IP
            if ! run_ssh true 2>/dev/null; then
                warn "SSH not yet available on Tailscale IP, will retry"
            fi
        fi
    fi

    # If SSH on public IP died (UFW kicked in) and we don't have TS IP yet,
    # fall back to local Tailscale peer discovery
    if [[ $consecutive_ssh_failures -ge 6 && "$SKIP_TAILSCALE" != "true" && -z "$TAILSCALE_IP" ]]; then
        warn "SSH on public IP lost (UFW likely active), trying local Tailscale peer discovery..."

        if ! command -v tailscale &>/dev/null; then
            error "Tailscale is not installed on this machine and public SSH is blocked"
            echo "  The VM has likely enabled UFW. Install Tailscale locally or" >&2
            echo "  re-deploy with --skip-tailscale" >&2
            exit 1
        fi

        # Extract expected Tailscale hostname from cloud-init config
        ts_hostname=$(grep -oP '(?<=--hostname=)\S+' "$CLOUD_INIT" | head -1 || true)
        if [[ -z "$ts_hostname" ]]; then
            ts_hostname=$(grep "^hostname:" "$CLOUD_INIT" | awk '{print $2}')
        fi
        if [[ -z "$ts_hostname" ]]; then
            ts_hostname="dokploy"
        fi

        step "Looking for Tailscale peer '$ts_hostname'..."
        ts_peer_attempts=0
        ts_peer_max=60  # 2 minutes

        while true; do
            ts_ip=$(tailscale status --json 2>/dev/null | jq -r \
                ".Peer[] | select(.HostName == \"$ts_hostname\") | .TailscaleIPs[0] // empty" 2>/dev/null || true)

            if [[ -n "$ts_ip" ]]; then
                TAILSCALE_IP="$ts_ip"
                SSH_TARGET="$ts_ip"
                info "Tailscale peer found: $ts_hostname ($ts_ip)"
                break
            fi

            ts_peer_attempts=$((ts_peer_attempts + 1))
            if [[ $ts_peer_attempts -ge $ts_peer_max ]]; then
                error "Tailscale peer '$ts_hostname' not found and public SSH is blocked"
                echo "  Possible causes:" >&2
                echo "    - TAILSCALE_AUTH_KEY is expired or already used (single-use)" >&2
                echo "    - Cloud-init failed before reaching the Tailscale step" >&2
                echo "    - The VM cannot reach the Tailscale coordination server" >&2
                echo "" >&2
                echo "  To diagnose, try accessing the VM serial console in Azure Portal" >&2
                exit 1
            fi
            if [[ $((ts_peer_attempts % 15)) -eq 0 ]]; then
                echo "  Still waiting for Tailscale peer... ($((ts_peer_attempts * 2))s)" >&2
            fi

            sleep 2
        done

        # Wait for SSH on Tailscale IP
        step "Waiting for SSH via Tailscale ($TAILSCALE_IP)..."
        ts_ssh_attempts=0
        while ! run_ssh true 2>/dev/null; do
            sleep 2
            ts_ssh_attempts=$((ts_ssh_attempts + 1))
            if [[ $ts_ssh_attempts -ge 30 ]]; then
                error "SSH not available via Tailscale after 60s"
                exit 1
            fi
        done
        consecutive_ssh_failures=0
        info "SSH available via Tailscale ($TAILSCALE_IP)"
    fi

    # If SSH keeps failing with no recovery path, bail
    if [[ $consecutive_ssh_failures -ge 6 && "$SKIP_TAILSCALE" == "true" ]]; then
        error "SSH connection lost on ${AZURE_HOST}"
        echo "  Cloud-init may have failed or the VM is unreachable." >&2
        exit 1
    fi

    # Match cloud-init status
    case "$status" in
        *"status: done"*)
            break
            ;;
        *"status: error"*)
            if echo "$status" | grep -q "recoverable"; then
                warn "Cloud-init completed with recoverable errors (non-critical)"
                break
            fi
            error "Cloud-init failed (status: error)"
            echo "  Full status: $status" >&2
            echo "" >&2
            echo "  Check logs:" >&2
            echo "    ssh ${SSH_USER}@${SSH_TARGET} 'tail -100 /var/log/cloud-init-output.log'" >&2
            exit 1
            ;;
        *"status: running"*|*"status: not started"*|*"ssh_failed"*|*"not_ready"*)
            # Still in progress, SSH hiccup, or cloud-init not yet started
            ;;
        *)
            warn "Unexpected cloud-init status: $status"
            ;;
    esac

    # Timeout check
    if [[ $((SECONDS - poll_start)) -ge $poll_timeout ]]; then
        error "Timed out waiting for cloud-init (${poll_timeout}s)"
        echo "  Cloud-init may still be running. Check manually:" >&2
        echo "    ssh ${SSH_USER}@${SSH_TARGET} 'cloud-init status'" >&2
        exit 1
    fi

    sleep 5
done

info "Cloud-init completed"

# ── Step 9: Health Check ─────────────────────────────────────────────────────

step "Running health check..."
run_ssh "sudo /opt/scripts/health-check.sh" 2>/dev/null || true

# ── Step 10: Print Access Info ───────────────────────────────────────────────

echo "" >&2
info "Deployment complete!"
echo "" >&2
if [[ -n "$TAILSCALE_IP" ]]; then
    echo "  SSH (Tailscale): ssh ${SSH_USER}@${TAILSCALE_IP}" >&2
    echo "  SSH (Azure IP):  blocked by UFW (Tailscale-only mode)" >&2
    echo "  Dokploy UI:      http://${TAILSCALE_IP}:3000" >&2
else
    echo "  SSH:         ssh ${SSH_USER}@${SSH_TARGET}" >&2
    echo "  Dokploy UI:  http://${SSH_TARGET}:3000" >&2
fi
echo "  Logs:        ssh ${SSH_USER}@${SSH_TARGET} 'cat /var/log/dokploy-install.log'" >&2
echo "" >&2
