# FSx for Lustre 在 EKS 上的设置指南

## 问题背景

FSx for Lustre需要在EKS节点上安装Lustre客户端才能挂载文件系统。当前集群使用**Amazon Linux 2023**，该系统对Lustre的支持有限。

## 当前状态

- ✅ FSx CSI Driver已正确安装（Controller + Node DaemonSet）
- ✅ FSx文件系统已创建并可用（fs-097f6673c498e9ccc）
- ❌ 节点缺少Lustre客户端模块，无法挂载FSx卷

## 解决方案

### 方案1: 使用DaemonSet动态安装（测试环境）

**优点**:
- 无需重建节点
- 快速验证

**缺点**:
- AL2023对Lustre支持有限，可能安装失败
- 节点重启后需要重新安装
- 不适合生产环境

**实施步骤**:
```bash
kubectl apply -f manifests/addons/lustre-client-installer.yaml
```

**manifest位置**: `manifests/addons/lustre-client-installer.yaml`

---

### 方案2: 使用Amazon Linux 2 AMI（推荐）

**优点**:
- Amazon Linux 2原生支持Lustre客户端
- 稳定可靠，适合生产环境
- AWS官方支持

**缺点**:
- 需要重建节点组

**实施步骤**:

1. **获取AL2 EKS优化AMI ID**:
```bash
aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.34/amazon-linux-2/recommended/image_id \
  --region us-east-2 \
  --query 'Parameter.Value' \
  --output text
```

2. **修改节点组配置**:

在`scripts/6_create_nodegroups.sh`中修改AMI选择逻辑，或在eksctl配置中指定AMI:

```yaml
nodeGroups:
  - name: system-nodes
    amiFamily: AmazonLinux2  # 从AmazonLinux2023改为AmazonLinux2
    # 或明确指定AMI
    # ami: ami-xxxxxxxxx
```

3. **添加Lustre客户端安装用户数据** (Launch Template):

```bash
#!/bin/bash
# Install Lustre client
amazon-linux-extras install -y lustre
modprobe lustre
```

4. **重建节点组**:
```bash
eksctl delete nodegroup --cluster=gpu-cluster --name=system-nodes --region=us-east-2
bash scripts/6_create_nodegroups.sh
```

---

### 方案3: 自定义Launch Template（灵活方案）

为节点组创建自定义Launch Template，包含Lustre客户端安装脚本。

**实施步骤**:

1. **创建Launch Template**:
```bash
aws ec2 create-launch-template \
  --launch-template-name eks-fsx-nodes \
  --version-description "EKS nodes with Lustre client" \
  --launch-template-data '{
    "UserData": "base64-encoded-user-data-script",
    "ImageId": "ami-xxxxxxxxx"
  }'
```

2. **在eksctl配置中引用Launch Template**:
```yaml
nodeGroups:
  - name: fsx-nodes
    launchTemplate:
      id: lt-xxxxxxxxxxxxx
      version: "$Latest"
```

---

## 验证Lustre客户端安装

在节点上运行以下命令验证:

```bash
# 检查Lustre模块是否加载
lsmod | grep lustre

# 检查mount.lustre命令是否存在
which mount.lustre

# 测试挂载
mount -t lustre fs-097f6673c498e9ccc.fsx.us-east-2.amazonaws.com@tcp:/n6on3bev /mnt/fsx
```

---

## 推荐方案总结

**测试环境**:
- 先尝试方案1（DaemonSet），快速验证
- 如果失败，使用方案2（切换到AL2）

**生产环境**:
- 直接使用方案2（Amazon Linux 2）
- FSx官方推荐使用AL2

---

## 相关资源

- [AWS FSx for Lustre CSI Driver](https://github.com/kubernetes-sigs/aws-fsx-csi-driver)
- [EKS Optimized AMIs](https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html)
- [FSx Lustre Client Installation](https://docs.aws.amazon.com/fsx/latest/LustreGuide/install-lustre-client.html)

---

## 当前集群信息

- **OS**: Amazon Linux 2023.9.20251208
- **Kernel**: 6.12.58-82.121.amzn2023.x86_64
- **FSx File System**: fs-097f6673c498e9ccc (1200 GiB, SCRATCH_2)
- **DNS Name**: fs-097f6673c498e9ccc.fsx.us-east-2.amazonaws.com
- **Mount Name**: n6on3bev
