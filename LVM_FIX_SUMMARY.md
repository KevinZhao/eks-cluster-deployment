# Karpenter LVM Configuration Fix

## Problem

Karpenter-provisioned nodes failed to configure LVM for containerd data disk. The LVM setup script in EC2NodeClass user-data had variable expansion issues.

### Root Cause

The user-data boothook script used `$$` to escape dollar signs in command substitutions:

```bash
if [ -z "$$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)" ]; then
```

During execution, `$$` expanded to the shell's **process ID** (e.g., `2075`) instead of staying as `$`, resulting in:

```bash
if [ -z "2075(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)" ]; then
```

This made the test **always false** (never empty), so the script incorrectly thought no data disk existed and exited early without configuring LVM.

### Evidence

From cloud-init logs on failed node (i-08ac9ed4e18937e9d):
```
2025-12-25 07:37:36,822 - util.py[WARNING]: Boothooks script execution error
Stderr: + '[' -z '2075(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)' ']'
```

Result:
- `vgs` and `lvs` showed no LVM configuration
- `/var/lib/containerd` still on root partition
- Data disk `nvme1n1 100G` attached but unused
- Node failed to join cluster

## Solution

Changed from `$$` to `\$` for escaping dollar signs in command substitutions.

### Fixed Code

**Files modified:**
- [manifests/karpenter/ec2nodeclass-default.yaml](manifests/karpenter/ec2nodeclass-default.yaml)
- [manifests/karpenter/ec2nodeclass-graviton.yaml](manifests/karpenter/ec2nodeclass-graviton.yaml)

**New LVM script (lines 61-80):**
```bash
# Auto-detect EBS data disk (exclude root disk nvme0n1)
if [ -z "\$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)" ]; then
  echo "No data disk found, skip LVM setup"
  systemctl start containerd
  exit 0
fi

# Check if LVM already configured
if vgs vg_data &>/dev/null; then
  echo "LVM already configured"
else
  # Install lvm2 (not installed by default on AL2023)
  dnf install -y lvm2

  # Create LVM using inline disk detection
  pvcreate "\$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)"
  vgcreate vg_data "\$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1)"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd
fi
```

**Key change:** `$$` → `\$`

This ensures `$(command)` is preserved literally in the user-data and executed correctly by the shell at boot time.

## Testing

### Quick Test from Bastion

1. Connect to bastion:
```bash
aws ssm start-session --target i-02dce60a8f397b6ce --region eu-central-1
```

2. Run test script:
```bash
cd ~/eks-cluster-deployment
git pull origin master
export CLUSTER_NAME=eks-frankfurt-test AWS_REGION=eu-central-1
./scripts/test_karpenter_lvm_fix.sh
```

### Verification Steps

The test script will:
1. Apply updated EC2NodeClass configurations
2. Delete old NodeClaims (optional)
3. Create test deployment to trigger provisioning
4. Monitor NodeClaim creation (60 seconds)
5. Check if node joins cluster
6. Fetch instance user-data and verify LVM script syntax
7. Check console output for LVM setup logs
8. Optionally verify LVM via SSM on the node

### Expected Success Indicators

✅ NodeClaim created and instance launched
✅ User-data contains `\$(lsblk...)` (not `2075(lsblk...)`)
✅ Console logs show: `pvcreate`, `vgcreate`, `lvcreate`, `vg_data`
✅ Node registers with cluster (Ready status)
✅ LVM configured on node:
```bash
# On the node via SSM:
vgs      # Should show vg_data
lvs      # Should show lv_containerd
df -h /var/lib/containerd  # Should show /dev/mapper/vg_data-lv_containerd
```

## Related Issues

This fix resolves the node provisioning failures discovered during testing in Frankfurt (eu-central-1).

**Other fixes applied:**
1. Bastion security group and IAM access to EKS API
2. Karpenter IAM permissions for instance profile management
3. Removed non-existent SQS queue configuration from Helm
4. Updated all Karpenter manifests to v1 API

See [BASTION_TEST_COMMANDS.md](BASTION_TEST_COMMANDS.md) for detailed testing procedures.
