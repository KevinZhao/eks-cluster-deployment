# EKS 集群部署脚本验证报告
# 日期: 2026-04-10
# 目标: 在 Oregon (us-west-2) 和 Ohio (us-east-2) 创建 EKS 集群，验证所有部署脚本

## 环境信息
- 执行环境: EC2 实例 (us-east-1 VPC, 非目标集群 VPC)
- K8s 版本: 1.35 (最新)
- Oregon VPC: vpc-081ea929da61b21d7 (10.0.0.0/16, 4 AZ: a,b,c,d)
- Ohio VPC: vpc-0bcb622cffd226d26 (10.1.0.0/16, 3 AZ: a,b,c)
- Oregon 集群名: gpu-cluster-oregon
- Ohio 集群名: gpu-cluster-ohio
- 节点实例类型: m7g.large (Graviton3, ARM64)

## 脚本执行结果总览

### Oregon (us-west-2) - gpu-cluster-oregon

| 脚本 | 状态 | 耗时 | 说明 |
|------|------|------|------|
| 1_enable_vpc_dns.sh | PASS | <10s | DNS 已在 VPC 创建时启用 |
| 3_create_vpc_endpoints.sh | PASS | ~60s | 13 interface + 1 gateway = 14 端点 |
| 4_install_eks_cluster.sh | PASS | ~12min | K8s 1.35, 4 AZ, 含 5 个 addon |
| option_create_bastion.sh | PASS | ~3min | t4g.micro, SSM 就绪, 工具安装 |
| 6_create_system_nodegroup.sh | PASS | ~7min | 2 节点 Ready, LVM 正常 |
| 7_install_eks_addon.sh | PASS | ~3min | CA + ALB Controller + Pod Identity |

### Ohio (us-east-2) - gpu-cluster-ohio

| 脚本 | 状态 | 耗时 | 说明 |
|------|------|------|------|
| 1_enable_vpc_dns.sh | PASS | <10s | DNS 已在 VPC 创建时启用 |
| 3_create_vpc_endpoints.sh | PASS | ~60s | 13 interface + 1 gateway = 14 端点 |
| 4_install_eks_cluster.sh | PASS | ~12min | K8s 1.35, 3 AZ, 含 5 个 addon |
| option_create_bastion.sh | PASS | ~3min | t4g.micro, SSM 就绪, 工具安装 |
| 6_create_system_nodegroup.sh | PASS | ~7min | 2 节点 Ready, LVM 正常 |
| 7_install_eks_addon.sh | PASS | ~3min | CA + ALB Controller + Pod Identity |

## 发现的问题

### BUG-1: [HIGH] option_create_bastion.sh - kubectl 安装可能损坏

**现象**: bastion 上安装的 kubectl 二进制文件损坏，运行时报 `Bus error (core dumped)`。
`file` 命令显示 `too large section header offset 54984704`。

**根因**: bastion 脚本 `option_create_bastion.sh` 行 391 使用 `curl -LO` 下载 kubectl，
但没有验证下载是否完整（无 SHA256 校验、无文件大小检查、无 curl 退出码检查）。
通过 NAT Gateway 从 dl.k8s.io 下载时可能因网络抖动导致截断。

**影响**: bastion 创建成功但 kubectl 不可用，后续脚本 6/7 无法执行。
SSM 命令安装日志显示 "Tools installed successfully" 但实际 kubectl 已损坏。

