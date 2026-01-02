# S3 Express One Zone 部署和使用指南

## 概述

S3 Express One Zone 是 AWS S3 的高性能存储类，为单可用区提供个位数毫秒级访问延迟和高吞吐量。本指南介绍如何在 EKS 集群中使用 S3 Mountpoint CSI Driver 挂载 S3 Express One Zone directory buckets。

### 性能特点
- **低延迟**: 个位数毫秒级访问延迟
- **高吞吐量**: 适合数据密集型工作负载
- **成本优化**: 针对频繁访问的数据优化成本
- **单可用区**: 数据存储在单个可用区，降低延迟

## 前置条件

### 1. 已部署的组件
- EKS 集群 (v1.23+)
- S3 Mountpoint CSI Driver v2.2.2+
- EKS Pod Identity 已启用
- kubectl 配置正确

### 2. 权限要求
- 创建 S3 Express buckets 的权限
- 管理 IAM policies 和 roles 的权限
- EKS 集群管理权限

## 步骤一：部署 S3 Mountpoint CSI Driver

### 1.1 使用自动化脚本部署

```bash
# 设置环境变量
export CLUSTER_NAME=your-cluster-name
export AWS_REGION=us-east-2
export S3_BUCKET_ARNS="arn:aws:s3express:us-east-2:YOUR-ACCOUNT-ID:bucket/your-bucket--zone-id--x-s3"

# 运行安装脚本
bash scripts/option_install_csi_drivers.sh

# 选择选项 3 (S3 CSI Driver) 或选项 4 (安装所有驱动)
```

### 1.2 手动部署 (可选)

```bash
# 部署官方 S3 Mountpoint CSI Driver
kubectl apply -k "github.com/awslabs/mountpoint-s3-csi-driver/deploy/kubernetes/overlays/stable/?ref=v2.2.2"

# 验证部署
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
kubectl get pods -n mount-s3
```

### 1.3 配置 Pod Identity

Pod Identity 配置由安装脚本自动完成，包括：
- 创建 IAM 角色
- 创建 IAM 策略 (包含 S3 Express 权限)
- 创建 Pod Identity 关联
- 配置 ServiceAccount 注解

## 步骤二：创建 S3 Express One Zone Bucket

### 2.1 创建 Directory Bucket

```bash
# 设置变量
TIMESTAMP=$(date +%s)
BUCKET_NAME="your-app-${TIMESTAMP}--use2-az1--x-s3"
AWS_REGION="us-east-2"
ACCOUNT_ID="YOUR-ACCOUNT-ID"

# 创建 S3 Express One Zone bucket
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --create-bucket-configuration '{
    "Location": {
      "Type": "AvailabilityZone",
      "Name": "use2-az1"
    },
    "Bucket": {
      "DataRedundancy": "SingleAvailabilityZone",
      "Type": "Directory"
    }
  }' \
  --region "$AWS_REGION"

# 记录 Bucket ARN
BUCKET_ARN="arn:aws:s3express:${AWS_REGION}:${ACCOUNT_ID}:bucket/${BUCKET_NAME}"
echo "Bucket ARN: $BUCKET_ARN"
```

### 2.2 Bucket 命名规范

S3 Express One Zone bucket 名称必须遵循以下格式：
```
<bucket-base-name>--<zone-id>--x-s3
```

示例：
- `my-app-data--use2-az1--x-s3` (Ohio, AZ 1)
- `ml-training--usw2-az2--x-s3` (Oregon, AZ 2)

**可用区 ID 示例**：
- us-east-2: `use2-az1`, `use2-az2`, `use2-az3`
- us-west-2: `usw2-az1`, `usw2-az2`, `usw2-az3`, `usw2-az4`
- 其他区域请查阅 AWS 文档

## 步骤三：配置 IAM 权限

### 3.1 创建 IAM Policy

创建包含 S3 Express 权限的 IAM policy：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ExpressCreateSession",
      "Effect": "Allow",
      "Action": ["s3express:CreateSession"],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/your-bucket--zone-id--x-s3"
      ]
    },
    {
      "Sid": "S3ExpressListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/your-bucket--zone-id--x-s3"
      ]
    },
    {
      "Sid": "S3ExpressObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/your-bucket--zone-id--x-s3/*"
      ]
    }
  ]
}
```

### 3.2 更新现有 Policy (添加新 Bucket)

```bash
# 创建新版本的 policy
cat > /tmp/s3_policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ExpressCreateSession",
      "Effect": "Allow",
      "Action": ["s3express:CreateSession"],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/bucket1--use2-az1--x-s3",
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/bucket2--use2-az1--x-s3"
      ]
    },
    {
      "Sid": "S3ExpressListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/bucket1--use2-az1--x-s3",
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/bucket2--use2-az1--x-s3"
      ]
    },
    {
      "Sid": "S3ExpressObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/bucket1--use2-az1--x-s3/*",
        "arn:aws:s3express:us-east-2:ACCOUNT-ID:bucket/bucket2--use2-az1--x-s3/*"
      ]
    }
  ]
}
EOF

