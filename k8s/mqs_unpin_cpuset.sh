#!/bin/bash
# 在宿主机上把指定进程从 kubelet 独占 cpuset 迁到整机 cpuset，并拉宽 affinity。
#
# 用法（root）:
#   ./mqs_unpin_cpuset.sh <pid>
#   ./mqs_unpin_cpuset.sh 85559
#   ./mqs_unpin_cpuset.sh -q 16 85559          # 同时卡 CPU quota=16 核
#   ./mqs_unpin_cpuset.sh -m 85559             # 解开 NUMA 内存绑定并打散已有页面
#   ./mqs_unpin_cpuset.sh -q 16 -m 85559
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
#   5) 可选 -m：cpuset.mems 放宽只允许“以后”分配到所有 node。JVM AlwaysPreTouch
#      已经把堆摸在出生 node 上，且 mempolicy=BIND 会继续钉新分配。
#      所以 -m 会 gdb 把所有线程 set_mempolicy(MPOL_DEFAULT)，再用 move_pages
#      把匿名页按 node 数交错搬走。pids/memory cgroup 仍不改。

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
UNBIND_MEM=0
POLICY_ONLY=0

usage() {
  cat <<EOF
用法: $0 [-q N] [-m] [--policy-only] [-l] [-i 秒] [-p] [-n] <pid|关键字> [pid...]

  -q N           同时把进程迁到 ${CPUROOT}/mqs_quota_<pid>，CFS quota=N 核
  -m             解开 NUMA 内存：重置 mempolicy + 把已有匿名页交错迁到所有 node
                 （18G 堆可能要几十秒，且会短暂停一下 Java；只改 CPU 时不要加）
  --policy-only  只重置 mempolicy，不 migrate 已有页面（新分配会散，旧堆仍在原 node）
  -l             循环纠正 CPU affinity（默认每 2 秒）。内存迁移不会在循环里重复做
  -i 秒          循环间隔（默认 2）
  -p             只迁指定 pid，不迁它所在 cpuset cgroup 里的其它进程
  -n             dry-run，只打印

例:
  $0 85559
  $0 -q 16 -l 85559
  $0 -m 15451              # 1342/1343 内存还钉在单 node 时用
  $0 -q 16 -m 15451
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -q|--quota) QUOTA_CORES="$2"; shift 2 ;;
    -l|--loop) LOOP=1; shift ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -p|--pid-only) PID_ONLY=1; shift ;;
    -m|--memory|--unbind-mem) UNBIND_MEM=1; shift ;;
    --policy-only) POLICY_ONLY=1; UNBIND_MEM=1; shift ;;
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
  grep -E '^Mems_allowed(_list)?:' "/proc/$pid/status" 2>/dev/null || true
  if [[ -r "/proc/$pid/numa_maps" ]]; then
    echo -n "numa_policy: "
    awk '
      /bind:/ { b=1; print "BIND" }
      /interleave:/ { i=1; print "INTERLEAVE" }
      /prefer:/ { p=1; print "PREFER" }
      END { if (!b && !i && !p) print "DEFAULT/first-touch(看 numastat)" }
    ' "/proc/$pid/numa_maps" | sort -u | tr '\n' ' '
    echo
  fi
}

expand_nodelist() {
  local spec="$1" item a b
  local out=()
  spec=${spec// /}
  IFS=',' read -ra items <<< "$spec"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    if [[ "$item" == *-* ]]; then
      a=${item%-*}
      b=${item#*-}
      local i
      for ((i=a; i<=b; i++)); do
        out+=("$i")
      done
    else
      out+=("$item")
    fi
  done
  (IFS=,; echo "${out[*]}")
}

show_numastat() {
  local pid="$1"
  if command -v numastat >/dev/null 2>&1; then
    numastat -p "$pid" 2>/dev/null | sed -n '1,40p'
  else
    echo "(没有 numastat，看 /proc/$pid/numa_maps 的 N0= N1= ...)"
    awk '{
      for (i=1;i<=NF;i++) if ($i ~ /^N[0-9]+=/) printf "%s ", $i
    } END { print "" }' "/proc/$pid/numa_maps" 2>/dev/null | head
  fi
}

reset_mempolicy() {
  local pid="$1"
  local nr=238
  case "$(uname -m)" in
    aarch64|arm64) nr=237 ;;
  esac
  if (( DRY )); then
    echo "DRY: gdb -p $pid thread apply all syscall($nr, MPOL_DEFAULT)"
    return 0
  fi
  if ! command -v gdb >/dev/null 2>&1; then
    echo "警告: 没有 gdb。mempolicy=BIND 时新分配仍会钉在原 node，请装 gdb 后重跑 -m" >&2
    return 1
  fi
  echo "重置 mempolicy (MPOL_DEFAULT) pid=$pid  会短暂 ptrace 停住所有 Java 线程"
  gdb -p "$pid" -batch \
    -ex "thread apply all call (long)syscall($nr, 0, 0, 0)" \
    -ex detach -ex quit \
    >"/tmp/mqs-gdb-mempolicy.${pid}.log" 2>&1 || true
  if grep -q "Cannot access memory" "/tmp/mqs-gdb-mempolicy.${pid}.log" 2>/dev/null; then
    echo "警告: gdb 未能 call syscall，详见 /tmp/mqs-gdb-mempolicy.${pid}.log" >&2
    return 1
  fi
  echo "mempolicy gdb: /tmp/mqs-gdb-mempolicy.${pid}.log"
}

