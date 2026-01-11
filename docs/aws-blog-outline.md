# 企业级 EKS 集群生产环境配置最佳实践

在帮助企业客户将工作负载迁移到 Amazon EKS 的过程中，AWS 解决方案架构师团队总结了一套经过验证的最佳实践。本文将分享如何在 **25-35 分钟内**部署一个满足企业级安全合规要求的生产就绪 EKS 集群，并提供完整的自动化部署脚本。

> **本文亮点**
> - 使用 Pod Identity 替代 IRSA，简化 IAM 管理
> - 容器运行时存储与系统盘隔离，提升节点稳定性
> - 支持 EBS、EFS、FSx、S3 四种存储场景
> - 原生支持 GPU 实例（P5/P5en/P6）与 EFA 网络
> - 私有 API Endpoint 满足高安全要求的企业级场景
> - 全程脚本化部署，幂等且 CI/CD 友好

---

## 企业客户面临的挑战

在与众多企业客户的合作中，生产环境 EKS 部署面临五类共性问题：

**安全合规方面**，默认的 EKS 集群会将 API Server 暴露在公网。虽然可以通过配置公有 API Endpoint 的 IP 白名单来限制访问来源，但对于安全要求更高的企业客户，将 API Server 完全置于私有网络是更彻底的方案。同时，传统的 IRSA（IAM Roles for Service Accounts）方案需要为每个集群配置 OIDC Provider，增加了 IAM 管理的复杂度。

**节点稳定性方面**，containerd 默认将容器镜像和运行时数据存储在系统根卷的 `/var/lib/containerd` 目录。当容器频繁拉取镜像或写入大量日志时，会与系统 I/O 产生竞争，严重时导致节点进入 `DiskPressure` 或 `NotReady` 状态。

**存储需求方面**，不同的应用场景对存储有截然不同的要求：数据库需要高性能块存储，微服务需要共享文件系统，机器学习训练需要高吞吐并行存储，数据分析需要直接访问 S3 数据湖。

**弹性扩缩容方面**，GPU 实例的配置尤为复杂，涉及实例类型选择、EFA 网络配置、驱动安装等多个环节。同时，客户希望能灵活使用 Spot 实例、ODCR（On-Demand Capacity Reservations）等方式优化成本。

**部署效率方面**，手动部署一个生产级集群往往需要数小时甚至数天，且容易出现配置不一致的问题，难以在多个环境间复现。

本文将逐一介绍这些问题的解决方案，并最终将所有方案沉淀为标准化的自动化部署脚本。

## 整体架构概览

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                        AWS Cloud                                          │
│  ┌────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                    VPC (Multi-AZ)                                   │  │
│  │                                                                                     │  │
│  │  ┌─────────────────────────────────────────────────────────────────────────────┐   │  │
│  │  │                              Private Subnets                                 │   │  │
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

下面将深入探讨每个问题的解决方案。

---

## 私有 API Endpoint：纵深防御的网络架构

EKS 集群的 API Server 访问控制有两种主流方案：

**公有 API Endpoint + IP 白名单**：保留公有 Endpoint，通过配置 `publicAccessCidrs` 限制可访问的源 IP 范围。这种方案配置简单，适合大多数场景，运维人员可以从办公网络直接访问集群。

**私有 API Endpoint**：完全禁用公有 Endpoint，API Server 仅在 VPC 内部可达。这种方案提供了更强的网络隔离，API Server 的 DNS 解析只返回 VPC 内部 IP，从根本上消除了公网暴露面。

对于安全要求更高的企业客户，推荐采用私有 API Endpoint 方案。虽然这会增加一定的运维复杂度（需要通过堡垒机或 VPN 访问集群），但它提供了纵深防御的安全架构，是零信任网络的重要组成部分。

采用私有 API Endpoint 需要配合以下组件：

**VPC Endpoints**：由于集群位于私有网络，节点和 Pod 无法通过 NAT Gateway 访问 AWS 服务。需要创建 13 个 VPC Endpoints，包括 ECR（容器镜像）、S3（存储）、SSM（管理）、STS（身份验证）、EC2、EKS、EBS、EFS、FSx、CloudWatch 等。这不仅解决了连通性问题，还能降低数据传输成本。