# 创建新版本并设为默认
aws iam create-policy-version \
  --policy-arn arn:aws:iam::ACCOUNT-ID:policy/${CLUSTER_NAME}-S3CSIDriverPolicy \
  --policy-document file:///tmp/s3_policy.json \
  --set-as-default
```

### 3.3 关键权限说明

- **s3express:CreateSession**: S3 Express 专用，用于创建会话令牌，必需
- **s3:ListBucket**: 列出 bucket 中的对象
- **s3:GetObject**: 读取对象
- **s3:PutObject**: 写入对象
- **s3:DeleteObject**: 删除对象
- **s3:AbortMultipartUpload**: 中止分段上传

## 步骤四：创建 Kubernetes 资源

### 4.1 创建 PersistentVolume

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-express-pv
spec:
  capacity:
    storage: 1200Gi  # 容量值对 S3 无实际限制，仅用于 PVC 匹配
  accessModes:
    - ReadWriteMany
  mountOptions:
    - allow-delete       # 允许删除文件
    - allow-overwrite    # 允许覆写文件 (写操作必需)
    - region us-east-2   # 指定区域
  csi:
    driver: s3.csi.aws.com
    volumeHandle: your-bucket--use2-az1--x-s3  # Bucket 名称
    volumeAttributes:
      bucketName: your-bucket--use2-az1--x-s3  # Bucket 名称
```

### 4.2 创建 PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-express-claim
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""  # 使用静态 PV，留空
  resources:
    requests:
      storage: 1200Gi   # 必须匹配 PV 容量
  volumeName: s3-express-pv  # 绑定到特定 PV
```

### 4.3 在 Pod 中使用

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: s3-express-app
  namespace: default
spec:
  containers:
  - name: app
    image: your-application:latest
    volumeMounts:
    - name: s3-data
      mountPath: /data  # 容器内挂载路径
  volumes:
  - name: s3-data
    persistentVolumeClaim:
      claimName: s3-express-claim
```

### 4.4 部署资源

```bash
# 应用所有资源
kubectl apply -f s3-express-resources.yaml

# 验证 PV 状态
kubectl get pv s3-express-pv

# 验证 PVC 状态
kubectl get pvc s3-express-claim -n default

# 验证 Pod 状态
kubectl get pod s3-express-app -n default

# 检查 Mountpoint pods (实际执行挂载的 pod)
kubectl get pods -n mount-s3
```

## 步骤五：验证和测试

### 5.1 基础验证

```bash
# 检查 Pod 是否正常运行
kubectl get pod s3-express-app -n default

# 查看 Pod 详情
kubectl describe pod s3-express-app -n default

# 检查 Mountpoint pod 日志
kubectl logs -n mount-s3 -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver
```

### 5.2 功能测试

```bash
# 进入 Pod 测试读写
kubectl exec -it s3-express-app -- /bin/sh

# 在 Pod 内执行
cd /data
echo "Test file content" > test.txt
ls -lh
cat test.txt
```

### 5.3 创建测试 Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: s3-express-test
  namespace: default
spec:
  containers:
  - name: test
    image: public.ecr.aws/docker/library/busybox:latest
    command: ["/bin/sh"]
    args:
      - -c
      - |
        echo "Writing test file..."
        echo "S3 Express test - $(date)" > /data/test-$(date +%s).txt
        ls -lh /data/
        cat /data/test-*.txt
        echo "Test completed successfully!"
        sleep 3600
    volumeMounts:
    - name: s3-volume
      mountPath: /data
  volumes:
  - name: s3-volume
    persistentVolumeClaim:
      claimName: s3-express-claim
```

部署测试 Pod：

```bash
kubectl apply -f s3-express-test.yaml

# 等待 Pod 启动
kubectl wait --for=condition=Ready pod/s3-express-test --timeout=120s

# 查看测试日志
kubectl logs s3-express-test
```

## 常见问题和故障排查

### 问题 1: Mountpoint Pod CrashLoopBackOff

**错误信息**:
```
AWS_ERROR_S3EXPRESS_CREATE_SESSION_FAILED, CreateSession call failed
```

**原因**: IAM 权限不足或 Pod Identity 配置错误

**解决方案**:
```bash
# 1. 检查 IAM policy 是否包含 s3express:CreateSession
aws iam get-policy-version \
  --policy-arn arn:aws:iam::ACCOUNT-ID:policy/${CLUSTER_NAME}-S3CSIDriverPolicy \
  --version-id $(aws iam get-policy --policy-arn arn:aws:iam::ACCOUNT-ID:policy/${CLUSTER_NAME}-S3CSIDriverPolicy --query 'Policy.DefaultVersionId' --output text)

