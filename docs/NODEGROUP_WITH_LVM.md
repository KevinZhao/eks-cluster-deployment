# EKS 系统节点组 LVM 配置指南

## 概述

本文档说明如何创建配置了 LVM 的 EKS 系统节点组，用于将 containerd 运行时存储在独立的 100GB LVM 卷上。

## 推荐方案：使用外部 Launch Template（脚本 9）

**脚本**：[scripts/9_replace_system_nodegroup.sh](../scripts/9_replace_system_nodegroup.sh)

### 优点

✅ **最稳定可靠** - user-data 不经过任何模板替换，完全避免变量转义问题
✅ **与 Karpenter 一致** - 使用相同的 MIME multipart + cloud-boothook 格式
✅ **完全控制** - Launch Template 通过 AWS CLI 创建，所有参数可定制
✅ **版本管理** - 支持 Launch Template 版本控制，便于回滚

### 工作原理

1. **创建 Launch Template**：使用 AWS CLI 创建包含 LVM 配置的 Launch Template
2. **User-Data 格式**：使用 MIME multipart 格式，cloud-boothook 部分在 EKS bootstrap 前执行
3. **LVM 配置**：
   - 自动检测数据盘（排除根盘 nvme0n1）
   - 安装 lvm2
   - 创建 VG `vg_data` 和 LV `lv_containerd`
   - 使用 rsync 迁移 containerd 数据（保留 AMI 缓存的镜像）
   - 挂载到 `/var/lib/containerd`
   - 添加 fstab 条目持久化
4. **eksctl 引用**：生成 eksctl 配置引用 Launch Template ID 和版本

### 使用方法

```bash
cd /home/ec2-user/workspace/eks-cluster-deployment
./scripts/9_replace_system_nodegroup.sh
```

### 配置详情

**磁盘配置**：
- 根盘：50GB gp3（系统）
- 数据盘：100GB gp3，3000 IOPS，125 MBps（containerd）

**节点配置**：
- 实例类型：m8g.large (Graviton4, ARM64)
- AMI：EKS optimized AL2023 for ARM64
- 节点数：3 (min: 3, max: 6)
- 标签：
  - `app=eks-utils`
  - `arch=arm64`
  - `node-group-type=system`

**LVM 配置**：
- Volume Group: `vg_data`
- Logical Volume: `lv_containerd`
- 文件系统：XFS
- 挂载点：`/var/lib/containerd`

## 验证 LVM 配置

在节点上检查：

```bash
# 查看 LVM 状态
vgs
lvs

# 查看挂载点
df -h /var/lib/containerd

# 查看 fstab
grep containerd /etc/fstab

# 查看 LVM 设置日志
cat /var/log/lvm-setup.log
```

预期输出：

```
VG      #PV #LV #SN Attr   VSize    VFree
vg_data   1   1   0 wz--n- <100.00g    0

LV           VG      Attr       LSize    Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
lv_containerd vg_data -wi-ao---- <100.00g

Filesystem                    Size  Used Avail Use% Mounted on
/dev/mapper/vg_data-lv_containerd  100G  4.2G   96G   5% /var/lib/containerd

/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2
```

## 关键技术细节

### 为什么使用外部 Launch Template？

eksctl 的 `preBootstrapCommands` 存在变量替换问题：
- `$$VAR` → eksctl 处理成 `$` 或 `$VAR`，破坏 bash 语法
- 单 `$VAR` → 在某些情况下被 envsubst 误处理

使用外部 Launch Template：
- User-data 在 HEREDOC 中定义，使用 `'EOF'` 引号防止 shell 处理
- 通过 AWS CLI 的 `base64` 编码传递，不经过任何文本处理
- eksctl 只引用 Launch Template ID，不处理其内容

### MIME Multipart 格式

```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
# LVM setup script here

--==BOUNDARY==--
```

**cloud-boothook** 类型的脚本：
- 在每次启动时执行（不仅首次）
- 在 cloud-init 的其他阶段之前运行
- 在 EKS bootstrap 之前执行，适合配置基础设施

### rsync 数据迁移

使用 `rsync -aHAX` 迁移 containerd 数据的优势：
- 保留 AMI 中缓存的镜像（pause, kube-proxy, aws-node 等）
- 避免首次启动时拉取镜像
- 防止 "localhost/kubernetes/pause not found" 错误
- 保留所有文件属性、权限、硬链接

## 故障排查

### 节点创建但 LVM 未配置

1. **检查日志**：
   ```bash
   kubectl debug node/<node-name> -it --image=busybox:1.36 -- \
     chroot /host cat /var/log/lvm-setup.log
   ```

2. **检查数据盘**：
   ```bash
   kubectl debug node/<node-name> -it --image=busybox:1.36 -- \
     chroot /host lsblk
   ```
   应该看到 `nvme1n1 100G`

3. **检查 Launch Template**：
   ```bash
   aws ec2 describe-launch-template-versions \
     --launch-template-id <lt-id> \
     --region eu-central-1
   ```

### LVM 配置失败

常见原因：
- 数据盘未附加（检查 BlockDeviceMappings）
- lvm2 安装失败（网络问题）
- 磁盘已有数据（pvcreate 失败）

## 与 Karpenter 的一致性

Karpenter 使用相同的技术栈：
- EC2NodeClass 的 userData 也使用 MIME multipart 格式
- 相同的 LVM 配置脚本
- 相同的 rsync 数据迁移逻辑
- 相同的磁盘命名（/dev/xvdb）

参考：
- [manifests/karpenter/ec2nodeclass-default.yaml](../manifests/karpenter/ec2nodeclass-default.yaml)
- [manifests/karpenter/ec2nodeclass-graviton.yaml](../manifests/karpenter/ec2nodeclass-graviton.yaml)

## 参考资料

- [EKS Best Practices - Custom Launch Templates](https://aws.github.io/aws-eks-best-practices/cluster-autoscaling/launch-templates/)
- [cloud-init Documentation](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#bootcmd)
- [eksctl Launch Template Support](https://eksctl.io/usage/launch-templates/)
