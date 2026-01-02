# EKS CSI Drivers 完整部署指南

## 文档概述

本文档记录了 EKS 集群上所有 AWS CSI 驱动的完整部署方法和验证结果。所有配置已通过自动化脚本测试验证。

**最后更新**: 2026-01-02
**测试集群**: gpu-cluster (us-east-2, Ohio)
**Kubernetes**: v1.34
**节点OS**: Amazon Linux 2023

---

## CSI Drivers 状态总览

| CSI Driver | 版本 | 部署方式 | 认证方式 | 状态 | 测试结果 |
|---|---|---|---|---|---|
| **EBS CSI** | Latest | EKS Addon | Pod Identity | ✅ 运行中 | ✅ 完全通过 |
| **EFS CSI** | v2.2.0 | 自定义Manifest | Pod Identity | ✅ 运行中 | ✅ 完全通过 |
| **FSx Lustre CSI** | v1.7.0 | 自定义Manifest | Pod Identity | ✅ 运行中 | ✅ 完全通过 |
| **S3 Mountpoint CSI** | v2.2.2 | 官方Kustomize | Pod Identity | ✅ 运行中 | ✅ 完全通过 |

---

## 自动化部署方法

### 使用统一安装脚本

所有 CSI Drivers 可以通过统一的安装脚本部署：

```bash
# 位置
cd /path/to/eks-cluster-deployment

# 运行安装脚本
bash scripts/option_install_csi_drivers.sh
```

### 交互式选项

脚本提供以下选项：

1. **EFS CSI Driver** - 共享文件系统
2. **FSx CSI Driver** - 高性能 Lustre/ONTAP
3. **S3 CSI Driver** - S3 对象存储挂载
4. **安装所有驱动** - 一键部署 EFS + FSx + S3
5. **退出**

### 非交互式部署

```bash
# 设置环境变量
export CLUSTER_NAME=your-cluster
export AWS_REGION=us-east-2
export INSTALL_DRIVERS=all  # 或 efs, fsx, s3

# EFS 配置
export EFS_ID=fs-xxxxxxxxx

# S3 配置 (支持 Standard S3 和 S3 Express)
export S3_BUCKET_ARNS="arn:aws:s3:::bucket1,arn:aws:s3express:region:account:bucket/bucket2--zone--x-s3"

# 运行脚本
bash scripts/option_install_csi_drivers.sh
```

---

## 1. EBS CSI Driver

### 配置概要

- **Driver版本**: Latest (AWS 管理)
- **部署方式**: EKS Managed Addon
- **认证方式**: EKS Pod Identity (自动配置)
- **状态**: ✅ 默认已安装

### StorageClass 配置

项目包含两个预配置的 StorageClass：

#### gp3 (默认)
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

#### io2 (高性能)
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: io2
provisioner: ebs.csi.aws.com
parameters:
  type: io2
  iops: "10000"
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

### 使用示例

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3  # 或 io2
  resources:
    requests:
      storage: 10Gi
```

### 验证命令

```bash
# 检查 addon 状态
aws eks describe-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-ebs-csi-driver \
  --region $AWS_REGION

# 检查 pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# 检查 StorageClass
kubectl get storageclass gp3 io2
```

---

## 2. EFS CSI Driver

### 配置概要

- **Driver版本**: v2.2.0
- **部署方式**: 自定义 Manifest
- **认证方式**: EKS Pod Identity
- **访问模式**: ReadWriteMany (RWX)

### 前置条件

1. **创建 EFS 文件系统**

```bash
# 获取子网 IDs
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=shared" \
  --query "Subnets[*].SubnetId" \
  --output text --region $AWS_REGION)

# 创建 EFS 文件系统
EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=${CLUSTER_NAME}-efs \
  --region $AWS_REGION \
  --query "FileSystemId" \
  --output text)

# 创建挂载目标
for subnet in $SUBNET_IDS; do
  aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $subnet \
    --security-groups $EFS_SECURITY_GROUP_ID \
    --region $AWS_REGION
