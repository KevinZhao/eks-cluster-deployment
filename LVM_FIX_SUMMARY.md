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

Three critical issues were discovered and fixed:

### Issue 1: envsubst destroying bash variables (RESOLVED)

### Root Cause Analysis

When using `envsubst` to substitute `${CLUSTER_NAME}` in EC2NodeClass YAML files, it also processes `$DATA_DISK` as:
- `$` (literal dollar sign escape) + `DATA_DISK` (variable to substitute)
- Since `DATA_DISK` environment variable doesn't exist, result is: `$DATA_DISK` → `$`

Evidence from bastion testing:
```bash
# YAML contains:
DATA_DISK=$(lsblk...)
if [ -z "$DATA_DISK" ]; then

# After envsubst:
DATA_DISK=$(lsblk...)  # First occurrence preserved
if [ -z "$" ]; then     # ❌ Subsequent $DATA_DISK became just $
```

### Issue 2: rsync command not found (RESOLVED)

**Problem**: AL2023 doesn't have `rsync` installed by default.
- Boothook script failed with exit code 127: "rsync: command not found"
- Script successfully created LVM but failed during data migration
- Volume mounted at /mnt/runtime/containerd but not migrated to final location

**Solution**: Replace `rsync -aHAX` with `cp -a` which is available by default.

### Issue 3: Root disk misidentification (RESOLVED - CRITICAL)

**Problem**: Script detected root disk (/dev/nvme0n1) as data disk, causing `pvcreate` failure (exit code 5).

**Root cause**:
```bash
# findmnt returns: /dev/nvme0n1p1
# After sed 's/[0-9]*$//' becomes: /dev/nvme0n1p (still has 'p')
ROOT_DEV="$(findmnt -no SOURCE / | sed 's/[0-9]*$//' || echo nvme0n1)"
# awk receives double /dev/ prefix: /dev//dev/nvme0n1p
DISK="$(lsblk -dpno NAME,TYPE | awk -v r="/dev/$ROOT_DEV" '$2=="disk" && $1!=r {print $1; exit}' || true)"
```

**Solution**:
- Use `sed 's/p\?[0-9]*$//'` to strip partition suffix with 'p' prefix
- Remove duplicate /dev/ prefix in awk command
- Update fallback to include /dev/ prefix

### Fixed Code

**Files modified:**
- [manifests/karpenter/ec2nodeclass-x86.yaml](manifests/karpenter/ec2nodeclass-x86.yaml) - All fixes applied
- [manifests/karpenter/ec2nodeclass-graviton.yaml](manifests/karpenter/ec2nodeclass-graviton.yaml) - All fixes applied
- [scripts/10_install_karpenter.sh](scripts/10_install_karpenter.sh) - Changed from envsubst to sed

**Final working LVM script (preserves AMI cached images):**
```bash
# Stop containerd first
systemctl stop containerd || true

# Auto-detect EBS data disk (exclude root disk)
# Get root device first, then find the first non-root NVMe disk
ROOT_DEV="$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//' || echo /dev/nvme0n1)"
DISK="$(lsblk -dpno NAME,TYPE | awk -v r="$ROOT_DEV" '$2=="disk" && $1!=r {print $1; exit}' || true)"

if [ -z "$DISK" ]; then
  echo "No data disk found, skip LVM setup"
  systemctl start containerd
  exit 0
fi

echo "Found data disk: $DISK"

# Check if LVM already configured
if vgs vg_data &>/dev/null; then
  echo "LVM already configured"
else
  # Install lvm2 (not installed by default on AL2023)
  dnf install -y lvm2

  # Create LVM
  pvcreate "$DISK"
  vgcreate vg_data "$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd
fi

# Mount LV to temporary directory and migrate data
TEMP_MOUNT="/mnt/runtime/containerd"
mkdir -p "$TEMP_MOUNT"

echo "Mounting LV to temporary directory: $TEMP_MOUNT"
mount /dev/vg_data/lv_containerd "$TEMP_MOUNT"

echo "Copying containerd data (including cached images) from AMI..."
cp -a /var/lib/containerd/. "$TEMP_MOUNT/"

echo "Unmounting temporary directory"
umount "$TEMP_MOUNT"

echo "Mounting LV to final destination: /var/lib/containerd"
mount /dev/vg_data/lv_containerd /var/lib/containerd

# Add to fstab for persistence
grep -q "lv_containerd" /etc/fstab || \
  echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab

echo "Containerd data migration completed"
df -h /var/lib/containerd

# Start containerd with migrated data
systemctl start containerd
```

**Key advantages:**
- Uses `cp -a` instead of rsync (available by default on AL2023)
- Correctly identifies data disk vs root disk
- Preserves all AMI-cached images (pause, kube-proxy, aws-node, etc.)
- Prevents "localhost/kubernetes/pause not found" errors

**Deployment method (uses sed instead of envsubst):**
```bash
# In scripts/9_install_karpenter.sh:
sed "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" "${PROJECT_ROOT}/manifests/karpenter/ec2nodeclass-default.yaml" | kubectl apply -f -
sed "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" "${PROJECT_ROOT}/manifests/karpenter/ec2nodeclass-graviton.yaml" | kubectl apply -f -
```

**Key change:** Replace `envsubst` with `sed` that only substitutes `${CLUSTER_NAME}`

This ensures all bash variables (`$DATA_DISK`, `$?`, etc.) in the user-data script are preserved intact.

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
✅ User-data contains `$(lsblk...)` with single dollar sign
✅ Console logs show: rsync migration and LVM setup (`pvcreate`, `vgcreate`, `lvcreate`)
✅ Node registers with cluster (Ready status)
✅ LVM configured on node with migrated data:
```bash
# On the node via SSM:
vgs      # Should show vg_data ~100GB
lvs      # Should show lv_containerd
df -h /var/lib/containerd  # Should show /dev/mapper/vg_data-lv_containerd
ctr -n k8s.io images ls | grep pause  # Should show cached pause images
```

##  Verification - Final Working State

Successfully tested on Frankfurt cluster (eks-frankfurt-test):

**x86 Node (i-0516b479359256bef / ip-10-3-12-97)**:
```
VG: vg_data (100GB)
LV: lv_containerd (100GB, mounted at /var/lib/containerd)
fstab: /dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2
Disks: nvme0n1 (50G root) + nvme1n1 (100G data/LVM)
Status: Node Ready, all pods Running
```

**Graviton Node (i-080ed8ab9a44bc58e / ip-10-3-12-72)**:
```
VG: vg_data (100GB)
LV: lv_containerd (100GB, mounted at /var/lib/containerd)
Cached images: pause, kube-proxy, aws-node (preserved from AMI)
Status: Node Ready, all pods Running
```

## Problems Encountered and Solutions Summary

### Problem 1: envsubst destroying bash variables (FIXED)
**Solution:** Replace `envsubst` with `sed` that only substitutes `${CLUSTER_NAME}`

### Problem 2: rsync command not found (FIXED)
**Solution:** Replace `rsync -aHAX` with `cp -a` (available by default)

### Problem 3: Root disk misidentification - CRITICAL (FIXED)
**Solution:** Fix sed pattern and awk command to correctly identify root device

## Related Issues

This fix resolves the node provisioning failures discovered during testing in Frankfurt (eu-central-1).

**Other fixes applied:**
1. Bastion security group and IAM access to EKS API
2. Karpenter IAM permissions for instance profile management
3. Removed non-existent SQS queue configuration from Helm
4. Updated all Karpenter manifests to v1 API
5. Created EKS access entry for KarpenterNodeRole
