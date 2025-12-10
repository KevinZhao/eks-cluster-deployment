# EKS 核心组件与 GPU 节点支持 - 设计文档

**版本**: 1.0
**日期**: 2025-12-09
**状态**: 草稿 - 待审核

---

## 1. 执行摘要

### 1.1 概述

本文档描述了为现有 EKS 部署项目添加核心 Kubernetes 组件和 GPU 节点支持的设计方案。该项目当前使用 AWS Pod Identity 架构(而非 IRSA)进行所有 AWS 服务认证。

### 1.2 目标

1. 添加生产就绪的必备组件(StorageClass、Metrics Server)
2. 添加可灵活配置的可选组件(Karpenter、FSx CSI、EFS CSI、S3 CSI)
3. 支持使用 P5 实例的 GPU 工作负载(p5.48xlarge、p5en.48xlarge)
4. 保持清晰、模块化的架构,遵循现有模式
5. 支持 S3 CSI Driver 的集群后配置

### 1.3 非目标

- 支持 IRSA(项目已完全迁移到 Pod Identity)
- P5 系列以外的 GPU 实例(可在后续添加)
- 替换 Cluster Autoscaler(Karpenter 是可选项,非替代品)

---

## 2. 背景

### 2.1 当前架构

项目使用:
- **Pod Identity** 进行 AWS 服务认证(无 OIDC Provider)
- **辅助函数模式** 在 `pod_identity_helpers.sh` 中实现组件设置
- **模块化脚本设计**: 脚本 4(基础集群)、脚本 6(自定义节点组)、脚本 7(可选 CSI 驱动)
- **基于清单的部署**: `manifests/addons/` 和 `manifests/cluster/` 中的 YAML 文件
- **Terraform 管理启动模板**: 自定义节点配置

### 2.2 现有组件

**当前已安装(必备)**:
- Cluster Autoscaler (CA)
- EBS CSI Driver
- AWS Load Balancer Controller

**当前可选(脚本 7)**:
- EFS CSI Driver
- S3 CSI Driver

---

## 3. 需求

### 3.1 功能需求

#### FR1: 必备组件
- **FR1.1**: 必须安装 gp3 StorageClass 并设置为默认
- **FR1.2**: 必须安装 Metrics Server 以支持 HPA/VPA
- **FR1.3**: 必须移除现有默认 gp2 StorageClass 的注解

#### FR2: 可选组件
- **FR2.1**: 组件通过 .env 中的独立布尔标志控制
- **FR2.2**: io2 StorageClass(高性能) - 可选
- **FR2.3**: Karpenter 自动扩缩容器 - 可选,与 Cluster Autoscaler 共存
- **FR2.4**: FSx CSI Driver - 可选,用于 Lustre/ONTAP 工作负载
- **FR2.5**: EFS CSI Driver - 可选(移至 .env 标志控制)
- **FR2.6**: S3 CSI Driver - 特殊情况(见 FR3)

#### FR3: S3 CSI Driver 特殊处理
- **FR3.1**: 必须支持在集群创建后安装
- **FR3.2**: 必须接受特定的 S3 存储桶 ARN 作为参数
- **FR3.3**: 必须支持使用新存储桶更新现有安装
- **FR3.4**: 提供独立脚本用于生产环境

#### FR4: GPU 节点支持
- **FR4.1**: 支持 P5 系列实例(p5.48xlarge、p5en.48xlarge)
- **FR4.2**: 16 个支持 EFA 的网络接口(ENI 0: 带 IP,ENI 1-15: 仅 EFA)
- **FR4.3**: ENI 分布在 3 个子网以实现最佳性能
- **FR4.4**: NVIDIA 驱动安装(可配置版本)
- **FR4.5**: EFA 驱动安装
- **FR4.6**: 用于多 GPU 通信的 NCCL 插件
- **FR4.7**: 用于 GPU 发现的 NVIDIA Device Plugin
- **FR4.8**: GPU 特定的节点标签和污点

### 3.2 非功能需求

#### NFR1: 配置管理
- 所有可选组件通过 `.env` 文件配置
- 明确区分必备组件和可选组件
- 所有可选设置提供默认值

#### NFR2: 一致性
- 遵循现有 Pod Identity 辅助函数模式
- 保持幂等操作(可安全重新运行)
- 一致的日志记录和错误处理