# 2. 检查 Pod Identity 关联
aws eks list-pod-identity-associations \
  --cluster-name $CLUSTER_NAME \
  --region $AWS_REGION

# 3. 更新 IAM policy 后，重启 CSI pods
kubectl rollout restart daemonset s3-csi-node -n kube-system

# 4. 删除并重新创建测试 Pod
kubectl delete pod s3-express-test
kubectl apply -f s3-express-test.yaml
```

### 问题 2: 写操作失败 (Operation not permitted)

**错误信息**:
```
/bin/sh: line 1: /data/test.txt: Operation not permitted
```

**原因**: 缺少 `allow-overwrite` mount option

**解决方案**:
在 PV 的 `mountOptions` 中添加 `allow-overwrite`:

```yaml
spec:
  mountOptions:
    - allow-delete
    - allow-overwrite  # 添加此选项
    - region us-east-2
```

### 问题 3: Bucket 名称格式错误

**错误信息**:
```
Invalid bucket name format
```

**原因**: S3 Express bucket 名称不符合格式要求

**正确格式**:
```
<bucket-base-name>--<zone-id>--x-s3
```

**示例**:
- ✅ `my-data--use2-az1--x-s3`
- ❌ `my-data-use2-az1-x-s3` (缺少双横线)
- ❌ `my-data--use2-az1--s3` (缺少 x-)

### 问题 4: Pod Identity 权限传播延迟

**现象**: IAM policy 已更新，但 Pod 仍然无法访问新 bucket

**原因**: Pod Identity credentials 缓存，需要时间传播

**解决方案**:
```bash
# 等待 30-60 秒后重试
sleep 60

# 或重启相关 pods
kubectl delete pod <pod-name>
kubectl delete pods -n mount-s3 --all
```

### 问题 5: 跨可用区延迟

**现象**: S3 Express 性能不如预期

**原因**: Pod 运行的可用区与 S3 Express bucket 不在同一可用区

**解决方案**:
使用 nodeAffinity 将 Pod 调度到 bucket 所在可用区：

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values:
            - us-east-2a  # bucket 所在可用区
```

## 性能优化建议

### 1. 可用区亲和性
将计算工作负载调度到与 S3 Express bucket 相同的可用区，以获得最低延迟。

### 2. 并发访问
S3 Express One Zone 支持高并发访问，适合多 Pod 并发读写场景。

### 3. 文件大小优化
- 小文件 (<1MB): S3 Express 提供最佳性能提升
- 大文件: 考虑使用分段上传

### 4. 缓存策略
对于频繁访问的只读数据，考虑在应用层实现缓存。

## 成本考虑

### S3 Express One Zone 定价特点
- 较高的存储成本 (相比 S3 Standard)
- 较低的请求成本
- 无数据传输费用 (同区域内)
- 适合高频访问、低延迟场景

### 成本优化建议
1. 仅对性能敏感数据使用 S3 Express
2. 冷数据使用 S3 Standard 或其他存储类
3. 监控访问模式，优化存储类选择
4. 使用生命周期策略自动迁移数据

## 监控和日志

### 监控指标

```bash
# 查看 CSI Driver 状态
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver

# 查看 Mountpoint pods 状态
kubectl get pods -n mount-s3

# 查看 PV/PVC 状态
kubectl get pv,pvc -A
```

### 日志收集

```bash
# S3 CSI Controller 日志
kubectl logs -n kube-system -l app=s3-csi-controller --tail=100

# S3 CSI Node 日志
kubectl logs -n kube-system -l app=s3-csi-node --tail=100

# Mountpoint pod 日志
kubectl logs -n mount-s3 <mountpoint-pod-name>

# 应用 Pod 挂载信息
kubectl exec <pod-name> -- df -h /data
kubectl exec <pod-name> -- mount | grep s3
```

## 安全最佳实践

### 1. 最小权限原则
只授予必要的 S3 权限，按 bucket 粒度控制访问。

### 2. 使用 Pod Identity
优先使用 EKS Pod Identity，避免使用 IAM User credentials。

### 3. 网络隔离
使用 VPC Endpoints 访问 S3，避免公网流量。

### 4. 加密
S3 Express One Zone 默认启用服务端加密 (SSE-S3)。

### 5. 审计
启用 CloudTrail 记录 S3 Express 访问日志。

## 高级配置

