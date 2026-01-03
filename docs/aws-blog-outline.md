# 企业级 EKS 集群生产环境配置最佳实践

---

## 文章逻辑

**客户技术问题 → 逐一解决 → 标准化自动化部署脚本**

---

## 技术亮点（Call-out Box）

| 亮点 | 说明 |
|------|------|
| **25-35 分钟** | 完成生产级集群部署 |
| **Pod Identity** | 替代 IRSA，简化 IAM 管理，无需 OIDC Provider |
| **容器运行时存储分离** | containerd 数据目录迁移至独立 LVM-based EBS 数据盘，与系统根卷 I/O 隔离 |
| **双 EBS 卷架构** | 50GB 根卷 + 100GB 数据卷，cloud-boothook 自动完成 LVM 配置和数据迁移 |
| **4 种 CSI Driver** | EBS/EFS/FSx/S3 全存储场景覆盖 |
| **GPU + EFA** | P5/P5en/P6 实例 + EFA 网络，支持 AI/ML 分布式训练 |
| **私有 API Endpoint** | API Server 不暴露公网，满足金融/医疗合规要求 |
| **全程脚本化** | 幂等、非交互，CI/CD 友好 |

---

## 大纲

### 1. 引言：企业客户面临的 EKS 生产环境挑战

在帮助企业客户部署生产级 EKS 集群的过程中，我们发现以下技术问题反复出现：

| 问题类别 | 具体挑战 |
|----------|----------|
| **安全合规** | API Server 暴露公网、IAM 权限管理复杂（IRSA/OIDC） |
| **节点稳定性** | containerd 与系统共用根卷，I/O 竞争导致节点 NotReady |
| **存储需求多样** | 块存储、共享文件系统、高性能存储、对象存储挂载 |
| **弹性扩缩容** | GPU 节点支持、成本优化（Spot/ODCR） |
| **部署效率** | 手动部署耗时、配置不一致、难以复现 |

本文将逐一分析这些问题，并介绍我们如何将解决方案沉淀为**标准化、自动化的部署脚本**。

#### 整体架构图

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                        AWS Cloud                                          │
│  ┌────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                    VPC (Multi-AZ)                                   │  │
│  │                                                                                     │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐   │  │
│  │  │                           Private Subnets (3-4 AZ)                           │   │  │
│  │  │                                                                              │   │  │
│  │  │   ┌─────────────┐     ┌──────────────────────────────────────────────────┐  │   │  │
│  │  │   │   Bastion   │     │              EKS Cluster                          │  │   │  │
│  │  │   │   (SSM)     │────▶│  ┌─────────────────────────────────────────────┐  │  │   │  │
│  │  │   └─────────────┘     │  │         Control Plane (AWS Managed)         │  │  │   │  │
│  │  │                       │  │         Private API Endpoint                 │  │  │   │  │
│  │  │                       │  └─────────────────────────────────────────────┘  │  │   │  │
│  │  │                       │                       │                           │  │   │  │
│  │  │                       │  ┌─────────────────────────────────────────────┐  │  │   │  │
│  │  │                       │  │      System Node Group (eks-utils)          │  │  │   │  │
│  │  │                       │  │  ┌───────────┐ ┌───────────┐ ┌───────────┐  │  │  │   │  │
│  │  │                       │  │  │  Node 1   │ │  Node 2   │ │  Node 3   │  │  │  │   │  │
│  │  │                       │  │  │ ┌───────┐ │ │ ┌───────┐ │ │ ┌───────┐ │  │  │  │   │  │
│  │  │                       │  │  │ │Root 50G│ │ │ │Root 50G│ │ │ │Root 50G│ │  │  │  │   │  │
│  │  │                       │  │  │ ├───────┤ │ │ ├───────┤ │ │ ├───────┤ │  │  │  │   │  │
│  │  │                       │  │  │ │LVM 100G│ │ │ │LVM 100G│ │ │ │LVM 100G│ │  │  │  │   │  │
│  │  │                       │  │  │ │containerd│ │ │containerd│ │ │containerd│  │  │   │  │
│  │  │                       │  │  │ └───────┘ │ │ └───────┘ │ │ └───────┘ │  │  │  │   │  │
│  │  │                       │  │  └───────────┘ └───────────┘ └───────────┘  │  │  │   │  │
│  │  │                       │  │  Runs: CoreDNS, Autoscaler, LB Controller,  │  │  │   │  │
│  │  │                       │  │        CSI Drivers, Metrics Server          │  │  │   │  │
│  │  │                       │  └─────────────────────────────────────────────┘  │  │   │  │
│  │  │                       │                       │                           │  │   │  │
│  │  │                       │  ┌─────────────────────────────────────────────┐  │  │   │  │
│  │  │                       │  │    Worker Nodes (Karpenter Managed)         │  │  │   │  │
│  │  │                       │  │    - On-Demand / Spot / ODCR                │  │  │   │  │
│  │  │                       │  │    - GPU (P5/P5en/P6) + EFA                 │  │  │   │  │
│  │  │                       │  └─────────────────────────────────────────────┘  │  │   │  │
│  │  │                       └──────────────────────────────────────────────────┘  │   │  │
│  │  │                                                                              │   │  │
│  │  └──────────────────────────────────────────────────────────────────────────────┘   │  │
│  │                                          │                                          │  │
│  │  ┌───────────────────────────────────────┼───────────────────────────────────────┐  │  │
│  │  │                            VPC Endpoints (13+)                                │  │  │
│  │  │  ECR | S3 | SSM | STS | EC2 | EKS | EBS | EFS | FSx | CloudWatch | ...       │  │  │
│  │  └───────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                          │                                          │  │
│  │  ┌───────────────────────────────────────┼───────────────────────────────────────┐  │  │
│  │  │                              Storage Layer                                    │  │  │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────────┐  ┌─────────────────────────────┐  │  │  │
│  │  │  │ EBS CSI │  │ EFS CSI │  │ FSx Lustre  │  │ S3 CSI (Mountpoint)         │  │  │  │
│  │  │  │ (RWO)   │  │ (RWX)   │  │ CSI (RWX)   │  │ (ROX) + Express One Zone    │  │  │  │
│  │  │  └─────────┘  └─────────┘  └─────────────┘  └─────────────────────────────┘  │  │  │
│  │  └───────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                                     │  │
│  └─────────────────────────────────────────────────────────────────────────────────────┘  │
│                                          │                                                │
│  ┌───────────────────────────────────────┼────────────────────────────────────────────┐  │
│  │                                 IAM Layer                                          │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐  │  │
│  │  │  Pod Identity (替代 IRSA)                                                    │  │  │
│  │  │  - EKS Pod Identity Agent                                                    │  │  │
│  │  │  - 简化 IAM 信任策略                                                          │  │  │
│  │  │  - 无需 OIDC Provider                                                        │  │  │
│  │  └─────────────────────────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

