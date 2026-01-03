# EKS 集群部署标准操作流程 (SOP)

## 文档信息
- **版本**: v1.0
- **最后更新**: 2025-12-29
- **适用范围**: EKS 1.34 集群自动化部署
- **执行环境**: AWS VPC 内的堡垒机 (Bastion Host)

---

## 概述

本 SOP 描述了使用自动化脚本部署生产级 EKS 集群的完整流程，包括集群控制平面、系统节点组（带 LVM 配置）和集群核心组件的安装。

### 部署架构

```
EKS Cluster (Kubernetes 1.34)
├── 控制平面 (AWS 托管)
│   └── 私有 API Endpoint
├── 系统节点组 (eks-utils)
│   ├── 实例类型: m7i.2xlarge (Intel x86_64)
│   ├── 节点数: 3 (可扩展至 6)
│   ├── 存储: 50GB 根卷 + 100GB LVM 数据卷
│   └── 运行组件: CoreDNS, Cluster Autoscaler, Load Balancer Controller, EBS CSI Driver
└── 网络配置
    ├── VPC CNI (v1.18.5)
    ├── 私有子网 (3个 AZ)
    └── VPC Endpoints (EKS, ECR, S3, SSM 等)
```

### 关键特性

- ✅ 私有 API 访问（高安全性）
- ✅ 多可用区高可用部署
- ✅ LVM 配置实现存储隔离和性能优化
- ✅ Pod Identity 认证（替代 IRSA）
- ✅ 自动扩缩容（Cluster Autoscaler）
- ✅ 持久化存储支持（EBS CSI Driver）

---

## 前置条件

### 1. VPC 网络要求

本部署方案支持两种场景：

#### 场景 A：使用已有 VPC（推荐）

| 资源类型 | 要求 | 说明 |
|---------|------|------|
| VPC | 1 个 | 已创建并配置好网络 |
| 私有子网 | 3 个 | 分布在 3 个不同的 AZ |
| 公有子网 | 3 个 | 分布在 3 个不同的 AZ |
| NAT Gateway | 至少 1 个 | 建议 3 个（每个 AZ 一个） |
| Internet Gateway | 1 个 | 已配置并关联到 VPC |
| VPC DNS | - | 脚本会自动启用 |
| VPC Endpoints | - | 脚本会自动创建 13 个 |

**适用于**：已有 VPC 基础设施的生产环境

#### 场景 B：新建 VPC

如果还没有 VPC，需要先创建：

**选项 1：使用 AWS 控制台** - 创建包含公有/私有子网的 VPC（推荐使用 VPC 向导）

**选项 2：使用 CloudFormation/Terraform** - 参考 AWS VPC 最佳实践模板

**选项 3：使用 eksctl** - 可以在集群创建时自动创建 VPC
```bash
# 注意：本 SOP 脚本假设 VPC 已存在，如需 eksctl 自动创建 VPC，
# 需要修改 manifests/cluster/eksctl_cluster_template.yaml
```

**网络规划建议**：
- VPC CIDR：/16 网段（如 10.0.0.0/16）
- 私有子网：每个 AZ 一个 /19 或 /20 网段
- 公有子网：每个 AZ 一个 /24 网段
- 预留足够 IP 地址给 Pod（EKS 使用 VPC CNI）

### 2. 堡垒机（必需）

**⚠️ 重要说明**：由于集群使用私有 API 访问模式，**必须**从 VPC 内部执行部署脚本。堡垒机是访问私有集群的唯一方式。

| 项目 | 规格 |
|------|------|
| 实例类型 | t3.micro（最小），t3.small（推荐） |
| 操作系统 | Amazon Linux 2023 |
| 子网位置 | 私有子网（推荐）或公有子网 |
| IAM 角色 | AdministratorAccess 或等效权限 |
| 安全组 | 脚本自动配置（允许访问 EKS API） |
| Session Manager | 必需（通过 SSM 连接） |

**堡垒机用途**：
- 执行所有 EKS 部署脚本
- 运行 kubectl 命令管理集群
- 作为集群日常运维的跳板机

**访问方式**：
- 通过 AWS Systems Manager Session Manager（推荐，无需 SSH Key）
- 通过 SSH（需要配置密钥和公网访问）

### 3. 工具依赖

在堡垒机上需要安装以下工具：

| 工具 | 最低版本 | 安装验证命令 |
|------|---------|--------------|
| AWS CLI | v2.x | `aws --version` |
| eksctl | v0.150+ | `eksctl version` |
| kubectl | v1.31+ | `kubectl version --client` |
| helm | v3.x | `helm version` |
| jq | 任意 | `jq --version` |
| envsubst | 任意 | `envsubst --version` |

