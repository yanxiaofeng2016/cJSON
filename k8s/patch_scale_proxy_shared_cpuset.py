#!/usr/bin/env python3
"""DEPRECATED: do not apply the old 15900m Burstable patch.

scale_proxy_pods.sh now uses a kubelet-untouched custom cgroup:
  /sys/fs/cgroup/cpuset/mqs_full_cpuset   (all online CPUs)
  /sys/fs/cgroup/cpu/mqs_quota_<pod>      (CFS quota = cpu_com)

The previous requests=15900m Burstable path lets Hulk bypass kubelet CFS
quota, so usage exceeds cpu_com. Use k8s/scale_proxy_pods.sh instead.
"""
from __future__ import annotations

import sys


def main() -> int:
    print(
        "不要使用本补丁（旧 15900m Burstable 会超 N 核）。\n"
        "请直接使用 k8s/scale_proxy_pods.sh：无 NUMA + cpu_com=N 会把进程迁到\n"
        "/sys/fs/cgroup/cpuset/mqs_full_cpuset（整机 CPU）和\n"
        "/sys/fs/cgroup/cpu/mqs_quota_<pod>（quota=N 核）。",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
