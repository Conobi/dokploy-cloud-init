#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="dokploy-test"
CLOUD_INIT=""
MEMORY="2048"  # MB for libvirt, will be converted for multipass
DISK="10"      # GB
BACKEND=""     # auto-detect if empty

# Cache/work directories (libvirt needs files in a qemu-accessible location)
USER_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cloud-init-test"
LIBVIRT_IMAGES_DIR="/var/lib/libvirt/images/cloud-init-test"
UBUNTU_VERSION="24.04"
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
UBUNTU_IMAGE_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"

# Libvirt connection URI (system for networking support)
LIBVIRT_URI="qemu:///system"

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
Usage: $0 [options] [cloud-init-file]

Test cloud-init configuration locally using Multipass or libvirt/QEMU.

Options:
    --name NAME         VM name (default: dokploy-test)
    --backend BACKEND   Force backend: multipass, libvirt (default: auto-detect)
    --skip-tailscale    Remove Tailscale setup for local testing
    --cleanup           Delete VM after test completes
    --memory MB         Memory in MB (default: 2048)
    --disk GB           Disk size in GB (default: 10)
    -h, --help          Show this help message

Backends:
    multipass           Best on Ubuntu, uses Multipass VMs
    libvirt             Best on Arch/Fedora, uses QEMU/KVM via libvirt

Examples:
    $0 cloud-init-dev.yaml
    $0 --skip-tailscale cloud-init-dev.yaml
    $0 --backend libvirt --skip-tailscale cloud-init-dev.yaml
    $0 --name my-test --cleanup cloud-init-dev.yaml
EOF
    exit 0
}

# ── Backend Detection ──────────────────────────────────────────────────────────

detect_backend() {
    if [[ -n "$BACKEND" ]]; then
        echo "$BACKEND"
        return
    fi

    # Prefer multipass if available (simpler)
    if command -v multipass &>/dev/null; then
        echo "multipass"
    elif command -v virsh &>/dev/null && command -v virt-install &>/dev/null; then
        echo "libvirt"
    else
        echo ""
    fi
}

check_libvirt_deps() {
    local missing=()

    for cmd in virsh virt-install cloud-localds qemu-img; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        echo "" >&2
        echo "Install on Arch Linux:" >&2
        echo "  sudo pacman -S libvirt qemu-full virt-manager cloud-image-utils" >&2
        echo "  sudo systemctl enable --now libvirtd" >&2
        echo "  sudo usermod -aG libvirt \$USER  # then re-login" >&2
        exit 1
    fi

    # Check libvirtd is running
    if ! systemctl is-active --quiet libvirtd; then
        error "libvirtd service is not running"
        echo "" >&2
        echo "Start it with:" >&2
        echo "  sudo systemctl enable --now libvirtd" >&2
        exit 1
    fi

    # Check user is in libvirt group
    if ! groups | grep -qw libvirt; then
        warn "User not in libvirt group - you may need sudo for virsh commands"
    fi

    # Check default network exists and is active
    if ! virsh --connect "$LIBVIRT_URI" net-info default &>/dev/null; then
        error "libvirt 'default' network not found"
        echo "" >&2
        echo "Create and start it with:" >&2
        echo "  sudo virsh net-define /usr/share/libvirt/networks/default.xml" >&2
        echo "  sudo virsh net-start default" >&2
        echo "  sudo virsh net-autostart default" >&2
        exit 1
    fi

    if ! virsh --connect "$LIBVIRT_URI" net-list --name 2>/dev/null | grep -q "^default$"; then
        error "libvirt 'default' network is not active"
        echo "" >&2
        echo "Start it with:" >&2
        echo "  sudo virsh net-start default" >&2
        echo "  sudo virsh net-autostart default  # optional: start on boot" >&2
        exit 1
    fi
}

# ── SSH Key Detection ──────────────────────────────────────────────────────────

find_ssh_pubkey() {
    local key_files=("$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub")

    for key_file in "${key_files[@]}"; do
        if [[ -f "$key_file" ]]; then
            echo "$key_file"
            return
        fi
    done

    echo ""
}

