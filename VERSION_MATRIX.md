# EKS 组件版本矩阵

**最后更新:** 2025-12-05
**Kubernetes 版本:** 1.34

## 📦 当前版本 vs 最新稳定版本

| 组件 | 当前版本 | 最新稳定版 | 状态 | 更新优先级 |
|------|---------|-----------|------|-----------|
| **核心组件** |
| Kubernetes | 1.34 | 1.31 | ⚠️ 1.34未发布 | 🔴 **需修复** |
| Amazon VPC CNI | latest | v1.18.5 | ⚠️ 需锁定 | 🟡 P1 |
| CoreDNS | latest | v1.11.3 | ⚠️ 需锁定 | 🟡 P1 |
| kube-proxy | latest | auto | ✅ OK | - |
| **CSI Drivers** |
| EBS CSI Driver | latest | v1.37.0 | ⚠️ 需锁定 | 🟡 P1 |
| EFS CSI Driver | v2.0.7 | v2.1.0 | 🟡 需更新 | 🟢 P2 |
| S3 CSI Driver (Mountpoint) | v1.10.0 | v1.11.0 | 🟡 需更新 | 🟢 P2 |
| **Cluster Add-ons** |
| Cluster Autoscaler | v1.34.0 | v1.31.0 | ⚠️ 版本过高 | 🔴 **需修复** |
| AWS Load Balancer Controller | v1.13.0 | v2.11.0 | 🔴 需更新 | 🔴 **立即** |
| Metrics Server | ❌ 未安装 | v0.7.2 | 🔴 需安装 | 🟡 P1 |
| Pod Identity Agent | latest | auto | ✅ OK | - |
| **监控和可观测性** |
| Prometheus | ❌ 未安装 | v2.54.1 | 🟡 建议 | 🟢 P2 |
| Grafana | ❌ 未安装 | v11.3.0 | 🟡 建议 | 🟢 P2 |
| kube-prometheus-stack | ❌ 未安装 | v65.8.1 | 🟡 建议 | 🟢 P2 |

---

## 🔴 关键版本问题

### 1. Kubernetes 1.34 不存在！
**当前配置:** `K8S_VERSION=1.34`
**问题:** Kubernetes 1.34 尚未发布,最新稳定版是 1.31

**EKS 支持的版本 (截至 2025-12-05):**
- 1.31 ✅ **推荐** (最新)
- 1.30 ✅ 稳定
- 1.29 ✅ 稳定
- 1.28 ⚠️ 即将弃用

**修复:**
```yaml
# manifests/cluster/eksctl_cluster_template.yaml
version: "1.31"

# scripts/setup_env.sh
export K8S_VERSION="${K8S_VERSION:-1.31}"

# .env.example
K8S_VERSION=1.31
```

### 2. Cluster Autoscaler 版本不匹配
**当前:** v1.34.0
**问题:** Cluster Autoscaler 版本必须与 K8s 版本匹配

**版本对应关系:**
- K8s 1.31 → Cluster Autoscaler v1.31.x
- K8s 1.30 → Cluster Autoscaler v1.30.x

**修复:**
```yaml
# manifests/addons/cluster-autoscaler.yaml
image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.31.0
```

### 3. AWS Load Balancer Controller 版本过旧
**当前:** v1.13.0
**最新:** v2.11.0
**问题:** 缺少重要功能和安全修复

**修复:**
```bash
# scripts/install_eks_cluster.sh
# 下载最新 IAM policy
curl -o "${PROJECT_ROOT}/iam_policy.json" \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

# 安装最新版本
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 2.11.0 \
  # ... 其他参数
```

---

## 📋 推荐版本配置

### eksctl 集群模板
```yaml
metadata:
  version: "1.31"  # EKS 最新稳定版

addons:
  - name: vpc-cni
    version: v1.18.5-eksbuild.1  # 锁定版本
  - name: coredns
    version: v1.11.3-eksbuild.1  # 锁定版本
  - name: kube-proxy
    version: v1.31.2-eksbuild.3  # 匹配 K8s 版本
  - name: eks-pod-identity-agent
    version: v1.3.4-eksbuild.1  # 最新稳定版
  - name: aws-ebs-csi-driver
    version: v1.37.0-eksbuild.1  # 最新稳定版
```