**一键安装命令**（Amazon Linux 2023）:
```bash
sudo yum update -y
sudo yum install -y git unzip tar gzip jq gettext

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
chmod +x /usr/local/bin/eksctl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 4. AWS 权限要求

堡垒机的 IAM 角色需要以下权限：
- EKS 集群创建和管理
- EC2 实例、安全组、Launch Template 管理
- IAM 角色和策略管理
- VPC Endpoints 创建
- CloudWatch Logs 访问
- Systems Manager (SSM) 访问

**推荐**：使用 `AdministratorAccess` 托管策略（生产环境可根据最小权限原则细化）

---

## 部署流程总览

### 部署顺序

```
┌─────────────────────────────────────────────────────────────┐
│                    场景选择                                    │
├─────────────────────────────────────────────────────────────┤
│  已有 VPC ────→ 第一阶段（创建堡垒机）                          │
│  新建 VPC ────→ 创建 VPC → 第一阶段（创建堡垒机）                │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│              第一阶段：准备堡垒机（必需）                         │
│  1. 创建堡垒机（如不存在）                                       │
│  2. 连接到堡垒机                                                │
│  3. 克隆项目代码                                                │
│  4. 配置 .env 文件                                              │
│  5. 安装工具依赖                                                │
│  6. 验证配置                                                    │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│           第二阶段：配置 VPC 网络（在堡垒机执行）                  │
│  1. 启用 VPC DNS 支持                                           │
│  2. （可选）验证网络环境                                         │
│  3. 创建 VPC Endpoints                                          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│          第三阶段：创建 EKS 集群（在堡垒机执行）                   │
│  1. 创建集群控制平面（8-10分钟）                                 │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│         第四阶段：创建系统节点组（在堡垒机执行）                    │
│  1. 配置安全组                                                  │
│  2. 创建节点组（带 LVM，8-12分钟）                               │
│  3. 验证节点就绪                                                │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│        第五阶段：安装集群组件（在堡垒机执行）                       │
│  1. 安装 Cluster Autoscaler                                    │
│  2. 安装 AWS Load Balancer Controller                          │
│  3. 安装 EBS CSI Driver                                         │
│  4. （可选）安装 EFS/S3 CSI Driver                              │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│             第六阶段：验证和测试（在堡垒机执行）                   │
│  1. 验证集群状态                                                │
│  2. 测试自动扩缩容                                              │
│  3. 测试持久化存储                                              │
└─────────────────────────────────────────────────────────────┘
```

### 时间预估

| 阶段 | 预计耗时 | 说明 |
|------|----------|------|
| 第一阶段：准备堡垒机 | 5-10 分钟 | 创建实例、安装工具、配置环境 |
| 第二阶段：配置 VPC 网络 | 2-3 分钟 | 启用 DNS、创建 VPC Endpoints |
| 第三阶段：创建集群控制平面 | 8-10 分钟 | 创建 EKS 集群 |
| 第四阶段：创建系统节点组 | 8-12 分钟 | 创建带 LVM 配置的节点组 |
| 第五阶段：安装集群组件 | 5-8 分钟 | 安装核心 Addons |
| 第六阶段：验证和测试 | 5-10 分钟 | 功能验证 |
| **总计** | **33-53 分钟** | 完整部署流程 |

---

## 第一阶段：准备堡垒机

### 步骤 1.1：创建堡垒机（必需）

**执行位置**：VPC 外部（AWS CloudShell、本地终端、或现有 EC2）

使用项目提供的脚本自动创建堡垒机：

```bash
# 1. 克隆项目代码到本地或 CloudShell
git clone <your-repository-url> eks-cluster-deployment
cd eks-cluster-deployment

# 2. 配置基本环境变量（临时用于创建堡垒机）
export VPC_ID=vpc-xxxxx
export PRIVATE_SUBNET_A=subnet-xxxxx  # 或使用公有子网
export AWS_REGION=eu-central-1
export CLUSTER_NAME=eks-demo-1

# 3. 执行堡垒机创建脚本
# 非交互模式（推荐）：
REUSE_BASTION=no ./scripts/option_create_bastion.sh

# 或交互模式（如果发现已有堡垒机会提示是否复用）：
./scripts/option_create_bastion.sh
```

脚本会自动创建：
- EC2 实例（t3.micro）
- IAM 角色和实例配置文件（包含管理员权限）
- 安全组（允许 HTTPS 出站）
- 自动安装 SSM Agent（用于 Session Manager 连接）
- 将实例 ID 保存到 `/tmp/eks-bastion-instance-id.txt`

**验证堡垒机创建成功**：
```bash
# 获取实例 ID
INSTANCE_ID=$(cat /tmp/eks-bastion-instance-id.txt)

# 验证实例状态
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text \
  --region ${AWS_REGION}

# 应输出: running
```

### 步骤 1.2：连接到堡垒机

使用 AWS Systems Manager Session Manager 连接（无需 SSH Key）：

```bash
# 获取实例 ID（如果使用自动化脚本创建）
INSTANCE_ID=$(cat /tmp/eks-bastion-instance-id.txt)