# Inject SSH public key into cloud-init config for local testing
inject_ssh_key() {
    local config="$1"
    local output="$2"

    local key_file
    key_file=$(find_ssh_pubkey)

    if [[ -z "$key_file" ]]; then
        warn "No SSH public key found in ~/.ssh/ - VM will not be accessible via SSH"
        warn "Generate one with: ssh-keygen -t ed25519"
        cp "$config" "$output"
        return
    fi

    local pubkey
    pubkey=$(cat "$key_file")
    info "Injecting SSH key: $key_file"

    # Insert ssh_authorized_keys before write_files (a known top-level key)
    awk -v key="$pubkey" '
        /^write_files:/ {
            print "ssh_authorized_keys:"
            print "  - " key
            print ""
        }
        { print }
    ' "$config" > "$output"
}

# ── Cloud Image Management ─────────────────────────────────────────────────────

download_cloud_image() {
    mkdir -p "$USER_CACHE_DIR"

    local image_path="$USER_CACHE_DIR/$UBUNTU_IMAGE_NAME"

    if [[ -f "$image_path" ]]; then
        info "Using cached Ubuntu cloud image"
    else
        step "Downloading Ubuntu ${UBUNTU_VERSION} cloud image..."
        curl -L -o "$image_path" "$UBUNTU_IMAGE_URL"
        info "Downloaded to $image_path"
    fi

    echo "$image_path"
}

# Copy base image to libvirt-accessible location
prepare_libvirt_image() {
    local src="$1"
    sudo mkdir -p "$LIBVIRT_IMAGES_DIR"
    local dst="$LIBVIRT_IMAGES_DIR/$UBUNTU_IMAGE_NAME"

    if [[ ! -f "$dst" ]] || [[ "$src" -nt "$dst" ]]; then
        step "Copying base image to libvirt storage..."
        sudo cp "$src" "$dst"
        sudo chown libvirt-qemu:libvirt-qemu "$dst"
    fi

    echo "$dst"
}

# ── Multipass Backend ──────────────────────────────────────────────────────────

multipass_cleanup() {
    if multipass info "$VM_NAME" &>/dev/null; then
        info "Cleaning up Multipass VM: $VM_NAME"
        multipass delete "$VM_NAME" --purge
    fi
}

multipass_test() {
    local config="$1"

    # Cleanup existing VM if present
    if multipass info "$VM_NAME" &>/dev/null; then
        warn "VM '$VM_NAME' already exists, deleting..."
        multipass delete "$VM_NAME" --purge
    fi

    # Launch VM
    step "Launching Multipass VM: $VM_NAME (memory=${MEMORY}M, disk=${DISK}G)"
    multipass launch "$UBUNTU_VERSION" \
        --name "$VM_NAME" \
        --cloud-init "$config" \
        --memory "${MEMORY}M" \
        --disk "${DISK}G"

    # Wait for cloud-init to complete
    step "Waiting for cloud-init to complete..."
    if ! multipass exec "$VM_NAME" -- cloud-init status --wait; then
        error "Cloud-init failed"
        echo ""
        echo "Last 50 lines of cloud-init output:"
        multipass exec "$VM_NAME" -- tail -50 /var/log/cloud-init-output.log
        return 1
    fi

    # Run health check
    step "Running health check..."
    multipass exec "$VM_NAME" -- sudo /opt/scripts/health-check.sh || true

    # Show access info
    local vm_ip
    vm_ip=$(multipass info "$VM_NAME" --format csv | tail -1 | cut -d',' -f3)

    echo ""
    info "VM ready!"
    echo ""
    echo "  SSH:     multipass shell $VM_NAME"
    echo "  IP:      $vm_ip"
    echo "  Dokploy: http://$vm_ip:3000"
    echo "  Logs:    multipass exec $VM_NAME -- cat /var/log/dokploy-install.log"
    echo "  Cleanup: multipass delete $VM_NAME --purge"
    echo ""
}

# ── Libvirt Backend ────────────────────────────────────────────────────────────

libvirt_cleanup() {
    # Stop and undefine VM
    if virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" &>/dev/null; then
        info "Cleaning up libvirt VM: $VM_NAME"
        virsh --connect "$LIBVIRT_URI" destroy "$VM_NAME" 2>/dev/null || true
        # Don't use --remove-all-storage (would delete base image too)
        virsh --connect "$LIBVIRT_URI" undefine "$VM_NAME" 2>/dev/null || true
    fi

    # Cleanup per-VM work files (keep base image for reuse)
    sudo rm -f "$LIBVIRT_IMAGES_DIR/${VM_NAME}-disk.qcow2"
    sudo rm -f "$LIBVIRT_IMAGES_DIR/${VM_NAME}-seed.iso"
}

