#!/bin/bash
# The initramfs hook and the systemd generator for unattended installs are
# /bin/sh scripts, which is dash on Debian: [[ ]] and == are not dash, and a
# test written with them is false. Run both under dash with a kernel command
# line asking for an unattended install from a file, with debugging.
# Needs root and a private mount namespace for /proc/cmdline; skipped
# otherwise (exit 77).
set -u
if [ "$(id -u)" -ne 0 ] || ! command -v dash >/dev/null || ! unshare -m true 2>/dev/null; then
    echo "SKIP: needs root, dash and unshare"
    exit 77
fi
here=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo 'autoinstall settings' > "$work/vii.config"
echo "BOOT_IMAGE=/live/vmlinuz boot=live vyatta-autoinstall=file:$work/vii.config vyatta-autoinstall.debug quiet" > "$work/cmdline"
mkdir -p "$work/root" "$work/normal" "$work/early"

# shellcheck disable=SC2016 # reason: the script runs in the namespace, with its own arguments
unshare -m sh -c '
    mount --bind "$1/cmdline" /proc/cmdline
    rootmnt="$1/root" dash "$2/backend/initramfs-tools/scripts/init-bottom/vyatta-autoinstall"
    dash "$2/systemd/system-generators/vyatta-autoinstall-generator" "$1/normal" "$1/early"
' _ "$work" "$here"

fail=0
if [ "$(cat "$work/root/vii.config" 2>/dev/null)" = 'autoinstall settings' ]; then
    echo "ok: the initramfs hook copied the autoinstall file to the root"
else
    echo "FAIL: the initramfs hook did not copy the autoinstall file"; fail=1
fi
if [ -f "$work/normal/vyatta-autoinstall.service.d/debug.conf" ]; then
    echo "ok: the generator wrote the debug override"
else
    echo "FAIL: the generator did not write the debug override"; fail=1
fi
exit $fail
