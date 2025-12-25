# EKS Deployment Scripts - Testing Fixes Summary

## 测试日期
2025-12-25

## 测试区域
eu-central-1 (Frankfurt)

## 已修复的问题

### 1. 堡垒机安全组和IAM访问配置 ✅

**问题描述**:
- 堡垒机无法访问EKS API endpoint (443端口)
- 堡垒机IAM角色没有EKS集群访问权限

**修复内容**:
- 修改文件: `scripts/create_bastion.sh`
- 添加自动配置EKS集群安全组规则允许堡垒机访问
- 添加自动创建EKS access entry并授予集群管理员权限
- 如果集群不存在会给出清晰提示

**修复位置**: [create_bastion.sh:374-434](scripts/create_bastion.sh#L374-L434)

### 2. Karpenter IAM权限不足 ✅

**问题描述**:
- Karpenter controller缺少 Instance Profile 相关IAM权限
- 导致无法创建和管理EC2 Instance Profiles

**修复内容**:
- 修改文件: `scripts/9_install_karpenter.sh`
- 在 KarpenterControllerPolicy 中添加以下权限:
  - `iam:GetInstanceProfile`
  - `iam:CreateInstanceProfile`
  - `iam:AddRoleToInstanceProfile`
  - `iam:RemoveRoleFromInstanceProfile`
  - `iam:DeleteInstanceProfile`
  - `iam:TagInstanceProfile`
  - `iam:ListInstanceProfiles`
  - `iam:ListInstanceProfileTags`

**修复位置**: [9_install_karpenter.sh:199-212](scripts/9_install_karpenter.sh#L199-L212)

### 3. kubectl访问权限前置检查 ✅

**问题描述**:
- 脚本9执行时如果没有kubectl访问权限会在后续步骤失败
- 错误信息不够清晰

**修复内容**:
- 修改文件: `scripts/9_install_karpenter.sh`
- 在安装Karpenter前添加kubectl访问验证
- 如果无法访问会给出清晰的错误提示和解决方案

**修复位置**: [9_install_karpenter.sh:31-49](scripts/9_install_karpenter.sh#L31-L49)

### 4. SQS队列配置问题 ✅

**问题描述**:
- Karpenter配置了interruptionQueue但没有创建SQS队列
- 导致持续ERROR日志: "AWS.SimpleQueueService.NonExistentQueue"

**修复内容**:
- 修改文件: `scripts/9_install_karpenter.sh`
- 移除Helm安装时的 `--set "settings.interruptionQueue=..."`
- 添加注释说明如何手动启用中断处理

**修复位置**: [9_install_karpenter.sh:356-372](scripts/9_install_karpenter.sh#L356-L372)

### 5. Karpenter v1 API配置更新 ✅

**问题描述**:
- Karpenter 1.8.3使用v1 API，但配置文件使用v1beta1
- v1 API字段要求和格式有变化

**修复内容**:
所有Karpenter manifest文件已更新:

#### EC2NodeClass
- API版本: `karpenter.k8s.aws/v1beta1` → `karpenter.k8s.aws/v1`
- 添加 `amiSelectorTerms` with name pattern (必需字段)
- 文件:
  - [manifests/karpenter/ec2nodeclass-default.yaml](manifests/karpenter/ec2nodeclass-default.yaml)
  - [manifests/karpenter/ec2nodeclass-graviton.yaml](manifests/karpenter/ec2nodeclass-graviton.yaml)

#### NodePool
- API版本: `karpenter.sh/v1beta1` → `karpenter.sh/v1`
- `nodeClassRef` 添加 `group` 和 `kind` 字段
- `disruption.expireAfter` → `disruption.consolidateAfter` + `disruption.budgets`
- `consolidationPolicy`: `WhenUnderutilized` → `WhenEmptyOrUnderutilized`
- 文件:
  - [manifests/karpenter/nodepool-default.yaml](manifests/karpenter/nodepool-default.yaml)
  - [manifests/karpenter/nodepool-graviton.yaml](manifests/karpenter/nodepool-graviton.yaml)

**详细变更**:
```yaml
# v1beta1 (旧)
apiVersion: karpenter.sh/v1beta1
spec:
  template:
    spec:
      nodeClassRef:
        name: default
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h

# v1 (新)
apiVersion: karpenter.sh/v1
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - nodes: "10%"
```

### 6. LVM配置脚本变量展开问题 ✅ (第二次修复)

**问题描述**:
- preBootstrapCommands和userData中的 `$DATA_DISK` 被eksctl/karpenter展开为空字符串
- 导致脚本中 `if [ -z "$DATA_DISK" ]` 变成 `if [ -z "" ]` 总是为真
- LVM永远不会被配置

**第一次修复尝试** (失败):
- 使用 `$$` 转义: `$DATA_DISK` → `$$DATA_DISK`
- 问题: `$$` 在不同位置表现不一致
  - 第一次出现: `$$DATA_DISK` → `$DATA_DISK` (正确)
  - 后续引用: `$$DATA_DISK` → `$` (错误，变成空字符串)
- 实际user-data中: `if [ -z "$" ]` 而不是 `if [ -z "$DATA_DISK" ]`

**第二次修复** (当前):
- 完全避免使用变量，改用内联命令替换
- 直接在需要的地方执行 `$(lsblk ...)` 命令

**影响的文件**:
- [manifests/karpenter/ec2nodeclass-default.yaml](manifests/karpenter/ec2nodeclass-default.yaml#L61-L78)
- [manifests/karpenter/ec2nodeclass-graviton.yaml](manifests/karpenter/ec2nodeclass-graviton.yaml#L59-L76)

**修复示例**:
```bash
# 第一次修复 (失败)
DATA_DISK=$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)
if [ -z "$$DATA_DISK" ]; then  # 实际变成 if [ -z "$" ]
  ...
fi
pvcreate "$$DATA_DISK"  # 实际变成 pvcreate "$"

# 第二次修复 (当前)
if [ -z "$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)" ]; then
  echo "No data disk found, skip LVM setup"
  exit 0
fi
pvcreate "$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)"
vgcreate vg_data "$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)"
```

**应用方法**:
需要从堡垒机内执行:
```bash
export CLUSTER_NAME=eks-frankfurt-test AWS_REGION=eu-central-1
envsubst < manifests/karpenter/ec2nodeclass-default.yaml | kubectl apply -f -
envsubst < manifests/karpenter/ec2nodeclass-graviton.yaml | kubectl apply -f -
```

## 测试验证状态

### 已验证 ✅
1. Karpenter成功安装到集群
2. Karpenter Pods正常运行
3. EC2NodeClass和NodePool成功创建
4. Karpenter可以创建NodeClaim
5. EC2实例被成功launch

### 待验证 ⏳
1. 应用更新的EC2NodeClass配置 (需要从堡垒机执行)
2. 删除旧的NodeClaim (i-0865b43b27e3297a5) 让Karpenter创建新节点
3. 新节点是否成功加入集群
4. LVM配置在新节点上是否正常工作
5. Pods是否能调度到Karpenter创建的节点
6. 完整的自动扩缩容流程

## 建议的后续改进

### 高优先级
1. 考虑在脚本4中也添加堡垒机IAM配置逻辑
2. 添加SQS队列创建脚本用于中断处理功能
3. 添加节点LVM配置验证脚本

### 中优先级
1. 改进错误消息和日志输出
2. 添加更多的前置条件检查
3. 创建自动化测试脚本

### 低优先级
1. 添加清理脚本（删除所有创建的资源）
2. 改进文档和使用说明
3. 添加不同场景的配置示例

## 已知限制

1. **现有节点的LVM配置**: 在修复前创建的节点LVM配置仍然是坏的，需要重建节点
2. **SQS队列**: 中断处理功能需要手动创建SQS队列和EventBridge规则
3. **区域特定**: AMI选择器使用name pattern，如果AMI命名变化可能需要更新
4. **Karpenter版本**: 配置文件针对v1.8.3优化，其他版本可能需要调整

## 回滚说明

如果需要回滚修改，可以使用git恢复：

```bash
# 回滚单个文件
git checkout HEAD~1 scripts/create_bastion.sh
git checkout HEAD~1 scripts/9_install_karpenter.sh

# 回滚所有Karpenter manifest
git checkout HEAD~1 manifests/karpenter/

# 回滚LVM配置
git checkout HEAD~1 manifests/cluster/eksctl_cluster_template.yaml
git checkout HEAD~1 manifests/cluster/eksctl_cluster_base.yaml
```

## 相关Issue和文档

- Karpenter v1 Migration Guide: https://karpenter.sh/docs/upgrading/v1-migration/
- EKS Access Entries: https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html
- Eksctl preBootstrapCommands: https://eksctl.io/usage/schema/#managedNodeGroups-preBootstrapCommands

## 维护者
- 测试执行: Claude Code
- 测试环境: Frankfurt (eu-central-1)
- 测试集群: eks-frankfurt-test
