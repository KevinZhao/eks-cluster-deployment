# EKS GPU 节点支持与 Pod 磁盘配额 - 设计文档

**版本**: 2.0
**日期**: 2026-01-02
**状态**: 待实施

---

## 0. 变更记录

### 版本 2.0 (2026-01-02)

**文档重构：移除已完成功能**

本版本移除了所有已完成的功能设计，仅保留尚未实施的功能：
- GPU 节点组支持 (P5 实例 + EFA)
- Pod 磁盘配额限制

**已完成并移除的内容**:
- ✅ StorageClass (gp3/io2) - 已实施
- ✅ Metrics Server - 已实施
- ✅ Karpenter - 已实施 (option_install_karpenter.sh)
- ✅ FSx CSI Driver - 已实施
- ✅ EFS CSI Driver - 已实施
- ✅ S3 CSI Driver - 已实施 (支持 Standard S3 和 S3 Express)

---

## 1. 执行摘要

### 1.1 概述

本文档描述为现有 EKS 部署项目添加 GPU 节点支持和 Pod 磁盘配额限制的设计方案。该项目使用 AWS Pod Identity 架构进行所有 AWS 服务认证。

### 1.2 目标

1. 支持使用 P5 实例的 GPU 工作负载 (p5.48xlarge、p5en.48xlarge)
2. 实现 Pod 内磁盘配额限制，使 Pod 只能看到分配的磁盘空间
3. 保持清晰、模块化的架构，遵循现有模式

### 1.3 非目标

- P5 系列以外的 GPU 实例 (可在后续添加)
- 集群级别的磁盘配额管理 (仅关注 Pod 级别)

---

## 2. 当前架构

项目使用:
- **Pod Identity** 进行 AWS 服务认证 (无 OIDC Provider)
- **辅助函数模式** 在 `pod_identity_helpers.sh` 中实现组件设置
- **模块化脚本设计**: 脚本按功能分离，职责单一
- **基于清单的部署**: `manifests/addons/` 和 `manifests/storage/` 中的 YAML 文件
- **Terraform 管理启动模板**: 自定义节点配置

**现有节点组**:
- 系统节点组 (eks-utils): 运行系统组件，使用 LVM 配置
- 应用节点组: 用户工作负载

---

## 3. 需求

### 3.1 功能需求

#### FR1: GPU 节点支持
- **FR1.1**: 支持 P5 系列实例 (p5.48xlarge、p5en.48xlarge)
- **FR1.2**: 16 个支持 EFA 的网络接口 (ENI 0: 带 IP，ENI 1-15: 仅 EFA)
- **FR1.3**: ENI 分布在 3 个子网以实现最佳性能
- **FR1.4**: NVIDIA 驱动安装 (可配置版本)
- **FR1.5**: EFA 驱动安装
- **FR1.6**: 用于多 GPU 通信的 NCCL 插件
- **FR1.7**: 用于 GPU 发现的 NVIDIA Device Plugin
- **FR1.8**: GPU 特定的节点标签和污点

#### FR2: Pod 磁盘配额限制
- **FR2.1**: Pod 内只能看到分配的磁盘空间，而非整个节点磁盘
- **FR2.2**: 支持动态配额调整
- **FR2.3**: 配额限制应用于容器文件系统和挂载卷
- **FR2.4**: 提供配额使用监控能力

### 3.2 非功能需求

#### NFR1: 配置管理
- 所有 GPU 配置通过 `.env` 文件配置
- 所有可选设置提供默认值

#### NFR2: 一致性
- 遵循现有 Pod Identity 辅助函数模式
- 保持幂等操作 (可安全重新运行)
- 一致的日志记录和错误处理

#### NFR3: 性能
- GPU 节点针对 AI/ML 工作负载优化
- GPU 节点使用高 IOPS 存储 (16000 IOPS gp3)
- EFA/RDMA 流量的网络优化

---

## 4. 设计

### 4.1 GPU 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                     EKS 集群                                 │
│                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐  │
│  │   eks-utils    │  │  app nodegroup │  │ gpu nodegroup│  │
│  │   nodegroup    │  │  (ARM64/x86)   │  │  (P5 + EFA)  │  │
│  │                │  │                │  │              │  │
│  │ • 系统组件      │  │ • 用户应用      │  │ • GPU 应用   │  │
│  │ • Addons       │  │ • 工作负载      │  │ • 16 ENIs    │  │
│  │                │  │                │  │ • NVIDIA     │  │
│  │                │  │                │  │ • EFA        │  │
│  └────────────────┘  └────────────────┘  └──────────────┘  │
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

### 4.2 GPU 组件设计

#### 4.2.1 GPU 启动模板 (新 Terraform 模块)

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