# 连接到实例
aws ssm start-session --target $INSTANCE_ID --region <your-region>
```

或通过 AWS 控制台：
1. 进入 EC2 控制台
2. 选择实例
3. 点击"连接" → "Session Manager" → "连接"

### 步骤 1.3：安装工具依赖

**执行位置**：堡垒机

在堡垒机上安装所需工具：

```bash
# 更新系统包
sudo yum update -y
sudo yum install -y git unzip tar gzip jq gettext

# 安装 kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# 安装 eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
chmod +x /usr/local/bin/eksctl

# 安装 helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 验证安装
kubectl version --client
eksctl version
helm version
aws --version
jq --version
```

### 步骤 1.4：克隆项目代码

**执行位置**：堡垒机

```bash
cd ~
git clone <your-repository-url> eks-cluster-deployment
cd eks-cluster-deployment
```

**或者**，如果代码在本地机器：
```bash
# 在本地打包
tar czf eks-project.tar.gz eks-cluster-deployment/

# 上传到 S3
aws s3 cp eks-project.tar.gz s3://your-bucket/

# 在堡垒机下载
aws s3 cp s3://your-bucket/eks-project.tar.gz .
tar xzf eks-project.tar.gz
cd eks-cluster-deployment
```

### 步骤 1.5：配置环境变量

**执行位置**：堡垒机

```bash
# 复制配置模板
cp .env.example .env

# 编辑配置文件
vim .env  # 或使用 nano
```

**必填配置项**：

```bash
# 集群名称（必须唯一）
CLUSTER_NAME=eks-demo-1

# VPC 和子网 ID
VPC_ID=vpc-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_A=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_B=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_C=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_A=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_B=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_C=subnet-xxxxxxxxxxxxxxxxx

# AWS 区域
AWS_REGION=eu-central-1
AWS_DEFAULT_REGION=eu-central-1
```

**可选配置项**（使用默认值即可）：

```bash
# Kubernetes 版本（默认: 1.34）
K8S_VERSION=1.34

