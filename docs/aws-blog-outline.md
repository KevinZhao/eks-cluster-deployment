# 企业级 EKS 集群生产环境配置最佳实践

在与众多企业客户的合作中，生产环境 EKS 部署面临五类共性问题：

- **安全合规**：默认 API Endpoint 暴露在公网,IRSA 方案对 OIDC Provider 与跨账户配置依赖较重。
- **节点稳定性**：containerd 与系统 I/O 共用根卷,峰值场景容易触发 `DiskPressure` 甚至 `NotReady`。
- **存储多样**：块存储 / 共享文件系统 / 高吞吐并行存储 / 对象存储数据湖,场景差异大,缺乏统一接入。
- **弹性扩缩容**:节点需要分钟级伸缩并叠加 Spot / ODCR 等定价模式,Cluster Autoscaler 对混合实例池与 Spot 中断支持有限。
- **部署效率**：手动部署生产级集群耗时长,且容易出现配置漂移,难以在多环境间复现。

本文将逐一介绍这些问题的解决方案，并最终将所有方案沉淀为一套声明式的 Terraform 模块。

**目录**

- [一、整体架构概览：私有集群的全景视图](#section1)
- [二、EKS 集群 API Endpoint 私有化：纵深防御的网络架构](#section2)
- [三、VPC CNI 网络优化：IP 预热策略调优](#section3)
- [四、Pod Identity：简化 Pod 级 IAM 权限管理](#section4)
- [五、容器运行时存储隔离：提升节点稳定性](#section5)
- [六、全场景存储支持：四种 CSI Driver](#section6)
- [七、自动化部署：以 Terraform 为中心的声明式实现](#section7)
- [八、部署后验证、检查清单与成本优化](#section8)

---

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
│  │  │  │ EBS CSI │  │ EFS CSI │  │ FSx Lustre  │  │ S3 CSI (Mountpoint)         │  │  │
│  │  │  │ (RWO)   │  │ (RWX)   │  │ CSI (RWX)   │  │ Standard S3 / Express 1Z    │  │  │
│  │  │  └─────────┘  └─────────┘  └─────────────┘  └─────────────────────────────┘  │  │
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

> **节点管理策略**：系统节点组(运行 CoreDNS / CSI / LB Controller 等基础组件)与 GPU 节点组始终使用 EKS Managed Node Groups 管理;应用工作负载节点可选 Managed Node Groups 或 Karpenter,后者适合弹性大、混合实例池的场景。详见 §五、§7.5。

---

## 二、EKS 集群 API Endpoint 私有化：纵深防御的网络架构

EKS 在集群创建时为每个集群分配一个 AWS 托管的 HTTPS 域名,形如 `https://<UUID>.gr7.<region>.eks.amazonaws.com`,这就是 AWS 文档中的 **cluster endpoint**,也是 `kubectl`、Karpenter、Cluster Autoscaler、CSI Controller 等所有 Kubernetes 客户端访问 control plane 的统一入口。Cluster endpoint 是集群最外层的访问面,它的暴露范围直接决定了攻击面的大小。EKS 提供两种暴露模式:

### 2.1 两种 cluster endpoint 暴露模式

**公有 cluster endpoint + IP 白名单**(`cluster_mode = "public"`):cluster endpoint 走公网 DNS 解析,通过 `public_access_cidrs = ["<出口 IP>/32"]` 把允许访问的源 IP 收窄到指定范围。配置简单,从开发机或办公网就能直接 `kubectl`,**适合开发测试环境、PoC、培训演示等无需长期对外暴露的场景**。不建议长期用于生产:白名单维护是手工流程,容易随运维人员变动逐步放宽,且 cluster endpoint 仍位于公网。

**私有 cluster endpoint**（`cluster_mode = "private"`,**生产环境推荐**）：完全禁用公网解析。EKS 在 VPC 内为 control plane 创建一组 ENI,域名 DNS 改为只返回这些 ENI 的私有 IP,公网攻击面归零。代价是运维必须通过 VPC 内的入口(堡垒机 / VPN / Direct Connect)才能访问集群,这通常正是合规与零信任所要求的。

### 2.2 私有 cluster endpoint 的两个配套组件

私有 cluster endpoint 把 API 入口的 ENI 放进了 VPC(control plane 仍由 AWS 托管),但还有两个工程问题需要解决:第一,工作节点如何调用其他 AWS 服务(ECR 拉镜像、CloudWatch 上报日志…);第二,运维人员如何安全地接入 VPC。本方案分别用 VPC Endpoints 与 SSM 堡垒机解决。

**VPC Endpoints — 让节点 / Pod 触达 AWS 服务**

注意:VPC Endpoints 与 cluster endpoint 是**两件不同的事**。前者是节点和 Pod 走 PrivateLink 调用其他 AWS 服务的私网通道,后者是 Kubernetes 客户端访问 control plane 的入口。本方案通过 `vpc_endpoints_mode` 提供两档,选哪一档**取决于 VPC 是否允许节点出公网,而不是 cluster endpoint 是公有还是私有**:

- **`vpc_endpoints_mode = "full"`** —— 创建 **14 个 VPC Endpoints**:13 个 Interface Endpoint(EKS、EKS-Auth、STS、ECR.api、ECR.dkr、EC2、EFS、CloudWatch Logs、Autoscaling、ELB、SSM、SSMMessages、EC2Messages)+ 1 个 S3 Gateway Endpoint。**当 VPC 没有 NAT/IGW、或被 SCP / 合规策略禁止节点出公网时(金融、政务、合规 landing zone)必须选这一档**,所有 AWS API 调用都走 PrivateLink,完全不依赖出网路径。EBS CSI 复用 `ec2` endpoint,FSx 通过子网与安全组打通,均不需要独立的 PrivateLink。
- **`vpc_endpoints_mode = "minimal"`** —— 创建 **5 个 VPC Endpoints**:4 个必需 Interface Endpoint(EKS、EKS-Auth、STS、EC2)+ 1 个 S3 Gateway。**当 VPC 有 NAT/IGW 且无出网合规限制时可选这一档**,这 4 个 endpoint 承载 EKS 节点注册与 Pod Identity Agent 这条强依赖链路(无公网回退),保留为 PrivateLink 既稳定又免去 NAT 流量费;其余 9 类流量走 NAT Gateway。S3 Gateway 本身免费,因此两档都包含。

`cluster_mode` 与 `vpc_endpoints_mode` 是**正交**的:私有 cluster endpoint 集群如果允许节点 NAT 出网,理论上可以用 `minimal`;公有 cluster endpoint 集群如果工作节点处于受限子网,也可能需要 `full`。生产环境最常见的组合是 `private` + `full`,本方案默认即是这一组合。

**运维接入 VPC — 堡垒机或专线**

私有 cluster endpoint 集群无法从公网直接 `kubectl`,运维入口必须落在 VPC 内。常见有两条路径,按企业网络现状选择:

- **SSM 堡垒机(无现有专线时的最简方案)** — 本方案在私有子网部署一台 t4g.small 堡垒机,运维通过 AWS Systems Manager Session Manager 接入:无需开放任何 SSH 端口、无需 IP 白名单、所有会话有完整 CloudTrail 审计;堡垒机角色经 EKS Access Entry 授予 cluster-admin RBAC,登录后即可直接 `kubectl`。一台 t4g.small 月成本约 $12,适合开发 / 中小规模生产。
- **Direct Connect / VPN(已有企业专线时的零跳方案)** — 如果企业已经把 IDC 通过 AWS Direct Connect 或 Site-to-Site VPN 接入 AWS,运维主机可以**直接走专线把 cluster endpoint 的私有 IP 当作内网地址访问**,完全不需要堡垒机。这种模式下还需要两件事:一是把 IDC 网段加入 cluster security group ingress(本方案的 `extra_api_ingress_cidrs` 变量);二是让 IDC 的 DNS 能解析到 cluster endpoint 的 VPC 内私有 IP(典型做法是用 Route 53 Resolver inbound endpoint 把 VPC DNS 暴露给 IDC,或在 IDC 侧配置 conditional forwarder)。

两种方式可以并存:即使有专线也保留一台 SSM 堡垒机作为 break-glass 通道,在专线故障或运维网调整期间避免失联。

---

## 三、VPC CNI 网络优化：IP 预热策略调优

Amazon VPC CNI 是 EKS 的默认网络插件，为每个 Pod 分配 VPC 内的真实 IP 地址，使 Pod 能够直接与 VPC 内的其他资源通信。本方案对 VPC CNI 做了一项关键调优：

**IP 预热策略**：默认情况下 VPC CNI 会按整个 ENI 预热 IP，对小型节点会造成 IP 资源浪费。本方案关闭 `WARM_ENI_TARGET`、改用 `WARM_IP_TARGET` + `MINIMUM_IP_TARGET` 精细控制预热 IP 数量，既避免 ENI 资源浪费，又保留足够的 Pod 调度缓冲。

此外，VPC CNI 自身原生支持 Kubernetes NetworkPolicy，本方案直接沿用，无需额外安装 Calico 等第三方组件，简化了集群的网络策略管理。

```
VPC CNI 默认配置（terraform/modules/eks-cluster/main.tf）
├── AWS_VPC_K8S_CNI_EXTERNALSNAT=false    # 由 NAT Gateway 做 SNAT
├── WARM_ENI_TARGET=0                     # 不预热 ENI
├── WARM_IP_TARGET=5                      # 预热 5 个 IP
└── MINIMUM_IP_TARGET=3                   # 最少预留 3 个 IP
```

对于需要更高 Pod 密度或 Pod 级别安全组等进阶场景,VPC CNI 还提供前缀委派(`ENABLE_PREFIX_DELEGATION`)与 Pod ENI(`ENABLE_POD_ENI`)等额外开关 —— 它们各自有实例类型和额度的限制,本文不展开,详见 [Amazon VPC CNI 文档](https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html)。

---

## 四、Pod Identity：简化 Pod 级 IAM 权限管理

EKS 集群里需要 IAM 权限的不只是工作负载,Cluster Autoscaler、AWS Load Balancer Controller、所有 CSI Driver 都需要调用 AWS API。让 Pod 安全地拿到临时 IAM 凭证,长期以来有两条路径:**IRSA**(2019 年推出)与 **Pod Identity**(2023 年 11 月推出,**当前 AWS 推荐**)。本方案在控制平面、所有 addon 与所有 CSI Driver 上**全面采用 Pod Identity**,从源头消除 OIDC Provider 的运维与安全负担。

### 4.1 为什么不再使用 IRSA

IRSA 的工作原理是让集群充当 OIDC Identity Provider:每个集群有一个独立的 OIDC discovery URL,Pod 内的 ServiceAccount token 是该 IdP 签发的 JWT,IAM 通过校验 JWT 上的 issuer 与 subject 来决定是否允许 AssumeRole。这条链路带来三个长期痛点:

- **每个集群必须在 IAM 中注册一个 OIDC Provider**,而每个 IAM 角色的信任策略要硬编码该集群的 OIDC issuer URL。多集群、跨账户场景下,角色信任策略数量按集群数线性膨胀,且集群重建会换 issuer URL,所有信任策略都要刷一遍。
- **OIDC Provider 是有状态的全局资源**,被 SCP 误删、被 IAM 配额命中、或 Region 故障时,集群里所有依赖 IRSA 的 Pod 一起拿不到凭证,故障域大。
- **私有集群下还要额外解决 OIDC issuer 的 DNS 解析**(`oidc.eks.<region>.amazonaws.com` 在 VPC 内默认无法解析),需要运维手工配置 hosts 或 DNS 转发。

### 4.2 Pod Identity 的机制

Pod Identity 用**一个集群内 DaemonSet** 替代 OIDC:每台节点跑一份 Pod Identity Agent,Pod 调用 AWS SDK 时,Agent 校验请求来源 Pod 的 `(namespace, serviceAccount)`,直接从 EKS 控制平面换取临时凭证返回。角色信任策略 Principal 固定为 `pods.eks.amazonaws.com`,**不再与具体集群绑定** —— 跨账户、跨集群、集群重建都不影响,这是它所有运维优势的根源。

### 4.3 IRSA vs Pod Identity 对比

| 维度 | IRSA | Pod Identity |
|---|---|---|
| 凭证签发方 | 集群充当 OIDC IdP,IAM 校验 JWT | EKS Pod Identity Agent + control plane |
| 全账户额外资源 | 每集群 1 个 IAM OIDC Provider | 无(AWS 托管,零账户级资源) |
| 信任策略 Principal | `Federated: <集群 OIDC ARN>`,绑定具体集群 | `Service: pods.eks.amazonaws.com`,通用 |
| 角色复用 | 跨集群需各自维护一份信任策略 | 同一角色可被多集群、多账户的 Pod 直接复用 |
| 跨账户支持 | 复杂(联合身份 + 显式信任声明) | 原生(目标账户角色 + 源集群关联) |
| 故障域 | OIDC Provider 单点 | 节点级 DaemonSet,挂掉只影响本节点 |
| 私有集群可用性 | 需手工解决 oidc.eks.<region> DNS | 开箱即用,无 DNS 依赖 |

### 4.4 在 Terraform 中接入

每个需要 IAM 权限的组件都遵循同一三步范式:**建角色 → 挂策略 → 关联 ServiceAccount**。

```hcl
# 1. 建角色：信任策略 Principal 固定为 EKS Pod Identity 服务
resource "aws_iam_role" "my_service" {
  name = "MyServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# 2. 挂策略：与普通 IAM 角色完全一致
resource "aws_iam_role_policy_attachment" "my_service_s3" {
  role       = aws_iam_role.my_service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# 3. 关联 ServiceAccount：cluster + namespace + ServiceAccount → 角色
resource "aws_eks_pod_identity_association" "my_service" {
  cluster_name    = var.cluster_name
  namespace       = "my-namespace"
  service_account = "my-service-account"
  role_arn        = aws_iam_role.my_service.arn
}
```

注意第 3 步是 EKS 资源(`aws_eks_pod_identity_association`),不是 IAM 资源 —— 关联关系存在控制平面侧,集群删除后自动失效,不需要清理 OIDC Provider 这种全局资源。

本方案的 Terraform 模块为 Cluster Autoscaler、AWS Load Balancer Controller、Karpenter、EBS / EFS / FSx / S3 四种 CSI Driver、GPU 节点组等所有需要 AWS 权限的组件都接入了 Pod Identity,集群默认 `enable_irsa = false`,彻底告别 OIDC Provider。

---

## 五、容器运行时存储隔离：提升节点稳定性

EKS 优化 AMI 默认只挂一块根卷,OS、kubelet 工作目录、`/var/log/`、containerd 的 `/var/lib/containerd`(镜像层、可写层、元数据)全部挤在同一块 gp3 上 —— 基线只有 3000 IOPS / 125 MB/s。多 Pod 并发拉镜像 + 容器 stdout 洪峰 + kubelet 日志 + 镜像 GC 一起冲击根卷,先表现为节点心跳抖动,然后触发 `DiskPressure` 大规模驱逐 Pod,最坏情况下根卷打满、节点直接 `NotReady`。这类问题日常负载不易触发,但**流量峰值或大规模发版时容易暴露成节点级故障**。

解决思路是**把容器运行时从根卷迁出,让系统 I/O 与容器 I/O 物理隔离**:

```
┌─────────────────────────────────────────────────────┐
│  EC2 Instance (m8g.xlarge)                          │
├─────────────────────────────────────────────────────┤
│  /dev/xvda (50GB gp3)  →  /  (OS / kubelet / 日志)   │
├─────────────────────────────────────────────────────┤
│  /dev/xvdb (100GB gp3) →  LVM vg_data/lv_containerd │
│                          →  /var/lib/containerd (XFS)│
└─────────────────────────────────────────────────────┘
```

Terraform 模块 `eks-system-nodegroup` 在 `aws_launch_template` 里同时声明两块 EBS(50GB 根卷 + 100GB 数据卷,均开启加密,可通过 `kms_key_arn` 改用自带 CMK),并把 LVM/格式化/挂载逻辑写进节点 user-data。两个卷大小由 `system_node_root_volume_size` / `system_node_data_volume_size` 控制;Launch Template 同时强制 IMDSv2,这是顺手的安全基线,与本章主题正交。

启动**次序**很关键:containerd 一旦被 kubelet 拉起就会往 `/var/lib/containerd` 写数据,之后再切换挂载点会丢镜像或挂载失败。所以本方案在 `cloud-boothook` 阶段(EKS bootstrap 之前)完成 LVM 创建、XFS 格式化、迁移 AMI 预置 pause 镜像、挂载、写 fstab 这套动作。其中**迁移预置 pause 镜像这步不能省**:EKS 优化 AMI 已经预拉了 pause 与常用 sandbox 资产,直接挂空卷会让节点首次启动多花数十秒拉镜像。文件系统选 **XFS** 是因为它在大量小文件高并发写入下延迟更平稳,且 64-bit inode 永不耗尽。

带来的收益:**容器 I/O 不再挤占系统盘带宽**(核心);容器层容量 / IOPS 可以独立调大或升级到 io2,根卷不动;**故障域解耦** —— 数据卷写满只让 containerd 受影响,kubelet / SSH / journald 仍可用,运维能进节点排查。代价是每节点多一块 EBS,系统节点 3 台 × 100GB gp3 月增加约 $24,这点成本对换稳定性是合算的。

---

## 六、全场景存储支持：四种 CSI Driver

CSI Driver 的生产部署不止 helm install:还要配 IAM 角色、关联 Pod Identity、预置 StorageClass、对齐节点 user-data 上的客户端依赖、规避版本兼容陷阱。本方案 Terraform 模块把这套链路收敛为 **EBS 默认安装 + EFS/FSx/S3 三个独立 toggle**,工作负载侧拿 PVC 即用。

**Amazon EBS CSI Driver(块存储,RWO)** —— **始终安装,无需配置**。模块预置两个 StorageClass:`gp3`(默认,覆盖 90% 通用场景)与 `io2`(高 IOPS、低延迟,用于高 QPS 数据库或延迟敏感工作负载),并把 `gp2` 的默认 SC 标记移除。其他类型(io1 / st1 / sc1)使用频率低,需要时业务侧自定义 sc 即可。EBS 是数据库、消息队列、有状态应用最常用的卷类型,几乎所有集群都会用到,所以不做 toggle。

**Amazon EFS CSI Driver(共享文件系统,RWX)** —— `install_efs_csi = true` 启用。提供完全托管的 NFS,支持多 Pod 跨节点同时挂载同一目录读写。典型场景是**需要持久共享目录**的工作负载:CMS / 论坛上传目录、Jenkins workspace、机器学习数据集共享、需要跨 Pod 同步状态的应用等。开关打开后,模块创建 IAM 角色 + Pod Identity 关联 + 部署 CSI Controller,业务方按需自行创建 EFS file system 与 PVC。

**Amazon FSx for Lustre CSI Driver(高性能并行文件系统,RWX)** —— `install_fsx_csi = true` 启用。单文件系统可达数百 GB/s 聚合吞吐,适合 HPC 与机器学习训练;能通过 **DRA(Data Repository Association)与 S3 联动 —— 冷数据存 S3、热数据 lazy-load 到 Lustre**,显著降低成本。**版本兼容性提示**:节点 user-data 用 `dnf install lustre-client` 装 AL2023 仓库的 2.15.x 客户端,因此创建 FSx 时**必须使用 `DeploymentType = PERSISTENT_2`**(Lustre 2.15);若误用 `SCRATCH_2` 或 `PERSISTENT_1`(Lustre 2.10),挂载会因服务端 / 客户端版本不兼容直接失败。

**Mountpoint for Amazon S3 CSI Driver(对象存储,只读 / 顺序写)** —— `install_s3_csi = true` + `s3_csi_bucket_arns = [...]` 启用。让 Pod 直接挂载 S3 桶,适合**模型权重 / 数据集 / 大文件**这类只读或顺序追加的访问模式;**不支持随机写、不支持 rename、不支持 hard link**,数据库类工作负载和需要原地更新的场景不能用。模块根据 `s3_csi_bucket_arns` 自动生成最小权限 IAM policy 并通过 Pod Identity 注入 CSI Controller,同时支持 Standard S3 与 S3 Express One Zone(低延迟、高 TPS directory bucket)的 ARN 格式。Standard 与 S3 Express 的访问模式选型(高 TPS 小对象 vs 大文件顺序读)在 **本系列第二篇** 展开。

> **关闭 toggle 等于完全不部署**:`install_efs_csi = false` 时,EFS CSI 的 helm release、IAM 角色、Pod Identity 关联**都不会被创建**,不存在"装好但没配"的中间态。业务上线需要某个 CSI 时再翻 toggle、`terraform apply`,模块会增量创建对应资源。

---

## 七、自动化部署：以 Terraform 为中心的声明式实现

Terraform 是承载前述所有设计的入口。一份 `terraform.tfvars` + 一次 `apply`,声明式拉起整套生产级集群。运维类工具(`option_inspect_eks.sh` 集群健康检查、`option_verify_gpu_efa.sh` NCCL 跨节点带宽测试、`option_show_nodegroup_topology.sh` 拓扑标签读取、`option_create_bastion.sh` 堡垒机生命周期)因为是**面向运行中集群的命令式动作**而非基础设施声明,继续保留为 Bash 脚本。

### 7.1 模块结构

```
terraform/
├── main.tf / variables.tf / outputs.tf / providers.tf / versions.tf
├── terraform.tfvars.example                # 复制为 terraform.tfvars 后修改
├── bootstrap/                              # S3 + DynamoDB 远端 state（每账号一次）
├── bootstrap-vpc/                          # 独立 3-AZ VPC（用于演练或全新环境）
├── bootstrap-bastion/                      # SSM-only 堡垒机（私有集群专用）
├── modules/
│   ├── vpc-endpoints/                      # 14 个 VPC Endpoints
│   ├── eks-cluster/                        # 控制平面 + 基础 Addons + Access Entries
│   ├── eks-system-nodegroup/               # LVM 双卷系统节点组
│   ├── eks-addons/                         # CoreDNS / Metrics / CA / ALB Controller
│   ├── eks-csi-drivers/                    # EBS / EFS / FSx / S3 四种 CSI（按 toggle 启用）
│   ├── eks-karpenter/                      # Karpenter + EC2NodeClass / NodePool
│   ├── eks-gpu-nodegroup/                  # GPU 节点组（多张 EFA NIC 拓扑见第二篇）
│   └── eks-gpu-stack/                      # K8s 端 GPU 栈（standard / operator 两种模式）
└── scripts/safe-destroy.sh                 # helm uninstall → terraform destroy 的兜底脚本
```

每个模块对外只暴露**业务级开关**：`install_efs_csi`、`install_fsx_csi`、`install_s3_csi`、`install_karpenter`、`install_gpu_nodegroups`、`install_gpu_stack` / `gpu_stack_mode` 等。打开开关即声明该能力存在；关闭后 `terraform apply` 会自动回收对应资源。

### 7.2 部署流程

整个部署过程对 Terraform 来说是一次 `apply`，内部按模块依赖图自动顺序化执行，总耗时约 **25–35 分钟**：

| 阶段 | 内容 | 耗时 |
|---|---|---|
| 网络 | VPC DNS 校验 + VPC Endpoints（`full` 14 个 / `minimal` 5 个） | ~2 分钟 |
| 控制平面 | 私有 cluster endpoint + 基础 Addons（vpc-cni / kube-proxy / pod-identity-agent） | 8-10 分钟 |
| 系统节点组 | 3 节点 LVM 双卷管理节点组 | 8-12 分钟 |
| 核心组件 | CoreDNS / Metrics Server / Cluster Autoscaler / ALB Controller | 5-8 分钟 |
| 可选 | EBS（默认）/ EFS / FSx / S3 CSI、Karpenter、GPU 节点组 | 按需 |

### 7.3 快速开始

私有集群下 cluster endpoint 仅 VPC 内可达，因此 `terraform apply` 必须在 VPC 内部主机（堡垒机或 DX 接入的运维主机）上执行。完整流程是三个独立 stack 串行：

```bash
# —— 在本地或运维主机上执行 ——

# 0. 一次性：bootstrap state 后端（S3 + DynamoDB）
terraform -chdir=terraform/bootstrap apply \
  -var="bucket_name=my-eks-tfstate" -var="region=us-west-2"

# 1. 独立 VPC（如果使用现成 VPC 可跳过此步）
terraform -chdir=terraform/bootstrap-vpc apply

# 2. 创建 SSM-only 堡垒机
terraform -chdir=terraform/bootstrap-bastion apply \
  -var="vpc_id=<step1 输出>" \
  -var="subnet_id=<某个 private subnet>"

# 3. 通过 AWS Systems Manager 登录堡垒机（无需 SSH 端口、无公网暴露）
aws ssm start-session --target <bastion-instance-id>

# —— 以下步骤在堡垒机上执行 ——

# 4. 配置变量
git clone <repo> && cd terraform
cp terraform.tfvars.example terraform.tfvars && vim terraform.tfvars

# 5. Init + Apply（含集群 + 系统节点组 + 核心 Addons + 可选模块）
terraform init \
  -backend-config="bucket=my-eks-tfstate" \
  -backend-config="key=eks-cluster-deployment/prod/terraform.tfstate" \
  -backend-config="region=us-west-2" \
  -backend-config="dynamodb_table=my-eks-tfstate-lock"

terraform apply

# 6. Apply 完成后跑健康检查
./scripts/option_inspect_eks.sh
```

`terraform.tfvars` 的核心字段示例：

```hcl
cluster_name       = "prod-eks"
aws_region         = "us-west-2"
vpc_id             = "vpc-xxxxxxxx"
private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
public_subnet_ids  = ["subnet-ppp", "subnet-qqq", "subnet-rrr"]

cluster_mode       = "private"
vpc_endpoints_mode = "full"

# 跨 VPC / 同 VPC 的 API 入口放行
extra_api_ingress_security_group_ids = ["sg-bastion"]   # 同 VPC 的堡垒机
# extra_api_ingress_cidrs            = ["10.100.0.0/16"]  # DX / VPN

# CSI / Karpenter / GPU 按需启用
install_efs_csi    = true
install_fsx_csi    = false
install_s3_csi     = false
install_karpenter  = true
```

### 7.4 CI/CD 集成

由于 Terraform 已经是声明式与非交互的，CI/CD 接入即"在具备 VPC 访问能力的 runner 上跑一遍 `apply`"，不再需要环境变量魔法：

```bash
# 适用于堡垒机、DX 接入的 CI runner，或 VPC 内的 self-hosted GitHub Action
terraform -chdir=terraform init -backend-config=... -input=false
terraform -chdir=terraform plan  -out=tfplan -input=false
terraform -chdir=terraform apply -input=false -auto-approve tfplan
./scripts/option_inspect_eks.sh
```

公有集群（仅适用于开发/演示）可以省掉堡垒机：在 `terraform.tfvars` 设置 `cluster_mode = "public"` + `public_access_cidrs = ["<你的出口 IP>/32"]`，直接从开发机 apply。

### 7.5 可选组件:Karpenter 与 GPU 节点组

完成核心 `apply` 后即得到一套通用的生产级集群。在此之上,可按需叠加两类上层能力,全部以同一份 `terraform.tfvars` 中的开关声明:

**Karpenter 自动扩缩容**:相较传统 Cluster Autoscaler,Karpenter 直接与 EC2 Fleet API 交互,分钟级完成节点扩容,并原生支持 Spot 中断处理与混合实例池。在 `terraform.tfvars` 中设置 `install_karpenter = true` 即启用,`apply` 后 Karpenter Controller、关联的 Pod Identity 角色、`EC2NodeClass`、Graviton/x86 两套 `NodePool` 模板(位于 `terraform/assets/karpenter/`)会一并部署。

**GPU 节点组**:通过 `install_gpu_nodegroups = true` + `gpu_nodegroups = [...]` 列表声明启用,支持 P5 / P5en / P6 / G7e 四个系列与 On-Demand / Spot / ODCR / Capacity Block 四种定价模式;K8s 端 GPU 栈再通过 `install_gpu_stack = true` + `gpu_stack_mode = "standard" | "operator"` 配套部署。GPU 工作负载涉及**计算(EFA 多网卡拓扑、驱动与 Device Plugin)**、**网络(基于 AWS 原生 `topology.k8s.aws/network-node-layer-N` 的邻近性调度)**、**存储(FSx for Lustre / S3 Express One Zone 按访问模式选型)** 三层架构,任何一层配置不当都会显著影响性能 —— 这三层的设计决策与最佳实践,以及 `gpu_nodegroups` 列表的完整字段、EFA 多网卡的精确摆位、两种 GPU 栈模式的取舍,**详见本系列第二篇《EKS 上的 GPU 工作负载》**。

---

## 八、部署后验证、检查清单与成本优化

`terraform apply` 成功只意味着资源创建完毕,集群是否真的处于"生产就绪"状态还需要验证。本章从一键健康检查、按需手动核对、上线前自检、成本优化四个维度依次展开。

### 8.1 一键健康检查

仓库提供 `scripts/option_inspect_eks.sh` 作为部署后的统一入口,跑一次 **9 项检查**(控制平面 / addons / 系统 NG / 节点级 kubelet & containerd & LVM / helm releases / VPC Endpoints / SG ingress / Pod Identity 关联 / in-cluster DNS + spot vCPU 配额),全 PASS 即可放心交付,任一 FAIL 直接 exit 1,适合接入 CI/CD 的部署后门禁。

### 8.2 按需手动核对

需要更细粒度的排查时,常用命令:

```bash
# 节点 / Pod 状态
kubectl get nodes -o wide
kubectl get pods -A

# 验证 LVM 配置（通过 chroot 使用节点自带的 lvm2 工具）
kubectl debug node/<node-name> -it --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- \
  chroot /host bash -c "vgs && lvs && df -h /var/lib/containerd"

# 存储类
kubectl get storageclass
```

> **说明**：`kubectl debug node/...` 在 kubectl v1.30+ 会提示 `--profile=legacy` 已弃用，可按需追加 `--profile=sysadmin` 消除告警；`vgs/lvs` 由节点 AMI 自带的 `lvm2` 提供，调试容器只是借 `chroot` 进入节点命名空间。

### 8.3 上线前检查清单

**Terraform 模块默认已启用的安全基线**(开箱即有,核对一下即可):

* 私有 cluster endpoint(API 不暴露公网)
* Pod Identity 替代 IRSA(简化 IAM 管理)
* VPC Endpoints 完整配置(私有集群 / `vpc_endpoints_mode = "full"` 下创建 13 个 Interface + 1 个 S3 Gateway;公有集群 / `"minimal"` 模式下仅创建 4 个必需 Interface + 1 个 S3 Gateway)
* EBS 卷加密(使用 `alias/aws/ebs` 管理的 KMS 密钥)
* IMDSv2 强制使用(所有节点 Launch Template 设置 `HttpTokens=required`)
* 容器运行时存储已从系统根卷剥离(LVM `/var/lib/containerd`)

**需要按业务自行确认的项**:

* 安全组最小权限原则(默认允许同 VPC 访问,根据业务收敛至具体来源)
* CSI Drivers 按需安装(EBS 默认安装;EFS / FSx / S3 按需启用)
* 日志与审计(CloudWatch Logs、审计日志投递到合规存储)
* Kubernetes RBAC 策略(按团队/namespace 划分权限)

### 8.4 成本优化建议

安全基线满足之后,可以从下面四个方向进一步压低成本:

* **使用 Graviton 实例** —— Graviton 处理器相较同等 x86 实例性价比可提升最多 40%;Terraform 模块原生支持 Graviton 节点组(`system_node_instance_type` 默认 `m8g.xlarge`,架构由模块按 EC2 API 自动检测)。
* **利用 VPC Endpoints** —— `vpc_endpoints_mode = "full"` 下流量走 PrivateLink,既提升安全性又避免 NAT Gateway 数据传输费用,长期运行往往把 endpoint 月费摊回来。
* **合理使用 Spot** —— 无状态或可容错的工作负载用 Spot 最高可省 90%,Karpenter 自动处理中断信号与节点替换。
* **按需配置节点组大小** —— 系统节点组按实际 addon footprint 评估(默认 3 节点的 m8g.xlarge 已能轻松撑住 CoreDNS / ALB Controller / CSI / Metrics 全套),业务节点交给 Karpenter 弹性伸缩。

---

## 总结

本文围绕**安全合规、节点稳定性、全场景存储、弹性扩缩容、部署效率**五类企业客户的实际挑战展开,把私有 cluster endpoint、Pod Identity、容器运行时存储隔离、四种 CSI Driver、Karpenter / GPU 节点组等设计决策沉淀为一套约 3000 行的 Terraform 模块。约 30 分钟一次 `apply` 即可完成生产级集群部署,`option_inspect_eks.sh` 9 项健康检查作为交付门禁。

立即开始:

```bash
git clone https://github.com/KevinZhao/eks-cluster-deployment
cd eks-cluster-deployment/terraform
cp terraform.tfvars.example terraform.tfvars && vim terraform.tfvars
terraform init -backend-config=...
terraform apply
```

GPU 工作负载相关的 EFA 多网卡、拓扑感知调度、高性能存储选型等深度内容,详见**本系列第二篇《EKS 上的 GPU 工作负载:节点、网络与高性能存储的架构实践》**。

---

**下一步行动：**

* 克隆开源仓库 [eks-cluster-deployment](https://github.com/KevinZhao/eks-cluster-deployment)，复制 `terraform/terraform.tfvars.example` 为 `terraform.tfvars` 并填入 `cluster_name` / `vpc_id` / `private_subnet_ids` 等核心字段。
* 一次性 bootstrap 远端 state 后端（`terraform/bootstrap`）；如需独立 VPC 与堡垒机，分别 apply `bootstrap-vpc/` 与 `bootstrap-bastion/`。
* 在 VPC 内主机上 `terraform -chdir=terraform apply`，约 30 分钟即可获得一套生产级 EKS 集群；apply 完成后跑 `./scripts/option_inspect_eks.sh` 做 9 项健康检查。
* 按需在 `terraform.tfvars` 中开启 `install_efs_csi` / `install_fsx_csi` / `install_s3_csi` / `install_karpenter` / `install_gpu_nodegroups` 等开关，重新 apply 即可叠加能力。
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
AWS 解决方案架构师，基于多个企业客户的实际部署经验，专注于 Amazon EKS 与容器化工作负载的生产级落地实践。完整的 Terraform 模块与运维脚本已在 [GitHub](https://github.com/KevinZhao/eks-cluster-deployment) 开源。