#### NFR3: 文档
- 全面的 .env.example 及使用说明
- README 中的 StorageClass 使用文档
- GPU 部署指南及测试说明

#### NFR4: 性能
- GPU 节点针对 AI/ML 工作负载优化
- GPU 节点使用高 IOPS 存储(16000 IOPS gp3)
- EFA/RDMA 流量的网络优化

---

## 4. 设计

### 4.1 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                     EKS 集群                                 │
│                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐  │
│  │   eks-utils    │  │  app nodegroup │  │ gpu nodegroup│  │
│  │   nodegroup    │  │  (ARM64/x86)   │  │  (P5 + EFA)  │  │
│  │                │  │                │  │              │  │
│  │ • CA           │  │ • 用户应用      │  │ • GPU 应用   │  │
│  │ • ALB Ctrl     │  │ • 工作负载      │  │ • 16 ENIs    │  │
│  │ • Metrics Srv  │  │                │  │ • NVIDIA     │  │
│  │ • Karpenter?   │  │                │  │ • EFA        │  │
│  └────────────────┘  └────────────────┘  └──────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │          存储类                                       │  │
│  │  • gp3 (默认) - 通用                                  │  │
│  │  • io2 (可选) - 高性能                                │  │
│  │  • gp2 (现有,非默认)                                  │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │          CSI 驱动                                     │  │
│  │  • EBS CSI (必备) - 块存储                            │  │
│  │  • EFS CSI (可选) - 共享文件系统                      │  │
│  │  • FSx CSI (可选) - 高性能 Lustre/ONTAP               │  │
│  │  • S3 CSI (独立) - 对象存储挂载                       │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ Pod Identity (无 OIDC)
                            ↓
                   ┌─────────────────┐
                   │   AWS IAM       │
                   │   角色          │
                   └─────────────────┘
```

### 4.2 组件设计

#### 4.2.1 StorageClass (必备)

**设计决策**: 始终安装 gp3 作为默认,可选安装 io2。

**实现**:
```yaml
# gp3 (默认)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  iops: "3000"
  throughput: "125"
```

**理由**:
- gp3 比 gp2 更具成本效益(便宜约 20%)
- gp3 提供基线 3000 IOPS(而 gp2 基于大小变化)
- io2 用于延迟敏感型工作负载(数据库、高 I/O 应用)

**位置**: `manifests/storage/storageclass-gp3.yaml`

#### 4.2.2 Metrics Server (必备)

**设计决策**: 为私有 API 服务器安装带有 `--kubelet-insecure-tls` 的 Metrics Server。

**实现**:
- ServiceAccount、RBAC(ClusterRole、ClusterRoleBinding)
- Deployment(2 副本)带有 eks-utils 节点选择器
- APIService 注册

**特殊配置**:
```yaml
args:
  - --kubelet-insecure-tls  # 私有 API 服务器所需
  - --kubelet-preferred-address-types=InternalIP
