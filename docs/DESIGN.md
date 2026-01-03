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

## 7. CSI Driver 托管化优化

**状态**: 待验证

### 7.1 背景

当前 EFS 和 S3 CSI Driver 使用自定义方式安装，可改为 EKS Managed Addon 以简化管理。

### 7.2 当前实现 vs 目标

| Driver | 当前方式 | 目标方式 | EKS Addon 名称 |
|--------|----------|----------|----------------|
| EFS CSI | 本地 manifest | EKS Managed Addon | `aws-efs-csi-driver` |
| S3 CSI | 官方 kustomize | EKS Managed Addon | `aws-mountpoint-s3-csi-driver` |
| FSx CSI | 本地 manifest | 保持不变 | 无 (AWS 未提供) |

### 7.3 优势

- 统一管理: 与 EBS CSI、Metrics Server 等一致
- 自动更新: EKS 托管版本升级
- 简化配置: 支持 `--configuration-values` 设置 nodeSelector

### 7.4 待验证事项

- [ ] EFS addon 是否支持 Pod Identity (非 IRSA)
- [ ] S3 addon 是否支持自定义 bucket ARNs 权限配置
- [ ] nodeSelector 配置格式是否与 EBS CSI 一致
- [ ] 验证从自定义安装迁移到托管 addon 的平滑过渡

### 7.5 实施步骤 (待验证后执行)

1. 修改 `option_install_csi_drivers.sh`:
   - EFS: 改用 `aws eks create-addon --addon-name aws-efs-csi-driver`
   - S3: 改用 `aws eks create-addon --addon-name aws-mountpoint-s3-csi-driver`

2. 更新 Pod Identity 设置:
   - 确认 addon 使用的 ServiceAccount 名称
   - 调整 `setup_efs_csi_pod_identity` / `setup_s3_csi_pod_identity`

3. 删除不再需要的本地 manifest:
   - `manifests/addons/efs-csi-driver.yaml`
   - `manifests/addons/s3-csi-driver.yaml` (如有)

### 7.6 参考命令

```bash
# 查看可用 addon 版本
aws eks describe-addon-versions --addon-name aws-efs-csi-driver
aws eks describe-addon-versions --addon-name aws-mountpoint-s3-csi-driver

# 安装 EFS CSI addon
aws eks create-addon \
    --cluster-name ${CLUSTER_NAME} \
    --addon-name aws-efs-csi-driver \
    --configuration-values '{"controller":{"nodeSelector":{"app":"eks-utils"}}}' \
    --resolve-conflicts OVERWRITE
```

---

## 8. 参考资料

- [Ephemeral Storage](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage)
- [XFS Project Quotas](https://www.kernel.org/doc/html/latest/filesystems/xfs-self-describing-metadata.html)
- [EKS Managed Addons](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
