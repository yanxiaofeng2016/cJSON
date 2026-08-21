#!/usr/bin/env python3
"""Patch scale_proxy_pods.sh: share the node cpuset, hard-cap app CPU at cpu_com.

No-NUMA + cpu_com=N becomes:
  - requests.cpu = N*1000-100 m  (Burstable → kubelet will not exclusive-pin)
  - limits.cpu   = N             (CFS quota)
  - HULK_CORE    = N             (Hulk cgroup)
  - start script writes quota + expands cpuset, refreshes 15s
  - app mounts cgroup-cpu so it can write Hulk's one-cpu-config

Usage:
  python3 patch_scale_proxy_shared_cpuset.py /path/to/scale_proxy_pods.sh
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

MARKER = "SHARED_CPUSET_QUOTA_V1"


def must_replace(text: str, old: str, new: str, label: str) -> str:
    if new.strip() and new in text and old not in text:
        print(f"  skip (already applied): {label}")
        return text
    if old not in text:
        raise SystemExit(f"错误: 找不到补丁锚点 [{label}]\n---- 期望片段前 120 字 ----\n{old[:120]}")
    return text.replace(old, new, 1)


OLD_QUOTA_FN = r'''cpu_quota_shell_cmd() {
  local q=$(( $1 * 100000 ))
  # 不要用 & 结尾：后面会接 "; mkdir ..."，bash/sh 里 "&;" 会直接语法错误 → CrashLoop。
  printf 'quota=%s; for f in /sys/fs/cgroup/cpu/cpu.cfs_quota_us /var/sankuai/hulk/one-cpu-config/cpu.cfs_quota_us; do if [ -w "$f" ]; then echo $quota > "$f" || true; fi; done; if [ -w /sys/fs/cgroup/cpu.max ]; then echo "$quota 100000" > /sys/fs/cgroup/cpu.max || true; fi' "$q"
}'''

NEW_QUOTA_FN = r'''cpu_quota_shell_cmd() {
  local q=$(( $1 * 100000 ))
  # 写 CFS quota（k8s + Hulk one-cpu-config），并把 cpuset 扩到 online 全核。
  # 后台再刷 15s，防止 sidecar 随后把 quota 改回 32 核或重新绑核。
  # 本函数以 & 结尾；调用方必须用空格拼接后续命令，禁止 "; mkdir"（&; 会 CrashLoop）。
  printf 'quota=%s; wq() { for f in /sys/fs/cgroup/cpu/cpu.cfs_quota_us /sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us /var/sankuai/hulk/one-cpu-config/cpu.cfs_quota_us; do if [ -w "$f" ]; then echo $quota > "$f" || true; fi; done; if [ -w /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then echo 100000 > /sys/fs/cgroup/cpu/cpu.cfs_period_us || true; fi; if [ -w /sys/fs/cgroup/cpu.max ]; then echo "$quota 100000" > /sys/fs/cgroup/cpu.max || true; fi; }; wcset() { online=`cat /sys/devices/system/cpu/online 2>/dev/null || true`; [ -n "$online" ] || return 0; for f in /sys/fs/cgroup/cpuset/cpuset.cpus /sys/fs/cgroup/cpuset.cpus; do if [ -w "$f" ]; then echo "$online" > "$f" || true; fi; done; mems=`cat /sys/devices/system/node/online 2>/dev/null || true`; [ -n "$mems" ] || return 0; for f in /sys/fs/cgroup/cpuset/cpuset.mems /sys/fs/cgroup/cpuset.mems; do if [ -w "$f" ]; then echo "$mems" > "$f" || true; fi; done; }; wq; wcset; (i=0; while [ $i -lt 15 ]; do sleep 1; wq; wcset; i=$((i+1)); done) &' "$q"
}'''

OLD_PREFIX = '''    prefix="$(cpu_quota_shell_cmd "$CPU_CORES"); ${logs}"'''

NEW_PREFIX = '''    # 配额命令以 & 结尾启动后台刷新；必须用空格拼接，禁止 "; mkdir"（&; 会 CrashLoop）
    prefix="$(cpu_quota_shell_cmd "$CPU_CORES") ${logs}"'''

OLD_CREATE_CPU = '''    inject_hulk_core_into_yaml "$yaml_file" "$CPU_CORES"
    # 无 NUMA 也不再把 requests 降成 15900m（Burstable 可突破）。
    # requests=limits=整数 cpu_com → Guaranteed，kubelet 独占 N 核，严格限流。
  fi'''

NEW_CREATE_CPU = '''    inject_hulk_core_into_yaml "$yaml_file" "$CPU_CORES"
    if [[ -z "$NUMA_SPEC" ]]; then
      # 无 NUMA：requests 略低于 limits → Burstable，避开 static CPU manager 独占绑核，
      # 容器跑在整机共享 cpuset；用量由 limits + HULK_CORE + 启动写 quota 卡在 N 核。
      local cpu_req_milli=$((CPU_CORES * 1000 - 100))
      (( cpu_req_milli < 1 )) && cpu_req_milli=1
      lower_app_cpu_request "$yaml_file" "${cpu_req_milli}m"
      ensure_app_hulk_cpu_cgroup_mount "$yaml_file"
    fi
  fi'''

NEW_MOUNT_FN = r'''
# 无 NUMA 限核：把 hostPath volume cgroup-cpu 挂进 app，启动脚本才能写
# /var/sankuai/hulk/one-cpu-config/cpu.cfs_quota_us。否则 Hulk 把进程迁到自己的
# cgroup 后，只写 kubelet 的 cpu.cfs_quota_us 管不住（docker stats 能到 2000%+）。
# SHARED_CPUSET_QUOTA_V1
ensure_app_hulk_cpu_cgroup_mount() {
  local yaml_file="$1"
  local vol_name="cgroup-cpu"
  local mount_path="/var/sankuai/hulk/one-cpu-config"
  local tmp_file="${yaml_file}.cgcpu.tmp"

  if ! grep -qE "name:[[:space:]]*${vol_name}([[:space:]]|$)" "$yaml_file" 2>/dev/null; then
    return 0
  fi

  awk -v vol="$vol_name" -v mpath="$mount_path" '
    BEGIN {
      in_containers = 0
      cidx = 0
      in_first = 0
      in_vm = 0
      vm_injected = 0
      nbuf = 0
    }
    function flush_vm_entry(   i, is_target) {
      if (nbuf == 0) return
      is_target = 0
      for (i = 1; i <= nbuf; i++) {
        if (buf[i] ~ ("name:[[:space:]]*" vol "([[:space:]]|$)")) is_target = 1
      }
      if (!is_target) {
        for (i = 1; i <= nbuf; i++) print buf[i]
      }
      nbuf = 0
    }
    function inject_mount() {
      if (vm_injected) return
      print "    - mountPath: " mpath
      print "      name: " vol
      vm_injected = 1
    }
    /^  containers:[[:space:]]*$/ { in_containers = 1; print; next }
    in_containers && /^  - / {
      flush_vm_entry()
      if (in_vm && in_first && !vm_injected) inject_mount()
      in_vm = 0
      cidx++
      in_first = (cidx == 1)
      print
      next
    }
    in_containers && /^  [a-zA-Z]/ && !/^  - / {
      flush_vm_entry()
      if (in_vm && in_first && !vm_injected) inject_mount()
      in_containers = 0
      in_first = 0
      in_vm = 0
      print
      next
    }
    in_first && /^    volumeMounts:[[:space:]]*$/ { in_vm = 1; print; next }
    in_first && in_vm && /^    [a-zA-Z]/ && !/^    - / {
      flush_vm_entry()
      if (!vm_injected) inject_mount()
      in_vm = 0
      print
      next
    }
    in_first && in_vm && /^    - mountPath:/ {
      flush_vm_entry()
      buf[++nbuf] = $0
      next
    }
    in_first && in_vm && nbuf > 0 { buf[++nbuf] = $0; next }
    { if (!in_first || !in_vm) print }
    END {
      flush_vm_entry()
      if (in_vm && in_first && !vm_injected) inject_mount()
    }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
}

'''

OLD_LOWER_COMMENT = '''# 无 NUMA 路径：把 app（第一个 container）的 requests.cpu 降为略低于 limits.cpu 的
# 毫核值（cpu_com*1000-100，如 cpu_com=16 → 15900m）。
# 原因：kubelet static CPU manager 对 "Guaranteed QoS Pod + 整数 CPU request" 的容器
# 直接分配独占 cpuset（表现为 taskset -cp 显示进程钉在 N 个连续核，如 36-51），
# 这与 hulk 的 HULK_CPUSET 机制无关，光清除 env/annotation 挡不住。
# requests<limits 后 Pod QoS 变为 Burstable → static policy 不再给独占核，
# 容器共享节点默认 cpuset（整机 CPU 减去其他 Pod 的独占核）；
# CPU 用量仍由 limits.cpu 的 cfs quota 严格限制（不变）。
# 只改第一个 container 的 requests.cpu，不动 limits，也不动 sidecar。
lower_app_cpu_request() {'''

NEW_LOWER_COMMENT = '''# 无 NUMA 路径：把 app（第一个 container）的 requests.cpu 降为略低于 limits.cpu 的
# 毫核值（cpu_com*1000-100，如 cpu_com=16 → 15900m）。
# 原因：kubelet static CPU manager 对 "Guaranteed QoS Pod + 整数 CPU request" 的容器
# 直接分配独占 cpuset（表现为 taskset -cp 显示进程钉在 N 个连续核，如 36-51），
# 这与 hulk 的 HULK_CPUSET 机制无关，光清除 env/annotation 挡不住。
# requests<limits 后 Pod QoS 变为 Burstable → static policy 不再给独占核，
# 容器共享节点默认 cpuset（整机 CPU 减去其他 Pod 的独占核）。
# 用量仍由 limits.cpu + HULK_CORE + 启动脚本写 CFS quota 卡在 N 核；
# 以前超 N 核是因为 HULK_CORE 仍为 32 / sidecar 改回 quota，不是 Burstable 本身。
# 只改第一个 container 的 requests.cpu，不动 limits，也不动 sidecar。
lower_app_cpu_request() {'''

OLD_OVERVIEW = '''    echo "           app requests.cpu=limits.cpu=${CPU_CORES}（整数）→ QoS Guaranteed，"
    echo "           kubelet 独占 ${CPU_CORES} 核，严格不可突破；HULK_CORE=${CPU_CORES}；内存 ${EFFECTIVE_MEM_NONUMA}"'''

NEW_OVERVIEW = '''    echo "           app limits.cpu=${CPU_CORES}，requests.cpu=$((CPU_CORES * 1000 - 100))m → QoS Burstable，"
    echo "           整机共享 cpuset（不独占绑核）；CFS quota + HULK_CORE=${CPU_CORES} 把用量硬限制在 ${CPU_CORES} 核；内存 ${EFFECTIVE_MEM_NONUMA}"'''

OLD_SUMMARY_MODE = '''    echo "  app requests.cpu = limits.cpu = ${CPU_CORES}（整数）→ Pod QoS=Guaranteed"
    echo "  kubelet static CPU manager 独占 ${CPU_CORES} 核，物理上不可突破（不再用 15900m Burstable）"
    echo "  HULK_CORE/HULK_CORE_NUM=${CPU_CORES}；总 Pod CPU request ≈ app + sidecar（如 ${CPU_CORES}+1）"'''

NEW_SUMMARY_MODE = '''    echo "  app limits.cpu = ${CPU_CORES}，requests.cpu = $((CPU_CORES * 1000 - 100))m → Pod QoS=Burstable"
    echo "  kubelet static CPU manager 不独占绑核，容器跑在整机共享 cpuset（taskset 应为 online 全核减去其他独占核）"
    echo "  用量由 CFS quota + HULK_CORE/HULK_CORE_NUM=${CPU_CORES} 硬限制在 ${CPU_CORES} 核（上限 ${CPU_CORES}00%）"
    echo "  总 Pod CPU request ≈ app(毫核) + sidecar（如 $((CPU_CORES * 1000 - 100))m+1）"'''

OLD_VERIFY = '''  echo "  验证: cat /sys/fs/cgroup/cpuset/cpuset.cpus（容器内，应为整机全部 CPU）"
  echo "        cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us / cpu.cfs_period_us（应=cpu_com）"'''

NEW_VERIFY = '''  echo "  验证: cat /sys/fs/cgroup/cpuset/cpuset.cpus（容器内，应为整机 online CPU，而不是连续 ${CPU_CORES:-N} 核）"
  echo "        cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us / cpu.cfs_period_us（应=cpu_com*100000 / 100000）"
  echo "        cat /var/sankuai/hulk/one-cpu-config/cpu.cfs_quota_us（Hulk cgroup，同样应=cpu_com*100000）"'''

OLD_DIAG = '''  echo "  ----- 独占绑核问题诊断（若 taskset 仍显示钉在连续 ${CPU_CORES:-N} 核）-----"
  echo "  # 确认 kubelet cpu manager 策略及独占分配（在节点上，static 策略会记录 pod 的独占核）:"
  echo "  cat /var/lib/kubelet/cpu_manager_state"
  echo "  # 确认 Pod QoS（应为 Guaranteed）:"
  echo "  kubectl --kubeconfig=${KCFG} -n ${NS} get pod <pod> -o jsonpath='{.status.qosClass}'"
  echo "  # 宿主机上看进程亲和性，应为整机所有 CPU（减去其他 Pod 的独占核）:"
  echo "  taskset -cp <pid>"
  echo "  # 容器内确认 quota（应=cpu_com*100000 / 100000）:"
  echo "  cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us /sys/fs/cgroup/cpu/cpu.cfs_period_us"
  echo "  # 确认 hulk 核数（应为 cpu_com，不是模板 32）："
  echo "  printenv HULK_CORE HULK_CORE_NUM"'''

NEW_DIAG = '''  echo "  ----- 整机 cpuset + ${CPU_CORES:-N} 核 quota 验证 -----"
  echo "  # Pod QoS 应为 Burstable（不是 Guaranteed；Guaranteed 会独占绑核）:"
  echo "  kubectl --kubeconfig=${KCFG} -n ${NS} get pod <pod> -o jsonpath='{.status.qosClass}'"
  echo "  # kubelet cpu manager：Burstable Pod 不应出现在 exclusiveCPUSet 里"
  echo "  cat /var/lib/kubelet/cpu_manager_state"
  echo "  # 宿主机上看进程亲和性，应为整机 online CPU（减去其他 Pod 的独占核），不能是连续 ${CPU_CORES:-N} 核:"
  echo "  taskset -cp <pid>"
  echo "  # 容器内 cpuset / quota（quota 应=cpu_com*100000，cpuset 应接近整机）:"
  echo "  cat /sys/fs/cgroup/cpuset/cpuset.cpus"
  echo "  cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us /sys/fs/cgroup/cpu/cpu.cfs_period_us"
  echo "  cat /var/sankuai/hulk/one-cpu-config/cpu.cfs_quota_us"
  echo "  # 确认 hulk 核数（应为 cpu_com，不是模板 32）："
  echo "  printenv HULK_CORE HULK_CORE_NUM"'''

OLD_CPU_BOX = '''    echo "  app resources.requests.cpu = ${CPU_CORES}（与 limits 相同 → Guaranteed，独占 ${CPU_CORES} 核，不可突破）"'''

NEW_CPU_BOX = '''    echo "  app resources.requests.cpu = $((CPU_CORES * 1000 - 100))m（略低于 limits → Burstable，整机共享 cpuset；用量仍卡在 ${CPU_CORES} 核）"'''

OLD_HEADER_REQ = '''#              app 容器 requests.cpu = limits.cpu = N（整数）。不要再用 15900m 把
#              QoS 降成 Burstable：那是「可突破」模式，实际用量会超过 N 核。
#              整数 request+limit → Guaranteed，kubelet static CPU manager 独占分配
#              N 个 CPU，物理上无法突破。
#              内存不做节点绑定，但由 memory cgroup 严格限制 resources.limits.memory=32Gi。'''

NEW_HEADER_REQ = '''#              app 容器 limits.cpu=N，requests.cpu=N*1000-100m（如 16 → 15900m）。
#              QoS=Burstable：kubelet static CPU manager 不独占绑核，容器可在整机
#              cpuset 上调度；用量由 limits + HULK_CORE + 启动写 quota 硬限制为 N 核。
#              以前 15900m 会超 N 核，是因为 HULK_CORE 仍为 32 / sidecar 改回 quota，
#              不是「Burstable 就可突破 limits」。
#              内存不做节点绑定，但由 memory cgroup 严格限制 resources.limits.memory=32Gi。'''

OLD_USAGE_NONUMA = '''                       无 NUMA（整机共享+quota 限制模式）：
                         不绑定 cpuset/内存节点，容器可用整机所有 CPU 和内存；
                         app requests.cpu = limits.cpu = N（整数，如 16），QoS=Guaranteed，
                         kubelet 独占 N 核，严格不可突破；
                         同步 HULK_CORE/HULK_CORE_NUM=N；
                         内存严格限制 32Gi（memory cgroup）；省略 cpu_com 则保持模板原值'''

NEW_USAGE_NONUMA = '''                       无 NUMA（整机共享+quota 限制模式）：
                         不绑定 cpuset/内存节点，容器跑在整机共享 cpuset；
                         app limits.cpu=N，requests.cpu=N*1000-100m（如 16 → 15900m），
                         QoS=Burstable（不独占绑核）；用量硬限制为 N 核（上限 N00%）；
                         同步 HULK_CORE/HULK_CORE_NUM=N，启动脚本写 CFS quota；
                         内存严格限制 32Gi（memory cgroup）；省略 cpu_com 则保持模板原值'''


def patch(text: str) -> str:
    text = must_replace(text, OLD_QUOTA_FN, NEW_QUOTA_FN, "cpu_quota_shell_cmd")
    text = must_replace(text, OLD_PREFIX, NEW_PREFIX, "entrypoint prefix join")
    text = must_replace(text, OLD_CREATE_CPU, NEW_CREATE_CPU, "create_pod cpu_com branch")
    text = must_replace(text, OLD_LOWER_COMMENT, NEW_LOWER_COMMENT, "lower_app_cpu_request comment")
    if MARKER not in text:
        needle = "inject_java_tool_options() {"
        if needle not in text:
            raise SystemExit("错误: 找不到 inject_java_tool_options，无法插入 ensure_app_hulk_cpu_cgroup_mount")
        text = text.replace(needle, NEW_MOUNT_FN + needle, 1)
        print("  insert: ensure_app_hulk_cpu_cgroup_mount")
    else:
        print("  skip (already applied): ensure_app_hulk_cpu_cgroup_mount")
    text = must_replace(text, OLD_OVERVIEW, NEW_OVERVIEW, "overview echo")
    text = must_replace(text, OLD_SUMMARY_MODE, NEW_SUMMARY_MODE, "summary mode echo")
    text = must_replace(text, OLD_VERIFY, NEW_VERIFY, "verify echo")
    text = must_replace(text, OLD_DIAG, NEW_DIAG, "diagnostic echo")
    text = must_replace(text, OLD_CPU_BOX, NEW_CPU_BOX, "cpu config box echo")
    text = must_replace(text, OLD_HEADER_REQ, NEW_HEADER_REQ, "header cpu_com comment")
    text = must_replace(text, OLD_USAGE_NONUMA, NEW_USAGE_NONUMA, "usage() cpu_com text")
    return text


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"错误: 找不到文件 {path}", file=sys.stderr)
        return 1
    original = path.read_text(encoding="utf-8")
    updated = patch(original)
    if updated == original:
        print(f"无需修改: {path}")
        return 0
    bak = path.with_suffix(path.suffix + ".bak-shared-cpuset")
    shutil.copy2(path, bak)
    path.write_text(updated, encoding="utf-8")
    print(f"已备份: {bak}")
    print(f"已更新: {path}")
    print("无 NUMA + cpu_com=N 现在会：共享整机 cpuset，用量硬限制 N 核。")
    print("请用 del 重建 Pod 后验证 qosClass=Burstable 且 taskset 为整机 CPU。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