```

**理由**:
- HPA(Horizontal Pod Autoscaler)所需
- VPA(Vertical Pod Autoscaler)所需
- 提供 `kubectl top nodes/pods` 功能
- 无需 IAM 权限(Kubernetes 原生)

**位置**: `manifests/addons/metrics-server.yaml`

#### 4.2.3 Karpenter (可选)

**设计决策**: 可选的替代/互补自动扩缩容器,与 Cluster Autoscaler 共存。

**IAM 要求**:
- EC2、ASG、SSM、Pricing API 的自定义 IAM 策略
- Karpenter Node Role(用于其启动的 EC2 实例)
- Instance Profile

**集成方法**: Helm chart + 自定义 NodePool/EC2NodeClass

**Pod Identity 设置**:
```bash
setup_karpenter_pod_identity() {
    # 1. 使用自定义策略创建 IAM 角色
    # 2. 创建 Karpenter Node Role(用于实例)
    # 3. 创建 Instance Profile
    # 4. 创建 Pod Identity Association
}
```

**配置**:
- `.env` 标志: `INSTALL_KARPENTER=true|false`
- 可配置版本: `KARPENTER_VERSION=1.1.0`

**位置**:
- IAM 策略: `iam-policies/karpenter-policy.json`
- NodePool: `manifests/addons/karpenter-nodepool.yaml`

#### 4.2.4 FSx CSI Driver (可选)

**设计决策**: 支持 FSx Lustre 用于高性能计算工作负载。

**IAM 要求**: FSx 操作的自定义策略(DescribeFileSystems、CreateFileSystem 等)

**Pod Identity 设置**:
```bash
setup_fsx_csi_pod_identity() {
    # 1. 使用 FSx 策略创建 IAM 角色
    # 2. 创建 ServiceAccount
    # 3. 创建 Pod Identity Association
}
```

**集成**: 添加到脚本 7 菜单(选项 3)

**位置**:
- IAM 策略: `iam-policies/fsx-csi-policy.json`
- 清单: `manifests/addons/fsx-csi-driver.yaml`

#### 4.2.5 S3 CSI Driver (独立)

**设计决策**: 独立脚本用于集群后安装,支持特定存储桶权限。

**为何独立**:
- 生产部署需要特定的存储桶 ARN(非通配符)
- 存储桶可能在集群创建时不存在
- 不同环境需要不同的存储桶访问权限

**脚本**: `scripts/add_s3_csi.sh`

**用法**:
```bash
./scripts/add_s3_csi.sh arn:aws:s3:::my-bucket-1 arn:aws:s3:::my-bucket-2
```

**功能**:
- 接受存储桶 ARN 作为命令行参数
- 验证集群访问
- 支持更新现有安装
- 重用 `setup_s3_csi_pod_identity()` 辅助函数

#### 4.2.6 GPU 启动模板 (新 Terraform 模块)

**设计决策**: 用于 GPU 特定配置的独立 Terraform 模块。

**目录结构**:
```
terraform/launch-template-gpu/
├── main.tf          # 带有 16 个 ENI 的启动模板
├── variables.tf     # GPU 特定变量
├── outputs.tf       # 模板 ID、ARN、IAM 角色
└── userdata.tpl     # 引导脚本
```

**网络接口配置**:
```hcl
# ENI 0 - 带 IP 分配的主接口
network_interfaces {
  device_index       = 0
  network_card_index = 0
  subnet_id          = var.gpu_subnet_a
  interface_type     = "efa"
  # 获取 IP 分配用于 Kubernetes 网络
}

# ENI 1-15 - 仅 EFA 模式(无 IP)
dynamic "network_interfaces" {
  for_each = range(1, 16)
  content {
    device_index       = network_interfaces.value
    network_card_index = network_interfaces.value
    subnet_id          = local.eni_subnet_mapping[network_interfaces.value]
    interface_type     = "efa"
    # 无 IP 分配 - 纯 RDMA 流量
  }
}
```

**ENI 分布策略**:
- ENI 0: 子网 A(主接口,带 IP)
- ENI 1-7: 子网 B(仅 EFA)
- ENI 8-15: 子网 C(仅 EFA)

**理由**: 跨子网分布 ENI 以实现:
- 容错能力
- 网络带宽优化
- 减少单个子网争用

**安全组配置**:
- 允许安全组内的所有流量(EFA RDMA 所需)
- 允许来自集群安全组的流量

**卷配置**:
- 根卷: 最小 200GB(用于驱动和依赖项)
- 可选数据卷: 1TB(用于模型和数据集)
- 类型: gp3,16000 IOPS,1000 MB/s 吞吐量

#### 4.2.7 GPU 用户数据引导

**设计决策**: 通过用户数据在实例启动时安装驱动。

**引导步骤**:
1. 安装 NVIDIA 驱动(可配置版本)
2. 安装 EFA 驱动
3. 安装 AWS OFI NCCL 插件(用于通过 EFA 的多 GPU)
4. 为 NVIDIA 运行时配置 containerd
5. 配置 NCCL 环境变量
6. 挂载数据卷(如果存在)
7. 优化网络设置(TCP、BBR)
8. 使用 GPU 标签和污点引导 EKS

**NCCL 配置**:
```bash
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_PROTO=simple
export NCCL_SOCKET_IFNAME=^docker,lo
```

**GPU 标签**:
- `nvidia.com/gpu=true`
- `node.kubernetes.io/instance-type=<type>`
- `eks.amazonaws.com/compute-type=gpu`

**GPU 污点**:
- `nvidia.com/gpu=true:NoSchedule`

**位置**: `terraform/launch-template-gpu/userdata.tpl`

#### 4.2.8 GPU 节点组部署脚本

**设计决策**: 结合 Terraform 和 eksctl 的编排脚本。

**脚本**: `scripts/9_create_gpu_nodegroup.sh`

**工作流程**:
```
1. 加载 .env 配置
2. 验证集群可访问性
3. 检查现有 GPU 节点组
4. 运行 Terraform 创建启动模板
5. 生成 eksctl GPU 节点组清单
6. 使用 eksctl 部署节点组
7. 等待节点就绪
8. 部署 NVIDIA Device Plugin DaemonSet
9. 验证 GPU 可用性
```

**NVIDIA Device Plugin**:
- 部署到 kube-system 的 DaemonSet
- 节点选择器: `nvidia.com/gpu=true`
- 容忍度: `nvidia.com/gpu`
- 向 Kubernetes 调度器公开 GPU 资源

### 4.3 配置管理

#### 4.3.1 .env 配置

**结构**:
```bash
# ============================================
# 可选 EKS 组件配置
# ============================================

