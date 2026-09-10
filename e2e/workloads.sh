#!/usr/bin/env bash
# Registry and workload management helpers for e2e tests.

node_internal_ip() {
  local ip
  ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  [[ -n "$ip" ]] || fail "could not read node InternalIP"
  echo "$ip"
}

set_registry_image_vars() {
  if [[ -z "${IMAGE_TAG}" ]]; then
    IMAGE_TAG="$(git -C "${REPO_DIR}" rev-parse --short=12 HEAD)"
  fi
  REGISTRY_ADDR="$(node_internal_ip):${REGISTRY_NODEPORT}"
  IMAGE_NAME="${REGISTRY_ADDR}/${PLUGIN_REPO}"
  IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
}

apply_registry_manifest() {
  REGISTRY_NS="${REGISTRY_NS}" \
  REGISTRY_NAME="${REGISTRY_NAME}" \
  REGISTRY_IMAGE="${REGISTRY_IMAGE}" \
  REGISTRY_NODEPORT="${REGISTRY_NODEPORT}" \
    envsubst < "${SCRIPT_DIR}/registry.yaml.tmpl" | kubectl apply -f -
  kubectl -n "${REGISTRY_NS}" rollout status "deploy/${REGISTRY_NAME}" --timeout=180s
}

wait_for_registry() {
  for i in $(seq 1 30); do
    if curl -sf "http://${REGISTRY_ADDR}/v2/" >/dev/null; then
      echo "registry ready at http://${REGISTRY_ADDR}/v2/"
      return
    fi
    echo "  waiting for registry HTTP on ${REGISTRY_ADDR} (${i}/30)"
    sleep 2
  done
  kubectl -n "${REGISTRY_NS}" get pods,svc -o wide || true
  kubectl -n "${REGISTRY_NS}" logs "deploy/${REGISTRY_NAME}" --tail=50 || true
  fail "in-cluster registry did not become ready on ${REGISTRY_ADDR}"
}

install_registry() {
  info "6) In-cluster registry (${REGISTRY_NS})"
  set_registry_image_vars
  echo "Driver image will be ${IMAGE}"
  apply_registry_manifest
  wait_for_registry
}

image_in_registry() {
  [[ -n "${REGISTRY_ADDR}" ]] || return 1
  local out
  out="$(curl -sf "http://${REGISTRY_ADDR}/v2/${PLUGIN_REPO}/tags/list" 2>/dev/null || true)"
  echo "$out" | grep -q "\"${IMAGE_TAG}\""
}

# CRI-O will not pull HTTP NodePort without a root change to registries.conf.
# Copy the pushed image into the node's CRI-O store from inside the cluster.
apply_image_import_job() {
  local node src
  node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
  src="docker://${REGISTRY_NAME}.${REGISTRY_NS}.svc.cluster.local:5000/${PLUGIN_REPO}:${IMAGE_TAG}"
  kdel job cex-dra-image-import -n "${REGISTRY_NS}"
  REGISTRY_NS="${REGISTRY_NS}" \
  NODE="${node}" \
  IMPORT_IMAGE="${IMPORT_IMAGE}" \
  SRC="${src}" \
  IMAGE="${IMAGE}" \
    envsubst < "${SCRIPT_DIR}/image-import.yaml.tmpl" | kubectl apply -f -
}

import_image_to_node() {
  step "Import ${IMAGE} into the node container store"
  apply_image_import_job
  if ! kubectl -n "${REGISTRY_NS}" wait --for=condition=complete "job/cex-dra-image-import" --timeout=300s; then
    kubectl -n "${REGISTRY_NS}" describe "job/cex-dra-image-import" || true
    kubectl -n "${REGISTRY_NS}" logs "job/cex-dra-image-import" --tail=80 || true
    fail "failed to import ${IMAGE} into the node container store"
  fi
  echo "imported ${IMAGE}"
}

# ---------------------------------------------------------------------------
# 1–2. Remove leftover driver and KubeVirt
# ---------------------------------------------------------------------------
delete_vms_in_namespace() {
  crd_exists virtualmachineinstances.kubevirt.io || return 0
  kdel vmi,vm -n "${TEST_NS}" --all
  require_empty "VirtualMachines" vmi -n "${TEST_NS}"
}

delete_resourceclaims_in_namespace() {
  crd_exists resourceclaims.resource.k8s.io || return 0
  kdel resourceclaim,resourceclaimtemplate -n "${TEST_NS}" --all
  require_empty "ResourceClaims" resourceclaim -n "${TEST_NS}"
}

delete_workloads() {
  # Scope teardown to the test namespace this script owns. Do NOT touch VMs or
  # ResourceClaims in other namespaces.
  step "Deleting VMs and ResourceClaims in namespace ${TEST_NS}"
  if still_there ns "${TEST_NS}"; then
    delete_vms_in_namespace
    delete_resourceclaims_in_namespace
  fi
  kdel ns "${TEST_NS}"
  require_ns_gone "${TEST_NS}"
}