**堡垒机访问模式**：运维人员通过 AWS Systems Manager Session Manager 连接到堡垒机，再从堡垒机访问 EKS API。这种方式无需开放 SSH 端口，所有操作都有完整的审计日志。

```
┌─────────────────────────────────────────────────────────────┐
│  VPC                                                        │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │  Bastion    │───▶│  EKS API    │    │  VPC Endpoints  │ │
│  │  (SSM)      │    │  (Private)  │    │  (ECR/S3/SSM..) │ │
│  └─────────────┘    └─────────────┘    └─────────────────┘ │
│         │                  │                    │           │
│         └──────────────────┴────────────────────┘           │
│                       Private Subnets                       │
└─────────────────────────────────────────────────────────────┘
```

---

## VPC CNI 网络优化

Amazon VPC CNI 是 EKS 的默认网络插件，为每个 Pod 分配 VPC 内的真实 IP 地址，使 Pod 能够直接与 VPC 内的其他资源通信。本方案对 VPC CNI 进行了以下优化配置：

**前缀委派（Prefix Delegation）**：默认情况下，每个 ENI 的辅助 IP 数量受实例类型限制。启用前缀委派后，每个 ENI 槽位可分配一个 /28 前缀（16 个 IP），显著提升单节点可运行的 Pod 数量。对于 m8g.xlarge 实例，Pod 容量可提升约 2-3 倍。

**Pod 安全组**：通过启用 `ENABLE_POD_ENI`，可以为特定 Pod 分配独立的安全组，实现细粒度的网络访问控制。这对于需要直接访问 RDS、ElastiCache 等 VPC 资源的应用尤为重要。

**网络策略支持**：VPC CNI 原生支持 Kubernetes NetworkPolicy，无需额外安装 Calico 等第三方组件，简化了集群的网络策略管理。

```
VPC CNI 配置
├── ENABLE_PREFIX_DELEGATION=true     # 启用前缀委派
├── ENABLE_POD_ENI=true               # 启用 Pod 安全组
├── POD_SECURITY_GROUP_ENFORCING_MODE=standard
├── WARM_PREFIX_TARGET=1              # 预热前缀数量
└── MINIMUM_IP_TARGET=10              # 最小 IP 预留
```

这些优化使得 VPC CNI 能够更好地支持高密度部署场景，同时保持与 VPC 原生网络的完全兼容。

---

## Pod Identity：简化 IAM 权限管理

传统的 IRSA（IAM Roles for Service Accounts）方案虽然解决了 Pod 级别的 IAM 权限问题，但存在明显的管理负担：每个集群需要配置独立的 OIDC Provider，IAM 信任策略中包含集群特定的 OIDC URL，跨账户配置繁琐，且 OIDC Provider 可能成为单点故障。

**EKS Pod Identity** 是 AWS 在 2023 年推出的新方案，它从根本上简化了这一流程：

| 维度 | IRSA | Pod Identity |
|------|------|--------------|
| 依赖组件 | OIDC Provider | EKS Pod Identity Agent |
| IAM 信任策略 | 包含集群 OIDC URL | 通用的简化策略 |
| 管理复杂度 | 高（每集群一个 OIDC） | 低（AWS 托管） |
| 跨账户支持 | 配置复杂 | 原生支持 |

使用 Pod Identity 只需三步：

```bash
# 创建 Pod Identity 角色（信任策略由 AWS 托管）
create_pod_identity_role "MyServiceRole"

# 附加所需的 IAM 策略
attach_managed_policy "MyServiceRole" "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"

# 将角色关联到 Kubernetes ServiceAccount
create_pod_identity_association "my-namespace" "my-service-account" "$ROLE_ARN"
```

本方案的部署脚本为所有组件（Cluster Autoscaler、AWS Load Balancer Controller、CSI Drivers 等）都采用了 Pod Identity，彻底告别 OIDC Provider 的管理负担。

---

## 容器运行时存储隔离：提升节点稳定性

这是一个经常被忽视但影响巨大的问题。在默认配置下，containerd 将所有容器镜像和运行时数据存储在系统根卷的 `/var/lib/containerd` 目录。当应用频繁拉取大型镜像或产生大量容器日志时，会与操作系统的 I/O 竞争，严重时会导致根卷空间耗尽，节点进入 `DiskPressure` 甚至 `NotReady` 状态。

