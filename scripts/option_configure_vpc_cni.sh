#!/bin/bash

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "=== Configure VPC CNI Settings ==="

# 1. 设置环境变量
source "${SCRIPT_DIR}/0_setup_env.sh"

# 2. 显示当前配置
echo ""
echo "Step 1: Checking current VPC CNI configuration..."
CURRENT_CONFIG=$(aws eks describe-addon \
    --cluster-name ${CLUSTER_NAME} \
    --addon-name vpc-cni \
    --region ${AWS_REGION} \
    --query 'addon.configurationValues' \
    --output text 2>/dev/null)

if [ "$CURRENT_CONFIG" = "None" ] || [ -z "$CURRENT_CONFIG" ]; then
    echo "Current configuration: (default)"
else
    echo "Current configuration:"
    echo "$CURRENT_CONFIG" | jq . 2>/dev/null || echo "$CURRENT_CONFIG"
fi

# 3. 显示将要应用的配置
echo ""
echo "Step 2: Preparing new VPC CNI configuration..."
echo ""
echo "📋 Configuration to be applied:"
echo "  - AWS_VPC_K8S_CNI_EXTERNALSNAT: false (禁用 SNAT)"
echo "  - WARM_ENI_TARGET: 0 (不预留整个 ENI)"
echo "  - WARM_IP_TARGET: 5 (预留 5 个 IP)"
echo "  - MINIMUM_IP_TARGET: 3 (最少保持 3 个 IP)"
echo ""
echo "💡 说明："
echo "  - EXTERNALSNAT=false: Pod 使用主 IP 直接访问外部，不做 NAT 转换"
echo "  - WARM_ENI_TARGET=0: 不预留整个 ENI，节省 IP"
echo "  - WARM_IP_TARGET=5: 预留 5 个 IP 用于快速启动 Pod"
echo "  - MINIMUM_IP_TARGET=3: 保证至少 3 个可用 IP"
echo ""
echo "  ✅ 优势: 节省 IP (相比默认节省 67%)，Pod 启动快"
echo "  - 要求: 必须有正确的路由表配置（通过 NAT Gateway 或 VPC Peering）"
echo ""

# 4. 确认是否继续
read -p "是否继续应用配置? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "操作已取消"
    exit 0
fi

# 5. 创建配置文件
echo ""
echo "Step 3: Creating VPC CNI configuration..."
cat > /tmp/vpc-cni-config.json <<EOF
{
  "env": {
    "AWS_VPC_K8S_CNI_EXTERNALSNAT": "false",
    "WARM_ENI_TARGET": "0",
    "WARM_IP_TARGET": "5",
    "MINIMUM_IP_TARGET": "3"
  }
}
EOF

echo "Configuration file created:"
cat /tmp/vpc-cni-config.json | jq .

# 6. 更新 VPC CNI addon
echo ""
echo "Step 4: Updating VPC CNI addon..."
aws eks update-addon \
    --cluster-name ${CLUSTER_NAME} \
    --addon-name vpc-cni \
    --configuration-values file:///tmp/vpc-cni-config.json \
    --resolve-conflicts OVERWRITE \
    --region ${AWS_REGION}

echo "✓ Update command sent"

# 7. 等待更新完成
echo ""
echo "Step 5: Waiting for addon update to complete..."
for i in {1..60}; do
    ADDON_STATUS=$(aws eks describe-addon \
        --cluster-name ${CLUSTER_NAME} \
        --addon-name vpc-cni \
        --region ${AWS_REGION} \
        --query 'addon.status' \
        --output text 2>/dev/null)

    if [ "$ADDON_STATUS" = "ACTIVE" ]; then
        echo "✓ VPC CNI addon is ACTIVE"
        break
    elif [ "$ADDON_STATUS" = "UPDATE_FAILED" ]; then
        echo "❌ VPC CNI addon update failed"
        aws eks describe-addon \
            --cluster-name ${CLUSTER_NAME} \
            --addon-name vpc-cni \
            --region ${AWS_REGION} \
            --query 'addon.health'
        exit 1
    else
        echo "Waiting... (Status: $ADDON_STATUS, attempt $i/60)"
        sleep 5
    fi
done

# 8. 重启 VPC CNI pods 使配置生效
echo ""
echo "Step 6: Restarting VPC CNI pods to apply new configuration..."
kubectl rollout restart daemonset aws-node -n kube-system
kubectl rollout status daemonset aws-node -n kube-system --timeout=180s

# 9. 验证配置
echo ""
echo "Step 7: Verifying new configuration..."
echo ""
echo "Checking environment variables in VPC CNI pods:"
POD_NAME=$(kubectl get pods -n kube-system -l k8s-app=aws-node -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system ${POD_NAME} -- env | grep -E "AWS_VPC_K8S_CNI_EXTERNALSNAT|WARM_ENI_TARGET|WARM_IP_TARGET|MINIMUM_IP_TARGET" || echo "Note: Variables may not show if using default values"

# 10. 清理临时文件
rm -f /tmp/vpc-cni-config.json

# 11. 完成
echo ""
echo "=== VPC CNI Configuration Update Complete ==="
echo ""
echo "✓ SNAT disabled: Pods will use their VPC IP directly"
echo "✓ IP warm pool optimized: Preload 5 IPs, minimum 3 IPs"
echo "✓ ENI allocation optimized: No pre-allocated ENIs (save ~67% IPs)"
echo ""
echo "⚠️  Important Notes:"
echo "  1. Ensure your route tables allow Pod CIDR to reach internet via NAT Gateway"
echo "  2. Security groups must allow traffic from Pod IPs"
echo "  3. Test connectivity: kubectl run test-pod --image=nginx --rm -it -- curl -I https://www.google.com"
echo ""
echo "To verify VPC CNI settings:"
echo "  kubectl get daemonset aws-node -n kube-system -o yaml | grep -A 5 WARM"
echo ""