# ENI 1-15 - 仅 EFA 模式 (无 IP)
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
- ENI 0: 子网 A (主接口，带 IP)
- ENI 1-7: 子网 B (仅 EFA)
- ENI 8-15: 子网 C (仅 EFA)

**理由**: 跨子网分布 ENI 以实现:
- 容错能力
- 网络带宽优化
- 减少单个子网争用

**安全组配置**:
- 允许安全组内的所有流量 (EFA RDMA 所需)
- 允许来自集群安全组的流量

**卷配置**:
- 根卷: 最小 200GB (用于驱动和依赖项)
- 可选数据卷: 1TB (用于模型和数据集)
- 类型: gp3，16000 IOPS，1000 MB/s 吞吐量

#### 4.2.2 GPU 用户数据引导

**引导步骤**:
1. 安装 NVIDIA 驱动 (可配置版本)
2. 安装 EFA 驱动
3. 安装 AWS OFI NCCL 插件 (用于通过 EFA 的多 GPU)
4. 为 NVIDIA 运行时配置 containerd
5. 配置 NCCL 环境变量
6. 挂载数据卷 (如果存在)
7. 优化网络设置 (TCP、BBR)
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

#### 4.2.3 GPU 节点组部署脚本

**脚本**: `scripts/12_create_gpu_nodegroup.sh`

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

#### 4.2.4 .env 配置

**新增配置项**:
```bash
# ============================================
# GPU 节点组配置 (可选)
# ============================================

GPU_INSTANCE_TYPE=p5en.48xlarge
GPU_NODE_GROUP_NAME=gpu-compute
GPU_MIN_SIZE=0
GPU_DESIRED_SIZE=0
GPU_MAX_SIZE=10

# 驱动版本
NVIDIA_DRIVER_VERSION=550.127.05
EFA_DRIVER_VERSION=latest
NCCL_VERSION=2.22.3

# 卷
GPU_ROOT_VOLUME_SIZE=200
GPU_DATA_VOLUME_SIZE=1000

# 网络 (16 个 ENI)
GPU_SUBNET_A=${PRIVATE_SUBNET_A}
GPU_SUBNET_B=${PRIVATE_SUBNET_B}
GPU_SUBNET_C=${PRIVATE_SUBNET_C}
```

### 4.3 Pod 磁盘配额设计

#### 4.3.1 技术方案选项

**方案 1: Kubernetes Ephemeral Storage Limits**
```yaml
resources:
  limits:
    ephemeral-storage: "10Gi"
  requests:
    ephemeral-storage: "5Gi"
```

**优点**:
- Kubernetes 原生支持
- 简单易用
- 不需要额外工具

**缺点**:
- 仅限制写入，Pod 仍能看到整个磁盘空间
- 不影响 `df` 命令显示的可用空间

**方案 2: Quota + Project ID (XFS/ext4)**

使用 Linux 磁盘配额功能：
- 每个 Pod 分配唯一的 project ID
- 在文件系统级别设置配额
- Pod 内 `df` 命令显示配额限制的空间

**优点**:
- Pod 真正只看到分配的空间
- 文件系统级别强制执行
- 精确的配额控制

**缺点**:
- 需要支持配额的文件系统 (XFS 或 ext4 with quota)
- 实施较复杂
- 需要修改 kubelet 或使用 admission webhook

**方案 3: 独立卷 + PV/PVC**

为每个 Pod 创建独立的 PersistentVolume：
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-storage
spec:
  resources:
    requests:
      storage: 10Gi
```

**优点**:
- Kubernetes 原生，成熟稳定
- Pod 只看到 PVC 的大小
- 易于管理和监控

**缺点**:
- 需要为每个 Pod 创建 PVC
- 额外的 EBS 卷成本
- 不适用于临时存储

**推荐方案**: **方案 1 (短期) + 方案 2 (长期)**

- **短期**: 使用 ephemeral-storage limits 作为保护措施
- **长期**: 实施 XFS quota + project ID，提供真实的磁盘视图

#### 4.3.2 实施步骤 (方案 2)

**1. 节点准备**

在节点启动时配置文件系统：
```bash
# userdata.tpl 中添加
# 挂载数据卷时启用 project quota
mkfs.xfs -f /dev/nvme1n1
mount -o prjquota /dev/nvme1n1 /var/lib/kubelet
```

**2. Quota Manager DaemonSet**

创建 DaemonSet 监听 Pod 创建：
- 分配唯一的 project ID
- 设置文件系统配额
- 应用到 Pod 的容器目录

**3. 配置 kubelet**

修改 kubelet 配置以感知配额：
```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
featureGates:
  LocalStorageCapacityIsolation: true
