#!/bin/bash

set -e

# 获取脚本所在目录的父目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 日志函数
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
warn() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }

log "=== Applying Critical Fixes to EKS Deployment ==="

# 1. 修复 Kubernetes 版本 (1.34 → 1.31)
log "Fix #1: Correcting Kubernetes version from 1.34 to 1.31..."

sed -i 's/K8S_VERSION:-1.34/K8S_VERSION:-1.31/g' "${SCRIPT_DIR}/setup_env.sh"
sed -i 's/K8S_VERSION=1.34/K8S_VERSION=1.31/g' "${PROJECT_ROOT}/.env.example"

log "✅ Kubernetes version fixed to 1.31"

# 2. 修复 Cluster Autoscaler 版本
log "Fix #2: Updating Cluster Autoscaler version to match K8s 1.31..."

sed -i 's/cluster-autoscaler:v1.34.0/cluster-autoscaler:v1.31.0/g' \
    "${PROJECT_ROOT}/manifests/addons/cluster-autoscaler.yaml"

log "✅ Cluster Autoscaler version fixed to v1.31.0"

# 3. 锁定 addon 版本
log "Fix #3: Locking addon versions..."

cat > "${PROJECT_ROOT}/manifests/cluster/addon-versions-patch.yaml" <<'EOF'
# 将此内容合并到 eksctl_cluster_template.yaml 的 addons 部分

addons:
  - name: vpc-cni
    version: v1.18.5-eksbuild.1  # 锁定版本
  - name: coredns
    version: v1.11.3-eksbuild.1  # 锁定版本
  - name: kube-proxy
    version: v1.31.2-eksbuild.3  # 匹配 K8s 版本
  - name: eks-pod-identity-agent
    version: v1.3.4-eksbuild.1   # 最新稳定版
  - name: aws-ebs-csi-driver
    version: v1.37.0-eksbuild.1  # 最新稳定版
    serviceAccountRoleArn: arn:${AWS_PARTITION}:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-ebs-csi-driver-role
EOF

log "✅ Created addon version patch file: manifests/cluster/addon-versions-patch.yaml"
warn "⚠️  Please manually merge addon-versions-patch.yaml into eksctl_cluster_template.yaml"

# 4. 修复 S3 IAM 权限
log "Fix #4: Creating restrictive S3 IAM policy..."

cat > "${PROJECT_ROOT}/manifests/cluster/s3-csi-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::${S3_BUCKET_PREFIX}*/*"
    }
  ]
}
EOF

log "✅ Created restrictive S3 policy: manifests/cluster/s3-csi-policy.json"
warn "⚠️  Update S3_BUCKET_PREFIX in the policy and apply manually"

# 5. 创建 ResourceQuota 和 LimitRange
log "Fix #5: Creating resource quotas and limits..."

cat > "${PROJECT_ROOT}/manifests/cluster/resource-controls.yaml" <<'EOF'
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: default-quota
  namespace: default
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    persistentvolumeclaims: "10"
    services.loadbalancers: "3"
    services.nodeports: "5"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limit-range
  namespace: default
spec:
  limits:
  - max:
      cpu: "4"
      memory: "8Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    type: Container
  - max:
      storage: "50Gi"
    min:
      storage: "1Gi"
    type: PersistentVolumeClaim
EOF

log "✅ Created resource controls: manifests/cluster/resource-controls.yaml"

# 6. 添加 Pod Security Standards
log "Fix #6: Creating Pod Security Standards..."

cat > "${PROJECT_ROOT}/manifests/cluster/pod-security.yaml" <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: default
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF

log "✅ Created Pod Security Standards: manifests/cluster/pod-security.yaml"

# 7. 更新 EFS CSI Driver 版本
log "Fix #7: Updating EFS CSI Driver to v2.1.0..."

sed -i 's/aws-efs-csi-driver:v2.0.7/aws-efs-csi-driver:v2.1.0/g' \
    "${PROJECT_ROOT}/manifests/addons/efs-csi-driver.yaml"

log "✅ EFS CSI Driver updated to v2.1.0"

# 8. 更新 S3 CSI Driver 版本
log "Fix #8: Updating S3 CSI Driver to v1.11.0..."

sed -i 's/mountpoint-s3-csi-driver:v1.10.0/mountpoint-s3-csi-driver:v1.11.0/g' \
    "${PROJECT_ROOT}/manifests/addons/s3-csi-driver.yaml"

log "✅ S3 CSI Driver updated to v1.11.0"

# 9. 修复 setup_env.sh 的换行符问题
log "Fix #9: Fixing newline in error message..."

sed -i 's/\\nPlease create/\x27$'"'"'\\n'"'"'$'"'"'Please create/g' "${SCRIPT_DIR}/setup_env.sh"

log "✅ Error message newline fixed"

# 10. 创建错误处理函数模板
log "Fix #10: Creating error handling template..."

cat > "${PROJECT_ROOT}/scripts/error_handling.sh" <<'EOF'
#!/bin/bash

# 错误处理和清理函数
# Source this file in install_eks_cluster.sh

DEPLOYMENT_FAILED=0

cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ $DEPLOYMENT_FAILED -eq 0 ]; then
        DEPLOYMENT_FAILED=1
        log "ERROR: Deployment failed with exit code $exit_code"
        log "Starting cleanup..."

        # 清理 Helm releases
        helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true

        # 询问是否删除集群
        read -p "Do you want to delete the cluster? (yes/no): " -r
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log "Deleting cluster..."
            eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_DEFAULT_REGION} --wait
            log "Cluster deleted"
        else
            log "Cluster kept for debugging. Delete manually with:"
            log "  eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_DEFAULT_REGION}"
        fi

        log "Cleanup completed"
        exit $exit_code
    fi
}

