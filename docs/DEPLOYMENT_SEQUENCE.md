# EKS 集群部署顺序

本文档说明完整的 EKS 集群部署流程和脚本执行顺序。

## 部署流程

### 阶段 1：准备工作

#### 1.0 环境配置
**脚本**：[scripts/0_setup_env.sh](../scripts/0_setup_env.sh)

- 加载 `.env` 文件配置
- 验证必需的环境变量
- 设置 AWS 区域和账户 ID

**自动执行**：其他脚本会自动调用此脚本

---

### 阶段 2：VPC 和网络配置

#### 2.1 启用 VPC DNS
**脚本**：[scripts/1_enable_vpc_dns.sh](../scripts/1_enable_vpc_dns.sh)

- 启用 VPC DNS 解析
- 启用 VPC DNS 主机名

#### 2.2 验证网络环境
**脚本**：[scripts/2_validate_network_environment.sh](../scripts/2_validate_network_environment.sh)

- 验证 VPC、子网配置
- 检查路由表
- 验证安全组

#### 2.3 创建 VPC Endpoints
**脚本**：[scripts/3_create_vpc_endpoints.sh](../scripts/3_create_vpc_endpoints.sh)

- 创建必需的 VPC Endpoints（ec2, ecr, s3, etc.）
- 用于私有集群访问 AWS 服务

---

### 阶段 3：EKS 集群创建

#### 3.1 创建 EKS 集群
**脚本**：[scripts/4_install_eks_cluster.sh](../scripts/4_install_eks_cluster.sh)

- 使用 eksctl 创建 EKS 控制平面
- 创建初始的系统节点组（AMD64 或 ARM64）
- 配置集群访问权限

**或者**使用自定义节点组：
**脚本**：[scripts/6_install_eks_with_custom_nodegroup.sh](../scripts/6_install_eks_with_custom_nodegroup.sh)

- 创建集群 + app 节点组（使用 Launch Template）

#### 3.2 安装核心插件
**脚本**：[scripts/5_install_eks_addon.sh](../scripts/5_install_eks_addon.sh)

- 安装/更新 EKS 插件：
  - vpc-cni
  - kube-proxy
  - coredns
  - aws-ebs-csi-driver
  - eks-pod-identity-agent

---

### 阶段 4：系统节点组优化（可选）

#### 4.1 替换为 Graviton + LVM 节点组
**脚本**：[scripts/9_replace_system_nodegroup.sh](../scripts/9_replace_system_nodegroup.sh)

**用途**：
- 将 AMD64 节点组替换为 Graviton (ARM64)
- 配置 LVM 用于 containerd 存储
- 使用外部 Launch Template（最稳定方案）

**执行时机**：
- 集群创建后，Karpenter 安装前
- 或者任何需要优化系统节点组的时候

**详细文档**：[NODEGROUP_WITH_LVM.md](NODEGROUP_WITH_LVM.md)

---

### 阶段 5：Karpenter 安装（可选）

#### 5.1 安装 Karpenter
**脚本**：[scripts/10_install_karpenter.sh](../scripts/10_install_karpenter.sh)

- 创建 Karpenter IAM 角色和策略
- 安装 Karpenter Helm Chart
- 部署 EC2NodeClass 和 NodePool
- 配置 Graviton 专用节点池

**前置条件**：
- 系统节点组必须正常运行
- 推荐先执行脚本 9 替换为 Graviton 节点组

---

### 阶段 6：可选 CSI 驱动

#### 6.1 安装 EFS/FSx CSI 驱动
**脚本**：[scripts/7_install_optional_csi_drivers.sh](../scripts/7_install_optional_csi_drivers.sh)

- aws-efs-csi-driver
- aws-fsx-csi-driver

#### 6.2 安装 S3 CSI 驱动
**脚本**：[scripts/8_install_s3_csi_driver.sh](../scripts/8_install_s3_csi_driver.sh)

- mountpoint-s3-csi-driver

---

