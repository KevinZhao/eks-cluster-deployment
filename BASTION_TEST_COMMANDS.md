# 堡垒机测试命令

## 1. 连接到堡垒机

```bash
aws ssm start-session --target i-02dce60a8f397b6ce --region eu-central-1
```

## 2. 在堡垒机上执行的命令

### 步骤1: 拉取最新代码

```bash
cd /home/ssm-user
# 如果已有项目目录，先拉取最新代码
cd eks-cluster-deployment && git pull origin master
# 或者如果没有，重新克隆
# git clone https://github.com/KevinZhao/eks-cluster-deployment.git
# cd eks-cluster-deployment
```

### 步骤2: 设置环境变量

```bash
export CLUSTER_NAME=eks-frankfurt-test
export AWS_REGION=eu-central-1
```

### 步骤3: 验证kubectl访问

```bash
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
kubectl get nodes
```

### 步骤4: 运行测试脚本

```bash
./scripts/test_karpenter_lvm_fix.sh
```

### 或者手动执行各个步骤:

#### 4a. 应用更新的EC2NodeClass配置

```bash
envsubst < manifests/karpenter/ec2nodeclass-default.yaml | kubectl apply -f -
envsubst < manifests/karpenter/ec2nodeclass-graviton.yaml | kubectl apply -f -
```

#### 4b. 检查现有NodeClaim

```bash
kubectl get nodeclaim -o wide
kubectl get nodeclaim -o yaml
```

#### 4c. 删除失败的NodeClaim (可选)

```bash
# 查看当前的NodeClaim
kubectl get nodeclaim

# 删除特定的NodeClaim (替换为实际名称)
kubectl delete nodeclaim <nodeclaim-name>

# 或删除所有
kubectl delete nodeclaim --all
```

#### 4d. 创建测试部署触发新节点

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      containers:
      - name: pause
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.2
        resources:
          requests:
            cpu: 1
            memory: 1Gi
      nodeSelector:
        karpenter.sh/capacity-type: on-demand
EOF
```

#### 4e. 监控节点创建

```bash
# 监控NodeClaim
watch -n 5 kubectl get nodeclaim -o wide

# 在另一个终端监控节点
kubectl get nodes -w

# 查看Karpenter日志
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

#### 4f. 获取新创建的实例信息

```bash
# 获取NodeClaim详情
NODECLAIM_NAME=$(kubectl get nodeclaim -o jsonpath='{.items[0].metadata.name}')
echo "NodeClaim: $NODECLAIM_NAME"

kubectl describe nodeclaim $NODECLAIM_NAME

# 获取实例ID
INSTANCE_ID=$(kubectl get nodeclaim $NODECLAIM_NAME -o jsonpath='{.status.providerID}' | cut -d'/' -f5)
echo "Instance ID: $INSTANCE_ID"
```

#### 4g. 检查user-data (验证LVM脚本)

```bash
# 获取user-data
aws ec2 describe-instance-attribute \
    --instance-id $INSTANCE_ID \
    --attribute userData \
    --region eu-central-1 \
    --query 'UserData.Value' \
    --output text | base64 -d > /tmp/userdata.txt

# 查看LVM相关部分
grep -A 20 "Auto-detect EBS data disk" /tmp/userdata.txt

# 检查关键行是否正确
grep 'if \[ -z "\$\$(lsblk' /tmp/userdata.txt && echo "✓ User-data looks correct" || echo "✗ User-data may have issues"
```

#### 4h. 检查控制台输出

```bash
# 获取控制台输出
aws ec2 get-console-output \
    --instance-id $INSTANCE_ID \
    --region eu-central-1 \
    --output text > /tmp/console-output.txt

# 查看LVM相关日志
grep -i "lvm\|pvcreate\|vgcreate\|lvcreate\|containerd" /tmp/console-output.txt

# 查看是否有错误
grep -i "error\|fail" /tmp/console-output.txt | grep -v "Starting\|Started"
```