# 在脚本中启用错误处理
enable_error_handling() {
    set -eE
    trap cleanup_on_error EXIT ERR
}

# 验证工具是否安装
check_prerequisites() {
    local missing_tools=()

    for tool in eksctl kubectl helm envsubst aws jq; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
    fi

    # 检查 eksctl 版本
    local eksctl_version=$(eksctl version | grep -oP '\d+\.\d+\.\d+' | head -1)
    local required_version="0.150.0"

    if [ "$(printf '%s\n' "$required_version" "$eksctl_version" | sort -V | head -n1)" != "$required_version" ]; then
        warn "eksctl version $eksctl_version is older than $required_version. Some features may not work."
    fi

    log "✅ All prerequisites satisfied"
}
EOF

chmod +x "${PROJECT_ROOT}/scripts/error_handling.sh"

log "✅ Created error handling template: scripts/error_handling.sh"

# 11. 优化成本配置
log "Fix #11: Creating cost-optimized cluster configuration..."

cat > "${PROJECT_ROOT}/manifests/cluster/cost-optimized-nodes.yaml" <<'EOF'
# 成本优化的节点组配置
# 替换 eksctl_cluster_template.yaml 中的 managedNodeGroups 部分

managedNodeGroups:
  # 系统节点组 - 使用 ARM 架构节省成本
  - name: eks-utils
    instanceType: t4g.medium  # ARM 架构,成本降低 ~60%
    amiFamily: AmazonLinux2023
    desiredCapacity: 2
    minSize: 1  # 允许缩减到 1
    maxSize: 3
    volumeSize: 20  # 减少到 20GB
    volumeType: gp3
    privateNetworking: true
    subnets:
      - ${PRIVATE_SUBNET_2A}
      - ${PRIVATE_SUBNET_2B}
      - ${PRIVATE_SUBNET_2C}
    labels:
      app: "eks-utils"
      node-type: "system"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
      cost-center: "platform"

  # 应用节点组 - 支持 Spot 实例
  - name: app-spot
    instanceTypes: ["m7i.large", "m6i.large", "m5.large"]  # 多实例类型
    spot: true  # 使用 Spot 实例,成本降低 ~70%
    desiredCapacity: 0  # 默认不运行
    minSize: 0
    maxSize: 10
    volumeSize: 30
    volumeType: gp3
    privateNetworking: true
    subnets:
      - ${PRIVATE_SUBNET_2A}
      - ${PRIVATE_SUBNET_2B}
      - ${PRIVATE_SUBNET_2C}
    labels:
      app: "application"
      node-type: "spot"
      capacity-type: "spot"
    taints:
      - key: "spot"
        value: "true"
        effect: "NoSchedule"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
      cost-center: "applications"

  # 按需节点组 - 用于关键工作负载
  - name: app-ondemand
    instanceType: m7i.large
    desiredCapacity: 0
    minSize: 0
    maxSize: 5
    volumeSize: 30
    volumeType: gp3
    privateNetworking: true
    subnets:
      - ${PRIVATE_SUBNET_2A}
      - ${PRIVATE_SUBNET_2B}
      - ${PRIVATE_SUBNET_2C}
    labels:
      app: "application"
      node-type: "ondemand"
      capacity-type: "on-demand"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
      cost-center: "applications"
EOF

log "✅ Created cost-optimized configuration: manifests/cluster/cost-optimized-nodes.yaml"

# 12. 创建 Network Policy 模板
log "Fix #12: Creating Network Policy templates..."

cat > "${PROJECT_ROOT}/manifests/cluster/network-policies.yaml" <<'EOF'
---
# 默认拒绝所有入站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
# 允许同 namespace 内的流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}
---
# 允许 DNS 查询
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    - podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
EOF

log "✅ Created Network Policy templates: manifests/cluster/network-policies.yaml"

# 13. 更新 CloudWatch 日志保留期
log "Fix #13: Updating CloudWatch log retention..."

log "ℹ️  Manual action required: Update eksctl_cluster_template.yaml:"
log "    cloudWatch.clusterLogging.logRetentionInDays: 90 → 30"

# 完成报告
log ""
log "=== Critical Fixes Applied Successfully ==="
log ""
log "📝 Summary of Changes:"
log "  ✅ Fixed Kubernetes version (1.34 → 1.31)"
log "  ✅ Fixed Cluster Autoscaler version (v1.34.0 → v1.31.0)"
log "  ✅ Updated EFS CSI Driver (v2.0.7 → v2.1.0)"
log "  ✅ Updated S3 CSI Driver (v1.10.0 → v1.11.0)"
log "  ✅ Created addon version lock file"
log "  ✅ Created restrictive S3 IAM policy"
log "  ✅ Created resource quotas and limits"
log "  ✅ Created Pod Security Standards"
log "  ✅ Created error handling template"
log "  ✅ Created cost-optimized node configuration"
log "  ✅ Created Network Policy templates"
log ""
log "⚠️  Manual Actions Required:"
log "  1. Merge addon-versions-patch.yaml into eksctl_cluster_template.yaml"
log "  2. Update S3 policy with actual bucket prefix"
log "  3. Apply eksctl_cluster_template.yaml changes to S3 CSI service account"
log "  4. Source error_handling.sh in install_eks_cluster.sh"
log "  5. Update CloudWatch log retention to 30 days"
log "  6. Consider using cost-optimized-nodes.yaml configuration"
log ""
log "📚 Review Documentation:"
log "  - COMPREHENSIVE_REVIEW.md - Full security and cost analysis"
log "  - VERSION_MATRIX.md - Component version guidelines"
log ""
log "🚀 Next Steps:"
log "  1. Review all generated files"
log "  2. Apply manual changes"
log "  3. Test in non-production environment"
log "  4. Deploy to production"
log ""
