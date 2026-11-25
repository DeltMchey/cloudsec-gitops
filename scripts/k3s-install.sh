#!/usr/bin/env bash
# Idempotent K3s server installation for the W3 Ubuntu VM.
# Execute only as root on the intended VM. This script never stops, removes, or
# recreates existing Docker data containers.
# pinned at execution 2026-11-25: v1.37.2+k3s1 (stable channel,
# resolved via update.k3s.io; CN mirror serves the same release as
# v1.37.2-k3s1 and the installer normalizes '+' to '-' itself).
set -Eeuo pipefail
IFS=$'\n\t'

readonly INSTALL_URL="https://rancher-mirror.rancher.cn/k3s/k3s-install.sh"
readonly TLS_SAN="${K3S_TLS_SAN:-192.168.137.10}"
readonly KUBE_USER="${K3S_KUBE_USER:-nijika}"
readonly MIN_VCPU=4
readonly MIN_AVAILABLE_MEMORY_MIB="${K3S_MIN_AVAILABLE_MEMORY_MIB:-500}"
readonly HEALTH_TIMEOUT_SECONDS="${K3S_HEALTH_TIMEOUT_SECONDS:-600}"

# TODO(pin-at-execution): export INSTALL_K3S_VERSION with the reviewed K3s
# release. The exact version is intentionally not guessed in the source batch.
INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-}"
# TODO(set-at-execution): export K3S_MIN_FREE_DISK_GIB after the VM capacity
# review. Required free space remains the intentional "[X] GiB" placeholder.
K3S_MIN_FREE_DISK_GIB="${K3S_MIN_FREE_DISK_GIB:-}"

K3S_BIN=""
INSTALLER_TMP=""
REGISTRIES_TMP=""
INSTALL_PERFORMED=false

log() {
    printf '[k3s-install] %s\n' "$*"
}

warn() {
    printf '[k3s-install] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[k3s-install] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$INSTALLER_TMP" && -f "$INSTALLER_TMP" ]]; then
        rm -f -- "$INSTALLER_TMP"
    fi
    if [[ -n "$REGISTRIES_TMP" && -f "$REGISTRIES_TMP" ]]; then
        rm -f -- "$REGISTRIES_TMP"
    fi
}
trap cleanup EXIT

require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 \
            || die "required command is missing: ${command_name}"
    done
}

require_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] \
        || die "${name} must be a positive integer; got '${value}'"
}

check_execution_placeholders() {
    [[ -n "$INSTALL_K3S_VERSION" ]] \
        || die "set INSTALL_K3S_VERSION (TODO pin-at-execution); implicit latest is forbidden"
    [[ "$INSTALL_K3S_VERSION" != *TODO* ]] \
        || die "INSTALL_K3S_VERSION still contains a TODO placeholder"
    [[ -n "$K3S_MIN_FREE_DISK_GIB" ]] \
        || die "set K3S_MIN_FREE_DISK_GIB; the [X] GiB capacity placeholder must be resolved"
    require_positive_integer "K3S_MIN_FREE_DISK_GIB" "$K3S_MIN_FREE_DISK_GIB"
    require_positive_integer "K3S_MIN_AVAILABLE_MEMORY_MIB" "$MIN_AVAILABLE_MEMORY_MIB"
    require_positive_integer "K3S_HEALTH_TIMEOUT_SECONDS" "$HEALTH_TIMEOUT_SECONDS"
}

