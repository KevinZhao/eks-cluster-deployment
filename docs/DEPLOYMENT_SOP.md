# EKS 集群部署标准操作流程 (SOP)

- **版本**: v1.3
- **最后更新**: 2026-01-11
- **适用范围**: EKS 1.35 集群自动化部署
- **执行环境**: AWS VPC 内的堡垒机 (Bastion Host)

---

## 概述

部署生产级 EKS 集群，包括：私有 API 访问、多 AZ 高可用、LVM 存储隔离、Pod Identity 认证。

**部署架构**：
```
EKS Cluster (K8s 1.35)
├── 控制平面 (AWS 托管，私有 API Endpoint)
├── 系统节点组 (eks-utils): m7i.2xlarge × 3，50GB 根卷 + 100GB LVM 数据卷
└── 核心组件: CoreDNS, Cluster Autoscaler, ALB Controller, EBS CSI Driver
```

**总耗时**: 35-50 分钟

---

## 前置条件

### 1. VPC 网络

**使用已有 VPC**（推荐）：需要 3 个私有子网 + 3 个公有子网 + NAT Gateway

**新建 VPC**：使用 [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc)

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false  # 生产环境：每个 AZ 一个 NAT
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS 必需标签
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
```

### 2. 堡垒机

由于集群使用私有 API，**必须**从 VPC 内部执行部署。

| 项目 | 规格 |
|------|------|
| 实例类型 | t3.micro / t3.small |
| 操作系统 | Amazon Linux 2023 |
| IAM 角色 | AdministratorAccess |
| 访问方式 | Session Manager |

### 3. 工具依赖

```bash
# Amazon Linux 2023 一键安装
sudo yum update -y && sudo yum install -y git unzip tar gzip jq

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# eksctl
curl -sL "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## 部署流程

### 第一阶段：准备堡垒机

**执行位置**：VPC 外部（CloudShell / 本地终端）

```bash
# 1. 克隆项目
git clone <your-repository-url> eks-cluster-deployment
cd eks-cluster-deployment

# 2. 设置环境变量
export VPC_ID=vpc-xxxxx
export PRIVATE_SUBNET_A=subnet-xxxxx
export AWS_REGION=eu-central-1
export CLUSTER_NAME=eks-demo-1

# 3. 创建堡垒机
REUSE_BASTION=no ./scripts/option_create_bastion.sh

# 4. 连接到堡垒机
INSTANCE_ID=$(cat /tmp/eks-bastion-instance-id.txt)
aws ssm start-session --target $INSTANCE_ID --region ${AWS_REGION}
```

**在堡垒机上**：

```bash
# 安装工具（参考上面的一键安装命令）

# 克隆项目并配置
cd ~ && git clone <your-repository-url> eks-cluster-deployment
cd eks-cluster-deployment
cp .env.example .env
vim .env  # 填写必填配置

# 验证配置
chmod +x scripts/*.sh
source scripts/0_setup_env.sh
```

**.env 必填配置**：
```bash
CLUSTER_NAME=eks-demo-1
VPC_ID=vpc-xxxxxxxxx
PRIVATE_SUBNET_A/B/C=subnet-xxx  # 3 个私有子网
PUBLIC_SUBNET_A/B/C=subnet-xxx   # 3 个公有子网
AWS_REGION=eu-central-1
```

**.env 可选配置（SSH 访问）**：

| 配置项 | 适用范围 | 说明 |
|--------|----------|------|
| `EC2_KEY_NAME` | 系统节点组 + GPU 节点组 | EC2 密钥对名称（区分大小写） |
| `SSH_PUBLIC_KEY` | Karpenter 节点 | SSH 公钥内容（通过 userData 注入） |

```bash
# 系统节点组 + GPU 节点组 SSH 访问（使用 EC2 密钥对）
# 注意：密钥名称区分大小写，必须与 AWS 控制台中显示的名称完全一致
EC2_KEY_NAME=my-eks-key

# Karpenter 节点 SSH 访问（使用公钥内容）
# 获取公钥：cat ~/.ssh/id_rsa.pub
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... user@host"
```

> **说明**：如不配置上述选项，所有节点默认通过 SSM Session Manager 访问。

### 第二阶段：配置 VPC 网络

**执行位置**：堡垒机

```bash
./scripts/1_enable_vpc_dns.sh        # 启用 DNS（10秒）
./scripts/2_validate_network_environment.sh  # 可选：验证网络
./scripts/3_create_vpc_endpoints.sh  # 创建 13 个 Endpoints（2-3分钟）
```

### 第三阶段：创建 EKS 集群

```bash
./scripts/4_install_eks_cluster.sh   # 创建控制平面（8-10分钟）
```

