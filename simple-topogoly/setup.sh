#!/usr/bin/env bash
# shellcheck disable=SC2086
set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION="${1:-}"
LEAF_COUNT=8
SPINE_COUNT=1
DEFAULT_LAB_NAME="ai-kind-rdma"
DEFAULT_WORKERS=4
DEFAULT_FABRIC_KIND="nokia_srlinux"
LINUX_KIND="linux"
LINUX_IMAGE="debian:12"
STORAGE_SWITCH_NODE="storage-switch"
STORAGE_HOST_NODE="storage-host"
STORAGE_IFACE_INDEX=$((LEAF_COUNT + 1))
# Optional HTTP proxy (used for apt-get inside containers)
HTTP_PROXY=""

check_kernel_version() {
  local kernel version major minor
  kernel="$(uname -r)"
  version="${kernel%%-*}"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if [[ -z "${major}" || -z "${minor}" ]]; then
    echo "Unable to determine kernel version from '${kernel}'." >&2
    exit 1
  fi
  if (( major < 5 || (major == 5 && minor < 3) )); then
    echo "Error: Software iWARP (SIW) requires Linux kernel >= 5.3. Detected ${kernel}." >&2
    exit 1
  fi
}

check_ofed_conflict() {
  if ! modprobe siw ; then
    cat <<EOF >&2
This Mellanox OFED may be active, which conflicts with Software iWARP (SIW).
Please unload the OFED driver or reboot without it before running this script.
EOF
    exit 1
  fi
}

run_sr_cli_script() {
  local container="$1"
  shift
  local script
  script=$(printf '%s\n' "$@")
  printf '[%s] sr_cli on %s\n' "$(date +'%Y-%m-%dT%H:%M:%S')" "${container}"
  set -x
  docker exec -i "${container}" sr_cli <<EOF
${script}
EOF
  set +x
}

default_fabric_image() {
  case "$1" in
    sonic-vs) echo "netreplica/docker-sonic-vs:20220111" ;;
    nokia_srlinux) echo "ghcr.io/nokia/srlinux:25.7" ;;
    ceos) echo "ceos:4.32.1F" ;;
    crpd) echo "crpd:23.2R1.13" ;;
    *) echo "" ;;
  esac
}

print_help() {
  cat <<EOF
Usage: $(basename "$0") <deploy|destroy> [options]

Actions:
  deploy                 Generate configs, deploy the lab, and enable Software iWARP (SIW) RDMA.
  destroy                Tear down the lab and clean generated resources.
  setip                  Apply IP/bridge configuration to switches and workers.
  show                   Display LLDP neighbors for each kind worker.

Common options:
  --workers N            Number of kind worker nodes (default: ${DEFAULT_WORKERS}).
  --lab-name NAME        Base name for generated files and containerlab lab (default: ${DEFAULT_LAB_NAME}).
  --kind-image IMAGE     Image used for all kind nodes. If omitted, kind falls back to its internal default.
  --fabric-kind KIND     Containerlab kind for leaf/spine fabric (default: ${DEFAULT_FABRIC_KIND}).
                         Examples: nokia_srlinux (default), sonic-vs, crpd, ceos, dell_sonic, sonic-vm.
  --fabric-image IMAGE   Image for the selected fabric kind. By default, common images are provided (e.g. nokia_srlinux → ghcr.io/nokia/srlinux:23.10.1).
                         Use this flag to override the image if needed.
  --http-proxy URL       HTTP proxy URL passed to apt-get inside worker/storage containers (default: empty).
  --disable-default-cni  Skip installing kind's built-in CNI (enabled by default). Use this to fully manage Pod networking yourself.
  --skip-install-tool    Skip installing diagnostic tooling (lshw/lldpd) on workers during setip/deploy.
  -h, --help             Show this help.

Notes:
  - The script expects containerlab, docker, kind, and rdma-core tools to be installed on the host.
  - This script uses Software iWARP (SIW) for RDMA support, which requires Linux kernel >= 5.3.
  - SIW devices are created manually using 'rdma link add <name> type siw netdev <interface>'.
  - SIW is based on iWARP protocol (RDMA over TCP) and works better than RXE in containerized environments.
  - Provide --http-proxy when your environment requires an HTTP proxy for apt-get operations inside the containers.
EOF
}