check_host_capacity() {
    local cpu_count available_memory_mib available_kib required_kib

    log "kernel: $(uname -r)"
    [[ -r /sys/kernel/btf/vmlinux ]] \
        || die "/sys/kernel/btf/vmlinux is missing; modern eBPF requires BTF"

    cpu_count="$(nproc)"
    (( cpu_count >= MIN_VCPU )) \
        || die "at least ${MIN_VCPU} vCPU required; detected ${cpu_count}"

    available_memory_mib="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)"
    [[ "$available_memory_mib" =~ ^[0-9]+$ ]] \
        || die "could not determine MemAvailable"
    (( available_memory_mib >= MIN_AVAILABLE_MEMORY_MIB )) \
        || die "available memory ${available_memory_mib} MiB is below the ${MIN_AVAILABLE_MEMORY_MIB} MiB stop line"

    # /var/lib/rancher is on the root filesystem in the W3 single-disk VM.
    available_kib="$(df -Pk / | awk 'NR == 2 { print $4 }')"
    [[ "$available_kib" =~ ^[0-9]+$ ]] \
        || die "could not determine free disk space"
    required_kib=$((K3S_MIN_FREE_DISK_GIB * 1024 * 1024))
    (( available_kib >= required_kib )) \
        || die "free disk is below the configured ${K3S_MIN_FREE_DISK_GIB} GiB threshold"

    log "capacity preflight: ${cpu_count} vCPU, ${available_memory_mib} MiB available, ${K3S_MIN_FREE_DISK_GIB} GiB disk threshold satisfied"
}

preserve_docker_data_services() {
    local running=""

    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker CLI not found; no Docker action will be attempted"
        return
    fi
    if ! docker info >/dev/null 2>&1; then
        warn "Docker daemon is not accessible; no Docker action will be attempted"
        return
    fi

    running="$(docker ps --format '{{.Names}}' | grep -E '^(secguard-redis|secguard-postgres)$' || true)"
    if [[ -n "$running" ]]; then
        log "preserving running data containers without restart or mutation:"
        printf '%s\n' "$running"
    else
        warn "secguard-redis/secguard-postgres not observed running; this script leaves Docker untouched"
    fi
}

check_ports_for_new_install() {
    local tcp_port
    for tcp_port in 2379 2380 2381 6443 10250; do
        if ss -H -lnt "sport = :${tcp_port}" | grep -q .; then
            die "TCP port ${tcp_port} is already occupied; refusing a new K3s install"
        fi
    done
    if ss -H -lnu 'sport = :8472' | grep -q .; then
        die "UDP port 8472 is already occupied; refusing a new K3s install"
    fi
    log "K3s server port preflight passed"
}

write_registries() {
    log "writing registry mirrors before the first K3s start"
    install -d -m 0755 /etc/rancher/k3s
    REGISTRIES_TMP="$(mktemp /tmp/k3s-registries.XXXXXX)"
    cat >"$REGISTRIES_TMP" <<'EOF'
# K3s registry mirrors for the China-direct VM network (ADR-005).
mirrors:
  docker.io:
    endpoint:
      - https://docker.m.daocloud.io
      # Optional explicit official fallback; K3s otherwise uses its default upstream:
      # - https://registry-1.docker.io
  ghcr.io:
    endpoint:
      - https://ghcr.m.daocloud.io
      # Optional explicit official fallback:
      # - https://ghcr.io
EOF
    install -m 0644 "$REGISTRIES_TMP" /etc/rancher/k3s/registries.yaml
    rm -f -- "$REGISTRIES_TMP"
    REGISTRIES_TMP=""
}

install_k3s() {
    local k3s_exec

    require_commands curl mktemp sh
    INSTALLER_TMP="$(mktemp /tmp/k3s-installer.XXXXXX)"
    log "downloading the installer from the configured Rancher CN mirror"
    curl -fsSL \
        --connect-timeout 15 \
        --retry 5 \
        --retry-delay 5 \
        --output "$INSTALLER_TMP" \
        "$INSTALL_URL"

    k3s_exec="server --disable=traefik --disable=servicelb --write-kubeconfig-mode=600 --tls-san=${TLS_SAN}"
    log "installing pinned K3s version ${INSTALL_K3S_VERSION}"
    INSTALL_K3S_MIRROR=cn \
        INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
        INSTALL_K3S_EXEC="$k3s_exec" \
        sh "$INSTALLER_TMP"
    rm -f -- "$INSTALLER_TMP"
    INSTALLER_TMP=""
    INSTALL_PERFORMED=true
    K3S_BIN="$(command -v k3s || true)"
    [[ -n "$K3S_BIN" ]] || die "installation completed without a k3s binary on PATH"
}

