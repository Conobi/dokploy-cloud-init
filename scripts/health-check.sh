#!/bin/bash
# Health check script for Dokploy installation
# Usage: sudo /opt/scripts/health-check.sh
#
# Note: This is a standalone copy of the script embedded in cloud-init.template.yaml.
# Keep both versions in sync when making changes.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
warned=0
failed=0

check_ok()    { echo -e "  ${GREEN}OK${NC}    $1"; ((passed++)); }
check_warn()  { echo -e "  ${YELLOW}WARN${NC}  $1"; ((warned++)); }
check_fail()  { echo -e "  ${RED}FAIL${NC}  $1"; ((failed++)); }

echo "========================================"
echo "Dokploy Health Check"
echo "========================================"
echo ""

# ── System ──────────────────────────────────
echo "--- System ---"

# Cloud-init
if cloud-init status 2>/dev/null | grep -q "done"; then
    check_ok "Cloud-init completed"
else
    STATUS=$(cloud-init status 2>/dev/null || echo "not available")
    check_warn "Cloud-init: $STATUS"
fi

# Installation marker
if [ -f /var/log/dokploy-installed ]; then
    check_ok "Installation marker present"
else
    check_fail "Installation marker NOT FOUND (/var/log/dokploy-installed)"
fi

# Swap
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
if [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
    check_ok "Swap active (${SWAP_TOTAL}M)"
else
    check_fail "Swap not active"
fi

echo ""

# ── Security ────────────────────────────────
echo "--- Security ---"

# SSH hardening
if [ -f /etc/ssh/sshd_config.d/99-harden.conf ]; then
    check_ok "SSH hardening config present"
else
    check_fail "SSH hardening config missing"
fi

# Fail2ban
if systemctl is-active --quiet fail2ban; then
    JAILS=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}')
    check_ok "Fail2ban running (${JAILS} jail(s))"
else
    check_fail "Fail2ban not running"
fi

# UFW
if ufw status 2>/dev/null | grep -q "Status: active"; then
    check_ok "UFW firewall active"
else
    check_fail "UFW firewall not active"
fi

# Unattended-upgrades
if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
    check_ok "Unattended-upgrades installed"
else
    check_warn "Unattended-upgrades not installed"
fi

echo ""

# ── Tailscale ───────────────────────────────
echo "--- Tailscale ---"

if command -v tailscale &>/dev/null; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$TS_IP" ]; then
        check_ok "Tailscale connected (IP: ${TS_IP})"
    else
        check_fail "Tailscale installed but not connected"
    fi
else
    check_fail "Tailscale not installed"
fi

echo ""

# ── Docker & Swarm ─────────────────────────
echo "--- Docker ---"

if docker info &>/dev/null; then
    check_ok "Docker daemon running"
else
    check_fail "Docker daemon not running"
fi

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    check_ok "Docker Swarm active"
else
    check_fail "Docker Swarm inactive"
fi

if docker network ls | grep -q dokploy-network; then
    check_ok "Dokploy network exists"
else
    check_fail "Dokploy network not found"
fi

echo ""

# ── Dokploy Services ───────────────────────
echo "--- Dokploy Services ---"

SERVICES=("dokploy-postgres" "dokploy-redis" "dokploy")
for SERVICE in "${SERVICES[@]}"; do
    REPLICAS=$(docker service ls --filter "name=$SERVICE" --format "{{.Replicas}}" 2>/dev/null)
    if [ -n "$REPLICAS" ]; then
        CURRENT=$(echo "$REPLICAS" | cut -d'/' -f1)
        DESIRED=$(echo "$REPLICAS" | cut -d'/' -f2)
        if [ "$CURRENT" = "$DESIRED" ] && [ "$CURRENT" != "0" ]; then
            check_ok "$SERVICE ($REPLICAS)"
        else
            check_warn "$SERVICE ($REPLICAS)"
        fi
    else
        check_fail "$SERVICE not found"
    fi
done

# Traefik (runs as container, not service)
if docker ps --filter "name=dokploy-traefik" --format "{{.Status}}" | grep -q "Up"; then
    check_ok "dokploy-traefik running"
else
    check_fail "dokploy-traefik not running"
fi

echo ""

# ── Endpoints ──────────────────────────────
echo "--- Endpoints ---"

if curl -s --connect-timeout 5 http://localhost:3000 >/dev/null 2>&1; then
    check_ok "Dokploy UI (port 3000)"
else
    check_warn "Dokploy UI (port 3000) not accessible yet"
fi

if curl -s --connect-timeout 5 http://localhost:80 >/dev/null 2>&1; then
    check_ok "Traefik HTTP (port 80)"
else
    check_warn "Traefik HTTP (port 80) not accessible"
fi

echo ""

# ── Summary ────────────────────────────────
echo "========================================"
echo -e "Results: ${GREEN}${passed} passed${NC}, ${YELLOW}${warned} warnings${NC}, ${RED}${failed} failed${NC}"
echo "========================================"
echo ""

if [ "$failed" -gt 0 ]; then
    echo "Useful commands:"
    echo "  cat /var/log/dokploy-install.log"
    echo "  cat /var/log/cloud-init-output.log"
    echo "  docker service logs dokploy"
    echo "  tailscale status"
    echo "  ufw status verbose"
    echo "  fail2ban-client status sshd"
    exit 1
fi
