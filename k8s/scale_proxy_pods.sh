#!/bin/bash
# 按 Pod 数 + Node 列表 + NUMA 列表创建 proxy Pod
#
# 用法:
#   ./scale_proxy_pods.sh [del|plus] <数量> <node列表> [numa列表] [cpu_com=<N>] [event_loop=<N>] [java_path=<PATH>] [--update-jvm] [--app_version <VER>] [--mem <值>]
#
# 模式说明:
#   <数量> <node列表>           增量模式：当前 Pod 数 < 数量 时才补足到目标数
#   del  <数量> <node列表>      删重建：删除指定 node 列表上的 proxy Pod，再重建
#   plus <数量> <node列表>      追加模式：在现有 Pod 基础上再额外新增指定数量
#
# cpu_com 参数（可选，放任意位置）:
#   cpu_com=16     仅改 app（第一个 container）的 resources.limits/requests.cpu=16
#   cpu_com=8      同上，设为 8 核（不指定则保持模板原值）
#                  不动 hulk-sidecar / hulk-init 的 CPU（模板默认通常为 1 或 100m）。
#                  总 Pod CPU request ≈ app + sidecar（如 16+1=17），Guaranteed 准入按总和计。
#   无 NUMA 时（自定义 cgroup：整机 cpuset + N 核 quota）：
#              不注入 HULK_CPUSET/HULK_NUMA_NODE。app requests.cpu=limits.cpu=N（整数）。
#              不要再用 15900m Burstable：kubelet 的 CFS quota 会被 Hulk 绕开，实际会超 N 核。
#              做法（cgroup v1，各控制器独立，内存/pids 仍留在 kubelet 的 cgroup）：
#              1) hostPath 挂载宿主机 /sys/fs/cgroup -> /host-cgroup
#              2) 在 kubelet 不会管的树上建自定义 cgroup（与 kubepods 同级，不是容器 cgroup 的子目录，
#                 否则 parent 已被独占绑核，子 cgroup 无法扩成 0-255）：
#                   mkdir /host-cgroup/cpuset/mqs_full_cpuset
#                   echo "<online>" > cpuset.cpus
#                   echo "<node online>" > cpuset.mems
#                   mkdir /host-cgroup/cpu/mqs_quota_<pod>
#                   echo N*100000 > cpu.cfs_quota_us
#              3) 把 kubelet 容器 cgroup 里的 host PID 迁到上述自定义 cgroup
#                 （echo $pid > cgroup.procs）；后台循环防止 kubelet/Hulk 把进程迁回去
#              4) 同步 HULK_CORE/HULK_CORE_NUM=N
#              5) JAVA_TOOL_OPTIONS=-XX:ActiveProcessorCount=N（无 event_loop 时）
#              内存不做节点绑定，由 memory cgroup 限制 resources.limits.memory=32Gi。
#   有 NUMA 时：省略 cpu_com → 自动设为整 NUMA 核数（从本机 OS 实时读取，
#              SMT on 时常为 32，SMT off 时常为 16；勿写死）
#              cpu_com=N（1<=N<=NUMA核数）→ 取该 NUMA OS cpuset 的前 N 个 CPU 作为子集
#              app: requests.cpu = limits.cpu = N（整数，Guaranteed 的 CPU 部分）
#              例 SMT off: cpu_com=16 numa1 → HULK_CPUSET=16-31（整 NUMA，16 核）
#              例 SMT on:  cpu_com=16 numa1 → HULK_CPUSET=16-31（从 16-31,144-159 取前 16）
#              例: cpu_com=8 numa0  → HULK_CPUSET=0-7（从该 NUMA 完整 cpuset 取前 8）
#              例: cpu_com=整 NUMA 核数 → 整 NUMA cpuset 不变
#
# event_loop 参数（可选，放任意位置）:
#   event_loop=8   注入 JAVA_TOOL_OPTIONS，限制 gRPC Netty EventLoop 为 8（含 ActiveProcessorCount=8）
#                  可与 cpu_com=16 组合：16 核 cgroup + 8 个 grpc-nio-worker
#
# java_path 参数（可选，放任意位置；也可写 java_home=）:
#   java_path=/home/test/HPEJDK_1.0.0_linux_x64
#   java_path=/home/test/HPEJDK_1.0.0_linux_x64/          # 尾斜杠可接受
#   java_path=/home/test/HPEJDK_1.0.0_linux_x64/bin
#   java_path=/home/test/HPEJDK_1.0.0_linux_x64/bin/java
#                  将宿主机 JDK 通过 hostPath 挂到 app 容器：
#                    1) /opt/custom-jdk          （JAVA_HOME 清晰挂载点）
#                    2) /usr/local/mjdk-8.0.0-312（覆盖镜像 MJDK；mqs 脚本硬编码此路径）
#                  设置 JAVA_HOME=/opt/custom-jdk，PATH 前置 /opt/custom-jdk/bin，
#                  并用 sh -c 包装 entrypoint，强制 JAVA_HOME/PATH 后 exec mqs。
#                  仅设 PATH/JAVA_HOME 不够：mqs 启动脚本硬编码 mjdk 路径，不走 PATH。
#
# update_jvm / --update-jvm（可选，放任意位置）:
#   --update-jvm | update_jvm=1 | update_jvm=true
#                  32G 高吞吐推荐 JVM 参数（通过 /tmp/jdk-wrap 包装 java，插到主类名之前，
#                  覆盖 mqs setup_jre_option 硬编码的 PROXY GC/堆参数；勿改镜像内 mqs）。
#                  注入 flags:
#                    -XX:InitialRAMPercentage=75.0 -XX:MaxRAMPercentage=75.0
#                    -XX:ParallelGCThreads=20 -XX:ConcGCThreads=5 -XX:MaxGCPauseMillis=50
#                    -XX:+UseNUMA
#                    -Xlog:gc*=info:file=/opt/logs/mqs/gc.log:time,uptime,level,tags:filecount=5,filesize=50M
#                  可选（未默认注入）: -XX:MaxDirectMemorySize=2g
#                  可与 java_path 联用：REAL_JAVA=/opt/custom-jdk；否则 REAL_JAVA=/usr/local/mjdk-8.0.0-312
#
# app_version / --app_version（可选，放任意位置）:
#   --app_version 1.8 | app_version=1.8
#                  （也接受拼写别名 --app_verison / app_verison=）
#                  切换 app（第一个 container）镜像；不动 hulk-sidecar / init。
#                  1.8 → docker.io/system_test/com.sankuai.mqs:stable_amd64_1785306832245
#                  1.6 或省略 → 保持模板默认镜像
#
# mem / --mem（可选，放任意位置）:
#   --mem 16G | --mem 16Gi | mem=16G | mem=16Gi
#                  覆盖 app（第一个 container）的 resources.limits.memory 与
#                  resources.requests.memory（两者同值），与 cpu_com/NUMA/镜像等
#                  其它设置完全独立，互不影响。只改 app 容器，不动 hulk-sidecar / hulk-init。
#                  接受常见 k8s 内存单位 Gi/G/Mi/M（也支持 Ki/K/Ti/T）；裸 G/M/K/T
#                  （不带 i 后缀）按用户口语习惯映射为 Gi/Mi/Ki/Ti（如 "16C16G" 中的
#                  16G 等价 16Gi，而非 SI 十进制 GB），已带 xi 后缀或纯数字（字节）原样透传。
#                  省略 --mem 时行为与改动前完全一致：
#                    无 NUMA（整机共享+quota 模式）→ 仍强制 32Gi（NONUMA_MEM_LIMIT）
#                    有 NUMA → 仍不改写内存，沿用模板 prox-pod-extra-1341.yaml 默认值
#                  NUMA / 非 NUMA 模式均可用；del/plus/add 三种模式都经 create_pod
#                  逐 Pod 生效，无需分别适配。
#
# 示例:
#   ./scale_proxy_pods.sh 6 1341-1343                       # 增量到 6 个
#   ./scale_proxy_pods.sh del 6 1341-1343                   # 仅删 1341-1343 上 proxy，再重建 6 个
#   ./scale_proxy_pods.sh plus 6 1341-1343                  # 在现有基础上追加 6 个
#   ./scale_proxy_pods.sh del 9 1341-1343 numa0-numa2       # NUMA 绑定，cpu_com 自动=整 NUMA（live）
#   ./scale_proxy_pods.sh del 9 1341-1343 numa0-numa2 cpu_com=16  # SMT off 时 = 整 NUMA；先填各 node 同 NUMA
#   ./scale_proxy_pods.sh del 3 1341-1343 java_home=/home/test/HPEJDK_1.0.0_linux_x64 cpu_com=16 numa1
#                                                          # numa1：SMT off → 16-31；SMT on → 子集 16-31
#   ./scale_proxy_pods.sh del 6 1341-1343 cpu_com=16        # 无 NUMA，每个 16 核
#   ./scale_proxy_pods.sh plus 3 1341-1343 cpu_com=8        # 追加 3 个 8 核容器
#   ./scale_proxy_pods.sh del 6 1341-1343 cpu_com=16 event_loop=8  # 16 核 Pod，EventLoop 限 8
#   ./scale_proxy_pods.sh del 3 1341-1343 java_path=/home/test/HPEJDK_1.0.0_linux_x64/
#   ./scale_proxy_pods.sh del 3 1341-1343 --update-jvm
#   ./scale_proxy_pods.sh del 3 1341-1343 java_path=/home/test/HPEJDK... --update-jvm cpu_com=16 numa1
#   ./scale_proxy_pods.sh del 3 1341-1343 cpu_com=16 --app_version 1.8
#   ./scale_proxy_pods.sh plus 3 1341-1343 numa1 cpu_com=16 --app_version 1.8
#   ./scale_proxy_pods.sh del 3 1341-1343                   # 默认 1.6 / 模板镜像
#   ./scale_proxy_pods.sh del 3 1341-1343 cpu_com=16 --mem 16G   # 16C16G
#   ./scale_proxy_pods.sh plus 3 1341-1343 numa1 cpu_com=16 --mem 16G  # NUMA 绑核 + 16G 内存
#
# 删除相关环境变量（可选）:
#   DELETE_WAIT_TIMEOUT=20    等待 Pod 终止秒数（默认 20）
#   DELETE_GRACE_PERIOD=30    优雅退出宽限期（默认 30）
#   DELETE_FORCE=true         超时后强制删除（默认 true）
#
# 依赖: kube.cfg、模板 prox-pod-extra-1341.yaml

set -euo pipefail

# ---------------------------------------------------------------------------
# 全局默认
# ---------------------------------------------------------------------------
NS="${NAMESPACE:-sankuai-test-its-haiguang}"
KCFG="${KUBECONFIG_FILE:-./kube.cfg}"
TEMPLATE="${TEMPLATE_YAML:-prox-pod-extra-1341.yaml}"
LABEL_SELECTOR="${LABEL_SELECTOR:-mqs-component=proxy}"
NODE_NAME_PREFIX="${NODE_NAME_PREFIX:-hldy-hulk-k8s-ep-test}"
NODE_NAME_SUFFIX="${NODE_NAME_SUFFIX:-.mt}"
NUMA_ENV_NAME="${NUMA_ENV_NAME:-HULK_NUMA_NODE}"
NUMA_ANNOTATION_KEY="${NUMA_ANNOTATION_KEY:-hulk.alpha.kubernetes.io/numa-node}"
NUMA_CPUSET_ENV_NAME="${NUMA_CPUSET_ENV_NAME:-HULK_CPUSET}"
NUMA_CPUSET_ANNOTATION_KEY="${NUMA_CPUSET_ANNOTATION_KEY:-hulk.alpha.kubernetes.io/cpuset-cpus}"
# 无 NUMA（整机共享+quota 限制模式）时，app 容器内存硬上限（memory cgroup 强制）
NONUMA_MEM_LIMIT="${NONUMA_MEM_LIMIT:-32Gi}"
# app_version=1.8 时覆盖 app（第一个 container）镜像；1.6/省略保持模板
APP_IMAGE_V18="docker.io/system_test/com.sankuai.mqs:stable_amd64_1785306832245"

# 规范化 --mem / mem= 的内存取值为合法 k8s Quantity。
# 用户口语 "16C16G" 中的 16G 指的是 16Gi（二进制吉字节），而非 SI 十进制 G，
# 因此裸 G/M/K/T（不带 i 后缀）一律映射为对应的 xi 单位；已带 Ki/Mi/Gi/Ti 后缀
# 或纯数字（字节）原样透传。非法格式直接报错退出，不做静默兜底。
# 提前定义在此处（而非工具函数区）是因为下方参数校验阶段就要调用它。
normalize_mem_value() {
  local input="$1"
  local num unit norm_unit

  if [[ ! "$input" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
    echo "错误: --mem 格式无效: ${input}（期望形如 16G / 16Gi / 16384M / 16384Mi）" >&2
    return 1
  fi
  num="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"

  case "$unit" in
    ""|Ki|Mi|Gi|Ti) norm_unit="$unit" ;;
    G|g) norm_unit="Gi" ;;   # 口语化 16G -> 16Gi（如 "16C16G"），非 SI 十进制
    M|m) norm_unit="Mi" ;;
    K|k) norm_unit="Ki" ;;
    T|t) norm_unit="Ti" ;;
    *)
      echo "错误: --mem 单位无效: ${unit}（支持 Gi/Mi/Ki/Ti，或裸 G/M/K/T 同义映射为对应 xi）" >&2
      return 1
      ;;
  esac

  echo "${num}${norm_unit}"
}

# ---------------------------------------------------------------------------
# 参数解析：先提取 cpu_com=N / event_loop=N / java_path=... / update_jvm / app_version / mem（可在任意位置），再解析剩余位置参数
# ---------------------------------------------------------------------------
CPU_CORES=""
EVENT_LOOPS=""
JAVA_PATH=""
UPDATE_JVM=0
APP_VERSION=""
APP_MEM=""
# 32G 高吞吐推荐 flags（由 /tmp/jdk-wrap/bin/java 插入主类名之前，覆盖 mqs 硬编码）
# 可选未注入: -XX:MaxDirectMemorySize=2g
UPDATE_JVM_FLAGS='-XX:InitialRAMPercentage=75.0 -XX:MaxRAMPercentage=75.0 -XX:ParallelGCThreads=20 -XX:ConcGCThreads=5 -XX:MaxGCPauseMillis=50 -XX:+UseNUMA -Xlog:gc*=info:file=/opt/logs/mqs/gc.log:time,uptime,level,tags:filecount=5,filesize=50M'
DEFAULT_MJDK_HOME="${MQS_JDK_OVERLAY_PATH:-/usr/local/mjdk-8.0.0-312}"
ARGS=()
expect_app_version=0
expect_mem=0
for arg in "$@"; do
  if (( expect_app_version )); then
    APP_VERSION="${arg//$'\r'/}"
    expect_app_version=0
    continue
  fi
  if (( expect_mem )); then
    APP_MEM="${arg//$'\r'/}"
    expect_mem=0
    continue
  fi
  if [[ "$arg" =~ ^cpu_com=([0-9]+)$ ]]; then
    CPU_CORES="${BASH_REMATCH[1]}"
  elif [[ "$arg" =~ ^event_loop=([0-9]+)$ ]]; then
    EVENT_LOOPS="${BASH_REMATCH[1]}"
  elif [[ "$arg" =~ ^(java_path|java_home)=(.*)$ ]]; then
    JAVA_PATH="${BASH_REMATCH[2]}"
  elif [[ "$arg" == "--update-jvm" ]]; then
    UPDATE_JVM=1
  elif [[ "$arg" =~ ^update_jvm=(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      1|true|TRUE|True|yes|YES|Yes|on|ON|On) UPDATE_JVM=1 ;;
      0|false|FALSE|False|no|NO|No|off|OFF|Off) UPDATE_JVM=0 ;;
      *) echo "错误: update_jvm 无效值: ${BASH_REMATCH[1]}（期望 1/true 或 0/false）"; exit 1 ;;
    esac
  elif [[ "$arg" == "--app_version" || "$arg" == "--app_verison" ]]; then
    expect_app_version=1
  elif [[ "$arg" =~ ^(app_version|app_verison)=(.*)$ ]]; then
    APP_VERSION="${BASH_REMATCH[2]//$'\r'/}"
  elif [[ "$arg" == "--mem" ]]; then
    expect_mem=1
  elif [[ "$arg" =~ ^mem=(.*)$ ]]; then
    APP_MEM="${BASH_REMATCH[1]//$'\r'/}"
  else
    ARGS+=("$arg")
  fi
done
if (( expect_app_version )); then
  echo "错误: --app_version 需要版本参数（目前支持 1.6 或 1.8）"
  exit 1
