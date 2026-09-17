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
REGISTRY_LOCAL_PORT="${REGISTRY_LOCAL_PORT:-5000}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-docker.io/library/registry:2}"
IMPORT_IMAGE="${IMPORT_IMAGE:-quay.io/skopeo/stable:latest}"
# Set after install_registry: NODE_IP:30511/cex-dra-kubeletplugin
IMAGE_NAME=""
IMAGE=""
REGISTRY_ADDR=""
REGISTRY_PF_PID=""

# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/lib/helpers.sh"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"
# shellcheck source=lib/workloads.sh
source "${SCRIPT_DIR}/lib/workloads.sh"
# shellcheck source=lib/uninstall.sh
source "${SCRIPT_DIR}/lib/uninstall.sh"
# shellcheck source=lib/preconditions.sh
source "${SCRIPT_DIR}/lib/preconditions.sh"
# shellcheck source=lib/kubevirt.sh
source "${SCRIPT_DIR}/lib/kubevirt.sh"
# shellcheck source=lib/driver.sh
source "${SCRIPT_DIR}/lib/driver.sh"
# shellcheck source=lib/vm-check.sh
source "${SCRIPT_DIR}/lib/vm-check.sh"
# shellcheck source=lib/vm.sh
source "${SCRIPT_DIR}/lib/vm.sh"

# Announce non-zero exits. This script does NOT auto-clean on failure so the
# broken state can be inspected; re-running the script cleans up first (steps
# 1-2), or run './deploy-cex-dra-fedora.sh clean' to tear everything down.
on_exit() {
  local rc=$?
  stop_registry_port_forward
  if [[ $rc -ne 0 ]]; then
    echo >&2
    echo "FAILED (exit ${rc}). Cluster state left in place for debugging." >&2
    echo "  clean up with:  ${0} clean   (or just re-run; steps 1-2 remove leftovers)" >&2
  fi
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# 9. Final teardown
# ---------------------------------------------------------------------------
final_cleanup() {
  info "Delete test namespace, driver, registry, and KubeVirt"
  delete_workloads
  uninstall_driver
  uninstall_registry
  uninstall_kubevirt
  assert_driver_gone
  assert_registry_gone
  assert_kubevirt_gone
  echo "Node lszcrypt after cleanup (queue should be back on the node):"
  run_on_node 'lszcrypt || true' || true
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
  info "Remove existing driver and registry (if any)"
  delete_workloads
  uninstall_driver
  uninstall_registry
  assert_driver_gone
  assert_registry_gone

  install_registry
  build_image
  push_image
  import_image_to_node
  deploy_driver
}

do_all() {
  info "Remove existing driver, registry, and KubeVirt (if any)"
  do_clean

  check_preconditions
  install_kubevirt
  configure_kubevirt
  install_registry
  build_image
  push_image
  import_image_to_node
  deploy_driver
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