# 存储
INSTALL_IO2_STORAGECLASS=false
IO2_IOPS=10000

# 自动扩缩容
INSTALL_KARPENTER=false
KARPENTER_VERSION=1.1.0

# 文件系统
INSTALL_EFS_CSI=false
INSTALL_FSX_CSI=false
INSTALL_S3_CSI=false  # 仅基本设置,生产环境使用 add_s3_csi.sh

# ============================================
# GPU 节点组配置(可选)
# ============================================

GPU_INSTANCE_TYPE=p5en.48xlarge
GPU_NODE_GROUP_NAME=gpu-compute

# 驱动版本
NVIDIA_DRIVER_VERSION=550.127.05
EFA_DRIVER_VERSION=latest
NCCL_VERSION=2.22.3

# 卷
GPU_ROOT_VOLUME_SIZE=200
GPU_DATA_VOLUME_SIZE=1000

# 网络(16 个 ENI)
GPU_SUBNET_A=${PRIVATE_SUBNET_A}
GPU_SUBNET_B=${PRIVATE_SUBNET_B}
GPU_SUBNET_C=${PRIVATE_SUBNET_C}
```

#### 4.3.2 配置验证

**位置**: `scripts/0_setup_env.sh`

**验证函数**:
```bash
# 标准化布尔标志
normalize_bool() {
    local val="${1,,}"
    case "$val" in
        true|1|yes) echo "true" ;;
        *) echo "false" ;;
    esac
}

# 验证 io2 IOPS 范围
if [ "$INSTALL_IO2_STORAGECLASS" = "true" ]; then
    if [ "$IO2_IOPS" -lt 1000 ] || [ "$IO2_IOPS" -gt 64000 ]; then
        warn "IO2_IOPS 超出范围,使用默认值: 10000"
    fi
fi

# 验证 P5 的 GPU ENI 数量
if [[ "$GPU_INSTANCE_TYPE" == p5* ]] && [ "$GPU_NUM_ENIS" -ne 16 ]; then
    warn "P5 实例需要 16 个 ENI,正在调整"
    export GPU_NUM_ENIS=16
fi
```

### 4.4 集成点

#### 4.4.1 脚本 4 和 6 集成

**位置**: EBS CSI 设置之后(脚本 4 的第 86 行附近,脚本 6 的第 170 行附近)

**集成流程**:
```bash
# 6. 设置 EBS CSI Driver
setup_ebs_csi_pod_identity

# 6.5. 配置 StorageClass(必备)
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl apply -f "${PROJECT_ROOT}/manifests/storage/storageclass-gp3.yaml"

if [ "$INSTALL_IO2_STORAGECLASS" = "true" ]; then
    envsubst < "${PROJECT_ROOT}/manifests/storage/storageclass-io2.yaml" | kubectl apply -f -
fi

# 6.6. 安装 Metrics Server(必备)
setup_metrics_server

# 6.7. 安装 Karpenter(可选)
if [ "$INSTALL_KARPENTER" = "true" ]; then
    setup_karpenter_pod_identity
    helm install karpenter ...
fi

# 6.8. 安装 FSx CSI Driver(可选)
if [ "$INSTALL_FSX_CSI" = "true" ]; then
    setup_fsx_csi_pod_identity
    kubectl apply -f "${PROJECT_ROOT}/manifests/addons/fsx-csi-driver.yaml"
fi
```

#### 4.4.2 脚本 7 集成

**更新**: 添加 FSx 作为选项 3

**菜单**:
```
可用驱动:
  1. EFS CSI Driver
  2. S3 CSI Driver
  3. FSx CSI Driver  <-- 新增
  4. 安装多个驱动
  5. 退出
