#!/usr/bin/env bash
# Quick boot test: QEMU microvm + kernel + rootfs (no networking needed)
set -euo pipefail

BOLD=$'\033[1m' GREEN=$'\033[0;32m' RED=$'\033[0;31m' RESET=$'\033[0m'
die() { echo "${RED}ERROR: $*${RESET}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

BASE_DIR="${HOME}/.local/share/paranoid/base"
VMLINUZ="${BASE_DIR}/vmlinuz"
BASE_IMAGE="${BASE_DIR}/alpine-base.qcow2"
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

[[ -f "$VMLINUZ" ]] || die "Kernel not found: $VMLINUZ (run paranoid setup first)"
[[ -f "$BASE_IMAGE" ]] || die "Base image not found: $BASE_IMAGE"

echo "${BOLD}Creating test overlay...${RESET}"
qemu-img create -f qcow2 -b "$BASE_IMAGE" -B qcow2 "${WORKDIR}/test.qcow2" 2G >/dev/null

echo "${BOLD}Booting QEMU microVM (15s timeout)...${RESET}"
timeout 15 qemu-system-x86_64 \
    -M "microvm,isa-serial=on,rtc=off,pit=off,pic=off" \
    -enable-kvm -cpu host -m 256 -smp 1 \
    -nodefaults -no-user-config -nographic \
    -kernel "$VMLINUZ" \
    -append "console=ttyS0 root=/dev/vda rw quiet init=/sbin/micro-init" \
    -drive "id=rootfs,file=${WORKDIR}/test.qcow2,format=qcow2,if=none" \
    -device "virtio-blk-device,drive=rootfs" \
    -serial stdio 2>&1 | tee "${WORKDIR}/boot.log" &
PID=$!

BOOTED=0
for _ in $(seq 1 30); do
    sleep 0.5
    grep -q "login:" "${WORKDIR}/boot.log" 2>/dev/null && { BOOTED=1; break; }
    grep -qi "panic\|not syncing" "${WORKDIR}/boot.log" 2>/dev/null && {
        kill $PID 2>/dev/null; wait $PID 2>/dev/null
        echo "${RED}${BOLD}KERNEL PANIC${RESET}"
        grep -i "panic\|not syncing" "${WORKDIR}/boot.log"
        exit 1
    }
done

kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo ""
[[ $BOOTED -eq 1 ]] \
    && echo "${GREEN}${BOLD}BOOT TEST PASSED${RESET}" \
    || echo "${RED}${BOLD}BOOT TEST FAILED — no login prompt in 15s${RESET}"
exit $((1 - BOOTED))