fi
if (( expect_mem )); then
  echo "错误: --mem 需要内存参数（如 16G 或 16Gi）"
  exit 1
fi
# 去掉意外空白，避免 "1.8 " 导致后续 == "1.8" 比较失败、inject 被跳过
APP_VERSION="${APP_VERSION//[[:space:]]/}"
APP_MEM="${APP_MEM//[[:space:]]/}"

# 解析模式：del | plus | 默认(add)
MODE="add"
COUNT=""
NODE_SPEC=""
NUMA_SPEC=""

case "${ARGS[0]:-}" in
  del)
    MODE="del"
    COUNT="${ARGS[1]:-}"
    NODE_SPEC="${ARGS[2]:-}"
    NUMA_SPEC="${ARGS[3]:-}"
    ;;
  plus)
    MODE="plus"
    COUNT="${ARGS[1]:-}"
    NODE_SPEC="${ARGS[2]:-}"
    NUMA_SPEC="${ARGS[3]:-}"
    ;;
  *)
    MODE="add"
    COUNT="${ARGS[0]:-}"
    NODE_SPEC="${ARGS[1]:-}"
    NUMA_SPEC="${ARGS[2]:-}"
    ;;
esac

# ---------------------------------------------------------------------------
# 用法函数
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
用法: scale_proxy_pods.sh [del|plus] <数量> <node列表> [numa列表] [cpu_com=<N>] [event_loop=<N>] [java_path=<PATH>] [--update-jvm] [--app_version <VER>] [--mem <值>]

模式:
  <数量>               增量模式：补足到目标总数（当前 < 目标才创建）
  del  <数量>          删重建：删除指定 node 列表上的 proxy Pod，再重建 <数量> 个
  plus <数量>          追加：在现有 Pod 基础上额外增加 <数量> 个

可选参数（任意位置）:
  cpu_com=<N>          仅设置 app（第一个 container）的 CPU 核数；sidecar/init 保持模板原值
                       总 Pod CPU request ≈ app + sidecar（如 16+1=17），Guaranteed 按总和计
                       无 NUMA（自定义 cgroup：整机 cpuset + N 核 quota）：
                         不绑 HULK_CPUSET；app requests=limits=N（整数，Guaranteed）；
                         启动时在 /sys/fs/cgroup/cpuset/mqs_full_cpuset 建 kubelet 不管的
                         cpuset（online 全核），把进程从 kubepods 迁过去；
                         另建 cpu/mqs_quota_<pod>，CFS quota=N，用量上限 N00%；
                         不要用 15900m Burstable（Hulk 会绕开 k8s limit 超 N 核）；
                         内存严格限制 32Gi；省略 cpu_com 则保持模板原值
                       有 NUMA：省略则自动设为整 NUMA 核数（本机 OS 实时拓扑；
                         SMT on 常 32，SMT off 常 16）
                       cpu_com=N（1<=N<=NUMA核数）→ 取该 NUMA cpuset 前 N 个 CPU；
                         app requests.cpu=limits.cpu=N（sidecar CPU 不动）
                       例 SMT off: cpu_com=16 numa1 → HULK_CPUSET=16-31（整 NUMA）
                       例 SMT on:  cpu_com=16 numa1 → HULK_CPUSET=16-31（从 16-31,144-159）
  event_loop=<N>       限制 gRPC Netty EventLoop 为 N（注入 JAVA_TOOL_OPTIONS + ActiveProcessorCount=N）
  java_path=<PATH>     宿主机 JDK（也可用 java_home=；尾斜杠可接受）
                       支持 JDK 根目录、bin 目录或 java 可执行文件路径
                       hostPath 双挂载: /opt/custom-jdk + /usr/local/mjdk-8.0.0-312
                       （mqs 硬编码 mjdk 路径，仅改 PATH/JAVA_HOME 无效）
                       另设 JAVA_HOME/PATH，并用 sh -c 包装 mqs entrypoint
  --update-jvm         或 update_jvm=1 / update_jvm=true
                       注入 /tmp/jdk-wrap java 包装，把 32G 高吞吐推荐 JVM flags
                       插入主类名之前（覆盖 mqs 硬编码 PROXY GC；可与 java_path 联用）
  --app_version <VER>  或 app_version=<VER>（也接受 --app_verison / app_verison=）
                       切换 app（第一个 container）镜像；sidecar/init 不动
                       1.8 → docker.io/system_test/com.sankuai.mqs:stable_amd64_1785306832245
                       1.6 或省略 → 保持模板默认镜像
  --mem <值>           或 mem=<值>（如 16G / 16Gi，也支持 Mi/M/Ki/K/Ti/T）
                       覆盖 app（第一个 container）resources.limits/requests.memory
                       （两者同值）；与 cpu_com/NUMA/镜像等其它设置完全独立
                       sidecar/init 内存不动；裸 G/M/K/T 按口语习惯映射为 Gi/Mi/Ki/Ti
                       （如 "16C16G" 中的 16G → 16Gi，非 SI 十进制）
                       省略时行为不变：无 NUMA 保持 32Gi；有 NUMA 保持模板默认值

node列表:
  1341-1343 | 1341,1342,1343 | 完整 nodeName

numa列表（可选）:
  numa0-numa7 | numa0,numa2-numa5 | 0,2-7
  NUMA→cpuset 从本机 OS 实时读取（/sys/.../nodeN/cpulist；勿假设 HT 兄弟核）
  省略 cpu_com → 注入完整 NUMA cpuset（SMT off: 0-15=16 核；SMT on: 0-15,128-143=32 核）
  cpu_com=N → 注入该 cpuset 的前 N 核子集（如 numa1 + cpu_com=8 → 16-23）
  Pod 分配：按本次创建批次内序号，先按 node 轮转填满同一 NUMA，再换下一 NUMA
  （del/plus/add 绑定规则相同；mode 只影响数量/是否先删）
  完全省略 numa 参数 → 整机共享+quota 限制模式：不绑定 cpuset/内存节点，
  容器可用整机所有 CPU 和内存，仅靠 resources.limits（cpu=cpu_com, memory=32Gi）限流

示例:
  ./scale_proxy_pods.sh 6 1341-1343                       # 增量到 6 个
  ./scale_proxy_pods.sh del 6 1341-1343                   # 仅删指定 node 上 proxy，再重建 6 个
  ./scale_proxy_pods.sh plus 3 1341-1343                  # 现有基础上追加 3 个
  ./scale_proxy_pods.sh del 9 1341-1343 numa0-numa2       # NUMA 绑定，cpu_com 自动=整 NUMA
  ./scale_proxy_pods.sh del 9 1341-1343 numa0-numa2 cpu_com=16  # SMT off 时常=整 NUMA
  ./scale_proxy_pods.sh del 3 1341-1343 java_home=/home/test/HPEJDK_1.0.0_linux_x64 cpu_com=16 numa1
                                                          # numa1：live cpuset 或前 16 核子集
  ./scale_proxy_pods.sh del 6 1341-1343 cpu_com=16        # 无 NUMA，仅删指定 node 后重建每个 16 核
  ./scale_proxy_pods.sh plus 3 1341-1343 cpu_com=8        # 追加 3 个 8 核容器
  ./scale_proxy_pods.sh del 6 1341-1343 cpu_com=16 event_loop=8  # 16 核 + EventLoop=8
  ./scale_proxy_pods.sh del 3 1341-1343 java_path=/home/test/HPEJDK_1.0.0_linux_x64/
  ./scale_proxy_pods.sh del 3 1341-1343 java_home=/home/test/HPEJDK_1.0.0_linux_x64 cpu_com=16
  ./scale_proxy_pods.sh del 3 1341-1343 --update-jvm
  ./scale_proxy_pods.sh del 3 1341-1343 java_path=/home/test/HPEJDK... --update-jvm cpu_com=16 numa1
  ./scale_proxy_pods.sh del 3 1341-1343 cpu_com=16 --app_version 1.8
  ./scale_proxy_pods.sh plus 3 1341-1343 numa1 cpu_com=16 --app_version 1.8
  ./scale_proxy_pods.sh del 3 1341-1343                   # 默认 1.6 / 模板镜像
  ./scale_proxy_pods.sh del 3 1341-1343 cpu_com=16 --mem 16G   # 16C16G
  ./scale_proxy_pods.sh plus 3 1341-1343 numa1 cpu_com=16 --mem 16G  # NUMA 绑核 + 16G 内存

删除环境变量（可选）:
  DELETE_WAIT_TIMEOUT=20   等待终止秒数（默认 20）
  DELETE_GRACE_PERIOD=30   优雅退出宽限（默认 30）
  DELETE_FORCE=true        超时后 --force 强删（默认 true）
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# 参数校验
# ---------------------------------------------------------------------------
[[ -n "$COUNT" && "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || usage
[[ -n "$NODE_SPEC" ]] || usage
[[ -f "$KCFG" ]] || { echo "错误: 找不到 kubeconfig: $KCFG"; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "错误: 找不到模板 YAML: $TEMPLATE"; exit 1; }
[[ -z "$CPU_CORES" || "$CPU_CORES" -gt 0 ]] || { echo "错误: cpu_com 必须为正整数"; exit 1; }
[[ -z "$EVENT_LOOPS" || "$EVENT_LOOPS" -gt 0 ]] || { echo "错误: event_loop 必须为正整数"; exit 1; }
if [[ -n "$JAVA_PATH" ]]; then
  JAVA_PATH="${JAVA_PATH%/}"
  [[ -n "$JAVA_PATH" ]] || { echo "错误: java_path 不能为空"; exit 1; }
fi
case "$APP_VERSION" in
  ""|1.6|1.8) ;;
  *)
    echo "错误: app_version 无效: ${APP_VERSION}（目前仅支持 1.6 或 1.8）"
    exit 1
    ;;
esac
if [[ -n "$APP_MEM" ]]; then
  APP_MEM=$(normalize_mem_value "$APP_MEM") || exit 1
fi
# 无 NUMA 时的生效内存：--mem 显式覆盖优先，否则沿用既有默认 NONUMA_MEM_LIMIT（32Gi）
EFFECTIVE_MEM_NONUMA="${APP_MEM:-$NONUMA_MEM_LIMIT}"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
kubectl_cmd() {
  kubectl --kubeconfig="$KCFG" -n "$NS" "$@"
}

