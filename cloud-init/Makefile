.PHONY: validate test test-no-tailscale deploy deploy-no-tailscale clean generate status shell logs help deps

SHELL := /bin/bash
VM_NAME ?= dokploy-test
ENV ?= dev
BACKEND ?=  # auto-detect if empty
LIBVIRT_URI ?= qemu:///system

# Azure deploy variables
AZURE_HOST ?=
AZURE_USER ?= azureuser
AZURE_IDENTITY ?=

help:
	@echo "Cloud-init development targets:"
	@echo ""
	@echo "  make generate ENV=dev       Generate cloud-init from template"
	@echo "  make validate ENV=dev       Validate cloud-init syntax (fast)"
	@echo "  make test ENV=dev           Full test with VM"
	@echo "  make test-no-tailscale      Test without Tailscale (faster)"
	@echo "  make deploy AZURE_HOST=<ip> Deploy to an Azure VM"
	@echo "  make deploy-no-tailscale    Deploy without Tailscale"
	@echo "  make clean                  Delete test VM"
	@echo "  make status                 Show VM status"
	@echo "  make shell                  Shell into test VM"
	@echo "  make logs                   View install logs"
	@echo "  make deps                   Check/install dependencies"
	@echo ""
	@echo "Variables:"
	@echo "  ENV            Environment name (default: dev)"
	@echo "  VM_NAME        VM name (default: dokploy-test)"
	@echo "  BACKEND        Force backend: multipass, libvirt (default: auto-detect)"
	@echo "  AZURE_HOST     Azure VM IP or hostname (required for deploy)"
	@echo "  AZURE_USER     SSH user on Azure VM (default: azureuser)"
	@echo "  AZURE_IDENTITY SSH private key path (optional)"

# Check dependencies
deps:
	@echo "Checking available backends..."
	@echo ""
	@if command -v multipass &>/dev/null; then \
		echo "  ✓ Multipass: $$(multipass version | head -1)"; \
	else \
		echo "  ✗ Multipass: not installed"; \
		echo "    Install: sudo snap install multipass"; \
	fi
	@echo ""
	@if command -v virsh &>/dev/null && command -v virt-install &>/dev/null; then \
		echo "  ✓ libvirt: $$(virsh version --daemon 2>/dev/null | grep libvirtd | awk '{print $$3}' || echo 'installed')"; \
		if systemctl is-active --quiet libvirtd; then \
			echo "    libvirtd: running"; \
		else \
			echo "    libvirtd: NOT RUNNING (start with: sudo systemctl enable --now libvirtd)"; \
		fi; \
		if virsh --connect $(LIBVIRT_URI) net-info default &>/dev/null; then \
			if virsh --connect $(LIBVIRT_URI) net-list --name 2>/dev/null | grep -q "^default$$"; then \
				echo "    default network: active"; \
			else \
				echo "    default network: INACTIVE (start with: sudo virsh net-start default)"; \
			fi; \
		else \
			echo "    default network: NOT FOUND"; \
			echo "      Create with: sudo virsh net-define /usr/share/libvirt/networks/default.xml"; \
			echo "                   sudo virsh net-start default"; \
			echo "                   sudo virsh net-autostart default"; \
		fi; \
	else \
		echo "  ✗ libvirt: not installed"; \
		echo "    Install: sudo pacman -S libvirt qemu-full virt-manager cloud-image-utils"; \
	fi
	@echo ""
	@if command -v cloud-localds &>/dev/null; then \
		echo "  ✓ cloud-localds: installed"; \
	else \
		echo "  ✗ cloud-localds: not installed"; \
		echo "    Install: sudo pacman -S cloud-image-utils"; \
	fi
	@echo ""

# Generate config from template
generate:
	@./generate.sh secrets/$(ENV).env

# Validate cloud-init syntax (fast, no VM)
validate: cloud-init-$(ENV).yaml
	@if command -v cloud-init &>/dev/null; then \
		cloud-init schema --config-file cloud-init-$(ENV).yaml && echo "✓ Schema valid"; \
	else \
		echo "cloud-init not installed, using Docker for validation..."; \
		docker run --rm -v $(PWD):/config:ro ubuntu:24.04 \
			bash -c "apt-get update -qq && apt-get install -y -qq cloud-init >/dev/null 2>&1 && \
			cloud-init schema --config-file /config/cloud-init-$(ENV).yaml" && echo "✓ Schema valid"; \
	fi

cloud-init-$(ENV).yaml:
	@echo "Cloud-init file not found. Generate it first:"
	@echo "  make generate ENV=$(ENV)"
	@exit 1

# Full test with VM (auto-detect backend)
test: cloud-init-$(ENV).yaml
	@./test-local.sh --name $(VM_NAME) $(if $(BACKEND),--backend $(BACKEND),) cloud-init-$(ENV).yaml