解决方案采用**双 EBS 卷 + LVM 架构**：

```
┌─────────────────────────────────────────────────────┐
│  EC2 Instance (m8g.xlarge)                          │
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

实现这一架构的关键在于 **Launch Template** 和 **cloud-boothook** 的配合：

Launch Template 定义了双 EBS 卷配置——50GB 的 gp3 根卷用于操作系统，100GB 的 gp3 数据卷（3000 IOPS、125 MB/s 吞吐）用于容器运行时。两个卷都启用了 KMS 加密。

cloud-boothook 脚本会在 EKS bootstrap 之前执行，完成以下操作：创建 LVM 物理卷和卷组、创建逻辑卷、格式化为 XFS 文件系统、挂载到 `/var/lib/containerd`、使用 rsync 迁移 AMI 预缓存的 pause 镜像、写入 fstab 确保重启后自动挂载。

这种设计带来了显著的收益：容器 I/O 不再影响系统盘，节点稳定性大幅提升；可以独立调整数据卷的大小和 IOPS；XFS 原生支持 project quota，为未来的 Pod 磁盘配额功能预留了能力；即使数据卷满了，系统也能正常启动，便于故障恢复。

---

## 全场景存储支持

现代云原生应用对存储有多样化的需求。本方案通过四种 CSI Driver 实现全场景覆盖：

**Amazon EBS CSI Driver** 提供高性能块存储，适用于数据库和有状态应用。预配置了 gp3（通用场景，3000 IOPS 基线）和 io2（高性能场景，最高 64000 IOPS）两种 StorageClass。

**Amazon EFS CSI Driver** 提供完全托管的弹性文件系统，支持 RWX（ReadWriteMany）访问模式，多个 Pod 可以同时读写同一个文件系统，非常适合需要共享数据的微服务架构。

**Amazon FSx for Lustre CSI Driver** 提供高吞吐、低延迟的并行文件系统，是 GPU 训练工作负载的理想选择。FSx for Lustre 能够与 S3 无缝集成，支持从 S3 数据湖高效加载训练数据，单文件系统可提供数百 GB/s 的聚合吞吐量，满足大规模分布式训练对存储带宽的需求。

**Mountpoint for Amazon S3 CSI Driver** 允许 Pod 直接挂载 S3 存储桶，无需修改应用代码即可访问数据湖中的海量数据。特别是 **S3 Express One Zone** 提供个位数毫秒级延迟和高达数十 GB/s 的吞吐能力，为 GPU 推理场景下的模型加载和 checkpoint 读写提供了云原生的高性能存储选择。

FSx for Lustre 与 S3 Express One Zone 的组合，为 GPU 训练和推理工作负载提供了灵活多样的存储方案：训练阶段使用 FSx for Lustre 获得极致的并行 I/O 性能，推理阶段使用 S3 Express One Zone 实现模型的快速加载和弹性扩展。

| CSI Driver | 存储类型 | 访问模式 | 典型场景 |
|------------|----------|----------|----------|
| EBS CSI | 块存储 | RWO | 数据库、有状态应用 |
| EFS CSI | 共享文件系统 | RWX | 多 Pod 共享数据 |
| FSx Lustre CSI | 高性能并行文件系统 | RWX | GPU 训练、HPC |
| S3 CSI (Mountpoint) | 对象存储 | ROX/RWX | GPU 推理、数据湖 |

---

## GPU 工作负载与 EFA 网络

随着生成式 AI 的爆发，越来越多的客户需要在 EKS 上运行 GPU 工作负载。然而，GPU 节点的配置远比普通节点复杂：需要选择合适的实例类型（P5、P5en、P6），配置多达 32 个 EFA 网络接口，安装 NVIDIA 驱动、EFA 驱动和 NCCL 插件。

本方案使用 **Managed Node Groups** 管理 GPU 节点，通过 Launch Template 预配置所有 EFA 网络接口：

```
GPU 实例网络配置
├── ENI 0: 主 IP + EFA（用于管理流量）
├── ENI 1-N: 仅 EFA（用于 NCCL 集合通信）
│   ├── p5.48xlarge:      N=31 (共 32 ENI)
│   ├── p5en.48xlarge:    N=15 (共 16 ENI)
│   └── p6-b200.48xlarge: N=7  (共 8 ENI)
├── NVIDIA 驱动: AMI 预装
├── EFA 驱动: AMI 预装
└── NCCL 插件: 自动部署
```

不同实例类型的 EFA 网卡数量有所不同：p5.48xlarge 支持 32 个 ENI，p5en.48xlarge 支持 16 个，p6-b200.48xlarge 支持 8 个。脚本会根据实例类型自动配置正确的网卡数量。

为满足不同的成本和可用性需求，本方案支持三种定价模式：

- **Spot 实例**：适合容错能力强的训练任务，可节省高达 90% 的成本
- **ODCR（On-Demand Capacity Reservations）**：保障容量的按需实例
- **Capacity Blocks**：按时间段预留的 GPU 容量，适合可预测的训练任务

---

## 自动化部署脚本

将上述所有解决方案整合为一套**幂等、非交互、CI/CD 友好**的部署脚本。

### 设计原则

**幂等性**：所有脚本都可以安全地重复执行。如果资源已存在，脚本会自动跳过并输出相应日志，不会产生重复资源或错误。

**非交互**：通过环境变量控制所有配置，无需人工确认。这使得脚本可以直接集成到 CI/CD 流水线中。

**模块化**：核心脚本（编号 0-7）必须按顺序执行，可选脚本（`option_*` 前缀）可以根据需求独立运行。

**可追溯**：详细的日志输出，便于故障排查和合规审计。

### 脚本结构

```
scripts/
├── 0_setup_env.sh                    # 环境变量加载
├── 1_enable_vpc_dns.sh               # VPC DNS 配置
├── 2_validate_network_environment.sh # 网络验证（可选）
├── 3_create_vpc_endpoints.sh         # VPC Endpoints
├── 4_install_eks_cluster.sh          # EKS 控制平面
├── 5_check_environment.sh            # 本地环境检查（可选）
├── 6_create_system_nodegroup.sh      # 系统节点组 (LVM)
├── 7_install_eks_addon.sh            # 核心 Addons
├── option_create_bastion.sh          # 堡垒机（可选）
├── option_install_csi_drivers.sh     # CSI Drivers（可选）
├── option_install_karpenter.sh       # Karpenter（可选）
├── option_install_gpu_nodegroups.sh  # GPU 节点组（可选）
└── pod_identity_helpers.sh           # Pod Identity 辅助函数
```

### 部署流程

整个部署过程分为四个阶段，总耗时约 25-35 分钟：

**网络准备阶段**（约 5 分钟）：启用 VPC DNS 支持，创建 13 个 VPC Endpoints，为私有集群建立与 AWS 服务的连通性。

**控制平面阶段**（约 8-10 分钟）：创建 EKS 集群，配置私有 API Endpoint，这是整个部署中耗时最长的步骤，因为需要等待 AWS 完成控制平面的配置。

**系统节点阶段**（约 8-12 分钟）：创建系统节点组，包含 3 个节点，每个节点都配置了 LVM 存储架构。系统节点用于运行集群基础设施组件。

**核心组件阶段**（约 5-8 分钟）：部署 Cluster Autoscaler、AWS Load Balancer Controller、EBS CSI Driver、Metrics Server 等核心组件。

### 快速开始

在堡垒机上执行以下命令即可完成部署：

```bash
# 配置环境变量
cp .env.example .env && vim .env

