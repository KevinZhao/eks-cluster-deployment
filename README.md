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
./scripts/4_install_eks_cluster.sh
```

**部署时间:** 约 20-25 分钟

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

### 方式 1: 标准部署 ⭐ 推荐新手

**特点:**
- ✅ 配置简单，只需 .env 文件
- ✅ 快速部署，约 20 分钟
- ❌ 无法自定义 SSH Key
- ❌ 无法添加数据盘
- ❌ 无法自定义 User Data

**适用:** 测试环境、学习、演示

**命令:**
```bash
./scripts/4_install_eks_cluster.sh
```

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

| 特性 | 标准部署 | Launch Template |
|------|---------|----------------|
| 复杂度 | ⭐ 简单 | ⭐⭐⭐ 中等 |
| SSH Key | ❌ | ✅ |
| 数据盘 | ❌ | ✅ |
| 预装软件 | ❌ | ✅ |
| 系统优化 | ❌ | ✅ |
| 部署时间 | 20分钟 | 25-30分钟 |

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
PRIVATE_SUBNET_2A=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_2B=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_2C=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_2A=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_2B=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_2C=subnet-xxxxxxxxxxxxxxxxx
AWS_REGION=ap-southeast-1
AWS_DEFAULT_REGION=ap-southeast-1
```

### Step 2: 执行部署

```bash
chmod +x scripts/*.sh
./scripts/4_install_eks_cluster.sh
```

**自动执行:**
1. 创建 EKS 集群（15-20分钟）
2. 部署 Cluster Autoscaler
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
PRIVATE_SUBNET_2A=subnet-xxx
PRIVATE_SUBNET_2B=subnet-xxx
PRIVATE_SUBNET_2C=subnet-xxx
PUBLIC_SUBNET_2A=subnet-xxx
PUBLIC_SUBNET_2B=subnet-xxx
PUBLIC_SUBNET_2C=subnet-xxx
AWS_REGION=ap-southeast-1
AWS_DEFAULT_REGION=ap-southeast-1
```

**可选:**
```bash
K8S_VERSION=1.34
SERVICE_IPV4_CIDR=172.20.0.0/16
AZ_2A=ap-southeast-1a
AZ_2B=ap-southeast-1b
AZ_2C=ap-southeast-1c
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
│   ├── 0_setup_env.sh          # 环境变量加载
│   ├── 4_install_eks_cluster.sh            # 标准部署
│   └── 6_install_eks_with_custom_nodegroup.sh  # Launch Template 部署
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