if [[ -z "${ACTION}" ]]; then
  print_help >&2
  exit 1
fi
if [[ "${ACTION}" == "-h" || "${ACTION}" == "--help" ]]; then
  print_help
  exit 0
fi

check_ofed_conflict

shift

LAB_NAME="${DEFAULT_LAB_NAME}"
WORKER_COUNT="${DEFAULT_WORKERS}"
KIND_IMAGE=""
FABRIC_KIND="${DEFAULT_FABRIC_KIND}"
FABRIC_IMAGE=""
DISABLE_DEFAULT_CNI=false
SKIP_INSTALL_TOOL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)
      WORKER_COUNT="${2:-}"
      shift 2
      ;;
    --lab-name)
      LAB_NAME="${2:-}"
      shift 2
      ;;
    --kind-image)
      KIND_IMAGE="${2:-}"
      shift 2
      ;;
    --fabric-kind)
      FABRIC_KIND="${2:-}"
      shift 2
      ;;
    --fabric-image)
      FABRIC_IMAGE="${2:-}"
      shift 2
      ;;
    --http-proxy)
      if [[ -z "${2:-}" ]]; then
        echo "--http-proxy requires a non-empty URL argument." >&2
        exit 1
      fi
      HTTP_PROXY="${2}"
      shift 2
      ;;
    --disable-default-cni)
      DISABLE_DEFAULT_CNI=true
      shift
      ;;
    --skip-install-tool)
      SKIP_INSTALL_TOOL=true
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "${WORKER_COUNT}" =~ ^[0-9]+$ ]] || (( WORKER_COUNT < 1 )); then
  echo "Worker count must be a positive integer." >&2
  exit 1
fi

CLAB_FILE="${WORKDIR}/${LAB_NAME}.clab.yml"
KIND_CONFIG_FILE="${WORKDIR}/${LAB_NAME}-kind.yaml"
KIND_NODE_NAME="${LAB_NAME}-cluster"

log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S')] $*"
}

ensure_tools() {
  for tool in containerlab kind docker rdma; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "Required tool '${tool}' is not available in PATH." >&2
      exit 1
    fi
  done
}

ensure_netns_symlink() {
  local container="$1"
  local sandbox
  sandbox="$(docker inspect -f '{{.NetworkSettings.SandboxKey}}' "${container}" 2>/dev/null || true)"
  if [[ -z "${sandbox}" || "${sandbox}" == "<no value>" || "${sandbox}" == "<nil>" ]]; then
    log "Warning: sandbox key for ${container} not found, skipping RDMA setup"
    return 1
  fi
  sudo ln -sf "${sandbox}" "/var/run/netns/${container}"
  return 0
}

create_siw_interface() {
  local container="$1"
  local iface="$2"
  local siw_name="$3"
  if ! sudo ip netns exec "${container}" ip link show "${iface}" >/dev/null 2>&1; then
    log "Warning: interface ${iface} missing in ${container}, skipping RDMA device ${siw_name}"
    return
  fi
  if sudo ip netns exec "${container}" rdma link show "${siw_name}" >/dev/null 2>&1; then
    return
  fi
  log "Creating ${siw_name} on ${container}:${iface}"
  sudo ip netns exec "${container}" rdma link add "${siw_name}" type siw netdev "${iface}"
}

