#!/usr/bin/env bash
# Hardware preconditions (CEX/AP) and KubeVirt/virtctl setup helpers.
# Sourced by cex-dra.sh; requires helpers.sh to already be sourced.

# ---------------------------------------------------------------------------
# 3. Preconditions
# ---------------------------------------------------------------------------
check_cex_availability() {
  echo "kernel: $(uname -r)"
  echo
  echo "--- lszcrypt ---"
  lszcrypt || fail "lszcrypt failed"
  echo
  if ! lszcrypt | grep -Eq '^[0-9a-fA-F]{2}\.[0-9a-fA-F]{4}'; then
    fail "no AP queue (CARD.DOM) visible; CEX is not available on this node"
  fi
  [[ -d /sys/bus/ap ]] || fail "/sys/bus/ap missing"
}

check_ap_masks() {
  echo "--- apmask / aqmask ---"
  local apmask aqmask leftover
  apmask="$(cat /sys/bus/ap/apmask)"
  aqmask="$(cat /sys/bus/ap/aqmask)"
  echo "apmask=${apmask}"
  echo "aqmask=${aqmask}"
  leftover="$(echo "${apmask#0x}${aqmask#0x}" | tr -d 'fF')"
  if [[ -n "$leftover" ]]; then
    echo "WARNING: masks are not all-f; preflight may fail"
    echo "  chzdev --type ap apmask=+0x00-0xff aqmask=+0x00-0xff"
  fi
}

check_driver_override() {
  echo "--- driver_override ---"
  local overrides
  overrides="$(find /sys/bus/ap /sys/devices/ap -name driver_override 2>/dev/null || true)"
  if [[ -z "$overrides" ]]; then
    fail "AP driver_override not found. Fedora 7.x should have it; RHCOS/RHEL 9 typically does not."
  fi
  echo "$overrides"
  echo "driver_override: OK"
}

check_vfio_ap() {
  if [[ ! -e /sys/devices/vfio_ap/matrix ]]; then
    echo "vfio_ap not loaded; modprobe (requires sudo)"
    need_cmd sudo
    sudo modprobe vfio_ap || fail "modprobe vfio_ap failed"
  fi
  [[ -e /sys/devices/vfio_ap/matrix ]] || fail "/sys/devices/vfio_ap/matrix missing"
  echo "vfio_ap: OK"
  ls /sys/class/mdev_bus >/dev/null 2>&1 || fail "/sys/class/mdev_bus missing"
  echo "mdev: OK"
}

check_preconditions() {
  info "3) Preconditions (CEX, driver_override, vfio_ap)"
  [[ "$(uname -m)" == "s390x" ]] || fail "this script is for s390x (got $(uname -m))"

  check_cex_availability
  check_ap_masks
  check_driver_override
  check_vfio_ap
  kubectl get nodes -o wide
}

# ---------------------------------------------------------------------------
# 4–5. KubeVirt / virtctl helpers
# ---------------------------------------------------------------------------
fetch_latest_kubevirt_version() {
  local latest="$(curl -fsSL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt || true)"
  if [[ -z "$latest" ]]; then
    latest="$(curl -fsSL https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep -o '"tag_name": *"[^"]*"' | sed 's/.*": *"\(.*\)"/\1/')"
  fi
  [[ -n "$latest" ]] || fail "could not resolve KubeVirt version (set KUBEVIRT_VERSION=v1.9.0)"
  echo "$latest"
}

resolve_kubevirt_version() {
  if [[ -n "${KUBEVIRT_VERSION}" ]]; then
    echo "${KUBEVIRT_VERSION}"
    return
  fi
  local latest="$(fetch_latest_kubevirt_version)"
  # HostDevicesWithDRA needs >= 1.9
  case "$latest" in
    v1.[0-8].*) echo "v1.9.0" ;;
    *) echo "$latest" ;;
  esac
}

detect_arch() {
  local arch="$(uname -m)"
  case "$arch" in
    s390x) ;;
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
  esac
  echo "$arch"
}

download_virtctl() {
  local ver="$1" arch="$2" bin="$3"
  info "virtctl not on PATH; downloading virtctl ${ver} linux-${arch} to ${bin}"
  curl -fL -o "$bin" \
    "https://github.com/kubevirt/kubevirt/releases/download/${ver}/virtctl-${ver}-linux-${arch}"
  chmod +x "$bin"
  hash -r 2>/dev/null || true
  command -v virtctl >/dev/null 2>&1 || fail "virtctl downloaded to ${bin} but not on PATH"
  echo "virtctl: $(command -v virtctl)"
}

ensure_virtctl() {
  local ver="$1"
  export PATH="${WORK_DIR}:${PATH}"
  if command -v virtctl >/dev/null 2>&1; then
    echo "virtctl: skip (already $(command -v virtctl))"
    return
  fi
  local arch="$(detect_arch)"
  mkdir -p "${WORK_DIR}"
  local bin="${WORK_DIR}/virtctl"
  download_virtctl "$ver" "$arch" "$bin"
}
