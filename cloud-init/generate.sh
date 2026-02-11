#!/usr/bin/env bash
set -euo pipefail

# Generate a per-environment cloud-init file from the template.
#
# Usage: ./generate.sh <env-file>
# Example: ./generate.sh secrets/dev.env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${1:?Usage: $0 <env-file>}"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: env file '$ENV_FILE' not found" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Validate required variables
for VAR in ENVIRONMENT TAILSCALE_AUTH_KEY DOCKER_SWARM_ADDR_POOL; do
    if [ -z "${!VAR:-}" ]; then
        echo "Error: $VAR is not set in $ENV_FILE" >&2
        exit 1
    fi
done

VM_HOSTNAME="${VM_HOSTNAME:-dokploy-${ENVIRONMENT}}"

export ENVIRONMENT TAILSCALE_AUTH_KEY DOCKER_SWARM_ADDR_POOL VM_HOSTNAME

OUTPUT="${SCRIPT_DIR}/cloud-init-${ENVIRONMENT}.yaml"
envsubst '${ENVIRONMENT} ${TAILSCALE_AUTH_KEY} ${DOCKER_SWARM_ADDR_POOL} ${VM_HOSTNAME}' \
    < "${SCRIPT_DIR}/cloud-init.template.yaml" > "$OUTPUT"

echo "Generated $OUTPUT"