```

#### 4.4.3 辅助函数

**位置**: `scripts/pod_identity_helpers.sh`

**新函数**:
```bash
setup_metrics_server()
setup_karpenter_pod_identity()
setup_fsx_csi_pod_identity()
```

**模式**:
```bash
setup_<component>_pod_identity() {
    log "使用 Pod Identity 设置 <component>"

    local role_name="${CLUSTER_NAME}-<component>-role"
    local namespace="kube-system"
    local service_account="<component>-sa"

    create_pod_identity_role "${role_name}"
    attach_managed_policy "${role_name}" "<policy-arn>"
    create_service_account "${namespace}" "${service_account}"
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ <component> Pod Identity 设置完成"
}
```

---

## 5. 数据模型

### 5.1 环境变量

| 变量 | 类型 | 默认值 | 描述 |
|----------|------|---------|-------------|
| `INSTALL_IO2_STORAGECLASS` | 布尔 | false | 安装 io2 StorageClass |
| `IO2_IOPS` | 整数 | 10000 | io2 卷的 IOPS (1000-64000) |
| `INSTALL_KARPENTER` | 布尔 | false | 安装 Karpenter 自动扩缩容器 |
| `KARPENTER_VERSION` | 字符串 | 1.1.0 | Karpenter 版本 |
| `INSTALL_EFS_CSI` | 布尔 | false | 安装 EFS CSI Driver |
| `INSTALL_FSX_CSI` | 布尔 | false | 安装 FSx CSI Driver |
| `INSTALL_S3_CSI` | 布尔 | false | 安装 S3 CSI Driver(基础) |
| `GPU_INSTANCE_TYPE` | 字符串 | p5en.48xlarge | GPU 实例类型 |
| `GPU_NODE_GROUP_NAME` | 字符串 | gpu-compute | GPU 节点组名称 |
| `GPU_MIN_SIZE` | 整数 | 0 | 最小 GPU 节点数 |
| `GPU_DESIRED_SIZE` | 整数 | 0 | 期望 GPU 节点数 |
| `GPU_MAX_SIZE` | 整数 | 10 | 最大 GPU 节点数 |
| `NVIDIA_DRIVER_VERSION` | 字符串 | 550.127.05 | NVIDIA 驱动版本 |
| `EFA_DRIVER_VERSION` | 字符串 | latest | EFA 驱动版本 |
| `NCCL_VERSION` | 字符串 | 2.22.3 | NCCL 版本 |
| `GPU_ROOT_VOLUME_SIZE` | 整数 | 200 | 根卷大小 (GB) |
| `GPU_DATA_VOLUME_SIZE` | 整数 | 1000 | 数据卷大小 (GB) |
| `GPU_SUBNET_A` | 字符串 | ${PRIVATE_SUBNET_A} | ENI 0 的子网 |
| `GPU_SUBNET_B` | 字符串 | ${PRIVATE_SUBNET_B} | ENI 1-7 的子网 |
| `GPU_SUBNET_C` | 字符串 | ${PRIVATE_SUBNET_C} | ENI 8-15 的子网 |

### 5.2 IAM 策略

#### 5.2.1 Karpenter Controller 策略

**权限**:
- EC2: RunInstances、CreateFleet、TerminateInstances、Describe*
- IAM: PassRole、CreateInstanceProfile、TagInstanceProfile
- SSM: GetParameter
- Pricing: GetProducts
- SQS: ReceiveMessage、DeleteMessage(用于中断队列)
- EKS: DescribeCluster

**资源限制**:
- EC2 实例: 基于标签(`karpenter.sh/cluster`)
- 启动模板: 基于标签
- IAM 角色: 特定角色名称模式

#### 5.2.2 FSx CSI Driver 策略

**权限**:
- FSx: CreateFileSystem、DeleteFileSystem、DescribeFileSystems、UpdateFileSystem、TagResource
- EC2: DescribeSubnets、DescribeNetworkInterfaces、CreateNetworkInterface、DeleteNetworkInterface
- S3: GetObject、PutObject(用于 FSx Lustre 数据仓库)

**资源限制**: 无(FSx 允许通配符)

---

## 6. 实施计划

### 6.1 阶段 1: 环境配置
**优先级**: 高
**预计工作量**: 2-3 小时

**任务**:
1. 使用所有新配置选项更新 `.env.example`
2. 向 `scripts/0_setup_env.sh` 添加验证逻辑
3. 测试配置加载和验证

**交付成果**:
- 更新的 `.env.example`(约 80 行新内容)
- 更新的 `scripts/0_setup_env.sh`(约 60 行新内容)

### 6.2 阶段 2: 必备组件
**优先级**: 高
**预计工作量**: 4-5 小时

**任务**:
1. 创建 `manifests/storage/` 目录
2. 创建 StorageClass 清单(gp3、io2)
3. 创建 Metrics Server 清单
4. 为 Metrics Server 添加辅助函数
5. 集成到脚本 4 和 6

**交付成果**:
- `manifests/storage/storageclass-gp3.yaml`
- `manifests/storage/storageclass-io2.yaml`
- `manifests/storage/README.md`
- `manifests/addons/metrics-server.yaml`
- 更新的 `scripts/pod_identity_helpers.sh`
- 更新的 `scripts/4_install_eks_cluster.sh`
- 更新的 `scripts/6_install_eks_with_custom_nodegroup.sh`

### 6.3 阶段 3: 可选组件
**优先级**: 中
**预计工作量**: 6-8 小时

**任务**:
1. 创建 Karpenter IAM 策略
2. 创建 Karpenter 辅助函数
3. 创建 Karpenter NodePool 清单
4. 创建 FSx IAM 策略
5. 创建 FSx CSI Driver 清单
6. 创建 FSx 辅助函数
7. 使用 FSx 选项更新脚本 7
8. 将可选组件集成到脚本 4 和 6

**交付成果**:
- `iam-policies/karpenter-policy.json`
- `manifests/addons/karpenter-nodepool.yaml`
- `iam-policies/fsx-csi-policy.json`
- `manifests/addons/fsx-csi-driver.yaml`
- 更新的 `scripts/pod_identity_helpers.sh`(2 个新函数)
- 更新的 `scripts/7_install_optional_csi_drivers.sh`
- 更新的脚本 4 和 6(可选组件集成)

### 6.4 阶段 4: S3 CSI 独立脚本
**优先级**: 高
**预计工作量**: 3-4 小时

**任务**:
1. 创建独立 S3 CSI 安装脚本
2. 添加命令行参数解析
3. 添加集群验证
4. 添加更新支持
5. 使用单个和多个存储桶进行测试

**交付成果**:
- `scripts/add_s3_csi.sh`(约 250 行)

### 6.5 阶段 5: GPU 启动模板
**优先级**: 高
**预计工作量**: 8-10 小时

**任务**:
1. 创建 Terraform 模块目录
2. 创建带有 16 个 ENI 配置的 `main.tf`
3. 创建带有 GPU 特定变量的 `variables.tf`
4. 创建 `outputs.tf`
5. 创建带有驱动安装的 `userdata.tpl`
6. 测试启动模板创建
7. 验证 ENI 附加
8. 测试驱动安装

**交付成果**:
- `terraform/launch-template-gpu/main.tf`(约 400 行)
- `terraform/launch-template-gpu/variables.tf`(约 150 行)
- `terraform/launch-template-gpu/outputs.tf`(约 100 行)
- `terraform/launch-template-gpu/userdata.tpl`(约 250 行)

### 6.6 阶段 6: GPU 节点组脚本
**优先级**: 高
**预计工作量**: 4-5 小时

**任务**:
1. 创建 GPU 节点组部署脚本
2. 添加 Terraform 编排
3. 添加 eksctl 集成
4. 添加 NVIDIA Device Plugin 部署
5. 添加验证步骤
6. 测试端到端 GPU 节点部署

**交付成果**:
- `scripts/9_create_gpu_nodegroup.sh`(约 300 行)

### 6.7 阶段 7: 测试和文档
**优先级**: 高
**预计工作量**: 4-6 小时

**任务**:
1. 单独测试每个组件
2. 测试集成流程
3. 测试 GPU 部署
4. 更新 README
5. 创建 GPU 部署指南
6. 添加故障排除指南

**交付成果**:
- 测试结果文档
- 更新的 README
- GPU 部署指南

---

## 7. 测试策略

### 7.1 单元测试

**StorageClass**:
```bash
# 测试 gp3 是默认的
kubectl get storageclass gp3 -o yaml | grep "is-default-class: \"true\""

