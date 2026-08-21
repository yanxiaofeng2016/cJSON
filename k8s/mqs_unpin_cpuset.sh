#!/bin/bash
# 在宿主机上把指定进程从 kubelet 独占 cpuset 迁到整机 cpuset，并拉宽 affinity。
#
# 用法（root）:
#   ./mqs_unpin_cpuset.sh <pid>
#   ./mqs_unpin_cpuset.sh 85559
#   ./mqs_unpin_cpuset.sh -q 16 85559          # 同时卡 CPU quota=16 核
#   ./mqs_unpin_cpuset.sh -l -q 16 85559       # 每 2 秒循环纠正（Hulk 会钉回去）
#   ./mqs_unpin_cpuset.sh mqs                  # 非数字参数按 cmdline 模糊匹配
#
# 原理（cgroup v1）:
#   1) 在 /sys/fs/cgroup/cpuset 下建与 kubepods 同级的 mqs_full_cpuset
#      （必须是同级：写在容器自己的 cpuset 子目录里扩不出去）
#   2) echo $pid > mqs_full_cpuset/cgroup.procs   # 迁出独占核
#   3) taskset -acp <online> $pid                 # attach 只重置那一瞬间的 affinity，
#                                                 # Hulk 之后再 sched_setaffinity 会钉回 16 核
#   4) 可选：迁到 cpu/mqs_quota_<pid>，cfs_quota = N*100000
#
# 内存 / pids 控制器不动。

set -u

CSROOT="${MQS_CPUSET_ROOT:-/sys/fs/cgroup/cpuset}"
CPUROOT="${MQS_CPU_ROOT:-/sys/fs/cgroup/cpu}"
PIN_NAME="${MQS_PIN_NAME:-mqs_full_cpuset}"
PIN="${CSROOT}/${PIN_NAME}"
QUOTA_CORES="${MQS_QUOTA_CORES:-}"
LOOP=0
INTERVAL=2
PID_ONLY=0
DRY=0

usage() {
  cat <<EOF
用法: $0 [-q N] [-l] [-i 秒] [-p] [-n] <pid|关键字> [pid...]

  -q N    同时把进程迁到 ${CPUROOT}/mqs_quota_<pid>，CFS quota=N 核
  -l      循环纠正（默认每 2 秒）；Hulk/kubelet 会把 affinity 或 cgroup 改回去
  -i 秒   循环间隔（默认 2）
  -p      只迁指定 pid，不迁它所在 cpuset cgroup 里的其它进程
  -n      dry-run，只打印

例:
  $0 85559
  $0 -q 16 -l 85559
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -q|--quota) QUOTA_CORES="$2"; shift 2 ;;
    -l|--loop) LOOP=1; shift ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -p|--pid-only) PID_ONLY=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    --) shift; break ;;
    -*) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 跑（需要写 ${CSROOT}）。" >&2
  exit 1
fi

resolve_pids() {
  local a out=""
  for a in "$@"; do
    if [[ "$a" =~ ^[0-9]+$ ]]; then
      if [[ -d "/proc/$a" ]]; then
        out+="$a "
      else
        echo "警告: pid $a 不存在" >&2
      fi
    else
      local found
      found=$(pgrep -f "$a" 2>/dev/null || true)
      if [[ -z "$found" ]]; then
        echo "警告: 没有 cmdline 匹配 '$a' 的进程" >&2
      else
        out+="$found "
      fi
    fi
  done
  echo "$out"
}

cg_field() {
  local pid="$1" ctrl="$2"
  awk -F: -v c="$ctrl" '$2 == c || $2 ~ "(^|,)" c "(,|$)" { print $3; exit }' "/proc/$pid/cgroup" 2>/dev/null
}

run() {
  if (( DRY )); then
    echo "DRY: $*"
    return 0
  fi
  "$@"
}

write_file() {
  local file="$1" val="$2"
  if (( DRY )); then
    echo "DRY: echo '$val' > $file"
    return 0
  fi
  if ! printf '%s\n' "$val" > "$file" 2>/dev/null; then
    echo "失败: echo '$val' > $file" >&2
    return 1
  fi
}

ensure_pin() {
  if [[ ! -f "${CSROOT}/cgroup.procs" ]]; then
    echo "错误: 找不到 ${CSROOT}/cgroup.procs（不是 cgroup v1 cpuset？）" >&2
    exit 1
  fi
  run mkdir -p "$PIN"
  local mems cpus
  mems=$(cat "${CSROOT}/cpuset.mems" 2>/dev/null || echo 0)
  cpus=$(cat "${CSROOT}/cpuset.cpus" 2>/dev/null || cat /sys/devices/system/cpu/online)
  # cgroup v1：必须先写 mems 再写 cpus
  write_file "${PIN}/cpuset.mems" "$mems" || return 1
  write_file "${PIN}/cpuset.cpus" "$cpus" || return 1
  if [[ -w "${PIN}/cpuset.memory_migrate" ]]; then
    write_file "${PIN}/cpuset.memory_migrate" 1 || true
  fi
  echo "pin=$PIN  cpus=$(cat "${PIN}/cpuset.cpus" 2>/dev/null)  mems=$(cat "${PIN}/cpuset.mems" 2>/dev/null)"
}

