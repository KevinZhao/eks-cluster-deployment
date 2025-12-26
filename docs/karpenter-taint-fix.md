# Karpenter Taint 配置修复说明

## 问题描述

在之前的配置中，Karpenter NodePools 配置了 taints，但测试 Pods 没有相应的 tolerations，导致 Pods 无法调度到 Karpenter 创建的节点上。

### 错误配置示例

**NodePool 配置** (有 taint):
```yaml
spec:
  template:
    spec:
      taints:
        - key: arch
          value: arm64
          effect: NoSchedule
```

**Pod 配置** (没有 toleration):
```yaml
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
  # 缺少 tolerations！
```

**错误日志**:
```
could not schedule pod, did not tolerate taint (taint=arch=arm64:NoSchedule)
```

## 修复方案

已修改以下文件，移除了 taints 配置：

1. `manifests/karpenter/nodepool-graviton.yaml` - 移除 `arch=arm64:NoSchedule` taint
2. `manifests/karpenter/nodepool-x86.yaml` - 移除 `arch=amd64:NoSchedule` taint

### 修改后的配置

taints 部分已注释掉：

```yaml
# Taints - 移除 taints，使用 nodeSelector 就足够了
# 如果需要专用节点，请给 Pod 添加对应的 tolerations
# taints:
#   - key: arch
#     value: arm64
#     effect: NoSchedule
```

## 架构区分方案对比

### 方案 1: 使用 nodeSelector (当前方案 - 推荐)

**优点**:
- 简单直接
- Pod 配置简洁
- 适合大多数场景

**NodePool 配置**:
```yaml
spec:
  template:
    metadata:
      labels:
        arch: arm64
```

**Pod 配置**:
```yaml
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
```

### 方案 2: 使用 Taints + Tolerations (专用节点场景)

**优点**:
- 强制隔离
- 防止意外调度
- 适合专用/敏感工作负载

**NodePool 配置**:
```yaml
spec:
  template:
    spec:
      taints:
        - key: arch
          value: arm64
          effect: NoSchedule
```

**Pod 配置** (需要添加 toleration):
```yaml
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
  tolerations:
    - key: arch
      value: arm64
      effect: NoSchedule
      operator: Equal
```

### 方案 3: 使用 Node Affinity (灵活场景)

**优点**:
- 最灵活
- 支持软/硬亲和性
- 可以设置优先级

**Pod 配置**:
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/arch
            operator: In
            values:
            - arm64
```

## 何时使用 Taints

Taints 适合以下场景：

1. **专用节点**: GPU 节点、高内存节点等昂贵资源
2. **安全隔离**: 处理敏感数据的节点
3. **特殊硬件**: 需要特定硬件特性的工作负载
4. **生产/测试隔离**: 环境级别的隔离

## 如何重新启用 Taints

如果你确实需要使用 taints，需要同时修改两处：

### 1. 取消注释 NodePool 中的 taints

在 `manifests/karpenter/nodepool-graviton.yaml`:
```yaml
taints:
  - key: arch
    value: arm64
    effect: NoSchedule
```

### 2. 给 Deployment 添加 tolerations

在 `scripts/12_test_karpenter_pools.sh`:
```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      tolerations:
        - key: arch
          value: arm64
          effect: NoSchedule
          operator: Equal
      containers:
      - name: inflate
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
```

## 验证修复

运行以下命令验证修复是否成功：

```bash
# 1. 检查 NodePool 配置
kubectl get nodepool graviton -o yaml | grep -A 5 taints

# 2. 应用修改后的配置
kubectl apply -f manifests/karpenter/nodepool-graviton.yaml
kubectl apply -f manifests/karpenter/nodepool-x86.yaml

# 3. 测试 Pod 调度
kubectl scale deployment inflate-graviton --replicas=5
kubectl get pods -l app=inflate-graviton -w

# 4. 检查 Karpenter 日志
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50
```

## 参考资料

- [Kubernetes Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Karpenter NodePool Documentation](https://karpenter.sh/docs/concepts/nodepools/)
- [Node Affinity vs Node Selector](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)

## 更新日志

- **2025-12-26**: 移除 NodePool taints 配置，修复 Pod 调度问题
- 保留 taints 配置注释，方便未来根据需要启用
