#!/usr/bin/env bash
# ============================================================
# OSWorld Ubuntu VM launcher for ABCI (no Docker on ABCI).
#
# Runs the QEMU 9.1 that ships inside happysixd/osworld-docker (the image OSWorld's
# docker provider uses) through `singularity exec --userns`, and reproduces that
# image's own defaults (qemus/qemu-docker scripts, build 2024-10-17):
#   q35 + KVM, -cpu host, 4 vCPU, 4G RAM, UEFI pflash (edk2-x86_64-code.fd),
#   system disk = -hda qcow2 overlay backed by Ubuntu.qcow2, virtio-vga,
#   virtio-net-pci, guest IP 20.20.20.21, guest ports 5000 (server) / 9222 (Chrome CDP) / 8080 (VLC).
# Only networking differs: the image builds a tap bridge + NAT (needs root/NET_ADMIN);
# here it is slirp user-mode networking with per-VM localhost port forwards.
#
# A fresh overlay is created on every `start`, so stop+start == OSWorld revert_to_snapshot.
#
# usage:
#   launch_vm.sh start  <slot>             # prints the OSWorld vm_ip string 127.0.0.1:<server>:<chrome>:<vnc>:<vlc>
#   launch_vm.sh wait   <slot> [timeout_s] # blocks until GET /screenshot returns 200 (default 600 s)
#   launch_vm.sh stop   <slot>
#   launch_vm.sh status <slot>
# ports: slot s -> 20000+10s (server), +1 (chrome), +2 (VNC), +3 (VLC); slot in 0..99
# env:   GRR_ROOT, VM_SIF, VM_BASE (Ubuntu.qcow2), VM_RUN_DIR (default $PBS_LOCALDIR/grr_vms), VM_CPUS, VM_RAM,
#        VM_ACCEL=kvm|tcg — ABCI PBS jobs deny /dev/kvm (EPERM from the job's device cgroup, probe job 2726256),
#        so inside jobs only tcg (pure software emulation, multi-threaded) is available until that changes.
# ============================================================
set -euo pipefail

ROOT=${GRR_ROOT:-/groups/gcg51557/experiments/0314_clip-modality-gap/vangrr}
SIF=${VM_SIF:-$ROOT/vm/osworld-docker.sif}
BASE=${VM_BASE:-$ROOT/vm/Ubuntu.qcow2}
RUN_ROOT=${VM_RUN_DIR:-${PBS_LOCALDIR:-/tmp}/grr_vms}
CPUS=${VM_CPUS:-4}
RAM=${VM_RAM:-4G}
ACCEL=${VM_ACCEL:-kvm}

cmd=${1:?usage: launch_vm.sh start|wait|stop|status <slot> [timeout_s]}
slot=${2:?slot (0..99) required}
[[ "$slot" =~ ^[0-9]+$ ]] && (( slot < 100 )) || { echo "bad slot: $slot" >&2; exit 2; }

base_port=$((20000 + slot * 10))
P_SERVER=$base_port
P_CHROME=$((base_port + 1))
P_VNC=$((base_port + 2))
P_VLC=$((base_port + 3))
RUN=$RUN_ROOT/vm$slot
PIDF=$RUN/qemu.pid
BASE_DIR=$(dirname "$BASE")