done
```

2. **配置安全组**

确保 EFS 挂载目标安全组允许来自节点安全组的 NFS 流量 (TCP 2049)。

### 自动化部署

```bash
# 方法 1: 使用安装脚本
export EFS_ID=fs-xxxxxxxxx
bash scripts/option_install_csi_drivers.sh
# 选择选项 1 (EFS CSI Driver)

# 方法 2: 直接调用函数
source scripts/pod_identity_helpers.sh
setup_efs_csi_pod_identity
kubectl apply -f manifests/addons/efs-csi-driver.yaml
```

### 使用示例

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: efs-pv
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  csi:
    driver: efs.csi.aws.com
    volumeHandle: fs-xxxxxxxxx  # EFS File System ID
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
```

### 验证命令

```bash
# 检查 Driver pods
kubectl get pods -n kube-system -l app=efs-csi-controller
kubectl get pods -n kube-system -l app=efs-csi-node

# 检查 Pod Identity
aws eks list-pod-identity-associations \
  --cluster-name $CLUSTER_NAME \
  --region $AWS_REGION | grep efs

# 测试挂载
kubectl run -it --rm efs-test \
  --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"efs-test","image":"busybox","command":["sh"],"volumeMounts":[{"name":"efs","mountPath":"/data"}]}],"volumes":[{"name":"efs","persistentVolumeClaim":{"claimName":"efs-claim"}}]}}' \
  -- sh -c "echo test > /data/test.txt && cat /data/test.txt"
```

---

## 3. FSx for Lustre CSI Driver

### 配置概要

- **Driver版本**: v1.7.0
- **部署方式**: 自定义 Manifest
- **认证方式**: EKS Pod Identity
- **Lustre版本**: 2.15 (兼容 AL2023)
- **访问模式**: ReadWriteMany (RWX)
- **性能**: 高吞吐量 (500+ MB/s)

### 前置条件

1. **节点 Lustre 客户端**

Amazon Linux 2023 原生支持 Lustre 2.15：

```bash
# 已集成到节点启动脚本中
dnf install -y lustre-client
modprobe lustre
```

2. **创建 FSx 文件系统**

```bash
# 创建 FSx for Lustre (SCRATCH_2)
FSX_ID=$(aws fsx create-file-system \
  --file-system-type LUSTRE \
  --file-system-type-version 2.15 \
  --lustre-configuration "DeploymentType=SCRATCH_2,PerUnitStorageThroughput=200" \
  --storage-capacity 1200 \
  --subnet-ids $PRIVATE_SUBNET_ID \
  --security-group-ids $FSX_SECURITY_GROUP_ID \
  --tags Key=Name,Value=${CLUSTER_NAME}-fsx-lustre \
  --region $AWS_REGION \
  --query "FileSystem.FileSystemId" \
  --output text)
```

3. **配置安全组**

FSx Lustre 需要以下端口：
- TCP 988 (MGS - Management Server)
- TCP 1021-1023 (OSS - Object Storage Servers)

```bash
# 添加节点 SG 到 FSx SG 的入站规则
aws ec2 authorize-security-group-ingress \
  --group-id $FSX_SECURITY_GROUP_ID \
  --source-group $NODE_SECURITY_GROUP_ID \
  --protocol tcp \
  --port 988 \
  --region $AWS_REGION

aws ec2 authorize-security-group-ingress \
  --group-id $FSX_SECURITY_GROUP_ID \
  --source-group $NODE_SECURITY_GROUP_ID \
  --protocol tcp \
  --port 1021-1023 \
  --region $AWS_REGION
```

### 自动化部署

```bash
# 使用安装脚本
bash scripts/option_install_csi_drivers.sh
# 选择选项 2 (FSx CSI Driver)
```

部署自动执行：
1. 创建 IAM 角色和策略
2. 配置 Pod Identity 关联
3. 部署 Controller 和 Node DaemonSet
4. 验证安装

### 使用示例

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: fsx-pv
spec:
  capacity:
    storage: 1200Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: fsx.csi.aws.com
    volumeHandle: fs-xxxxxxxxx  # FSx File System ID
    volumeAttributes:
      dnsname: fs-xxxxxxxxx.fsx.us-east-2.amazonaws.com
      mountname: xxxxxx  # FSx Mount Name
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fsx-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 1200Gi
  volumeName: fsx-pv