# 核心部署
./scripts/1_enable_vpc_dns.sh
./scripts/3_create_vpc_endpoints.sh
./scripts/4_install_eks_cluster.sh
./scripts/6_create_system_nodegroup.sh
./scripts/7_install_eks_addon.sh

# 按需安装可选组件
./scripts/option_install_csi_drivers.sh efs      # EFS 共享存储
./scripts/option_install_karpenter.sh            # Karpenter 自动扩缩容
./scripts/option_install_gpu_nodegroups.sh       # GPU 节点组
```

对于 CI/CD 场景，可以通过环境变量实现完全非交互：

```bash
# 安装 EFS CSI 驱动
INSTALL_DRIVERS=efs ./scripts/option_install_csi_drivers.sh

# 安装 S3 CSI 驱动（指定 bucket）
INSTALL_DRIVERS=s3 S3_BUCKET_ARNS='arn:aws:s3:::my-bucket' ./scripts/option_install_csi_drivers.sh
```

---

## 运维与故障排查

部署完成后，可以使用以下命令验证集群状态：

```bash
# 检查节点状态
kubectl get nodes -o wide

# 检查所有 Pod
kubectl get pods -A

# 验证 LVM 配置
kubectl debug node/<node-name> -it --image=amazonlinux -- \
  chroot /host bash -c "vgs && lvs && df -h /var/lib/containerd"

