# S3 CSI Driver 测试指南

本文档记录 S3 CSI Driver 的配置和测试过程，包括标准 S3 和 S3 Express One Zone (Directory Bucket) 的使用。

## 目录

- [前置条件](#前置条件)
- [S3 Express One Zone 测试](#s3-express-one-zone-测试)
- [标准 S3 Bucket 测试](#标准-s3-bucket-测试)
- [故障排除](#故障排除)
- [清理资源](#清理资源)

## 前置条件

1. EKS 集群已部署并运行
2. S3 CSI Driver 已安装
3. kubectl 已配置正确的集群上下文

### 验证 S3 CSI Driver 状态

```bash
# 检查 S3 CSI Driver pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver

# 预期输出示例:
# NAME                                 READY   STATUS    RESTARTS   AGE
# s3-csi-controller-xxx                1/1     Running   0          30m
# s3-csi-node-xxx                      3/3     Running   0          30m

# 检查 Pod Identity Association
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} \
  --query "associations[?serviceAccount=='s3-csi-driver-sa']"
```

## S3 Express One Zone 测试

S3 Express One Zone 提供单位数毫秒延迟，适合对延迟敏感的应用。

### 步骤 1: 创建 S3 Express One Zone Bucket

```bash
# 查看可用区 ID
aws ec2 describe-availability-zones --region ${AWS_REGION} \
  --query 'AvailabilityZones[*].[ZoneName,ZoneId]' --output table

# 示例输出 (us-west-2):
# |  us-west-2a |  usw2-az1  |
# |  us-west-2b |  usw2-az2  |
# |  us-west-2c |  usw2-az3  |
# |  us-west-2d |  usw2-az4  |

# 设置变量
export BUCKET_BASE="${CLUSTER_NAME}-test-express"
export AZ_ID="usw2-az1"  # 根据实际区域调整
export BUCKET_NAME="${BUCKET_BASE}--${AZ_ID}--x-s3"

# 创建 S3 Express One Zone bucket
aws s3api create-bucket \
  --bucket "${BUCKET_NAME}" \
  --create-bucket-configuration '{
    "Location": {
      "Type": "AvailabilityZone",
      "Name": "'${AZ_ID}'"
    },
    "Bucket": {
      "DataRedundancy": "SingleAvailabilityZone",
      "Type": "Directory"
    }
  }' \
  --region ${AWS_REGION}

# 验证创建成功
aws s3api head-bucket --bucket "${BUCKET_NAME}" --region ${AWS_REGION}
```

### 步骤 2: 更新 IAM 权限

S3 Express One Zone 需要额外的 `s3express:CreateSession` 权限。

**方式 A: 重新运行安装脚本（推荐）**

```bash
# 脚本会自动检测 S3 Express bucket 并添加所需权限
./scripts/option_install_csi_drivers.sh s3 "arn:aws:s3express:${AWS_REGION}:${ACCOUNT_ID}:bucket/${BUCKET_NAME}"
```

**方式 B: 手动更新 IAM Policy**

```bash
# 获取当前 policy 版本
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-S3CSIDriverPolicy"
CURRENT_VERSION=$(aws iam get-policy --policy-arn "${POLICY_ARN}" --query 'Policy.DefaultVersionId' --output text)

# 查看当前 policy
aws iam get-policy-version --policy-arn "${POLICY_ARN}" --version-id ${CURRENT_VERSION} \
  --query 'PolicyVersion.Document' --output json | jq .

# 创建新 policy 文件，添加 S3 Express 权限
cat > /tmp/s3-csi-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ExpressCreateSession",
      "Effect": "Allow",
      "Action": "s3express:CreateSession",
      "Resource": [
        "arn:aws:s3express:${AWS_REGION}:${ACCOUNT_ID}:bucket/${BUCKET_NAME}"
      ]
    }
  ]
}
EOF

# 更新 policy (添加新版本)
aws iam create-policy-version \
  --policy-arn "${POLICY_ARN}" \
  --policy-document file:///tmp/s3-csi-policy.json \
  --set-as-default

# 重启 S3 CSI node pods 以刷新凭证
kubectl rollout restart daemonset s3-csi-node -n kube-system
kubectl rollout status daemonset s3-csi-node -n kube-system
```

### 步骤 3: 创建 PV 和 PVC

```bash
cat << EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-express-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  csi:
    driver: s3.csi.aws.com
    volumeHandle: s3-csi-express-volume
    volumeAttributes:
      bucketName: ${BUCKET_NAME}
      authenticationSource: driver  # 关键: 使用 driver 认证
  mountOptions:
    - allow-delete
    - region ${AWS_REGION}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-express-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 100Gi
  volumeName: s3-express-pv
EOF

# 验证 PV/PVC 绑定
kubectl get pv s3-express-pv
kubectl get pvc s3-express-pvc
```

### 步骤 4: 创建测试 Pod

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: s3-express-test
spec:
  nodeSelector:
    app: eks-utils
  containers:
  - name: app
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["/bin/sh", "-c"]
    args:
      - |
        echo "=== S3 Express One Zone Test ==="
        echo "Timestamp: $(date)"
        echo "Pod: $HOSTNAME"
        echo ""
        echo "Writing test file..."
        echo "Hello from S3 Express One Zone! $(date)" > /data/test-$(date +%s).txt
        echo ""
        echo "Listing files in /data:"
        ls -la /data/
        echo ""
        echo "Test complete. Sleeping..."
        sleep infinity
    volumeMounts:
    - name: s3-storage
      mountPath: /data
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
  volumes:
  - name: s3-storage
    persistentVolumeClaim:
      claimName: s3-express-pvc
EOF
```

### 步骤 5: 验证测试结果

```bash
# 等待 Pod 运行
kubectl wait --for=condition=Ready pod/s3-express-test --timeout=120s

# 查看 Pod 日志
kubectl logs s3-express-test

# 预期输出:
# === S3 Express One Zone Test ===
# Timestamp: Sat Jan  3 15:20:40 UTC 2026
# Pod: s3-express-test
#
# Writing test file...
#
# Listing files in /data:
# total 1
# drwxr-xr-x. 2 1000 root  0 Jan  3 15:20 .
# drwxr-xr-x. 1 root root 40 Jan  3 15:20 ..
# -rw-r--r--. 1 1000 root 61 Jan  3 15:20 test-1767453640.txt
#
# Test complete. Sleeping...

# 验证 S3 bucket 中的文件
aws s3 ls "s3://${BUCKET_NAME}/" --region ${AWS_REGION}

# 读取文件内容
aws s3 cp "s3://${BUCKET_NAME}/test-1767453640.txt" - --region ${AWS_REGION}

# 在 Pod 中执行额外测试
kubectl exec s3-express-test -- sh -c "echo 'Additional write test' >> /data/extra-test.txt && cat /data/extra-test.txt"
```

## 标准 S3 Bucket 测试

### 创建标准 S3 Bucket

```bash
export STANDARD_BUCKET="${CLUSTER_NAME}-test-standard-$(date +%s)"

aws s3 mb "s3://${STANDARD_BUCKET}" --region ${AWS_REGION}
```

### 安装 S3 CSI Driver

```bash
./scripts/option_install_csi_drivers.sh s3 "arn:aws:s3:::${STANDARD_BUCKET}"
```

### 创建 PV/PVC 和测试 Pod

```bash
cat << EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-standard-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  csi:
    driver: s3.csi.aws.com
    volumeHandle: s3-csi-standard-volume
    volumeAttributes:
      bucketName: ${STANDARD_BUCKET}
      authenticationSource: driver
  mountOptions:
    - allow-delete
    - region ${AWS_REGION}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-standard-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 100Gi
  volumeName: s3-standard-pv
---
apiVersion: v1
kind: Pod
metadata:
  name: s3-standard-test
spec:
  nodeSelector:
    app: eks-utils
  containers:
  - name: app
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["/bin/sh", "-c"]
    args: ["echo 'Test file' > /data/test.txt && ls -la /data/ && sleep infinity"]
    volumeMounts:
    - name: s3-storage
      mountPath: /data
  volumes:
  - name: s3-storage
    persistentVolumeClaim:
      claimName: s3-standard-pvc
EOF
```

## 故障排除

### 常见问题

#### 1. Pod 卡在 ContainerCreating 状态

```bash
# 查看 Pod 事件
kubectl describe pod <pod-name> | tail -20

# 查看 Mountpoint Pod 状态
kubectl get pods -n mount-s3

# 查看 Mountpoint Pod 日志
kubectl logs -n mount-s3 <mp-pod-name>
# 如果 Pod 已重启，查看前一次日志
kubectl logs -n mount-s3 <mp-pod-name> --previous
```

#### 2. AWS_ERROR_S3EXPRESS_CREATE_SESSION_FAILED

**原因**: 缺少 `s3express:CreateSession` 权限

**解决方案**:
```bash
# 1. 检查 IAM policy
aws iam get-policy-version --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_NAME}-S3CSIDriverPolicy" \
  --version-id v1 --query 'PolicyVersion.Document'

# 2. 确认包含 s3express:CreateSession 权限
# 3. 如果没有，重新运行安装脚本或手动添加
# 4. 重启 S3 CSI node pods
kubectl rollout restart daemonset s3-csi-node -n kube-system
```

#### 3. Mountpoint Pod 使用 default ServiceAccount

**原因**: PV 没有配置 `authenticationSource: driver`

**解决方案**:
```yaml
# 在 PV 的 volumeAttributes 中添加:
volumeAttributes:
  bucketName: your-bucket-name
  authenticationSource: driver  # 添加此行
```

#### 4. IAM 权限更新后不生效

**解决方案**:
```bash
# 重启 S3 CSI node DaemonSet
kubectl rollout restart daemonset s3-csi-node -n kube-system
kubectl rollout status daemonset s3-csi-node -n kube-system

# 删除并重建测试 Pod
kubectl delete pod <pod-name> --force
kubectl apply -f <pod-manifest>
```

### 调试命令

```bash
# 查看 S3 CSI Driver 日志
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver --tail=100

# 查看 CSI Driver 详情
kubectl describe csidriver s3.csi.aws.com

# 检查 Pod Identity Association
aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} \
  --query "associations[].[namespace,serviceAccount,associationArn]" --output table

# 检查 IAM Role 权限
aws iam list-attached-role-policies --role-name "${CLUSTER_NAME}-s3-csi-driver-role"
```

## 清理资源

```bash
# 删除测试 Pod
kubectl delete pod s3-express-test s3-standard-test --force 2>/dev/null

# 删除 PVC
kubectl delete pvc s3-express-pvc s3-standard-pvc 2>/dev/null

# 删除 PV
kubectl delete pv s3-express-pv s3-standard-pv 2>/dev/null

# 删除测试用 Pod Identity Association (如果创建了额外的)
aws eks delete-pod-identity-association \
  --cluster-name ${CLUSTER_NAME} \
  --association-id <association-id>

# 清空并删除 S3 bucket
aws s3 rm "s3://${BUCKET_NAME}" --recursive --region ${AWS_REGION}
aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region ${AWS_REGION}

# 对于标准 S3 bucket
aws s3 rb "s3://${STANDARD_BUCKET}" --force --region ${AWS_REGION}
```

## 关键配置参考

### PV volumeAttributes

| 参数 | 说明 | 必需 |
|------|------|------|
| `bucketName` | S3 bucket 名称 | 是 |
| `authenticationSource` | 认证来源，设为 `driver` 使用 CSI driver 凭证 | 推荐 |

### mountOptions

| 选项 | 说明 |
|------|------|
| `allow-delete` | 允许删除文件 |
| `region <region>` | 指定 S3 bucket 所在区域 |
| `read-only` | 只读模式 |
| `prefix <path>` | 只挂载 bucket 中的特定前缀 |

### IAM 权限要求

**标准 S3**:
- `s3:ListBucket` (bucket 级别)
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload` (对象级别)

**S3 Express One Zone** (额外权限):
- `s3express:CreateSession` (bucket 级别)

## 测试记录

| 日期 | 测试项 | 结果 | 备注 |
|------|--------|------|------|
| 2026-01-03 | S3 Express One Zone 读写 | 通过 | 需要 authenticationSource: driver |
| 2026-01-03 | IAM 权限更新 | 通过 | 需要重启 s3-csi-node |