# 使用默认测试 PVC
kubectl apply -f test-pvc.yaml
kubectl get pvc test-pvc

# 如果启用,测试 io2
kubectl get storageclass io2
```

**Metrics Server**:
```bash
# 测试指标 API
kubectl top nodes
kubectl top pods -A

# 使用 HPA 测试
kubectl autoscale deployment test-app --cpu-percent=50 --min=1 --max=10
kubectl get hpa
```

**Karpenter**:
```bash
# 验证控制器
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# 测试配置
kubectl scale deployment inflate --replicas=10
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

### 7.2 集成测试

**完整集群部署**:
```bash
# 测试脚本 4
./scripts/4_install_eks_cluster.sh

# 验证所有必备组件
kubectl get storageclass
kubectl get deployment metrics-server -n kube-system
kubectl get pod-identity-associations
```

**GPU 部署**:
```bash
# 部署 GPU 节点组
./scripts/9_create_gpu_nodegroup.sh

# 验证 GPU 节点
kubectl get nodes -l nvidia.com/gpu=true

# 测试 GPU 访问
kubectl run gpu-test --rm -it --image=nvidia/cuda:12.3.0-base-ubuntu22.04 -- nvidia-smi

# 测试 EFA
kubectl exec -it gpu-pod -- fi_info -p efa
```

