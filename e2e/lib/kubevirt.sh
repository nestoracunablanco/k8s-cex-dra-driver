#!/usr/bin/env bash
# kubevirt.sh — KubeVirt install/configure helpers.
# Sourced by cex-dra.sh; expects SCRIPT_DIR, WORK_DIR, and kubectl to be
# available in the calling environment.

install_kubevirt() {
  info "Deploy KubeVirt"
  assert_kubevirt_gone
  KUBEVIRT_VERSION="$(resolve_kubevirt_version)"
  echo "${KUBEVIRT_VERSION}" > "${WORK_DIR}/kubevirt.version"
  echo "KubeVirt ${KUBEVIRT_VERSION}"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  echo "Waiting for KubeVirt Available (can take several minutes)..."
  kubectl wait -n kubevirt kubevirt/kubevirt --for=condition=Available --timeout=600s
  kubectl get kubevirt -n kubevirt
  ensure_virtctl "${KUBEVIRT_VERSION}"
}

configure_kubevirt() {
  info "Configure KubeVirt feature gates and vfio-ap keep-list"
  kubectl patch kubevirt kubevirt -n kubevirt --type merge \
    --patch-file "${SCRIPT_DIR}/kubevirt-config-patch.yaml"
  kubectl wait -n kubevirt kubevirt/kubevirt --for=condition=Available --timeout=300s
  echo "featureGates / permittedHostDevices:"
  kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}{"\n"}'
  kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.spec.configuration.permittedHostDevices}{"\n"}'
}