configure_worker_siw() {
  local worker_index="$1"
  local container_name
  container_name="$(worker_container_name "${worker_index}")"

  if ! ensure_netns_symlink "${container_name}"; then
    return
  fi

  for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
    local iface="eth${leaf}"
    local siw_name="siw-w${worker_index}-l${leaf}"
    create_siw_interface "${container_name}" "${iface}" "${siw_name}"
  done

  local storage_iface="eth${STORAGE_IFACE_INDEX}"
  local storage_siw="siw-w${worker_index}-s1"
  create_siw_interface "${container_name}" "${storage_iface}" "${storage_siw}"
}

configure_storage_host_siw() {
  local container_name="clab-${LAB_NAME}-${STORAGE_HOST_NODE}"
  if ! ensure_netns_symlink "${container_name}"; then
    return
  fi
  create_siw_interface "${container_name}" "eth1" "siw-storage-eth1"
}

configure_worker_packages() {
  log "Configuring worker/storage packages and LLDP tooling"
  local pids=()
  for ((worker=1; worker<=WORKER_COUNT; worker++)); do
    local container_name
    container_name="$(worker_container_name "${worker}")"
    (
      docker exec "${container_name}" bash -c "
set -euo pipefail
if [[ -n '${HTTP_PROXY}' ]]; then
  export http_proxy='${HTTP_PROXY}'
  export https_proxy='${HTTP_PROXY}'
else
  unset http_proxy https_proxy
fi
export no_proxy=\"127.0.0.1,localhost\"
apt-get clean
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y lshw lldpd perftest iputils-ping rdma-core ibverbs-utils
lldpd
" | sed "s/^/[${container_name}] /"
    ) &
    pids+=("$!")
  done

  local storage_host_name="clab-${LAB_NAME}-${STORAGE_HOST_NODE}"
  if docker ps --format '{{.Names}}' | grep -qx "${storage_host_name}"; then
    (
      docker exec "${storage_host_name}" bash -c "
set -euo pipefail
if [[ -n '${HTTP_PROXY}' ]]; then
  export http_proxy='${HTTP_PROXY}'
  export https_proxy='${HTTP_PROXY}'
else
  unset http_proxy https_proxy
fi
export no_proxy=\"127.0.0.1,localhost\"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y lshw lldpd perftest iproute2 iputils-ping rdma-core ibverbs-utils
lldpd
" | sed "s/^/[${storage_host_name}] /"
    ) &
    pids+=("$!")
  else
    log "Warning: storage host container ${storage_host_name} not running, skipping package setup"
  fi

  local fail=0
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      fail=1
    fi
  done

  if (( fail )); then
    log "Warning: package configuration failed on one or more nodes"
  else
    log "Worker/storage package configuration completed"
  fi
}

configure_leaf_networks() {
  log "Configuring leaf access networks"
  for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
    local leaf_name="clab-${LAB_NAME}-leaf${leaf}"
    if ! docker ps --format '{{.Names}}' | grep -qx "${leaf_name}"; then
      log "Warning: leaf container ${leaf_name} not running, skipping"
      continue
    fi

    local network_name="host-access-${leaf}"
    local irb_name="irb${leaf}"
    local cmds=(
      "enter candidate"
      "delete network-instance ${network_name}"
      "delete interface ${irb_name}"
      "commit stay"
      "set interface ${irb_name} admin-state enable"
      "set interface ${irb_name} subinterface 0 admin-state enable"
      "set interface ${irb_name} subinterface 0 ipv4 admin-state enable"
      "set interface ${irb_name} subinterface 0 ipv4 address 10.1.${leaf}.254/24"
    )
    for ((worker=1; worker<=WORKER_COUNT; worker++)); do
      local port=$((1 + worker))
      cmds+=(
        "set interface ethernet-1/${port} admin-state enable"
        "set interface ethernet-1/${port} subinterface 0 type bridged"
        "set interface ethernet-1/${port} subinterface 0 admin-state enable"
      )
    done
    cmds+=(
      "set network-instance ${network_name} type mac-vrf"
      "set network-instance ${network_name} interface ${irb_name}.0"
    )
    for ((worker=1; worker<=WORKER_COUNT; worker++)); do
      local port=$((1 + worker))
      cmds+=("set network-instance ${network_name} interface ethernet-1/${port}.0")
    done
    cmds+=(
      "set network-instance default interface ${irb_name}.0"
      "commit now"
      "exit"
    )

    if ! run_sr_cli_script "${leaf_name}" "${cmds[@]}"; then
      log "Warning: failed to configure ${leaf_name}"
    fi
  done
}