验证：
```bash
aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.status'
# 应返回: "ACTIVE"
```

### 第四阶段：创建系统节点组

```bash
AUTO_DELETE_NODEGROUP=yes ./scripts/6_create_system_nodegroup.sh  # 8-12分钟
```

验证：
```bash
kubectl get nodes -o wide  # 应显示 3 个 Ready 节点
```

### 第五阶段：安装集群组件

```bash
./scripts/7_install_eks_addon.sh     # 5-8分钟
```

验证：
```bash
kubectl get pods -A  # 所有 Pod 应为 Running
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}
```

---

## 验证和测试

### 集群状态

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes
```

### 测试自动扩缩容

```bash
# 部署测试应用
kubectl create deployment autoscaler-test --image=nginx:alpine --replicas=1
kubectl set resources deployment autoscaler-test --requests=cpu=1000m,memory=1Gi

# 扩容触发自动扩容
kubectl scale deployment autoscaler-test --replicas=10
watch kubectl get nodes

# 清理
kubectl delete deployment autoscaler-test
```

### 测试 Load Balancer

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/examples/2048/2048_full.yaml
kubectl get ingress -n game-2048 -w
kubectl delete namespace game-2048
```

### 测试存储

**EBS**：
```bash
kubectl apply -f examples/ebs-test.yaml
kubectl get pvc
kubectl delete -f examples/ebs-test.yaml
```

**EFS**（需先安装驱动）：
```bash
INSTALL_DRIVERS=efs ./scripts/option_install_csi_drivers.sh
export EFS_ID=fs-xxx
# 参考 examples/ 目录下的测试文件
```

**FSx Lustre**（GPU 场景）：
```bash
INSTALL_DRIVERS=fsx ./scripts/option_install_csi_drivers.sh
export FSX_ID=fs-xxx
export FSX_DNS=$(aws fsx describe-file-systems --file-system-ids ${FSX_ID} --region ${AWS_REGION} --query 'FileSystems[0].DNSName' --output text)
export FSX_MOUNT_NAME=$(aws fsx describe-file-systems --file-system-ids ${FSX_ID} --region ${AWS_REGION} --query 'FileSystems[0].LustreConfiguration.MountName' --output text)
envsubst < examples/fsx-app.yaml | kubectl apply -f -
```

**S3**：
```bash
INSTALL_DRIVERS=s3 S3_BUCKET_ARNS='arn:aws:s3:::my-bucket' ./scripts/option_install_csi_drivers.sh
# 参考 examples/ 目录下的测试文件
```

---

## 可选组件

```bash
# Karpenter（更灵活的自动扩缩容）
./scripts/option_install_karpenter.sh

# GPU 节点组
./scripts/option_install_gpu_nodegroups.sh

# 测试脚本
./examples/option_test_pod_scheduling.sh
./examples/option_test_karpenter_pools.sh
```

---

## 常见问题

### kubectl 无法连接

```bash
# 症状: The connection to the server localhost:8080 was refused
export KUBECONFIG="${HOME}/.kube/config"
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
```

### kubectl 超时

```bash
# 症状: dial tcp 10.0.x.x:443: i/o timeout
# 原因: 安全组或 VPC Endpoints 问题
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" --region ${AWS_REGION}
./scripts/6_create_system_nodegroup.sh  # 会自动配置安全组
```

### 节点 NotReady

```bash
kubectl describe node <node-name>
kubectl debug node/<node-name> -it --image=amazonlinux -- chroot /host journalctl -u kubelet -n 100

# 如果配置了 EC2_KEY_NAME，也可通过 SSH 访问
ssh -i ~/.ssh/my-key.pem ec2-user@<node-private-ip>
```

### Pod Identity 认证失败

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=eks-pod-identity-agent
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}
```

---

## 堡垒机管理

```bash
# 停止（节省成本）
aws ec2 stop-instances --instance-ids $INSTANCE_ID --region ${AWS_REGION}

# 启动
aws ec2 start-instances --instance-ids $INSTANCE_ID --region ${AWS_REGION}
```

---

## 参考文档

- [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc)
- [AWS EKS 官方文档](https://docs.aws.amazon.com/eks/)
- [eksctl 文档](https://eksctl.io/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

---

| 版本 | 日期 | 变更内容 |
|------|------|----------|
| v1.0 | 2025-12-29 | 初始版本 |
| v1.1 | 2026-01-10 | 修复脚本编号引用；简化 FSx 测试步骤 |
| v1.2 | 2026-01-11 | 合并 VPC_SETUP.md；大幅简化文档 |
| v1.3 | 2026-01-11 | 添加 SSH 密钥配置：系统/GPU 节点组 (EC2_KEY_NAME) 和 Karpenter 节点 (SSH_PUBLIC_KEY) |