libvirt_test() {
    local config="$1"

    check_libvirt_deps

    # Download base image to user cache, then copy to libvirt storage
    local user_image
    user_image=$(download_cloud_image)
    local base_image
    base_image=$(prepare_libvirt_image "$user_image")

    # Work files in libvirt-accessible directory
    local disk_image="$LIBVIRT_IMAGES_DIR/${VM_NAME}-disk.qcow2"
    local seed_iso="$LIBVIRT_IMAGES_DIR/${VM_NAME}-seed.iso"

    # Cleanup existing VM if present
    if virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" &>/dev/null; then
        warn "VM '$VM_NAME' already exists, deleting..."
        libvirt_cleanup
    fi

    # Create disk from base image
    step "Creating VM disk (${DISK}G)..."
    sudo qemu-img create -f qcow2 -b "$base_image" -F qcow2 "$disk_image" "${DISK}G"
    sudo chown libvirt-qemu:libvirt-qemu "$disk_image"

    # Inject local SSH key for test access
    local test_config
    test_config=$(mktemp)
    inject_ssh_key "$config" "$test_config"

    # Create seed ISO with cloud-init config
    step "Creating cloud-init seed ISO..."

    # Create meta-data file (required by NoCloud)
    local meta_data
    meta_data=$(mktemp)
    cat > "$meta_data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

    sudo cloud-localds -v "$seed_iso" "$test_config" "$meta_data"
    sudo chown libvirt-qemu:libvirt-qemu "$seed_iso"
    rm -f "$meta_data" "$test_config"

    # Create VM
    step "Creating libvirt VM: $VM_NAME (memory=${MEMORY}M, disk=${DISK}G)"
    virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$VM_NAME" \
        --memory "$MEMORY" \
        --vcpus 2 \
        --disk "$disk_image",device=disk,bus=virtio \
        --disk "$seed_iso",device=cdrom \
        --os-variant ubuntu24.04 \
        --network network=default,model=virtio \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --import

    # Wait for VM to get an IP
    step "Waiting for VM to boot and get IP address..."
    local vm_ip=""
    local max_attempts=60
    local attempt=0

    while [[ -z "$vm_ip" && $attempt -lt $max_attempts ]]; do
        sleep 2
        vm_ip=$(virsh --connect "$LIBVIRT_URI" domifaddr "$VM_NAME" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
        attempt=$((attempt + 1))
        if [[ $((attempt % 10)) -eq 0 ]]; then
            echo "  Still waiting for IP... (${attempt}/${max_attempts})" >&2
        fi
    done

    if [[ -z "$vm_ip" ]]; then
        error "Failed to get VM IP address"
        echo ""
        echo "Debug with:"
        echo "  virsh console $VM_NAME"
        echo "  virsh domifaddr $VM_NAME"
        return 1
    fi

    info "VM libvirt IP: $vm_ip"

    # Shared SSH options: temp known_hosts so the key persists across calls
    local known_hosts
    known_hosts=$(mktemp)
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$known_hosts -o ConnectTimeout=5"

    # Determine SSH target: Tailscale IP (full test) or libvirt IP (skip-tailscale)
    local ssh_target="$vm_ip"

    if [[ "$SKIP_TAILSCALE" == "true" ]]; then
        # Direct SSH via libvirt network
        step "Waiting for SSH to be available..."
        local ssh_attempts=0
        local ssh_max=60

        while ! ssh $ssh_opts "ubuntu@$ssh_target" true 2>/dev/null; do
            sleep 2
            ssh_attempts=$((ssh_attempts + 1))
            if [[ $ssh_attempts -ge $ssh_max ]]; then
                rm -f "$known_hosts"
                error "SSH not available after ${ssh_max} attempts"
                return 1
            fi
            if [[ $((ssh_attempts % 10)) -eq 0 ]]; then
                echo "  Still waiting for SSH... (${ssh_attempts}/${ssh_max})" >&2
            fi
        done
    else
        # SSH via Tailscale — wait for the node to join the tailnet
        if ! command -v tailscale &>/dev/null; then
            rm -f "$known_hosts"
            error "Tailscale is not installed on this machine"
            echo "  Install it or use --skip-tailscale for local testing" >&2
            return 1
        fi

        # Extract expected Tailscale hostname from cloud-init config
        local ts_hostname
        ts_hostname=$(grep "^hostname:" "$config" | awk '{print $2}')
        if [[ -z "$ts_hostname" ]]; then
            ts_hostname="$VM_NAME"
        fi

        step "Waiting for Tailscale node '$ts_hostname' to join tailnet..."
        local ts_attempts=0
        local ts_max=120  # 4 minutes (Tailscale install + connect takes time)

        while true; do
            local ts_ip
            ts_ip=$(tailscale status --json 2>/dev/null | jq -r \
                ".Peer[] | select(.HostName == \"$ts_hostname\") | .TailscaleIPs[0] // empty" 2>/dev/null || true)

            if [[ -n "$ts_ip" ]]; then
                ssh_target="$ts_ip"
                info "Tailscale node found: $ts_hostname ($ts_ip)"
                break
            fi

            ts_attempts=$((ts_attempts + 1))
            if [[ $ts_attempts -ge $ts_max ]]; then
                rm -f "$known_hosts"
                error "Tailscale node '$ts_hostname' did not appear after $((ts_max * 2))s"
                echo "  Check your TAILSCALE_AUTH_KEY and that the VM has internet access" >&2
                echo "  Debug: virsh --connect $LIBVIRT_URI console $VM_NAME" >&2
                return 1
            fi
            if [[ $((ts_attempts % 15)) -eq 0 ]]; then
                echo "  Still waiting for Tailscale node... ($((ts_attempts * 2))s)" >&2
            fi

            sleep 2
        done

        # Wait for SSH over Tailscale
        step "Waiting for SSH via Tailscale ($ssh_target)..."
        local ssh_attempts=0
        local ssh_max=30

        while ! ssh $ssh_opts "ubuntu@$ssh_target" true 2>/dev/null; do
            sleep 2
            ssh_attempts=$((ssh_attempts + 1))
            if [[ $ssh_attempts -ge $ssh_max ]]; then
                rm -f "$known_hosts"
                error "SSH not available via Tailscale after ${ssh_max} attempts"
                return 1
            fi
        done
    fi

    info "SSH available ($ssh_target)"

    # Wait for cloud-init to complete, polling install log for progress
    step "Waiting for cloud-init to complete..."

    local seen_lines=0

    local poll_timeout=600  # 10 minutes max
    local poll_start=$SECONDS

    while true; do
        # Get cloud-init status (full output for precise matching)
        local status
        status=$(ssh $ssh_opts "ubuntu@$ssh_target" "cloud-init status" 2>/dev/null) || status="ssh_failed"

        # Show all new install log lines since last poll
        local new_lines
        new_lines=$(ssh $ssh_opts "ubuntu@$ssh_target" "tail -n +$((seen_lines + 1)) /var/log/dokploy-install.log 2>/dev/null" 2>/dev/null || true)
        if [[ -n "$new_lines" ]]; then
            while IFS= read -r line; do
                echo "  $line" >&2
            done <<< "$new_lines"
            seen_lines=$((seen_lines + $(echo "$new_lines" | wc -l)))
        fi

        # Match explicit cloud-init status values
        case "$status" in
            *"status: done"*)
                break
                ;;
            *"status: error"*)
                # "recoverable error" is non-fatal
                if echo "$status" | grep -q "recoverable"; then
                    warn "Cloud-init completed with recoverable errors (non-critical)"
                    break
                fi
                error "Cloud-init failed (status: error)"
                echo "  Full status output: $status" >&2
                echo "" >&2
                echo "  Check logs: ssh ubuntu@$ssh_target 'tail -100 /var/log/cloud-init-output.log'" >&2
                return 1
                ;;
            *"status: running"*|*"status: not started"*|*"ssh_failed"*)
                # Still in progress or SSH hiccup, keep waiting
                ;;
            *)
                # Unknown status, log it and keep waiting
                warn "Unexpected cloud-init status: $status"
                ;;
        esac

        # Timeout check
        if [[ $((SECONDS - poll_start)) -ge $poll_timeout ]]; then
            error "Timed out waiting for cloud-init (${poll_timeout}s)"
            return 1
        fi

        sleep 5
    done

    info "Cloud-init completed"

    # Run health check
    step "Running health check..."
    ssh $ssh_opts "ubuntu@$ssh_target" "sudo /opt/scripts/health-check.sh" 2>/dev/null || true

    # Clean up temp known_hosts
    rm -f "$known_hosts"

    # Show access info
    echo "" >&2
    info "VM ready!"
    echo "" >&2
    echo "  SSH:     ssh ubuntu@$ssh_target" >&2
    if [[ "$ssh_target" != "$vm_ip" ]]; then
        echo "  TS IP:   $ssh_target (Tailscale)" >&2
        echo "  VM IP:   $vm_ip (libvirt, not SSH-accessible)" >&2
    else
        echo "  IP:      $ssh_target" >&2
    fi
    echo "  Dokploy: http://$ssh_target:3000" >&2
    echo "  Console: virsh --connect $LIBVIRT_URI console $VM_NAME" >&2
    echo "  Logs:    ssh ubuntu@$ssh_target 'cat /var/log/dokploy-install.log'" >&2
    echo "  Cleanup: virsh --connect $LIBVIRT_URI destroy $VM_NAME && virsh --connect $LIBVIRT_URI undefine $VM_NAME" >&2
    echo "" >&2
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Parse arguments
SKIP_TAILSCALE=false
AUTO_CLEANUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            VM_NAME="$2"
            shift 2
            ;;
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --disk)
            DISK="$2"
            shift 2
            ;;
        --skip-tailscale)
            SKIP_TAILSCALE=true
            shift
            ;;
        --cleanup)
            AUTO_CLEANUP=true
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
            CLOUD_INIT="$1"
            shift
            ;;
    esac