configure_storage_network() {
  log "Configuring storage network"
  local switch_name="clab-${LAB_NAME}-${STORAGE_SWITCH_NODE}"
  if docker ps --format '{{.Names}}' | grep -qx "${switch_name}"; then
    local network_name="storage-access"
    local irb_name="irb100"
    local cmds=(
      "enter candidate"
      "delete network-instance ${network_name}"
      "delete interface ${irb_name}"
      "commit stay"
      "set interface ${irb_name} admin-state enable"
      "set interface ${irb_name} subinterface 0 admin-state enable"
      "set interface ${irb_name} subinterface 0 ipv4 admin-state enable"
      "set interface ${irb_name} subinterface 0 ipv4 address 10.3.1.254/24"
    )
    for ((worker=1; worker<=WORKER_COUNT; worker++)); do
      cmds+=(
        "set interface ethernet-1/${worker} admin-state enable"
        "set interface ethernet-1/${worker} subinterface 0 type bridged"
        "set interface ethernet-1/${worker} subinterface 0 admin-state enable"
      )
    done
    local storage_port=$((WORKER_COUNT + 1))
    cmds+=(
      "set interface ethernet-1/${storage_port} admin-state enable"
      "set interface ethernet-1/${storage_port} subinterface 0 type bridged"
      "set interface ethernet-1/${storage_port} subinterface 0 admin-state enable"
      "set network-instance ${network_name} type mac-vrf"
      "set network-instance ${network_name} interface ${irb_name}.0"
    )
    for ((worker=1; worker<=WORKER_COUNT; worker++)); do
      cmds+=("set network-instance ${network_name} interface ethernet-1/${worker}.0")
    done
    cmds+=(
      "set network-instance ${network_name} interface ethernet-1/${storage_port}.0"
      "set network-instance default interface ${irb_name}.0"
      "commit now"
      "exit"
    )
    if ! run_sr_cli_script "${switch_name}" "${cmds[@]}"; then
      log "Warning: failed to configure storage switch"
    fi
  else
    log "Warning: storage switch container ${switch_name} not running"
  fi

  local storage_host_name="clab-${LAB_NAME}-${STORAGE_HOST_NODE}"
  if docker ps --format '{{.Names}}' | grep -qx "${storage_host_name}"; then
    docker exec "${storage_host_name}" sh -c '
ip addr flush dev eth1
ip link set eth1 up
ip addr add 10.3.1.250/24 dev eth1
' >/dev/null 2>&1 || log "Warning: failed to configure storage host IP"
  else
    log "Warning: storage host container ${storage_host_name} not running"
  fi
}

