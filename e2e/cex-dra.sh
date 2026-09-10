#!/usr/bin/env bash
# End-to-end CEX DRA on Fedora Kubernetes (t313lp42 / s390x / CRI-O).
#
#  1. Remove CEX DRA driver and in-cluster registry (if any)
#  2. Remove KubeVirt (if any)
#  3. Check preconditions (CEX queue, driver_override, vfio_ap, ...)
#  4. Deploy KubeVirt
#  5. Configure HostDevices + HostDevicesWithDRA + vfio-ap keep-list
#  6. Start an in-cluster registry, rootless-build the driver, push, deploy
#  7. Start a VM that claims one queue
#  8. Check the card inside the VM
#  9. Delete the test namespace, driver, registry, and KubeVirt
#
# Run:
#   ./e2e/cex-dra.sh
#
# The script uses the repository it lives in (no cloning). Kustomize overlays
# are resolved relative to the repo root automatically.
# CRI-O cannot pull plain HTTP without host config, so a privileged Job copies
# the image into the node store for this run.
#
# KEEP=1          leave VM/driver/registry/KubeVirt after a successful run
# DELETE_WAIT=120 max seconds to wait for each uninstall (then error and stop)
# KUBEVIRT_VERSION=v1.9.0   pin KubeVirt (default: latest GitHub release, min v1.9.0)
# IMAGE_TAG=...   default: first 12 chars of HEAD git SHA

set -euo pipefail

# Resolve the repo root: the script lives at <repo>/e2e/cex-dra.sh, so go up
# one level from the directory that contains this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OVERLAY="${OVERLAY:-my-cluster}"
KEEP="${KEEP:-0}"
DELETE_WAIT="${DELETE_WAIT:-120}"
TEST_NS="${TEST_NS:-cex-dra-test}"
VM_NAME="${VM_NAME:-cex-quickstart}"
WORK_DIR="${WORK_DIR:-$HOME/cex-dra-e2e-work}"
FEDORA_DISK="${FEDORA_DISK:-quay.io/containerdisks/fedora:latest}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-}"

PLUGIN_REPO="${PLUGIN_REPO:-cex-dra-kubeletplugin}"
IMAGE_TAG="${IMAGE_TAG:-}"
REGISTRY_NS="${REGISTRY_NS:-cex-dra-registry}"
REGISTRY_NAME="${REGISTRY_NAME:-registry}"
REGISTRY_NODEPORT="${REGISTRY_NODEPORT:-30511}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-docker.io/library/registry:2}"
IMPORT_IMAGE="${IMPORT_IMAGE:-quay.io/skopeo/stable:latest}"
# Set after install_registry: NODE_IP:30511/cex-dra-kubeletplugin
IMAGE_NAME=""
IMAGE=""
REGISTRY_ADDR=""

# shellcheck source=helpers.sh
source "${SCRIPT_DIR}/helpers.sh"
# shellcheck source=assert.sh
source "${SCRIPT_DIR}/assert.sh"
# shellcheck source=workloads.sh
source "${SCRIPT_DIR}/workloads.sh"
# shellcheck source=uninstall.sh
source "${SCRIPT_DIR}/uninstall.sh"
# shellcheck source=preconditions.sh
source "${SCRIPT_DIR}/preconditions.sh"
# shellcheck source=deploy.sh
source "${SCRIPT_DIR}/deploy.sh"