### 7.3 性能测试

**GPU 性能**:
- 使用 NCCL 的多 GPU 训练测试
- EFA 带宽测试
- RDMA 延迟测试

**存储性能**:
- io2 IOPS 验证
- gp3 吞吐量测试

---

## 8. 安全考虑

### 8.1 IAM 权限

**最小权限原则**:
- Karpenter: EC2 资源的基于标签的限制
- FSx CSI: 仅必要的 FSx 操作
- 所有角色使用 Pod Identity 信任策略(无 OIDC)

### 8.2 网络安全

**GPU 节点**:
- 安全组允许组内的所有流量(EFA 所需)
- 无公共 IP 分配
- 所有通信通过私有子网

**EFA**:
- RDMA 流量隔离到集群安全组
- EFA 接口无外部访问

### 8.3 密钥管理

**驱动安装**:
- 无硬编码凭证
- 所有资源从公共存储库获取
- 实例元数据(IMDSv2)用于 AWS 凭证

---

## 9. 运维考虑

### 9.1 监控

**要监控的指标**:
- 每节点 GPU 利用率
- EFA 网络吞吐量
- StorageClass PVC 配置成功率
- Karpenter 配置延迟

**工具**:
- Metrics Server 用于基本指标
- NVIDIA DCGM 用于 GPU 指标(未来增强)
- CloudWatch 用于 AWS 级别监控

### 9.2 故障排除

**常见问题**:

1. **gp2 仍是默认**: 检查注解移除,验证 gp3 有默认注解
2. **Metrics Server TLS 错误**: 验证 `--kubelet-insecure-tls` 标志已设置
3. **Karpenter 不配置**: 检查 IAM PassRole,Node Role 存在,EC2NodeClass 子网正确
4. **GPU ENI 附加失败**: 验证子网有 IP,安全组允许所有流量
5. **EFA 不工作**: 检查 `fi_info -p efa`,验证 NCCL 环境变量,确保插件已安装

### 9.3 维护

**升级**:
- Metrics Server: 更新清单中的镜像版本
- Karpenter: 更新 Helm chart 版本
- CSI Driver: 更新清单中的镜像版本
- GPU Driver: 更新 `.env` 中的版本,重新创建启动模板

**备份/恢复**:
- 所有配置在 Git 中
- IAM 角色可以从策略重新创建
- 启动模板已版本化(无数据丢失)

---

## 10. 未来增强

### 10.1 短期(未来 3 个月)

1. 支持额外的 GPU 系列(P4、G5、G6)
2. NVIDIA DCGM 集成用于 GPU 监控
3. 通过 DaemonSet 自动驱动更新
4. 多可用区 GPU 节点组支持

### 10.2 中期(3-6 个月)

1. GPU 节点自愈
2. GPU 节点的自定义 Karpenter provisioner
3. FSx Lustre 集成示例
4. S3 CSI 性能优化

### 10.3 长期(6-12 个月)

1. 多集群 GPU 调度
2. GPU 时间切片支持
3. A100/H100 的 MIG(Multi-Instance GPU)支持
4. Ray/Kubeflow 集成

---

## 11. 风险与缓解

### 11.1 技术风险

