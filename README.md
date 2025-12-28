# EKS 集群自动化部署完整指南

生产级 AWS EKS 集群自动化部署方案，支持标准部署和自定义 Launch Template 部署。

[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)

---

## 📋 目录

- [功能特性](#功能特性)
- [快速开始](#快速开始)
- [架构说明](#架构说明)
- [部署方式选择](#部署方式选择)
- [前置要求](#前置要求)
- [标准部署](#标准部署)
- [Launch Template 部署](#launch-template-部署)
- [配置说明](#配置说明)
- [成本优化](#成本优化)
- [验证和测试](#验证和测试)
- [故障排查](#故障排查)
  - [如何从 VPC 外部署集群](#如何从-vpc-外部署集群)
- [清理资源](#清理资源)

---

## 🚀 功能特性

### 核心功能
- ✅ **自动化部署** - 一键部署完整 EKS 集群
- ✅ **多 AZ 高可用** - 跨 3 个可用区部署
- ✅ **混合架构** - 系统节点 Intel，应用节点 Graviton，兼顾兼容性和成本
- ✅ **工作负载隔离** - 系统组件和应用完全隔离
- ✅ **自动扩缩容** - Cluster Autoscaler 自动管理节点
- ✅ **存储支持** - EBS/EFS/S3 CSI Driver
- ✅ **负载均衡** - AWS Load Balancer Controller
- ✅ **自定义节点** - 支持 Launch Template 自定义配置（SSH Key、数据盘、预装软件）

### 支持的存储类型
- **EBS** (gp3) - 块存储，适合数据库
- **EFS** - 共享文件系统，适合多 Pod 访问
- **S3** (Mountpoint) - 对象存储，适合大数据

### 已集成组件
| 组件 | 版本 | 用途 |
|------|------|------|
| Kubernetes | 1.34 | 容器编排 |
| VPC CNI | v1.18.5 | Pod 网络 |
| CoreDNS | v1.11.3 | DNS 解析 |
| Kube-proxy | v1.31.2 | 网络代理 |
| Pod Identity Agent | v1.3.4 | IAM 认证 |
| EBS CSI Driver | v1.37.0 | 块存储 |
| Cluster Autoscaler | v1.34.2 | 自动扩缩容 |
| AWS LB Controller | v2.11.0 | 负载均衡 |

---

## ⚡ 快速开始

### 最简部署（5 分钟配置 + 20 分钟等待）

```bash
# 1. 配置环境变量
cp .env.example .env
nano .env  # 填写 VPC_ID、子网 ID 等

# 2. 部署集群
chmod +x scripts/*.sh

# 步骤2.1: 创建集群控制平面
./scripts/4_install_eks_cluster.sh

# 步骤2.2: 创建系统节点组（带LVM配置）
./scripts/4.5_create_system_nodegroup_with_lvm.sh

# 步骤2.3: 安装集群addons
./scripts/5_install_eks_addon.sh
```

**部署时间:** 约 20-25 分钟（3个步骤合计）

> ⚠️ **重要提示**：本项目集群配置为私有 API 访问（`publicAccess: false`），部署脚本需要从 **VPC 内部** 执行。如果您在 VPC 外部（如 CloudShell、本地机器），请参考 [如何从 VPC 外部署集群](#如何从-vpc-外部署集群) 章节。

---

## 🏗️ 架构说明

### 集群架构

```
EKS Cluster (Kubernetes 1.34)
├── Control Plane (AWS 托管)
│   └── API Server (内网访问)
│
├── eks-utils 节点组 (3x m7i.large, Intel)
│   ├── 无 Taint
│   └── 运行: CoreDNS, Cluster Autoscaler, LB Controller, CSI Controllers
│
└── app 节点组 (3x c8g.large, Graviton ARM64)
    ├── Taint: workload=user-apps:NoSchedule
    └── 运行: 用户应用（需要 toleration）
```

### 网络架构

```
VPC (10.0.0.0/16)
├── 3个可用区
│   ├── Public Subnet → IGW
│   │   └── NAT Gateway
│   └── Private Subnet → NAT GW
│       └── EKS 节点
```

---

## 🎯 部署方式选择

### 方式 1: 标准部署 ⭐ 推荐

**特点:**
- ✅ 配置简单，只需 .env 文件
- ✅ 系统节点组使用LVM配置（m7i.2xlarge + 100GB数据卷）
- ✅ 灵活部署，可独立创建控制平面和节点组
- ✅ 自动创建Launch Template和IAM资源
- ✅ 快速部署，约 15-20 分钟

**适用:** 生产环境、测试环境、学习、演示

**部署步骤:**
```bash
# 步骤1: 创建集群控制平面（无节点组）
./scripts/4_install_eks_cluster.sh

# 步骤2: 创建系统节点组（带LVM配置）
./scripts/4.5_create_system_nodegroup_with_lvm.sh

# 步骤3: 安装集群addons
./scripts/5_install_eks_addon.sh
```

**更新说明（2025-12-28）:**
- ✅ 系统节点组创建逻辑分离为独立脚本 4.5
- ✅ 脚本4仅创建控制平面，提供更高灵活性
- ✅ 脚本4.5专门创建带LVM配置的系统节点组
- ✅ 支持灵活的部署流程，可按需跳过或重新运行

### 方式 2: Launch Template 部署 ⭐ 推荐生产

**特点:**
- ✅ 完全自定义节点配置
- ✅ 支持 SSH Key（如 spider.pem）
- ✅ 支持额外数据盘（如 1000GB）
- ✅ 支持自定义 User Data（预装软件、系统优化）
- ✅ Terraform 管理，状态可追踪

**适用:** 生产环境、需要 SSH、需要数据盘、需要预装软件

**命令:**
```bash
./scripts/6_install_eks_with_custom_nodegroup.sh
```

### 对比表格

| 特性 | 标准部署 | Launch Template（应用节点组） |
|------|---------|----------------|
| 复杂度 | ⭐ 简单 | ⭐⭐⭐ 中等 |
| 系统节点LVM | ✅ 自动配置 | ✅ 自动配置 |
| 应用节点LVM | ❌ | ✅ 自动配置 |
| SSH Key | ❌ | ✅ |
| 自定义User Data | ❌ | ✅ |
| 系统优化 | ✅ 基础配置 | ✅ 完全自定义 |
| 部署时间 | 15-20分钟 | 20-25分钟 |

**说明:** 标准部署（脚本4）现在会自动为系统节点组配置LVM（m7i.2xlarge + 100GB数据卷），无需额外操作。

---

## 📦 前置要求

### 1. AWS 网络环境

**必须预先创建:**
- 1 个 VPC
- 3 个公有子网（每个 AZ）
- 3 个私有子网（每个 AZ）
- NAT Gateway（至少 1 个，建议 3 个）
- Internet Gateway

**快速创建 VPC:**
```bash
cd terraform/vpc
terraform init
terraform apply

# 获取输出用于 .env
terraform output env_file_format
```

### 2. 工具要求

| 工具 | 最小版本 | 检查命令 |
|------|---------|---------|
| AWS CLI | v2.x | `aws --version` |
| eksctl | v0.150+ | `eksctl version` |
| kubectl | v1.31+ | `kubectl version --client` |
| helm | v3.x | `helm version` |
| envsubst | - | `envsubst --version` |
| terraform* | v1.0+ | `terraform version` |

*仅 Launch Template 部署需要

**一键安装（Amazon Linux 2023）:**
```bash
sudo yum install -y aws-cli kubectl gettext

curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# terraform（可选）
wget https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip
unzip terraform_1.7.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/
```

### 3. AWS 权限

需要: EKS、EC2、IAM、CloudWatch Logs、VPC 权限

---

## 🔧 标准部署

### Step 1: 配置环境变量

```bash
cp .env.example .env
nano .env
```

**必填:**
```bash
CLUSTER_NAME=eks-demo-1
VPC_ID=vpc-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_A=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_B=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_C=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_A=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_B=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_C=subnet-xxxxxxxxxxxxxxxxx
AWS_REGION=ap-southeast-1
AWS_DEFAULT_REGION=ap-southeast-1
```

### Step 2: 执行部署

```bash
chmod +x scripts/*.sh

# 步骤1: 创建集群控制平面
./scripts/4_install_eks_cluster.sh

# 步骤2: 创建系统节点组（带LVM配置）
./scripts/4.5_create_system_nodegroup_with_lvm.sh

# 步骤3: 安装集群addons
./scripts/5_install_eks_addon.sh
```

**自动执行:**
1. 脚本4: 创建 EKS 集群控制平面（8-10分钟）
2. 脚本4.5: 创建系统节点组，配置LVM（8-12分钟）
3. 脚本5: 部署 Cluster Autoscaler 和其他addons
3. 安装 AWS Load Balancer Controller
4. 迁移到 Pod Identity

### Step 3: 验证

```bash
# 检查节点（应该有 6 个）
kubectl get nodes -o wide

# 检查系统组件
kubectl get pods -n kube-system

# 检查 Cluster Autoscaler
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=20
```

---

## 🎨 Launch Template 部署

### 使用场景：爬虫项目示例

**需求:**
- SSH Key: spider.pem
- 数据盘: 1000GB
- 预装: Python、爬虫库、监控工具
- 优化: 文件描述符、TCP 参数

### Step 1: 创建 SSH Key

```bash
# 创建新 key
aws ec2 create-key-pair \
  --key-name spider \
  --region ap-southeast-1 \
  --query 'KeyMaterial' \
  --output text > spider.pem
chmod 400 spider.pem

# 验证
aws ec2 describe-key-pairs --key-names spider --region ap-southeast-1
```

### Step 2: 配置 Launch Template

```bash
cd terraform/launch-template

# 使用示例配置
cp terraform.tfvars.spider-example terraform.tfvars

# 查看配置
cat terraform.tfvars
```

**配置内容示例:**
```hcl
key_name = "spider"
instance_type = "c8g.large"

# 系统盘
root_volume_size = 30
root_volume_type = "gp3"

# 数据盘 1000GB
data_volume_size = 1000
data_volume_type = "gp3"
data_volume_iops = 5000
data_volume_throughput = 250

# 自定义 User Data
custom_userdata = <<-EOT
  # 挂载 1000GB 数据盘到 /data
  if [ -e /dev/xvdb ]; then
    mkfs -t xfs /dev/xvdb
    mkdir -p /data
    mount /dev/xvdb /data
    echo '/dev/xvdb /data xfs defaults,nofail 0 2' >> /etc/fstab
  fi
  
  # 安装 Python + 爬虫库
  yum install -y python3 python3-pip htop
  pip3 install requests beautifulsoup4 scrapy selenium
  
  # 系统优化
  echo "* soft nofile 65536" >> /etc/security/limits.conf
  echo "* hard nofile 65536" >> /etc/security/limits.conf
EOT
```

### Step 3: 一键部署

```bash
cd ../..
./scripts/6_install_eks_with_custom_nodegroup.sh
```

**执行流程:**
1. 检查 SSH Key
2. Terraform 创建 Launch Template（1-2分钟）
3. 创建 EKS 基础集群（15-20分钟）
4. 创建 app 节点组（5-10分钟）
5. 部署 Autoscaler 和 LB Controller

### Step 4: 验证自定义配置

```bash
# 获取实例 ID
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*app-node*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text --region ap-southeast-1)

# 使用 SSM 连接
aws ssm start-session --target $INSTANCE_ID --region ap-southeast-1

# 在节点上验证
sudo cat /var/log/spider-node-init.log  # 初始化日志
df -h /data                              # 验证数据盘
tree -L 2 /data                          # 查看目录
python3 --version                        # 验证 Python
pip3 list | grep scrapy                  # 验证库
```

### Step 5: 使用 SSH（可选）

```bash
# 从 VPC 内部
NODE_IP=$(kubectl get nodes -l workload=user-apps \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

ssh -i spider.pem ec2-user@$NODE_IP
```

---

## ⚙️ 配置说明

### .env 配置

**必需:**
```bash
CLUSTER_NAME=eks-demo-1
VPC_ID=vpc-xxx
PRIVATE_SUBNET_A=subnet-xxx
PRIVATE_SUBNET_B=subnet-xxx
PRIVATE_SUBNET_C=subnet-xxx
PUBLIC_SUBNET_A=subnet-xxx
PUBLIC_SUBNET_B=subnet-xxx
PUBLIC_SUBNET_C=subnet-xxx
AWS_REGION=ap-southeast-1
AWS_DEFAULT_REGION=ap-southeast-1
```

**可选:**
```bash
K8S_VERSION=1.34
SERVICE_IPV4_CIDR=172.20.0.0/16
AZ_A=ap-southeast-1a
AZ_B=ap-southeast-1b
AZ_C=ap-southeast-1c
```

### Launch Template 配置

**完整示例（terraform.tfvars）:**
```hcl
aws_region   = "ap-southeast-1"
cluster_name = "eks-demo-1"
vpc_id       = "vpc-xxx"

# SSH Key
key_name = "spider"

# 实例
instance_type = "c8g.large"

# 根卷
root_volume_size = 30
root_volume_type = "gp3"

# 数据盘
data_volume_size = 1000
data_volume_type = "gp3"
data_volume_iops = 5000
data_volume_throughput = 250

# User Data
custom_userdata = <<-EOT
# 你的自定义脚本
EOT
```

---

## 💰 成本优化

### 标准部署成本（新加坡）

| 项目 | 配置 | 月度 |
|------|------|------|
| EKS Control Plane | - | $72 |
| eks-utils | 3x m7i.large | $263 |
| app | 3x c8g.large | $180 |
| EBS | 6x 30GB gp3 | $18 |
| Logs | 30天 | $30 |
| NAT GW | 3个 | $96 |
| **总计** | | **$659** |

### Launch Template（含1000GB数据盘）

| 项目 | 月度 |
|------|------|
| 基础 | $659 |
| **数据盘** | **+$300** |
| **总计** | **$959** |

### 优化建议

**1. 使用 Spot 实例（节省 ~70%）**
```yaml
spot: true
instanceTypes: ["c8g.large", "c7g.large"]
```
节省: ~$126/月

**2. 单 NAT Gateway**
```hcl
single_nat_gateway = true
```
节省: $64/月

**3. 减少数据盘**
```hcl
data_volume_size = 500
```
节省: $150/月

**优化后:** $469-619/月（节省 29-51%）

---

## ✅ 验证和测试

### 1. 验证集群

```bash
# 节点
kubectl get nodes -o wide

# 标签
kubectl get nodes --show-labels

# Taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Pod
kubectl get pods -A -o wide
```

### 2. 测试 Autoscaler

```bash
# 部署测试
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test
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
      tolerations:
      - key: "workload"
        operator: "Equal"
        value: "user-apps"
        effect: "NoSchedule"
      nodeSelector:
        workload: user-apps
      containers:
      - name: nginx
        image: nginx:alpine
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
EOF

# 扩容触发自动扩容
kubectl scale deployment test --replicas=10
watch kubectl get nodes

# 缩容
kubectl scale deployment test --replicas=0

# 清理
kubectl delete deployment test
```

### 3. 测试 Load Balancer

```bash
# 部署 2048 游戏
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/examples/2048/2048_full.yaml

# 等待 ALB（3-5 分钟）
kubectl get ingress -n game-2048 -w

# 访问
ALB_URL=$(kubectl get ingress -n game-2048 -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB_URL"

# 清理
kubectl delete namespace game-2048
```

### 4. 测试 EBS

```bash
# 创建 PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3
EOF

# 检查
kubectl get pvc test-pvc

# 清理
kubectl delete pvc test-pvc
```

---

## 🔧 故障排查

### 问题 1: 集群创建失败

```bash
# 查看 CloudFormation
aws cloudformation describe-stack-events \
  --stack-name eksctl-${CLUSTER_NAME}-cluster \
  --region ${AWS_REGION}

# 检查 VPC
aws ec2 describe-vpcs --vpc-ids $VPC_ID
```

### 问题 2: 无法访问 API Server

**错误:** `dial tcp 10.0.x.x:443: i/o timeout`

**原因:** API 纯内网访问（`publicAccess: false`）

**解决:**
- 从 VPC 内部部署
- 或临时启用公网:
```bash
# 修改 manifests/cluster/eksctl_cluster_base.yaml
# publicAccess: false → publicAccess: true
```

详细解决方案请参考下方的 [如何从 VPC 外部署集群](#如何从-vpc-外部署集群) 章节。

---

## 如何从 VPC 外部署集群

### 背景说明

本项目的 EKS 集群采用 **私有 API 访问架构**（`publicAccess: false`），这意味着：

- ✅ **安全性高**：API Server 仅在 VPC 内部可访问，不暴露到公网
- ❌ **部署限制**：所有 kubectl 命令必须从 VPC 内部执行
- ❌ **CloudShell 不可用**：CloudShell 运行在 AWS 管理环境中，不在您的 VPC 内
- ❌ **本地机器不可用**：除非通过 VPN 连接到 VPC

**部署流程对比**：

```
✅ VPC 内部署（推荐）:
  EC2 (VPC内) → EKS API (私有10.0.x.x) → 集群部署成功

❌ VPC 外部署（会失败）:
  CloudShell/本地 → [无法访问] → EKS API (私有10.0.x.x) → 失败: dial tcp timeout

⚠️ 临时公网访问:
  CloudShell/本地 → Internet → EKS API (公网临时) → 集群部署成功 → 禁用公网
```

**哪些操作受影响**：

| 脚本/操作 | VPC 外可执行 | 说明 |
|----------|------------|------|
| `0_setup_env.sh` | ✅ 可以 | 仅设置环境变量 |
| `1_enable_vpc_dns.sh` | ✅ 可以 | AWS API 操作 |
| `2_validate_network_environment.sh` | ✅ 可以 | AWS API 验证 |
| `3_create_vpc_endpoints.sh` | ✅ 可以 | AWS API 操作 |
| `eksctl create cluster` | ✅ 可以 | AWS 托管操作 |
| `kubectl get nodes` | ❌ 不可以 | 需要访问私有 API |
| `kubectl apply/helm install` | ❌ 不可以 | 需要访问私有 API |
| 所有组件部署 | ❌ 不可以 | 需要访问私有 API |

---

### 推荐方案：使用临时跳板机部署

#### 方案优势

- ✅ **安全**：API Server 始终保持私有，不暴露到公网
- ✅ **符合最佳实践**：生产环境推荐配置
- ✅ **成本极低**：t3.micro 运行 30 分钟 < $0.01
- ✅ **无需 SSH 密钥**：使用 AWS Systems Manager Session Manager

> ⚠️ **前置要求**：如果您计划将 EC2 实例创建在**私有子网**中，必须先运行 `./scripts/3_create_vpc_endpoints.sh` 创建 VPC 端点（包括 SSM 相关的 3 个端点：`ssm`、`ssmmessages`、`ec2messages`）。否则 Session Manager 将无法连接。

---

#### 步骤 0：创建 VPC 端点（如果尚未创建）

如果您尚未创建 VPC 端点，请先运行：

```bash
# 启用 VPC DNS（必需）
./scripts/1_enable_vpc_dns.sh

# 创建 VPC 端点（包含 SSM 端点）
./scripts/3_create_vpc_endpoints.sh
```

这将创建 13 个 VPC 端点，包括：
- **EKS 相关**：eks、eks-auth、sts
- **容器镜像**：ecr.api、ecr.dkr
- **日志和存储**：logs、s3
- **EKS 组件**：ec2、autoscaling、elasticloadbalancing、elasticfilesystem
- **Session Manager（关键）**：ssm、ssmmessages、ec2messages

等待 2-3 分钟让端点变为可用状态。

---

#### 步骤 1：创建临时 EC2 实例

> 💡 **简化方式**：使用项目提供的自动化脚本一键创建跳板机：
> ```bash
> ./scripts/create_bastion.sh
> ```
> 该脚本会自动完成以下所有步骤（1.1-1.5），跳到步骤 2 连接实例即可。

**手动创建步骤**（如果不使用自动化脚本）：

**1.1 准备配置**

首先确认您的环境变量（来自 `.env` 文件）：

```bash
# 加载环境变量
source scripts/0_setup_env.sh

# 确认变量
echo "VPC ID: $VPC_ID"
echo "Private Subnet: $PRIVATE_SUBNET_A"
```

**1.2 获取最新的 Amazon Linux 2023 AMI**

```bash
# 获取最新 AMI ID
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region ${AWS_DEFAULT_REGION})

echo "将使用 AMI: $AMI_ID"
```

**1.3 创建或确认 IAM 角色**

EC2 实例需要以下权限：

```bash
# 检查角色是否存在
aws iam get-role --role-name EKS-Deploy-Role 2>/dev/null

# 如果不存在，创建角色
if [ $? -ne 0 ]; then
  echo "创建 IAM 角色..."

  # 创建信任策略
  cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  # 创建角色
  aws iam create-role \
    --role-name EKS-Deploy-Role \
    --assume-role-policy-document file:///tmp/trust-policy.json

  # 附加必要权限（根据您的需求调整）
  aws iam attach-role-policy \
    --role-name EKS-Deploy-Role \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

  aws iam attach-role-policy \
    --role-name EKS-Deploy-Role \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess  # 仅用于部署，部署后可删除

  # 创建实例配置文件
  aws iam create-instance-profile --instance-profile-name EKS-Deploy-Profile
  aws iam add-role-to-instance-profile \
    --instance-profile-name EKS-Deploy-Profile \
    --role-name EKS-Deploy-Role

  # 等待角色生效
  echo "等待 IAM 角色生效..."
  sleep 10
fi
```

**1.4 创建安全组（如果不存在）**

```bash
# 创建安全组（仅允许出站流量，Session Manager 不需要入站）
SG_ID=$(aws ec2 create-security-group \
  --group-name eks-deploy-temp-sg \
  --description "Temporary SG for EKS deployment" \
  --vpc-id ${VPC_ID} \
  --output text \
  --region ${AWS_DEFAULT_REGION})

echo "创建的安全组 ID: $SG_ID"

# 添加标签
aws ec2 create-tags \
  --resources $SG_ID \
  --tags Key=Name,Value=eks-deploy-temp-sg \
  --region ${AWS_DEFAULT_REGION}
```

**1.5 启动 EC2 实例**

```bash
# 创建 EC2 实例
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ${AMI_ID} \
  --instance-type t3.micro \
  --subnet-id ${PUBLIC_SUBNET_A} \
  --security-group-ids ${SG_ID} \
  --iam-instance-profile Name=EKS-Deploy-Profile \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=EKS-Deploy-Temp},{Key=Purpose,Value=EKS-Deployment},{Key=AutoDelete,Value=true}]' \
  --region ${AWS_DEFAULT_REGION} \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "实例 ID: $INSTANCE_ID"

# 等待实例运行
echo "等待实例启动..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region ${AWS_DEFAULT_REGION}

# 等待 SSM Agent 就绪（大约 1-2 分钟）
echo "等待 Systems Manager Agent 就绪..."
for i in {1..30}; do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text \
    --region ${AWS_DEFAULT_REGION} 2>/dev/null)

  if [ "$STATUS" = "Online" ]; then
    echo "✅ 实例已就绪！"
    break
  fi

  echo "等待中... ($i/30)"
  sleep 10
done
```

**成本说明**：t3.micro 按需实例约 $0.0104/小时（us-east-1），部署耗时 20-30 分钟，总成本不到 $0.01。

---

#### 步骤 2：连接到实例

**使用 AWS Systems Manager Session Manager（推荐）**：

```bash
# 如果使用自动化脚本创建，实例 ID 已保存
INSTANCE_ID=$(cat /tmp/eks-bastion-instance-id.txt)

# 方式 1：通过 AWS CLI 连接
aws ssm start-session \
  --target $INSTANCE_ID \
  --region ${AWS_DEFAULT_REGION}

# 方式 2：通过 AWS 控制台连接
# 访问 EC2 控制台 → 选择实例 → 点击"连接" → 选择"Session Manager"标签页 → 点击"连接"
```

**优势**：
- ✅ 无需 SSH 密钥
- ✅ 无需开放 22 端口
- ✅ 所有会话记录在 CloudTrail
- ✅ 可通过 IAM 精细控制访问权限

连接成功后，您将看到类似的提示符：

```
sh-5.2$
```

---

#### 步骤 3：在实例上安装必要工具

> 💡 **简化方式**：使用项目提供的自动化脚本一键安装所有工具：
> ```bash
> # 从 GitHub 下载安装脚本
> curl -O https://raw.githubusercontent.com/your-username/eks-cluster-deployment/main/scripts/install_tools.sh
> bash install_tools.sh
> ```
>
> 或者如果已经克隆了项目：
> ```bash
> cd eks-cluster-deployment
> ./scripts/install_tools.sh
> ```

**手动安装步骤**（如果不使用自动化脚本）：

连接到实例后，执行以下命令安装所有必要工具：

```bash
#!/bin/bash
# 一键安装所有部署工具

echo "=== 安装 EKS 部署工具 ==="

# 更新系统
sudo yum update -y

# 安装基础工具
sudo yum install -y git unzip tar gzip jq

# 1. 安装 kubectl
echo "安装 kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# 2. 安装 eksctl
echo "安装 eksctl..."
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
chmod +x /usr/local/bin/eksctl

# 3. 安装 helm
echo "安装 helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 4. 验证安装
echo ""
echo "=== 验证工具版本 ==="
kubectl version --client
eksctl version
helm version
aws --version

echo ""
echo "✅ 所有工具安装完成！"
```

**预期输出**：

```
Client Version: v1.31.x
eksctl version: 0.x.x
version.BuildInfo{Version:"v3.x.x"...}
aws-cli/2.x.x Python/3.x.x Linux/6.x.x
```

---

#### 步骤 4：克隆项目并运行安装脚本

**4.1 克隆项目代码**

如果项目在 Git 仓库中：

```bash
# 克隆项目
cd ~
git clone <your-repository-url> eks-cluster-deployment
cd eks-cluster-deployment

# 或者，如果需要认证
git clone https://github.com/your-username/eks-cluster-deployment.git
```

如果项目不在 Git 仓库，可以从本地上传：

```bash
# 在本地机器上打包
tar czf eks-project.tar.gz eks-cluster-deployment/

# 上传到 S3
aws s3 cp eks-project.tar.gz s3://your-bucket/

# 在 EC2 实例上下载
aws s3 cp s3://your-bucket/eks-project.tar.gz .
tar xzf eks-project.tar.gz
cd eks-cluster-deployment
```

**4.2 配置环境变量**

```bash
# 复制并编辑配置文件
cp .env.example .env
nano .env  # 或使用 vi

# 确保填写正确的值：
# - CLUSTER_NAME
# - VPC_ID
# - 所有子网 ID
# - AWS_REGION
```

**4.3 运行安装脚本**

```bash
# 给脚本执行权限
chmod +x scripts/*.sh

# 标准部署流程
./scripts/4_install_eks_cluster.sh                 # 创建集群控制平面
./scripts/4.5_create_system_nodegroup_with_lvm.sh  # 创建系统节点组（LVM）
./scripts/5_install_eks_addon.sh                   # 安装addons

# 或者包含网络配置的完整部署
./scripts/1_enable_vpc_dns.sh
./scripts/2_validate_network_environment.sh
./scripts/3_create_vpc_endpoints.sh
./scripts/4_install_eks_cluster.sh
./scripts/4.5_create_system_nodegroup_with_lvm.sh
./scripts/5_install_eks_addon.sh
```

**部署时间**：约 20-25 分钟（3个核心步骤）

**监控部署进度**：

```bash
# 查看集群创建状态
eksctl get cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION}

# 查看节点状态
kubectl get nodes

# 查看所有 Pod
kubectl get pods -A
```

---

#### 步骤 5：清理临时资源

部署完成并验证集群正常后，清理临时 EC2 实例：

> 💡 **简化方式**：使用项目提供的自动化脚本删除跳板机：
> ```bash
> ./scripts/delete_bastion.sh
> ```
> 该脚本会自动查找并删除跳板机实例。

**手动清理步骤**（如果不使用自动化脚本）：

**5.1 退出 Session Manager**

```bash
# 在 EC2 实例的 shell 中执行
exit
```

**5.2 终止 EC2 实例**

```bash
# 在本地或 CloudShell 中执行

# 获取实例 ID（如果使用自动化脚本创建）
INSTANCE_ID=$(cat /tmp/eks-bastion-instance-id.txt)

# 或手动查找
# INSTANCE_ID=$(aws ec2 describe-instances \
#   --filters "Name=tag:Name,Values=EKS-Deploy-Bastion-${CLUSTER_NAME}" \
#   --query 'Reservations[0].Instances[0].InstanceId' \
#   --output text)

# 终止实例
aws ec2 terminate-instances \
  --instance-ids $INSTANCE_ID \
  --region ${AWS_DEFAULT_REGION}

# 验证实例已终止
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text \
  --region ${AWS_DEFAULT_REGION}
```

**5.3 清理安全组和 IAM 资源（可选）**

```bash
# 等待实例完全终止后，删除安全组
aws ec2 delete-security-group \
  --group-id $SG_ID \
  --region ${AWS_DEFAULT_REGION}

# 如果不再需要，删除 IAM 角色
aws iam remove-role-from-instance-profile \
  --instance-profile-name EKS-Deploy-Profile \
  --role-name EKS-Deploy-Role

aws iam delete-instance-profile \
  --instance-profile-name EKS-Deploy-Profile

aws iam detach-role-policy \
  --role-name EKS-Deploy-Role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam detach-role-policy \
  --role-name EKS-Deploy-Role \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

aws iam delete-role --role-name EKS-Deploy-Role
```

---

### 备选方案：临时启用公网访问

如果您更倾向于从 CloudShell 或本地机器直接部署（适用于开发/测试环境），可以临时启用公网访问。

#### 方案优势

- ✅ **简单快捷**：无需创建额外资源
- ✅ **零成本**：使用 CloudShell 完全免费
- ⚠️ **安全性较低**：临时暴露 API Server 到公网

#### 实施步骤

**步骤 1：修改集群配置**

编辑 `manifests/cluster/eksctl_cluster_base.yaml`:

```yaml
clusterEndpoints:
  privateAccess: true
  publicAccess: true        # 修改为 true
  publicAccessCIDRs:        # 可选：限制访问 IP
    - "YOUR_IP/32"          # 替换为您的公网 IP
```

**获取您的公网 IP**：

```bash
curl ifconfig.me
# 或
curl checkip.amazonaws.com
```

**步骤 2：在 CloudShell 中运行部署**

```bash
# 克隆项目
git clone <your-repo> eks-cluster-deployment
cd eks-cluster-deployment

# 配置环境
cp .env.example .env
nano .env

# 运行安装
./scripts/4_install_eks_cluster.sh                 # 创建集群控制平面
./scripts/4.5_create_system_nodegroup_with_lvm.sh  # 创建系统节点组
./scripts/5_install_eks_addon.sh                   # 安装addons
```

**步骤 3：部署完成后禁用公网访问**

选项 A：使用 AWS CLI（从任何地方）

```bash
aws eks update-cluster-config \
  --name ${CLUSTER_NAME} \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true \
  --region ${AWS_DEFAULT_REGION}

# 等待更新完成（约 5 分钟）
aws eks wait cluster-active \
  --name ${CLUSTER_NAME} \
  --region ${AWS_DEFAULT_REGION}
```

选项 B：使用项目提供的脚本（需要从 VPC 内或公网访问仍然启用时）

```bash
./scripts/disable_public_access.sh
```

---

### 故障排查

#### 问题 1：Session Manager 无法连接

**症状**：`aws ssm start-session` 返回错误或超时

**排查步骤**：

```bash
# 1. 确认实例状态
aws ec2 describe-instance-status --instance-ids $INSTANCE_ID

# 2. 确认 SSM Agent 状态
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID"

# 3. 检查 IAM 角色是否正确附加
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile'

# 4. 检查 VPC 端点（如果使用私有子网）
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID"
```

**解决方案**：
- 等待 2-3 分钟让 SSM Agent 完全初始化
- 确认 IAM 角色包含 `AmazonSSMManagedInstanceCore` 策略
- **如果使用私有子网，必须确保 VPC 有以下 3 个端点**：
  - `com.amazonaws.<region>.ssm` - Systems Manager 端点
  - `com.amazonaws.<region>.ssmmessages` - Session Manager 消息端点
  - `com.amazonaws.<region>.ec2messages` - EC2 消息端点（用于 SSM Agent）

**重要提示**：本项目的 `scripts/3_create_vpc_endpoints.sh` 脚本已经包含了这 3 个 SSM 端点。如果您的 VPC 端点是手动创建的或使用旧版本脚本，请运行以下命令补充创建：

```bash
# 重新运行 VPC 端点创建脚本（会跳过已存在的端点）
./scripts/3_create_vpc_endpoints.sh

# 或手动创建缺失的 SSM 端点
source scripts/0_setup_env.sh

# 创建 ssmmessages 端点
aws ec2 create-vpc-endpoint \
  --vpc-id ${VPC_ID} \
  --service-name com.amazonaws.${AWS_REGION}.ssmmessages \
  --vpc-endpoint-type Interface \
  --subnet-ids ${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B} ${PRIVATE_SUBNET_C} \
  --security-group-ids <your-vpc-endpoints-sg-id> \
  --private-dns-enabled

# 创建 ec2messages 端点
aws ec2 create-vpc-endpoint \
  --vpc-id ${VPC_ID} \
  --service-name com.amazonaws.${AWS_REGION}.ec2messages \
  --vpc-endpoint-type Interface \
  --subnet-ids ${PRIVATE_SUBNET_A} ${PRIVATE_SUBNET_B} ${PRIVATE_SUBNET_C} \
  --security-group-ids <your-vpc-endpoints-sg-id> \
  --private-dns-enabled
```

#### 问题 2：kubectl 提示权限不足

**症状**：`error: You must be logged in to the server (Unauthorized)`

**解决方案**：

```bash
# 更新 kubeconfig
aws eks update-kubeconfig \
  --name ${CLUSTER_NAME} \
  --region ${AWS_DEFAULT_REGION}

# 验证配置
kubectl config current-context
kubectl get nodes
```

#### 问题 3：工具安装失败

**症状**：kubectl/eksctl/helm 安装错误

**解决方案**：

```bash
# 检查网络连接
ping -c 3 google.com

# 如果在私有子网，检查 NAT Gateway
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID"

# 检查路由表
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID"
```

---

### 最佳实践建议

1. **生产环境**：
   - ✅ 使用临时跳板机方案
   - ✅ 保持 API Server 私有访问
   - ✅ 使用 Session Manager 而非 SSH
   - ✅ 部署完成立即删除跳板机

2. **开发/测试环境**：
   - ✅ 可以临时启用公网访问
   - ✅ 使用 IP 白名单限制访问
   - ✅ 部署完成后禁用公网访问

3. **长期维护**：
   - 考虑设置永久跳板机（使用自动关机策略降低成本）
   - 或配置 AWS Client VPN
   - 或使用 AWS Direct Connect / Site-to-Site VPN

4. **安全建议**：
   - ❌ 不要长期启用 API Server 公网访问
   - ✅ 使用 IAM 角色而非长期密钥
   - ✅ 定期审计 CloudTrail 日志
   - ✅ 使用 Security Groups 和 Network ACLs 加固网络

---

### 问题 3: Pod 无法调度到 app 节点

**原因:** 缺少 Toleration

**解决:**
```yaml
spec:
  tolerations:
  - key: "workload"
    operator: "Equal"
    value: "user-apps"
    effect: "NoSchedule"
  nodeSelector:
    workload: user-apps
```

### 问题 4: SSH Key 不存在

```bash
# 创建
aws ec2 create-key-pair --key-name spider --region ap-southeast-1 \
  --query 'KeyMaterial' --output text > spider.pem
chmod 400 spider.pem
```

### 问题 5: 数据盘未挂载

```bash
# SSH 到节点
aws ssm start-session --target <instance-id>

# 查看磁盘
lsblk

# 检查日志
sudo cat /var/log/spider-node-init.log

# 手动挂载
sudo mkfs -t xfs /dev/xvdb
sudo mount /dev/xvdb /data
```

---

## 🗑️ 清理资源

### 完整清理

```bash
# 1. 删除测试应用
kubectl delete deployment test 2>/dev/null || true
kubectl delete namespace game-2048 2>/dev/null || true

# 2. 删除 Load Balancer
kubectl delete ingress --all -A

# 3. 删除 PVC
kubectl delete pvc --all -A

# 4. 等待
sleep 60

# 5. 删除集群
eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_REGION} --wait
```

### 清理 Launch Template

```bash
cd terraform/launch-template
terraform destroy
```

### 清理 VPC

```bash
cd terraform/vpc
terraform destroy
```

---

## 📊 项目结构

```
eks-cluster-deployment/
├── README.md                    # 本文档（唯一文档）
├── .env.example                 # 环境变量模板
│
├── scripts/
│   ├── 0_setup_env.sh                          # 环境变量加载
│   ├── 4_install_eks_cluster.sh                # 创建集群控制平面
│   ├── 4.5_create_system_nodegroup_with_lvm.sh # 创建系统节点组（LVM）
│   ├── 5_install_eks_addon.sh                  # 安装集群addons
│   └── 6_install_eks_with_custom_nodegroup.sh  # Launch Template部署（应用节点组）
│
├── manifests/
│   ├── cluster/
│   │   ├── eksctl_cluster_template.yaml    # 原始（两个节点组）
│   │   ├── eksctl_cluster_base.yaml        # 基础（仅 eks-utils）
│   │   └── eksctl_nodegroup_app.yaml       # app 节点组
│   ├── addons/
│   │   ├── cluster-autoscaler-rbac.yaml
│   │   ├── cluster-autoscaler.yaml
│   │   ├── efs-csi-driver.yaml
│   │   └── s3-csi-driver.yaml
│   └── examples/
│       ├── autoscaler.yaml
│       ├── ebs-app.yaml
│       ├── efs-app.yaml
│       └── s3-app.yaml
│
└── terraform/
    ├── vpc/                     # VPC 创建
    ├── vpc-endpoints/           # VPC Endpoints
    └── launch-template/         # Launch Template
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── terraform.tfvars.spider-example  # Spider 示例
```

---

## 📚 常用命令

### 集群管理
```bash
# 查看集群
eksctl get cluster --region=${AWS_REGION}

# 更新 kubeconfig
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

# 节点组
eksctl get nodegroup --cluster=${CLUSTER_NAME} --region=${AWS_REGION}
```

### 节点管理
```bash
# 列出节点
kubectl get nodes -o wide

# 详情
kubectl describe node <node-name>

# 资源使用
kubectl top nodes
```

### 监控
```bash
# Pod 资源
kubectl top pods -A --sort-by=memory

# 事件
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# 日志
kubectl logs -n kube-system -l app=cluster-autoscaler -f
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -f
```

### Launch Template
```bash
# 查看
aws ec2 describe-launch-templates --region ${AWS_REGION}

# 更新
cd terraform/launch-template
terraform apply

# 更新节点组
eksctl upgrade nodegroup --cluster=${CLUSTER_NAME} --name=app --region=${AWS_REGION}
```

---

## 🆘 获取帮助

### 文档
- [AWS EKS](https://docs.aws.amazon.com/eks/)
- [eksctl](https://eksctl.io/)
- [Kubernetes](https://kubernetes.io/docs/)
- [Cluster Autoscaler](https://github.com/kubernetes/autoscaler)

### 排查流程
1. `kubectl describe pod <pod-name>`
2. `kubectl logs <pod-name>`
3. `kubectl describe node <node-name>`
4. 查看 CloudFormation
5. 查看 CloudWatch Logs

---

## 📝 更新日志

### v2.0 (2025-12-09)
- ✅ 添加 Launch Template 支持
- ✅ 支持自定义 SSH Key、数据盘、User Data
- ✅ 添加 Spider 爬虫项目示例
- ✅ 统一文档，删除冗余文件
- ✅ 更新所有配置为最新版本

### v1.0 (2025-12-05)
- ✅ 初始版本
- ✅ 混合架构（Intel + Graviton）
- ✅ Cluster Autoscaler
- ✅ AWS Load Balancer Controller
- ✅ EBS/EFS/S3 CSI Driver

---

**维护者:** Platform Team
**最后更新:** 2025-12-09
**文档版本:** v2.0

---

## 🚨 部署执行记录

### 新加坡集群部署 (2025-12-09)

**集群信息**:
- 名称: eks-singapore
- 区域: ap-southeast-1
- 状态: ✅ ACTIVE
- 节点: 6个 (3x m7i.large + 3x c8g.large)
- 部署时间: 约13分钟

**堡垒机**:
- 实例ID: i-0b3bc4cfb8b84e34c
- 子网: subnet-0b3ff3647c930a34e
- 用途: VPC内部部署集群

### kubectl 配置重要提示

**问题**: kubectl 尝试连接 localhost:8080

**原因**: `KUBECONFIG` 环境变量未设置

**解决方案**:
```bash
# 在任何使用kubectl的脚本中,添加:
export KUBECONFIG="${HOME}/.kube/config"

# 或在命令中指定:
kubectl --kubeconfig=/root/.kube/config get nodes
```

**最佳实践**: 
- 始终在脚本开头显式设置 `KUBECONFIG`
- 对私有集群,使用 `timeout` 避免长时间等待
- 提供 AWS CLI 备用验证方案

详细说明见部署脚本: [scripts/working_deploy_eks.sh](scripts/working_deploy_eks.sh)

