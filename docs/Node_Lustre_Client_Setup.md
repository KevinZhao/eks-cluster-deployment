# EKS节点Lustre客户端自动安装

## 修改内容

### 脚本文件
**文件**: `scripts/6_create_system_nodegroup.sh`

### 修改1: 切换AMI为Amazon Linux 2

**位置**: 第701-707行

**修改前**:
```bash
AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)
```

**修改后**:
```bash
# Use Amazon Linux 2 for FSx Lustre support
AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)
echo "AMI ID: ${AMI_ID} (Amazon Linux 2 for FSx Lustre support)"
```

**原因**: Amazon Linux 2原生支持Lustre客户端，AL2023不支持。

---

### 修改2: 添加Lustre客户端安装

**位置**: 第318-342行（用户数据中）

**新增内容**:
```bash
--==BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
# Install FSx Lustre client
set -ex

echo "=== Installing Lustre Client ==="

# Install Lustre client for Amazon Linux 2
amazon-linux-extras install -y lustre

# Load Lustre kernel module
modprobe lustre

# Verify installation
if lsmod | grep -q lustre; then
  echo "✓ Lustre client installed successfully"
  lsmod | grep lustre
else
  echo "⚠ WARNING: Lustre module not loaded"
fi

echo "=== Lustre Client Installation Complete ==="

--==BOUNDARY==
```

---

## 用户数据结构

完整的Launch Template用户数据现在包含3个部分：

```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook
# 部分1: LVM配置（在EKS bootstrap之前执行）
# - 配置第二块EBS卷作为LVM
# - 挂载到/var/lib/containerd
# - 100GB容器存储空间

--==BOUNDARY==
Content-Type: text/x-shellscript
# 部分2: Lustre客户端安装（新增）
# - 安装lustre包
# - 加载内核模块
# - 验证安装

--==BOUNDARY==
Content-Type: application/node.eks.aws
# 部分3: EKS NodeConfig
# - 集群配置
# - 节点加入集群

--==BOUNDARY==--
```

---

## 验证Lustre客户端安装

### 方法1: 检查日志

SSH到节点后查看安装日志：
```bash
# 查看cloud-init日志
sudo cat /var/log/cloud-init-output.log | grep -A 10 "Installing Lustre Client"

# 查看系统日志
sudo journalctl -u cloud-final | grep -i lustre
```

### 方法2: 检查模块是否加载

```bash
# 检查Lustre内核模块
lsmod | grep lustre

# 验证mount.lustre命令
which mount.lustre

# 检查Lustre版本
modinfo lustre | grep version
```

### 方法3: 从Kubernetes调试

```bash
# 获取节点名称
NODE_NAME=$(kubectl get nodes -l app=eks-utils -o jsonpath='{.items[0].metadata.name}')

# 使用debug pod进入节点
kubectl debug node/${NODE_NAME} -it --image=busybox -- sh

# 在debug pod中
chroot /host bash
lsmod | grep lustre
```

---

## 测试FSx挂载

Lustre客户端安装后，FSx CSI Driver可以正常挂载FSx卷：

```bash
# 部署测试Pod
kubectl apply -f /path/to/fsx-test.yaml

# 检查挂载状态
kubectl get pods -l app=fsx-test
kubectl describe pod fsx-writer

# 查看FSx CSI日志（应该没有错误）
kubectl logs -n kube-system -l app=fsx-csi-node -c fsx-plugin --tail=50
```

---

## 重建节点组流程

如果需要应用这些修改到现有集群：

```bash
# 1. 备份当前工作负载（如有必要）
kubectl get pods --all-namespaces

# 2. 删除现有节点组
eksctl delete nodegroup --cluster=gpu-cluster --name=eks-utils --region=us-east-2

# 3. 重新运行脚本创建节点组
bash scripts/6_create_system_nodegroup.sh

# 4. 验证节点
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.osImage}'

# 5. 验证Lustre客户端
kubectl debug node/<node-name> -it --image=busybox -- sh -c "chroot /host lsmod | grep lustre"
```

---

## 预期输出

### 节点信息
```
NAME                                         STATUS   ROLES    AGE   VERSION
ip-10-200-10-61.us-east-2.compute.internal   Ready    <none>   5m    v1.34.x-eks-xxxxx

OS-IMAGE: Amazon Linux 2
KERNEL-VERSION: 5.10.x-x.x.amzn2.x86_64
```

### Lustre模块
```bash
$ lsmod | grep lustre
lustre               1234567  2
libcfs               123456  3 lustre,ko2iblnd,ksocklnd
```

---

## 参考资料

- [Amazon Linux 2 Lustre Client](https://docs.aws.amazon.com/fsx/latest/LustreGuide/install-lustre-client.html)
- [EKS Optimized Amazon Linux AMI](https://docs.aws.amazon.com/eks/latest/userguide/eks-optimized-ami.html)
- [FSx for Lustre CSI Driver](https://github.com/kubernetes-sigs/aws-fsx-csi-driver)
- [User Data and Cloud-Init](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)

---

## 问题排查

### 问题1: Lustre模块未加载

**检查**:
```bash
dmesg | grep -i lustre
journalctl -xe | grep -i lustre
```

**解决**: 手动加载
```bash
sudo modprobe lustre
```

### 问题2: amazon-linux-extras命令失败

**检查**: 确认OS版本
```bash
cat /etc/os-release
```

**解决**: 只有Amazon Linux 2支持`amazon-linux-extras`

### 问题3: FSx挂载仍然失败

**检查CSI日志**:
```bash
kubectl logs -n kube-system -l app=fsx-csi-node -c fsx-plugin --tail=100
```

**常见错误**:
- `mount.lustre: command not found` - Lustre客户端未安装
- `Invalid argument (exit 22)` - 通常是Lustre客户端问题
- `No such device` - Lustre内核模块未加载
