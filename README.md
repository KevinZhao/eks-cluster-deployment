# EKS 集群自动化部署

生产级 AWS EKS 集群自动化部署方案，包含完整的安全配置、成本优化和最佳实践。

[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.31-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 📋 目录

- [功能特性](#功能特性)
- [快速开始](#快速开始)
- [前置要求](#前置要求)
- [项目结构](#项目结构)
- [配置说明](#配置说明)
- [部署步骤](#部署步骤)
- [版本信息](#版本信息)
- [安全配置](#安全配置)
- [成本优化](#成本优化)
- [测试验证](#测试验证)
- [监控和日志](#监控和日志)
- [故障排查](#故障排查)
- [清理资源](#清理资源)

---

## 🚀 功能特性

### 核心功能
- ✅ **自动化部署** - 一键部署完整 EKS 集群
- ✅ **多 AZ 高可用** - 跨 3 个可用区部署
- ✅ **Graviton 架构** - 使用 AWS Graviton3 (c8g.large) 节省 31% 成本
- ✅ **自动扩缩容** - Cluster Autoscaler 自动管理节点
- ✅ **存储支持** - EBS/EFS/S3 CSI Driver
- ✅ **负载均衡** - AWS Load Balancer Controller
- ✅ **安全加固** - 纯内网 API、Pod Security、Network Policy

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
| EFS CSI Driver | v2.1.15 | 文件存储 |
| S3 CSI Driver | v2.2.1 | 对象存储 |
| Cluster Autoscaler | v1.34.2 | 自动扩缩容 |
| AWS LB Controller | v2.11.0 | 负载均衡 |

---

## ⚡ 快速开始

```bash
# 1. 克隆仓库
git clone <repository-url>
cd eks-cluster-deployment

# 2. 配置环境变量
cp .env.example .env
nano .env  # 填写必需的配置

# 3. 部署集群
chmod +x scripts/*.sh
./scripts/install_eks_cluster.sh
```

**部署时间:** 约 20-30 分钟

**架构说明:**
- 默认使用 AWS Graviton3 (c8g.large) ARM64 架构
- 相比 Intel 实例节省 31% 成本，性能相当或更好
- 所有容器镜像均支持 ARM64 架构（multi-arch）

**节点组划分:**
- **eks-utils (3节点)**: 系统组件专用，运行 CoreDNS、Cluster Autoscaler、AWS LB Controller 等
- **app (3节点)**: 应用工作负载专用，带 taint 防止系统组件调度

---

## 📦 前置要求

### 1. AWS 网络环境

必须预先创建以下资源：

#### VPC 和子网
- **1 个 VPC**
- **3 个公有子网**（每个 AZ 一个）
- **3 个私有子网**（每个 AZ 一个）
- **NAT Gateway**（至少 1 个，建议 3 个）
- **Internet Gateway**

#### 路由配置
```
私有子网 → 0.0.0.0/0 → NAT Gateway → Internet Gateway
公有子网 → 0.0.0.0/0 → Internet Gateway
```

#### 网络架构图
```
VPC (10.0.0.0/16)
├── AZ-A (us-east-2a)
│   ├── Public Subnet (10.0.1.0/24)  → IGW
│   │   └── NAT Gateway
│   └── Private Subnet (10.0.11.0/24) → NAT GW → IGW
│       └── EKS 节点
├── AZ-B (us-east-2b)
│   ├── Public Subnet (10.0.2.0/24)  → IGW
│   │   └── NAT Gateway
│   └── Private Subnet (10.0.12.0/24) → NAT GW → IGW
│       └── EKS 节点
└── AZ-C (us-east-2c)
    ├── Public Subnet (10.0.3.0/24)  → IGW
    │   └── NAT Gateway
    └── Private Subnet (10.0.13.0/24) → NAT GW → IGW
        └── EKS 节点
```

### 2. 工具要求

| 工具 | 最小版本 | 安装命令 |
|------|---------|---------|
| AWS CLI | v2.x | `brew install awscli` 或 [官方文档](https://aws.amazon.com/cli/) |
| eksctl | v0.150+ | `brew install eksctl` 或 [官方文档](https://eksctl.io/) |
| kubectl | v1.31+ | `brew install kubectl` 或 [官方文档](https://kubernetes.io/docs/tasks/tools/) |
| helm | v3.x | `brew install helm` 或 [官方文档](https://helm.sh/) |
| envsubst | - | `brew install gettext` |

#### macOS 安装
```bash
brew install awscli eksctl kubectl helm gettext
```

#### Amazon Linux 2023 安装
```bash
sudo yum install -y aws-cli kubectl gettext

# eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 3. AWS 权限

需要以下 IAM 权限：
- EKS 完整权限
- EC2 完整权限
- IAM 创建角色和策略权限
- CloudWatch Logs 写入权限
- VPC 读取权限

---

## 📁 项目结构

### 节点组架构

```
EKS Cluster (Kubernetes 1.34)
├── eks-utils 节点组 (3x c8g.large)
│   ├── 标签: app=eks-utils, arch=arm64
│   ├── 无 Taint (接受所有系统组件)
│   └── 运行组件:
│       ├── CoreDNS
│       ├── Cluster Autoscaler
│       ├── AWS Load Balancer Controller
│       ├── EBS/EFS/S3 CSI Controllers
│       └── kube-proxy, vpc-cni
│
└── app 节点组 (3x c8g.large)
    ├── 标签: app=application, arch=arm64, workload=user-apps
    ├── Taint: workload=user-apps:NoSchedule
    └── 运行组件:
        └── 用户应用 Pod（需要容忍 taint）
```

### 目录结构

```
eks-cluster-deployment/
├── README.md                           # 本文档
├── .env.example                        # 环境变量模板
├── .gitignore                          # Git 忽略规则
│
├── scripts/                            # 部署脚本
│   ├── setup_env.sh                   # 环境变量加载和验证
│   ├── install_eks_cluster.sh         # 主安装脚本
│   ├── apply_critical_fixes.sh        # 自动修复脚本
│   └── error_handling.sh              # 错误处理库（生成）
│
├── manifests/                          # Kubernetes 清单
│   ├── cluster/                       # 集群配置
│   │   ├── eksctl_cluster_template.yaml      # EKS 集群模板
│   │   ├── addon-versions-patch.yaml         # Addon 版本锁定（生成）
│   │   ├── resource-controls.yaml            # 资源配额（生成）
│   │   ├── pod-security.yaml                 # Pod 安全标准（生成）
│   │   ├── network-policies.yaml             # 网络策略（生成）
│   │   ├── cost-optimized-nodes.yaml         # 成本优化配置（生成）
│   │   └── s3-csi-policy.json                # S3 限制策略（生成）
│   │
│   ├── addons/                        # 集群插件
│   │   ├── cluster-autoscaler-rbac.yaml
│   │   ├── cluster-autoscaler.yaml
│   │   ├── efs-csi-driver.yaml
│   │   └── s3-csi-driver.yaml
│   │
│   └── examples/                      # 测试示例
│       ├── autoscaler.yaml            # 测试自动扩缩容
│       ├── ebs-app.yaml              # 测试 EBS 存储
│       ├── efs-app.yaml              # 测试 EFS 存储
│       └── s3-app.yaml               # 测试 S3 存储
│
└── eksctl_cluster_final.yaml          # 最终生成的配置（.gitignore）
```

---

## ⚙️ 配置说明

### 环境变量配置

1. **复制模板**
   ```bash
   cp .env.example .env
   ```

2. **填写必需配置**
   ```bash
   # 集群基本信息
   CLUSTER_NAME=my-eks-cluster

   # VPC 和子网 ID
   VPC_ID=vpc-xxxxxxxxxxxxxxxxx
   PRIVATE_SUBNET_2A=subnet-xxxxxxxxxxxxxxxxx
   PRIVATE_SUBNET_2B=subnet-xxxxxxxxxxxxxxxxx
   PRIVATE_SUBNET_2C=subnet-xxxxxxxxxxxxxxxxx
   PUBLIC_SUBNET_2A=subnet-xxxxxxxxxxxxxxxxx
   PUBLIC_SUBNET_2B=subnet-xxxxxxxxxxxxxxxxx
   PUBLIC_SUBNET_2C=subnet-xxxxxxxxxxxxxxxxx
   ```

3. **可选配置**
   ```bash
   # AWS 配置（自动检测）
   AWS_REGION=us-east-2
   ACCOUNT_ID=123456789012

   # Kubernetes 配置
   K8S_VERSION=1.31
   SERVICE_IPV4_CIDR=172.20.0.0/16  # 不能与 VPC CIDR 冲突

   # 可用区（自动推导）
   AZ_2A=us-east-2a
   AZ_2B=us-east-2b
   AZ_2C=us-east-2c
   ```

### 配置验证

```bash
# 验证配置
source scripts/setup_env.sh

# 检查 AWS 凭证
aws sts get-caller-identity

# 验证 VPC
aws ec2 describe-vpcs --vpc-ids $VPC_ID

# 验证子网
aws ec2 describe-subnets --subnet-ids $PRIVATE_SUBNET_2A $PRIVATE_SUBNET_2B $PRIVATE_SUBNET_2C
```

---

## 🚀 部署步骤

### Step 1: 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env

# 编辑配置文件，填写必需的参数
nano .env
```

**必填参数：**
- `CLUSTER_NAME`: 集群名称
- `VPC_ID`: VPC ID
- `PRIVATE_SUBNET_2A/2B/2C`: 私有子网 ID
- `PUBLIC_SUBNET_2A/2B/2C`: 公有子网 ID

### Step 2: 部署集群

```bash
./scripts/install_eks_cluster.sh
```

**部署流程：**
1. 加载和验证环境变量
2. 创建 EKS 集群（15-20分钟）
3. 部署 Cluster Autoscaler
4. 安装 AWS Load Balancer Controller
5. 迁移到 Pod Identity
6. 部署测试应用

### Step 3: 应用安全配置（可选）

部署完成后，可以应用额外的安全配置：

```bash
# 应用资源配额
kubectl apply -f manifests/cluster/resource-controls.yaml

# 应用 Pod 安全标准
kubectl apply -f manifests/cluster/pod-security.yaml

# 应用网络策略
kubectl apply -f manifests/cluster/network-policies.yaml
```

### Step 4: 验证部署

```bash
# 检查节点和标签
kubectl get nodes --show-labels

# 检查节点 Taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# 检查所有 Pod 及其调度位置
kubectl get pods -A -o wide

# 验证系统组件在 eks-utils 节点上
kubectl get pods -n kube-system -o wide | grep -E "coredns|cluster-autoscaler|aws-load-balancer"

# 检查 Cluster Autoscaler
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=20

# 检查 AWS LB Controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20
```

---

## 📊 版本信息

### 当前版本
- **Kubernetes**: 1.34（EKS 最新版本，2024年12月发布）
- **Cluster Autoscaler**: v1.34.2（匹配 K8s 版本）
- **AWS Load Balancer Controller**: v2.11.0
- **EBS CSI Driver**: v1.37.0（EKS Addon 管理）
- **EFS CSI Driver**: v2.1.15（2024年11月发布）
- **S3 CSI Driver**: v2.2.1（2024年11月发布）
- **CSI Sidecar 组件**:
  - External-Provisioner: v6.1.0
  - Node-Driver-Registrar: v2.15.0
  - Livenessprobe: v2.17.0

### 版本兼容性

| K8s 版本 | Cluster Autoscaler | AWS LB Controller | 状态 |
|---------|-------------------|-------------------|------|
| 1.34 | v1.34.x | v2.8.0+ | ✅ **最新** |
| 1.33 | v1.33.x | v2.8.0+ | ✅ 稳定 |
| 1.32 | v1.32.x | v2.8.0+ | ✅ 稳定 |
| 1.31 | v1.31.x | v2.8.0+ | ✅ 稳定 |
| 1.30 | v1.30.x | v2.8.0+ | ⚠️ 扩展支持 |

### 版本更新策略
- **季度检查**：每 3 个月检查组件更新
- **安全更新**：立即应用关键安全补丁
- **主版本升级**：在非生产环境测试后再升级

---

## 🔒 安全配置

### 网络安全
- ✅ **EKS API 纯内网访问**（`privateAccess: true, publicAccess: false`）
- ✅ **节点部署在私有子网**
- ✅ **通过 NAT Gateway 访问互联网**
- ✅ **Network Policy 隔离**

### Pod 安全
- ✅ **Pod Security Standards**（baseline/restricted）
- ✅ **非 root 用户运行**
- ✅ **只读根文件系统**
- ✅ **禁止权限提升**
- ✅ **最小化 Capabilities**

### 访问控制
- ✅ **Pod Identity for IRSA**
- ✅ **最小权限 IAM 角色**
- ✅ **RBAC 权限控制**

### 日志和审计
- ✅ **Control Plane 日志**（保留 30 天）
- ✅ **CloudWatch Logs 集成**
- ✅ **审计日志启用**

### 安全检查清单

部署后运行：
```bash
# 检查 Pod Security
kubectl auth can-i create pod --as=system:serviceaccount:default:default

# 检查 Network Policy
kubectl get networkpolicies -A

# 检查 ResourceQuota
kubectl describe resourcequota -n default

# 检查容器安全上下文
kubectl get pods -A -o json | jq '.items[].spec.containers[].securityContext'

# 检查运行为 root 的 Pod
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.containers[].securityContext.runAsUser==0) | .metadata.name'
```

---

## 💰 成本优化

### 当前成本估算（优化前 - Intel）
| 项目 | 配置 | 月度成本 (us-east-2) |
|------|------|---------------------|
| EKS 控制平面 | - | $72 |
| eks-utils 节点 | 3x m7i.large | $263 |
| app 节点 | 3x m7i.large | $263 |
| EBS 卷 | 6x 30GB gp3 | $18 |
| CloudWatch Logs | 90天保留 | $150-300 |
| NAT Gateway | 3个 | $96 |
| **总计** | | **$862-1012** |

### 优化后成本估算（当前配置 - Graviton）
| 项目 | 配置 | 月度成本 | 节省 |
|------|------|---------|------|
| EKS 控制平面 | - | $72 | - |
| eks-utils 节点 | 3x c8g.large (ARM) | $180 | **-31%** |
| app 节点 | 3x c8g.large (ARM) | $180 | **-31%** |
| EBS 卷 | 6x 30GB gp3 | $18 | - |
| CloudWatch Logs | 30天保留 | $30 | **-80%** |
| NAT Gateway | 3个 | $96 | - |
| **总计** | | **$576** | **-33% 到 -43%** |

### 进一步优化（Graviton + Spot）
| 项目 | 配置 | 月度成本 | 节省 |
|------|------|---------|------|
| EKS 控制平面 | - | $72 | - |
| eks-utils 节点 | 3x c8g.large (ARM) | $180 | **-31%** |
| app 节点 | 3x Spot c8g.large (ARM) | $54 | **-79%** |
| EBS 卷 | 5x 20GB gp3 | $10 | **-44%** |
| CloudWatch Logs | 30天保留 | $30 | **-80%** |
| NAT Gateway | 3个 | $96 | - |
| **总计** | | **$442** | **-49% 到 -56%** |

**月度节省: $286-436（33-43%）到 $420-570（49-56% with Spot）**

### 优化建议

1. **✅ 已应用：使用 Graviton (ARM) 架构**
   ```yaml
   # 当前配置使用 c8g.large (AWS Graviton3)
   instanceType: c8g.large
   # 相比 Intel m7i.large 节省 31%
   # 性能相当或更好，能耗更低
   ```

2. **进一步优化：应用节点使用 Spot 实例**
   ```yaml
   # 修改 app 节点组
   spot: true
   instanceTypes: ["c8g.large", "c7g.large", "c6g.large"]
   # 额外节省 ~70% 成本
   ```

3. **✅ 已应用：减少日志保留期**
   ```yaml
   cloudWatch:
     clusterLogging:
       logRetentionInDays: 30  # 已从 90 改为 30
   ```

4. **动态节点扩缩容**
   ```yaml
   desiredCapacity: 0  # 无负载时缩减到 0
   minSize: 0
   maxSize: 10
   ```

5. **✅ 已部署：Cluster Autoscaler**
   - 自动移除空闲节点
   - 优化资源利用率

### 成本监控

```bash
# 使用 kubectl-cost 插件
kubectl cost --window 7d

# 查看节点利用率
kubectl top nodes

# 查看 Pod 资源使用
kubectl top pods -A
```

---

## 🧪 测试验证

### 1. 测试 Cluster Autoscaler

```bash
# 部署测试负载（会调度到 app 节点组）
kubectl apply -f manifests/examples/autoscaler.yaml

# 扩容到 10 个副本，触发节点自动扩容
kubectl scale deployment autoscaler-test --replicas=10

# 观察节点自动增加（app 节点组）
kubectl get nodes -w

# 检查 Pod 调度情况（应该都在 app 节点上）
kubectl get pods -o wide

# 缩容到 0
kubectl scale deployment autoscaler-test --replicas=0

# 观察节点自动减少（约 10 分钟后）
kubectl get nodes -w
```

**注意**:
- 测试应用包含 `tolerations` 和 `nodeSelector`，确保调度到 app 节点组
- 系统组件始终在 eks-utils 节点组运行，不受测试影响

### 2. 测试 EBS CSI Driver

```bash
# 部署 EBS 测试应用
kubectl apply -f manifests/examples/ebs-app.yaml

# 验证 PVC 创建和绑定
kubectl get pvc
kubectl get pv

# 验证 Pod 运行
kubectl get pods -l app=ebs-app

# 验证数据持久化
kubectl exec -it $(kubectl get pod -l app=ebs-app -o name) -- df -h /data
```

### 3. 测试 EFS CSI Driver

```bash
# 先创建 EFS 文件系统
EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --region ${AWS_REGION} \
  --query 'FileSystemId' \
  --output text)

# 创建挂载目标（每个私有子网）
for subnet in $PRIVATE_SUBNET_2A $PRIVATE_SUBNET_2B $PRIVATE_SUBNET_2C; do
  aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $subnet \
    --security-groups <your-security-group-id>
done

# 部署 EFS CSI Driver
kubectl apply -f manifests/addons/efs-csi-driver.yaml

# 部署测试应用
export EFS_ID=$EFS_ID
envsubst < manifests/examples/efs-app.yaml | kubectl apply -f -

# 验证多 Pod 共享访问
kubectl scale deployment efs-app --replicas=3
kubectl get pods -l app=efs-app
```

### 4. 测试 S3 CSI Driver

```bash
# 创建 S3 bucket
S3_BUCKET_NAME="my-eks-test-bucket-$(date +%s)"
aws s3 mb s3://${S3_BUCKET_NAME}

# 部署 S3 CSI Driver
kubectl apply -f manifests/addons/s3-csi-driver.yaml

# 部署测试应用
export S3_BUCKET_NAME=$S3_BUCKET_NAME
envsubst < manifests/examples/s3-app.yaml | kubectl apply -f -

# 验证挂载
kubectl exec -it $(kubectl get pod -l app=s3-app -o name | head -1) -- ls -la /data
```

### 5. 测试 AWS Load Balancer Controller

```bash
# 部署 2048 游戏（自动创建 ALB）
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/examples/2048/2048_full.yaml

# 获取 ALB 地址
kubectl get ingress -n game-2048

# 等待 ALB 创建（约 3-5 分钟）
watch kubectl get ingress -n game-2048

# 访问游戏
# 复制 ADDRESS 到浏览器
```

---

## 📊 监控和日志

### 查看组件日志

```bash
# Cluster Autoscaler
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50 -f

# AWS LB Controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50 -f

# EBS CSI Controller
kubectl logs -n kube-system -l app=ebs-csi-controller --tail=50 -f

# EFS CSI Controller
kubectl logs -n kube-system -l app=efs-csi-controller --tail=50 -f

# CoreDNS
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50 -f
```

### CloudWatch Logs

```bash
# 列出日志组
aws logs describe-log-groups \
  --log-group-name-prefix /aws/eks/${CLUSTER_NAME}

# 查看 API Server 日志
aws logs tail /aws/eks/${CLUSTER_NAME}/cluster/api --follow

# 查看审计日志
aws logs tail /aws/eks/${CLUSTER_NAME}/cluster/audit --follow
```

### 资源监控

```bash
# 节点资源使用
kubectl top nodes

# Pod 资源使用
kubectl top pods -A --sort-by=memory

# 按命名空间统计
kubectl top pods -A | awk '{if(NR>1) arr[$1]+=$3} END {for (i in arr) print i, arr[i]}'
```

### 事件监控

```bash
# 查看最近事件
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# 监控事件
kubectl get events -A -w

# 查看告警事件
kubectl get events -A --field-selector type!=Normal
```

---

## 🔧 故障排查

### 常见问题

#### 1. 集群创建失败

**问题：** `eksctl create cluster` 失败

**排查步骤：**
```bash
# 检查 AWS 凭证
aws sts get-caller-identity

# 检查 VPC 和子网
aws ec2 describe-vpcs --vpc-ids $VPC_ID
aws ec2 describe-subnets --subnet-ids $PRIVATE_SUBNET_2A $PRIVATE_SUBNET_2B $PRIVATE_SUBNET_2C

# 检查 IAM 权限
aws iam get-user

# 查看 CloudFormation 错误
aws cloudformation describe-stack-events \
  --stack-name eksctl-${CLUSTER_NAME}-cluster \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]'
```

#### 2. Pod 无法调度

**问题：** Pod 一直处于 Pending 状态

**排查步骤：**
```bash
# 查看 Pod 事件
kubectl describe pod <pod-name>

# 检查节点资源
kubectl top nodes
kubectl describe nodes

# 检查 Cluster Autoscaler 日志
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50
```

#### 3. 无法访问 API Server

**问题：** `kubectl` 命令超时

**原因：** API Server 配置为纯内网访问

**解决方案：**
- 从 VPC 内部访问（EC2、VPN、Direct Connect）
- 临时启用公网访问：
  ```bash
  eksctl utils update-cluster-endpoints \
    --cluster=${CLUSTER_NAME} \
    --private-access=true \
    --public-access=true \
    --region=${AWS_REGION}
  ```

#### 4. LoadBalancer 创建失败

**问题：** Ingress 没有分配 ADDRESS

**排查步骤：**
```bash
# 检查 AWS LB Controller 日志
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100

# 检查 Ingress 事件
kubectl describe ingress <ingress-name> -n <namespace>

# 检查子网标签
aws ec2 describe-subnets --subnet-ids $PUBLIC_SUBNET_2A --query 'Subnets[].Tags'
```

**解决方案：** 确保公有子网有标签：
```
kubernetes.io/role/elb = 1
kubernetes.io/cluster/${CLUSTER_NAME} = shared
```

#### 5. EBS 卷无法挂载

**问题：** PVC 一直 Pending

**排查步骤：**
```bash
# 检查 StorageClass
kubectl get sc

# 检查 EBS CSI Driver
kubectl get pods -n kube-system -l app=ebs-csi-controller

# 检查 PVC 事件
kubectl describe pvc <pvc-name>

# 检查 EBS CSI Controller 日志
kubectl logs -n kube-system -l app=ebs-csi-controller --tail=50
```

---

## 🗑️ 清理资源

### 完整清理

```bash
# 1. 删除测试应用
kubectl delete -f manifests/examples/autoscaler.yaml
kubectl delete -f manifests/examples/ebs-app.yaml
kubectl delete -f manifests/examples/efs-app.yaml
kubectl delete -f manifests/examples/s3-app.yaml
kubectl delete namespace game-2048

# 2. 删除 Load Balancer（防止阻止集群删除）
kubectl delete ingress --all -A

# 3. 删除 PVC（释放 EBS 卷）
kubectl delete pvc --all -A

# 4. 等待 LoadBalancer 和 EBS 卷释放
sleep 60

# 5. 删除集群
eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_REGION} --wait

# 6. 清理 IAM 策略（可选）
aws iam delete-policy \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}

# 7. 删除 EFS 文件系统（如果创建了）
aws efs delete-file-system --file-system-id ${EFS_ID}

# 8. 删除 S3 bucket（如果创建了）
aws s3 rb s3://${S3_BUCKET_NAME} --force
```

### 部分清理

```bash
# 只删除测试应用
kubectl delete -f manifests/examples/

# 只删除特定节点组
eksctl delete nodegroup --cluster=${CLUSTER_NAME} --name=test --region=${AWS_REGION}

# 只卸载 Helm releases
helm uninstall aws-load-balancer-controller -n kube-system
```

---

## 📚 参考资源

### 官方文档
- [AWS EKS Documentation](https://docs.aws.amazon.com/eks/)
- [eksctl Documentation](https://eksctl.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

### 最佳实践
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [Kubernetes Production Best Practices](https://learnk8s.io/production-best-practices)
- [Cost Optimization Guide](https://www.kubecost.com/kubernetes-cost-optimization/)

### 组件版本
- [Kubernetes Releases](https://kubernetes.io/releases/)
- [Cluster Autoscaler Releases](https://github.com/kubernetes/autoscaler/releases)
- [EBS CSI Driver Releases](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/releases)
- [EFS CSI Driver Releases](https://github.com/kubernetes-sigs/aws-efs-csi-driver/releases)
- [S3 CSI Driver Releases](https://github.com/awslabs/mountpoint-s3-csi-driver/releases)

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

---

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE) 文件

---

## ✨ 致谢

本项目使用了以下开源项目：
- [eksctl](https://eksctl.io/)
- [Kubernetes](https://kubernetes.io/)
- [AWS Controllers for Kubernetes](https://aws-controllers-k8s.github.io/community/)

---

**维护者:** Platform Team
**最后更新:** 2025-12-05
**文档版本:** v2.0
