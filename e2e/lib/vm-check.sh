#!/usr/bin/env bash
# VM guest SSH helpers and AP-device verification.
#
# Sourced by cex-dra.sh.  Requires the following variables to be set by the
# caller before any function is invoked:
#
#   WORK_DIR   – writable directory used to cache the generated SSH key pair
#   TEST_NS    – Kubernetes namespace where the VMI is running
#   VM_NAME    – name of the VirtualMachineInstance
#
# After ensure_ssh_key() returns, SSH_PUB and SSH_PRIV are available to the
# caller (e.g. to embed the public key in the cloud-init userData).

# ---------------------------------------------------------------------------
# SSH key management
# ---------------------------------------------------------------------------

ensure_ssh_key() {
  mkdir -p "${WORK_DIR}"
  if [[ ! -f "${WORK_DIR}/id_ed25519" || ! -f "${WORK_DIR}/id_ed25519.pub" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${WORK_DIR}/id_ed25519" -q
  fi
  SSH_PUB="$(cat "${WORK_DIR}/id_ed25519.pub")"
  SSH_PRIV="${WORK_DIR}/id_ed25519"
}

# ---------------------------------------------------------------------------
# virtctl / plain-ssh helpers
# ---------------------------------------------------------------------------

# Probe once whether the installed virtctl supports --local-ssh-opts; result
# is cached in VIRTCTL_HAS_LOCAL_SSH_OPTS (1 or 0) for subsequent calls.
_probe_virtctl_ssh() {
  [[ -n "${VIRTCTL_HAS_LOCAL_SSH_OPTS:-}" ]] && return
  if virtctl ssh --help 2>&1 | grep -q -- '--local-ssh-opts'; then
    VIRTCTL_HAS_LOCAL_SSH_OPTS=1
  else
    VIRTCTL_HAS_LOCAL_SSH_OPTS=0
  fi
}

# Populate the caller-supplied array (nameref) with the virtctl ssh arguments
# for the given cmd.  Requires _probe_virtctl_ssh to have been called first.
_build_virtctl_ssh_args() {
  local -n _args_ref="$1"   # nameref — caller passes the array name as a string
  local cmd="$2"
  _args_ref=(-n "${TEST_NS}")
  [[ -n "${SSH_PRIV:-}" ]] && _args_ref+=(-i "${SSH_PRIV}")
  if [[ "${VIRTCTL_HAS_LOCAL_SSH_OPTS}" == "1" ]]; then
    _args_ref+=("--local-ssh-opts=-o StrictHostKeyChecking=no")
    _args_ref+=("--local-ssh-opts=-o UserKnownHostsFile=/dev/null")
    _args_ref+=("--local-ssh-opts=-o ConnectTimeout=8")
  fi
  _args_ref+=(-c "${cmd}" "fedora@vmi/${VM_NAME}")
}

# Run cmd inside the VM via virtctl ssh.  Returns 0 on success, non-zero if
# virtctl is not installed or the command fails.
_guest_ssh_virtctl() {
  local cmd="$1"
  command -v virtctl >/dev/null 2>&1 || return 1
  _probe_virtctl_ssh
  local -a vargs
  _build_virtctl_ssh_args vargs "${cmd}"
  virtctl ssh "${vargs[@]}"
}

# Fall back to plain ssh using the VM's IP from the VMI status.
_guest_ssh_plain() {
  local cmd="$1"
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

# Run cmd inside the VM: try virtctl ssh first, then fall back to plain ssh.
guest_ssh() {
  local cmd="$1"
  _guest_ssh_virtctl "${cmd}" && return 0
  _guest_ssh_plain "${cmd}"
}

# ---------------------------------------------------------------------------
# AP-device verification helpers
# ---------------------------------------------------------------------------

# Print the host-side lszcrypt output so the caller can verify the queue has
# moved into the VM (the queue line should be absent on the host).
_show_host_lszcrypt() {
  echo "--- host lszcrypt (queue line gone means the VM holds it) ---"
  run_on_node 'lszcrypt || true' || true
  echo
}

# Attempt one SSH round-trip into the guest and check whether an AP device is
# visible.  Sets the caller-local variable 'out' on success.
# Returns 0 when an AP device is detected (caller should return immediately),
# 1 when the SSH succeeded but no AP device was visible yet, and 2 when SSH
# itself failed.
_probe_guest_ap() {
  local errf="$1"
  local -n _out_ref="$2"   # nameref — caller passes the variable name
  if _out_ref="$(guest_ssh 'ls /sys/bus/ap/devices 2>/dev/null; command -v lszcrypt >/dev/null && lszcrypt || true' 2>"$errf")"; then
    echo "${_out_ref}"
    if echo "${_out_ref}" | grep -Eq '^[0-9a-fA-F]{2}\.[0-9a-fA-F]{4}|card[0-9a-fA-F]{2}'; then
      return 0
    fi
    return 1
  fi
  return 2
}

# Emit periodic diagnostic output when the guest is taking unusually long.
# Called on retries 12 and 24 so successful fast runs stay quiet.
_maybe_emit_diagnostics() {
  local i="$1"
  local detail="$2"
  if (( i == 12 || i == 24 )); then
    [[ -n "$detail" ]] && echo "    last ssh detail: ${detail}"
    kubectl get vmi "${VM_NAME}" -n "${TEST_NS}" 2>/dev/null || true
  fi
}

# Dump full VMI description and recent events, then fail with a clear message.
_fail_no_ap_device() {
  kubectl describe vmi "${VM_NAME}" -n "${TEST_NS}" || true
  kubectl get events -n "${TEST_NS}" --sort-by=.lastTimestamp | tail -30 || true
  fail "guest never showed an AP queue (lszcrypt /sys/bus/ap)"
}

# Read the SSH error file, sanitise CR/newlines, and print the appropriate
# retry progress line.  Echoes the cleaned detail string so the caller can
# pass it on to _maybe_emit_diagnostics.
_print_retry_status() {
  local i="$1"
  local errf="$2"
  local detail
  # "connection refused" / "255" on the early tries just means sshd/cloud-init
  # is still coming up; that is expected and the loop retries. Only surface
  # the (CR-sanitized) detail periodically so it is not mistaken for a crash.
  detail="$(tr -d '\r' < "$errf" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//;s/ *$//')"
  if echo "$detail" | grep -qiE 'connection refused|dial tcp|no route to host|exit status 255|handshake'; then
    echo "  retry ${i}/36 (guest sshd not ready yet)..."
  else
    echo "  retry ${i}/36..."
  fi
  echo "$detail"
}

# Execute one probe iteration for retry i: probe the guest, announce success
# or print retry status + diagnostics, then clean up the temp file.
# Returns 0 when an AP device is confirmed (caller should stop the loop),
# 1 when the attempt failed or no device was visible yet.
_run_probe_iteration() {
  local i="$1" out errf detail
  errf="$(mktemp)"
  if _probe_guest_ap "$errf" out; then
    rm -f "$errf"
    echo
    echo "Guest sees an AP device: OK"
    kubectl get resourceclaims -n "${TEST_NS}"
    return 0
  fi
  detail="$(_print_retry_status "$i" "$errf")"
  # Only surface ssh detail once the guest is taking unusually long (a normal
  # boot connects within the first few retries), so successful runs stay quiet.
  _maybe_emit_diagnostics "$i" "$detail"
  rm -f "$errf"
  return 1
}

# Drive the SSH retry loop: probe the guest up to 36 times (10 s apart).
# Returns normally when an AP device is confirmed; calls _fail_no_ap_device
# when all attempts are exhausted.
_poll_guest_ap() {
  local i
  for i in $(seq 1 36); do
    if _run_probe_iteration "$i"; then
      return
    fi
    sleep 10
  done
  _fail_no_ap_device
}

check_card_in_vm() {
  info "Check CEX card inside the VM"
  _show_host_lszcrypt
  echo "Checking guest via virtctl ssh (sshd + cloud-init can take a minute)..."
  _poll_guest_ap
}
