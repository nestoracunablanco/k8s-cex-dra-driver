#!/usr/bin/env bash
# Uninstall helpers: tear down the in-cluster registry, CEX DRA driver, and KubeVirt.

uninstall_registry() {
  step "Removing in-cluster registry (if present)"
  stop_registry_port_forward
  kdel ns "${REGISTRY_NS}"
  require_ns_gone "${REGISTRY_NS}"
  assert_registry_gone
}

# ---------------------------------------------------------------------------
# 1–2. Remove leftover driver and KubeVirt
# ---------------------------------------------------------------------------

remove_vfio_ap_mdevs() {
  [[ -d /sys/devices/vfio_ap/matrix ]] || return 0
  local d base
  for d in /sys/devices/vfio_ap/matrix/*; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    [[ "$base" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
    if [[ -w "$d/remove" ]]; then
      echo 1 | sudo tee "$d/remove" >/dev/null || true
    fi
  done
}

delete_cex_resourceslices() {
  crd_exists resourceslices.resource.k8s.io || return 0
  kdel resourceslice -l app.kubernetes.io/name=cex-dra-driver
  while IFS=' ' read -r name driver rest; do
    [[ -n "$name" ]] || continue
    if echo "${name} ${driver} ${rest}" | grep -qiE 'cex|ap-queue|vfio_ap'; then
      echo "deleting ResourceSlice ${name} driver= ${driver}"
      kubectl delete resourceslice "$name" --ignore-not-found=true --wait=true --timeout="${DELETE_WAIT}s" || true
    fi
  done < <(kubectl get resourceslice -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.driver}{" "}{.spec}{"\n"}{end}' 2>/dev/null || true)
}

delete_cex_cluster_resources() {
  kdel clusterrole cex-dra-driver
  kdel clusterrolebinding cex-dra-driver
  kdel deviceclass ap-queue.virtual-machine.ibm.com
  kdel deviceclass -l app.kubernetes.io/name=cex-dra-driver
  delete_cex_resourceslices
  local leftover="$(cex_cluster_leftovers)"
  if [[ -n "$leftover" ]]; then
    echo "Deleting remaining CEX DRA cluster objects:"
    echo "$leftover"
    # shellcheck disable=SC2086
    kdel $leftover
  fi
}

uninstall_driver() {
  step "Removing CEX DRA driver (if present)"
  local od="$(overlay_dir)"
  if [[ -d "$od" ]]; then
    kubectl delete -k "$od" --ignore-not-found=true --wait=true --timeout="${DELETE_WAIT}s" || true
  fi
  kdel daemonset cex-dra-driver -n cex-dra-driver
  kdel ns cex-dra-driver
  require_ns_gone cex-dra-driver
  delete_cex_cluster_resources
  remove_vfio_ap_mdevs
  assert_driver_gone
}

delete_kubevirt_apiservices_webhooks() {
  kdel apiservice v1.subresources.kubevirt.io v1alpha3.subresources.kubevirt.io
  kdel mutatingwebhookconfiguration virt-api-mutator
  kdel validatingwebhookconfiguration \
    virt-api-validator virt-operator-validator virt-template-validating-webhook-configuration
}

_kubevirt_already_gone() {
  if ! still_there ns kubevirt && [[ -z "$(kubevirt_cluster_leftovers)" ]]; then
    echo "KubeVirt: nothing to remove"
    assert_kubevirt_gone
    return 0
  fi
  return 1
}

_delete_kubevirt_cr() {
  # CR first, then APIServices/webhooks, then operator. Wait up to DELETE_WAIT
  # seconds for each step, then error and stop if it is not gone.
  if crd_exists kubevirts.kubevirt.io; then
    kdel kubevirt --all -A
    require_empty "KubeVirt CR" kubevirt -A
  fi
  delete_kubevirt_apiservices_webhooks
}

_delete_kubevirt_operator() {
  local ver="${KUBEVIRT_VERSION:-}"
  if [[ -z "$ver" && -f "${WORK_DIR}/kubevirt.version" ]]; then
    ver="$(cat "${WORK_DIR}/kubevirt.version")"
  fi
  if [[ -n "$ver" ]]; then
    kubectl delete -f "https://github.com/kubevirt/kubevirt/releases/download/${ver}/kubevirt-operator.yaml" \
      --ignore-not-found=true --wait=true --timeout="${DELETE_WAIT}s" || true
  else
    kdel deployment virt-operator -n kubevirt
  fi
  kdel ns kubevirt
  require_ns_gone kubevirt
}

_delete_kubevirt_leftovers() {
  local leftover="$(kubevirt_cluster_leftovers)"
  if [[ -n "$leftover" ]]; then
    echo "Deleting remaining KubeVirt cluster objects:"
    echo "$leftover"
    # shellcheck disable=SC2086
    kdel $leftover
  fi
}

uninstall_kubevirt() {
  step "Removing KubeVirt (if present)"
  _kubevirt_already_gone && return 0
  _delete_kubevirt_cr
  _delete_kubevirt_operator
  _delete_kubevirt_leftovers
  assert_kubevirt_gone
}