ensure_quota() {
  local pid="$1" cores="$2"
  local qdir="${CPUROOT}/mqs_quota_${pid}"
  if [[ ! -f "${CPUROOT}/cgroup.procs" ]]; then
    echo "警告: 找不到 ${CPUROOT}/cgroup.procs，跳过 quota" >&2
    return 0
  fi
  run mkdir -p "$qdir"
  write_file "${qdir}/cpu.cfs_period_us" 100000 || true
  write_file "${qdir}/cpu.cfs_quota_us" $(( cores * 100000 )) || true
  echo "quota=$qdir  cfs_quota_us=$(cat "${qdir}/cpu.cfs_quota_us" 2>/dev/null)" >&2
  printf '%s\n' "$qdir"
}

move_one() {
  local pid="$1" dst="$2"
  if [[ ! -d "/proc/$pid" ]]; then
    echo "跳过: pid $pid 已消失"
    return 0
  fi
  if write_file "${dst}/cgroup.procs" "$pid"; then
    echo "moved $pid -> $dst"
    return 0
  fi
  echo "move_fail $pid -> $dst" >&2
  return 1
}

move_cpuset() {
  local pid="$1"
  local rel src p
  rel=$(cg_field "$pid" cpuset)
  if [[ -z "$rel" ]]; then
    echo "警告: pid $pid 没有 cpuset 行，直接迁 pid" >&2
    move_one "$pid" "$PIN"
    return
  fi
  src="${CSROOT}${rel}"
  echo "src_cpuset=$src"
  if (( PID_ONLY )) || [[ ! -f "${src}/cgroup.procs" ]]; then
    move_one "$pid" "$PIN"
    return
  fi
  if [[ "$src" == "$PIN" || "$rel" == "/" || "$rel" == "" ]]; then
    echo "src 已是 pin 或 root，只迁 pid $pid"
    move_one "$pid" "$PIN"
    return
  fi
  while read -r p; do
    [[ -n "$p" ]] || continue
    move_one "$p" "$PIN" || true
  done < "${src}/cgroup.procs"
}

move_cpu_quota() {
  local pid="$1" qdir="$2"
  local rel src p
  [[ -n "$qdir" && -f "${qdir}/cgroup.procs" ]] || return 0
  rel=$(cg_field "$pid" cpu)
  [[ -z "$rel" ]] && rel=$(cg_field "$pid" cpu,cpuacct)
  src="${CPUROOT}${rel}"
  echo "src_cpu=$src"
  if (( PID_ONLY )) || [[ ! -f "${src}/cgroup.procs" ]]; then
    move_one "$pid" "$qdir"
    return
  fi
  if [[ "$src" == "$qdir" || "$rel" == "/" || "$rel" == "" ]]; then
    move_one "$pid" "$qdir"
    return
  fi
  while read -r p; do
    [[ -n "$p" ]] || continue
    move_one "$p" "$qdir" || true
  done < "${src}/cgroup.procs"
  if [[ -f /sys/fs/cgroup/cpu/all-rocket-config/one-cpu-config/cgroup.procs ]] \
     && grep -qx "$pid" /sys/fs/cgroup/cpu/all-rocket-config/one-cpu-config/cgroup.procs 2>/dev/null; then
    move_one "$pid" "$qdir" || true
  fi
}

reaff() {
  local want p cur
  want=$(cat "${PIN}/cpuset.cpus" 2>/dev/null || cat /sys/devices/system/cpu/online)
  [[ -n "$want" ]] || return 0
  if (( DRY )); then
    echo "DRY: taskset -acp $want <pids in $PIN>"
    return 0
  fi
  if ! command -v taskset >/dev/null 2>&1; then
    echo "警告: 没有 taskset，跳过 affinity 纠正" >&2
    return 0
  fi
  while read -r p; do
    [[ -n "$p" && -d "/proc/$p" ]] || continue
    cur=$(taskset -cp "$p" 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}')
    if [[ -n "$cur" && "$cur" != "$want" ]]; then
      if taskset -acp "$want" "$p" >/dev/null 2>&1; then
        echo "reaff $p  $cur -> $want"
      else
        echo "reaff_fail $p  cur=$cur want=$want" >&2
      fi
    fi
  done < "${PIN}/cgroup.procs"
}

show_pid() {
  local pid="$1"
  echo "----- pid $pid -----"
  if [[ ! -d "/proc/$pid" ]]; then
    echo "进程已消失"
    return
  fi
  tr '\0' ' ' < "/proc/$pid/cmdline"; echo
  grep -E 'cpuset|:cpu[,:]' "/proc/$pid/cgroup" || true
  taskset -cp "$pid" 2>/dev/null || true
}

once() {
  local pids qdir="" p
  pids=$(resolve_pids "$@")
  if [[ -z "${pids// /}" ]]; then
    echo "错误: 没有可操作的 pid" >&2
    return 1
  fi
  echo "targets:$pids"
  for p in $pids; do
    show_pid "$p"
  done
  ensure_pin
  if [[ -n "$QUOTA_CORES" ]]; then
    qdir=$(ensure_quota "$(echo "$pids" | awk '{print $1}')" "$QUOTA_CORES")
  fi
  for p in $pids; do
    move_cpuset "$p"
    if [[ -n "$qdir" ]]; then
      move_cpu_quota "$p" "$qdir"
    fi
  done
  reaff
  echo "----- after -----"
  for p in $pids; do
    show_pid "$p"
  done
  echo "pin.procs=$(tr '\n' ',' < "${PIN}/cgroup.procs" 2>/dev/null)"
}

if (( LOOP )); then
  echo "循环纠正 interval=${INTERVAL}s  Ctrl-C 停止"
  while true; do
    echo "===== $(date '+%F %T') ====="
    once "$@" || true
    sleep "$INTERVAL"
  done
else
  once "$@"
fi
