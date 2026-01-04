# EKS Pod 磁盘配额 - 设计文档

**版本**: 3.0
**日期**: 2026-01-03
**状态**: 待实施

---

## 1. 概述

本文档描述 Pod 磁盘配额限制的设计方案，使 Pod 只能看到分配的磁盘空间而非整个节点磁盘。

### 1.1 目标

- Pod 内只能看到分配的磁盘空间，而非整个节点磁盘
- 支持动态配额调整
- 配额限制应用于容器文件系统和挂载卷
- 提供配额使用监控能力

### 1.2 非目标

- 集群级别的磁盘配额管理 (仅关注 Pod 级别)

---

## 2. 技术方案

### 2.1 方案对比

| 方案 | 优点 | 缺点 | Pod 视图 |
|------|------|------|----------|
| Ephemeral Storage Limits | K8s 原生，简单 | Pod 仍看到全部磁盘 | 完整磁盘 |
| XFS Quota + Project ID | 真实限制，精确控制 | 实现复杂 | 仅配额空间 |
| 独立 PV/PVC | K8s 原生，成熟 | 额外成本 | 仅 PVC 大小 |

### 2.2 推荐方案

**短期**: Ephemeral Storage Limits (K8s 原生)
**长期**: XFS Quota + Project ID (真实磁盘视图)

---

## 3. 短期方案: Ephemeral Storage Limits

```yaml
resources:
  limits:
    ephemeral-storage: "10Gi"
  requests:
    ephemeral-storage: "5Gi"
```

### 3.1 待办任务

- [ ] 创建示例 manifest: `examples/pod-with-storage-limit.yaml`
- [ ] 添加使用文档

---

## 4. 长期方案: XFS Quota + Project ID

### 4.1 实施步骤

**1. 节点准备**
```bash
# userdata 中启用 project quota
mkfs.xfs -f /dev/nvme1n1
mount -o prjquota /dev/nvme1n1 /var/lib/kubelet
```

**2. Quota Manager DaemonSet**
- 监听 Pod 创建
- 分配唯一 project ID
- 设置文件系统配额

**3. kubelet 配置**
```yaml
featureGates:
  LocalStorageCapacityIsolation: true
```

**4. Admission Webhook**
- 拒绝没有配额设置的 Pod
- 验证配额值范围

### 4.2 待办任务

- [ ] 设计 Quota Manager DaemonSet
- [ ] 实现 project ID 分配逻辑
- [ ] 创建 admission webhook
- [ ] 更新节点 userdata 启用配额
- [ ] 实施监控和报警
- [ ] 端到端测试

### 4.3 交付成果

- `manifests/addons/quota-manager.yaml`
- Admission Webhook
- 监控 metrics

---

## 5. 配置项

| 变量 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `ENABLE_POD_STORAGE_QUOTA` | 布尔 | false | 启用 Pod 存储配额 |
| `DEFAULT_POD_STORAGE_QUOTA` | 字符串 | 10Gi | 默认 Pod 存储配额 |

---

## 6. 测试

### 6.1 Ephemeral Storage 测试
```bash
kubectl apply -f examples/pod-with-storage-limit.yaml
kubectl exec pod -- dd if=/dev/zero of=/data/file bs=1M count=15000
# 应该失败，超过配额
```

### 6.2 XFS Quota 测试
```bash
kubectl exec test-pod -- df -h
# 应该显示配额限制的大小，而非整个磁盘
```

---

## 7. 参考资料

- [Ephemeral Storage](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage)
- [XFS Project Quotas](https://www.kernel.org/doc/html/latest/filesystems/xfs-self-describing-metadata.html)
- [EKS Managed Addons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
