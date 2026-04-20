# EKS 集群自动化部署

生产级 AWS EKS 集群自动化部署方案，支持私有 API 访问、LVM 存储配置、Pod Identity 认证。

[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)

---

## 🚀 快速开始

### 前置要求

- ✅ 已有 VPC（包含公有/私有子网、NAT Gateway）
- ✅ 堡垒机（VPC 内部，用于执行部署脚本）
- ✅ 安装工具：kubectl, eksctl, helm, aws-cli, jq

> ⚠️ **重要**：集群使用私有 API 访问模式，必须从 VPC 内部执行部署。详见 [docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md)

### 5 分钟快速部署

```bash
# 1. 配置环境变量
cp .env.example .env
nano .env  # 填写 VPC_ID、子网 ID 等

# 2. 执行部署（在堡垒机上）
chmod +x scripts/*.sh

# 配置 VPC 网络
./scripts/1_enable_vpc_dns.sh           # 启用 DNS
./scripts/3_create_vpc_endpoints.sh     # 创建 VPC Endpoints

# 部署 EKS 集群
./scripts/4_install_eks_cluster.sh      # 创建控制平面（8-10分钟）
./scripts/6_create_system_nodegroup.sh  # 创建系统节点组（8-12分钟）
./scripts/7_install_eks_addon.sh        # 安装核心组件（5-8分钟）

# 3. 验证
kubectl get nodes
kubectl get pods -A
```

**总耗时**：约 25-35 分钟

---

## 🏗️ 架构特性

### 核心功能

- ✅ **私有 API 访问** - 高安全性，API Server 不暴露公网
- ✅ **多 AZ 高可用** - 跨 3 个可用区部署
- ✅ **LVM 存储配置** - 系统节点自动配置 100GB LVM 数据卷
- ✅ **Pod Identity** - 使用 EKS Pod Identity 替代 IRSA
- ✅ **自动扩缩容** - Cluster Autoscaler 自动管理节点
- ✅ **完整 CSI 支持** - EBS/EFS/FSx/S3 存储驱动
- ✅ **GPU 节点支持** - P5/P5en/P6/G7e 实例 + EFA 多网卡 + `vpc.amazonaws.com/efa` 设备插件

### 集群架构

```
EKS Cluster (Kubernetes 1.35)
├── Control Plane (AWS 托管)
│   └── 私有 API Endpoint (10.0.x.x)
│
├── 系统节点组 (eks-utils)
│   ├── 实例: 3x m7i.2xlarge (Intel)
│   ├── 存储: 50GB 根卷 + 100GB LVM 数据卷
│   ├── 标签: app=eks-utils
│   └── 运行: CoreDNS, Cluster Autoscaler, LB Controller, CSI Drivers
│
└── 网络
    ├── VPC CNI (v1.18.5)
    ├── 私有子网 (3个 AZ)
    └── VPC Endpoints (13个)
```

---

## 📦 已集成组件

| 组件 | 版本 | 用途 |
|------|------|------|
| Kubernetes | 1.35 | 容器编排 |
| VPC CNI | v1.18.5 | Pod 网络 |
| CoreDNS | v1.11.3 | DNS 解析 |
| Pod Identity Agent | v1.3.4 | IAM 认证 |
| EBS CSI Driver | v1.37.0 | 块存储 |
| Cluster Autoscaler | v1.35.0 | 自动扩缩容 |
| AWS LB Controller | v1.13.0 | 负载均衡 |
| Metrics Server | v0.7.2 | 资源指标 |

---

## 📋 部署流程

完整部署流程请参考 **[docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md)**，包括：

1. **准备堡垒机** - 创建和配置 VPC 内部跳板机
2. **配置 VPC 网络** - 启用 DNS、创建 VPC Endpoints
3. **创建 EKS 集群** - 部署控制平面
4. **创建系统节点组** - 配置 LVM 存储
5. **安装集群组件** - 部署 Autoscaler、LB Controller、CSI Drivers
6. **验证和测试** - 功能验证

### 脚本说明

**核心部署脚本（按顺序执行）**：

