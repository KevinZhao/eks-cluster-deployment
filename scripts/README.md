# Scripts 使用指南

本目录包含用于 EKS 集群部署的自动化脚本。脚本按执行顺序编号，支持幂等性操作。

---

## 📋 脚本列表

| 脚本 | 功能 | 幂等性 | 必需 |
|------|------|--------|------|
| [0_setup_env.sh](#0_setup_envsh) | 加载环境变量 | N/A | ✅ |
| [1_enable_vpc_dns.sh](#1_enable_vpc_dnssh) | 启用 VPC DNS 设置 | ✅ | ✅ |
| [2_validate_network_environment.sh](#2_validate_network_environmentsh) | 验证网络环境 | N/A | 推荐 |
| [3_create_vpc_endpoints.sh](#3_create_vpc_endpointssh) | 创建 VPC Endpoints | ✅ | ✅ |
| [5_create_s3_csi_policy.sh](#5_create_s3_csi_policysh) | 创建 S3 CSI Driver 自定义 IAM Policy | ✅ | 可选 |
| [4_install_eks_cluster.sh](#4_install_eks_clustersh) | 部署 EKS 集群 | ⚠️ | ✅ |

---

## 🚀 快速开始

### 完整部署流程

```bash
# 1. 配置环境变量
cp ../.env.example ../.env
# 编辑 .env 文件，填入你的 VPC 和集群信息

# 2. 启用 VPC DNS 设置（VPC Endpoints 必需）
./1_enable_vpc_dns.sh

# 3. 验证网络环境（可选但推荐）
./2_validate_network_environment.sh

# 4. 创建 VPC Endpoints
./3_create_vpc_endpoints.sh

# 5. 再次验证（确保一切就绪）
./2_validate_network_environment.sh

# 6. （可选）如果需要 S3 CSI Driver，创建自定义 IAM Policy
./5_create_s3_csi_policy.sh

# 7. 部署 EKS 集群
./4_install_eks_cluster.sh
```

---

## 📖 脚本详解

### 0_setup_env.sh

**功能:** 加载和验证环境变量配置

**用法:**
```bash
# 通常不需要直接运行，其他脚本会自动调用
source scripts/0_setup_env.sh
```

**输出:**
- 配置摘要
- 环境变量验证结果

**注意事项:**
- 需要项目根目录存在 `.env` 文件
- 会验证所有必需的环境变量
- 自动获取 AWS 账户 ID（如果未设置）

---

### 1_enable_vpc_dns.sh

**功能:** 启用 VPC 的 DNS Support 和 DNS Hostnames 设置

**为什么需要:**
VPC Endpoints 需要这两个 DNS 设置才能正常工作。

**用法:**
```bash
./scripts/1_enable_vpc_dns.sh
```

**幂等性:** ✅ 支持
- 如果设置已启用，显示 "already enabled"，不重复操作
- 可以安全地多次运行

**输出示例:**
```
╔════════════════════════════════════════════════════╗
║  Enable VPC DNS Settings for EKS                   ║
╚════════════════════════════════════════════════════╝

✓ VPC vpc-0440f5a67e15d639f exists
✓ DNS Support is already enabled
✓ DNS Hostnames is already enabled

╔════════════════════════════════════════════════════╗
║  VPC DNS Settings Configuration: SUCCESS          ║
╚════════════════════════════════════════════════════╝
```

**所需权限:**
- `ec2:DescribeVpcs`
- `ec2:DescribeVpcAttribute`
- `ec2:ModifyVpcAttribute`

**执行时间:** ~2-3 秒

---

### 2_validate_network_environment.sh

**功能:** 全面验证 EKS 网络环境配置

**检查内容:**
1. 环境变量配置 (9 项)
2. VPC 配置和 DNS 设置 (3 项)
3. 子网配置 (6 项)
4. 路由表和 NAT Gateways (7 项)
5. VPC Endpoints (11 项)
6. VPC Endpoint Security Groups (1 项)

**用法:**
```bash
./scripts/2_validate_network_environment.sh
```

**输出示例:**

**成功情况:**
```
Passed Checks: 35
Warnings: 0
Failed Checks: 0

╔════════════════════════════════════════════════════╗
║  Network Environment Validation: PASSED            ║
║  You can proceed with EKS cluster deployment       ║
╚════════════════════════════════════════════════════╝
```

**失败情况:**
```
Passed Checks: 23
Warnings: 5
Failed Checks: 8

Critical Issues Found:
  ✗ DNS Support is NOT enabled
  ✗ 7 required VPC endpoints are missing

Recommendations:
  [CRITICAL] Create required VPC endpoints:
  ./scripts/3_create_vpc_endpoints.sh
```

**所需权限:**
- `ec2:DescribeVpcs`
- `ec2:DescribeVpcAttribute`
- `ec2:DescribeSubnets`
- `ec2:DescribeRouteTables`
- `ec2:DescribeVpcEndpoints`
- `ec2:DescribeSecurityGroups`
- `ec2:DescribeInternetGateways`
- `ec2:DescribeNatGateways`

**执行时间:** ~15 秒

---

### 3_create_vpc_endpoints.sh

**功能:** 创建私有 EKS 集群所需的所有 VPC Endpoints

**创建的资源:**
- **Security Group** (1个) - 允许 VPC 内的 HTTPS 流量
- **Interface Endpoints** (11个):
  - EKS API
  - EKS Auth (Pod Identity)
  - STS (IRSA)
  - ECR API
  - ECR Docker
  - CloudWatch Logs
  - EC2 (EBS CSI)
  - Auto Scaling (Cluster Autoscaler)
  - ELB (AWS Load Balancer Controller)
  - EFS (EFS CSI Driver)
  - Systems Manager
- **Gateway Endpoint** (1个):
  - S3

**用法:**
```bash
./scripts/3_create_vpc_endpoints.sh
```

**幂等性:** ✅ 支持
- 自动检查资源是否已存在
- 已存在的资源不会重复创建
- Security Group 会被重用

**输出示例:**

**首次创建:**
```
Creating security group for VPC endpoints...
Security Group ID: sg-0ad6376533f8c730a
✓ Security group created

Creating interface endpoints...
Creating EKS API endpoint (eks)... ✓ created (vpce-03d9b2ad4dcb9c0cd)
Creating EKS Auth (Pod Identity) endpoint (eks-auth)... ✓ created (vpce-09d3917f5d35e8484)
...

Creating S3 Gateway Endpoint... ✓ created (vpce-0849d17af2cb0f68c)

VPC Endpoints Creation Complete!
Monthly cost estimate: ~$80-85 for 11 interface endpoints
```

**重复运行（幂等）:**
```
Creating security group for VPC endpoints...
Security Group ID: sg-0ad6376533f8c730a
Ingress rule already exists

Creating interface endpoints...
Creating EKS API endpoint (eks)... already exists (vpce-03d9b2ad4dcb9c0cd)
Creating EKS Auth (Pod Identity) endpoint (eks-auth)... already exists (vpce-09d3917f5d35e8484)
...

Creating S3 Gateway Endpoint... already exists (vpce-0849d17af2cb0f68c)
```

**所需权限:**
- `ec2:CreateSecurityGroup`
- `ec2:DescribeSecurityGroups`
- `ec2:AuthorizeSecurityGroupIngress`
- `ec2:CreateTags`
- `ec2:CreateVpcEndpoint`
- `ec2:DescribeVpcEndpoints`
- `ec2:DescribeRouteTables`

**执行时间:**
- 首次创建: ~45 秒
- 重复运行: ~5 秒

**成本:**
- Interface Endpoints: ~$80.30/月 (11个 × $7.30/月)
- Gateway Endpoints: 免费

---

### 5_create_s3_csi_policy.sh

**功能:** 创建 S3 CSI Driver 的最小权限 IAM Policy

**为什么需要:**
默认的 `AmazonS3FullAccess` 授予 `s3:*` 权限到所有 S3 桶，这是严重的安全风险。此脚本创建符合最小权限原则的自定义 Policy。

**用法:**
```bash
./scripts/5_create_s3_csi_policy.sh
```

**交互式配置:**
脚本会提示选择 Policy 范围：
1. **特定桶（推荐）** - 仅授权指定的桶
2. **前缀匹配** - 授权所有匹配前缀的桶（如 `my-app-*`）
3. **所有桶** - 授权所有桶（不推荐，仅用于测试）

**幂等性:** ✅ 支持
- 自动检查 Policy 是否已存在
- 已存在的 Policy 不会重复创建
- 提示如何更新现有 Policy

**输出示例:**

**首次创建:**
```
╔════════════════════════════════════════════════════╗
║  Create S3 CSI Driver IAM Policy                   ║
╚════════════════════════════════════════════════════╝

AWS Account: 788668107894
Region: ap-southeast-1
Cluster: eks-singapore-cluster

ℹ Policy Name: eks-singapore-cluster-S3CSIDriverPolicy
ℹ Policy ARN: arn:aws:iam::788668107894:policy/eks-singapore-cluster-S3CSIDriverPolicy

Select policy scope:
  1) Specific bucket(s) (Recommended - Most Secure)
  2) All buckets with prefix (e.g., my-app-*)
  3) All buckets in account (Not Recommended - Use for testing only)

Enter choice [1-3] (default: 1): 1

Enter S3 bucket names (comma-separated):
Example: my-app-data,my-app-logs,my-app-backups
Bucket names: my-app-data

✓ IAM policy created successfully
✓ Policy ARN: arn:aws:iam::788668107894:policy/eks-singapore-cluster-S3CSIDriverPolicy

╔════════════════════════════════════════════════════╗
║  S3 CSI Driver Policy Creation: SUCCESS           ║
╚════════════════════════════════════════════════════╝

Next Steps:

1. Update eksctl_cluster_template.yaml to use this policy:
   attachPolicyARNs:
     - arn:aws:iam::788668107894:policy/eks-singapore-cluster-S3CSIDriverPolicy

2. Deploy or update your EKS cluster:
   ./scripts/4_install_eks_cluster.sh

3. Verify the policy is attached to the ServiceAccount:
   kubectl describe sa s3-csi-driver-sa -n kube-system
```

**重复运行（幂等）:**
```
✓ Policy already exists: arn:aws:iam::788668107894:policy/eks-singapore-cluster-S3CSIDriverPolicy

⚠ To update the policy, you need to:
  1. Create a new policy version, or
  2. Delete the existing policy and run this script again
```

**创建的 Policy 内容:**
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "MountpointListBuckets",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::my-app-data"
        },
        {
            "Sid": "MountpointObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:AbortMultipartUpload"
            ],
            "Resource": "arn:aws:s3:::my-app-data/*"
        },
        {
            "Sid": "DenyDangerousOperations",
            "Effect": "Deny",
            "Action": [
                "s3:DeleteBucket",
                "s3:DeleteBucketPolicy",
                "s3:PutBucketPolicy",
                "s3:PutBucketAcl",
                "s3:PutBucketPublicAccessBlock",
                "s3:PutLifecycleConfiguration",
                "s3:PutReplicationConfiguration",
                "s3:PutEncryptionConfiguration"
            ],
            "Resource": "*"
        }
    ]
}
```

**所需权限:**
- `iam:CreatePolicy`
- `iam:GetPolicy`
- `iam:TagPolicy`

**执行时间:** ~5 秒

**后续步骤:**
1. 在 `manifests/cluster/eksctl_cluster_template.yaml` 中取消注释 S3 CSI Driver 配置
2. 更新 `attachPolicyARNs` 为创建的自定义 Policy ARN
3. 部署或更新 EKS 集群

---

### 4_install_eks_cluster.sh

**功能:** 使用 eksctl 部署完整的 EKS 集群

**部署内容:**
- EKS 控制平面 (Kubernetes 1.34)
- 2 个节点组:
  - **eks-utils** (Intel m7i.large) - 3节点，系统组件
  - **app** (Graviton c8g.large) - 3节点，应用工作负载
- EKS Add-ons:
  - VPC CNI
  - CoreDNS
  - kube-proxy
  - EKS Pod Identity Agent
  - EBS CSI Driver
- CloudWatch Logs (30天保留)

**前置条件:**
- ✅ VPC DNS 设置已启用
- ✅ VPC Endpoints 已创建
- ✅ 网络环境验证通过

**用法:**
```bash
./scripts/4_install_eks_cluster.sh
```

**幂等性:** ⚠️ 部分支持
- eksctl 会检查集群是否已存在
- 如果集群已存在，部署会失败（这是 eksctl 的行为）
- **建议:** 只在确认集群不存在时运行

**所需权限:**
- EKS 完整权限
- EC2 完整权限
- IAM 创建角色和策略的权限
- CloudFormation 权限

**执行时间:** ~15-20 分钟

---

## ⚙️ 幂等性说明

### 什么是幂等性？

幂等性意味着脚本可以安全地多次运行，不会产生副作用或创建重复资源。

### 支持幂等性的脚本

| 脚本 | 幂等性 | 实现方式 |
|------|--------|---------|
| 1_enable_vpc_dns.sh | ✅ | 检查设置状态，已启用则跳过 |
| 3_create_vpc_endpoints.sh | ✅ | 查询现有资源，已存在则跳过创建 |
| 5_create_s3_csi_policy.sh | ✅ | 检查 IAM Policy 是否存在，已存在则跳过 |

### 幂等性示例

```bash
# 第一次运行 - 创建资源
./scripts/3_create_vpc_endpoints.sh
# 输出: ✓ created (vpce-xxx)

# 第二次运行 - 跳过已存在的资源
./scripts/3_create_vpc_endpoints.sh
# 输出: already exists (vpce-xxx)

# 结果: 只有一份资源，没有重复
```

---

## 🔍 故障排查

### 常见问题

#### 1. "VPC_ID is not set"

**原因:** 环境变量未配置

**解决:**
```bash
cp ../.env.example ../.env
# 编辑 .env 文件
vim ../.env
```

#### 2. "VPC does not exist"

**原因:** VPC ID 错误或区域不匹配

**解决:**
```bash
# 检查 VPC 是否存在
aws ec2 describe-vpcs --region ap-southeast-1

# 确认 .env 中的 VPC_ID 和 AWS_REGION
cat ../.env | grep -E "VPC_ID|AWS_REGION"
```

#### 3. "Permission denied"

**原因:** IAM 权限不足

**解决:**
- 检查 IAM 用户/角色权限
- 确保有足够的 EC2、VPC、EKS 权限

#### 4. "Endpoints creation failed"

**原因:** 可能是 DNS 设置未启用或子网配置错误

**解决:**
```bash
# 1. 确保 DNS 设置已启用
./scripts/1_enable_vpc_dns.sh

# 2. 验证网络环境
./scripts/2_validate_network_environment.sh

# 3. 检查错误信息，根据提示修复
```

---

## 📊 脚本依赖关系

```
┌─────────────────────┐
│  0_setup_env.sh     │ ← 被所有脚本依赖
└─────────────────────┘
          ↓
┌─────────────────────┐
│ 1_enable_vpc_dns.sh │ ← 独立运行
└─────────────────────┘
          ↓
┌─────────────────────────────────┐
│ 2_validate_network_environment  │ ← 独立运行（仅检查）
└─────────────────────────────────┘
          ↓
┌──────────────────────────┐
│ 3_create_vpc_endpoints   │ ← 需要 DNS 设置已启用
└──────────────────────────┘
          ↓
┌─────────────────────────────────┐
│ 2_validate_network_environment  │ ← 最终验证
└─────────────────────────────────┘
          ↓
┌─────────────────────────────┐
│ 5_create_s3_csi_policy.sh   │ ← 可选（如需 S3 CSI Driver）
└─────────────────────────────┘
          ↓
┌───────────────────────────┐
│ 4_install_eks_cluster.sh  │ ← 需要所有网络配置完成
└───────────────────────────┘
```

---

## 🎯 最佳实践

### 1. 始终先验证

```bash
# 在创建资源前验证
./scripts/2_validate_network_environment.sh

# 创建资源
./scripts/3_create_vpc_endpoints.sh

# 创建后再次验证
./scripts/2_validate_network_environment.sh
```

### 2. 保存输出日志

```bash
# 保存完整日志
./scripts/3_create_vpc_endpoints.sh 2>&1 | tee vpc-endpoints-creation.log

# 保存验证报告
./scripts/2_validate_network_environment.sh 2>&1 | tee validation-report.log
```

### 3. 分阶段执行

不要一次性运行所有脚本，建议分阶段执行并验证：

```bash
# 阶段 1: 网络准备
./scripts/1_enable_vpc_dns.sh
./scripts/2_validate_network_environment.sh

# 阶段 2: VPC Endpoints
./scripts/3_create_vpc_endpoints.sh
sleep 30  # 等待 endpoints 变为 available
./scripts/2_validate_network_environment.sh

# 阶段 3: S3 CSI Driver Policy（可选）
./scripts/5_create_s3_csi_policy.sh  # 如果需要 S3 mounting

# 阶段 4: EKS 集群（确认前面都通过）
./scripts/4_install_eks_cluster.sh
```

### 4. 测试环境先行

在生产环境部署前，先在测试环境完整运行一遍脚本。

---

## 📚 相关文档

- [VPC DNS 设置使用指南](../docs/vpc-dns-setup.md)
- [Scripts 测试报告](../docs/scripts-test-report.md)
- [VPC Endpoints 部署报告](../vpc-endpoints-deployment-report.md)
- [项目 README](../README.md)

---

## 🔄 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 1.0 | 2025-12-05 | 初始版本，支持编号脚本和幂等性 |

---

## 📞 支持

如遇到问题:
1. 检查脚本输出的错误信息
2. 查看验证脚本的详细报告
3. 参考故障排查部分
4. 查看 AWS CloudTrail 日志
5. 提交 Issue 到项目仓库

---

**维护者:** Claude Code
**最后更新:** 2025-12-05