### 2. 问题一：API Server 安全暴露 → 私有 API Endpoint

#### 2.1 客户痛点

- 默认 EKS 集群 API Server 暴露公网
- 金融、医疗等行业合规要求禁止公网访问
- 需要复杂的网络配置才能实现私有访问

#### 2.2 解决方案

- 创建仅私有 API Endpoint 的 EKS 集群
- 配置 VPC Endpoints（13 个）实现内网访问 AWS 服务
- 堡垒机部署模式：通过 SSM Session Manager 访问

#### 2.3 架构图

```
┌─────────────────────────────────────────────────────────────┐
│  VPC                                                        │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │  Bastion    │───▶│  EKS API    │    │  VPC Endpoints  │ │
│  │  (SSM)      │    │  (Private)  │    │  (ECR/S3/SSM..) │ │
│  └─────────────┘    └─────────────┘    └─────────────────┘ │
│         │                  │                    │           │
│         └──────────────────┴────────────────────┘           │
│                    Private Subnets (3-4 AZ)                 │
└─────────────────────────────────────────────────────────────┘
```

---

### 3. 问题二：IAM 权限管理复杂 → Pod Identity 替代 IRSA

#### 3.1 客户痛点

- IRSA 需要为每个集群配置 OIDC Provider
- IAM 信任策略包含 OIDC URL，管理复杂
- 跨账户场景配置繁琐
- OIDC Provider 成为单点故障

#### 3.2 解决方案：Pod Identity

| 维度 | IRSA | Pod Identity |
|------|------|--------------|
| 依赖 | OIDC Provider | EKS Pod Identity Agent |
| IAM 配置 | 信任策略含 OIDC URL | 简化的信任策略 |
| 管理复杂度 | 高（每集群一个 OIDC） | 低（AWS 托管） |
| 跨账户 | 复杂 | 原生支持 |

#### 3.3 实现模式

```bash
# 1. 创建 Pod Identity 角色
create_pod_identity_role "MyServiceRole"

# 2. 附加策略
attach_managed_policy "MyServiceRole" "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"

# 3. 创建 Pod Identity Association
create_pod_identity_association "my-namespace" "my-service-account" "$ROLE_ARN"
```

---

### 4. 问题三：节点存储 I/O 竞争 → 容器运行时迁移至独立 LVM 数据盘

#### 4.1 客户痛点

- 默认配置：containerd 位于根卷 `/var/lib/containerd`
- 容器镜像拉取、日志写入与系统 I/O 竞争
- 根卷空间耗尽导致节点 `DiskPressure` 或 `NotReady`
- 无法独立扩展容器存储容量和 IOPS

#### 4.2 解决方案：双 EBS + LVM