| 风险 | 影响 | 概率 | 缓解措施 |
|------|--------|-------------|------------|
| EFA 驱动安装超时 | 高 | 中 | 使用预安装驱动的 Deep Learning AMI |
| P5 ENI 附加失败 | 高 | 低 | 全面的子网验证,清晰的错误消息 |
| Karpenter 与 CA 冲突 | 中 | 低 | 关于共存的清晰文档,独立节点组 |
| GPU 驱动不兼容 | 高 | 低 | 固定特定驱动版本,部署前测试 |
| S3 CSI 性能问题 | 中 | 中 | 关于用例的清晰文档,推荐高 IOPS 使用 EFS |

### 11.2 运维风险

| 风险 | 影响 | 概率 | 缓解措施 |
|------|--------|-------------|------------|
| 不正确的 .env 配置 | 中 | 中 | 在 0_setup_env.sh 中验证,.env.example 中的清晰示例 |
| 用户安装冲突组件 | 低 | 低 | 关于组件兼容性的文档 |
| 16 个 ENI 的子网 IP 不足 | 高 | 中 | 部署前验证,清晰的错误消息 |

---

## 12. 附录

### 12.1 文件结构

```
eks-cluster-deployment/
├── .env.example (更新)
├── DESIGN.md (本文档)
├── iam-policies/
│   ├── karpenter-policy.json (新)
│   └── fsx-csi-policy.json (新)
├── manifests/
│   ├── addons/
│   │   ├── metrics-server.yaml (新)
│   │   ├── karpenter-nodepool.yaml (新)
│   │   └── fsx-csi-driver.yaml (新)
│   └── storage/ (新目录)
│       ├── storageclass-gp3.yaml (新)
│       ├── storageclass-io2.yaml (新)
│       └── README.md (新)
├── scripts/
│   ├── 0_setup_env.sh (更新)
│   ├── 4_install_eks_cluster.sh (更新)
│   ├── 6_install_eks_with_custom_nodegroup.sh (更新)
│   ├── 7_install_optional_csi_drivers.sh (更新)
│   ├── pod_identity_helpers.sh (更新)
│   ├── add_s3_csi.sh (新)
│   └── 9_create_gpu_nodegroup.sh (新)
└── terraform/
    └── launch-template-gpu/ (新目录)
        ├── main.tf (新)
        ├── variables.tf (新)
        ├── outputs.tf (新)
        └── userdata.tpl (新)
```

### 12.2 参考资料

**AWS 文档**:
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [EFA 用户指南](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [P5 实例](https://aws.amazon.com/ec2/instance-types/p5/)
- [EBS 卷类型](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)

**Kubernetes 文档**:
- [Metrics Server](https://github.com/kubernetes-sigs/metrics-server)
- [StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)

**第三方工具**:
- [Karpenter](https://karpenter.sh/)
- [EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [EFS CSI Driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)
- [FSx CSI Driver](https://github.com/kubernetes-sigs/aws-fsx-csi-driver)
- [S3 CSI Driver](https://github.com/awslabs/mountpoint-s3-csi-driver)

### 12.3 术语表

- **CA**: Cluster Autoscaler (集群自动扩缩容器)
- **CSI**: Container Storage Interface (容器存储接口)
- **EBS**: Elastic Block Store (弹性块存储)
- **EFA**: Elastic Fabric Adapter (弹性网络适配器)
- **EFS**: Elastic File System (弹性文件系统)
- **ENI**: Elastic Network Interface (弹性网络接口)
- **FSx**: Amazon FSx (文件系统)
- **HPA**: Horizontal Pod Autoscaler (水平 Pod 自动扩缩容器)
- **IOPS**: Input/Output Operations Per Second (每秒输入/输出操作数)
- **IRSA**: IAM Roles for Service Accounts (服务账户的 IAM 角色,本项目已弃用)
- **NCCL**: NVIDIA Collective Communications Library (NVIDIA 集合通信库)
- **RDMA**: Remote Direct Memory Access (远程直接内存访问)
- **VPA**: Vertical Pod Autoscaler (垂直 Pod 自动扩缩容器)

---

## 13. 审批

**文档状态**: 草稿 - 待审核

**审核人**:
- [ ] 项目负责人
- [ ] DevOps 团队
- [ ] 安全团队
- [ ] 平台工程团队

**批准日期**: _____________

**批准人**: _____________

---

**设计文档结束**
