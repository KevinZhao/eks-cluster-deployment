# EKS 集群自动化部署

使用 eksctl 自动化部署 AWS EKS 集群，包含 Cluster Autoscaler（集群自动扩缩容）、EBS CSI Driver（持久化存储）和 AWS Load Balancer Controller（负载均衡器）。

## 功能特性

- 🚀 **自动化 EKS 集群创建** - 使用 eksctl 一键部署
- 📈 **集群自动扩缩容** - 根据负载自动调整节点数量
- 💾 **EBS CSI Driver** - 支持持久化存储
- 🔀 **AWS Load Balancer Controller** - 自动管理 ALB/NLB
- 🔒 **安全配置** - 无硬编码凭证，配置与代码分离
- ✅ **自动验证** - 部署前验证 AWS 资源

## 前置要求

确保已安装以下工具：

- [AWS CLI](https://aws.amazon.com/cli/) v2.x
- [eksctl](https://eksctl.io/) v0.150+
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.30+
- [helm](https://helm.sh/) v3.x
- `envsubst` (通常包含在 `gettext` 包中)

### 安装前置工具

```bash
# macOS
brew install awscli eksctl kubectl helm gettext

# Amazon Linux 2023
sudo yum install -y aws-cli kubectl gettext
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# 安装 Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 快速开始

### 1. 配置 AWS 凭证

```bash
aws configure
```

### 2. 创建配置文件

```bash
# 复制配置模板
cp .env.example .env

# 编辑配置文件
nano .env
```

**`.env` 文件中需要填写的必需值：**

```bash
CLUSTER_NAME=your-cluster-name
VPC_ID=vpc-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_2A=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_2B=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_2C=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_2A=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_2B=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_2C=subnet-xxxxxxxxxxxxxxxxx
```

详细配置选项请参考 [CONFIGURATION.md](CONFIGURATION.md)。

### 3. 部署集群

```bash
# 添加执行权限
chmod +x *.sh

# 运行安装脚本
./install_eks_cluster.sh
```

脚本将自动完成以下步骤：
1. 加载并验证配置
2. 创建 EKS 集群和托管节点组
3. 部署 Cluster Autoscaler
4. 安装 EBS CSI Driver
5. 安装 AWS Load Balancer Controller
6. 迁移到 Pod Identity 以增强安全性
7. 部署测试应用

## 配置说明

### 使用配置文件（推荐）

本项目使用 `.env` 文件进行配置，这种方式具有以下优点：
- ✅ 敏感数据不会被提交到版本控制
- ✅ 自动检测 AWS 账户信息
- ✅ 部署前验证资源
- ✅ 支持多环境配置

完整文档请参考 [CONFIGURATION.md](CONFIGURATION.md)。

### 配置迁移助手

如果你正在从旧版本（硬编码配置）升级：

```bash
./migrate_config.sh
```

这个交互式脚本将帮助你创建 `.env` 配置文件。

## 架构说明

### 集群组件

- **控制平面**：由 AWS EKS 托管
- **节点组**：
  - `eks-utils`：系统组件专用（2-4 节点，m5.large）
  - `test`：应用工作负载（2-10 节点，m5.large）
- **网络**：跨 3 个可用区的多 AZ 部署
- **存储**：EBS CSI Driver 支持 gp3 卷
- **自动扩缩容**：基于 Pod 资源请求的 Cluster Autoscaler
- **负载均衡**：AWS Load Balancer Controller 管理 ALB/NLB

### 插件列表

| 插件 | 版本 | 用途 |
|--------|---------|---------|
| vpc-cni | latest | Pod 网络 |
| coredns | latest | DNS 解析 |
| kube-proxy | latest | 网络代理 |
| eks-pod-identity-agent | latest | IAM 认证 |
| aws-ebs-csi-driver | latest | 持久化存储 |
| cluster-autoscaler | v1.30.0 | 节点自动扩缩容 |
| aws-load-balancer-controller | v1.13.0 | Ingress/负载均衡 |

## 集群配置详情

### 节点组

**eks-utils**（系统组件）：
- 实例类型：m5.large (2 vCPU, 8GB RAM)
- 容量：2-4 节点
- 标签：`app=eks-utils`
- 用途：CoreDNS、Load Balancer Controller、Cluster Autoscaler

**test**（应用工作负载）：
- 实例类型：m5.large (2 vCPU, 8GB RAM)
- 容量：2-10 节点
- 标签：`app=test`
- 用途：应用 Pod

### 安全特性

- ✅ 使用 Pod Identity 进行服务账户认证
- ✅ 工作节点部署在私有子网
- ✅ Cluster Autoscaler 的 RBAC 权限控制
- ✅ 最小权限安全上下文
- ✅ 只读根文件系统
- ✅ 禁止权限提升
- ✅ 启用控制平面日志（保留 90 天）

## 测试

### 测试集群自动扩缩容

```bash
# 部署测试工作负载
kubectl apply -f test-autoscaler.yaml

# 扩容
kubectl scale deployment test-autoscaler --replicas=10

# 观察节点自动增加
kubectl get nodes -w

# 缩容
kubectl scale deployment test-autoscaler --replicas=0
```

### 测试 EBS CSI Driver

```bash
# 部署带持久化卷的测试应用
kubectl apply -f test-ebs-app.yaml

# 验证 PVC 已绑定
kubectl get pvc

# 验证 Pod 正在运行
kubectl get pods
```

### 测试 Load Balancer Controller

安装脚本会自动部署 2048 游戏作为测试：

```bash
# 获取 Ingress URL
kubectl get ingress -n game-2048

# 在浏览器中访问显示的 ADDRESS
```

## 监控

### 查看 Cluster Autoscaler 日志

```bash
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50 -f
```

### 查看 Load Balancer Controller 日志

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50 -f
```

### 查看 EBS CSI Driver 日志

```bash
kubectl logs -n kube-system -l app=ebs-csi-controller --tail=50 -f
```

## 清理资源

删除集群和所有相关资源：

```bash
# 先删除测试应用
kubectl delete -f test-autoscaler.yaml
kubectl delete -f test-ebs-app.yaml
kubectl delete -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/examples/2048/2048_full.yaml

# 删除集群
eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_REGION}

# 清理 IAM 策略（可选）
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}
```

## 故障排查

### 配置问题

如果遇到配置错误：

```bash
# 验证配置
./setup_env.sh

# 检查 AWS 凭证
aws sts get-caller-identity

# 验证 VPC 和子网
aws ec2 describe-vpcs --vpc-ids $VPC_ID
aws ec2 describe-subnets --subnet-ids $PRIVATE_SUBNET_2A
```

### 部署问题

```bash
# 检查集群状态
eksctl get cluster --name=${CLUSTER_NAME}

# 检查节点状态
kubectl get nodes

# 检查 Pod 状态
kubectl get pods -A

# 查看事件
kubectl get events -A --sort-by='.lastTimestamp'
```

### 常见问题

详细解决方案请参考 [CONFIGURATION.md](CONFIGURATION.md) 的故障排查部分。

## 成本估算

AWS 费用估算（us-east-2 区域）：

| 组件 | 每小时 | 每月 |
|-----------|-----------|------------|
| EKS 控制平面 | $0.10 | ~$73 |
| 4个 m5.large 节点 | $0.384 | ~$280 |
| EBS gp3 卷 (120GB) | - | ~$10 |
| 数据传输 | 变动 | ~$10-50 |
| **总计** | **~$0.50** | **~$373-413** |

> 注意：费用因使用量、区域和数据传输而异。使用 [AWS 定价计算器](https://calculator.aws/)获取精确估算。

## 安全最佳实践

- ✅ 安全存储 `.env` 文件，永远不要提交到 git
- ✅ 尽可能使用 IAM 角色而不是访问密钥
- ✅ 启用 CloudTrail 进行审计日志记录
- ✅ 定期更新 EKS 版本和插件
- ✅ 实施网络策略
- ✅ 使用 AWS Secrets Manager 管理应用密钥
- ✅ 启用 GuardDuty 进行威胁检测

## 文档

- [CONFIGURATION.md](CONFIGURATION.md) - 详细配置指南
- [.env.example](.env.example) - 配置模板
- [AWS EKS 文档](https://docs.aws.amazon.com/eks/)
- [eksctl 文档](https://eksctl.io/)

## 支持

如有问题：
1. 查看 [CONFIGURATION.md](CONFIGURATION.md) 获取配置帮助
2. 查看 CloudWatch 日志排查部署问题
3. 检查 eksctl 和 kubectl 日志

## 许可证

本项目按原样提供，用于教育和部署目的。