configure_worker_ips() {
  set -x

  log "Assigning IP addresses to worker interfaces"
  for ((worker=1; worker<=WORKER_COUNT; worker++)); do
    local container_name="$(worker_container_name "${worker}")"
    if ! docker ps --format '{{.Names}}' | grep -qx "${container_name}"; then
      log "Warning: worker container ${container_name} not running, skipping"
      continue
    fi
    local cmds="set -euo pipefail;"
    for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
      cmds+=" ip -4 addr flush dev eth${leaf}; ip link set eth${leaf} up; ip addr add 10.1.${leaf}.${worker}/24 dev eth${leaf};"
      # Add direct route in main table for local subnet
      cmds+=" ip -4 route replace 10.1.${leaf}.0/24 dev eth${leaf} proto kernel scope link src 10.1.${leaf}.${worker};"
      local table_id=$((200 + leaf))
      local leaf_ip="10.1.${leaf}.${worker}"
      cmds+=" ip -4 rule del from ${leaf_ip}/32 table ${table_id} 2>/dev/null || true;"
      cmds+=" ip -4 route flush table ${table_id} 2>/dev/null || true;"
      cmds+=" ip -4 rule add from ${leaf_ip}/32 table ${table_id};"
      cmds+=" ip -4 route replace 10.1.${leaf}.0/24 dev eth${leaf} table ${table_id};"
      cmds+=" ip -4 route replace default via 10.1.${leaf}.254 dev eth${leaf} table ${table_id};"
    done
    cmds+=" ip -4 addr flush dev eth${STORAGE_IFACE_INDEX}; ip link set eth${STORAGE_IFACE_INDEX} up; ip addr add 10.3.1.${worker}/24 dev eth${STORAGE_IFACE_INDEX};"
    # Add direct route in main table for storage subnet
    cmds+=" ip -4 route replace 10.3.1.0/24 dev eth${STORAGE_IFACE_INDEX} proto kernel scope link src 10.3.1.${worker};"
    local storage_table_id=$((200 + STORAGE_IFACE_INDEX))
    local storage_ip="10.3.1.${worker}"
    cmds+=" ip -4 rule del from ${storage_ip}/32 table ${storage_table_id} 2>/dev/null || true;"
    cmds+=" ip -4 route flush table ${storage_table_id} 2>/dev/null || true;"
    cmds+=" ip -4 rule add from ${storage_ip}/32 table ${storage_table_id};"
    cmds+=" ip -4 route replace 10.3.1.0/24 dev eth${STORAGE_IFACE_INDEX} table ${storage_table_id};"
    cmds+=" ip -4 route replace default via 10.3.1.254 dev eth${STORAGE_IFACE_INDEX} table ${storage_table_id};"
    if ! docker exec "${container_name}" bash -c "${cmds}" >/dev/null 2>&1; then
      log "Warning: failed to configure IPs on ${container_name}"
    fi
  done

  set +x
}

cleanup_netns_symlinks() {
  log "Removing netns symlinks for kind workers and storage host"
  local targets=()
  targets+=("clab-${LAB_NAME}-${STORAGE_HOST_NODE}")
  for ((worker=1; worker<=WORKER_COUNT; worker++)); do
    targets+=("$(worker_container_name "${worker}")")
  done

  for name in "${targets[@]}"; do
    local path="/var/run/netns/${name}"
    if [[ -L "${path}" || -e "${path}" ]]; then
      if ! sudo rm -f "${path}" >/dev/null 2>&1; then
        log "Warning: failed to remove netns symlink ${path}"
      fi
    fi
  done
}

configure_spine_leaf_ptp_links() {
  log "Configuring spine point-to-point interfaces"
  local spine_name="clab-${LAB_NAME}-spine1"
  if ! docker ps --format '{{.Names}}' | grep -qx "${spine_name}"; then
    log "Warning: spine container ${spine_name} not running, skipping"
    return
  fi

  local cmds=("enter candidate" "set network-instance default type default")
  for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
    local prefix="10.2.${leaf}"
    local spine_ip="${prefix}.1/30"
    cmds+=(
      "set interface ethernet-1/${leaf} admin-state enable"
      "set interface ethernet-1/${leaf} subinterface 0 type routed"
      "set interface ethernet-1/${leaf} subinterface 0 ipv4 address ${spine_ip}"
      "set network-instance default interface ethernet-1/${leaf}.0"
    )
  done
  cmds+=("commit now" "exit")

  if ! run_sr_cli_script "${spine_name}" "${cmds[@]}"; then
    log "Warning: failed to configure spine point-to-point IPs"
  fi
}