| 脚本 | 用途 | 执行位置 | 耗时 |
|------|------|---------|------|
| `0_setup_env.sh` | 加载环境变量 | 任意 | <1分钟 |
| `1_enable_vpc_dns.sh` | 启用 VPC DNS | 任意 | <1分钟 |
| `2_validate_network_environment.sh` | 验证网络配置（可选） | 任意 | <1分钟 |
| `3_create_vpc_endpoints.sh` | 创建 VPC Endpoints | 任意 | 2-3分钟 |
| `5_check_environment.sh` | 检查本地环境（可选） | 任意 | <1分钟 |
| `4_install_eks_cluster.sh` | 创建集群控制平面 | VPC 内 | 8-10分钟 |
| `6_create_system_nodegroup.sh` | 创建系统节点组（LVM） | VPC 内 | 8-12分钟 |
| `7_install_eks_addon.sh` | 安装核心组件 | VPC 内 | 5-8分钟 |

**可选功能脚本**：

| 脚本 | 用途 | 执行位置 |
|------|------|---------|
| `option_create_bastion.sh` | 创建堡垒机 | VPC 外 |
| `option_install_csi_drivers.sh` | 安装 EFS/FSx/S3 CSI Driver | VPC 内 |
| `option_install_karpenter.sh` | 安装 Karpenter 自动扩缩容 | VPC 内 |
| `examples/option_test_pod_scheduling.sh` | 测试 Pod 调度到系统节点 | VPC 内 |
| `examples/option_test_karpenter_pools.sh` | 测试 Karpenter 节点池 | VPC 内 |

---

## 🎯 非交互模式（自动化）

所有脚本支持非交互模式，通过环境变量控制：

```bash
# 创建堡垒机
REUSE_BASTION=no ./scripts/option_create_bastion.sh

# 创建节点组（自动删除旧节点组）
AUTO_DELETE_NODEGROUP=yes ./scripts/6_create_system_nodegroup.sh

# 安装 CSI 驱动
INSTALL_DRIVERS=efs ./scripts/option_install_csi_drivers.sh
INSTALL_DRIVERS=s3 S3_BUCKET_ARNS='arn:aws:s3:::my-bucket' ./scripts/option_install_csi_drivers.sh

# 测试脚本
AUTO_RESTART_KARPENTER=yes ./examples/option_test_pod_scheduling.sh
AUTO_CLEANUP_TEST=yes ./examples/option_test_karpenter_pools.sh
```

---

## ✅ 快速验证

```bash
# 1. 查看集群状态
kubectl get nodes -o wide
kubectl get pods -A

# 2. 测试 EBS CSI Driver
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi
EOF

kubectl get pvc test-pvc  # 应为 Bound 状态
kubectl delete pvc test-pvc

# 3. 测试 Load Balancer Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.0/docs/examples/2048/2048_full.yaml
kubectl get ingress -n game-2048 -w  # 等待 ALB 创建
kubectl delete namespace game-2048
```

---

## 🔧 故障排查

### 问题 1: kubectl 无法连接集群

**错误**: `dial tcp 10.0.x.x:443: i/o timeout`

**原因**: 集群使用私有 API，必须从 VPC 内部访问