```

**4. Admission Webhook**

验证 Pod 请求的配额：
- 拒绝没有配额设置的 Pod
- 验证配额值在允许范围内

#### 4.3.3 配额监控

**Prometheus Metrics**:
```
pod_storage_quota_bytes{pod="", namespace=""}
pod_storage_used_bytes{pod="", namespace=""}
```

**kubectl 插件**:
```bash
kubectl quota get pod my-pod
kubectl quota list -n default
```

---

## 5. 数据模型

### 5.1 环境变量

| 变量 | 类型 | 默认值 | 描述 |
|----------|------|---------|-------------|
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
| `ENABLE_POD_STORAGE_QUOTA` | 布尔 | false | 启用 Pod 存储配额 |
| `DEFAULT_POD_STORAGE_QUOTA` | 字符串 | 10Gi | 默认 Pod 存储配额 |

---

## 6. 实施计划

### 6.1 阶段 1: GPU 启动模板 (优先级: 高)

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
- `terraform/launch-template-gpu/main.tf`
- `terraform/launch-template-gpu/variables.tf`
- `terraform/launch-template-gpu/outputs.tf`
- `terraform/launch-template-gpu/userdata.tpl`

### 6.2 阶段 2: GPU 节点组脚本 (优先级: 高)

**任务**:
1. 创建 GPU 节点组部署脚本
2. 添加 Terraform 编排
3. 添加 eksctl 集成
4. 添加 NVIDIA Device Plugin 部署
5. 添加验证步骤
6. 测试端到端 GPU 节点部署

**交付成果**:
- `scripts/12_create_gpu_nodegroup.sh`
- NVIDIA Device Plugin manifest

### 6.3 阶段 3: GPU 配置 (优先级: 高)

**任务**:
1. 更新 `.env.example` 添加 GPU 配置
2. 向 `scripts/0_setup_env.sh` 添加 GPU 验证逻辑
3. 测试配置加载和验证

**交付成果**:
- 更新的 `.env.example`
- 更新的 `scripts/0_setup_env.sh`

### 6.4 阶段 4: Pod 配额 - 短期方案 (优先级: 中)

**任务**:
1. 创建示例 manifest 展示 ephemeral-storage limits
2. 添加文档说明使用方法
3. 创建监控 dashboard

**交付成果**:
- `manifests/examples/pod-with-storage-limit.yaml`
- 文档更新

### 6.5 阶段 5: Pod 配额 - 长期方案 (优先级: 低)

**任务**:
1. 设计 Quota Manager DaemonSet
2. 实现 project ID 分配逻辑
3. 创建 admission webhook
4. 更新节点 userdata 启用配额
5. 实施监控和报警
6. 端到端测试

**交付成果**:
- Quota Manager DaemonSet
- Admission Webhook
- 监控 metrics 和 dashboard

### 6.6 阶段 6: 测试和文档 (优先级: 高)

**任务**:
1. 测试 GPU 部署
2. 测试 GPU 工作负载 (NCCL, multi-GPU)
3. 测试 EFA 性能
4. 更新 README
5. 创建 GPU 部署指南
6. 添加故障排除指南

**交付成果**:
- 测试结果文档
- GPU 部署指南
- 故障排除文档

---

## 7. 测试策略

### 7.1 GPU 功能测试

**启动模板测试**:
```bash
# 验证 Terraform 创建
cd terraform/launch-template-gpu
terraform plan
terraform apply

# 验证 ENI 配置
aws ec2 describe-launch-templates --launch-template-ids <id>
```

**节点组部署测试**:
```bash
# 部署 GPU 节点组
./scripts/12_create_gpu_nodegroup.sh

# 验证 GPU 节点
kubectl get nodes -l nvidia.com/gpu=true

# 测试 GPU 访问
kubectl run gpu-test --rm -it --image=nvidia/cuda:12.3.0-base-ubuntu22.04 -- nvidia-smi

# 测试 EFA
kubectl exec -it gpu-pod -- fi_info -p efa
```

**GPU 性能测试**:
- 使用 NCCL 的多 GPU 训练测试
- EFA 带宽测试 (ib_write_bw)
- RDMA 延迟测试 (ib_write_lat)

### 7.2 Pod 配额测试

**Ephemeral Storage 测试**:
```bash
# 创建带配额的 Pod
kubectl apply -f manifests/examples/pod-with-storage-limit.yaml

# 验证配额限制
kubectl exec pod -- dd if=/dev/zero of=/data/file bs=1M count=15000
# 应该失败，超过配额
```

**XFS Quota 测试** (长期方案):
```bash
# 验证配额设置
kubectl exec quota-manager-xxx -- xfs_quota -x -c 'report -h' /var/lib/kubelet