done

# Default cloud-init file
if [[ -z "$CLOUD_INIT" ]]; then
    CLOUD_INIT="$SCRIPT_DIR/cloud-init-dev.yaml"
fi

# Resolve to absolute path
if [[ ! "$CLOUD_INIT" = /* ]]; then
    CLOUD_INIT="$SCRIPT_DIR/$CLOUD_INIT"
fi

if [[ ! -f "$CLOUD_INIT" ]]; then
    error "Cloud-init file not found: $CLOUD_INIT"
    echo ""
    echo "Generate it first with:"
    echo "  ./generate.sh secrets/dev.env"
    exit 1
fi

# Detect backend
BACKEND=$(detect_backend)

if [[ -z "$BACKEND" ]]; then
    error "No supported backend found"
    echo ""
    echo "Install one of:"
    echo ""
    echo "  Multipass (Ubuntu):"
    echo "    sudo snap install multipass"
    echo ""
    echo "  Libvirt/QEMU (Arch/Fedora):"
    echo "    sudo pacman -S libvirt qemu-full virt-manager cloud-image-utils"
    echo "    sudo systemctl enable --now libvirtd"
    echo "    sudo usermod -aG libvirt \$USER"
    exit 1
fi

info "Using backend: $BACKEND"

# Validate cloud-init syntax
step "Validating cloud-init syntax..."
if command -v cloud-init &>/dev/null; then
    if ! cloud-init schema --config-file "$CLOUD_INIT" 2>&1; then
        error "Cloud-init schema validation failed"
        exit 1
    fi
else
    warn "cloud-init not installed locally, skipping schema validation"
fi
info "Syntax validation passed"

# Optionally create a modified config without Tailscale
TEST_CONFIG="$CLOUD_INIT"
if [[ "$SKIP_TAILSCALE" == "true" ]]; then
    warn "Skipping Tailscale (--skip-tailscale flag)"
    TEST_CONFIG="$SCRIPT_DIR/.cloud-init-test-notailscale.yaml"

    # Remove Tailscale, replace tailscale0 rule with direct SSH access
    sed -e '/# --- 6. Tailscale ---/,/log "Tailscale IP:/d' \
        -e 's/ufw allow in on tailscale0.*/ufw allow 22\/tcp/' \
        "$CLOUD_INIT" > "$TEST_CONFIG"
fi

info "Cloud-init: $(basename "$TEST_CONFIG")"

# Run test based on backend
case "$BACKEND" in
    multipass)
        multipass_test "$TEST_CONFIG"
        if [[ "$AUTO_CLEANUP" == "true" ]]; then
            info "Auto-cleanup enabled, deleting VM..."
            multipass_cleanup
        fi
        ;;
    libvirt)
        libvirt_test "$TEST_CONFIG"
        if [[ "$AUTO_CLEANUP" == "true" ]]; then
            info "Auto-cleanup enabled, deleting VM..."
            libvirt_cleanup
        fi
        ;;
    *)
        error "Unknown backend: $BACKEND"
        exit 1
        ;;
esac
