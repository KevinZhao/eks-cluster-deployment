# Karpenter NodePool 测试

本目录包含用于测试 Karpenter NodePool 自动扩缩容的测试清单。

## 测试文件

### 单个Pod测试
- `test-graviton-pod.yaml` - 测试 Graviton NodePool (r8g.8xlarge)
- `test-x86-pod.yaml` - 测试 x86 NodePool (r7i.8xlarge)

### Deployment测试
- `test-deployment-graviton.yaml` - 3副本测试 Graviton NodePool
- `test-deployment-x86.yaml` - 3副本测试 x86 NodePool

## 使用方法

### 测试 Graviton NodePool (r8g.8xlarge)

1. **部署单个Pod**:
```bash
kubectl apply -f manifests/test/test-graviton-pod.yaml
```

2. **查看Pod状态**:
```bash
kubectl get pod test-graviton -o wide
```

3. **查看Karpenter日志**:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 -f
```

4. **查看新创建的节点**:
```bash
kubectl get nodes -l node-type=graviton
```

5. **验证节点类型**:
```bash
kubectl get node <node-name> -o json | jq '.metadata.labels'
```

6. **清理**:
```bash
kubectl delete -f manifests/test/test-graviton-pod.yaml
```

### 测试 x86 NodePool (r7i.8xlarge)

1. **部署单个Pod**:
```bash
kubectl apply -f manifests/test/test-x86-pod.yaml
```

2. **查看Pod状态**:
```bash
kubectl get pod test-x86 -o wide
```

3. **查看Karpenter日志**:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 -f
```

4. **查看新创建的节点**:
```bash
kubectl get nodes -l node-type=x86
```

5. **验证节点类型**:
```bash
kubectl get node <node-name> -o json | jq '.metadata.labels'
```

6. **清理**:
```bash
kubectl delete -f manifests/test/test-x86-pod.yaml
```

### 测试自动扩缩容 (Deployment)

#### 测试 Graviton 扩容

1. **部署Deployment (3副本)**:
```bash
kubectl apply -f manifests/test/test-deployment-graviton.yaml
```

2. **观察节点创建**:
```bash
watch kubectl get nodes -l node-type=graviton
```

3. **扩容到10个副本**:
```bash
kubectl scale deployment test-graviton-deployment --replicas=10
```

4. **观察Karpenter自动创建节点**:
```bash
kubectl get pods -l app=test-graviton -o wide
kubectl get nodes -l node-type=graviton
```

5. **测试缩容 - 减少到1个副本**:
```bash
kubectl scale deployment test-graviton-deployment --replicas=1
```

6. **等待1分钟后，观察节点自动删除**:
```bash
watch kubectl get nodes -l node-type=graviton
```

7. **清理**:
```bash
kubectl delete -f manifests/test/test-deployment-graviton.yaml
```

#### 测试 x86 扩缩容

1. **部署Deployment (3副本)**:
```bash
kubectl apply -f manifests/test/test-deployment-x86.yaml
```

2. **观察节点创建**:
```bash
watch kubectl get nodes -l node-type=x86
```

3. **扩容到10个副本**:
```bash
kubectl scale deployment test-x86-deployment --replicas=10
```

4. **观察Karpenter自动创建节点**:
```bash
kubectl get pods -l app=test-x86 -o wide
kubectl get nodes -l node-type=x86
```

5. **测试缩容 - 减少到1个副本**:
```bash
kubectl scale deployment test-x86-deployment --replicas=1
```

6. **等待1分钟后，观察节点自动删除**:
```bash
watch kubectl get nodes -l node-type=x86
```

7. **清理**:
```bash
kubectl delete -f manifests/test/test-deployment-x86.yaml
```

## 预期行为

### 节点创建
- Karpenter 会根据 Pod 的资源请求和 toleration 自动选择合适的 NodePool
- Graviton Pod 只会调度到 r8g.8xlarge 节点 (256GB内存, 32vCPU)
- x86 Pod 只会调度到 r7i.8xlarge 节点 (256GB内存, 32vCPU)

### 节点缩容
- 节点变空或低利用率后，等待 1 分钟
- Karpenter 会自动删除空闲节点
- 每次最多删除 10% 的节点（budget 配置）

## 监控命令

### 查看所有 Karpenter 管理的节点
```bash
kubectl get nodes -l karpenter.sh/nodepool
```

### 查看 NodePool 状态
```bash
kubectl get nodepool
```

### 查看 EC2NodeClass 状态
```bash
kubectl get ec2nodeclass
```

### 查看 Karpenter 事件
```bash
kubectl get events -n kube-system --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp'
```

### 实时查看 Karpenter 日志
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

## 注意事项

1. **Taints 和 Tolerations**:
   - Graviton NodePool 有 `arch=arm64:NoSchedule` taint
   - x86 NodePool 有 `arch=amd64:NoSchedule` taint
   - 测试 Pod 必须包含对应的 toleration

2. **节点选择器**:
   - 使用 `node-type` 标签确保 Pod 调度到正确的 NodePool

3. **缩容时间**:
   - consolidateAfter 设置为 1 分钟
   - 删除 Pod 后，需要等待至少 1 分钟才会触发缩容

4. **资源限制**:
   - 每个 NodePool 最多创建 1000 个 CPU 和 1000Gi 内存的节点
   - r8g.8xlarge: 32 vCPU, 256GB → 最多约 31 个节点
   - r7i.8xlarge: 32 vCPU, 256GB → 最多约 31 个节点

5. **成本控制**:
   - r8g.8xlarge 和 r7i.8xlarge 都是较大的实例类型
   - 测试完成后请及时清理资源
