#!/usr/bin/env bash
# Hardware checks run on a Kubernetes node via a privileged debug pod
# (chroot /host). Verifies: CEX/AP queue visibility, apmask/aqmask,
# driver_override support, and vfio_ap/mdev availability.
# Executed by check_preconditions() in preconditions.sh via run_on_node.
set -euo pipefail

echo "kernel: $(uname -r)"
echo

echo "--- lszcrypt ---"
lszcrypt || { echo "ERROR: lszcrypt failed" >&2; exit 1; }
echo
if ! lszcrypt | grep -Eq '^[0-9a-fA-F]{2}\.[0-9a-fA-F]{4}'; then
  echo "ERROR: no AP queue (CARD.DOM) visible; CEX is not available on this node" >&2
  exit 1
fi
[[ -d /sys/bus/ap ]] || { echo "ERROR: /sys/bus/ap missing" >&2; exit 1; }

echo "--- apmask / aqmask ---"
apmask="$(cat /sys/bus/ap/apmask)"
aqmask="$(cat /sys/bus/ap/aqmask)"
echo "apmask=${apmask}"
echo "aqmask=${aqmask}"
leftover="$(echo "${apmask#0x}${aqmask#0x}" | tr -d 'fF')"
if [[ -n "$leftover" ]]; then
  echo "WARNING: masks are not all-f; preflight may fail"
  echo "  chzdev --type ap apmask=+0x00-0xff aqmask=+0x00-0xff"
fi

echo "--- driver_override ---"
overrides="$(find /sys/bus/ap /sys/devices/ap -name driver_override 2>/dev/null || true)"
if [[ -z "$overrides" ]]; then
  echo "ERROR: AP driver_override not found. Fedora 7.x should have it; RHCOS/RHEL 9 typically does not." >&2
  exit 1
fi
echo "$overrides"
echo "driver_override: OK"

echo "--- vfio_ap ---"
if [[ ! -e /sys/devices/vfio_ap/matrix ]]; then
  echo "vfio_ap not loaded; loading module"
  modprobe vfio_ap || { echo "ERROR: modprobe vfio_ap failed" >&2; exit 1; }
fi
[[ -e /sys/devices/vfio_ap/matrix ]] || { echo "ERROR: /sys/devices/vfio_ap/matrix missing" >&2; exit 1; }
echo "vfio_ap: OK"
ls /sys/class/mdev_bus >/dev/null 2>&1 || { echo "ERROR: /sys/class/mdev_bus missing" >&2; exit 1; }
echo "mdev: OK"