kube() {
    "$K3S_BIN" kubectl "$@"
}

node_is_ready() {
    local ready
    ready="$(kube get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$ready" == "True" ]]
}

deployment_is_available() {
    local deployment="$1"
    local replicas
    replicas="$(kube -n kube-system get deployment "$deployment" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    [[ "$replicas" =~ ^[0-9]+$ ]] && (( replicas >= 1 ))
}

local_storage_is_ready() {
    deployment_is_available local-path-provisioner \
        && kube get storageclass local-path >/dev/null 2>&1
}

wait_for() {
    local description="$1"
    shift
    local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))

    while ! "$@"; do
        if (( SECONDS >= deadline )); then
            die "timed out after ${HEALTH_TIMEOUT_SECONDS}s waiting for ${description}"
        fi
        log "waiting for ${description}"
        sleep 5
    done
    log "healthy: ${description}"
}

check_cluster_health() {
    systemctl is-active --quiet k3s \
        || die "k3s.service is not active; inspect it instead of applying an implicit repair"
    wait_for "node Ready" node_is_ready
    wait_for "CoreDNS Available" deployment_is_available coredns
    wait_for "metrics-server Available" deployment_is_available metrics-server
    wait_for "local-path storage Available" local_storage_is_ready
}

write_user_kubeconfig() {
    local user_home user_group

    id "$KUBE_USER" >/dev/null 2>&1 \
        || die "kubeconfig user does not exist: ${KUBE_USER}"
    user_home="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
    user_group="$(id -gn "$KUBE_USER")"
    [[ -n "$user_home" && "$user_home" != "/" ]] \
        || die "refusing an unsafe home directory for ${KUBE_USER}: '${user_home}'"
    [[ -r /etc/rancher/k3s/k3s.yaml ]] \
        || die "/etc/rancher/k3s/k3s.yaml is unavailable"

    install -d -m 0700 -o "$KUBE_USER" -g "$user_group" "$user_home/.kube"
    install -m 0600 -o "$KUBE_USER" -g "$user_group" \
        /etc/rancher/k3s/k3s.yaml "$user_home/.kube/config"
    log "kubeconfig installed at ${user_home}/.kube/config (directory 0700, file 0600)"
}

print_acceptance_summary() {
    printf '\n========== W3 K3s acceptance summary ==========\n'
    if [[ "$INSTALL_PERFORMED" == true ]]; then
        printf 'Mode: fresh pinned installation\n'
    else
        printf 'Mode: existing version reused; installation skipped\n'
    fi
    "$K3S_BIN" --version
    kube get nodes -o wide
    kube -n kube-system get deployment coredns metrics-server local-path-provisioner
    printf 'TLS SAN: %s\n' "$TLS_SAN"
    printf 'Docker data containers: untouched\n'
    printf '\nNEXT GATE: create the VMware snapshot named w3-k3s-clean.\n'
    printf 'Do not continue to Argo CD until that snapshot exists.\n'
}

main() {
    (( EUID == 0 )) || die "run as root on the intended Ubuntu VM"
    umask 027
    require_commands awk cut df getent grep id install nproc ss systemctl uname
    check_execution_placeholders
    check_host_capacity
    preserve_docker_data_services

    K3S_BIN="$(command -v k3s || true)"
    if [[ -n "$K3S_BIN" ]]; then
        local installed_version
        installed_version="$("$K3S_BIN" --version | awk 'NR == 1 { print $3 }')"
        [[ -n "$installed_version" ]] || die "could not identify the installed K3s version"
        if [[ "$installed_version" != "$INSTALL_K3S_VERSION" ]]; then
            die "installed K3s ${installed_version} differs from requested ${INSTALL_K3S_VERSION}; take a snapshot and perform a separate reviewed upgrade"
        fi
        log "K3s ${installed_version} already installed; skipping installer and registry changes"
    else
        check_ports_for_new_install
        write_registries
        install_k3s
    fi

    check_cluster_health
    write_user_kubeconfig
    print_acceptance_summary
}

main "$@"
