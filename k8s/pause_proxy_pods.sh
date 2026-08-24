#!/bin/bash
# 冻结 / 解冻 proxy 容器进程（不删除 Pod）。
# k8s 没有 Pause 状态，这里对容器做 docker/crictl pause（cgroup freezer）。
#
# 用法（在能访问 kube.cfg 的节点上，一般是 1341）:
#   ./pause_proxy_pods.sh pause
#   ./pause_proxy_pods.sh unpause
#   ./pause_proxy_pods.sh pause --pod_namespace sankuai-test-its-haiguang
#
# 本机容器直接 pause；其它 node 通过 ssh root@<nodeName> 执行。

set -euo pipefail

NS="${NAMESPACE:-sankuai-test-its-haiguang}"
KCFG="${KUBECONFIG_FILE:-./kube.cfg}"
LABEL_SELECTOR="${LABEL_SELECTOR:-mqs-component=proxy}"
ACTION=""
SSH_USER="${PAUSE_SSH_USER:-root}"

usage() {
  cat <<EOF
用法: $0 pause|unpause [--pod_namespace <NS>]

  pause     冻结匹配 Pod 的所有容器（进程停，Pod 不删，kubectl 仍显示 Running）
  unpause   解冻

例:
  $0 pause
  $0 unpause
  $0 pause --pod_namespace sankuai-test-its-haiguang
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    pause|unpause) ACTION="$1"; shift ;;
    --pod_namespace|--pod-namespace|--namespace)
      [[ $# -ge 2 ]] || usage
      NS="$2"
      shift 2
      ;;
    pod_namespace=*|namespace=*) NS="${1#*=}"; shift ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

[[ "$ACTION" == "pause" || "$ACTION" == "unpause" ]] || usage
[[ -f "$KCFG" ]] || { echo "错误: 找不到 kubeconfig: $KCFG"; exit 1; }

kubectl_n() {
  kubectl --kubeconfig="$KCFG" -n "$NS" "$@"
}

short_cid() {
  local raw="$1"
  raw="${raw#*://}"
  raw="${raw%%[$'\r\n']*}"
  echo "${raw:0:64}"
}

local_pause() {
  local cid="$1"
  if command -v docker >/dev/null 2>&1 && docker inspect "$cid" >/dev/null 2>&1; then
    docker "$ACTION" "$cid"
    echo "  docker $ACTION $cid -> $(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo '?')"
    return 0
  fi
  if command -v crictl >/dev/null 2>&1; then
    crictl "$ACTION" "$cid"
    echo "  crictl $ACTION $cid"
    return 0
  fi
  echo "  本机找不到 docker/crictl 容器 $cid" >&2
  return 1
}

remote_pause() {
  local node="$1" cid="$2"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "${SSH_USER}@${node}" "bash -s" <<EOF
set -e
cid='$cid'
if command -v docker >/dev/null 2>&1 && docker inspect "\$cid" >/dev/null 2>&1; then
  docker $ACTION "\$cid"
  echo "  docker $ACTION \$cid @ $node -> \$(docker inspect -f '{{.State.Status}}' "\$cid" 2>/dev/null || echo '?')"
  exit 0
fi
if command -v crictl >/dev/null 2>&1; then
  crictl $ACTION "\$cid"
  echo "  crictl $ACTION \$cid @ $node"
  exit 0
fi
echo "  $node 上找不到 docker/crictl 或容器 \$cid" >&2
exit 1
EOF
}

this_host=$(hostname -f 2>/dev/null || hostname)
this_short=$(hostname -s 2>/dev/null || hostname)

echo "===== $ACTION  namespace=$NS  selector=$LABEL_SELECTOR ====="
mapfile -t LINES < <(kubectl_n get pod -l "$LABEL_SELECTOR" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)

if (( ${#LINES[@]} == 0 )); then
  echo "没有 Running 的 proxy Pod"
  exit 0
fi

for line in "${LINES[@]}"; do
  [[ -n "$line" ]] || continue
  pod="${line%%$'\t'*}"
  node="${line#*$'\t'}"
  echo "--- $pod  @ $node ---"
  while read -r cname cidraw; do
    [[ -n "$cname" && -n "$cidraw" ]] || continue
    cid=$(short_cid "$cidraw")
    echo "  container $cname $cid"
    if [[ "$node" == "$this_host" || "$node" == "$(hostname)" || "$node" == "$this_short" ]]; then
      local_pause "$cid" || true
    else
      if ! remote_pause "$node" "$cid"; then
        echo "  ssh 失败时请到 $node 上执行:"
        echo "    docker $ACTION $cid    # 或 crictl $ACTION $cid"
      fi
    fi
  done < <(kubectl_n get pod "$pod" -o jsonpath='{range .status.containerStatuses[*]}{.name}{" "}{.containerID}{"\n"}{end}')
done

echo ""
echo "kubectl 仍会显示 Running，这是正常的。"
echo "恢复: $0 unpause --pod_namespace $NS"