# Test without Tailscale (for local iteration)
test-no-tailscale: cloud-init-$(ENV).yaml
	@./test-local.sh --name $(VM_NAME) $(if $(BACKEND),--backend $(BACKEND),) --skip-tailscale cloud-init-$(ENV).yaml

# Deploy to an already-running Azure VM
deploy: cloud-init-$(ENV).yaml
	@test -n "$(AZURE_HOST)" || { echo "Usage: make deploy AZURE_HOST=<ip> ENV=<env>"; exit 1; }
	@./deploy-azure.sh --user $(AZURE_USER) $(if $(AZURE_IDENTITY),--identity $(AZURE_IDENTITY),) $(AZURE_HOST) cloud-init-$(ENV).yaml

# Deploy without Tailscale (opens SSH publicly)
deploy-no-tailscale: cloud-init-$(ENV).yaml
	@test -n "$(AZURE_HOST)" || { echo "Usage: make deploy-no-tailscale AZURE_HOST=<ip> ENV=<env>"; exit 1; }
	@./deploy-azure.sh --skip-tailscale --user $(AZURE_USER) $(if $(AZURE_IDENTITY),--identity $(AZURE_IDENTITY),) $(AZURE_HOST) cloud-init-$(ENV).yaml

# Cleanup test VM (works for both backends)
clean:
	@echo "Cleaning up VM: $(VM_NAME)"
	@# Multipass cleanup
	@multipass delete $(VM_NAME) --purge 2>/dev/null || true
	@# Libvirt cleanup
	@virsh --connect $(LIBVIRT_URI) destroy $(VM_NAME) 2>/dev/null || true
	@virsh --connect $(LIBVIRT_URI) undefine $(VM_NAME) --remove-all-storage 2>/dev/null || true
	@# Test artifacts
	@rm -f .cloud-init-test-*.yaml
	@sudo rm -f /var/lib/libvirt/images/cloud-init-test/$(VM_NAME)-*.qcow2 2>/dev/null || true
	@sudo rm -f /var/lib/libvirt/images/cloud-init-test/$(VM_NAME)-*.iso 2>/dev/null || true
	@echo "✓ Cleaned up"

# Show VM status (works for both backends)
status:
	@echo "=== Multipass ==="
	@multipass info $(VM_NAME) 2>/dev/null || echo "No Multipass VM '$(VM_NAME)'"
	@echo ""
	@echo "=== Libvirt ==="
	@virsh --connect $(LIBVIRT_URI) dominfo $(VM_NAME) 2>/dev/null || echo "No libvirt VM '$(VM_NAME)'"

# Shell into test VM
shell:
	@if multipass info $(VM_NAME) &>/dev/null; then \
		multipass shell $(VM_NAME); \
	elif virsh --connect $(LIBVIRT_URI) dominfo $(VM_NAME) &>/dev/null; then \
		VM_IP=$$(virsh --connect $(LIBVIRT_URI) domifaddr $(VM_NAME) 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1); \
		if [ -n "$$VM_IP" ]; then \
			ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$$VM_IP; \
		else \
			echo "Could not get VM IP. Try: virsh --connect $(LIBVIRT_URI) console $(VM_NAME)"; \
		fi; \
	else \
		echo "No VM '$(VM_NAME)' found"; \
	fi

SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

# Helper to get VM IP
define get_vm_ip
$$(virsh --connect $(LIBVIRT_URI) domifaddr $(VM_NAME) 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
endef

# View install logs (tail -f for live following)
logs:
	@if multipass info $(VM_NAME) &>/dev/null; then \
		multipass exec $(VM_NAME) -- tail -f /var/log/dokploy-install.log; \
	elif virsh --connect $(LIBVIRT_URI) dominfo $(VM_NAME) &>/dev/null; then \
		VM_IP=$(get_vm_ip); \
		if [ -n "$$VM_IP" ]; then \
			ssh $(SSH_OPTS) ubuntu@$$VM_IP 'tail -f /var/log/dokploy-install.log'; \
		else \
			echo "Could not get VM IP"; \
		fi; \
	else \
		echo "No VM '$(VM_NAME)' found"; \
	fi

# View cloud-init output log (tail -f for live following)
logs-full:
	@if multipass info $(VM_NAME) &>/dev/null; then \
		multipass exec $(VM_NAME) -- tail -f /var/log/cloud-init-output.log; \
	elif virsh --connect $(LIBVIRT_URI) dominfo $(VM_NAME) &>/dev/null; then \
		VM_IP=$(get_vm_ip); \
		if [ -n "$$VM_IP" ]; then \
			ssh $(SSH_OPTS) ubuntu@$$VM_IP 'tail -f /var/log/cloud-init-output.log'; \
		else \
			echo "Could not get VM IP"; \
		fi; \
	else \
		echo "No VM '$(VM_NAME)' found"; \
	fi