# 验证 Pod 视图
kubectl exec test-pod -- df -h
# 应该显示配额限制的大小
```

---

## 8. 安全考虑

### 8.1 GPU 网络安全

**安全组规则**:
- 仅允许集群内通信
- EFA 流量限制在 GPU 节点组内
- 无公共 IP 分配

**EFA RDMA**:
- RDMA 流量隔离到专用安全组
- 仅允许同组节点间通信

### 8.2 配额安全

**资源隔离**:
- 防止单个 Pod 占用所有节点磁盘
- 配额强制执行在文件系统层
- 管理员可以覆盖配额 (紧急情况)

---

## 9. 运维考虑

### 9.1 监控

**GPU 指标**:
- GPU 利用率 (per device)
- GPU 内存使用
- EFA 网络吞吐量
- 温度和功耗

**配额指标**:
- Pod 存储使用 vs 配额
- 配额超限事件
- 磁盘 I/O 压力

**工具**:
- NVIDIA DCGM Exporter (GPU metrics)
- Prometheus + Grafana
- CloudWatch Container Insights

### 9.2 故障排除

**GPU 常见问题**:
1. **GPU ENI 附加失败**: 验证子网有足够 IP，安全组允许流量
2. **EFA 不工作**: 检查 `fi_info -p efa`，验证 NCCL 环境变量
3. **驱动安装失败**: 查看 `/var/log/user-data.log`，验证驱动版本兼容性
4. **Device Plugin 未发现 GPU**: 检查 containerd 配置，验证 nvidia-smi 可用

**配额常见问题**:
1. **Pod 仍看到全部磁盘**: 验证 XFS quota 已启用，project ID 已设置
2. **配额未生效**: 检查 Quota Manager logs，验证 admission webhook
3. **df 显示不正确**: 重新挂载文件系统，确保 prjquota 选项

---

## 10. 文件结构

```
eks-cluster-deployment/
├── .env.example (更新 - 添加 GPU 配置)
├── DESIGN.md (本文档)
├── manifests/
│   ├── addons/
│   │   ├── nvidia-device-plugin.yaml (新)
│   │   └── quota-manager.yaml (新 - 长期)
│   └── examples/
│       ├── gpu-test-pod.yaml (新)
│       └── pod-with-storage-limit.yaml (新)
├── scripts/
│   ├── 0_setup_env.sh (更新 - GPU 配置验证)
│   └── 12_create_gpu_nodegroup.sh (新)
└── terraform/
    └── launch-template-gpu/ (新目录)
        ├── main.tf (新)
        ├── variables.tf (新)
        ├── outputs.tf (新)
        └── userdata.tpl (新)
```

---

## 11. 风险与缓解

### 11.1 技术风险

| 风险 | 影响 | 概率 | 缓解措施 |
|------|--------|-------------|------------|
| EFA 驱动安装超时 | 高 | 中 | 使用预安装驱动的 Deep Learning AMI |
| P5 ENI 附加失败 | 高 | 低 | 全面的子网验证，清晰的错误消息 |
| GPU 驱动不兼容 | 高 | 低 | 固定特定驱动版本，部署前测试 |
| XFS quota 性能影响 | 中 | 中 | 性能测试，可选禁用功能 |

### 11.2 运维风险

| 风险 | 影响 | 概率 | 缓解措施 |
|------|--------|-------------|------------|
| 16 个 ENI 的子网 IP 不足 | 高 | 中 | 部署前验证，清晰的错误消息 |
| GPU 节点成本意外增加 | 中 | 低 | 默认 desired_size=0，需显式启用 |
| 配额设置错误导致 Pod 失败 | 中 | 中 | Admission webhook 验证，合理的默认值 |

---

## 12. 参考资料

**AWS 文档**:
- [EFA 用户指南](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [P5 实例](https://aws.amazon.com/ec2/instance-types/p5/)
- [EBS 卷类型](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)

**Kubernetes 文档**:
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
- [Resource Management for Pods](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Ephemeral Storage](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage)

**存储配额**:
- [XFS Project Quotas](https://www.kernel.org/doc/html/latest/filesystems/xfs-self-describing-metadata.html)
- [Linux Disk Quotas](https://wiki.archlinux.org/title/Disk_quota)

---

## 13. 术语表

- **EFA**: Elastic Fabric Adapter (弹性网络适配器)
- **ENI**: Elastic Network Interface (弹性网络接口)
- **NCCL**: NVIDIA Collective Communications Library (NVIDIA 集合通信库)
- **RDMA**: Remote Direct Memory Access (远程直接内存访问)
- **Project ID**: XFS 文件系统用于配额管理的项目标识符
- **Ephemeral Storage**: Kubernetes 中的临时存储 (容器层 + emptyDir)

---

**文档状态**: 草稿 - 待实施

**审批日期**: _____________

---

**设计文档结束**