# 验证存储类
kubectl get storageclass
```

### 常见问题

**kubectl 连接超时**：由于集群使用私有 API Endpoint，必须从 VPC 内部访问。请确保通过堡垒机执行 kubectl 命令。

**节点 NotReady**：最常见的原因是 LVM 配置失败。登录节点查看 `/var/log/lvm-setup.log` 获取详细错误信息。

**CSI 挂载失败**：检查对应 CSI Driver 的 Pod Identity Association 是否正确配置。可以通过 `aws eks list-pod-identity-associations` 命令验证。

**GPU 节点无 EFA**：确认 Launch Template 中的网络接口配置正确，不同实例类型的 EFA 网卡数量不同。

---

## 最佳实践检查清单

在将集群用于生产环境之前，请确认以下安全配置：

- 私有 API Endpoint（API Server 不暴露公网）
- Pod Identity 替代 IRSA（简化 IAM 管理）
- VPC Endpoints 完整配置（13 个核心服务）
- EBS 卷加密（使用 KMS）
- IMDSv2 强制使用（防止 SSRF 攻击）
- 安全组最小权限原则

### 成本优化建议

**使用 Graviton 实例**：Graviton 处理器提供比同等 x86 实例高 40% 的性价比，脚本原生支持 Graviton 节点组。

**利用 VPC Endpoints**：VPC Endpoints 不仅提供安全性，还能避免数据通过 NAT Gateway 传输产生的费用。

**合理使用 Spot 实例**：对于无状态或可容错的工作负载，Spot 实例可以节省高达 90% 的成本。Karpenter 可以自动处理 Spot 中断。

**按需配置节点组大小**：根据实际工作负载配置合适的节点数量和实例类型，避免过度配置。

---

## 总结

本文从企业客户在 EKS 生产环境中面临的实际挑战出发，介绍了一套经过验证的解决方案：

针对**高安全要求**，本方案提供私有 API Endpoint 配合 13 个 VPC Endpoints，确保所有流量都在 VPC 内部传输，构建纵深防御的网络架构。

针对**网络性能优化**，通过 VPC CNI 前缀委派提升单节点 Pod 密度，支持 Pod 级别安全组实现细粒度访问控制。

针对**IAM 管理复杂度**，全面采用 Pod Identity 替代 IRSA，消除 OIDC Provider 的管理负担，简化跨账户访问配置。

针对**节点稳定性问题**，通过双 EBS 卷 + LVM 架构将容器运行时存储与系统盘隔离，从根本上解决 I/O 竞争问题。

针对**多样化存储需求**，提供 EBS、EFS、FSx、S3 四种 CSI Driver 的一键部署，覆盖块存储、共享文件系统、高性能存储和对象存储挂载等全部场景。

针对**GPU 工作负载**，通过 Managed Node Groups 预配置 EFA 网络接口，支持 P5、P5en、P6 等最新 GPU 实例，并提供 Spot、ODCR、Capacity Blocks 三种定价模式。

所有这些方案都已沉淀为标准化、自动化的部署脚本，实现 25-35 分钟完成生产级集群部署，幂等设计支持重复执行，非交互模式便于 CI/CD 集成。

希望这套方案能够帮助更多企业客户快速、安全地部署生产级 EKS 集群。完整的部署脚本和文档已在 GitHub 开源，欢迎试用和反馈。

---

## 关于作者

本文由 AWS 解决方案架构师团队撰写，基于多个企业客户的实际部署经验总结。如有问题或建议，欢迎通过 GitHub Issues 反馈。

---

*本文发布于 2026 年 1 月*