```
┌─────────────────────────────────────────────────────┐
│  EC2 Instance (m7i.2xlarge)                         │
├─────────────────────────────────────────────────────┤
│  /dev/xvda (50GB gp3)                              │
│    └── /  (系统根卷: OS, kubelet, logs)            │
├─────────────────────────────────────────────────────┤
│  /dev/xvdb (100GB gp3, 3000 IOPS, 125 MB/s)        │
│    └── LVM: vg_data/lv_containerd                  │
│        └── /var/lib/containerd (XFS)               │
│            ├── 容器镜像层                           │
│            ├── 容器可写层                           │
│            └── containerd 元数据                    │
└─────────────────────────────────────────────────────┘
```

#### 4.3 实现机制

- **Launch Template**：定义双 EBS 卷（加密、gp3）
- **cloud-boothook**：在 EKS bootstrap 前执行 LVM 配置
- **自动迁移**：rsync 迁移 AMI 预缓存镜像（pause image）
- **持久化**：写入 fstab，重启后自动挂载

#### 4.4 收益

| 收益 | 说明 |
|------|------|
| I/O 隔离 | 容器运行时不影响系统盘，节点更稳定 |
| 独立扩展 | 可单独调整数据卷大小和 IOPS |
| 配额就绪 | XFS 支持 project quota，为 Pod 磁盘配额预留能力 |
| 故障隔离 | 数据卷满不会导致系统无法启动 |

---

### 5. 问题四：多样化存储需求 → 4 种 CSI Driver 全覆盖

#### 5.1 客户痛点

- 有状态应用需要块存储（数据库）
- 多 Pod 需要共享文件系统
- ML/HPC 需要高性能并行存储
- 数据湖场景需要挂载 S3

#### 5.2 解决方案：CSI Driver 矩阵

| CSI Driver | 存储类型 | 访问模式 | 典型场景 |
|------------|----------|----------|----------|
| EBS CSI | 块存储 | RWO | 数据库、有状态应用 |
| EFS CSI | 共享文件系统 | RWX | 多 Pod 共享数据 |
| FSx Lustre CSI | 高性能并行文件系统 | RWX | HPC、ML 训练 |
| S3 CSI (Mountpoint) | 对象存储 | ROX/RWX | 数据湖、ML 数据集 |

#### 5.3 StorageClass 设计

```yaml
# gp3（默认）：通用场景
storageClassName: gp3    # 3000 IOPS 基线

# io2：高性能场景
storageClassName: io2    # 可配置 IOPS (最高 64000)

# EFS：共享存储
storageClassName: efs-sc # 多 Pod 共享

# FSx Lustre：HPC/ML
storageClassName: fsx-sc # 高吞吐
```

---

### 6. 问题五：GPU 工作负载支持 → Karpenter + EFA 网络

#### 6.1 客户痛点

- GPU 实例类型选择复杂（P5/P5en/P6）
- EFA 网络配置繁琐（16 网卡）
- 驱动安装（NVIDIA、EFA、NCCL）容易出错
- 成本优化需求（Spot、ODCR、Capacity Blocks）

#### 6.2 解决方案

- **Karpenter** 动态调度 GPU 节点
- **EC2NodeClass** 预配置 EFA 网络（ENI 0 带 IP，ENI 1-15 仅 EFA）
- **NodePool** 支持多种定价模式

#### 6.3 GPU 节点配置

```
P5/P5en/P6 Instance
├── 16 Network Interfaces
│   ├── ENI 0: Primary IP + EFA
│   └── ENI 1-15: EFA only (no IP)
├── NVIDIA Driver: Auto-installed
├── EFA Driver: Auto-installed
└── NCCL Plugin: Auto-installed
```

---

### 7. 解决方案沉淀：标准化自动化部署脚本

将上述解决方案沉淀为**幂等、非交互、CI/CD 友好**的部署脚本。

#### 7.1 设计原则

| 原则 | 说明 |
|------|------|
| **幂等性** | 可重复执行，已存在资源自动跳过 |
| **非交互** | 环境变量控制，无需人工确认 |
| **模块化** | 核心脚本（必选）+ 可选脚本（按需） |
| **可追溯** | 详细日志，便于排查 |

#### 7.2 脚本结构

```
scripts/
├── 0_setup_env.sh              # 环境变量加载
├── 1_enable_vpc_dns.sh         # VPC DNS 配置
├── 2_validate_network.sh       # 网络验证（可选）
├── 3_create_vpc_endpoints.sh   # VPC Endpoints
├── option_create_bastion.sh         # 堡垒机
├── 5_install_eks_cluster.sh    # EKS 控制平面
├── 6_create_system_nodegroup.sh # 系统节点组 (LVM)
├── 7_install_eks_addon.sh      # 核心 Addons
├── option_install_csi_drivers.sh  # CSI Drivers（可选）
├── option_install_karpenter.sh    # Karpenter（可选）
└── pod_identity_helpers.sh     # Pod Identity 辅助函数
```