# 收集指定 node 上匹配 LABEL_SELECTOR 的 proxy Pod 名（空格分隔）
collect_proxy_pods_on_nodes() {
  local node names all=""
  for node in "${NODES[@]}"; do
    names=$(kubectl_cmd get pods -l "$LABEL_SELECTOR" \
      --field-selector "spec.nodeName=${node}" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [[ -n "$names" ]]; then
      [[ -n "$all" ]] && all+=" "
      all+="$names"
    fi
  done
  echo "$all"
}

# 统计指定 node 上仍存在的 proxy Pod 数
count_proxy_pods_on_nodes() {
  local node cnt total=0
  for node in "${NODES[@]}"; do
    cnt=$(kubectl_cmd get pods -l "$LABEL_SELECTOR" \
      --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | wc -l)
    cnt=${cnt// /}
    total=$((total + cnt))
  done
  echo "$total"
}

# 仅删除 NODES[] 上的 proxy Pod（不触及其他 node）
# 依赖：调用前已解析 NODE_SPEC → NODES[] / NODE_LABELS[]
delete_proxy_pods_on_nodes() {
  local pods remaining stuck node
  local wait_timeout="${DELETE_WAIT_TIMEOUT:-20}"
  local grace="${DELETE_GRACE_PERIOD:-30}"
  local force="${DELETE_FORCE:-true}"

  if (( ${#NODES[@]} == 0 )); then
    echo "错误: NODES 为空，无法按节点删除 proxy Pod"
    exit 1
  fi

  echo "===== 删除指定节点上的 proxy Pod（仅 ${NODE_SPEC} / ${#NODES[@]} 个 node）====="
  for i in "${!NODES[@]}"; do
    echo "  范围 node${i}: ${NODE_LABELS[$i]} -> ${NODES[$i]}"
  done

  pods=$(collect_proxy_pods_on_nodes)
  if [[ -z "$pods" ]]; then
    echo "指定节点上没有需要删除的 proxy Pod。"
    echo ""
    return 0
  fi

  for node in "${NODES[@]}"; do
    kubectl_cmd get pods -l "$LABEL_SELECTOR" \
      --field-selector "spec.nodeName=${node}" -o wide 2>/dev/null || true
  done
  echo ""
  echo "发送删除请求（grace-period=${grace}s，最多等待 ${wait_timeout}s）..."

  # shellcheck disable=SC2086
  kubectl_cmd delete pod $pods --ignore-not-found --wait=false --grace-period="$grace"

  local deadline=$((SECONDS + wait_timeout))
  while (( SECONDS < deadline )); do
    remaining=$(count_proxy_pods_on_nodes)
    remaining=${remaining// /}
    if (( remaining == 0 )); then
      echo "指定节点上的 proxy Pod 已全部删除。"
      echo ""
      return 0
    fi
    echo "  等待终止中... 剩余 ${remaining} 个（仅统计指定 node）"
    for node in "${NODES[@]}"; do
      kubectl_cmd get pods -l "$LABEL_SELECTOR" \
        --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | sed 's/^/    /' || true
    done
    sleep 5
  done

  stuck=$(collect_proxy_pods_on_nodes)
  if [[ -z "$stuck" ]]; then
    echo "指定节点上的 proxy Pod 已全部删除。"
    echo ""
    return 0
  fi

  echo ""
  echo "警告: ${wait_timeout}s 后仍有 Pod 卡在 Terminating（仅指定 node）:"
  # shellcheck disable=SC2086
  kubectl_cmd get pod $stuck -o wide 2>/dev/null || true

  if [[ "$force" == "true" || "$force" == "1" || "$force" == "yes" ]]; then
    echo ""
    echo "尝试强制删除（--grace-period=0 --force）..."
    # shellcheck disable=SC2086
    kubectl_cmd delete pod $stuck --ignore-not-found --grace-period=0 --force --wait=false
    sleep 5
    stuck=$(collect_proxy_pods_on_nodes)
    if [[ -n "$stuck" ]]; then
      echo "错误: 以下 Pod 仍无法删除，请手动处理:"
      # shellcheck disable=SC2086
      kubectl_cmd get pod $stuck -o wide
      echo "  手动: kubectl --kubeconfig=$KCFG -n $NS delete pod <name> --grace-period=0 --force"
      exit 1
    fi
    echo "指定节点上的 proxy Pod 已强制删除完成。"
  else
    echo "设置 DELETE_FORCE=true 可自动强制删除。"
    exit 1
  fi
  echo ""
}

expand_token() {
  local token="$1"
  token="${token// /}"

  if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
    if (( start > end )); then echo "错误: 无效区间 ${token}" >&2; return 1; fi
    for ((i = start; i <= end; i++)); do echo "$i"; done
    return 0
  fi

  if [[ "$token" =~ ^([a-zA-Z_-]+)([0-9]+)-([a-zA-Z_-]*)([0-9]+)$ ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local start="${BASH_REMATCH[2]}"
    local mid="${BASH_REMATCH[3]}"
    local end="${BASH_REMATCH[4]}"
    if [[ -n "$mid" && "$mid" != "$prefix" ]]; then
      echo "错误: 无效区间 ${token}" >&2
      return 1
    fi
    if (( start > end )); then echo "错误: 无效区间 ${token}" >&2; return 1; fi
    for ((i = start; i <= end; i++)); do echo "${prefix}${i}"; done
    return 0
  fi

  echo "$token"
}

parse_list() {
  local spec="$1"
  local part
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    while IFS= read -r token; do
      [[ -n "$token" ]] && echo "$token"
    done < <(expand_token "$part")
  done
}

resolve_node_name() {
  local n="$1"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "${NODE_NAME_PREFIX}${n}${NODE_NAME_SUFFIX}"
  else
    echo "$n"
  fi
}

node_short_label() {
  local n="$1"
  if [[ "$n" =~ ^${NODE_NAME_PREFIX}([0-9]+)${NODE_NAME_SUFFIX}$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$n" | tr '/:' '-'
  fi
}

extract_numa_id() {
  local t="$1"
  if [[ "$t" =~ ^[nN][uU][mM][aA]([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$t" =~ ^([0-9]+)$ ]]; then
    echo "$t"
  else
    echo "$t"
  fi
}

# ---------------------------------------------------------------------------
# OS NUMA → CPUSET：从本机实时拓扑读取（勿写死 SMT-on 的 HT 兄弟核 128-255）
#
# 注意: 拓扑只读一次，来源是运行本脚本的机器（通常是 k8s 管理机/登录节点，
# 或某台业务节点如 1341）。本舰队各 node 拓扑一致（同 SMT on/off）时可用；
# 若各节点拓扑不同，需在目标节点上跑本脚本，或自行扩展为逐节点探测。
# 优先: /sys/devices/system/node/nodeN/cpulist ∩ /sys/devices/system/cpu/online
# 回退: lscpu -p=CPU,NODE  →  numactl -H（同样只保留 online CPU）
# 失败则直接报错退出，绝不回退到任何写死的 SMT-on 假表。
# ---------------------------------------------------------------------------
declare -A NUMA_CPUSET=()
declare -a DISCOVERED_NUMA_IDS=()
declare -A ONLINE_CPU_SET=()
ONLINE_CPU_LIST=""
ONLINE_CPU_SRC=""

# 将已排序的 CPU 编号列表压缩为 cpuset 字符串（如 0 1 2 4 → 0-2,4）
compress_cpu_ids() {
  local -a cpus=("$@")
  local i cpu prev run_start out=""
  (( ${#cpus[@]} > 0 )) || { echo ""; return 0; }
  run_start=""
  prev=""
  for cpu in "${cpus[@]}"; do
    if [[ -z "$run_start" ]]; then
      run_start="$cpu"
      prev="$cpu"
    elif (( cpu == prev + 1 )); then
      prev="$cpu"
    else
      if (( run_start == prev )); then
        [[ -n "$out" ]] && out+=","
        out+="${run_start}"
      else
        [[ -n "$out" ]] && out+=","
        out+="${run_start}-${prev}"
      fi
      run_start="$cpu"
      prev="$cpu"
    fi
  done
  if [[ -n "$run_start" ]]; then
    if (( run_start == prev )); then
      [[ -n "$out" ]] && out+=","
      out+="${run_start}"
    else
      [[ -n "$out" ]] && out+=","
      out+="${run_start}-${prev}"
    fi
  fi
  echo "$out"
}

# 展开 cpuset 字符串为逐行 CPU id（不排序去重；调用方可再处理）
expand_cpuset_to_ids() {
  local cpuset="$1"
  local -a parts=()
  local part start end i
  IFS=',' read -ra parts <<< "$cpuset"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if (( start > end )); then
        echo "错误: 无效 cpuset 区间 ${part}" >&2
        return 1
      fi
      for ((i = start; i <= end; i++)); do
        printf '%s\n' "$i"
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$part"
    else
      echo "错误: 无效 cpuset 片段: ${part}" >&2
      return 1
    fi
  done
}

# 读取 online CPU 列表。SMT off 后 nodeN/cpulist 常仍含离线 HT 兄弟核，必须与此求交。
load_online_cpus() {
  ONLINE_CPU_SET=()
  ONLINE_CPU_LIST=""
  ONLINE_CPU_SRC=""
  local online="" id
  local -a ids=()

  if [[ -r /sys/devices/system/cpu/online ]]; then
    online=$(tr -d ' \n\r\t' < /sys/devices/system/cpu/online 2>/dev/null || true)
    ONLINE_CPU_SRC="/sys/devices/system/cpu/online"
  fi
  if [[ -z "$online" ]] && command -v lscpu >/dev/null 2>&1; then
    online=$(lscpu 2>/dev/null | awk -F: '/^On-line CPU\(s\) list:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')
    [[ -n "$online" ]] && ONLINE_CPU_SRC="lscpu On-line CPU(s) list"
  fi
  if [[ -z "$online" ]]; then
    echo "错误: 无法读取 online CPU 列表（需要 /sys/devices/system/cpu/online 或 lscpu）" >&2
    echo "  拒绝继续：否则可能把已离线的 HT 兄弟核（如 128-255）当成可用核。" >&2
    return 1
  fi

  mapfile -t ids < <(expand_cpuset_to_ids "$online" | sort -n || true)
  if (( ${#ids[@]} == 0 )); then
    echo "错误: online CPU 列表解析为空: ${online}" >&2
    return 1
  fi
  for id in "${ids[@]}"; do
    ONLINE_CPU_SET[$id]=1
  done
  ONLINE_CPU_LIST=$(compress_cpu_ids "${ids[@]}")
  return 0
}

# 将 cpuset 与 online 求交后重新压缩；若结果为空则失败
filter_cpuset_by_online() {
  local cpulist="$1"
  local id
  local -a kept=()

  if (( ${#ONLINE_CPU_SET[@]} == 0 )); then
    echo "错误: ONLINE_CPU_SET 未加载，无法过滤离线 CPU" >&2
    return 1
  fi
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    [[ -n "${ONLINE_CPU_SET[$id]+x}" ]] && kept+=("$id")
  done < <(expand_cpuset_to_ids "$cpulist")

  if (( ${#kept[@]} == 0 )); then
    echo "错误: cpuset=${cpulist} 与 online(${ONLINE_CPU_LIST}) 求交后为空" >&2
    return 1
  fi
  compress_cpu_ids "${kept[@]}"
}

discover_os_numa_topology() {
  NUMA_CPUSET=()
  DISCOVERED_NUMA_IDS=()
  local node_dir id cpulist line cpu node src="" filtered
  local -A tmp_cpus=()
  local -a sorted=() raw_ids=()
  local example_id example_cs example_n=""

  load_online_cpus || return 1

  # 1) /sys/devices/system/node/nodeN/cpulist ∩ online
  if [[ -d /sys/devices/system/node ]]; then
    for node_dir in /sys/devices/system/node/node[0-9]*; do
      [[ -e "$node_dir" ]] || continue
      [[ -r "$node_dir/cpulist" ]] || continue
      id="${node_dir##*/node}"
      [[ "$id" =~ ^[0-9]+$ ]] || continue
      cpulist=$(tr -d ' \n\r\t' < "$node_dir/cpulist" 2>/dev/null || true)
      [[ -n "$cpulist" ]] || continue
      filtered=$(filter_cpuset_by_online "$cpulist") || {
        echo "错误: NUMA node${id} cpulist=${cpulist} 过滤 online 后无可用 CPU" >&2
        return 1
      }
      NUMA_CPUSET[$id]="$filtered"
      DISCOVERED_NUMA_IDS+=("$id")
    done
    if (( ${#DISCOVERED_NUMA_IDS[@]} > 0 )); then
      src="/sys/devices/system/node/*/cpulist ∩ online"
    fi
  fi

  # 2) lscpu -p=CPU,NODE（仅 online；lscpu -p 通常已不含 offline，仍再滤一次）
  if (( ${#DISCOVERED_NUMA_IDS[@]} == 0 )) && command -v lscpu >/dev/null 2>&1; then
    tmp_cpus=()
    while IFS= read -r line; do
      [[ "$line" =~ ^# ]] && continue
      [[ "$line" =~ ^([0-9]+),([0-9]+) ]] || continue
      cpu="${BASH_REMATCH[1]}"
      node="${BASH_REMATCH[2]}"
      [[ -n "${ONLINE_CPU_SET[$cpu]+x}" ]] || continue
      if [[ -z "${tmp_cpus[$node]+x}" ]]; then
        tmp_cpus[$node]="$cpu"
      else
        tmp_cpus[$node]+=" $cpu"
      fi
    done < <(lscpu -p=CPU,NODE 2>/dev/null || true)
    for id in "${!tmp_cpus[@]}"; do
      sorted=()
      mapfile -t sorted < <(echo "${tmp_cpus[$id]}" | tr ' ' '\n' | sort -n)
      (( ${#sorted[@]} > 0 )) || continue
      NUMA_CPUSET[$id]=$(compress_cpu_ids "${sorted[@]}")
      DISCOVERED_NUMA_IDS+=("$id")
    done
    if (( ${#DISCOVERED_NUMA_IDS[@]} > 0 )); then
      src="lscpu -p=CPU,NODE ∩ online"
    fi
  fi

  # 3) numactl -H ∩ online
  if (( ${#DISCOVERED_NUMA_IDS[@]} == 0 )) && command -v numactl >/dev/null 2>&1; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^node[[:space:]]+([0-9]+)[[:space:]]+cpus:(.*)$ ]]; then
        id="${BASH_REMATCH[1]}"
        cpulist="${BASH_REMATCH[2]}"
        cpulist="${cpulist#"${cpulist%%[![:space:]]*}"}"
        cpulist="${cpulist%"${cpulist##*[![:space:]]}"}"
        [[ -n "$cpulist" ]] || continue
        raw_ids=()
        mapfile -t raw_ids < <(echo "$cpulist" | tr -s '[:space:]' '\n' | grep -E '^[0-9]+$' | sort -n)
        (( ${#raw_ids[@]} > 0 )) || continue
        cpulist=$(compress_cpu_ids "${raw_ids[@]}")
        filtered=$(filter_cpuset_by_online "$cpulist") || {
          echo "错误: numactl NUMA node${id} 过滤 online 后无可用 CPU" >&2
          return 1
        }
        NUMA_CPUSET[$id]="$filtered"
        DISCOVERED_NUMA_IDS+=("$id")
      fi
    done < <(numactl -H 2>/dev/null || true)
    if (( ${#DISCOVERED_NUMA_IDS[@]} > 0 )); then
      src="numactl -H ∩ online"
    fi
  fi

  if (( ${#DISCOVERED_NUMA_IDS[@]} == 0 )); then
    echo "错误: 无法从本机读取 NUMA 拓扑（尝试了 /sys/devices/system/node/*/cpulist、lscpu -p、numactl -H）" >&2
    echo "  已拒绝使用任何写死的 SMT-on 假表；请在有真实 NUMA sysfs 的机器上运行，或检查权限。" >&2
    return 1
  fi

  mapfile -t DISCOVERED_NUMA_IDS < <(printf '%s\n' "${DISCOVERED_NUMA_IDS[@]}" | sort -n)
  example_id="${DISCOVERED_NUMA_IDS[0]}"
  example_cs="${NUMA_CPUSET[$example_id]}"
  example_n=$(count_cpus_in_cpuset "$example_cs") || return 1

  echo "===== 拓扑来源: ${src}；online=${ONLINE_CPU_LIST}（来自 ${ONLINE_CPU_SRC}）====="
  echo "===== 每 NUMA 核数示例: ${example_n}（node${example_id}: ${example_cs}）；共 ${#DISCOVERED_NUMA_IDS[@]} 个 NUMA 节点 ====="
  echo "提示: 若仍看到 128-255 段，说明脚本未更新或未与 online 求交；本版会过滤离线 HT 兄弟核。"
}

get_os_numa_cpuset() {
  local id="$1"
  if [[ -n "${NUMA_CPUSET[$id]+x}" && -n "${NUMA_CPUSET[$id]}" ]]; then
    echo "${NUMA_CPUSET[$id]}"
    return 0
  fi
  echo "错误: NUMA id=${id} 不在本机已发现的 OS NUMA 节点中（已发现: ${DISCOVERED_NUMA_IDS[*]:-无}）" >&2
  return 1
}

# 统计 cpuset 字符串中的 CPU 个数，如 0-15,128-143 → 32；0-15 → 16
count_cpus_in_cpuset() {
  local cpuset="$1"
  local total=0
  local part start end
  local -a parts=()
  IFS=',' read -ra parts <<< "$cpuset"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if (( start > end )); then
        echo "错误: 无效 cpuset 区间 ${part}" >&2
        return 1
      fi
      total=$((total + end - start + 1))
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      total=$((total + 1))
    else
      echo "错误: 无效 cpuset 片段: ${part}" >&2
      return 1
    fi
  done
  echo "$total"
}

# 从完整 cpuset 取前 n 个 CPU，再压缩为 range/comma 形式
# 例: subset_cpuset "16-31,144-159" 16 → 16-31
#     subset_cpuset "0-15,128-143" 8  → 0-7
#     subset_cpuset "16-31,144-159" 32 → 16-31,144-159（原样）
subset_cpuset() {
  local full_cpuset="$1"
  local n="$2"
  local -a cpus=()
  local -a parts=()
  local part start end i cpu prev run_start out=""

  if [[ -z "$n" || ! "$n" =~ ^[0-9]+$ || "$n" -le 0 ]]; then
    echo "错误: subset_cpuset 需要正整数 N，收到: ${n}" >&2
    return 1
  fi

  IFS=',' read -ra parts <<< "$full_cpuset"
  for part in "${parts[@]}"; do
    part="${part// /}"
    [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      if (( start > end )); then
        echo "错误: 无效 cpuset 区间 ${part}" >&2
        return 1
      fi
      for ((i = start; i <= end; i++)); do
        cpus+=("$i")
      done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      cpus+=("$part")
    else
      echo "错误: 无效 cpuset 片段: ${part}" >&2
      return 1
    fi
  done

  local total=${#cpus[@]}
  if (( n > total )); then
    echo "错误: 请求 ${n} 核，但 cpuset ${full_cpuset} 仅有 ${total} 核" >&2
    return 1
  fi
  if (( n == total )); then
    echo "$full_cpuset"
    return 0
  fi

  # 取前 n 个，压缩为紧凑 range
  run_start=""
  prev=""
  out=""
  for ((i = 0; i < n; i++)); do
    cpu="${cpus[$i]}"
    if [[ -z "$run_start" ]]; then
      run_start="$cpu"
      prev="$cpu"
    elif (( cpu == prev + 1 )); then
      prev="$cpu"
    else
      if (( run_start == prev )); then
        [[ -n "$out" ]] && out+=","
        out+="${run_start}"
      else
        [[ -n "$out" ]] && out+=","
        out+="${run_start}-${prev}"
      fi
      run_start="$cpu"
      prev="$cpu"
    fi
  done
  if [[ -n "$run_start" ]]; then
    if (( run_start == prev )); then
      [[ -n "$out" ]] && out+=","
      out+="${run_start}"
    else
      [[ -n "$out" ]] && out+=","
      out+="${run_start}-${prev}"
    fi
  fi
  echo "$out"
}

# Pod → node/numa 索引（按「本次创建批次」内的 1-based 序号 assign_k，与模式无关）：
#   node = (assign_k-1) % num_nodes
#   numa = floor((assign_k-1) / num_nodes) % num_numas
# 即先按 node 轮转填满同一 NUMA，再换下一 NUMA，避免同 (node,numa) 叠满。
# del/plus/add 共用同一公式；mode 只决定创建数量 / 是否先删，不改变绑定规则。
# 全局序号 k（用于 Pod 命名）可能因 plus/add 从 total_current+1 起，但绑核用 assign_k=k-START_K+1。
# 例: 本次创建 9 pods × 3 nodes × numa0-2 →
#   assign #1..#3: (n0,numa0)(n1,numa0)(n2,numa0)
#   assign #4..#6: (n0,numa1)(n1,numa1)(n2,numa1)
#   assign #7..#9: (n0,numa2)(n1,numa2)(n2,numa2)
# 例: plus 3 × 3 nodes × numa1 → assign #1..#3 各 1 个 node，全部 numa1
node_index_for_pod() {
  echo $(( ($1 - 1) % num_nodes ))
}

numa_index_for_pod() {
  echo $(( (($1 - 1) / num_nodes) % num_numas ))
}

numa_info_for_pod() {
  local k="$1"
  local nidx full_cpuset
  nidx=$(numa_index_for_pod "$k")
  NUMA_TOKEN_FOR_POD="${NUMA_TOKENS[$nidx]}"
  NUMA_ID_FOR_POD="${NUMA_IDS[$nidx]}"
  full_cpuset=$(get_os_numa_cpuset "$NUMA_ID_FOR_POD")
  if [[ -n "$CPU_CORES" ]]; then
    NUMA_CPUSET_FOR_POD=$(subset_cpuset "$full_cpuset" "$CPU_CORES") || return 1
  else
    NUMA_CPUSET_FOR_POD="$full_cpuset"
  fi
}

pod_exists() {
  kubectl_cmd get pod "$1" &>/dev/null
}

inject_numa_into_yaml() {
  local yaml_file="$1"
  local numa_id="$2"
  local cpuset="$3"

  if grep -q "name: ${NUMA_ENV_NAME}" "$yaml_file" 2>/dev/null; then
    sed -i "/name: ${NUMA_ENV_NAME}/{n;s/value: .*/value: \"${numa_id}\"/}" "$yaml_file"
  else
    sed -i "/^    - name: NODE_NAME$/i\\
    - name: ${NUMA_ENV_NAME}\\
      value: \"${numa_id}\"" "$yaml_file"
  fi

  if grep -q "name: ${NUMA_CPUSET_ENV_NAME}" "$yaml_file" 2>/dev/null; then
    sed -i "/name: ${NUMA_CPUSET_ENV_NAME}/{n;s/value: .*/value: \"${cpuset}\"/}" "$yaml_file"
  else
    sed -i "/^    - name: NODE_NAME$/i\\
    - name: ${NUMA_CPUSET_ENV_NAME}\\
      value: \"${cpuset}\"" "$yaml_file"
  fi

  if grep -q "${NUMA_ANNOTATION_KEY}:" "$yaml_file" 2>/dev/null; then
    sed -i "s|${NUMA_ANNOTATION_KEY}: .*|${NUMA_ANNOTATION_KEY}: \"${numa_id}\"|" "$yaml_file"
  else
    sed -i "/^  annotations:/a\\
    ${NUMA_ANNOTATION_KEY}: \"${numa_id}\"" "$yaml_file"
  fi

  if grep -q "${NUMA_CPUSET_ANNOTATION_KEY}:" "$yaml_file" 2>/dev/null; then
    sed -i "s|${NUMA_CPUSET_ANNOTATION_KEY}: .*|${NUMA_CPUSET_ANNOTATION_KEY}: \"${cpuset}\"|" "$yaml_file"
  else
    sed -i "/^  annotations:/a\\
    ${NUMA_CPUSET_ANNOTATION_KEY}: \"${cpuset}\"" "$yaml_file"
  fi
}

# 无 NUMA 路径：清除任何 cpuset/内存节点绑定痕迹（整机共享 + quota 限制模式）。
# 模板若从 NUMA Pod 导出，可能残留 HULK_CPUSET / HULK_NUMA_NODE env 或对应 annotation，
# 会被 hulk sidecar 拿去做 cpuset 绑定；此处全部删除，确保容器可用整机所有 CPU
# 和所有 NUMA 内存节点，CPU/内存用量只受 resources.limits（cfs quota + memory cgroup）约束。
strip_numa_pinning_from_yaml() {
  local yaml_file="$1"

  # env 条目为 "- name: XXX" + 下一行 "value: ..." 两行，成对删除
  if grep -q "name: ${NUMA_ENV_NAME}\$" "$yaml_file" 2>/dev/null; then
    sed -i "/- name: ${NUMA_ENV_NAME}\$/{N;d}" "$yaml_file"
  fi
  if grep -q "name: ${NUMA_CPUSET_ENV_NAME}\$" "$yaml_file" 2>/dev/null; then
    sed -i "/- name: ${NUMA_CPUSET_ENV_NAME}\$/{N;d}" "$yaml_file"
  fi

  # annotation 单行删除（key 含 / ，sed 用 | 作定界符）
  sed -i "\|^    ${NUMA_ANNOTATION_KEY}:|d" "$yaml_file"
  sed -i "\|^    ${NUMA_CPUSET_ANNOTATION_KEY}:|d" "$yaml_file"
}

# 无 NUMA 路径：强制 app（第一个 container）的 limits/requests.memory = NONUMA_MEM_LIMIT。
# 只改第一个 container，不动 sidecar/init 容器的 1Gi。
enforce_app_memory_limit() {
  local yaml_file="$1"
  local mem="$2"
  local tmp_file="${yaml_file}.mem.tmp"

  awk -v mem="$mem" '
    BEGIN { in_containers = 0; cidx = 0; in_first = 0; sect = "" }
    /^  containers:[[:space:]]*$/ { in_containers = 1; print; next }
    in_containers && /^  - / {
      cidx++
      in_first = (cidx == 1)
      sect = ""
      print
      next
    }
    # 2 空格缩进的兄弟字段 → 离开 containers 段
    in_containers && /^  [a-zA-Z]/ && !/^  - / {
      in_containers = 0
      in_first = 0
      sect = ""
      print
      next
    }
    in_first && /^      limits:[[:space:]]*$/   { sect = "limits";   print; next }
    in_first && /^      requests:[[:space:]]*$/ { sect = "requests"; print; next }
    in_first && sect != "" && /^        memory:/ {
      print "        memory: " mem
      next
    }
    in_first && sect != "" && /^      [a-zA-Z]/ { sect = "" }
    { print }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
}

# 改写 app（第一个 container）的 image:，不动 hulk-sidecar / initContainers。
# 兼容两种常见缩进：
#   containers: /  - name: /    image:     （kubectl/模板常见 2 空格 list）
#   containers: /    - name: /      image: （4 空格 list）
# 以第一个 list item 的缩进为准，避免把 env 里的 "    - name:" 当成新 container。
# 无论 image 值是否带引号、registry 路径为何，都整行改写。
inject_app_image_into_yaml() {
  local yaml_file="$1"
  local image="$2"
  local tmp_file="${yaml_file}.img.tmp"

  awk -v image="$image" '
    BEGIN {
      in_containers = 0
      cidx = 0
      in_first = 0
      done_img = 0
      list_indent = -1
    }
    /^  containers:[[:space:]]*$/ {
      in_containers = 1
      cidx = 0
      in_first = 0
      done_img = 0
      list_indent = -1
      print
      next
    }
    # 2 空格缩进的兄弟字段（initContainers/volumes/...）→ 离开 containers 段
    in_containers && /^  [a-zA-Z_]/ && !/^  - / {
      in_containers = 0
      in_first = 0
      list_indent = -1
      print
      next
    }
    in_containers && match($0, /^( *)- /) {
      sp = RLENGTH - 2
      if (list_indent < 0) list_indent = sp
      if (sp == list_indent) {
        cidx++
        in_first = (cidx == 1)
        done_img = 0
      }
      print
      next
    }
    # 第一容器字段级 image:（list_indent+2）；忽略更深缩进或其它字段
    in_first && !done_img && match($0, /^( *)image:/) {
      sp = RLENGTH - 6
      if (list_indent >= 0 && sp == list_indent + 2) {
        print substr($0, 1, sp) "image: " image
        done_img = 1
        next
      }
    }
    { print }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
}

# 注入 CPU 核数到 yaml：只改 app（第一个 container）的 limits/requests.cpu，
# 不动 hulk-sidecar / hulk-init（与 enforce_app_memory_limit / lower_app_cpu_request 一致）。
# 若第一容器 limits/requests 下已有 cpu 则改写；缺失则插入。
inject_cpu_into_yaml() {
  local yaml_file="$1"
  local cores="$2"
  local tmp_file="${yaml_file}.cpu.tmp"

  awk -v cores="$cores" '
    BEGIN { in_containers = 0; cidx = 0; in_first = 0; sect = ""; cpu_done = 0 }
    function flush_missing_cpu() {
      if (in_first && sect != "" && !cpu_done) {
        print "        cpu: \"" cores "\""
        cpu_done = 1
      }
    }
    /^  containers:[[:space:]]*$/ { in_containers = 1; print; next }
    in_containers && /^  - / {
      flush_missing_cpu()
      cidx++
      in_first = (cidx == 1)
      sect = ""
      cpu_done = 0
      print
      next
    }
    # 2 空格缩进的兄弟字段 → 离开 containers 段
    in_containers && /^  [a-zA-Z]/ && !/^  - / {
      flush_missing_cpu()
      in_containers = 0
      in_first = 0
      sect = ""
      cpu_done = 0
      print
      next
    }
    in_first && /^      limits:[[:space:]]*$/ {
      flush_missing_cpu()
      sect = "limits"
      cpu_done = 0
      print
      next
    }
    in_first && /^      requests:[[:space:]]*$/ {
      flush_missing_cpu()
      sect = "requests"
      cpu_done = 0
      print
      next
    }
    in_first && sect != "" && /^        cpu:/ {
      print "        cpu: \"" cores "\""
      cpu_done = 1
      next
    }
    # 离开 limits/requests 子段（同级 6 空格字段，或回到 4 空格容器字段）
    in_first && sect != "" && /^      [a-zA-Z]/ {
      flush_missing_cpu()
      sect = ""
      cpu_done = 0
      print
      next
    }
    in_first && sect != "" && /^    [a-zA-Z]/ {
      flush_missing_cpu()
      sect = ""
      cpu_done = 0
      print
      next
    }
    { print }
    END { flush_missing_cpu() }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
}

# 把 HULK_CORE / HULK_CORE_NUM 改成与 cpu_com 一致。
# 模板默认是 32；hulk-init 用这两个 env 写 /var/sankuai/hulk/one-cpu-config（hostPath
# 到节点 cpu cgroup）。若只改 k8s resources.limits.cpu=16 而 HULK_CORE 仍为 32，
# 实际 CPU 用量会按 32 核配，无法严格限制到 16 核占比。
# 范围：app（containers 第一个）+ 全部 initContainers；不动 hulk-sidecar（保持 1）。
inject_hulk_core_into_yaml() {
  local yaml_file="$1"
  local cores="$2"
  local tmp_file="${yaml_file}.hulkcore.tmp"

  awk -v cores="$cores" '
    BEGIN {
      section = ""
      cidx = 0
      in_target = 0
      list_indent = -1
      pending = 0
    }
    /^  containers:[[:space:]]*$/ {
      section = "containers"
      cidx = 0
      in_target = 0
      list_indent = -1
      pending = 0
      print
      next
    }
    /^  initContainers:[[:space:]]*$/ {
      section = "init"
      cidx = 0
      in_target = 0
      list_indent = -1
      pending = 0
      print
      next
    }
    section != "" && /^  [a-zA-Z_]/ && !/^  - / {
      section = ""
      in_target = 0
      pending = 0
      print
      next
    }
    section != "" && match($0, /^( *)- /) {
      sp = RLENGTH - 2
      if (list_indent < 0) list_indent = sp
      if (sp == list_indent) {
        cidx++
        in_target = (section == "init" || cidx == 1)
        pending = 0
        print
        next
      }
      # 更深缩进的 "- name:" 是 env 条目，不 next，交给下面 HULK_CORE 匹配
    }
    in_target && /name: HULK_CORE_NUM[[:space:]]*$/ {
      pending = 1
      print
      next
    }
    in_target && /name: HULK_CORE[[:space:]]*$/ {
      pending = 1
      print
      next
    }
    pending && match($0, /^( *)value:/) {
      print substr($0, 1, RLENGTH) " \"" cores "\""
      pending = 0
      next
    }
    { pending = 0; print }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
}

# 无 NUMA 路径：把 app（第一个 container）的 requests.cpu 降为略低于 limits.cpu 的
# 毫核值（cpu_com*1000-100，如 cpu_com=16 → 15900m）。
# 原因：kubelet static CPU manager 对 "Guaranteed QoS Pod + 整数 CPU request" 的容器
# 直接分配独占 cpuset（表现为 taskset -cp 显示进程钉在 N 个连续核，如 36-51），
# 这与 hulk 的 HULK_CPUSET 机制无关，光清除 env/annotation 挡不住。
# requests<limits 后 Pod QoS 变为 Burstable → static policy 不再给独占核，
# 容器共享节点默认 cpuset（整机 CPU 减去其他 Pod 的独占核）。
# 用量仍由 limits.cpu + HULK_CORE + 启动脚本写 CFS quota 卡在 N 核；
# 以前超 N 核是因为 HULK_CORE 仍为 32 / sidecar 改回 quota，不是 Burstable 本身。
# 只改第一个 container 的 requests.cpu，不动 limits，也不动 sidecar。
lower_app_cpu_request() {
  local yaml_file="$1"
  local cpu_req="$2"
  local tmp_file="${yaml_file}.cpureq.tmp"

  awk -v cpureq="$cpu_req" '
    BEGIN { in_containers = 0; cidx = 0; in_first = 0; sect = "" }
    /^  containers:[[:space:]]*$/ { in_containers = 1; print; next }
    in_containers && /^  - / {
      cidx++
      in_first = (cidx == 1)
      sect = ""
      print
      next
    }
    # 2 空格缩进的兄弟字段 → 离开 containers 段
    in_containers && /^  [a-zA-Z]/ && !/^  - / {
      in_containers = 0
      in_first = 0
      sect = ""
      print
      next
    }
    in_first && /^      limits:[[:space:]]*$/   { sect = "limits";   print; next }
    in_first && /^      requests:[[:space:]]*$/ { sect = "requests"; print; next }
    in_first && sect == "requests" && /^        cpu:/ {
      print "        cpu: " cpureq
      next
    }
    in_first && sect != "" && /^      [a-zA-Z]/ { sect = "" }
    { print }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
}

# 注入 JAVA_TOOL_OPTIONS（app 容器 env）。已有同名则改写 value，否则插到 NODE_NAME 前。

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

inject_java_tool_options() {
  local yaml_file="$1"
  local jvm_opts="$2"

  if grep -q "name: JAVA_TOOL_OPTIONS" "$yaml_file" 2>/dev/null; then
    sed -i "/name: JAVA_TOOL_OPTIONS/{n;s|value: .*|value: \"${jvm_opts}\"|}" "$yaml_file"
  elif grep -q "name: MQS_PROXY_GRPC_THREAD_POOL_SIZE" "$yaml_file" 2>/dev/null; then
    sed -i "/name: MQS_PROXY_GRPC_THREAD_POOL_SIZE/{n;a\\
    - name: JAVA_TOOL_OPTIONS\\
      value: \"${jvm_opts}\"
    }" "$yaml_file"
  else
    sed -i "/^    - name: NODE_NAME$/i\\
    - name: JAVA_TOOL_OPTIONS\\
      value: \"${jvm_opts}\"" "$yaml_file"
  fi
}

# 注入 gRPC EventLoop 限制（需 ActiveProcessorCount 才能生效，已实测验证）
inject_event_loop_into_yaml() {
  local yaml_file="$1"
  local loops="$2"
  local jvm_opts="-Dio.grpc.netty.shaded.io.netty.eventLoopThreads=${loops} -Dio.netty.eventLoopThreads=${loops} -XX:ActiveProcessorCount=${loops}"
  inject_java_tool_options "$yaml_file" "$jvm_opts"
}

# 规范化 java_path -> JAVA_HOME + bin 目录
# 支持: /jdk | /jdk/bin | /jdk/bin/java
normalize_java_path() {
  local p="$1"
  p="${p%/}"
  if [[ "$p" == */bin/java ]]; then
    JAVA_HOME_RESOLVED="${p%/bin/java}"
    JAVA_BIN_RESOLVED="${JAVA_HOME_RESOLVED}/bin"
  elif [[ "$p" == */bin ]]; then
    JAVA_BIN_RESOLVED="$p"
    JAVA_HOME_RESOLVED="${p%/bin}"
  elif [[ "$(basename "$p")" == "java" ]]; then
    JAVA_BIN_RESOLVED="$(dirname "$p")"
    JAVA_HOME_RESOLVED="$(dirname "$JAVA_BIN_RESOLVED")"
  else
    JAVA_HOME_RESOLVED="$p"
    JAVA_BIN_RESOLVED="${p}/bin"
  fi
}

# 注入 app 容器 entrypoint wrap（sh -c），仅改第一个 container，不碰 sidecar。
# 参数:
#   $1 yaml_file
#   $2 export_java_home  — 无 update_jvm 时 export 的 JAVA_HOME（如 /opt/custom-jdk）
#   $3 real_java         — update_jvm 时真实 JDK 根（/opt/custom-jdk 或 mjdk）
#   $4 update_jvm        — 0/1；为 1 时写 /tmp/jdk-wrap/bin/java，把推荐 flags 插到主类名之前
#
# update_jvm 原理: java 命令行中，第一个"主类名"（不以 - 开头，且不是 -cp/-classpath/
# -p/--module-path/--class-path 的取值）之后的所有 token 都是 program args，不再是
# JVM 参数。mqs 启动脚本把 -XX/-Xlog 硬编码放在主类名*之前*，随后再拼上 "$@"（本身
# 就包含主类名）。旧版 wrapper 把推荐 flags 接在 "$@" 之后 —— 也就是接在主类名之后 ——
# 于是这些 flags 变成了传给 MqsProxyApplication.main() 的无意义程序参数，被 JVM 静默
# 忽略（jcmd VM.flags 仍显示 mqs 的旧默认值）。修复：wrapper 必须扫描 "$@"，在主类名
# token *前面* 插入推荐 flags，这样它们仍是合法 JVM 选项，且因为"后出现的 -XX:Foo=X
# 覆盖先出现的同名 flag"，会正确覆盖 mqs 硬编码的 GC/堆参数。始终 mkdir/chmod/touch
# gc.log。
#
# 生成方式: wrapper 脚本内容（含字面 "$@"、"${ARGS[@]}" 等，运行时才展开）先在本脚本
# 自身的 bash 里用单引号 heredoc（<<'WRAPEOF'，未嵌套在任何字符串里，无转义问题）拼好，
# 替换 __REAL_JAVA__/__JVM_FLAGS__ 占位符后整体 base64 编码、去掉换行，得到一个只含
# [A-Za-z0-9+/=] 的单行字符串。这样最终塞进 wrap 的只是一段不透明 base64，不含任何
# $ / 引号 / 换行，彻底避开"bash 拼 wrap -> 容器 sh -c 解析 wrap -> wrapper 文件内容
# 本身还要保留字面 $@"这三层转义地狱（早期版本就是在这里出过 bug）。容器内只需
# `printf %s "<base64>" | base64 -d > 文件` 还原，然后 chmod +x 即可。
# 无 NUMA：把宿主机 *控制器* 挂进 app。
# 不能 hostPath 整个 /sys/fs/cgroup：cgroup v1 的 cpuset/cpu 是 tmpfs 上的子挂载，
# k8s hostPath 非递归 bind，容器里只能看到空目录，mkdir 不会出现在宿主机控制器下。
# 必须分别挂 /sys/fs/cgroup/cpuset 和 /sys/fs/cgroup/cpu。
ensure_one_hostpath_on_app() {
  local yaml_file="$1"
  local vol_name="$2"
  local host_path="$3"
  local mount_path="$4"
  local tmp_file="${yaml_file}.hostcg.tmp"
  local has_vol=0

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

  if awk -v vol="$vol_name" '
        /^  volumes:[[:space:]]*$/ { in_vol=1; next }
        in_vol && /^  [a-zA-Z]/ && !/^  - / { in_vol=0 }
        in_vol && $0 ~ ("name:[[:space:]]*" vol "([[:space:]]|$)") { found=1; exit }
        END { exit !found }
      ' "$yaml_file"; then
    has_vol=1
  fi

  if (( has_vol )); then
    return 0
  fi

  if grep -q "^  volumes:[[:space:]]*$" "$yaml_file" 2>/dev/null; then
    awk -v vol="$vol_name" -v hpath="$host_path" '
      /^  volumes:[[:space:]]*$/ { in_vol=1; print; next }
      in_vol && /^  [a-zA-Z]/ && !/^  - / {
        print "  - name: " vol
        print "    hostPath:"
        print "      path: " hpath
        print "      type: Directory"
        in_vol=0
        print
        next
      }
      { print }
      END {
        if (in_vol) {
          print "  - name: " vol
          print "    hostPath:"
          print "      path: " hpath
          print "      type: Directory"
        }
      }
    ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
  else
    cat >> "$yaml_file" <<EOF
  volumes:
  - name: ${vol_name}
    hostPath:
      path: ${host_path}
      type: Directory
EOF
  fi
}

ensure_app_host_cgroup_mounts() {
  local yaml_file="$1"
  ensure_one_hostpath_on_app "$yaml_file" "host-cgroup-cpuset" "/sys/fs/cgroup/cpuset" "/host-cgroup/cpuset"
  ensure_one_hostpath_on_app "$yaml_file" "host-cgroup-cpu" "/sys/fs/cgroup/cpu" "/host-cgroup/cpu"
}

# wrap 不得含单引号（YAML args 用单引号包一层）。
# 无 NUMA：在宿主机 cgroup 树上建 kubelet 不会碰的自定义 cpuset/cpu cgroup，
# 把 kubepods 里的进程迁过去。cgroup v1 各控制器独立，memory/pids 仍由 k8s 管。
# 本函数以 & 结尾；调用方必须用空格拼接后续命令，禁止 "; mkdir"（&; 会 CrashLoop）。
# 过程写到 /opt/logs/mqs/cgroup-setup.log，mkdir 失败不再静默。
cpu_quota_shell_cmd() {
  local q=$(( $1 * 100000 ))
  tr -s '[:space:]' ' ' <<EOF
quota=${q};
LOG=/opt/logs/mqs/cgroup-setup.log;
mkdir -p /opt/logs/mqs; echo CG_SETUP_BEGIN \$(date) > \$LOG;
HC=/host-cgroup;
echo ls_host_cgroup=\$(ls -ld \$HC 2>&1) >> \$LOG;
CS=\$HC/cpuset;
if [ ! -f "\$CS/cgroup.procs" ]; then echo FALLBACK_cpuset_not_cgroup >> \$LOG; CS=/sys/fs/cgroup/cpuset; fi;
CPU=\$HC/cpu;
if [ ! -f "\$CPU/cgroup.procs" ]; then CPU="\$HC/cpuacct"; fi;
if [ ! -f "\$CPU/cgroup.procs" ]; then CPU=/sys/fs/cgroup/cpu; fi;
PIN=\$CS/mqs_full_cpuset;
QDIR=\$CPU/mqs_quota_\$HOSTNAME;
echo CS=\$CS CPU=\$CPU PIN=\$PIN QDIR=\$QDIR >> \$LOG;
mkdir -p "\$PIN"; echo mkdir_pin_rc=\$? >> \$LOG;
mkdir -p "\$QDIR"; echo mkdir_quota_rc=\$? >> \$LOG;
root_cpus=\`cat "\$CS/cpuset.cpus" 2>/dev/null || cat /sys/devices/system/cpu/online\`;
root_mems=\`cat "\$CS/cpuset.mems" 2>/dev/null || echo 0\`;
echo root_cpus=\$root_cpus root_mems=\$root_mems >> \$LOG;
echo "\$root_mems" > "\$PIN/cpuset.mems"; echo write_mems_rc=\$? >> \$LOG;
echo "\$root_cpus" > "\$PIN/cpuset.cpus"; echo write_cpus_rc=\$? >> \$LOG;
if [ -w "\$PIN/cpuset.memory_migrate" ]; then echo 1 > "\$PIN/cpuset.memory_migrate" || true; fi;
echo 100000 > "\$QDIR/cpu.cfs_period_us"; echo write_period_rc=\$? >> \$LOG;
echo \$quota > "\$QDIR/cpu.cfs_quota_us"; echo write_quota_rc=\$? >> \$LOG;
if [ -w "\$QDIR/cpu.max" ]; then echo "\$quota 100000" > "\$QDIR/cpu.max" || true; fi;
cs_path=\`grep :cpuset: /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3\`;
cpu_path=\`grep -E ":(cpu|cpu,cpuacct):" /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3\`;
echo cs_path=\$cs_path cpu_path=\$cpu_path >> \$LOG;
cat /proc/self/cgroup >> \$LOG;
mvto() { s=\$1; d=\$2; if [ ! -f "\$s/cgroup.procs" ]; then echo missing_src=\$s >> \$LOG; return 0; fi; if [ ! -f "\$d/cgroup.procs" ]; then echo missing_dst=\$d >> \$LOG; return 0; fi; for p in \`cat "\$s/cgroup.procs" 2>/dev/null\`; do echo \$p > "\$d/cgroup.procs" 2>/dev/null && echo moved \$p to \$d >> \$LOG || echo move_fail \$p to \$d >> \$LOG; done; };
migrate() { if [ -n "\$cs_path" ]; then mvto "\$CS\$cs_path" "\$PIN"; fi; if [ -n "\$cpu_path" ]; then mvto "\$CPU\$cpu_path" "\$QDIR"; fi; if [ -d /var/sankuai/hulk/one-cpu-config ]; then mvto /var/sankuai/hulk/one-cpu-config "\$QDIR"; fi; };
migrate;
ls -l \$PIN \$QDIR >> \$LOG 2>&1;
echo CG_SETUP_DONE >> \$LOG;
( while true; do migrate; sleep 2; done ) &
EOF
}

inject_app_entrypoint_wrap() {
  local yaml_file="$1"
  local export_java_home="$2"
  local real_java="$3"
  local update_jvm="${4:-0}"
  local mqs_bin="/opt/meituan/apps/mqs/bin/mqs"
  local mqs_arg="proxy"
  local tmp_file="${yaml_file}.wrap.tmp"
  local jvm_flags="$UPDATE_JVM_FLAGS"
  local logs="mkdir -p /opt/logs/mqs; chmod 777 /opt/logs/mqs; touch /opt/logs/mqs/gc.log"
  local prefix="$logs"
  local wrap
  if [[ -n "$CPU_CORES" ]]; then
    # 配额命令以 & 结尾启动后台刷新；必须用空格拼接，禁止 "; mkdir"（&; 会 CrashLoop）
    prefix="$(cpu_quota_shell_cmd "$CPU_CORES") ${logs}"
  fi

  if [[ "$update_jvm" == "1" ]]; then
    # 可选未注入: -XX:MaxDirectMemorySize=2g
    #
    # wrapper 脚本源码：字面 "$@" / "${ARGS[@]}" 等只在此 heredoc 里出现一次，
    # 干净地属于本函数所在的 bash（未嵌套在任何外层字符串中），运行时才由
    # /tmp/jdk-wrap/bin/java 自己展开。__REAL_JAVA__ / __JVM_FLAGS__ 是占位符，
    # 稍后用 bash 参数替换填入真实值（替换值本身可含 * 等字符，不会被当作 glob，
    # 因为 ${var//pat/rep} 的替换串是字面文本，且 wrapper 里 `read -a` 那行还套了
    # 双引号 + 顶层 set -f，双重保险）。
    local wrapper_script
    read -r -d '' wrapper_script <<'WRAPEOF' || true
#!/bin/bash
set -f
REAL_JAVA="__REAL_JAVA__/bin/java"
read -r -a EXTRA_FLAGS <<< "__JVM_FLAGS__"
ARGS=("$@")
NEW_ARGS=()
inserted=0
skip_next=0
for arg in "${ARGS[@]}"; do
  if [[ $skip_next -eq 1 ]]; then
    NEW_ARGS+=("$arg")
    skip_next=0
    continue
  fi
  if [[ $inserted -eq 0 && "$arg" != -* ]]; then
    NEW_ARGS+=("${EXTRA_FLAGS[@]}")
    inserted=1
  fi
  NEW_ARGS+=("$arg")
  case "$arg" in
    -cp|-classpath|-p|--module-path|--class-path) skip_next=1 ;;
  esac
done
exec "$REAL_JAVA" "${NEW_ARGS[@]}"
WRAPEOF
    wrapper_script="${wrapper_script//__REAL_JAVA__/$real_java}"
    wrapper_script="${wrapper_script//__JVM_FLAGS__/$jvm_flags}"

    # 整段脚本 base64 编码并去掉换行 -> 单行、无 $/引号/换行的不透明字符串，
    # 可安全嵌进容器 sh -c 命令，也可安全嵌进外层 YAML 单引号字符串。
    local wrapper_b64
    wrapper_b64=$(printf '%s' "$wrapper_script" | base64 | tr -d '\n')

    wrap=$(printf 'mkdir -p /tmp/jdk-wrap/bin; printf %%s "%s" | base64 -d > /tmp/jdk-wrap/bin/java; chmod +x /tmp/jdk-wrap/bin/java; export JAVA_HOME=/tmp/jdk-wrap; export PATH=$JAVA_HOME/bin:$PATH; %s; exec %s %s' \
      "$wrapper_b64" "$prefix" "$mqs_bin" "$mqs_arg")
  elif [[ -n "$export_java_home" ]]; then
    wrap=$(printf 'export JAVA_HOME=%s; export PATH=$JAVA_HOME/bin:$PATH; %s; exec %s %s' \
      "$export_java_home" "$prefix" "$mqs_bin" "$mqs_arg")
  else
    wrap=$(printf '%s; exec %s %s' "$prefix" "$mqs_bin" "$mqs_arg")
  fi

  # ENVIRON 传递 wrap，避免 awk -v 把 \n 等转义成真实换行、弄坏 YAML 单行 args
  WRAP_SCRIPT="$wrap" awk '
    BEGIN {
      done = 0
      skip = 0
      in_c = 0
      list_indent = -1
      wrap = ENVIRON["WRAP_SCRIPT"]
    }
    function emit_wrapped_as_list_item() {
      print "  - command:"
      print "    - /bin/sh"
      print "    - -c"
      print "    args:"
      print "    - '\''" wrap "'\''"
    }
    /^  containers:[[:space:]]*$/ { in_c = 1; print; next }
    # 已处理完 app：后续 container（sidecar）一律原样输出
    done { print; next }

    # 第一个 container 的 list item（无论 - args: / - command: / - name:）都包装
    in_c && !skip && match($0, /^( *)- /) {
      sp = RLENGTH - 2
      if (list_indent < 0) list_indent = sp
      if (sp == list_indent) {
        emit_wrapped_as_list_item()
        skip = 1
        next
      }
    }
    skip {
      if (/^    env:[[:space:]]*$/ || /^    image:/ || /^    name:[[:space:]]+app/ || /^    imagePullPolicy:/) {
        skip = 0
        done = 1
        print
        next
      }
      # 跳过旧的 args/command 及其 list 项（含已包装的 -c / export 行 / flow-style）
      if (/^    command:[[:space:]]*/ || /^    args:[[:space:]]*/ || /^    - /) next
      if (/exec .*mqs/ || /JAVA_HOME=/ || /jdk-wrap/) next
      # 未知字段：停止 skip，保留该行（避免误删 resources 等）
      skip = 0
      done = 1
      print
      next
    }
    { print }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
}

# 仅 --update-jvm（无 java_path）：包装 entrypoint，REAL_JAVA=镜像默认 mjdk
inject_update_jvm_into_yaml() {
  local yaml_file="$1"
  local real_java="${DEFAULT_MJDK_HOME}"
  inject_app_entrypoint_wrap "$yaml_file" "" "$real_java" 1
}

# 注入 hostPath JDK，使 MQS 业务进程真正使用宿主机 JDK。
#
# 策略（防 CrashLoop）:
#   a) 始终 hostPath -> /opt/custom-jdk（JAVA_HOME 清晰挂载点）
#   b) 设 JAVA_HOME + PATH 前置（仅 app 容器）
#   c) command: [/bin/sh, -c] + 单条 YAML 单引号 args（保留 proxy 参数）
#   d) 可选 overlay -> /usr/local/mjdk-8.0.0-312（mqs 硬编码路径；MQS_JDK_OVERLAY 控制，默认 true）
#   e) 若 UPDATE_JVM=1：再套 /tmp/jdk-wrap，REAL_JAVA=/opt/custom-jdk，把推荐 flags 插到主类名之前
#
# volume: custom-jdk (hostPath.path = 宿主机规范化 JAVA_HOME)
# volumeMount: 仅 app 容器（第一个 container），不改 sidecar
inject_java_path_into_yaml() {
  local yaml_file="$1"
  local java_path="$2"
  local host_java_home host_java_bin
  local container_java_home="/opt/custom-jdk"
  local container_java_bin="/opt/custom-jdk/bin"
  local mjdk_overlay="${MQS_JDK_OVERLAY_PATH:-/usr/local/mjdk-8.0.0-312}"
  local vol_name="custom-jdk"
  local default_path new_path old_path tmp_file
  local has_vol=0
  local do_overlay=1
  local overlay_flag=0

  case "${MQS_JDK_OVERLAY:-true}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off) do_overlay=0 ;;
    *) do_overlay=1 ;;
  esac
  overlay_flag="$do_overlay"

  normalize_java_path "$java_path"
  host_java_home="$JAVA_HOME_RESOLVED"
  host_java_bin="$JAVA_BIN_RESOLVED"
  if (( do_overlay )); then
    default_path="${container_java_bin}:${mjdk_overlay}/bin:/opt/meituan/apps/mqs/bin:/usr/local/bin:/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin"
  else
    default_path="${container_java_bin}:/opt/meituan/apps/mqs/bin:/usr/local/bin:/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin"
  fi
  tmp_file="${yaml_file}.jdk.tmp"

  # ---- JAVA_HOME / PATH：仅注入到 app（第一个 container）的 env ----
  awk -v cjh="$container_java_home" -v cjb="$container_java_bin" \
      -v hjb="$host_java_bin" -v dpath="$default_path" '
    BEGIN {
      container_idx = 0
      in_first = 0
      in_env = 0
      path_done = 0
      java_home_done = 0
      new_path = dpath
    }
    /^  containers:[[:space:]]*$/ { print; next }
    /^  - / {
      container_idx++
      in_first = (container_idx == 1)
      in_env = 0
      print
      next
    }
    # 离开 containers
    container_idx > 0 && /^  [a-zA-Z]/ && !/^  - / {
      in_first = 0
      in_env = 0
      print
      next
    }
    in_first && /^    env:[[:space:]]*$/ {
      in_env = 1
      print
      next
    }
    in_first && in_env && /^    [a-zA-Z]/ && !/^    - / {
      # env 段结束前补齐缺失项
      if (!path_done) {
        print "    - name: PATH"
        print "      value: \"" new_path "\""
        path_done = 1
      }
      if (!java_home_done) {
        print "    - name: JAVA_HOME"
        print "      value: \"" cjh "\""
        java_home_done = 1
      }
      in_env = 0
      print
      next
    }
    in_first && in_env && /^    - name: PATH[[:space:]]*$/ {
      print
      getline
      if ($1 == "value:") {
        old = $0
        sub(/^[[:space:]]*value:[[:space:]]*/, "", old)
        gsub(/^"|"$/, "", old)
        if (index(old, cjb ":") == 1) old = substr(old, length(cjb) + 2)
        if (hjb != "" && index(old, hjb ":") == 1) old = substr(old, length(hjb) + 2)
        new_path = cjb ":" old
        print "      value: \"" new_path "\""
      } else {
        print "      value: \"" dpath "\""
        print
      }
      path_done = 1
      next
    }
    in_first && in_env && /^    - name: JAVA_HOME[[:space:]]*$/ {
      print
      getline
      if ($1 == "value:") {
        print "      value: \"" cjh "\""
      } else {
        print "      value: \"" cjh "\""
        print
      }
      java_home_done = 1
      next
    }
    { print }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"

  # ---- app 容器 command/args：稳健包装（支持 update_jvm）----
  inject_app_entrypoint_wrap "$yaml_file" "$container_java_home" "$container_java_home" "$UPDATE_JVM"

  # ---- volumeMounts（仅 app：第一个 container）----
  # overlay_flag=1 时额外挂 mjdk 路径；=0 时只挂 /opt/custom-jdk
  awk -v vol="$vol_name" -v mpath1="$container_java_home" -v mpath2="$mjdk_overlay" \
      -v do_overlay="$overlay_flag" '
    BEGIN {
      in_containers = 0
      container_idx = 0
      in_first = 0
      in_vm = 0
      vm_injected = 0
      nbuf = 0
    }
    function flush_vm_entry(   i, is_jdk) {
      if (nbuf == 0) return
      is_jdk = 0
      for (i = 1; i <= nbuf; i++) {
        if (buf[i] ~ ("name:[[:space:]]*" vol "([[:space:]]|$)")) is_jdk = 1
      }
      if (!is_jdk) {
        for (i = 1; i <= nbuf; i++) print buf[i]
      }
      nbuf = 0
    }
    function inject_jdk_mounts() {
      if (vm_injected) return
      print "    - mountPath: " mpath1
      print "      name: " vol
      print "      readOnly: true"
      if (do_overlay + 0) {
        print "    - mountPath: " mpath2
        print "      name: " vol
        print "      readOnly: true"
      }
      vm_injected = 1
    }
    /^  containers:[[:space:]]*$/ {
      in_containers = 1
      print
      next
    }
    in_containers && /^  - / {
      flush_vm_entry()
      if (in_vm && in_first && !vm_injected) inject_jdk_mounts()
      in_vm = 0
      container_idx++
      in_first = (container_idx == 1)
      print
      next
    }
    # 仅 2 空格缩进的兄弟字段才离开 containers（勿匹配 path:/name: 等更深缩进）
    in_containers && /^  [a-zA-Z]/ && !/^  - / {
      flush_vm_entry()
      if (in_vm && in_first && !vm_injected) inject_jdk_mounts()
      in_containers = 0
      in_first = 0
      in_vm = 0
      print
      next
    }
    in_first && /^    volumeMounts:[[:space:]]*$/ {
      in_vm = 1
      print
      next
    }
    in_first && in_vm && /^    [a-zA-Z]/ && !/^    - / {
      flush_vm_entry()
      if (!vm_injected) inject_jdk_mounts()
      in_vm = 0
      print
      next
    }
    in_first && in_vm && /^    - mountPath:/ {
      flush_vm_entry()
      buf[++nbuf] = $0
      next
    }
    in_first && in_vm && nbuf > 0 {
      buf[++nbuf] = $0
      next
    }
    {
      if (!in_first || !in_vm) print
    }
    END {
      flush_vm_entry()
      if (in_vm && in_first && !vm_injected) inject_jdk_mounts()
    }
  ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"

  # ---- volumes：custom-jdk hostPath ----
  # 注意：volumes 条目内的 "path:"/"name:" 是更深缩进，不能当作段结束。
  # 段结束条件：2 空格缩进的非 list 字段，或 EOF。
  # type 使用空串（与模板其他 hostPath 一致），避免 Directory 对 symlink/特殊挂载过严。
  if awk -v vol="$vol_name" '
        /^  volumes:[[:space:]]*$/ { in_vol=1; next }
        in_vol && /^  [a-zA-Z]/ && !/^  - / { in_vol=0 }
        in_vol && $0 ~ ("name:[[:space:]]*" vol "([[:space:]]|$)") { found=1; exit }
        END { exit !found }
      ' "$yaml_file"; then
    has_vol=1
  fi

  if (( has_vol )); then
    awk -v vol="$vol_name" -v hpath="$host_java_home" '
      function flush_buf(   i, is_target, line, path_done) {
        if (nbuf == 0) return
        is_target = 0
        for (i = 1; i <= nbuf; i++) {
          if (buf[i] ~ ("name:[[:space:]]*" vol "([[:space:]]|$)")) is_target = 1
        }
        path_done = 0
        for (i = 1; i <= nbuf; i++) {
          line = buf[i]
          if (is_target && !path_done && line ~ /^[[:space:]]*path:[[:space:]]/) {
            sub(/path:[[:space:]].*/, "path: " hpath, line)
            path_done = 1
          }
          print line
        }
        nbuf = 0
      }
      BEGIN { in_vol=0; nbuf=0 }
      /^  volumes:[[:space:]]*$/ {
        flush_buf()
        in_vol=1
        print
        next
      }
      in_vol && /^  [a-zA-Z]/ && !/^  - / {
        flush_buf()
        in_vol=0
        print
        next
      }
      in_vol && /^  - / {
        flush_buf()
        buf[++nbuf] = $0
        next
      }
      in_vol && nbuf > 0 {
        buf[++nbuf] = $0
        next
      }
      { print }
      END { flush_buf() }
    ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
  else
    if grep -q "^  volumes:[[:space:]]*$" "$yaml_file" 2>/dev/null; then
      awk -v vol="$vol_name" -v hpath="$host_java_home" '
        /^  volumes:[[:space:]]*$/ { in_vol=1; print; next }
        in_vol && /^  [a-zA-Z]/ && !/^  - / {
          print "  - name: " vol
          print "    hostPath:"
          print "      path: " hpath
          print "      type: \"\""
          in_vol=0
          print
          next
        }
        { print }
        END {
          if (in_vol) {
            print "  - name: " vol
            print "    hostPath:"
            print "      path: " hpath
            print "      type: \"\""
          }
        }
      ' "$yaml_file" > "$tmp_file" && mv "$tmp_file" "$yaml_file"
    else
      cat >> "$yaml_file" <<EOF
  volumes:
  - name: ${vol_name}
    hostPath:
      path: ${host_java_home}
      type: ""
EOF
    fi
  fi
}

# 等待新建 Pod Ready：周期性打印 STATUS/READY；遇 OutOfcpu/CrashLoop 等则快速失败
wait_new_pods_ready() {
  local timeout_s="${1:-300}"
  local poll_s="${2:-5}"
  local deadline=$((SECONDS + timeout_s))
  local -a pending=("${NEW_PODS[@]}")
  local -a ready_pods=()
  local -a failed_pods=()
  local pod line ready status reason remaining
  local fail_pat='OutOfcpu|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError|CreateContainerError|RunContainerError|Failed|Error|Evicted|UnexpectedAdmissionError'

  if (( ${#pending[@]} == 0 )); then
    echo "===== 无新建 Pod 需要等待 Ready ====="
    return 0
  fi

  echo "===== 等待新建 Pod Ready（最多 ${timeout_s}s，每 ${poll_s}s 打印 STATUS）====="

  while (( ${#pending[@]} > 0 )); do
    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )); then
      break
    fi

    echo ""
    echo "----- 待 Ready: ${#pending[@]} 个；剩余约 ${remaining}s -----"
    # 批量打印当前 STATUS，避免 silent hang
    # shellcheck disable=SC2086
    kubectl_cmd get pod "${pending[@]}" -o wide 2>/dev/null || \
      kubectl_cmd get pod "${pending[@]}" 2>/dev/null || true

    local -a still_pending=()
    for pod in "${pending[@]}"; do
      if ! kubectl_cmd get pod "$pod" >/dev/null 2>&1; then
        echo "警告: ${pod} 不存在（可能创建失败），跳过等待"
        failed_pods+=("$pod")
        continue
      fi

      # READY / STATUS 来自默认列；phase/reason 作补充
      line=$(kubectl_cmd get pod "$pod" --no-headers 2>/dev/null || true)
      ready=$(awk '{print $2}' <<< "$line")
      status=$(awk '{print $3}' <<< "$line")
      reason=$(kubectl_cmd get pod "$pod" -o jsonpath='{.status.reason}' 2>/dev/null || true)
      [[ -z "$reason" ]] && reason=$(kubectl_cmd get pod "$pod" \
        -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)

      # Ready: 所有容器 Ready（如 2/2）且 STATUS=Running
      if [[ "$ready" =~ ^([0-9]+)/([0-9]+)$ ]] && (( BASH_REMATCH[1] == BASH_REMATCH[2] && BASH_REMATCH[2] > 0 )) \
         && [[ "$status" == "Running" ]]; then
        echo "  ✓ ${pod} Ready (${ready} ${status})"
        ready_pods+=("$pod")
        continue
      fi

      # Fail-fast：调度/镜像/崩溃类终态不必空等满 timeout
      if [[ "$status" =~ ^(${fail_pat})$ ]] || [[ "$reason" =~ ^(${fail_pat})$ ]]; then
        echo "错误: ${pod} 进入失败状态 STATUS=${status} reason=${reason:-n/a} READY=${ready}"
        echo "  请检查: kubectl --kubeconfig=${KCFG} -n ${NS} describe pod ${pod} | tail -40"
        failed_pods+=("$pod")
        continue
      fi

      still_pending+=("$pod")
    done

    pending=("${still_pending[@]}")
    if (( ${#pending[@]} == 0 )); then
      break
    fi

    # 睡到下次轮询，但不超过 deadline
    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )); then
      break
    fi
    if (( poll_s < remaining )); then
      sleep "$poll_s"
    else
      sleep "$remaining"
    fi
  done

  echo ""
  if (( ${#pending[@]} > 0 )); then
    echo "警告: 超时 ${timeout_s}s 后仍未 Ready 的 Pod:"
    # shellcheck disable=SC2086
    kubectl_cmd get pod "${pending[@]}" -o wide 2>/dev/null || true
    for pod in "${pending[@]}"; do
      echo "  → kubectl --kubeconfig=${KCFG} -n ${NS} describe pod ${pod} | tail -40"
    done
  fi
  if (( ${#failed_pods[@]} > 0 )); then
    echo "警告: 快速失败（OutOfcpu/CrashLoop 等）的 Pod: ${failed_pods[*]}"
    for pod in "${failed_pods[@]}"; do
      echo "  → kubectl --kubeconfig=${KCFG} -n ${NS} describe pod ${pod} | tail -40"
    done
  fi
  if (( ${#pending[@]} == 0 && ${#failed_pods[@]} == 0 )); then
    echo "全部新建 Pod 已 Ready（${#ready_pods[@]} 个）。"
  fi
}

create_pod() {
  local global_idx="$1"
  local pod_name="$2"
  local node="$3"
  local numa_token="${4:-}"
  local numa_id="${5:-}"
  local cpuset="${6:-}"
  local yaml_file="prox-pod-auto-${pod_name}.yaml"

  sed -e "s/^  name: .*/  name: ${pod_name}/" \
      -e "s/^  nodeName: .*/  nodeName: ${node}/" \
      "$TEMPLATE" > "$yaml_file"

  if [[ -n "$NUMA_SPEC" ]]; then
    inject_numa_into_yaml "$yaml_file" "$numa_id" "$cpuset"
    # 设计取舍：NUMA 路径改动前从不改写内存（完全沿用模板默认值），与非 NUMA 路径
    # 强制 32Gi 的行为并不一致。为了不改变"省略 --mem"时的既有行为（用户可能依赖
    # 模板当前的默认内存值，其未必等于 32Gi），这里选择仅在用户显式传了 --mem 时
    # 才调用 enforce_app_memory_limit 覆盖 app 内存；未传 --mem 时不调用，
    # 与改动前完全一致。若未来需要"NUMA 也默认强制 32Gi"，可将下面的判断改为
    # 始终调用 enforce_app_memory_limit "$yaml_file" "$EFFECTIVE_MEM_NONUMA"。
    if [[ -n "$APP_MEM" ]]; then
      enforce_app_memory_limit "$yaml_file" "$APP_MEM"
    fi
  else
    # 整机共享 + quota 限制模式：去掉一切 cpuset/内存节点绑定，
    # 只靠 resources.limits（cpu=cpu_com 的 cfs quota + memory cgroup 限流）
    # --mem 显式指定时覆盖默认 32Gi（NONUMA_MEM_LIMIT），省略则行为不变
    strip_numa_pinning_from_yaml "$yaml_file"
    enforce_app_memory_limit "$yaml_file" "$EFFECTIVE_MEM_NONUMA"
  fi

  if [[ -n "$CPU_CORES" ]]; then
    inject_cpu_into_yaml "$yaml_file" "$CPU_CORES"
    # hulk-init 按 HULK_CORE/HULK_CORE_NUM 写 CPU cgroup；必须与 cpu_com 一致，
    # 否则模板残留 32 核会使实际用量超过 k8s limits.cpu
    inject_hulk_core_into_yaml "$yaml_file" "$CPU_CORES"
    if [[ -z "$NUMA_SPEC" ]]; then
      # 无 NUMA：保持 request=limit 整数（k8s CFS still N 核）。不降成 15900m Burstable。
      # 通过宿主机自定义 cgroup 把进程迁出 kubelet 独占 cpuset，同时用独立 cpu quota 卡 N 核。
      ensure_app_host_cgroup_mounts "$yaml_file"
      ensure_app_hulk_cpu_cgroup_mount "$yaml_file"
    fi
  fi

  # app_version=1.8：在 apply 前改写第一个 container 的 image（须在其它 mutating 之后也可，但放在 apply 前即可）
  if [[ "$APP_VERSION" == "1.8" ]]; then
    inject_app_image_into_yaml "$yaml_file" "$APP_IMAGE_V18"
    if ! grep -qF "image: ${APP_IMAGE_V18}" "$yaml_file"; then
      echo "错误: app_version=1.8 但未能改写 ${yaml_file} 中 app 容器 image -> ${APP_IMAGE_V18}" >&2
      echo "      请检查模板 containers/image 缩进是否异常" >&2
      exit 1
    fi
  fi

  if [[ -n "$EVENT_LOOPS" ]]; then
    inject_event_loop_into_yaml "$yaml_file" "$EVENT_LOOPS"
  elif [[ -n "$CPU_CORES" ]]; then
    # 与 --update-jvm 无关：只要有 cpu_com，JVM 就按 N 核感知，避免看到整机 128 核
    # 把 GC/线程池拉到 20 核（2000%）以上。event_loop 已含 ActiveProcessorCount，勿重复注入。
    inject_java_tool_options "$yaml_file" "-XX:ActiveProcessorCount=${CPU_CORES}"
  fi

  if [[ -n "$JAVA_PATH" ]]; then
    inject_java_path_into_yaml "$yaml_file" "$JAVA_PATH"
  elif (( UPDATE_JVM )); then
    inject_update_jvm_into_yaml "$yaml_file"
  elif [[ -n "$CPU_CORES" ]]; then
    # 无 java_path / --update-jvm 时也要包装 entrypoint，才能在启动时写入 cfs quota
    inject_app_entrypoint_wrap "$yaml_file" "" "" 0
  fi

  if [[ -z "$NUMA_SPEC" && -n "$CPU_CORES" ]]; then
    if ! grep -qE "name:[[:space:]]*host-cgroup-cpuset" "$yaml_file"; then
      echo "错误: ${yaml_file} 未注入 host-cgroup-cpuset（/sys/fs/cgroup/cpuset）。" >&2
      echo "      请检查模板 containers/volumeMounts 缩进" >&2
      exit 1
    fi
    if ! grep -q "mqs_full_cpuset" "$yaml_file"; then
      echo "错误: ${yaml_file} 的 app command/args 未包含 mqs_full_cpuset 启动脚本。" >&2
      echo "      模板第一个 container 可能不是以 list item 开头，entrypoint 包装失败" >&2
      exit 1
    fi
    echo "  已注入 host-cgroup-cpuset/cpu + 启动建 /sys/fs/cgroup/cpuset/mqs_full_cpuset"
  fi

  local info="  [#${global_idx}] apply ${pod_name} -> ${node}"
  if [[ -n "$NUMA_SPEC" ]]; then
    info+=", NUMA node${numa_id} cpuset=${cpuset}"
  else
    info+=", 整机共享(不绑cpuset)"
  fi
  [[ -n "$CPU_CORES" ]] && info+=", app_cpu=${CPU_CORES}核"
  if [[ -n "$APP_MEM" ]]; then
    info+=", app_mem=${APP_MEM}(--mem)"
  elif [[ -z "$NUMA_SPEC" ]]; then
    info+=", app_mem=${NONUMA_MEM_LIMIT}(默认)"
  fi
  [[ -n "$EVENT_LOOPS" ]] && info+=", event_loop=${EVENT_LOOPS}"
  [[ -n "$JAVA_PATH" ]] && info+=", java_path=${JAVA_PATH}"
  (( UPDATE_JVM )) && info+=", update_jvm=1"
  if [[ "$APP_VERSION" == "1.8" ]]; then
    info+=", app_version=1.8 -> image=${APP_IMAGE_V18}"
  elif [[ "$APP_VERSION" == "1.6" ]]; then
    info+=", app_version=1.6"
  fi
  echo "$info"
  kubectl_cmd apply -f "$yaml_file"
}

# ---------------------------------------------------------------------------
# 解析 Node 列表
# ---------------------------------------------------------------------------
declare -a NODE_TOKENS=()
declare -a NODES=()
declare -a NODE_LABELS=()

while IFS= read -r token; do
  NODE_TOKENS+=("$token")
  resolved=$(resolve_node_name "$token")
  NODES+=("$resolved")
  NODE_LABELS+=("$(node_short_label "$resolved")")
done < <(parse_list "$NODE_SPEC")

num_nodes=${#NODES[@]}
(( num_nodes > 0 )) || { echo "错误: node 列表为空: ${NODE_SPEC}"; exit 1; }

# ---------------------------------------------------------------------------
# 解析 NUMA 列表
# ---------------------------------------------------------------------------
declare -a NUMA_TOKENS=()
declare -a NUMA_IDS=()
num_numas=0

if [[ -n "$NUMA_SPEC" ]]; then
  discover_os_numa_topology || exit 1
  while IFS= read -r token; do
    NUMA_TOKENS+=("$token")
    nid=$(extract_numa_id "$token")
    get_os_numa_cpuset "$nid" >/dev/null || exit 1
    NUMA_IDS+=("$nid")
  done < <(parse_list "$NUMA_SPEC")
  num_numas=${#NUMA_TOKENS[@]}
  (( num_numas > 0 )) || { echo "错误: numa 列表为空: ${NUMA_SPEC}"; exit 1; }
fi

# ---------------------------------------------------------------------------
# NUMA 与 cpu_com 校验（须在 NUMA 列表解析之后、创建循环之前）
# cpu_com 省略 → 整 NUMA；cpu_com=N ≤ NUMA 核数 → 取 cpuset 前 N 核子集
# ---------------------------------------------------------------------------
CPU_CORES_AUTO_SET=0
if [[ -n "$NUMA_SPEC" ]]; then
  numa_expected_cpus=""
  numa_example_cpuset=""
  for nid in "${NUMA_IDS[@]}"; do
    cs=$(get_os_numa_cpuset "$nid")
    sz=$(count_cpus_in_cpuset "$cs") || exit 1
    if [[ -z "$numa_expected_cpus" ]]; then
      numa_expected_cpus="$sz"
      numa_example_cpuset="$cs"
    elif [[ "$numa_expected_cpus" -ne "$sz" ]]; then
      echo "错误: NUMA 列表中各节点 CPU 数不一致（期望 ${numa_expected_cpus}，但 NUMA node${nid} cpuset=${cs} 为 ${sz} 核）"
      exit 1
    fi
  done

  if [[ -z "$CPU_CORES" ]]; then
    CPU_CORES="$numa_expected_cpus"
    CPU_CORES_AUTO_SET=1
    echo "提示: 指定了 NUMA 绑定且未设 cpu_com，已自动设为 cpu_com=${CPU_CORES}（整 NUMA cpuset，如 ${numa_example_cpuset}）"
  elif [[ "$CPU_CORES" -gt "$numa_expected_cpus" ]]; then
    echo "错误: cpu_com=${CPU_CORES} 超过 NUMA 可用核数 ${numa_expected_cpus}（如 ${numa_example_cpuset}）"
    echo "  - 整 NUMA 绑定请用: cpu_com=${numa_expected_cpus} 或省略 cpu_com"
    echo "  - 子集绑定请用: cpu_com=N（1<=N<=${numa_expected_cpus}），如 cpu_com=16 numa1 → 取前 16 核"
    exit 1
  elif [[ "$CPU_CORES" -lt "$numa_expected_cpus" ]]; then
    subset_example=$(subset_cpuset "$numa_example_cpuset" "$CPU_CORES") || exit 1
    echo "提示: cpu_com=${CPU_CORES} < 整 NUMA ${numa_expected_cpus} 核，将取各 NUMA cpuset 前 ${CPU_CORES} 个 CPU"
    echo "      例: ${numa_example_cpuset} → ${subset_example}"
  fi
fi

# cpu_com 最终确定后再收紧 --update-jvm 的 GC 线程。
# 默认 ParallelGCThreads=20 在 16 核容器里会把用量顶到约 2000%；
# 有 cpu_com 时改为 Parallel=cpu_com、Conc=max(1, cpu_com/4)。
if (( UPDATE_JVM )) && [[ -n "$CPU_CORES" ]]; then
  _pgc="$CPU_CORES"
  _cgc=$(( CPU_CORES / 4 ))
  (( _cgc < 1 )) && _cgc=1
  UPDATE_JVM_FLAGS="-XX:InitialRAMPercentage=75.0 -XX:MaxRAMPercentage=75.0 -XX:ParallelGCThreads=${_pgc} -XX:ConcGCThreads=${_cgc} -XX:MaxGCPauseMillis=50 -XX:+UseNUMA -Xlog:gc*=info:file=/opt/logs/mqs/gc.log:time,uptime,level,tags:filecount=5,filesize=50M"
  unset _pgc _cgc
fi

# ---------------------------------------------------------------------------
# 打印配置概览
# ---------------------------------------------------------------------------
echo "===== MQS Proxy Pod 创建器 ====="
case "$MODE" in
  del)  echo "  模式: del（删除指定 node 列表上的 proxy Pod，重建 ${COUNT} 个）" ;;
  plus) echo "  模式: plus（在现有 Pod 基础上额外追加 ${COUNT} 个）" ;;
  add)  echo "  模式: add（增量：补足到目标总数 ${COUNT} 个）" ;;
esac
if [[ -n "$NUMA_SPEC" ]]; then
  echo "  绑定模式: NUMA 绑定模式（cpuset + 内存节点绑定，注入 ${NUMA_CPUSET_ENV_NAME} 等）"
  if [[ -n "$APP_MEM" ]]; then
    echo "           内存: app=${APP_MEM}（--mem 显式覆盖，与 NUMA 绑定相互独立）"
  else
    echo "           内存: 保持模板默认值（未指定 --mem，NUMA 路径不改写内存）"
  fi
else
  echo "  绑定模式: 整机共享+quota 限制模式"
  echo "           无 numa 参数时：不绑定 cpuset/内存节点，容器可用整机所有 CPU 和内存，"
  if [[ -n "$CPU_CORES" ]]; then
    echo "           app requests.cpu=limits.cpu=${CPU_CORES}（整数）→ QoS Guaranteed；"
    echo "           自定义 cgroup /sys/fs/cgroup/cpuset/mqs_full_cpuset = 整机 CPU，"
    echo "           /sys/fs/cgroup/cpu/mqs_quota_<pod> CFS quota=${CPU_CORES} 核；内存 ${EFFECTIVE_MEM_NONUMA}"
  else
    echo "           CPU quota 保持模板原值（未指定 cpu_com），内存严格限制 ${EFFECTIVE_MEM_NONUMA}"
  fi
  [[ -n "$APP_MEM" ]] && echo "           （内存 ${EFFECTIVE_MEM_NONUMA} 来自 --mem 显式覆盖；默认为 ${NONUMA_MEM_LIMIT}）"
fi
if [[ -n "$CPU_CORES" ]]; then
  if (( CPU_CORES_AUTO_SET )); then
    echo "  CPU核数: app=${CPU_CORES} 核（NUMA 默认自动设置；仅改 app 容器，sidecar 保持模板）"
  else
    echo "  CPU核数: app=${CPU_CORES} 核（仅覆盖 app 容器；sidecar/init 保持模板原值）"
  fi
  echo "           总 Pod CPU request ≈ app + sidecar（如 ${CPU_CORES}+1），Guaranteed 准入按总和计"
else
  echo "  CPU核数: 保持模板原值"
fi
[[ -n "$EVENT_LOOPS" ]] && echo "  EventLoop: ${EVENT_LOOPS}（JAVA_TOOL_OPTIONS + ActiveProcessorCount=${EVENT_LOOPS}）"
if [[ -n "$JAVA_PATH" ]]; then
  normalize_java_path "$JAVA_PATH"
  echo "  Java路径: ${JAVA_PATH}"
  echo "           hostPath ${JAVA_HOME_RESOLVED} -> /opt/custom-jdk"
  case "${MQS_JDK_OVERLAY:-true}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "           mjdk overlay: OFF (MQS_JDK_OVERLAY=false)"
      ;;
    *)
      echo "           + overlay -> ${MQS_JDK_OVERLAY_PATH:-/usr/local/mjdk-8.0.0-312} (MQS_JDK_OVERLAY=true)"
      ;;
  esac
  echo "           JAVA_HOME=/opt/custom-jdk  PATH前置=/opt/custom-jdk/bin"
  if (( UPDATE_JVM )); then
    echo "           + update_jvm: JAVA_HOME=/tmp/jdk-wrap REAL_JAVA=/opt/custom-jdk"
  else
    echo "           command: [/bin/sh, -c]  args: 'export JAVA_HOME=...; mkdir -p /opt/logs/mqs; chmod 777 /opt/logs/mqs; touch /opt/logs/mqs/gc.log; exec mqs proxy'"
  fi
fi
if (( UPDATE_JVM )); then
  echo "  update_jvm: ON（/tmp/jdk-wrap 把 flags 插到主类名之前，覆盖 mqs 硬编码 PROXY GC）"
  if [[ -n "$JAVA_PATH" ]]; then
    echo "           REAL_JAVA=/opt/custom-jdk"
  else
    echo "           REAL_JAVA=${DEFAULT_MJDK_HOME}"
  fi
  echo "           flags: ${UPDATE_JVM_FLAGS}"
  echo "           可选未注入: -XX:MaxDirectMemorySize=2g"
fi
if [[ "$APP_VERSION" == "1.8" ]]; then
  echo "  app_version: 1.8 -> image=${APP_IMAGE_V18}"
elif [[ "$APP_VERSION" == "1.6" ]]; then
  echo "  app_version: 1.6（保持模板默认 app 镜像）"
else
  echo "  app_version: 未指定（默认 1.6 / 保持模板默认 app 镜像）"
fi
echo ""

echo "===== Node 列表 (${num_nodes} 个) ====="
for i in "${!NODES[@]}"; do
  echo "  node${i}: ${NODE_TOKENS[$i]} -> ${NODES[$i]}"
done
echo ""

if [[ -n "$NUMA_SPEC" ]]; then
  echo "===== OS NUMA -> CPUSET 映射表（本机 live）====="
  for i in "${DISCOVERED_NUMA_IDS[@]}"; do
    echo "  NUMA node${i} CPU(s): $(get_os_numa_cpuset "$i")"
  done
  echo ""
  echo "===== NUMA 参数列表 (${num_numas} 个；按本次批次序号：先填各 node 同 NUMA，再换下一 NUMA) ====="
  for i in "${!NUMA_TOKENS[@]}"; do
    nid="${NUMA_IDS[$i]}"
    full_cs=$(get_os_numa_cpuset "$nid")
    if [[ -n "$CPU_CORES" ]]; then
      sub_cs=$(subset_cpuset "$full_cs" "$CPU_CORES") || exit 1
      if [[ "$sub_cs" == "$full_cs" ]]; then
        echo "  列表[${i}]: ${NUMA_TOKENS[$i]} -> OS node${nid} cpuset=${full_cs} (${numa_expected_cpus} 核，整 NUMA)"
      else
        echo "  列表[${i}]: ${NUMA_TOKENS[$i]} -> OS node${nid} full=${full_cs} subset=${sub_cs} (cpu_com=${CPU_CORES})"
      fi
    else
      echo "  列表[${i}]: ${NUMA_TOKENS[$i]} -> OS node${nid} cpuset=${full_cs}"
    fi
  done
  echo ""
fi

# ---------------------------------------------------------------------------
# 模式分支执行
# ---------------------------------------------------------------------------
total_current=$(kubectl_cmd get pods -l "$LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l)
total_current=${total_current// /}
echo "当前 proxy 总数: ${total_current}"

# 计算本次实际创建的起始序号和终止序号
case "$MODE" in
  del)
    # NODES[] 已在上方解析完成，此处仅删这些 node 上的 proxy
    delete_proxy_pods_on_nodes
    START_K=1
    END_K=$COUNT
    TOTAL=$COUNT
    ;;
  plus)
    START_K=$((total_current + 1))
    END_K=$((total_current + COUNT))
    TOTAL=$END_K
    ;;
  add)
    TOTAL=$COUNT
    if (( total_current >= TOTAL )); then
      echo "已达或超过目标 ${TOTAL}，无需创建。"
      if (( total_current > TOTAL )); then
        echo "提示: 当前 ${total_current} > 目标 ${TOTAL}，可用 'del ${TOTAL}' 删后重建，或 'plus N' 继续追加。"
      fi
      START_K=$((TOTAL + 1))
      END_K=$TOTAL
    else
      START_K=$((total_current + 1))
      END_K=$TOTAL
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 绑定计划预览
# ---------------------------------------------------------------------------
if (( END_K >= START_K )); then
  CREATE_COUNT=$((END_K - START_K + 1))
  echo "本次将创建: ${CREATE_COUNT} 个（序号 #${START_K} ~ #${END_K}）"
  echo ""
  echo "===== 绑定计划 ====="
  for ((k = START_K; k <= END_K; k++)); do
    if (( CREATE_COUNT > 15 && k > START_K + 4 && k <= END_K - 5 )); then
      (( k == START_K + 5 )) && echo "  ..."
      continue
    fi
    # 绑核按本次批次内序号，与 del/plus/add 无关；k 仅作全局命名序号
    assign_k=$((k - START_K + 1))
    nidx=$(node_index_for_pod "$assign_k")
    line="  Pod #${k} -> node${nidx}(${NODE_LABELS[$nidx]})"
    if [[ -n "$NUMA_SPEC" ]]; then
      numa_info_for_pod "$assign_k"
      line+=", NUMA node${NUMA_ID_FOR_POD} cpuset=${NUMA_CPUSET_FOR_POD}"
    else
      line+=", 整机共享(不绑cpuset)"
    fi
    [[ -n "$CPU_CORES" ]] && line+=", app_cpu=${CPU_CORES}核"
    if [[ -n "$APP_MEM" ]]; then
      line+=", app_mem=${APP_MEM}"
    elif [[ -z "$NUMA_SPEC" ]]; then
      line+=", app_mem=${NONUMA_MEM_LIMIT}"
    fi
    [[ -n "$EVENT_LOOPS" ]] && line+=", event_loop=${EVENT_LOOPS}"
    [[ -n "$JAVA_PATH" ]] && line+=", java_path=${JAVA_PATH}"
    (( UPDATE_JVM )) && line+=", update_jvm=1"
    if [[ "$APP_VERSION" == "1.8" ]]; then
      line+=", app_version=1.8 -> image=${APP_IMAGE_V18}"
    elif [[ "$APP_VERSION" == "1.6" ]]; then
      line+=", app_version=1.6"
    fi
    echo "$line"
  done
  echo ""

  # 同一 (物理节点, NUMA) 上多个 Pod 会请求同一 HULK_CPUSET；
  # 当 cpu_com >= 整 NUMA 核数时，每槽位最多 1 个 Guaranteed Pod，多余的易 OutOfcpu。
  if [[ -n "$NUMA_SPEC" ]]; then
    declare -A _pair_count=()
    declare -A _pair_label=()
    declare -A _pair_numa=()
    for ((k = START_K; k <= END_K; k++)); do
      assign_k=$((k - START_K + 1))
      nidx=$(node_index_for_pod "$assign_k")
      numa_info_for_pod "$assign_k"
      _key="${nidx}:${NUMA_ID_FOR_POD}"
      _pair_count[$_key]=$(( ${_pair_count[$_key]:-0} + 1 ))
      _pair_label[$_key]="${NODE_LABELS[$nidx]}"
      _pair_numa[$_key]="$NUMA_ID_FOR_POD"
    done
    for _key in "${!_pair_count[@]}"; do
      _cnt="${_pair_count[$_key]}"
      if (( _cnt > 1 )); then
        _nid="${_pair_numa[$_key]}"
        _nsz=$(count_cpus_in_cpuset "$(get_os_numa_cpuset "$_nid")") || _nsz="?"
        if [[ -n "$CPU_CORES" && "$CPU_CORES" -ge "${numa_expected_cpus:-0}" ]]; then
          echo "警告: node ${_pair_label[$_key]} 上有 ${_cnt} 个 Pod 绑定同一 NUMA node${_nid}（仅 ${_nsz} 核），cpu_com=${CPU_CORES} 时最多只能跑 1 个 Guaranteed Pod，其余很可能 OutOfcpu"
        else
          echo "警告: node ${_pair_label[$_key]} 上有 ${_cnt} 个 Pod 绑定同一 NUMA node${_nid}（cpuset 相同），可能争用同一批独占核导致 OutOfcpu"
        fi
      fi
    done
    # 若上面打印过警告，空一行分隔
    for _key in "${!_pair_count[@]}"; do
      if (( ${_pair_count[$_key]:-0} > 1 )); then
        echo ""
        break
      fi
    done
    unset _pair_count _pair_label _pair_numa _key _cnt _nid _nsz
  fi
fi

# ---------------------------------------------------------------------------
# 实际创建
# ---------------------------------------------------------------------------
declare -a NEW_PODS=()

if (( END_K >= START_K )); then
  echo "===== 开始创建 Pod #${START_K} ~ #${END_K} ====="
  for ((k = START_K; k <= END_K; k++)); do
    # 绑核按本次批次内序号；全局 k 只用于 Pod 名
    assign_k=$((k - START_K + 1))
    nidx=$(node_index_for_pod "$assign_k")
    node="${NODES[$nidx]}"
    label="${NODE_LABELS[$nidx]}"

    numa_token=""
    numa_id=""
    cpuset=""
    if [[ -n "$NUMA_SPEC" ]]; then
      numa_info_for_pod "$assign_k"
      numa_token="$NUMA_TOKEN_FOR_POD"
      numa_id="$NUMA_ID_FOR_POD"
      cpuset="$NUMA_CPUSET_FOR_POD"
    fi

    pod_name="proxy-cnhl-default-auto-${label}-$(printf '%04d' "$k")"
    if [[ -n "$NUMA_SPEC" ]]; then
      pod_name="proxy-cnhl-default-auto-${label}-n${numa_id}-$(printf '%04d' "$k")"
    fi

    while pod_exists "$pod_name"; do
      pod_name="${pod_name}-x"
    done

    create_pod "$k" "$pod_name" "$node" "$numa_token" "$numa_id" "$cpuset"
    NEW_PODS+=("$pod_name")
  done

  echo ""
  wait_new_pods_ready 300
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo ""
echo "===== 各 Node 当前 Pod 分布 ====="
for i in "${!NODES[@]}"; do
  cnt=$(kubectl_cmd get pods -l "$LABEL_SELECTOR" \
    --field-selector "spec.nodeName=${NODES[$i]}" --no-headers 2>/dev/null | wc -l)
  cnt=${cnt// /}
  echo "--- node${i} ${NODE_LABELS[$i]} (${NODES[$i]}) : ${cnt} 个 ---"
  kubectl_cmd get pods -o wide -l "$LABEL_SELECTOR" \
    --field-selector "spec.nodeName=${NODES[$i]}"
  echo ""
done

if [[ -n "$NUMA_SPEC" ]]; then
  echo "===== 运行模式: NUMA 绑定模式 ====="
  echo "===== Pod 注入的 NUMA / CPUSET 配置 ====="
  echo "  env: ${NUMA_ENV_NAME}=<0-7>"
  echo "  env: ${NUMA_CPUSET_ENV_NAME}=<cpuset 子集或整 NUMA，如 0-15 或 0-15,128-143>"
  echo "  annotation: ${NUMA_ANNOTATION_KEY}, ${NUMA_CPUSET_ANNOTATION_KEY}"
  if [[ -n "$CPU_CORES" && -n "${numa_expected_cpus:-}" && "$CPU_CORES" -lt "$numa_expected_cpus" ]]; then
    echo "  cpu_com=${CPU_CORES}: 注入的是各 NUMA OS cpuset 的前 ${CPU_CORES} 核子集（非整 NUMA）"
  fi
  if [[ -n "$APP_MEM" ]]; then
    echo "  app 内存: limits/requests.memory=${APP_MEM}（--mem 显式覆盖，仅 app 容器，与 NUMA 绑定无关）"
  else
    echo "  app 内存: 保持模板 ${TEMPLATE} 默认值（未指定 --mem，NUMA 路径不改写内存）"
  fi
  echo "  NUMA 拓扑来自本机 live OS（SMT on/off 会改变每 NUMA 核数）；舰队节点拓扑须一致"
  echo "  若 Hulk 字段名不同，请 export NUMA_ENV_NAME / NUMA_CPUSET_ENV_NAME 等后重跑"
  echo ""
else
  echo "===== 运行模式: 整机共享+quota 限制模式（无 numa 参数）====="
  echo "  不绑定 cpuset/内存节点：已清除 ${NUMA_CPUSET_ENV_NAME}/${NUMA_ENV_NAME} env 及对应 annotation"
  echo "  容器可用整机所有 CPU 和所有 NUMA 内存节点"
  if [[ -n "$CPU_CORES" ]]; then
    echo "  app requests.cpu = limits.cpu = ${CPU_CORES}（整数）→ Pod QoS=Guaranteed"
    echo "  启动后把进程迁到 kubelet 不管的自定义 cgroup："
    echo "    cpuset: /sys/fs/cgroup/cpuset/mqs_full_cpuset （online 全核，taskset 应为整机）"
    echo "    cpu:    /sys/fs/cgroup/cpu/mqs_quota_<pod>     （CFS quota=${CPU_CORES} 核，上限 ${CPU_CORES}00%）"
    echo "  内存/pids 仍留在 kubelet cgroup（cgroup v1 控制器独立）"
    echo "  HULK_CORE/HULK_CORE_NUM=${CPU_CORES}；总 Pod CPU request ≈ app + sidecar（如 ${CPU_CORES}+1）"
  else
    echo "  CPU quota 保持模板原值（未指定 cpu_com）"
  fi
  if [[ -n "$APP_MEM" ]]; then
    echo "  内存由 memory cgroup 严格限制 resources.limits.memory=${APP_MEM}（--mem 显式覆盖，默认为 ${NONUMA_MEM_LIMIT}）"
  else
    echo "  内存由 memory cgroup 严格限制 resources.limits.memory=${NONUMA_MEM_LIMIT}（默认，未指定 --mem）"
  fi
  echo "  验证: cat /host-cgroup/cpuset/mqs_full_cpuset/cpuset.cpus   # 整机 online CPU"
  echo "        cat /host-cgroup/cpu/mqs_quota_\$HOSTNAME/cpu.cfs_quota_us  # 应=cpu_com*100000"
  echo "        taskset -cp <java-pid>   # 应接近整机，而不是连续 ${CPU_CORES:-N} 核"
  echo "        cat /proc/<pid>/cgroup | grep cpuset   # 应含 mqs_full_cpuset，不是 kubepods 独占核"
  echo ""
  echo "  ----- 自定义 cgroup 验证 -----"
  echo "  # QoS 仍为 Guaranteed（k8s 侧 limit=request）；绑核靠自定义 cpuset 解开"
  echo "  kubectl --kubeconfig=${KCFG} -n ${NS} get pod <pod> -o jsonpath='{.status.qosClass}'"
  echo "  # 宿主机："
  echo "  cat /sys/fs/cgroup/cpuset/mqs_full_cpuset/cpuset.cpus"
  echo "  cat /sys/fs/cgroup/cpuset/mqs_full_cpuset/cgroup.procs"
  echo "  cat /sys/fs/cgroup/cpu/mqs_quota_<pod>/cpu.cfs_quota_us"
  echo "  taskset -cp <pid>"
  echo "  # 确认 hulk 核数（应为 cpu_com，不是模板 32）："
  echo "  printenv HULK_CORE HULK_CORE_NUM"
  echo ""
fi

if [[ -n "$CPU_CORES" ]]; then
  echo "===== CPU 算力配置（仅 app 容器；sidecar 保持模板）====="
  echo "  app resources.limits.cpu   = ${CPU_CORES}"
  echo "  app/init HULK_CORE         = ${CPU_CORES}（同步 HULK_CORE_NUM，hulk cgroup 按此严格限核）"
  echo "  与 --update-jvm 无关：只要 cpu_com=${CPU_CORES} 就会限核；未指定 event_loop 时还会注入 -XX:ActiveProcessorCount=${CPU_CORES}"
  if [[ -z "$NUMA_SPEC" ]]; then
    echo "  app resources.requests.cpu = ${CPU_CORES}（与 limits 相同；整机 cpuset 靠自定义 cgroup，不靠 Burstable）"
  else
    echo "  app resources.requests.cpu = ${CPU_CORES}（与 limits 相同 → Guaranteed 的 CPU 部分）"
  fi
  echo "  sidecar/init CPU：保持模板原值（通常 1 或 100m），不随 cpu_com 改写"
  echo "  总 Pod CPU request ≈ app + sidecar（如 ${CPU_CORES}+1），Guaranteed 准入按总和计"
  echo "  若需 limits/requests 不同，请手动修改生成的 prox-pod-auto-*.yaml"
  echo ""
fi

echo "===== 内存配置（仅 app 容器；sidecar/init 保持模板原值）====="
if [[ -n "$APP_MEM" ]]; then
  echo "  app resources.limits.memory   = ${APP_MEM}（--mem 显式覆盖）"
  echo "  app resources.requests.memory = ${APP_MEM}"
elif [[ -z "$NUMA_SPEC" ]]; then
  echo "  app resources.limits.memory   = ${NONUMA_MEM_LIMIT}（默认；无 NUMA 时强制限制）"
  echo "  app resources.requests.memory = ${NONUMA_MEM_LIMIT}"
else
  echo "  保持模板 ${TEMPLATE} 默认值（有 NUMA 且未指定 --mem，不改写内存）"
fi
echo "  自定义: --mem <值>（如 --mem 16G，等价 16Gi）或 mem=<值>"
echo ""

if [[ -n "$EVENT_LOOPS" ]]; then
  echo "===== EventLoop 配置 ====="
  echo "  JAVA_TOOL_OPTIONS = -Dio.grpc.netty.shaded.io.netty.eventLoopThreads=${EVENT_LOOPS}"
  echo "                      -Dio.netty.eventLoopThreads=${EVENT_LOOPS}"
  echo "                      -XX:ActiveProcessorCount=${EVENT_LOOPS}"
  echo "  验证: ps -L -p \$(pgrep -f MqsProxyApplication | head -1) -o comm | grep -c grpc-nio  # 期望 ~${EVENT_LOOPS}~$((EVENT_LOOPS + 1))"
  echo ""
fi

if [[ -n "$JAVA_PATH" ]]; then
  normalize_java_path "$JAVA_PATH"
  echo "===== Java 路径配置（hostPath + entrypoint 包装）====="
  echo "  输入:           ${JAVA_PATH}"
  echo "  宿主机路径:     ${JAVA_HOME_RESOLVED}"
  echo "  volume:         custom-jdk (hostPath, type \"\")"
  echo "  容器挂载点:     /opt/custom-jdk"
  case "${MQS_JDK_OVERLAY:-true}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      echo "  mjdk overlay:   OFF（若需 mqs 硬编码路径生效，设 MQS_JDK_OVERLAY=true）"
      ;;
    *)
      echo "  mjdk overlay:   ${MQS_JDK_OVERLAY_PATH:-/usr/local/mjdk-8.0.0-312}"
      echo "                  （CrashLoop 时可 MQS_JDK_OVERLAY=false 重试）"
      ;;
  esac
  echo "  JAVA_HOME:      /opt/custom-jdk"
  echo "  PATH 前置:      /opt/custom-jdk/bin"
  echo "  entrypoint:     command: [/bin/sh, -c]"
  if (( UPDATE_JVM )); then
    echo "                  + /tmp/jdk-wrap（REAL_JAVA=/opt/custom-jdk）覆盖 mqs 硬编码 GC"
  else
    echo "                  args: ['export JAVA_HOME=...; export PATH=\$JAVA_HOME/bin:\$PATH; mkdir -p /opt/logs/mqs; chmod 777 /opt/logs/mqs; touch /opt/logs/mqs/gc.log; exec mqs proxy']"
  fi
  echo "  说明: mqs 脚本硬编码 mjdk 路径；仅改 PATH 通常无效，故默认 overlay"
  echo "  验证:"
  echo "    ls /opt/custom-jdk/bin/java"
  echo "    ls /usr/local/mjdk-8.0.0-312/bin/java   # overlay=true 时"
  echo "    echo \$JAVA_HOME; which java; java -version"
  echo "    tr '\\0' '\\n' < /proc/\$(pgrep -f MqsProxyApplication|head -1)/environ | grep -E 'JAVA|PATH'"
  echo "    ls -l /proc/\$(pgrep -f MqsProxyApplication|head -1)/exe"
  echo ""
fi

if (( UPDATE_JVM )); then
  echo "===== update_jvm（32G 高吞吐推荐 flags）====="
  if [[ -n "$JAVA_PATH" ]]; then
    echo "  REAL_JAVA:      /opt/custom-jdk"
  else
    echo "  REAL_JAVA:      ${DEFAULT_MJDK_HOME}"
  fi
  echo "  JAVA_HOME:      /tmp/jdk-wrap（wrapper 的 bin/java 插入 flags）"
  echo "  覆盖原理:     wrapper 扫描 \"\$@\"，把 flags 插到主类名（MqsProxyApplication）token 之前，"
  echo "                仍是合法 JVM 选项，后出现的 -XX:Foo=X 覆盖 mqs 硬编码的同名 flag"
  echo "  flags: ${UPDATE_JVM_FLAGS}"
  echo "  可选未注入:   -XX:MaxDirectMemorySize=2g"
  echo "  验证:"
  echo "    cat /tmp/jdk-wrap/bin/java   # 查看生成的 wrapper（base64 解码后的内容）"
  echo "    echo \$JAVA_HOME; which java"
  echo "    # 找到真正的 java 进程（PID 1 是 catatonit，不是 java）："
  echo "    PID=\$(pgrep -f 'java.*MqsProxyApplication' | grep -v '^1\$' | head -1)"
  echo "    tr '\\0' '\\n' < /proc/\$PID/cmdline | tr '\\n' ' '; echo"
  echo "    # flags 必须出现在 com.meituan.mqs.proxy.MqsProxyApplication 之前，而不是之后"
  echo "    jcmd \$PID VM.flags | grep -E 'InitialRAMPercentage|ParallelGCThreads|ConcGCThreads|MaxGCPauseMillis|UseNUMA'"
  echo "    # expect InitialRAMPercentage=75 ParallelGCThreads=20 ConcGCThreads=5 MaxGCPauseMillis=50 UseNUMA=true"
  echo ""
fi

echo "===== app_version / 镜像 ====="
if [[ "$APP_VERSION" == "1.8" ]]; then
  echo "  app_version: 1.8 -> image=${APP_IMAGE_V18}"
  echo "  sidecar/init 镜像保持模板原值（未改写）"
elif [[ "$APP_VERSION" == "1.6" ]]; then
  echo "  app_version: 1.6"
  echo "  app image:   保持模板默认（未改写）"
else
  echo "  app_version: 未指定（默认 1.6）"
  echo "  app image:   保持模板默认（未改写）"
fi
echo "  验证: kubectl --kubeconfig=${KCFG} -n ${NS} get pod <pod> -o jsonpath='{.spec.containers[0].image}'"
echo ""

final_total=$(kubectl_cmd get pods -l "$LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l)
final_total=${final_total// /} 
echo "===== 汇总: proxy 总数 ${final_total} / 目标 ${TOTAL} ====="