# 系统节点组配置（默认值已优化）
SYSTEM_NODE_INSTANCE_TYPE=m7i.2xlarge
SYSTEM_NODE_ROOT_VOLUME_SIZE=50
SYSTEM_NODE_DATA_VOLUME_SIZE=100
SYSTEM_NODE_DESIRED_CAPACITY=3
SYSTEM_NODE_MIN_SIZE=3
SYSTEM_NODE_MAX_SIZE=6
```

### 步骤 1.6：验证配置

**执行位置**：堡垒机

```bash
# 给脚本执行权限
chmod +x scripts/*.sh

# 加载并验证环境变量
source scripts/0_setup_env.sh
```

**预期输出**：
```
=== Configuration Summary ===
ACCOUNT_ID: 123456789012
AWS_REGION: eu-central-1
CLUSTER_NAME: eks-demo-1
K8S_VERSION: 1.34
VPC_ID: vpc-xxx
PRIVATE_SUBNET_A: subnet-xxx
...
SYSTEM_NODE_LABEL: app=eks-utils
✓ Configuration validation completed successfully!
```

如果验证失败，检查 `.env` 文件中的配置是否正确。

---

## 第二阶段：配置 VPC 网络

**执行位置**：堡垒机

### 步骤 2.1：启用 VPC DNS 支持（必需）

```bash
./scripts/1_enable_vpc_dns.sh
```

**作用**：
- 启用 VPC DNS 主机名
- 启用 VPC DNS 解析
- 为 VPC Endpoints 提供必要的 DNS 支持

**预期输出**：
```
✓ DNS support enabled for VPC vpc-xxx
```

**耗时**: 约 10 秒

### 步骤 2.2：验证网络环境（可选）

```bash
./scripts/2_validate_network_environment.sh
```

**作用**：
- 验证 VPC 和子网配置
- 检查 NAT Gateway 和 Internet Gateway
- 验证路由表配置

### 步骤 2.3：创建 VPC Endpoints（必需）

```bash
./scripts/3_create_vpc_endpoints.sh
```

**作用**：
创建 13 个 VPC Endpoints，包括：
- **EKS 相关**: eks, eks-auth, sts
- **容器镜像**: ecr.api, ecr.dkr
- **日志和存储**: logs, s3
- **EKS 组件**: ec2, autoscaling, elasticloadbalancing, elasticfilesystem
- **Session Manager**: ssm, ssmmessages, ec2messages

**预期输出**：
```
✓ Creating VPC endpoint: com.amazonaws.eu-central-1.eks
✓ Creating VPC endpoint: com.amazonaws.eu-central-1.ecr.api
...
✓ All VPC endpoints created successfully
```

**耗时**: 约 2-3 分钟

**重要说明**：
- 这些 Endpoints 是**必需**的，确保私有集群能够访问 AWS 服务
- 如果堡垒机在私有子网，SSM 相关的 3 个 Endpoints 必须先创建
- 这些 Endpoints 会提高安全性并降低数据传输成本

**验证 Endpoints 创建成功**：
```bash
# 查看已创建的 VPC Endpoints
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[*].[ServiceName,State]' \
  --output table \
  --region ${AWS_REGION}

# 应显示 13 个 Endpoints，状态均为 available
```

---

## 第三阶段：创建 EKS 集群

**执行位置**：堡垒机

### 步骤 3.1：创建集群控制平面

```bash
./scripts/5_install_eks_cluster.sh
```

**执行内容**：
1. 验证依赖工具安装
2. 加载环境变量
3. 检查集群是否已存在（幂等性）
4. 使用 eksctl 创建控制平面
5. 等待集群状态变为 ACTIVE

**预期输出**：
```
=== EKS Cluster Installation ===
✓ All required dependencies are installed
Creating new cluster...
[ℹ]  eksctl version 0.xxx
[ℹ]  using region eu-central-1
[ℹ]  creating EKS cluster "eks-demo-1"
...
[✔]  EKS cluster "eks-demo-1" in "eu-central-1" is ready
```

**耗时**: 8-10 分钟

**配置详情**：
- API 访问模式：私有（`publicAccess: false`）
- Kubernetes 版本：1.34
- Pod Identity Agent：自动安装（v1.3.4）
- 核心 Addons：VPC CNI, CoreDNS, Kube-proxy

**验证命令**：
```bash
# 验证集群状态
aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query 'cluster.status'

# 应返回: "ACTIVE"
```

**注意事项**：
- ⚠️ 此步骤只创建控制平面，**不会创建任何节点**
- ⚠️ kubectl 命令此时无法正常工作（因为没有节点）

---

## 第四阶段：创建系统节点组

**执行位置**：堡垒机

### 步骤 4.1：创建系统节点组（带 LVM 配置）

```bash
# 非交互模式（自动删除旧节点组）：
AUTO_DELETE_NODEGROUP=yes ./scripts/6_create_system_nodegroup.sh

# 或交互模式（会提示确认）：
./scripts/6_create_system_nodegroup.sh
```

**执行内容**：
1. 验证集群状态
2. 配置安全组（允许堡垒机访问 EKS API）
3. 创建 IAM 角色和实例配置文件
4. 获取最新的 EKS 优化 AMI
5. 生成 LVM 配置的 User Data
6. 创建 Launch Template
7. 检查并删除旧节点组（如果存在）
8. 创建新节点组（3 个节点）
9. 等待节点就绪
10. 验证 LVM 配置

**预期输出**：
```
=== Create System Nodegroup with LVM Configuration ===
Expected duration: 8-12 minutes

Step 1: Gathering cluster information...
Step 2: Creating IAM Role and Instance Profile...
✓ IAM Role EKSNodeRole-eks-frankfurt already exists
✓ Instance Profile created

Step 3: Getting latest EKS optimized AMI...
AMI ID: ami-xxxxxxxxxxxxx

Step 4: Creating user-data with LVM configuration...
✓ User-data created

Step 5: Creating Launch Template...
Created Launch Template: lt-xxxxxxxxxxxxx

Step 6: Checking existing nodegroups...
✓ No existing nodegroups found

Step 7: Creating new nodegroup...
[ℹ]  building managed nodegroup stack "eks-demo-1-eks-utils"
...

Step 8: Waiting for nodes to be ready...
Ready nodes: 3/3
✓ All nodes are ready!

Step 9: Verifying LVM configuration...
✓ Node is Ready
✓ Instance type is correct: m7i.2xlarge
✓ LVM configuration verification complete

=== System Nodegroup with LVM Created Successfully ===
```

**耗时**: 8-12 分钟

**节点配置详情**：

| 配置项 | 值 |
|--------|-----|
| 实例类型 | m7i.2xlarge (8 vCPU, 32 GB RAM) |
| 根卷 | 50 GB gp3 |
| 数据卷 | 100 GB gp3 (LVM, 挂载到 /var/lib/containerd) |
| 节点数 | 3 (可扩展至 6) |
| 标签 | app=eks-utils, arch=x86_64 |
| 网络 | 私有子网，跨 3 个 AZ |
| Taints | 无（系统组件和应用都可以调度） |

**LVM 配置说明**：
- 自动创建 VG: `vg_data`
- 自动创建 LV: `lv_containerd` (100% VG)
- 自动格式化为 XFS
- 自动迁移 AMI 预缓存的镜像
- 自动挂载到 `/var/lib/containerd`
- 自动添加到 `/etc/fstab`

**验证命令**：
```bash
# 查看节点状态
kubectl get nodes -o wide

# 应显示 3 个 Ready 状态的节点
# NAME                                           STATUS   ROLES    AGE   VERSION
# ip-10-0-1-xxx.eu-central-1.compute.internal   Ready    <none>   5m    v1.34.x
# ip-10-0-2-xxx.eu-central-1.compute.internal   Ready    <none>   5m    v1.34.x
# ip-10-0-3-xxx.eu-central-1.compute.internal   Ready    <none>   5m    v1.34.x

# 查看节点详细信息
kubectl describe node <node-name>

# 验证标签
kubectl get nodes --show-labels | grep eks-utils

# 手动验证 LVM 配置（在节点上）
kubectl debug node/<node-name> -it --image=busybox -- sh
chroot /host bash
vgs              # 应显示 vg_data
lvs              # 应显示 lv_containerd
df -h /var/lib/containerd  # 应显示 100GB
```

**故障排查**：

如果节点未就绪，检查以下内容：

1. **安全组配置**：
```bash
# 检查堡垒机是否能访问集群 API
aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query 'cluster.resourcesVpcConfig.securityGroupIds'
```

2. **Launch Template 日志**：
```bash
# 获取实例 ID
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-eks-utils-node" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --region ${AWS_REGION})

# 查看系统日志
aws ec2 get-console-output --instance-id $INSTANCE_ID --region ${AWS_REGION}

# 或通过 SSM 连接查看日志
aws ssm start-session --target $INSTANCE_ID --region ${AWS_REGION}
sudo cat /var/log/lvm-setup.log
```

---

## 第五阶段：安装集群组件

**执行位置**：堡垒机

### 步骤 5.1：安装核心组件

```bash
./scripts/7_install_eks_addon.sh
```

**执行内容**：
1. 验证集群和节点状态
2. 等待 Pod Identity Agent 就绪
3. 配置 Cluster Autoscaler（使用 Pod Identity）
4. 部署 Cluster Autoscaler RBAC 和 Deployment
5. 配置 AWS Load Balancer Controller（使用 Pod Identity）
6. 使用 Helm 安装 Load Balancer Controller
7. 配置 EBS CSI Driver（使用 Pod Identity）
8. 安装 EBS CSI Driver Addon（确保运行在系统节点上）
9. 验证所有组件状态

**预期输出**：
```
=== EKS Addons Installation ===
✓ All required dependencies are installed

Step 3.1: Waiting for Pod Identity Agent...
✓ Pod Identity Agent is ready

Step 4: Setting up Cluster Autoscaler with Pod Identity...
✓ IAM role created: eks-demo-1-cluster-autoscaler-role
✓ Pod Identity association created
Deploying Cluster Autoscaler RBAC...
Deploying Cluster Autoscaler...
✓ Cluster Autoscaler is ready

Step 5: Setting up AWS Load Balancer Controller...
✓ IAM role created: eks-demo-1-aws-load-balancer-controller-role
✓ Pod Identity association created
Deploying Load Balancer Controller...
✓ AWS Load Balancer Controller is ready

Step 6: Setting up EBS CSI Driver...
✓ IAM role created: eks-demo-1-ebs-csi-driver-role
✓ Pod Identity association created
✓ EBS CSI Driver addon is ACTIVE
✓ EBS CSI Controller is ready

=== EKS Addons Installation Complete ===
✓ Cluster Autoscaler installed and configured
✓ AWS Load Balancer Controller installed and configured
✓ EBS CSI Driver addon installed and configured
✓ All components use Pod Identity for AWS authentication
```

**耗时**: 5-8 分钟

**安装的组件**：

| 组件 | 版本 | 用途 | 认证方式 |
|------|------|------|----------|
| Cluster Autoscaler | v1.34.2 | 自动扩缩容节点 | Pod Identity |
| AWS Load Balancer Controller | v1.13.0 | 管理 ALB/NLB | Pod Identity |
| EBS CSI Driver | v1.37.0 | 持久化块存储 | Pod Identity |

**验证命令**：

```bash
# 1. 查看所有 Pod 状态
kubectl get pods -A

# 应该看到以下 Pod 都处于 Running 状态：
# NAMESPACE     NAME                                            READY   STATUS
# kube-system   aws-load-balancer-controller-xxx-yyy            1/1     Running
# kube-system   cluster-autoscaler-xxx-yyy                      1/1     Running
# kube-system   coredns-xxx-yyy                                  1/1     Running
# kube-system   ebs-csi-controller-xxx-yyy                       6/6     Running
# kube-system   ebs-csi-node-xxx                                 3/3     Running

# 2. 验证 Cluster Autoscaler
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=20

# 应该看到类似日志：
# I1229 10:00:00.000000       1 static_autoscaler.go:xxx] Starting main loop
# I1229 10:00:00.000000       1 utils.go:xxx] No pod using affinity / antiaffinity found in cluster

# 3. 验证 Load Balancer Controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20

# 应该看到类似日志：
# {"level":"info","msg":"controller started"}

# 4. 验证 EBS CSI Driver
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# 应该看到 controller 和 node 都在运行

# 5. 验证 Pod Identity 关联
aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME} \
  --region ${AWS_REGION}

# 应该看到 3 个关联（autoscaler, alb-controller, ebs-csi-driver）
```

**测试 EBS CSI Driver**：

```bash
# 创建测试 PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ebs-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi
EOF

# 验证 PVC 状态
kubectl get pvc test-ebs-pvc

# 应该看到 STATUS 为 Bound

# 清理测试资源
kubectl delete pvc test-ebs-pvc
```

**故障排查**：

1. **Cluster Autoscaler 无法启动**：
```bash
# 检查日志
kubectl logs -n kube-system -l app=cluster-autoscaler

# 常见问题：
# - IAM 权限不足
# - 节点组标签缺失
# - Pod Identity 配置错误
```

2. **Load Balancer Controller 无法启动**：
```bash
# 检查日志
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 常见问题：
# - VPC ID 配置错误
# - IAM 权限不足
# - Service Account 配置错误
```

3. **EBS CSI Driver 无法创建卷**：
```bash
# 检查 controller 日志
kubectl logs -n kube-system -l app=ebs-csi-controller

# 检查 node 日志
kubectl logs -n kube-system -l app=ebs-csi-node

# 常见问题：
# - IAM 权限不足
# - 节点安全组未允许 EBS 访问
# - KMS 密钥权限问题
```

---

## 第六阶段：验证和测试

**执行位置**：堡垒机

### 步骤 6.1：验证集群状态

```bash
# 1. 查看集群信息
kubectl cluster-info

# 2. 查看节点状态
kubectl get nodes -o wide

# 3. 查看所有 Pod
kubectl get pods -A

# 4. 查看系统资源使用情况
kubectl top nodes
kubectl top pods -A --sort-by=memory

# 5. 查看集群事件
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

### 步骤 6.2：测试自动扩缩容

创建测试工作负载触发节点自动扩容：

```bash
# 部署测试应用
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscaler-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        resources:
          requests:
            cpu: 1000m
            memory: 1Gi
EOF

# 扩容到 10 个副本，触发自动扩容
kubectl scale deployment autoscaler-test --replicas=10

# 观察节点数量变化（新节点创建需要 3-5 分钟）
watch kubectl get nodes

# 查看 Cluster Autoscaler 日志
kubectl logs -n kube-system -l app=cluster-autoscaler -f

# 缩容回 0
kubectl scale deployment autoscaler-test --replicas=0

# 等待 10 分钟后，多余的节点会被自动删除

# 清理测试资源
kubectl delete deployment autoscaler-test
```

### 步骤 6.3：测试 Load Balancer

部署示例应用验证 ALB 创建：

```bash
# 部署 2048 游戏示例
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/examples/2048/2048_full.yaml

# 等待 Ingress 创建 ALB（约 3-5 分钟）
kubectl get ingress -n game-2048 -w

# 获取 ALB URL
ALB_URL=$(kubectl get ingress -n game-2048 -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "访问地址: http://$ALB_URL"

# 在浏览器中访问 URL，应该看到 2048 游戏

# 清理测试资源
kubectl delete namespace game-2048
```

### 步骤 6.4：测试 EBS 持久化存储

```bash
# 创建 PVC 和测试 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ebs-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ebs-test-pod
spec:
  containers:
  - name: app
    image: centos:7
    command: ["/bin/sh"]
    args: ["-c", "while true; do echo \$(date -u) >> /data/out.txt; sleep 5; done"]
    volumeMounts:
    - name: persistent-storage
      mountPath: /data
  volumes:
  - name: persistent-storage
    persistentVolumeClaim:
      claimName: ebs-test-pvc
EOF

# 等待 Pod 运行
kubectl wait --for=condition=Ready pod/ebs-test-pod --timeout=120s

# 验证数据写入
kubectl exec ebs-test-pod -- tail /data/out.txt

# 删除 Pod（保留 PVC）
kubectl delete pod ebs-test-pod

# 创建新 Pod 验证数据持久化
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ebs-test-pod-2
spec:
  containers:
  - name: app
    image: centos:7
    command: ["/bin/sh"]
    args: ["-c", "cat /data/out.txt && sleep 3600"]
    volumeMounts:
    - name: persistent-storage
      mountPath: /data
  volumes:
  - name: persistent-storage
    persistentVolumeClaim:
      claimName: ebs-test-pvc
EOF

# 验证数据仍然存在
kubectl logs ebs-test-pod-2

# 清理测试资源
kubectl delete pod ebs-test-pod-2
kubectl delete pvc ebs-test-pvc
```

---

## 部署后管理

### 日常维护建议

**堡垒机管理**：
- ✅ **推荐保留**：堡垒机是访问私有集群的必要跳板
- 💡 **节省成本**：可以在不使用时停止实例（而非终止）
- 🔧 **定期维护**：定期更新工具版本（kubectl, eksctl, helm）

**停止/启动堡垒机**：
```bash
# 停止实例（保留所有配置和数据）
aws ec2 stop-instances \
  --instance-ids $INSTANCE_ID \
  --region ${AWS_REGION}

# 需要时重新启动
aws ec2 start-instances \
  --instance-ids $INSTANCE_ID \
  --region ${AWS_REGION}

# 注意：重启后 IP 地址可能变化
```

### 可选功能部署

#### 安装可选 CSI 驱动

**执行位置**：堡垒机

安装 EFS、FSx 或 S3 CSI Driver：

```bash
# 非交互模式 - 安装 EFS CSI Driver
INSTALL_DRIVERS=efs ./scripts/option_install_csi_drivers.sh

# 非交互模式 - 安装 FSx Lustre CSI Driver
INSTALL_DRIVERS=fsx ./scripts/option_install_csi_drivers.sh

# 非交互模式 - 安装 S3 CSI Driver
INSTALL_DRIVERS=s3 S3_BUCKET_ARNS='arn:aws:s3:::my-bucket' ./scripts/option_install_csi_drivers.sh

# 或交互模式（会提示选择）
./scripts/option_install_csi_drivers.sh
```

#### 安装 Karpenter（按需扩缩容）

**执行位置**：堡垒机

如需更灵活的节点自动扩缩容，可安装 Karpenter：

```bash
./scripts/option_install_karpenter.sh
```

**Karpenter vs Cluster Autoscaler**：
- Cluster Autoscaler：基于节点组扩缩容，适合固定规格节点
- Karpenter：按需创建最适合的节点，更灵活和快速

#### 测试 Pod 调度

**执行位置**：堡垒机

```bash
# 非交互模式（自动重启 Karpenter）
AUTO_RESTART_KARPENTER=yes ./examples/option_test_pod_scheduling.sh

# 或交互模式
./examples/option_test_pod_scheduling.sh
```

#### 测试 Karpenter 节点池

**执行位置**：堡垒机

```bash
# 非交互模式（自动清理测试资源）
AUTO_CLEANUP_TEST=yes ./examples/option_test_karpenter_pools.sh

# 或交互模式
./examples/option_test_karpenter_pools.sh
```

---

## 常见问题排查

### 问题 1：kubectl 无法连接到集群

**症状**：
```
The connection to the server localhost:8080 was refused
```

**原因**：KUBECONFIG 环境变量未设置

**解决方案**：
```bash
# 设置 KUBECONFIG
export KUBECONFIG="${HOME}/.kube/config"

# 更新 kubeconfig
aws eks update-kubeconfig \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION}

# 验证连接
kubectl get nodes
```

### 问题 2：kubectl 超时

**症状**：
```
dial tcp 10.0.x.x:443: i/o timeout
```

**原因**：
1. 堡垒机安全组未允许访问 EKS API
2. VPC Endpoints 未创建
3. 不在 VPC 内部执行

**解决方案**：
```bash
# 1. 验证安全组
aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query 'cluster.resourcesVpcConfig.securityGroupIds'

# 2. 重新执行脚本 6（会自动配置安全组）
./scripts/6_create_system_nodegroup.sh

# 3. 确认 VPC Endpoints 存在
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --region ${AWS_REGION}
```

### 问题 3：节点无法加入集群

**症状**：节点显示 NotReady 或 Pod 无法调度

**排查步骤**：
```bash
# 1. 查看节点状态
kubectl describe node <node-name>

# 2. 检查 kubelet 日志
kubectl debug node/<node-name> -it --image=busybox -- sh
chroot /host bash
journalctl -u kubelet -f

# 3. 验证 IAM 权限
aws iam get-role --role-name EKSNodeRole-eks-frankfurt

# 4. 验证安全组
aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
  --query 'Reservations[].Instances[].SecurityGroups'
```

### 问题 4：LVM 配置失败

**症状**：节点就绪但 containerd 数据未在 LVM 卷上

**排查步骤**：
```bash
# 连接到节点
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-eks-utils-node" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --region ${AWS_REGION})

aws ssm start-session --target $INSTANCE_ID --region ${AWS_REGION}

# 查看 LVM 配置日志
sudo cat /var/log/lvm-setup.log

# 验证 LVM 状态
sudo vgs
sudo lvs
df -h /var/lib/containerd

# 验证磁盘
lsblk

# 如果 LVM 未创建，手动执行配置
# （参考脚本 6 中的 User Data 内容）
```

### 问题 5：Pod Identity 认证失败

**症状**：Pod 日志显示 AWS 认证错误

**排查步骤**：
```bash
# 1. 验证 Pod Identity Agent 运行
kubectl get pods -n kube-system -l app.kubernetes.io/name=eks-pod-identity-agent

# 2. 检查 Pod Identity 关联
aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME} \
  --region ${AWS_REGION}

# 3. 验证 IAM 角色存在
aws iam get-role --role-name ${CLUSTER_NAME}-cluster-autoscaler-role

# 4. 验证 IAM 策略附加
aws iam list-attached-role-policies \
  --role-name ${CLUSTER_NAME}-cluster-autoscaler-role

# 5. 检查 Service Account 配置
kubectl get sa -n kube-system cluster-autoscaler -o yaml
```

---

## 附录

### A. 配置文件说明

#### .env 文件结构

```bash
# ========== 必填配置 ==========
CLUSTER_NAME=                 # EKS 集群名称
VPC_ID=                       # VPC ID
PRIVATE_SUBNET_A/B/C=         # 私有子网 ID（3个）
PUBLIC_SUBNET_A/B/C=          # 公有子网 ID（3个）
AWS_REGION=                   # AWS 区域
AWS_DEFAULT_REGION=           # AWS 默认区域（同 AWS_REGION）

# ========== 可选配置 ==========
K8S_VERSION=1.34              # Kubernetes 版本
SERVICE_IPV4_CIDR=172.20.0.0/16  # 服务 CIDR
SYSTEM_NODE_INSTANCE_TYPE=m7i.2xlarge  # 系统节点实例类型
SYSTEM_NODE_ROOT_VOLUME_SIZE=50        # 根卷大小 (GB)
SYSTEM_NODE_DATA_VOLUME_SIZE=100       # 数据卷大小 (GB)
SYSTEM_NODE_DESIRED_CAPACITY=3         # 期望节点数
SYSTEM_NODE_MIN_SIZE=3                 # 最小节点数
SYSTEM_NODE_MAX_SIZE=6                 # 最大节点数
```

### B. 脚本说明

**核心部署脚本**：

| 脚本 | 用途 | 执行位置 | 必需 |
|------|------|---------|------|
| 0_setup_env.sh | 加载和验证环境变量 | 被其他脚本调用 | ✅ |
| 1_enable_vpc_dns.sh | 启用 VPC DNS | VPC 外/内 | 推荐 |
| 2_validate_network_environment.sh | 验证网络配置 | VPC 外/内 | 可选 |
| 3_create_vpc_endpoints.sh | 创建 VPC Endpoints | VPC 外/内 | 推荐 |
| option_create_bastion.sh | 创建堡垒机 | VPC 外 | 推荐 |
| 5_install_eks_cluster.sh | 创建集群控制平面 | VPC 内 | ✅ |
| 6_create_system_nodegroup.sh | 创建系统节点组 | VPC 内 | ✅ |
| 7_install_eks_addon.sh | 安装集群 Addons | VPC 内 | ✅ |

**可选功能脚本**：

| 脚本 | 用途 | 执行位置 |
|------|------|---------|
| option_install_csi_drivers.sh | 安装 EFS/FSx/S3 CSI Driver | VPC 内 |
| option_install_karpenter.sh | 安装 Karpenter 自动扩缩容 | VPC 内 |
| examples/option_test_pod_scheduling.sh | 测试 Pod 调度 | VPC 内 |
| examples/option_test_karpenter_pools.sh | 测试 Karpenter 节点池 | VPC 内 |

### C. 端口和协议要求

#### 节点安全组

| 端口 | 协议 | 源 | 用途 |
|------|------|-----|------|
| 443 | TCP | 控制平面安全组 | kubelet → API Server |
| 1025-65535 | TCP | 节点安全组 | Pod 间通信 |
| 53 | TCP/UDP | 节点安全组 | CoreDNS |

#### 控制平面安全组

| 端口 | 协议 | 源 | 用途 |
|------|------|-----|------|
| 443 | TCP | 堡垒机安全组 | kubectl → API Server |
| 443 | TCP | 节点安全组 | kubelet → API Server |

### D. IAM 角色和策略

#### 系统节点 IAM 角色

**角色名称**：`EKSNodeRole-eks-frankfurt`

**附加的托管策略**：
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryReadOnly`
- `AmazonSSMManagedInstanceCore`

#### Cluster Autoscaler IAM 角色

**角色名称**：`${CLUSTER_NAME}-cluster-autoscaler-role`

**自定义策略**：允许 Auto Scaling 操作

#### Load Balancer Controller IAM 角色

**角色名称**：`${CLUSTER_NAME}-aws-load-balancer-controller-role`

**自定义策略**：允许 ALB/NLB 管理

#### EBS CSI Driver IAM 角色

**角色名称**：`${CLUSTER_NAME}-ebs-csi-driver-role`

**自定义策略**：允许 EBS 卷管理

### E. 标签规范

所有资源都应该打上以下标签：

| 标签键 | 标签值 | 用途 |
|--------|--------|------|
| kubernetes.io/cluster/${CLUSTER_NAME} | owned | EKS 集群所有权 |
| k8s.io/cluster-autoscaler/enabled | true | 允许自动扩缩容 |
| k8s.io/cluster-autoscaler/${CLUSTER_NAME} | owned | 自动扩缩容标识 |
| business | middleware | 业务类型 |
| resource | eks | 资源类型 |

### F. 参考文档

- [AWS EKS 官方文档](https://docs.aws.amazon.com/eks/)
- [eksctl 文档](https://eksctl.io/)
- [Kubernetes 文档](https://kubernetes.io/docs/)
- [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)

---

## 变更历史

| 版本 | 日期 | 变更内容 | 作者 |
|------|------|----------|------|
| v1.0 | 2025-12-29 | 初始版本 | Platform Team |

---

**文档维护者**: Platform Team
**最后审核**: 2026-01-03
**下次审核**: 2026-04-03