configure_leaf_ptp_links() {
  log "Configuring leaf point-to-point interfaces"
  for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
    local leaf_name="clab-${LAB_NAME}-leaf${leaf}"
    if ! docker ps --format '{{.Names}}' | grep -qx "${leaf_name}"; then
      log "Warning: leaf container ${leaf_name} not running, skipping PTP config"
      continue
    fi

    local prefix="10.2.${leaf}"
    local leaf_ip="${prefix}.2/30"
    local cmds=(
      "enter candidate"
      "set network-instance default type default"
      "set interface ethernet-1/1 admin-state enable"
      "set interface ethernet-1/1 subinterface 0 type routed"
      "set interface ethernet-1/1 subinterface 0 ipv4 address ${leaf_ip}"
      "set network-instance default interface ethernet-1/1.0"
      "commit now"
      "exit"
    )

    if ! run_sr_cli_script "${leaf_name}" "${cmds[@]}"; then
      log "Warning: failed to configure PTP IP on ${leaf_name}"
    fi
  done
}

configure_ip_addresses() {
  configure_spine_leaf_ptp_links
  configure_leaf_ptp_links
  configure_leaf_networks
  configure_storage_network
  configure_worker_ips
  
  # Create Software iWARP (SIW) devices after IP configuration
  log "Creating Software iWARP (SIW) RDMA devices after IP configuration"
  
  # Ensure SIW kernel module is loaded
  if ! lsmod | grep -q "^siw"; then
    log "Loading siw kernel module"
    sudo modprobe siw
  fi
  
  # Ensure netns directory exists
  sudo mkdir -p /var/run/netns
  
  # Create SIW devices for all workers
  for ((worker=1; worker<=WORKER_COUNT; worker++)); do
    configure_worker_siw "${worker}"
  done
  
  # Create SIW device for storage host
  configure_storage_host_siw
  
  log "Software iWARP (SIW) RDMA device creation completed"
}