### CSI Drivers
```yaml
# EFS CSI Driver
image: amazon/aws-efs-csi-driver:v2.1.0

# S3 CSI Driver (Mountpoint)
image: public.ecr.aws/mountpoint-s3-csi-driver/mountpoint-s3-csi-driver:v1.11.0

# Sidecar containers
image: public.ecr.aws/eks-distro/kubernetes-csi/external-provisioner:v5.1.0-eks-1-31-latest
image: public.ecr.aws/eks-distro/kubernetes-csi/node-driver-registrar:v2.12.0-eks-1-31-latest
image: public.ecr.aws/eks-distro/kubernetes-csi/livenessprobe:v2.14.0-eks-1-31-latest
```

### Cluster Autoscaler
```yaml
image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.31.0
```

### AWS Load Balancer Controller
```bash
helm_chart_version: 2.11.0
app_version: v2.11.0
```

---

## 🔄 版本更新策略

### 1. 定期更新节奏
- **每季度:** 检查组件更新
- **每月:** 检查安全补丁
- **立即:** 修复 CVE 漏洞

### 2. 测试策略
```bash
# 1. 在非生产环境测试
kubectl create namespace test-upgrade
kubectl -n test-upgrade apply -f manifests/

# 2. 验证功能
kubectl -n test-upgrade get pods
kubectl -n test-upgrade logs <pod-name>

# 3. 运行测试套件
./scripts/run_tests.sh

# 4. 生产环境滚动更新
kubectl rollout restart deployment -n kube-system
```

### 3. 回滚计划
```bash
# 保存当前版本
kubectl get deployment -n kube-system -o yaml > backup-$(date +%Y%m%d).yaml

# 如果出问题,回滚
kubectl apply -f backup-YYYYMMDD.yaml
helm rollback aws-load-balancer-controller -n kube-system
```

---

## 🎯 版本兼容性矩阵

### EKS 1.31 兼容的版本
| 组件 | 推荐版本 | 最小版本 | 最大版本 |
|------|---------|---------|---------|
| Cluster Autoscaler | v1.31.0 | v1.31.0 | v1.31.x |
| AWS Load Balancer Controller | v2.11.0 | v2.8.0 | latest |
| EBS CSI Driver | v1.37.0 | v1.30.0 | latest |
| EFS CSI Driver | v2.1.0 | v2.0.0 | latest |
| S3 CSI Driver | v1.11.0 | v1.8.0 | latest |
| Metrics Server | v0.7.2 | v0.6.0 | latest |
| VPC CNI | v1.18.5 | v1.16.0 | latest |
| CoreDNS | v1.11.3 | v1.10.0 | v1.11.x |

---

## 📝 版本查询命令

```bash
# 查看 EKS 支持的版本
aws eks describe-addon-versions --region us-east-2

# 查看已安装的 addon 版本
eksctl get addons --cluster=${CLUSTER_NAME} --region=${AWS_REGION}

# 查看 Helm release 版本
helm list -A

# 查看容器镜像版本
kubectl get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'

# 检查可用的 EKS 版本
aws eks describe-addon-versions \
  --addon-name vpc-cni \
  --kubernetes-version 1.31 \
  --query 'addons[0].addonVersions[*].addonVersion' \
  --output table
```

---

## 🔗 官方版本发布页面

- **EKS:** https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
- **Kubernetes:** https://kubernetes.io/releases/
- **Cluster Autoscaler:** https://github.com/kubernetes/autoscaler/releases
- **AWS Load Balancer Controller:** https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases
- **EBS CSI Driver:** https://github.com/kubernetes-sigs/aws-ebs-csi-driver/releases
- **EFS CSI Driver:** https://github.com/kubernetes-sigs/aws-efs-csi-driver/releases
- **Mountpoint S3 CSI:** https://github.com/awslabs/mountpoint-s3-csi-driver/releases

---

## ⚠️ 弃用警告

### Kubernetes 1.28
- **弃用日期:** 2025-03-15
- **终止支持:** 2025-05-15
- **行动:** 计划升级到 1.30 或 1.31

### 旧版本 Addons
如果使用以下版本,请立即升级:
- VPC CNI < v1.16.0
- CoreDNS < v1.10.0
- AWS Load Balancer Controller < v2.6.0
- EBS CSI Driver < v1.25.0

---

**维护者:** Platform Team
**审查周期:** 每月
**下次审查:** 2025-01-05