```

### 性能测试

```bash
# 写入测试
kubectl exec -it <pod-name> -- dd if=/dev/zero of=/data/test.dat bs=1M count=1000 conv=fsync

# 读取测试
kubectl exec -it <pod-name> -- dd if=/data/test.dat of=/dev/null bs=1M

# 典型性能: 500-900 MB/s
```

### 验证命令

```bash
# 检查 Driver pods
kubectl get pods -n kube-system -l app=fsx-csi-controller
kubectl get pods -n kube-system -l app=fsx-csi-node

# 检查 FSx 文件系统状态
aws fsx describe-file-systems \
  --file-system-ids $FSX_ID \
  --region $AWS_REGION

# 检查节点 Lustre 客户端
kubectl debug node/<node-name> -it --image=busybox -- \
  chroot /host lsmod | grep lustre
```

### 重要说明

**版本兼容性**:
- Amazon Linux 2023 + Lustre 2.15: ✅ 完全兼容
- Amazon Linux 2023 + Lustre 2.10: ❌ 不兼容
- 必须确保 FSx 文件系统版本为 2.12 或 2.15

详细兼容性信息见: [FSx_Lustre_AL2023_Compatibility_Testing.md](FSx_Lustre_AL2023_Compatibility_Testing.md)

---

## 4. S3 Mountpoint CSI Driver

### 配置概要

- **Driver版本**: v2.2.2
- **部署方式**: 官方 Kustomize
- **认证方式**: EKS Pod Identity
- **支持类型**: Standard S3 + S3 Express One Zone
- **访问模式**: ReadWriteMany (RWX)

### 前置条件

1. **创建 S3 Bucket**

#### Standard S3
```bash
aws s3 mb s3://my-bucket --region us-east-2
```

#### S3 Express One Zone (高性能)
```bash
BUCKET_NAME="my-app-$(date +%s)--use2-az1--x-s3"
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --create-bucket-configuration '{
    "Location": {"Type": "AvailabilityZone", "Name": "use2-az1"},
    "Bucket": {"DataRedundancy": "SingleAvailabilityZone", "Type": "Directory"}
  }' \
  --region us-east-2
```

**命名格式**: `<base-name>--<zone-id>--x-s3`

### 自动化部署

```bash
# 设置 Bucket ARNs (支持多个，逗号分隔)
export S3_BUCKET_ARNS="arn:aws:s3:::standard-bucket,arn:aws:s3express:us-east-2:ACCOUNT:bucket/express-bucket--use2-az1--x-s3"

# 运行安装脚本
bash scripts/option_install_csi_drivers.sh
# 选择选项 3 (S3 CSI Driver)
```

部署自动执行：
1. 使用官方 kustomize 部署 CSI Driver
2. 创建 IAM 角色和策略 (自动识别 S3 Express)
3. 配置 Pod Identity 关联
4. 设置 ServiceAccount 注解

### IAM 权限说明

脚本自动生成包含以下权限的 IAM Policy：

**Standard S3**:
- `s3:ListBucket`
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`
- `s3:AbortMultipartUpload`

**S3 Express One Zone** (额外):
- `s3express:CreateSession` (必需)
- 对象级别权限同上

### 使用示例

#### S3 Express One Zone

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-express-pv
spec:
  capacity:
    storage: 1200Gi
  accessModes:
    - ReadWriteMany
  mountOptions:
    - allow-delete
    - allow-overwrite  # 启用写操作
    - region us-east-2
  csi:
    driver: s3.csi.aws.com
    volumeHandle: my-bucket--use2-az1--x-s3
    volumeAttributes:
      bucketName: my-bucket--use2-az1--x-s3
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-express-claim
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 1200Gi
  volumeName: s3-express-pv
```

#### Standard S3

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-pv
spec:
  capacity:
    storage: 1200Gi
  accessModes:
    - ReadWriteMany
  mountOptions:
    - allow-delete
    - allow-overwrite
    - region us-east-2
  csi:
    driver: s3.csi.aws.com
    volumeHandle: my-standard-bucket
    volumeAttributes:
      bucketName: my-standard-bucket
```