# Announce non-zero exits. This script does NOT auto-clean on failure so the
# broken state can be inspected; re-running the script cleans up first (steps
# 1-2), or run './deploy-cex-dra-fedora.sh clean' to tear everything down.
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo >&2
    echo "FAILED (exit ${rc}). Cluster state left in place for debugging." >&2
    echo "  clean up with:  ${0} clean   (or just re-run; steps 1-2 remove leftovers)" >&2
  fi
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# 7–8. VM + guest check
# ---------------------------------------------------------------------------
ensure_ssh_key() {
  mkdir -p "${WORK_DIR}"
  if [[ ! -f "${WORK_DIR}/id_ed25519" || ! -f "${WORK_DIR}/id_ed25519.pub" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${WORK_DIR}/id_ed25519" -q
  fi
  SSH_PUB="$(cat "${WORK_DIR}/id_ed25519.pub")"
  SSH_PRIV="${WORK_DIR}/id_ed25519"
}

guest_ssh() {
  local cmd="$1"
  if command -v virtctl >/dev/null 2>&1; then
    local -a vargs
    vargs=(-n "${TEST_NS}")
    [[ -n "${SSH_PRIV:-}" ]] && vargs+=(-i "${SSH_PRIV}")
    if [[ -z "${VIRTCTL_HAS_LOCAL_SSH:-}" ]]; then
      if virtctl ssh --help 2>&1 | grep -qE -- '--local-ssh([[:space:]]|=|$)'; then
        VIRTCTL_HAS_LOCAL_SSH=1
      else
        VIRTCTL_HAS_LOCAL_SSH=0
      fi
    fi
    if [[ "${VIRTCTL_HAS_LOCAL_SSH}" == "1" ]]; then
      vargs+=(--local-ssh=true)
      vargs+=(--local-ssh-opts=-o StrictHostKeyChecking=no)
      vargs+=(--local-ssh-opts=-o UserKnownHostsFile=/dev/null)
      vargs+=(--local-ssh-opts=-o ConnectTimeout=8)
    fi
    vargs+=(-c "${cmd}" "fedora@vmi/${VM_NAME}")
    virtctl ssh "${vargs[@]}" && return 0
  fi
  local ip
  ip="$(kubectl get vmi "${VM_NAME}" -n "${TEST_NS}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true)"
  [[ -n "$ip" && -n "${SSH_PRIV:-}" ]] || return 1
  ssh -i "${SSH_PRIV}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    -o BatchMode=yes \
    "fedora@${ip}" "${cmd}"
}

check_card_in_vm() {
  info "8) Check CEX card inside the VM"
  echo "--- host lszcrypt (queue line gone means the VM holds 06.0000) ---"
  lszcrypt || true
  echo
  echo "Checking guest via virtctl ssh (sshd + cloud-init can take a minute)..."
  local i out errf
  for i in $(seq 1 36); do
    errf="$(mktemp)"
    if out="$(guest_ssh 'ls /sys/bus/ap/devices 2>/dev/null; command -v lszcrypt >/dev/null && lszcrypt || true' 2>"$errf")"; then
      echo "$out"
      if echo "$out" | grep -Eq '^[0-9a-fA-F]{2}\.[0-9a-fA-F]{4}|card[0-9a-fA-F]{2}'; then
        rm -f "$errf"
        echo
        echo "Guest sees an AP device: OK"
        kubectl get resourceclaims -n "${TEST_NS}"
        return
      fi
    fi
    # "connection refused" / "255" on the early tries just means sshd/cloud-init
    # is still coming up; that is expected and the loop retries. Only surface
    # the (CR-sanitized) detail periodically so it is not mistaken for a crash.
    local detail
    detail="$(tr -d '\r' < "$errf" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//;s/ *$//')"
    if echo "$detail" | grep -qiE 'connection refused|dial tcp|no route to host|exit status 255|handshake'; then
      echo "  retry ${i}/36 (guest sshd not ready yet)..."
    else
      echo "  retry ${i}/36..."
    fi
    # Only surface ssh detail once the guest is taking unusually long (a normal
    # boot connects within the first few retries), so successful runs stay quiet.
    if (( i == 12 || i == 24 )); then
      [[ -n "$detail" ]] && echo "    last ssh detail: ${detail}"
      kubectl get vmi "${VM_NAME}" -n "${TEST_NS}" 2>/dev/null || true
    fi
    rm -f "$errf"
    sleep 10
  done
  kubectl describe vmi "${VM_NAME}" -n "${TEST_NS}" || true
  kubectl get events -n "${TEST_NS}" --sort-by=.lastTimestamp | tail -30 || true
  fail "guest never showed an AP queue (lszcrypt /sys/bus/ap)"
}

start_vm() {
  info "7) Start VM with one CEX queue"
  ensure_ssh_key
  local ctype req
  ctype="$(cex_type_from_cluster)"
  req="${ctype}-ap-queue"
  echo "Selecting cex.ibm.com/type == \"${ctype}\""
  kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF | kubectl apply -f -
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: single-${ctype}-ap-queue-vm
  namespace: ${TEST_NS}
spec:
  spec:
    devices:
      requests:
        - name: ${req}
          exactly:
            deviceClassName: ap-queue.virtual-machine.ibm.com
            allocationMode: ExactCount
            count: 1
            selectors:
              - cel:
                  expression: device.attributes["cex.ibm.com"].type == "${ctype}"
---
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstance
metadata:
  name: ${VM_NAME}
  namespace: ${TEST_NS}
spec:
  domain:
    devices:
      disks:
        - name: containerdisk
          disk:
            bus: virtio
        - name: cloudinit
          disk:
            bus: virtio
      hostDevices:
        - name: cex-${ctype}
          claimName: claim0
          requestName: ${req}
      rng: {}
    resources:
      requests:
        memory: 1Gi
      limits:
        memory: 1Gi
  volumes:
    - name: containerdisk
      containerDisk:
        image: ${FEDORA_DISK}
    - name: cloudinit
      cloudInitNoCloud:
        userData: |-
          #cloud-config
          user: fedora
          password: fedora
          chpasswd: { expire: False }
          ssh_pwauth: True
          ssh_authorized_keys:
            - ${SSH_PUB}
          packages:
            - s390utils-base
  resourceClaims:
    - name: claim0
      resourceClaimTemplateName: single-${ctype}-ap-queue-vm
EOF

  echo "Waiting for VMI phase=Running (image pull + boot)..."
  local i phase ready
  for i in $(seq 1 90); do
    phase="$(kubectl get vmi "${VM_NAME}" -n "${TEST_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    ready="$(kubectl get vmi "${VM_NAME}" -n "${TEST_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    echo "  t=${i}0s phase=${phase} Ready=${ready}"
    # Phase Running is enough to continue; guest SSH is retried in the next step.
    if [[ "$phase" == "Running" ]]; then
      break
    fi
    if [[ "$phase" == "Failed" ]]; then
      kubectl describe vmi "${VM_NAME}" -n "${TEST_NS}" || true
      fail "VMI Failed"
    fi
    sleep 10
  done
  kubectl get vmi "${VM_NAME}" -n "${TEST_NS}"
  kubectl get resourceclaims -n "${TEST_NS}"
  kubectl get vmi "${VM_NAME}" -n "${TEST_NS}" -o jsonpath='{.status.phase}' | grep -qx Running \
    || fail "VMI not Running"
}

# ---------------------------------------------------------------------------
# 9. Final teardown
# ---------------------------------------------------------------------------
final_cleanup() {
  info "9) Delete test namespace, driver, registry, and KubeVirt"
  delete_workloads
  uninstall_driver
  uninstall_registry
  uninstall_kubevirt
  assert_driver_gone
  assert_registry_gone
  assert_kubevirt_gone
  echo "Host lszcrypt after cleanup (queue should be back on the node):"
  lszcrypt || true
}

# ---------------------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: ${0##*/} [command]

Commands:
  all      (default) full end-to-end: clean -> deploy -> VM -> check -> cleanup
  clean    tear down everything (workloads, driver, registry, KubeVirt)
  deploy   registry + build + import + deploy driver (assumes clean cluster)
  vm       start the test VM and check the card (assumes driver deployed)
  check    re-check the card inside an already-running VM

Env: KEEP=1  DELETE_WAIT=${DELETE_WAIT}  KUBEVIRT_VERSION  IMAGE_TAG  TEST_NS=${TEST_NS}
USAGE
}

do_clean() {
  info "Remove CEX DRA driver and registry (if any)"
  delete_workloads
  uninstall_driver
  uninstall_registry

  info "Remove KubeVirt (if any)"
  uninstall_kubevirt
  assert_driver_gone
  assert_registry_gone
  assert_kubevirt_gone
}

do_deploy() {
  install_registry
  build_image
  push_image
  import_image_to_node
  deploy_driver
}

do_all() {
  info "1-2) Remove existing driver, registry, and KubeVirt (if any)"
  do_clean

  check_preconditions
  install_kubevirt
  configure_kubevirt
  do_deploy
  start_vm
  check_card_in_vm

  if [[ "${KEEP}" == "1" ]]; then
    info "KEEP=1: leaving VM, driver, registry, and KubeVirt"
    echo "VM: kubectl -n ${TEST_NS} get vmi ${VM_NAME}"
    echo "SSH: virtctl ssh -n ${TEST_NS} -i ${SSH_PRIV} fedora@vmi/${VM_NAME}"
    echo "registry: http://${REGISTRY_ADDR}/v2/"
    return
  fi
  final_cleanup
  info "E2E finished; cluster leftover namespaces should be gone"
}

main() {
  check_required_tools
  mkdir -p "${WORK_DIR}"

  case "${1:-all}" in
    all)    do_all ;;
    clean)  do_clean ;;
    deploy) do_deploy ;;
    vm)     start_vm; check_card_in_vm ;;
    check)  ensure_ssh_key; check_card_in_vm ;;
    -h|--help|help) usage ;;
    *)      usage; fail "unknown command: $1" ;;
  esac
}

main "$@"