alive() { [[ -f $PIDF ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

case "$cmd" in
  start)
    alive && { echo "slot $slot already running (pid $(cat "$PIDF"))" >&2; exit 3; }
    [[ -s $BASE ]] || { echo "missing base image: $BASE" >&2; exit 4; }
    mkdir -p "$RUN"
    rm -f "$RUN/disk.qcow2" "$RUN/uefi.rom"
    singularity exec --userns -B "$BASE_DIR" -B "$RUN" "$SIF" sh -c \
      "qemu-img create -q -f qcow2 -b '$BASE' -F qcow2 '$RUN/disk.qcow2' && cp /usr/share/OVMF/edk2-x86_64-code.fd '$RUN/uefi.rom'"
    # the image runs as root and never notices; as a normal user the copied firmware stays 0444
    # and QEMU cannot open the pflash read-write
    chmod 644 "$RUN/uefi.rom"
    mac=$(printf '02:47:52:00:%02x:%02x' $((slot / 256)) $((slot % 256)))
    net="user,id=hostnet0,host=20.20.20.1,net=20.20.20.0/24,dhcpstart=20.20.20.21,hostname=QEMU"
    net+=",hostfwd=tcp:127.0.0.1:$P_SERVER-20.20.20.21:5000"
    net+=",hostfwd=tcp:127.0.0.1:$P_CHROME-20.20.20.21:9222"
    net+=",hostfwd=tcp:127.0.0.1:$P_VLC-20.20.20.21:8080"
    machine=type=q35,smm=off,graphics=off,vmport=off,dump-guest-core=off,hpet=off
    case "$ACCEL" in
      kvm) accel_args=(-machine "$machine,accel=kvm" -enable-kvm -global kvm-pit.lost_tick_policy=discard -cpu host) ;;
      tcg) accel_args=(-machine "$machine" -accel tcg,thread=multi -cpu max) ;;
      *)   echo "bad VM_ACCEL: $ACCEL (kvm|tcg)" >&2; exit 2 ;;
    esac
    args=(
      -name "grr_vm$slot,process=grr_vm$slot"
      "${accel_args[@]}"
      -smp "$CPUS,sockets=1,dies=1,cores=$CPUS,threads=1" -m "$RAM"
      -display "vnc=127.0.0.1:$((P_VNC - 5900))" -vga virtio
      -monitor "unix:$RUN/monitor.sock,server,nowait"
      -serial "file:$RUN/serial.log"
      -device qemu-xhci,id=xhci -device usb-tablet
      -netdev "$net" -device "virtio-net-pci,romfile=,netdev=hostnet0,mac=$mac,id=net0"
      -hda "$RUN/disk.qcow2" -drive "if=pflash,format=raw,unit=0,file=$RUN/uefi.rom"
      -object rng-random,id=objrng0,filename=/dev/urandom
      -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0,addr=0x1c
      -device virtio-balloon-pci,id=balloon0,bus=pcie.0,addr=0x4
    )
    # Foreground QEMU under singularity (its FUSE mount must outlive QEMU), backgrounded in its
    # own session so `stop` can kill the whole process group.
    setsid singularity exec --userns -B "$BASE_DIR" -B "$RUN" "$SIF" \
      qemu-system-x86_64 "${args[@]}" > "$RUN/qemu.log" 2>&1 < /dev/null &
    echo $! > "$PIDF"
    echo "127.0.0.1:$P_SERVER:$P_CHROME:$P_VNC:$P_VLC"
    ;;
  wait)
    timeout_s=${3:-600}
    t0=$(date +%s)
    while (( $(date +%s) - t0 < timeout_s )); do
      alive || { echo "slot $slot: qemu exited" >&2; tail -20 "$RUN/qemu.log" >&2; exit 5; }
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$P_SERVER/screenshot" || true)
      [[ $code == 200 ]] && exit 0
      sleep 3
    done
    echo "slot $slot: server not ready after ${timeout_s}s" >&2
    exit 6
    ;;
  stop)
    if [[ -f $PIDF ]]; then
      pid=$(cat "$PIDF")
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -KILL -- "-$pid" 2>/dev/null || true
      rm -f "$PIDF"
    fi
    rm -f "$RUN/disk.qcow2" "$RUN/monitor.sock"
    ;;
  status)
    if alive; then echo "running pid=$(cat "$PIDF") server=127.0.0.1:$P_SERVER"; else echo "stopped"; fi
    ;;
  *)
    echo "unknown command: $cmd" >&2; exit 2
    ;;
esac