interleave_anon_pages() {
  local pid="$1"
  local nodes
  nodes=$(expand_nodelist "$(cat "${PIN}/cpuset.mems" 2>/dev/null || echo 0)")
  if [[ -z "$nodes" ]]; then
    echo "警告: 无法解析 cpuset.mems，跳过页面迁移" >&2
    return 1
  fi
  if (( DRY )); then
    echo "DRY: python3 move_pages interleave pid=$pid nodes=$nodes"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "警告: 没有 python3，无法交错迁移已有页面。可先 --policy-only，或装 python3 后重跑 -m" >&2
    return 1
  fi
  echo "交错迁移匿名页 pid=$pid nodes=$nodes （堆越大越慢，期间 RSS 会在 node 间搬家）"
  python3 - "$pid" "$nodes" <<'PY'
import ctypes, os, sys

pid = int(sys.argv[1])
nodes = [int(x) for x in sys.argv[2].split(",") if x != ""]
if not nodes:
    sys.exit("no nodes")

machine = os.uname().machine
nr = {"x86_64": 279, "aarch64": 239, "arm64": 239}.get(machine)
if nr is None:
    sys.exit("unsupported arch %s" % machine)

libc = ctypes.CDLL(None, use_errno=True)
syscall = libc.syscall
syscall.restype = ctypes.c_long

page = os.sysconf("SC_PAGESIZE")
MPOL_MF_MOVE = 2
batch = 2048
void_p = ctypes.c_void_p
int_t = ctypes.c_int

def vmas(pid):
    out = []
    with open("/proc/%d/maps" % pid) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 5:
                continue
            rng, perms, inode = parts[0], parts[1], parts[4]
            if "r" not in perms or "w" not in perms:
                continue
            if inode != "0":
                continue
            a, b = rng.split("-")
            start, end = int(a, 16), int(b, 16)
            if end <= start:
                continue
            out.append((start, end))
    return out

moved = failed = skipped = 0
idx = 0
try:
    maps = vmas(pid)
except OSError as e:
    sys.exit("read maps: %s" % e)

total = sum((e - s) // page for s, e in maps)
print("anon_pages~%d (%.1f MiB)" % (total, total * page / 1024.0 / 1024.0))

pages = (void_p * batch)()
dest = (int_t * batch)()
status = (int_t * batch)()

ncount = 0
for start, end in maps:
    addr = start
    while addr < end:
        n = 0
        while addr < end and n < batch:
            pages[n] = addr
            dest[n] = nodes[(idx + n) % len(nodes)]
            status[n] = 0
            n += 1
            addr += page
        rc = syscall(nr, ctypes.c_int(pid), ctypes.c_ulong(n), pages, dest, status, ctypes.c_int(MPOL_MF_MOVE))
        if rc != 0:
            err = ctypes.get_errno()
            skipped += n
        else:
            for i in range(n):
                st = status[i]
                if st == 0:
                    moved += 1
                else:
                    failed += 1
        idx += n
        ncount += n
        if ncount % (batch * 32) == 0:
            print("progress %d/%d moved=%d fail=%d" % (ncount, total, moved, failed))
            sys.stdout.flush()

print("move_pages done moved=%d fail=%d syscall_skip=%d" % (moved, failed, skipped))
PY
}

unbind_memory() {
  local pid="$1"
  echo "===== 解开 NUMA 内存 pid=$pid ====="
  echo "----- before -----"
  grep -E 'Mems_allowed_list' "/proc/$pid/status" 2>/dev/null || true
  show_numastat "$pid"
  write_file "${PIN}/cpuset.memory_migrate" 1 || true
  reset_mempolicy "$pid" || true
  if (( POLICY_ONLY )); then
    echo "只改了 mempolicy，已有页面不迁。新分配会跟 CPU 所在 node 走。"
  else
    interleave_anon_pages "$pid" || true
  fi
  echo "----- after -----"
  grep -E 'Mems_allowed_list' "/proc/$pid/status" 2>/dev/null || true
  show_numastat "$pid"
  echo "可再跑: numastat -p $pid"
}

ONCE_DID_MEM=0

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
  if (( UNBIND_MEM )) && (( ONCE_DID_MEM == 0 )); then
    for p in $pids; do
      unbind_memory "$p"
    done
    ONCE_DID_MEM=1
  fi
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