### 多 Bucket 配置

在单个 IAM policy 中支持多个 S3 Express buckets：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ExpressCreateSession",
      "Effect": "Allow",
      "Action": ["s3express:CreateSession"],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT:bucket/bucket1--use2-az1--x-s3",
        "arn:aws:s3express:us-east-2:ACCOUNT:bucket/bucket2--use2-az1--x-s3",
        "arn:aws:s3express:us-east-2:ACCOUNT:bucket/bucket3--use2-az2--x-s3"
      ]
    }
  ]
}
```

### 混合使用 Standard S3 和 S3 Express

同一个 CSI Driver 可以同时支持 Standard S3 和 S3 Express buckets：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StandardS3",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::standard-bucket"]
    },
    {
      "Sid": "StandardS3Objects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": ["arn:aws:s3:::standard-bucket/*"]
    },
    {
      "Sid": "S3Express",
      "Effect": "Allow",
      "Action": ["s3express:CreateSession"],
      "Resource": ["arn:aws:s3express:us-east-2:ACCOUNT:bucket/express-bucket--use2-az1--x-s3"]
    },
    {
      "Sid": "S3ExpressObjects",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3express:us-east-2:ACCOUNT:bucket/express-bucket--use2-az1--x-s3",
        "arn:aws:s3express:us-east-2:ACCOUNT:bucket/express-bucket--use2-az1--x-s3/*"
      ]
    }
  ]
}
```

## 参考资源

### AWS 文档
- [S3 Express One Zone 用户指南](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html)
- [Mountpoint for Amazon S3](https://github.com/awslabs/mountpoint-s3)
- [S3 CSI Driver](https://github.com/awslabs/mountpoint-s3-csi-driver)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)

### 相关脚本
- `scripts/option_install_csi_drivers.sh` - CSI Driver 自动化安装
- `scripts/pod_identity_helpers.sh` - Pod Identity 配置函数
- `iam-policies/` - IAM policy 模板

## 附录：完整示例

### 完整部署示例

```bash
#!/bin/bash
set -e

# 变量配置
export CLUSTER_NAME="my-cluster"
export AWS_REGION="us-east-2"
export ACCOUNT_ID="123456789012"
export BUCKET_NAME="my-app-data--use2-az1--x-s3"

# 1. 创建 S3 Express bucket
echo "Creating S3 Express One Zone bucket..."
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --create-bucket-configuration '{
    "Location": {"Type": "AvailabilityZone", "Name": "use2-az1"},
    "Bucket": {"DataRedundancy": "SingleAvailabilityZone", "Type": "Directory"}
  }' \
  --region "$AWS_REGION"

# 2. 创建 IAM policy
echo "Creating IAM policy..."
cat > /tmp/s3-express-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ExpressAccess",
      "Effect": "Allow",
      "Action": [
        "s3express:CreateSession",
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3express:${AWS_REGION}:${ACCOUNT_ID}:bucket/${BUCKET_NAME}",
        "arn:aws:s3express:${AWS_REGION}:${ACCOUNT_ID}:bucket/${BUCKET_NAME}/*"
      ]
    }
  ]
}
EOF

aws iam create-policy-version \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-S3CSIDriverPolicy" \
  --policy-document file:///tmp/s3-express-policy.json \
  --set-as-default

# 3. 创建 Kubernetes 资源
echo "Creating Kubernetes resources..."
cat > /tmp/s3-express-app.yaml << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-app-pv
spec:
  capacity:
    storage: 1200Gi
  accessModes:
    - ReadWriteMany
  mountOptions:
    - allow-delete
    - allow-overwrite
    - region ${AWS_REGION}
  csi:
    driver: s3.csi.aws.com
    volumeHandle: ${BUCKET_NAME}
    volumeAttributes:
      bucketName: ${BUCKET_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-claim
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 1200Gi
  volumeName: my-app-pv
---
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  namespace: default
spec:
  containers:
  - name: app
    image: nginx:latest
    volumeMounts:
    - name: s3-data
      mountPath: /usr/share/nginx/html
  volumes:
  - name: s3-data
    persistentVolumeClaim:
      claimName: my-app-claim
EOF

kubectl apply -f /tmp/s3-express-app.yaml

# 4. 等待 Pod 就绪
echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/my-app --timeout=120s

# 5. 验证
echo "Verifying deployment..."
kubectl get pod my-app
kubectl get pvc my-app-claim
kubectl get pv my-app-pv
kubectl get pods -n mount-s3

echo "✓ Deployment completed successfully!"
```

## 版本历史

- **v1.0** (2026-01-02): 初始版本
  - S3 Express One Zone 基础配置
  - Pod Identity 集成
  - 故障排查指南