**建议修复**:
```bash
# 添加 SHA256 校验
curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/arm64/kubectl"
curl -LO "https://dl.k8s.io/release/v1.31.0/bin/linux/arm64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

### BUG-2: [MEDIUM] 6_create_system_nodegroup.sh - SSM 环境下 HOME 未设置

**现象**: 通过 SSM send-command 执行脚本 6 时，`KUBECONFIG` 设置为 `/.kube/config`
而非 `/root/.kube/config`，导致 `verify_kubectl_context()` 失败。

**根因**: 脚本 `6_create_system_nodegroup.sh` 行 33: `export KUBECONFIG="${HOME}/.kube/config"`
假设 `$HOME` 已设置。但在 SSM RunShellScript 环境中，`HOME` 可能为空字符串。

**影响**: 从 SSM 自动化执行时脚本失败。需手动 `export HOME=/root`。

**复现**: `aws ssm send-command --parameters 'commands=["bash scripts/6_create_system_nodegroup.sh"]'`

**建议修复**:
```bash
export KUBECONFIG="${HOME:-/root}/.kube/config"
```

### BUG-3: [LOW] 7_install_eks_addon.sh - Cluster Autoscaler 策略 WARN 级别不准确

**现象**: 脚本输出 `[WARN] AmazonEKSClusterAutoscalerPolicy not found, creating custom policy`

**说明**: `AmazonEKSClusterAutoscalerPolicy` 不是 AWS 托管策略（AWS 不提供此策略），
脚本设计就是回退到创建自定义策略。使用 WARN 级别容易误导用户认为出了问题。

**建议**: 改为 INFO 级别，或直接创建自定义策略而不先尝试查找不存在的托管策略。

### ISSUE-4: [INFO] 私有集群脚本 6/7 必须从 VPC 内部执行

**现象**: 从外部 VPC 执行脚本 6 时，`eksctl create nodegroup` 报错:
```
Get "https://...eks.amazonaws.com/api": dial tcp 10.0.13.77:443: i/o timeout
```

**说明**: 这是私有集群（publicAccess: false）的预期行为。脚本 6 正确检测了
Cross-VPC 模式并添加了 CIDR 安全组规则，但没有 VPC Peering/Transit Gateway
时仍无法到达私有 API endpoint。

**建议**: 在脚本 6 开头增加网络可达性检测:
```bash
# 检测是否能连接集群 API
timeout 5 curl -sk "${CLUSTER_ENDPOINT}/healthz" >/dev/null 2>&1 || {
    echo "ERROR: Cannot reach cluster API at ${CLUSTER_ENDPOINT}"
    echo "Private clusters require running this script from within the VPC"
    exit 1
}
```

### ISSUE-5: [INFO] 节点分布未覆盖所有 AZ

**现象**: Oregon 配置 4 AZ 但 2 个节点只分布在 2 个 AZ (us-west-2a: 10.0.11.x, us-west-2d: 10.0.14.x)。
Ohio 配置 3 AZ 但 2 个节点只分布在 2 个 AZ (us-east-2b: 10.1.12.x, us-east-2c: 10.1.13.x)。

**说明**: 这是 EKS 的正常行为。当 desiredCapacity (2) 小于 AZ 数量 (3 或 4) 时，
EKS 自动选择 AZ 子集。如需覆盖所有 AZ，需设置 desiredCapacity >= AZ_COUNT。

### ISSUE-6: [INFO] eksctl Auto Mode 即将默认启用警告

**现象**: eksctl 输出警告:
```
Auto Mode will be enabled by default in an upcoming release of eksctl.
This means managed node groups and managed networking add-ons will no longer
be created by default.
```

**说明**: 未来 eksctl 版本可能改变默认行为。建议在集群配置中显式设置
`autoModeConfig.enabled: false` 以确保向前兼容。

## 部署结果验证

### Oregon (us-west-2) - gpu-cluster-oregon
```
节点:
  ip-10-0-11-159.us-west-2.compute.internal  Ready  m7g.large  v1.35.2-eks  AL2023  containerd://2.2.1
  ip-10-0-14-146.us-west-2.compute.internal  Ready  m7g.large  v1.35.2-eks  AL2023  containerd://2.2.1

Pod Identity:
  cluster-autoscaler -> kube-system
  aws-load-balancer-controller -> kube-system

Metrics Server: Working (CPU/Memory 正常采集)
```

### Ohio (us-east-2) - gpu-cluster-ohio
```
节点:
  ip-10-1-12-223.us-east-2.compute.internal  Ready  m7g.large  v1.35.2-eks  AL2023  containerd://2.2.1
  ip-10-1-13-162.us-east-2.compute.internal  Ready  m7g.large  v1.35.2-eks  AL2023  containerd://2.2.1

Pod Identity:
  cluster-autoscaler -> kube-system
  aws-load-balancer-controller -> kube-system

Metrics Server: Working (CPU/Memory 正常采集)
```

## 资源清单 (用于后续清理)

### Oregon (us-west-2)
- VPC: vpc-081ea929da61b21d7 (gpu-vpc, 10.0.0.0/16)
- EKS: gpu-cluster-oregon (K8s 1.35, deletion protection enabled)
- NAT Gateway: nat-05965ceaddcdf4101
- Bastion: i-081b2b010b6af530c
- VPC Endpoints: 14 个 (13 interface + 1 gateway)

### Ohio (us-east-2)
- VPC: vpc-0bcb622cffd226d26 (gpu-vpc, 10.1.0.0/16)
- EKS: gpu-cluster-ohio (K8s 1.35, deletion protection enabled)
- NAT Gateway: nat-0a72a573ff83d7b4e
- Bastion: i-0341d214635c1ca74
- VPC Endpoints: 14 个 (13 interface + 1 gateway)

### 共享资源
- S3: eks-deploy-temp-788668107894 (临时代码传输桶)
- IAM: EKS-Deploy-Role, EKS-Deploy-Profile