### 验证命令

```bash
# 检查 S3 CSI Driver pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver

# 检查 Mountpoint pods (动态创建)
kubectl get pods -n mount-s3

# 检查 Pod Identity
aws eks describe-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --association-id <association-id> \
  --region $AWS_REGION

# 测试读写
kubectl run -it --rm s3-test \
  --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"test","image":"busybox","command":["sh"],"volumeMounts":[{"name":"s3","mountPath":"/data"}]}],"volumes":[{"name":"s3","persistentVolumeClaim":{"claimName":"s3-express-claim"}}]}}' \
  -- sh -c "echo test-$(date +%s) > /data/test.txt && cat /data/test.txt"
```

### 重要配置

**Mount Options**:
- `allow-overwrite`: 启用文件覆写 (写操作必需)
- `allow-delete`: 允许删除文件
- `region`: 指定 bucket 区域

**架构**:
- S3 CSI Controller: 管理 Mountpoint pods 生命周期
- S3 CSI Node: DaemonSet，处理挂载请求
- Mountpoint Pods: 动态创建在 `mount-s3` 命名空间，执行实际挂载

**详细指南**: 参见 [s3-express-onezone-guide.md](s3-express-onezone-guide.md)

---

## Pod Identity 配置详解

所有 CSI Drivers 使用统一的 Pod Identity 配置流程：

### 配置组件

1. **IAM 角色**: 为每个 CSI Driver 创建专用角色
2. **IAM 策略**: 附加必要的服务权限
3. **Pod Identity 关联**: 将 IAM 角色与 ServiceAccount 关联
4. **ServiceAccount 注解**: 配置区域端点等

### 自动化函数

所有 Pod Identity 配置函数位于 `scripts/pod_identity_helpers.sh`:

```bash
# EFS
setup_efs_csi_pod_identity

# FSx
setup_fsx_csi_pod_identity

# S3
setup_s3_csi_pod_identity "$BUCKET_ARNS"
```

### 验证 Pod Identity

```bash
# 列出所有 Pod Identity 关联
aws eks list-pod-identity-associations \
  --cluster-name $CLUSTER_NAME \
  --region $AWS_REGION

# 查看特定关联详情
aws eks describe-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --association-id <id> \
  --region $AWS_REGION

# 检查 IAM 角色
aws iam list-attached-role-policies \
  --role-name ${CLUSTER_NAME}-<driver>-csi-driver-role
```

---

## 故障排查

### 常见问题

#### 1. CSI Driver Pod CrashLoopBackOff

**检查**:
```bash
kubectl logs -n kube-system <pod-name>
kubectl describe pod -n kube-system <pod-name>
```

**常见原因**:
- RBAC 权限不足
- IAM 权限缺失
- Pod Identity 未正确配置

#### 2. Pod 无法挂载卷

**检查**:
```bash
kubectl describe pod <pod-name>
kubectl get events --sort-by='.lastTimestamp'
```

**常见原因**:
- PV/PVC 配置错误
- 安全组规则缺失
- 文件系统/Bucket 不存在

#### 3. S3 CreateSession 失败

**检查 IAM Policy**:
```bash
aws iam get-policy-version \
  --policy-arn arn:aws:iam::ACCOUNT:policy/${CLUSTER_NAME}-S3CSIDriverPolicy \
  --version-id v1
```

**解决方案**:
- 确保包含 `s3express:CreateSession` 权限
- 等待权限传播 (30-60秒)
- 重启 CSI pods

#### 4. FSx Lustre 挂载失败

**检查 Lustre 客户端**:
```bash
kubectl debug node/<node-name> -it --image=busybox -- \
  chroot /host sh -c "lsmod | grep lustre && lustre --version"
```

**解决方案**:
- 确认节点已安装 Lustre 客户端
- 检查 FSx 版本与客户端版本兼容性
- 验证安全组规则 (TCP 988, 1021-1023)

### 日志查看

```bash
# CSI Controller logs
kubectl logs -n kube-system deployment/<driver>-csi-controller -c <driver>-plugin

# CSI Node logs
kubectl logs -n kube-system daemonset/<driver>-csi-node -c <driver>-plugin

# S3 Mountpoint logs
kubectl logs -n mount-s3 <mountpoint-pod-name>
```