#### 7.3 部署流程

| 阶段 | 脚本 | 耗时 | 产出 |
|------|------|------|------|
| 网络准备 | 1-3 | ~5 分钟 | VPC DNS、13 个 Endpoints |
| 控制平面 | 5 | 8-10 分钟 | EKS 集群（私有 API） |
| 系统节点 | 6 | 8-12 分钟 | 3 节点 + LVM 配置 |
| 核心组件 | 7 | 5-8 分钟 | Autoscaler、LB Controller、CSI |
| **总计** | - | **25-35 分钟** | 生产就绪集群 |

#### 7.4 一键部署示例

```bash
# 配置环境
cp .env.example .env && nano .env

# 部署（在堡垒机上执行）
./scripts/1_enable_vpc_dns.sh
./scripts/3_create_vpc_endpoints.sh
./scripts/5_install_eks_cluster.sh
./scripts/6_create_system_nodegroup.sh
./scripts/7_install_eks_addon.sh

# 可选：安装额外组件
./scripts/option_install_csi_drivers.sh efs
./scripts/option_install_karpenter.sh
```

#### 7.5 非交互模式（CI/CD）

```bash
# 自动删除旧节点组
AUTO_DELETE_NODEGROUP=yes ./scripts/6_create_system_nodegroup.sh

# 安装 CSI 驱动
INSTALL_DRIVERS=efs ./scripts/option_install_csi_drivers.sh

# 安装 S3 CSI（指定 bucket）
INSTALL_DRIVERS=s3 S3_BUCKET_ARNS='arn:aws:s3:::my-bucket' ./scripts/option_install_csi_drivers.sh
```

---

### 8. 运维与故障排查

#### 8.1 常见问题速查

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| kubectl 超时 | 私有 API，需从 VPC 内访问 | 使用堡垒机 |
| 节点 NotReady | LVM 配置失败 | 查看 `/var/log/lvm-setup.log` |
| CSI 挂载失败 | Pod Identity 未配置 | 检查 Pod Identity Association |
| GPU 节点无 EFA | EC2NodeClass 配置错误 | 验证网卡配置 |

#### 8.2 验证命令

```bash
# 集群状态
kubectl get nodes -o wide
kubectl get pods -A

# LVM 验证
kubectl debug node/<node-name> -it --image=busybox -- \
  chroot /host bash -c "vgs && lvs && df -h /var/lib/containerd"

# CSI 验证
kubectl get storageclass
kubectl get pvc -A
```

---

### 9. 最佳实践总结

#### 安全检查清单

- [x] 私有 API Endpoint
- [x] Pod Identity 替代 IRSA
- [x] VPC Endpoints 完整配置
- [x] EBS 卷加密
- [x] IMDSv2 强制使用
- [x] 安全组最小权限

#### 成本优化建议

- Graviton 实例（性价比 +40%）
- VPC Endpoints 减少 NAT 费用
- Spot 实例用于非关键工作负载
- 合理配置节点组大小

---

### 10. 结论

本文从企业客户在 EKS 生产环境中面临的实际技术问题出发：

1. **API 安全暴露** → 私有 API Endpoint + VPC Endpoints
2. **IAM 管理复杂** → Pod Identity 替代 IRSA
3. **节点存储 I/O 竞争** → 容器运行时迁移至独立 LVM 数据盘
4. **多样化存储需求** → 4 种 CSI Driver 全覆盖
5. **GPU 工作负载** → Karpenter + EFA 网络

最终将这些解决方案沉淀为**标准化、自动化的部署脚本**，实现：
- **25-35 分钟**完成生产级集群部署
- **幂等、非交互**，支持 CI/CD 集成
- **可重复、可追溯**，降低运维成本

---

## 附录：组件版本矩阵

| 组件 | 版本 | 安装方式 |
|------|------|----------|
| Kubernetes | 1.34 | EKS 托管 |
| VPC CNI | v1.18.5 | EKS Addon |
| CoreDNS | v1.11.3 | EKS Addon |
| Pod Identity Agent | v1.3.4 | EKS Addon |
| EBS CSI Driver | v1.37.0 | EKS Addon |
| Metrics Server | v0.7.2 | EKS Addon |
| Cluster Autoscaler | v1.34.2 | Helm |
| AWS LB Controller | v1.13.0 | Helm |
| EFS CSI Driver | 可选 | Manifest |
| FSx CSI Driver | 可选 | Manifest |
| S3 CSI Driver | 可选 | Kustomize |
| Karpenter | 可选 | Helm |

---

**作者**: Platform Team
**日期**: 2026-01-03
**版本**: v1.0