#### 4i. 通过SSM检查节点的LVM配置

```bash
# 等待SSM agent就绪
aws ssm wait command-executed --no-cli-pager

# 检查volume groups
aws ssm send-command \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["vgs"]' \
    --region eu-central-1

# 检查/var/lib/containerd挂载
aws ssm send-command \
    --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["df -h /var/lib/containerd"]' \
    --region eu-central-1

# 或直接登录到节点检查
aws ssm start-session --target $INSTANCE_ID --region eu-central-1
# 在节点内执行:
#   vgs
#   lvs
#   df -h /var/lib/containerd
#   lsblk
```

#### 4j. 验证节点加入集群

```bash
# 检查节点是否注册
kubectl get nodes -l karpenter.sh/capacity-type=on-demand

# 获取节点名称
NODE_NAME=$(kubectl get nodes -o json | jq -r ".items[] | select(.spec.providerID | contains(\"$INSTANCE_ID\")) | .metadata.name")
echo "Node name: $NODE_NAME"

# 查看节点详情
kubectl describe node $NODE_NAME

# 检查节点状态
kubectl get node $NODE_NAME -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

#### 4k. 检查Pod是否调度到新节点

```bash
# 查看测试Pod调度情况
kubectl get pods -o wide | grep karpenter-test

# 查看Pod事件
kubectl describe pods -l app=karpenter-test
```

## 3. 清理测试资源

```bash
# 删除测试deployment
kubectl delete deployment karpenter-test

# 删除NodeClaim (如果需要)
kubectl delete nodeclaim --all

# 或保留节点等待自动缩容
```

## 4. 问题排查

### 如果节点没有加入集群

```bash
# 1. 检查Karpenter日志
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=100

# 2. 检查NodeClaim状态
kubectl get nodeclaim -o yaml

# 3. 检查控制台输出中的错误
aws ec2 get-console-output --instance-id $INSTANCE_ID --region eu-central-1 --output text | grep -i error

# 4. 检查SSM连接
aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --region eu-central-1

# 5. 检查安全组
aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region eu-central-1 \
    --query 'Reservations[0].Instances[0].SecurityGroups'
```

### 如果LVM配置失败

```bash
# 登录到节点
aws ssm start-session --target $INSTANCE_ID --region eu-central-1

# 在节点内手动检查
lsblk
vgs
lvs
df -h /var/lib/containerd
journalctl -u containerd -n 100
cat /var/log/cloud-init-output.log | grep -A 30 "Auto-detect EBS"
```

## 5. 预期结果

### 成功标志:

1. ✓ EC2NodeClass配置成功应用
2. ✓ NodeClaim创建成功
3. ✓ EC2实例启动成功
4. ✓ User-data包含正确的LVM脚本 (使用 `$$(lsblk...)` 内联替换)
5. ✓ 控制台输出显示LVM创建成功
6. ✓ vg_data和lv_containerd创建成功
7. ✓ /var/lib/containerd挂载到LVM卷
8. ✓ 节点成功注册到Kubernetes集群
9. ✓ 节点状态为Ready
10. ✓ Pod可以调度到新节点

### 关键检查点:

**User-data中的LVM脚本应该是:**
```bash
if [ -z "$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)" ]; then
  echo "No data disk found, skip LVM setup"
  ...
fi
pvcreate "$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)"
vgcreate vg_data "$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)"
```

**而不是:**
```bash
if [ -z "$" ]; then  # ✗ 错误
if [ -z "$DATA_DISK" ]; then  # ✗ 变量为空
```

## 6. 快速测试命令 (一键执行)

```bash
# 完整测试流程
cd ~/eks-cluster-deployment && \
git pull origin master && \
export CLUSTER_NAME=eks-frankfurt-test AWS_REGION=eu-central-1 && \
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION} && \
./scripts/test_karpenter_lvm_fix.sh
```
