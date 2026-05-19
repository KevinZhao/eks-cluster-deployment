# 企业级 EKS 集群生产环境配置最佳实践

**摘要：** 本文分享 AWS 解决方案架构师团队在帮助企业客户将工作负载迁移到 Amazon EKS 过程中总结的一套生产环境部署最佳实践。文章从企业客户面临的五类共性挑战出发，介绍如何在约 30 分钟内部署一个满足企业级安全合规要求的生产就绪 EKS 集群，覆盖私有 API Endpoint、VPC Endpoints 全连通、Pod Identity 简化 IAM、容器运行时存储隔离、四类 CSI Driver 全场景存储等关键设计决策，并提供完整的幂等、非交互、CI/CD 友好的自动化部署脚本。

**目录**

01 [一、企业客户面临的挑战：五类共性问题](#section1)
02 [二、整体架构概览：私有集群的全景视图](#section2)
03 [三、私有 API Endpoint：纵深防御的网络架构](#section3)
04 [四、VPC CNI 网络优化：精细化 IP 预热](#section4)
05 [五、Pod Identity：简化 IAM 权限管理](#section5)
06 [六、容器运行时存储隔离：提升节点稳定性](#section6)
07 [七、全场景存储支持：四种 CSI Driver](#section7)
08 [八、自动化部署脚本：幂等、非交互、CI/CD 友好](#section8)
09 [九、可选组件：GPU 节点组与 Karpenter](#section9)
10 [十、运维与故障排查：部署后的快速验证](#section10)
11 [十一、生产环境部署检查清单：上线前自检](#section11)
12 [十二、成本优化建议：在安全与预算之间取得平衡](#section12)
13 [十三、总结：一套可复制的企业级 EKS 部署方案](#section13)

---

## 一、企业客户面临的挑战：五类共性问题

在与众多企业客户的合作中，生产环境 EKS 部署面临五类共性问题：

**安全合规方面**，默认的 EKS 集群会将 API Server 暴露在公网。虽然可以通过配置公有 API Endpoint 的 IP 白名单来限制访问来源，但对于安全要求更高的企业客户，将 API Server 完全置于私有网络是更彻底的方案。同时，传统的 IRSA（IAM Roles for Service Accounts）方案需要为每个集群配置 OIDC Provider，增加了 IAM 管理的复杂度。

**节点稳定性方面**，containerd 默认将容器镜像和运行时数据存储在系统根卷的 `/var/lib/containerd` 目录。当容器频繁拉取镜像或写入大量日志时，会与系统 I/O 产生竞争，严重时导致节点进入 `DiskPressure` 或 `NotReady` 状态。

**存储需求方面**，不同的应用场景对存储有截然不同的要求：数据库需要高性能块存储，微服务需要共享文件系统，机器学习训练需要高吞吐并行存储，数据分析需要直接访问 S3 数据湖。

**弹性扩缩容方面**，GPU 实例的配置尤为复杂，涉及实例类型选择、EFA 网络配置、驱动安装等多个环节。同时，客户希望能灵活使用 Spot 实例、ODCR（On-Demand Capacity Reservations）等方式优化成本。

**部署效率方面**，手动部署一个生产级集群往往需要数小时甚至数天，且容易出现配置漂移的问题，难以在多个环境间复现。

本文将逐一介绍这些问题的解决方案，并最终将所有方案沉淀为标准化的自动化部署脚本。

## 二、整体架构概览：私有集群的全景视图

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
│  │  │                       │  │  │ │Root50G│ │ │ │Root50G│ │ │ │Root50G│ │  │  │  │   │  │
│  │  │                       │  │  │ ├───────┤ │ │ ├───────┤ │ │ ├───────┤ │  │  │  │   │  │
│  │  │                       │  │  │ │LVM 100│ │ │ │LVM 100│ │ │ │LVM 100│ │  │  │  │   │  │
│  │  │                       │  │  │ │ctnr fs│ │ │ │ctnr fs│ │ │ │ctnr fs│ │  │  │  │   │  │
│  │  │                       │  │  │ └───────┘ │ │ └───────┘ │ │ └───────┘ │  │  │  │   │  │
│  │  │                       │  │  └───────────┘ └───────────┘ └───────────┘  │  │  │   │  │
│  │  │                       │  │  Runs: CoreDNS, Autoscaler, LB Controller,  │  │  │   │  │
│  │  │                       │  │        CSI Drivers, Metrics Server          │  │  │   │  │
│  │  │                       │  └─────────────────────────────────────────────┘  │  │   │  │
│  │  │                       │                       │                           │  │   │  │
│  │  │                       │  ┌─────────────────────────────────────────────┐  │  │   │  │
│  │  │                       │  │    Application Node Groups                   │  │  │   │  │
│  │  │                       │  │    - Managed NG (默认) / Karpenter (可选)    │  │  │   │  │
│  │  │                       │  │    - GPU + EFA (可选，详见第二篇)            │  │  │   │  │
│  │  │                       │  └─────────────────────────────────────────────┘  │  │   │  │
│  │  │                       └──────────────────────────────────────────────────┘  │   │  │
│  │  │                                                                              │   │  │
│  │  └──────────────────────────────────────────────────────────────────────────────┘   │  │
│  │                                          │                                          │  │
│  │  ┌───────────────────────────────────────┼───────────────────────────────────────┐  │  │
│  │  │                  VPC Endpoints (13 Interface + 1 S3 Gateway)                   │  │  │
│  │  │  EKS | EKS-Auth | STS | ECR.api | ECR.dkr | EC2 | EFS | Logs |                │  │  │
│  │  │  Autoscaling | ELB | SSM | SSMMessages | EC2Messages | S3 (Gateway)           │  │  │
│  │  └───────────────────────────────────────────────────────────────────────────────┘  │  │
│  │                                          │                                          │  │
│  │  ┌───────────────────────────────────────┼───────────────────────────────────────┐  │  │
│  │  │                              Storage Layer                                    │  │  │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────────┐  ┌─────────────────────────────┐  │  │  │
│  │  │  │ EBS CSI │  │ EFS CSI │  │ FSx Lustre  │  │ S3 CSI (Mountpoint)         │  │  │  │
│  │  │  │ (RWO)   │  │ (RWX)   │  │ CSI (RWX)   │  │ (RWX, 非POSIX) + Express 1Z │  │  │  │
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

> **节点管理策略说明**：本方案的**系统节点组**（3 个节点，运行 CoreDNS / CSI / LB Controller 等基础组件）始终使用 EKS Managed Node Groups 管理，以保证集群基础设施的稳定性；**应用工作负载节点**可选择 Managed Node Groups 或 Karpenter，Karpenter 适合弹性大、混合实例池、频繁扩缩容的场景；**GPU 节点组**由于需要在 Launch Template 中精确控制 EFA 多网卡配置与多种定价模式，始终使用 Managed Node Groups 管理（详见本系列第二篇）。

---

## 三、私有 API Endpoint：纵深防御的网络架构

EKS 集群的 API Server 访问控制有两种主流方案：

**公有 API Endpoint + IP 白名单**：保留公有 Endpoint，通过配置 `publicAccessCidrs` 限制可访问的源 IP 范围。这种方案配置简单，适合大多数场景，运维人员可以从办公网络直接访问集群。

**私有 API Endpoint**：完全禁用公有 Endpoint，API Server 仅在 VPC 内部可达。这种方案提供了更强的网络隔离，API Server 的 DNS 解析只返回 VPC 内部 IP，从根本上消除了公网暴露面。

对于安全要求更高的企业客户，推荐采用私有 API Endpoint 方案。虽然这会增加一定的运维复杂度（需要通过堡垒机或 VPN 访问集群），但它提供了纵深防御的安全架构，是零信任网络的重要组成部分。

采用私有 API Endpoint 需要配合以下组件：

**VPC Endpoints**：由于集群位于私有网络，节点和 Pod 无法通过 NAT Gateway 访问 AWS 服务。本方案在 `VPC_ENDPOINTS_MODE=full`（私有集群默认）下共创建 **14 个 VPC Endpoints**：13 个 Interface Endpoint（EKS、EKS-Auth、STS、ECR.api、ECR.dkr、EC2、EFS、CloudWatch Logs、Autoscaling、ELB、SSM、SSMMessages、EC2Messages）+ 1 个 S3 Gateway Endpoint。其中 EBS CSI 复用 `ec2` endpoint，FSx 的连通性通过子网与安全组打通（无独立 PrivateLink Endpoint）。公有集群可切换为 `minimal` 模式，仅创建 4 个必需 Interface Endpoint（EKS、EKS-Auth、STS、EC2）+ S3 Gateway，其他流量走 NAT Gateway。这不仅解决了连通性问题，还能降低数据传输成本。

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

## 四、VPC CNI 网络优化：精细化 IP 预热

Amazon VPC CNI 是 EKS 的默认网络插件，为每个 Pod 分配 VPC 内的真实 IP 地址，使 Pod 能够直接与 VPC 内的其他资源通信。本方案对 VPC CNI 做了一项关键调优：

**IP 预热策略**：默认情况下 VPC CNI 会按整个 ENI 预热 IP，对小型节点会造成 IP 资源浪费。本方案关闭 `WARM_ENI_TARGET`、改用 `WARM_IP_TARGET` + `MINIMUM_IP_TARGET` 精细控制预热 IP 数量，既避免 ENI 资源浪费，又保留足够的 Pod 调度缓冲。

此外，VPC CNI 自身原生支持 Kubernetes NetworkPolicy，本方案直接沿用，无需额外安装 Calico 等第三方组件，简化了集群的网络策略管理。

```
VPC CNI 默认配置（scripts/4_install_eks_cluster.sh）
├── AWS_VPC_K8S_CNI_EXTERNALSNAT=false    # 由 NAT Gateway 做 SNAT
├── WARM_ENI_TARGET=0                     # 不预热 ENI
├── WARM_IP_TARGET=5                      # 预热 5 个 IP
└── MINIMUM_IP_TARGET=3                   # 最少预留 3 个 IP
```

如果工作负载需要更高的 Pod 密度或 Pod 级别安全组，可在 addon 的 `configurationValues` 中追加以下参数：

```
# 可选：前缀委派（每个 ENI 槽位分配 /28 = 16 个 IP，显著提升 Pod 密度）
ENABLE_PREFIX_DELEGATION=true
WARM_PREFIX_TARGET=1

# 可选：Pod 安全组（为特定 Pod 分配独立的 SG，用于直连 RDS/ElastiCache 等）
ENABLE_POD_ENI=true
POD_SECURITY_GROUP_ENFORCING_MODE=standard
```

需要注意的是，前缀委派对支持的实例类型和子网可用 IP 数量有一定要求；Pod ENI 会消耗实例的 branch ENI 额度。建议根据实际工作负载评估后再开启。

---

## 五、Pod Identity：简化 IAM 权限管理

传统的 IRSA（IAM Roles for Service Accounts）方案虽然解决了 Pod 级别的 IAM 权限问题，但存在明显的管理负担：每个集群需要配置独立的 OIDC Provider，IAM 信任策略中包含集群特定的 OIDC URL，跨账户配置繁琐，且 OIDC Provider 可能成为单点故障。

**EKS Pod Identity** 是 EKS 当前推荐的 Pod 级 IAM 权限管理方式，它从根本上简化了这一流程：

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
# 第三个参数是 IAM Role 名称，函数内部会自动拼接为完整 ARN
create_pod_identity_association "my-namespace" "my-service-account" "MyServiceRole"
```

本方案的部署脚本为所有组件（Cluster Autoscaler、AWS Load Balancer Controller、CSI Drivers 等）都采用了 Pod Identity，彻底告别 OIDC Provider 的管理负担。

---

## 六、容器运行时存储隔离：提升节点稳定性

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

Launch Template 定义了双 EBS 卷配置——50GB 的 gp3 根卷用于操作系统，100GB 的 gp3 数据卷（3000 IOPS、125 MB/s 吞吐）用于容器运行时。两个卷均启用了 EBS 静态加密（默认使用 `alias/aws/ebs` 管理的 KMS 密钥，如需使用自带 CMK 可在 Launch Template 中追加 `KmsKeyId`）。同时，Launch Template 的 `MetadataOptions` 设置了 `HttpTokens=required`，强制所有节点使用 IMDSv2，从根本上消除传统 IMDSv1 的 SSRF 攻击面。

cloud-boothook 脚本会在 EKS bootstrap 之前执行，完成以下操作：创建 LVM 物理卷和卷组、创建逻辑卷、格式化为 XFS 文件系统、挂载到 `/var/lib/containerd`、使用 rsync 迁移 AMI 预缓存的 pause 镜像、写入 fstab 确保重启后自动挂载。

这种设计带来了显著的收益：容器 I/O 不再影响系统盘，节点稳定性大幅提升；可以独立调整数据卷的大小和 IOPS；XFS 原生支持 project quota，为未来的 Pod 磁盘配额功能预留了能力；即使数据卷满了，系统也能正常启动，便于故障恢复。

---

## 七、全场景存储支持：四种 CSI Driver

现代云原生应用对存储有多样化的需求。本方案通过四种 CSI Driver 实现全场景覆盖：

**Amazon EBS CSI Driver** 提供高性能块存储，适用于数据库和有状态应用。预配置了 gp3（通用场景，3000 IOPS 基线）和 io2（高性能场景，最高 64000 IOPS）两种 StorageClass。

**Amazon EFS CSI Driver** 提供完全托管的弹性文件系统，支持 RWX（ReadWriteMany）访问模式，多个 Pod 可以同时读写同一个文件系统，非常适合需要共享数据的微服务架构。

**Amazon FSx for Lustre CSI Driver** 提供高吞吐、低延迟的并行文件系统，是 GPU 训练工作负载的理想选择，单文件系统可提供数百 GB/s 的聚合吞吐量，并能与 S3 深度集成实现 lazy-load 数据加载。

> **重要兼容性提示**：本方案系统节点在 user-data 中通过 `dnf install lustre-client` 安装客户端，AL2023 仓库提供的版本为 2.15.x。创建 FSx 时请使用 `DeploymentType=PERSISTENT_2`（Lustre 2.15）。若使用 `SCRATCH_2` 或 `PERSISTENT_1`（Lustre 2.10），挂载会因版本不兼容而失败。

**Mountpoint for Amazon S3 CSI Driver** 允许 Pod 直接挂载 S3 存储桶；配合 **S3 Express One Zone** 可提供个位数毫秒级延迟与极高的请求吞吐，是 GPU 推理场景下模型加载的理想选择。需要注意的是 Mountpoint for S3 并非完整 POSIX 文件系统，写入语义有限（不支持随机写、不支持重命名等），生产使用前请参考官方限制说明。

FSx for Lustre 与 S3 Express One Zone 在 GPU 工作负载链路上的选型策略、性能优化与已知限制，将在**本系列第二篇**中展开。

| CSI Driver | 存储类型 | 访问模式 | 典型场景 |
|------------|----------|----------|----------|
| EBS CSI | 块存储 | RWO | 数据库、有状态应用 |
| EFS CSI | 共享文件系统 | RWX | 多 Pod 共享数据 |
| FSx Lustre CSI | 高性能并行文件系统 | RWX | HPC、机器学习训练 |
| S3 CSI (Mountpoint) | 对象存储 | RWX（非 POSIX） | 数据湖、模型/大文件只读挂载 |

---

## 八、自动化部署脚本：幂等、非交互、CI/CD 友好

将上述所有解决方案整合为一套**幂等、非交互、CI/CD 友好**的部署脚本。

### 设计原则

**幂等性**：所有脚本都可以安全地重复执行。如果资源已存在，脚本会自动跳过并输出相应日志，不会产生重复资源或错误。

**非交互**：通过环境变量控制所有配置，无需人工确认。这使得脚本可以直接集成到 CI/CD 流水线中。

**模块化**：核心脚本按顺序执行 1 → 3 → 4 → 6 → 7（其中 `2_validate_network_environment.sh` 和 `5_check_environment.sh` 为可选验证步骤）；可选脚本（`option_*` 前缀）可以根据需求独立运行。

**可追溯**：详细的日志输出，便于故障排查和合规审计。

### 脚本结构

```
scripts/
├── 0_setup_env.sh                      # 环境变量加载（被其他脚本 source）
├── 1_enable_vpc_dns.sh                 # VPC DNS 配置
├── 2_validate_network_environment.sh   # 网络验证（可选）
├── 3_create_vpc_endpoints.sh           # VPC Endpoints
├── 4_install_eks_cluster.sh            # EKS 控制平面
├── 5_check_environment.sh              # 本地环境检查（可选）
├── 6_create_system_nodegroup.sh        # 系统节点组 (LVM)
├── 7_install_eks_addon.sh              # 核心 Addons
├── option_create_bastion.sh            # 堡垒机（可选）
├── option_install_csi_drivers.sh       # CSI Drivers（可选）
├── option_install_karpenter.sh         # Karpenter（可选）
├── option_install_gpu_nodegroups.sh    # GPU 节点组（可选）
├── option_show_nodegroup_topology.sh   # 打印节点组的 AWS 原生拓扑清单（可选）
└── *_lib.sh / pod_identity_helpers.sh  # 共享函数库（磁盘检测、架构识别、拓扑读取、Pod Identity）
```

### 部署流程

整个部署过程分为四个阶段，总耗时约 25-35 分钟：

**网络准备阶段**（约 5 分钟）：启用 VPC DNS 支持，创建 14 个 VPC Endpoints（13 个 Interface + 1 个 S3 Gateway），为私有集群建立与 AWS 服务的连通性。

**控制平面阶段**（约 8-10 分钟）：创建 EKS 集群，配置私有 API Endpoint，这是整个部署中耗时最长的步骤，因为需要等待 AWS 完成控制平面的配置。

**系统节点阶段**（约 8-12 分钟）：创建系统节点组，包含 3 个节点，每个节点都配置了 LVM 存储架构。系统节点用于运行集群基础设施组件。

**核心组件阶段**（约 5-8 分钟）：部署 CoreDNS、Metrics Server、Cluster Autoscaler、AWS Load Balancer Controller 等核心组件（EBS/EFS/FSx/S3 等 CSI Driver 通过独立的 `option_install_csi_drivers.sh` 按需安装）。

### 快速开始

由于集群采用私有 API Endpoint，所有 `kubectl` 与脚本执行均需在 VPC 内部完成。典型流程如下：

```bash
# 0. 在本地（或跳板环境）准备环境变量与堡垒机
cp .env.example .env && vim .env
./scripts/option_create_bastion.sh

# 1. 通过 AWS Systems Manager 登录堡垒机（无需 SSH/公网）
aws ssm start-session --target <bastion-instance-id>

# —— 以下步骤均在堡垒机上执行 ——

# 2. 核心部署（脚本编号 1–7，按顺序）
./scripts/1_enable_vpc_dns.sh
./scripts/3_create_vpc_endpoints.sh
./scripts/4_install_eks_cluster.sh
./scripts/6_create_system_nodegroup.sh
./scripts/7_install_eks_addon.sh

# 3. 按需安装可选组件
INSTALL_DRIVERS=efs ./scripts/option_install_csi_drivers.sh   # EFS 共享存储
./scripts/option_install_karpenter.sh                          # Karpenter 自动扩缩容
./scripts/option_install_gpu_nodegroups.sh                     # GPU 节点组
```

对于 CI/CD 场景，可以通过环境变量一次性拉起完整集群，无需任何人工确认：

```bash
# 在堡垒机（或具备 VPC 访问权限的 CI runner）上运行
export CLUSTER_NAME=prod-eks
export INSTALL_DRIVERS=efs,s3
export S3_BUCKET_ARNS='arn:aws:s3:::my-bucket'

./scripts/1_enable_vpc_dns.sh
./scripts/3_create_vpc_endpoints.sh
./scripts/4_install_eks_cluster.sh
./scripts/6_create_system_nodegroup.sh
./scripts/7_install_eks_addon.sh
./scripts/option_install_csi_drivers.sh
```

---

## 九、可选组件：GPU 节点组与 Karpenter

本方案的核心脚本(1–7)完成后即得到一套通用的生产级 EKS 集群。在此之上，可按需叠加两类上层能力：

**Karpenter 自动扩缩容**：相较传统 Cluster Autoscaler，Karpenter 直接与 EC2 Fleet API 交互，分钟级完成节点扩容，并原生支持 Spot 中断处理与混合实例池。适用于工作负载弹性大、希望精细控制成本的场景。通过 `./scripts/option_install_karpenter.sh` 一键部署。

**GPU 节点组**：通过 `./scripts/option_install_gpu_nodegroups.sh` 部署，支持 P5 / P5en / P6 / G7e 四个系列，提供 On-Demand / Spot / ODCR / Capacity Block 四种定价模式（由 `DEPLOY_GPU_OD / DEPLOY_GPU_SPOT / DEPLOY_GPU_ODCR / DEPLOY_GPU_CB` 独立开关控制）。脚本根据实例类型自动配置 EFA 多网卡（p5.48xlarge / p5e.48xlarge 上最多 32 张，p5en 16 张，p6-b200 8 张，p6-b300 17 张，g7e.48xlarge 4 张），并自动部署 NVIDIA Device Plugin 与 AWS EFA Kubernetes Device Plugin。

> GPU 工作负载涉及**计算（EFA 多网卡拓扑、驱动与 Device Plugin）**、**网络（基于 AWS 原生 `topology.k8s.aws/network-node-layer-N` 的邻近性调度）**、**存储（FSx for Lustre 提供高聚合吞吐；S3 Express One Zone 作为低延迟、高 TPS 的对象存储选项按访问模式选用）** 三层架构，任何一层的配置不当都会显著影响 GPU 工作负载性能。**本系列第二篇**将专门展开这三层的设计决策与最佳实践。

---

## 十、运维与故障排查：部署后的快速验证

部署完成后，可以使用以下命令验证集群状态：

```bash
# 检查节点状态
kubectl get nodes -o wide

# 检查所有 Pod
kubectl get pods -A

# 验证 LVM 配置（通过 chroot 使用节点自带的 lvm2 工具，不依赖调试镜像自带 LVM 包）
kubectl debug node/<node-name> -it --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- \
  chroot /host bash -c "vgs && lvs && df -h /var/lib/containerd"

# 验证存储类
kubectl get storageclass
```

> **说明**：`kubectl debug node/...` 在 kubectl v1.30+ 会提示 `--profile=legacy` 已弃用，可按需追加 `--profile=sysadmin` 消除告警；`vgs/lvs` 由节点 AMI 自带的 `lvm2` 提供，调试容器只是借 `chroot` 进入节点命名空间。

---

## 十一、生产环境部署检查清单：上线前自检

**脚本默认已启用的安全基线**（无需手动操作，核对一下即可）：

* 私有 API Endpoint（API Server 不暴露公网）
* Pod Identity 替代 IRSA（简化 IAM 管理）
* VPC Endpoints 完整配置（13 个 Interface + 1 个 S3 Gateway）
* EBS 卷加密（使用 `alias/aws/ebs` 管理的 KMS 密钥）
* IMDSv2 强制使用（所有节点 Launch Template 设置 `HttpTokens=required`）
* 容器运行时存储已从系统根卷剥离（LVM `/var/lib/containerd`）

**需要按业务自行确认的项**：

* 安全组最小权限原则（默认允许同 VPC 访问，根据业务收敛至具体来源）
* CSI Drivers 按需安装（EBS 默认安装；EFS / FSx / S3 按需启用）
* 日志与审计（CloudWatch Logs、审计日志投递到合规存储）
* Kubernetes RBAC 策略（按团队/namespace 划分权限）

---

## 十二、成本优化建议：在安全与预算之间取得平衡

**使用 Graviton 实例**：Graviton 处理器相较同等 x86 实例最高可提升 40% 性价比，脚本原生支持 Graviton 节点组（系统节点默认即为 `m8g.xlarge`）。

**利用 VPC Endpoints**：VPC Endpoints 不仅提供安全性，还能避免数据通过 NAT Gateway 传输产生的费用。

**合理使用 Spot 实例**：对于无状态或可容错的工作负载，Spot 实例相较按需价格最高可节省 90%。Karpenter 可以自动处理 Spot 中断。

**按需配置节点组大小**：根据实际工作负载配置合适的节点数量和实例类型，避免过度配置。

---

## 十三、总结：一套可复制的企业级 EKS 部署方案

本文从企业客户在 EKS 生产环境中面临的实际挑战出发，介绍了一套经过验证的解决方案：

针对**高安全要求**，本方案提供私有 API Endpoint 配合 14 个 VPC Endpoints（13 个 Interface + 1 个 S3 Gateway），确保所有流量都在 VPC 内部传输，构建纵深防御的网络架构。

针对**网络性能优化**，对 VPC CNI 的 IP 预热策略进行了调优以避免 ENI 资源浪费，同时原生支持 NetworkPolicy；如需进一步提升 Pod 密度或启用 Pod 级别安全组，可按需开启前缀委派与 Pod ENI。

针对**IAM 管理复杂度**，全面采用 Pod Identity 替代 IRSA，消除 OIDC Provider 的管理负担，简化跨账户访问配置。

针对**节点稳定性问题**，通过双 EBS 卷 + LVM 架构将容器运行时存储与系统盘隔离，从根本上解决 I/O 竞争问题。

针对**多样化存储需求**，提供 EBS、EFS、FSx、S3 四种 CSI Driver 的一键部署，覆盖块存储、共享文件系统、高性能存储和对象存储挂载等全部场景。

针对 **GPU 工作负载**，通过 Managed Node Groups 提供 P5、P5en、P6、G7e 等最新 GPU 实例的支持，并集成 EFA 多网卡网络与四种定价模式。更深入的 GPU 架构实践（多网卡拓扑、邻近性调度、按访问模式选型的高性能存储）将在本系列第二篇中展开。

所有这些方案都已沉淀为标准化、自动化的部署脚本，实现约 30 分钟完成生产级集群部署，幂等设计支持重复执行，非交互模式便于 CI/CD 集成。

希望这套方案能够帮助更多企业客户快速、安全地部署生产级 EKS 集群。完整的部署脚本和文档已在 GitHub 开源，欢迎试用和反馈。

---

**下一步行动：**

* 克隆开源仓库 [eks-cluster-deployment](https://github.com/KevinZhao/eks-cluster-deployment)，按照 README 配置 `.env`。
* 在 VPC 内的堡垒机上依次执行编号脚本 1 → 3 → 4 → 6 → 7，约 30 分钟即可获得一套生产级 EKS 集群。
* 按需叠加 `option_install_csi_drivers.sh`、`option_install_karpenter.sh`、`option_install_gpu_nodegroups.sh` 等可选模块。
* 关注本系列第二篇《EKS 上的 GPU 工作负载：节点、网络与高性能存储的架构实践》，深入计算 / 网络 / 存储三层架构。

**相关产品：**

* [Amazon EKS](https://aws.amazon.com/cn/eks/)
* [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
* [Amazon EBS](https://aws.amazon.com/cn/ebs/)
* [Amazon EFS](https://aws.amazon.com/cn/efs/)
* [Amazon FSx for Lustre](https://aws.amazon.com/cn/fsx/lustre/)
* [Mountpoint for Amazon S3](https://aws.amazon.com/cn/s3/features/mountpoint/)
* [Karpenter](https://karpenter.sh/)
* [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

**相关文章：**

* [Amazon EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
* [Amazon EKS Blueprints for CDK](https://aws-quickstart.github.io/cdk-eks-blueprints/)（另有 [Terraform 版本](https://aws-ia.github.io/terraform-aws-eks-blueprints/)）
* [EKS Workshop](https://www.eksworkshop.com/)

**本篇作者**

**Kevin Zhao**
AWS 解决方案架构师，基于多个企业客户的实际部署经验，专注于 Amazon EKS 与容器化工作负载的生产级落地实践。完整的部署脚本已在 [GitHub](https://github.com/KevinZhao/eks-cluster-deployment) 开源。
