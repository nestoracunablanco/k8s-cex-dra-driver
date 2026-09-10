#!/usr/bin/env bash
# deploy.sh — KubeVirt install/configure and CEX DRA driver build/deploy helpers.
# Sourced by cex-dra.sh; expects SCRIPT_DIR, REPO_DIR, WORK_DIR, IMAGE, IMAGE_NAME,
# IMAGE_TAG, OVERLAY, and kubectl/podman to be available in the calling environment.

install_kubevirt() {
  info "4) Deploy KubeVirt"
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
  info "5) Configure KubeVirt feature gates and vfio-ap keep-list"
  kubectl patch kubevirt kubevirt -n kubevirt --type merge \
    --patch-file "${SCRIPT_DIR}/kubevirt-config-patch.yaml"
  kubectl wait -n kubevirt kubevirt/kubevirt --for=condition=Available --timeout=300s
  echo "featureGates / permittedHostDevices:"
  kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}{"\n"}'
  kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.spec.configuration.permittedHostDevices}{"\n"}'
}

# ---------------------------------------------------------------------------
# 6. Registry + driver image (rootless) + deploy
# ---------------------------------------------------------------------------
build_image() {
  [[ -n "${IMAGE}" ]] || fail "registry address not set (install_registry first)"
  set_registry_image_vars
  cd "${REPO_DIR}"
  local version="$(git describe --tags --always --dirty --long)"
  mkdir -p "${WORK_DIR}"
  info "CI build ${IMAGE} from ${version}"
  podman build --platform=linux/s390x \
    --build-arg VERSION="${version}" \
    --no-cache \
    -t "${IMAGE}" \
    .
}

push_image() {
  [[ -n "${IMAGE}" ]] || fail "registry address not set (install_registry first)"
  echo "Pushing ${IMAGE} (HTTP registry, tls-verify=false)"
  for attempt in 1 2 3; do
    if podman push --tls-verify=false "${IMAGE}"; then
      break
    fi
    [[ "$attempt" == "3" ]] && fail "podman push failed after 3 attempts"
    echo "  push attempt ${attempt} failed; retrying in 5s"
    sleep 5
  done
  image_in_registry || fail "push finished but ${IMAGE} is not in the registry catalog"
}

# Prepare the kustomize overlay directory with the target image name and tag.
prepare_overlay() {
  local od="$(overlay_dir)"
  local template="${REPO_DIR}/deploy/kustomize/overlays/template"
  [[ -d "$template" ]] || fail "missing ${template} after git update"
  if [[ "$od" != "$template" ]]; then
    rm -rf "$od"
    cp -a "$template" "$od"
  fi
  sed -i "0,/newName:/{s|\(newName:[[:space:]]*\).*|\1${IMAGE_NAME}|}" "$od/kustomization.yaml"
  sed -i "0,/newTag:/{s|\(newTag:[[:space:]]*\).*|\1${IMAGE_TAG}|}" "$od/kustomization.yaml"
  echo "$od/kustomization.yaml -> ${IMAGE_NAME} ${IMAGE_TAG}"
}

# Apply the kustomize overlay and force imagePullPolicy=IfNotPresent on the daemonset.
apply_driver_manifests() {
  local od="$(overlay_dir)"
  kubectl apply -k "$od"
  kubectl -n cex-dra-driver patch daemonset cex-dra-driver --type json -p \
    '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
    >/dev/null 2>&1 || \
  kubectl -n cex-dra-driver patch daemonset cex-dra-driver --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
    >/dev/null 2>&1 || true
}

# Poll until at least one ResourceSlice device is published by the driver.
wait_for_resourceslice() {
  echo "Waiting for ResourceSlice..."
  for i in $(seq 1 30); do
    if kubectl get resourceslices -o jsonpath='{.items[*].spec.devices[*].name}' 2>/dev/null | grep -q .; then
      kubectl get resourceslices -o wide
      return
    fi
    sleep 5
  done
  kubectl -n cex-dra-driver logs -l app.kubernetes.io/name=cex-dra-driver --tail=80 || true
  fail "no ResourceSlice devices published"
}

# Wait for the driver daemonset to roll out and for at least one ResourceSlice device.
wait_for_driver() {
  kubectl -n cex-dra-driver rollout status daemonset/cex-dra-driver --timeout=180s
  kubectl -n cex-dra-driver get pods -o wide
  kubectl -n cex-dra-driver logs -l app.kubernetes.io/name=cex-dra-driver --tail=30 || true
  wait_for_resourceslice
}

deploy_driver() {
  info "6) Deploy CEX DRA driver"
  assert_driver_gone
  [[ -n "${IMAGE_NAME}" ]] || fail "registry address not set (install_registry first)"
  cd "${REPO_DIR}"
  prepare_overlay
  apply_driver_manifests
  wait_for_driver
}

cex_type_from_cluster() {
  local t="$(kubectl get resourceslices -o jsonpath='{.items[0].spec.devices[0].attributes.cex\.ibm\.com/type.string}' 2>/dev/null || true)"
  if [[ -n "$t" ]]; then
    echo "$t"
    return
  fi
  if lszcrypt | grep -qi EP11; then
    echo ep11
  elif lszcrypt | grep -qi CCA; then
    echo cca
  else
    echo ep11
  fi
}