**解决**: 使用堡垒机执行，参考 [DEPLOYMENT_SOP.md - 第一阶段](DEPLOYMENT_SOP.md#第一阶段准备堡垒机)

### 问题 2: Session Manager 无法连接堡垒机

**原因**: VPC 缺少 SSM 相关的 VPC Endpoints

**解决**: 先运行 `./scripts/3_create_vpc_endpoints.sh` 创建端点

### 问题 3: 节点无法加入集群

**排查**:
```bash
# 1. 查看节点状态
kubectl describe node <node-name>

# 2. 检查安全组
aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.resourcesVpcConfig.securityGroupIds'

# 3. 查看节点日志（通过 SSM）
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${CLUSTER_NAME}-eks-utils-node" --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target $INSTANCE_ID
sudo journalctl -u kubelet -f
```

更多故障排查请参考 [DEPLOYMENT_SOP.md - 常见问题排查](DEPLOYMENT_SOP.md#常见问题排查)

---

## 🗑️ 清理资源

```bash
# 1. 删除测试资源
kubectl delete deployment,ingress,pvc --all -A

# 2. 等待 Load Balancer 删除
sleep 60

# 3. 删除集群
eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_REGION} --wait

# 4. 删除堡垒机（如果不再需要）
aws ec2 terminate-instances --instance-ids $(cat /tmp/eks-bastion-instance-id.txt)
```

---

## 📚 文档

- **[docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md)** - 完整部署标准操作流程（必读）
- **[docs/DESIGN.md](docs/DESIGN.md)** - 架构设计和技术决策说明
- **[docs/](docs/)** - CSI Drivers 部署指南、测试报告、S3 Express 指南

### 外部参考

- [AWS EKS 官方文档](https://docs.aws.amazon.com/eks/)
- [eksctl 文档](https://eksctl.io/)
- [Kubernetes 文档](https://kubernetes.io/docs/)
- [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

---

## 📊 项目结构

```
eks-cluster-deployment/
├── README.md                          # 本文档（快速入门）
├── .env.example                       # 环境变量模板
│
├── scripts/
│   ├── 0_setup_env.sh                 # 环境变量加载
│   ├── 1_enable_vpc_dns.sh            # 启用 VPC DNS
│   ├── 2_validate_network_environment.sh  # 验证网络配置
│   ├── 3_create_vpc_endpoints.sh      # 创建 VPC Endpoints
│   ├── 5_check_environment.sh         # 检查本地环境
│   ├── 4_install_eks_cluster.sh       # 创建集群控制平面
│   ├── 6_create_system_nodegroup.sh   # 创建系统节点组（LVM）
│   ├── 7_install_eks_addon.sh         # 安装核心组件
│   ├── option_create_bastion.sh       # 创建堡垒机（可选）
│   ├── option_install_csi_drivers.sh  # 安装 EFS/FSx/S3 CSI（可选）
│   ├── option_install_karpenter.sh    # 安装 Karpenter（可选）
│   └── pod_identity_helpers.sh        # Pod Identity 辅助函数
│
├── examples/
│   ├── option_test_pod_scheduling.sh  # 测试 Pod 调度
│   └── option_test_karpenter_pools.sh # 测试 Karpenter 节点池
│
├── manifests/
│   ├── addons/
│   │   ├── cluster-autoscaler-rbac.yaml   # Cluster Autoscaler RBAC
│   │   └── cluster-autoscaler.yaml        # Cluster Autoscaler 部署
│   │   # Note: EFS/FSx/S3 CSI drivers installed as EKS managed addons
│
└── docs/                                  # 详细文档
    ├── DEPLOYMENT_SOP.md                  # 完整部署流程
    ├── DESIGN.md                          # 架构设计
    ├── VPC_SETUP.md                       # VPC 创建指南
    └── COLLABORATION.md                   # 协作指南
```

> **Note**: VPC 创建请参考 [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc)，详见 [docs/VPC_SETUP.md](docs/VPC_SETUP.md)

---

## 📝 更新日志

### v2.0 (2025-12-29)
- ✅ 重构部署流程，分离控制平面和节点组创建
- ✅ 系统节点组自动配置 LVM（m7i.2xlarge + 100GB 数据卷）
- ✅ 所有脚本支持非交互模式（自动化友好）
- ✅ 统一使用 Pod Identity 认证（替代 IRSA）
- ✅ 简化 README，详细流程移至 DEPLOYMENT_SOP.md
- ✅ 删除冗余文件，优化文档结构

### v1.0 (2025-12-05)
- ✅ 初始版本
- ✅ 混合架构（Intel 系统节点）
- ✅ Cluster Autoscaler + AWS Load Balancer Controller
- ✅ EBS/EFS/S3 CSI Driver 支持

---

**维护者**: Platform Team
**最后更新**: 2026-01-03
**文档版本**: v2.1
**完整部署流程**: [docs/DEPLOYMENT_SOP.md](docs/DEPLOYMENT_SOP.md)
