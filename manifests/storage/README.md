# EKS StorageClass 使用指南

## 可用的 StorageClass

### 1. gp3 (默认)

**特点**:
- 基于 AWS EBS gp3 卷类型
- 3000 IOPS 基线，125 MB/s 吞吐量
- 自动加密
- 支持在线扩容
- 成本比 gp2 低约 20%

**适用场景**:
- 通用应用数据存储
- 日志持久化
- 配置文件存储
- 大部分工作负载的默认选择

**成本**: ~$0.08/GB/月

---

### 2. io2

**特点**:
- 基于 AWS EBS io2 卷类型
- 10000 IOPS（可根据需求调整）
- 低延迟、高性能
- 适合 I/O 密集型应用
- 支持在线扩容

**适用场景**:
- 数据库（MySQL, PostgreSQL, MongoDB）
- 高性能文件系统
- 实时数据处理
- 对延迟敏感的应用

**成本**: ~$0.125/GB/月 + $0.065/IOPS/月

---

## 使用示例

### 示例 1: 使用默认 StorageClass (gp3)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  # storageClassName 可以省略，会使用默认的 gp3
```

### 示例 2: 显式指定 gp3

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: logs-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3
  resources:
    requests:
      storage: 50Gi
```

### 示例 3: 使用 io2 高性能存储（数据库）

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: io2
  resources:
    requests:
      storage: 100Gi
```

### 示例 4: StatefulSet 使用 io2

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "changeme"
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: io2
      resources:
        requests:
          storage: 100Gi
```

---

## 在线扩容示例

所有 StorageClass 都支持在线扩容（无需重启 Pod）：

```bash
# 1. 编辑 PVC，增加存储大小
kubectl edit pvc app-data

# 修改 spec.resources.requests.storage 的值
# 例如: 20Gi -> 50Gi

# 2. 验证扩容状态
kubectl get pvc app-data
# STATUS 会显示 Resizing，完成后变为 Bound

# 3. 验证文件系统已扩容
kubectl exec <pod-name> -- df -h /mount/path
```

---

## 查看可用的 StorageClass

```bash
kubectl get storageclass

# 输出示例:
# NAME            PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
# gp2             ebs.csi.aws.com         Delete          WaitForFirstConsumer   false                  1h
# gp3 (default)   ebs.csi.aws.com         Delete          WaitForFirstConsumer   true                   5m
# io2             ebs.csi.aws.com         Delete          WaitForFirstConsumer   true                   5m
```

---

## 性能对比

| StorageClass | IOPS | 吞吐量 | 延迟 | 成本/GB | 适用场景 |
|-------------|------|--------|------|---------|----------|
| gp2 (旧默认) | 100-16000 (动态) | 250 MB/s | 中 | $0.10 | 旧默认，不推荐 |
| **gp3** (推荐) | 3000 基线 | 125 MB/s | 中 | **$0.08** | 通用场景 ✅ |
| **io2** | 10000 | 1000 MB/s | 低 | $0.125 + IOPS | 数据库 ✅ |

---

## 常见问题

### Q: 如何查看 PVC 使用的 StorageClass？

```bash
kubectl get pvc -o custom-columns=NAME:.metadata.name,STORAGECLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage
```

### Q: 如何更改默认 StorageClass？

```bash
# 移除当前默认
kubectl patch storageclass gp3 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# 设置新的默认
kubectl patch storageclass io2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Q: gp3 vs gp2 选择建议？

**推荐使用 gp3**，原因：
- ✅ 性能更好（3000 IOPS 基线 vs gp2 的动态 IOPS）
- ✅ 成本更低（约 20% cheaper）
- ✅ IOPS 和吞吐量可独立调整
- ✅ AWS 推荐的新一代卷类型

### Q: 什么时候使用 io2？

使用 io2 的场景：
- 需要高 IOPS（> 3000）
- 需要低延迟（< 1ms）
- 运行数据库工作负载
- I/O 密集型应用

---

## 成本估算示例

### 场景 1: 100GB 通用存储 (gp3)

```
存储成本: 100 GB × $0.08 = $8/月
IOPS 成本: 3000 IOPS（基线，免费）
总成本: $8/月
```

### 场景 2: 100GB 数据库存储 (io2, 10000 IOPS)

```
存储成本: 100 GB × $0.125 = $12.5/月
IOPS 成本: 10000 IOPS × $0.065 = $650/月
总成本: $662.5/月
```

**建议**: 仅在确实需要高性能时使用 io2，否则 gp3 已足够。

---

## 测试 StorageClass

```bash
# 创建测试 PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-gp3
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3
  resources:
    requests:
      storage: 10Gi
EOF

# 创建测试 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'Testing gp3 storage' > /data/test.txt && sleep 3600"]
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-gp3
EOF

# 验证
kubectl exec test-pod -- cat /data/test.txt

# 清理
kubectl delete pod test-pod
kubectl delete pvc test-gp3
```

---

## 参考文档

- [AWS EBS Volume Types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-volume-types.html)
- [EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [Kubernetes StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/)