# show_neighbors prints LLDP/IP/RDMA details for workers and IP/LLDP details for switches.
show_neighbors() {
  log "Gathering LLDP, IP, and RDMA details from worker nodes"
  local pattern="^${KIND_NODE_NAME}-worker([0-9]+)?$"
  local containers
  mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E "${pattern}" | sort)
  if [[ ${#containers[@]} -eq 0 ]]; then
    echo "No worker containers matching pattern ${KIND_NODE_NAME}-worker* found."
  else
    for container_name in "${containers[@]}"; do
      echo "==== ${container_name} ===="
      docker exec "${container_name}" sh -c '
echo "-- LLDP neighbors --"
if command -v lldpcli >/dev/null 2>&1; then
  lldpcli show neighbors || true
else
  echo "lldpcli not installed"
fi
echo "-- IP addresses --"
ip addr show || true
echo "-- route --"
ip rule show || true
ip route show || true
'
      echo "-- RDMA devices --"
      if sudo ip netns exec "${container_name}" rdma link show >/dev/null 2>&1; then
        sudo ip netns exec "${container_name}" rdma link show | grep netdev || true
      else
        echo "Unable to query RDMA devices (sudo rdma link show failed)"
      fi
      printf "\n"
    done
  fi

  echo "" 
  log "Gathering IP and LLDP details from fabric switches"
  local switches=("clab-${LAB_NAME}-spine1")
  for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
    switches+=("clab-${LAB_NAME}-leaf${leaf}")
  done
  switches+=("clab-${LAB_NAME}-${STORAGE_SWITCH_NODE}")

  for switch_name in "${switches[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${switch_name}"; then
      log "Warning: switch container ${switch_name} not running, skipping"
      continue
    fi
    echo "==== ${switch_name} ===="
    docker exec "${switch_name}" sh -c '
echo "-- IP/Interface information --"
if command -v sr_cli >/dev/null 2>&1; then
  sr_cli "show interface" || true
else
  if command -v ip >/dev/null 2>&1; then
    ip -o addr show || ip addr show || true
  else
    echo "No interface/IP command available"
  fi
fi
echo "-- LLDP neighbors --"
if command -v sr_cli >/dev/null 2>&1; then
  sr_cli "show system lldp neighbor" || true
else
  if command -v lldpcli >/dev/null 2>&1; then
    lldpcli show neighbors || true
  else
    echo "No LLDP utility available"
  fi
fi
' || true
    printf "\n"
  done

  local storage_host_name="clab-${LAB_NAME}-${STORAGE_HOST_NODE}"
  if docker ps --format '{{.Names}}' | grep -qx "${storage_host_name}"; then
    echo "==== ${storage_host_name} ===="
    docker exec "${storage_host_name}" sh -c '
echo "-- IP addresses --"
if command -v ip >/dev/null 2>&1; then
  ip addr show || true
else
  echo "ip command not available"
fi
' || true
    echo "-- RDMA devices --"
    if sudo ip netns exec "${storage_host_name}" rdma link show >/dev/null 2>&1; then
      sudo ip netns exec "${storage_host_name}" rdma link show | grep netdev || true
    else
      echo "Unable to query RDMA devices (sudo rdma link show failed)"
    fi
    printf "\n"
  else
    log "Warning: storage host container ${storage_host_name} not running"
  fi
}

generate_kind_config() {
  log "Generating kind cluster config at ${KIND_CONFIG_FILE}"
  cat <<EOF > "${KIND_CONFIG_FILE}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
EOF

  if [[ "${DISABLE_DEFAULT_CNI}" == "true" ]]; then
    cat <<EOF >> "${KIND_CONFIG_FILE}"
networking:
  disableDefaultCNI: true
EOF
  fi

  cat <<EOF >> "${KIND_CONFIG_FILE}"
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /dev/infiniband
        containerPath: /dev/infiniband
EOF

  if [[ -n "${KIND_IMAGE}" ]]; then
    cat <<EOF >> "${KIND_CONFIG_FILE}"
    image: ${KIND_IMAGE}
EOF
  fi

  for ((worker=1; worker<=WORKER_COUNT; worker++)); do
    cat <<EOF >> "${KIND_CONFIG_FILE}"
  - role: worker
    extraMounts:
      - hostPath: /dev/infiniband
        containerPath: /dev/infiniband
EOF
    if [[ -n "${KIND_IMAGE}" ]]; then
      cat <<EOF >> "${KIND_CONFIG_FILE}"
    image: ${KIND_IMAGE}
EOF
    fi
  done
}

worker_container_name() {
  local index="$1"
  if (( index == 1 )); then
    echo "${KIND_NODE_NAME}-worker"
  else
    echo "${KIND_NODE_NAME}-worker${index}"
  fi
}

generate_topology() {
  log "Generating topology file at ${CLAB_FILE}"
  local resolved_fabric_image="${FABRIC_IMAGE}"
  if [[ -z "${resolved_fabric_image}" ]]; then
    resolved_fabric_image="$(default_fabric_image "${FABRIC_KIND}")"
    if [[ -z "${resolved_fabric_image}" ]]; then
      echo "No default image found for fabric kind '${FABRIC_KIND}'. Please supply --fabric-image." >&2
      exit 1
    fi
  fi

  cat <<EOF > "${CLAB_FILE}"
name: ${LAB_NAME}

mgmt:
  ipv4-subnet: auto
  ipv6-subnet: auto

topology:
EOF

  local have_kinds=false
  if [[ -n "${resolved_fabric_image}" || -n "${LINUX_IMAGE}" ]]; then
    have_kinds=true
  fi

  if [[ "${have_kinds}" == "true" ]]; then
    cat <<EOF >> "${CLAB_FILE}"
  kinds:
EOF
    if [[ -n "${resolved_fabric_image}" ]]; then
      cat <<EOF >> "${CLAB_FILE}"
    ${FABRIC_KIND}:
      image: ${resolved_fabric_image}
EOF
    fi
    if [[ -n "${LINUX_IMAGE}" ]]; then
      cat <<EOF >> "${CLAB_FILE}"
    ${LINUX_KIND}:
      image: ${LINUX_IMAGE}
EOF
    fi
  fi

  cat <<EOF >> "${CLAB_FILE}"
  nodes:
    spine1:
      kind: ${FABRIC_KIND}
EOF

  for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
    cat <<EOF >> "${CLAB_FILE}"
    leaf${leaf}:
      kind: ${FABRIC_KIND}
EOF
  done

  cat <<EOF >> "${CLAB_FILE}"
    ${STORAGE_SWITCH_NODE}:
      kind: ${FABRIC_KIND}

    ${KIND_NODE_NAME}:
      kind: k8s-kind
      startup-config: $(basename "${KIND_CONFIG_FILE}")

    ${KIND_NODE_NAME}-control-plane:
      kind: ext-container
      binds:
        - /dev/infiniband:/dev/infiniband
EOF

  for ((worker=1; worker<=WORKER_COUNT; worker++)); do
    local container_name
    container_name="$(worker_container_name "${worker}")"
    cat <<EOF >> "${CLAB_FILE}"
    ${container_name}:
      kind: ext-container
      binds:
        - /dev/infiniband:/dev/infiniband
EOF
  done

  cat <<EOF >> "${CLAB_FILE}"
    ${STORAGE_HOST_NODE}:
      kind: ${LINUX_KIND}
      binds:
        - /dev/infiniband:/dev/infiniband

  links:
EOF

  for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
    local spine_port=$((leaf))
    cat <<EOF >> "${CLAB_FILE}"
    - endpoints: ["leaf${leaf}:e1-1", "spine1:e1-${spine_port}"]
EOF
  done

  for ((worker=1; worker<=WORKER_COUNT; worker++)); do
    local container_name
    container_name="$(worker_container_name "${worker}")"
    local leaf_port=$((1 + worker))
    for ((leaf=1; leaf<=LEAF_COUNT; leaf++)); do
      cat <<EOF >> "${CLAB_FILE}"
    - endpoints: ["leaf${leaf}:e1-${leaf_port}", "${container_name}:eth${leaf}"]
EOF
    done

    local storage_port=$((worker))
    cat <<EOF >> "${CLAB_FILE}"
    - endpoints: ["${STORAGE_SWITCH_NODE}:e1-${storage_port}", "${container_name}:eth${STORAGE_IFACE_INDEX}"]
EOF
  done

  local storage_host_port=$((WORKER_COUNT + 1))
  cat <<EOF >> "${CLAB_FILE}"
    - endpoints: ["${STORAGE_SWITCH_NODE}:e1-${storage_host_port}", "${STORAGE_HOST_NODE}:eth1"]
EOF
}

deploy_lab() {
  check_kernel_version
  ensure_tools
  generate_kind_config
  generate_topology

  log "------ step: Deploying containerlab topology"
  (cd "${WORKDIR}" && containerlab deploy -t "${CLAB_FILE}")

  if [[ "${SKIP_INSTALL_TOOL}" != "true" ]]; then
    log "------ step: Installing diagnostic tooling on worker nodes"
    configure_worker_packages
  else
    log "------ step: Skipping diagnostic tooling installation (requested)"
  fi

  log "------ step: Deployment complete. Topology file: ${CLAB_FILE}"
  log "NOTE: Run './setup.sh setip' to configure IP addresses and enable Software iWARP (SIW) RDMA"
}

destroy_lab() {
  if [[ ! -f "${CLAB_FILE}" ]]; then
    echo "Topology file ${CLAB_FILE} not found. Nothing to destroy." >&2
    exit 1
  fi

  cleanup_netns_symlinks

  log "Destroying containerlab topology"
  (cd "${WORKDIR}" && containerlab destroy -t "${CLAB_FILE}" --cleanup)
}

case "${ACTION}" in
  deploy)
    deploy_lab
    configure_ip_addresses
    ;;
  destroy)
    destroy_lab
    ;;
  show)
    ensure_tools
    show_neighbors
    ;;
  *)
    echo "Unknown action: ${ACTION}" >&2
    exit 1
    ;;
esac