---

## 性能对比

| 存储类型 | 访问模式 | 延迟 | 吞吐量 | IOPS | 用例 |
|---|---|---|---|---|---|
| **EBS gp3** | RWO | 低 | 125-1000 MB/s | 3000-16000 | 数据库，应用数据 |
| **EBS io2** | RWO | 极低 | 高 | 最高 256000 | 高性能数据库 |
| **EFS** | RWX | 中 | 可扩展 | 可扩展 | 共享文件，内容管理 |
| **FSx Lustre** | RWX | 低 | 500-1000+ MB/s | 极高 | HPC，ML 训练 |
| **S3 Standard** | RWX | 高 | 可扩展 | 低 | 对象存储，数据湖 |
| **S3 Express** | RWX | 极低 | 极高 | 极高 | 低延迟对象访问 |

---

## 最佳实践

### 1. 存储类型选择

- **数据库**: EBS io2 (高 IOPS) 或 gp3 (均衡性能)
- **共享文件**: EFS (通用) 或 FSx Lustre (高性能)
- **ML 训练**: FSx Lustre (大文件，高吞吐)
- **对象存储**: S3 Express (低延迟) 或 Standard (成本优化)

### 2. 安全配置

- 使用 EKS Pod Identity (优于 IRSA)
- 遵循最小权限原则
- 启用加密 (EBS, EFS, FSx 支持)
- 定期审计 IAM 权限

### 3. 性能优化

- **EBS**: 根据工作负载选择合适的 IOPS
- **EFS**: 考虑 Provisioned Throughput 模式
- **FSx**: 选择合适的吞吐量等级
- **S3 Express**: 将计算置于相同可用区

### 4. 成本优化

- **EBS**: gp3 相比 io2 成本更低
- **EFS**: 使用 Lifecycle Management
- **FSx**: SCRATCH_2 比 PERSISTENT 便宜
- **S3**: Standard 适合冷数据，Express 适合热数据

---

## 相关文档

### 项目文档
- [S3 Express One Zone 详细指南](s3-express-onezone-guide.md)
- [FSx Lustre AL2023 兼容性测试](FSx_Lustre_AL2023_Compatibility_Testing.md)

### AWS 官方文档
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [EFS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html)
- [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/)
- [S3 Express One Zone](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html)

### GitHub Repositories
- [aws-ebs-csi-driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [aws-efs-csi-driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)
- [aws-fsx-csi-driver](https://github.com/kubernetes-sigs/aws-fsx-csi-driver)
- [mountpoint-s3-csi-driver](https://github.com/awslabs/mountpoint-s3-csi-driver)

---

## 附录：完整部署脚本示例

### 一键部署所有 CSI Drivers

```bash
#!/bin/bash
set -e

# 配置变量
export CLUSTER_NAME="my-cluster"
export AWS_REGION="us-east-2"
export ACCOUNT_ID="123456789012"

# EFS 配置
export EFS_ID="fs-xxxxxxxxx"

# S3 配置 (混合 Standard 和 Express)
export S3_BUCKET_ARNS="arn:aws:s3:::my-data-bucket,arn:aws:s3express:us-east-2:${ACCOUNT_ID}:bucket/my-express--use2-az1--x-s3"

# 部署所有 CSI Drivers
export INSTALL_DRIVERS=all
bash scripts/option_install_csi_drivers.sh

# 验证部署
echo "=== Verification ==="
kubectl get pods -n kube-system | grep csi
kubectl get pods -n mount-s3

echo "✓ All CSI Drivers deployed successfully!"
```

---

## 版本历史

- **v2.0** (2026-01-02): 完整重写，基于实际部署验证
  - 更新 S3 CSI Driver 到 v2.2.2
  - 添加 S3 Express One Zone 完整支持
  - 统一 Pod Identity 配置流程
  - 添加自动化部署脚本
  - 完善故障排查指南

- **v1.0** (2026-01-02): 初始版本
  - 基础 CSI Drivers 配置
  - S3 v1.11.0 已知问题记录