### 阶段 7：工具脚本

#### Bastion 管理
- **创建**：[scripts/create_bastion.sh](../scripts/create_bastion.sh)
- **删除**：[scripts/delete_bastion.sh](../scripts/delete_bastion.sh)

#### 其他工具
- **禁用公网访问**：[scripts/disable_public_access.sh](../scripts/disable_public_access.sh)
- **Pod Identity 助手**：[scripts/pod_identity_helpers.sh](../scripts/pod_identity_helpers.sh)
- **示例应用部署**：[scripts/deploy_spider_example.sh](../scripts/deploy_spider_example.sh)

---

## 推荐部署顺序

### 标准部署（无 Karpenter）

```bash
# 1. 准备
./scripts/1_enable_vpc_dns.sh
./scripts/2_validate_network_environment.sh
./scripts/3_create_vpc_endpoints.sh

# 2. 创建集群
./scripts/4_install_eks_cluster.sh
./scripts/5_install_eks_addon.sh

# 3. 优化系统节点组（推荐）
./scripts/9_replace_system_nodegroup.sh

# 4. 可选：安装额外的 CSI 驱动
./scripts/7_install_optional_csi_drivers.sh
./scripts/8_install_s3_csi_driver.sh
```

### 带 Karpenter 的部署

```bash
# 1-2. 同上
./scripts/1_enable_vpc_dns.sh
./scripts/2_validate_network_environment.sh
./scripts/3_create_vpc_endpoints.sh
./scripts/4_install_eks_cluster.sh
./scripts/5_install_eks_addon.sh

# 3. 优化系统节点组（推荐，Karpenter 将运行在这些节点上）
./scripts/9_replace_system_nodegroup.sh

# 4. 安装 Karpenter
./scripts/10_install_karpenter.sh

# 5. 可选：安装额外的 CSI 驱动
./scripts/7_install_optional_csi_drivers.sh
./scripts/8_install_s3_csi_driver.sh
```

### 使用自定义节点组的部署

```bash
# 1. 准备
./scripts/1_enable_vpc_dns.sh
./scripts/2_validate_network_environment.sh
./scripts/3_create_vpc_endpoints.sh

# 2. 创建集群（包含自定义 app 节点组）
./scripts/6_install_eks_with_custom_nodegroup.sh

# 3. 优化系统节点组
./scripts/9_replace_system_nodegroup.sh

# 4. 安装 Karpenter
./scripts/10_install_karpenter.sh
```

---

## 关键决策点

### Q1: 是否需要替换系统节点组？

**建议替换（脚本 9）如果**：
- ✅ 想要使用 Graviton (ARM64) 降低成本
- ✅ 需要 LVM 隔离 containerd 存储
- ✅ 希望与 Karpenter 节点保持一致的配置

**可以保持原样如果**：
- 只是测试环境
- 不关心成本优化
- 不需要 LVM 隔离

### Q2: 何时安装 Karpenter？

**推荐在系统节点组优化之后**：
- Karpenter 本身会运行在系统节点组上
- 先优化系统节点组可以确保 Karpenter 运行在稳定的 ARM64 + LVM 节点上

### Q3: 脚本执行失败怎么办？

**每个脚本都是幂等的**：
- 可以安全地重复执行
- 会检查资源是否已存在
- 失败后可以继续从失败的脚本开始

---

## 故障排查

### 集群创建失败
- 检查 VPC 和子网配置
- 验证 IAM 权限
- 查看 CloudFormation 堆栈错误

### 节点无法加入集群
- 检查安全组配置
- 验证子网路由表
- 查看节点日志：`/var/log/cloud-init-output.log`

### Karpenter 无法调度
- 确保系统节点组正常运行
- 检查 EC2NodeClass 和 NodePool 配置
- 查看 Karpenter 日志：`kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter`

---

## 参考文档

- [系统节点组 LVM 配置](NODEGROUP_WITH_LVM.md)
- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter Documentation](https://karpenter.sh/)
