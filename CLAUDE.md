# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Automated deployment system for production-grade AWS EKS clusters with advanced features including LVM-configured system nodes, Pod Identity authentication, and optional components (Karpenter, CSI drivers for EBS/EFS/FSx/S3, GPU nodes).

**Key Characteristics:**
- **Deployment Environment**: Must run from bastion host inside VPC (private API endpoint)
- **Authentication**: Pod Identity (not IRSA/OIDC) for all AWS service integrations
- **Configuration**: `.env` file-based with auto-detection of AWS credentials and region
- **Architecture**: Sequential numbered scripts for core setup, `option_*` scripts for optional features

## Common Commands

### Core Deployment Sequence

```bash
# 1. Setup environment (sources .env, validates config)
source scripts/0_setup_env.sh

# 2. Enable VPC DNS support
./scripts/1_enable_vpc_dns.sh

# 3. Validate network environment (optional check)
./scripts/2_validate_network_environment.sh

# 4. Create VPC endpoints
./scripts/3_create_vpc_endpoints.sh

# 5. Install EKS cluster control plane (~8-10 min)
./scripts/4_install_eks_cluster.sh

# 6. Check local environment (optional)
./scripts/5_check_environment.sh

# 7. Create system nodegroup with LVM (~8-12 min)
./scripts/6_create_system_nodegroup.sh

# 8. Install core addons (Cluster Autoscaler, LB Controller, EBS CSI, Metrics Server)
./scripts/7_install_eks_addon.sh
```

### Optional Components

```bash
# Create bastion host (if needed for VPC internal access)
./scripts/option_create_bastion.sh

# Install Karpenter for advanced auto-scaling (CPU nodes only)
./scripts/option_install_karpenter.sh

# Install GPU node groups with EFA support (uses Managed Node Groups, not Karpenter)
# By default, this also auto-invokes option_install_gpu_stack.sh at the end
# (GPU_STACK_MODE=standard|operator). Set SKIP_GPU_STACK_AUTO_INSTALL=true to
# install the K8s stack separately.
./scripts/option_install_gpu_nodegroups.sh

# Install ONLY the K8s GPU stack (device-plugin / EFA / monitoring or Operator).
# Idempotent; safe to re-run after switching GPU_STACK_MODE.
GPU_STACK_MODE=standard ./scripts/option_install_gpu_stack.sh
# or
GPU_STACK_MODE=operator ./scripts/option_install_gpu_stack.sh

# Install CSI drivers (EFS, FSx, S3)
# Method 1: Positional arguments
./scripts/option_install_csi_drivers.sh efs      # EFS CSI Driver
./scripts/option_install_csi_drivers.sh fsx      # FSx CSI Driver
./scripts/option_install_csi_drivers.sh s3 <bucket-arns>  # S3 CSI Driver

# Method 2: Environment variables (non-interactive)
INSTALL_DRIVERS=efs ./scripts/option_install_csi_drivers.sh
INSTALL_DRIVERS=fsx ./scripts/option_install_csi_drivers.sh
INSTALL_DRIVERS=s3 S3_BUCKET_ARNS="arn:aws:s3:::bucket1,arn:aws:s3express:region:account:bucket/express-bucket" ./scripts/option_install_csi_drivers.sh

# Test Karpenter node provisioning (example)
./examples/option_test_karpenter_pools.sh

# Test pod scheduling on system nodes (example)
./examples/option_test_pod_scheduling.sh
```

### Cluster Verification

```bash
# Check cluster status
aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}

# Verify nodes
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system

# Verify addons
aws eks list-addons --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}

# Test storage classes
kubectl get storageclass

# View metrics
kubectl top nodes
kubectl top pods -A
```

## Architecture

### Script Organization

**Numbered Scripts (0-7)**: Core deployment sequence that must run in order
- `0_setup_env.sh`: Environment configuration loader and validation functions (always source this first)
- `1-3`: Network infrastructure setup (VPC DNS, validation, endpoints)
- `4`: EKS cluster control plane creation
- `5`: Local environment check (optional; alternative to bastion)
- `6`: System nodegroup creation (with LVM-backed containerd storage)
- `7`: Core addon installation (CoreDNS, Cluster Autoscaler, ALB Controller, EBS CSI, Metrics Server)

**option_* Scripts**: Optional features that can be installed after core deployment
- Can run independently after core setup completes
- Idempotent and safe to re-run

### Pod Identity Architecture

All AWS integrations use **Pod Identity** (not IRSA/OIDC). Helper functions in `pod_identity_helpers.sh`:

```bash
# Key helper functions
create_pod_identity_role <role_name>               # Create IAM role with Pod Identity trust policy
attach_managed_policy <role_name> <policy_arn>     # Attach AWS managed policy
attach_custom_policy <role_name> <policy_name> <policy_document>  # Attach custom policy
create_pod_identity_association <namespace> <sa> <role_arn>   # Associate role with K8s SA
```

**Pattern for adding new components:**
1. Source `0_setup_env.sh` and `pod_identity_helpers.sh`
2. Create IAM role with `create_pod_identity_role`
3. Attach necessary policies
4. Create Pod Identity association
5. Deploy K8s manifests with ServiceAccount

### Directory Structure

```
scripts/                    # Bash scripts for deployment
├── 0_setup_env.sh         # Environment setup (always source first)
├── 1-7_*.sh               # Numbered core scripts
├── option_*.sh            # Optional feature scripts
└── pod_identity_helpers.sh # Pod Identity helper functions

examples/                   # Example/test scripts and manifests
├── option_test_pod_scheduling.sh   # Test pod scheduling
├── option_test_karpenter_pools.sh  # Test Karpenter node pools
└── *.yaml                 # Example workload manifests

manifests/                  # Kubernetes manifests
├── addons/                # Core addons (autoscaler, LB controller, CSI drivers)
├── storage/               # StorageClass definitions
├── karpenter/             # Karpenter EC2NodeClass and NodePool configs (CPU only)
└── iam/                   # IAM policy templates

docs/                      # Additional documentation

# Note: VPC creation uses external terraform-aws-modules/vpc module
# See docs/DEPLOYMENT_SOP.md for recommended configuration
```

### Configuration Files

**`.env`**: Primary configuration file (copy from `.env.example`)
- Required: `CLUSTER_NAME`, `VPC_ID`, subnet IDs
- Auto-detected: `ACCOUNT_ID`, `AWS_REGION`
- Optional: Node sizes, component versions, feature flags

**Environment Variables:**
- `CLUSTER_NAME`: EKS cluster name
- `VPC_ID`: Target VPC
- `PRIVATE_SUBNET_A/B`: Private subnets (required, minimum 2 AZs)
- `PRIVATE_SUBNET_C/D`: Private subnets (optional, for 3-4 AZs)
- `PUBLIC_SUBNET_A/B`: Public subnets (required)
- `PUBLIC_SUBNET_C/D`: Public subnets (optional)
- `INSTALL_KARPENTER`: Enable Karpenter (true/false)
- `INSTALL_EFS_CSI`: Enable EFS CSI driver (true/false)
- `INSTALL_FSX_CSI`: Enable FSx CSI driver (true/false)
- `INSTALL_DRIVERS`: CSI driver type for option_install_csi_drivers.sh (efs/fsx/s3)
- `S3_BUCKET_ARNS`: Comma-separated S3 bucket ARNs for S3 CSI driver
- `SYSTEM_NODE_INSTANCE_TYPE`: System node EC2 instance type
- `K8S_VERSION`: Kubernetes version (default: 1.35)
- `EC2_KEY_NAME`: EC2 Key Pair name for SSH access to system/GPU nodegroups (case-sensitive)
- `SSH_PUBLIC_KEY`: SSH public key content for Karpenter nodes (injected via userData)

### System Nodegroup

System nodes (`app=eks-utils` label) run cluster infrastructure:
- CoreDNS, Cluster Autoscaler, AWS Load Balancer Controller
- EBS CSI Driver, Metrics Server
- Uses LVM configuration: 50GB root + 100GB data volume
- containerd data directory on separate LVM volume for performance

**Important**: All addon manifests use node selectors to schedule on system nodes.

### Storage Configuration

All CSI drivers are optional (via `option_install_csi_drivers.sh`):
- **EBS**: Block storage with gp3 (default) and io2 StorageClasses
- **EFS**: Shared filesystem across pods/nodes
- **FSx**: Lustre for HPC/ML workloads (requires PERSISTENT_2 for AL2023 lustre-client 2.15 compatibility)
- **S3**: Object storage mounting (Standard S3 and S3 Express One Zone, single replica - no HA needed)

## Key Development Patterns

### Adding New Optional Components

1. Create `scripts/option_install_<component>.sh`
2. Source environment and helpers:
   ```bash
   source "${SCRIPT_DIR}/0_setup_env.sh"
   source "${SCRIPT_DIR}/pod_identity_helpers.sh"
   ```
3. Follow Pod Identity pattern for AWS permissions
4. Add manifests to `manifests/addons/` or `manifests/<component>/`
5. Use `sed` to template environment variables into manifests
6. Add system node selectors if component should run on system nodes

### Validation Functions

Available from `0_setup_env.sh` after sourcing:
```bash
verify_kubectl_context                              # Verify kubectl connected to correct cluster
validate_vpc_exists <vpc_id> <region>              # Check VPC exists
validate_subnet_exists <subnet_id> <vpc_id>        # Check subnet exists
validate_ami_exists <ami_id>                       # Check AMI available
validate_security_group_exists <sg_id>             # Check security group
validate_iam_role_exists <role_name>               # Check IAM role
validate_eks_cluster_exists <cluster_name>         # Check EKS cluster
```

### Idempotency

All scripts are designed to be idempotent:
- Check resource existence before creation
- Skip if already exists with appropriate log message
- Safe to re-run after failures

### Error Handling

Scripts use `set -e` and common error handling:
```bash
log "message"           # Info logging with timestamp
error "message"         # Error logging and exit 1
warn "message"          # Warning logging (no exit)
```

## Karpenter Node Support (CPU Only)

**CPU Nodes (Graviton/x86):** `option_install_karpenter.sh`
- EC2NodeClass: `manifests/karpenter/ec2nodeclass-graviton.yaml`, `ec2nodeclass-x86.yaml`
- Graviton (arm64): r/c/m Graviton3+Graviton4 family, 4-16 vCPU, on-demand (example defaults — see manifest header)
- x86 (amd64):      r/c/m Intel 6th+7th gen family, 4-16 vCPU, on-demand
- LVM configuration for containerd data volume

## GPU Node Support (Managed Node Groups)

GPU support is split across two scripts (and two terraform modules) by
responsibility:

**Layer 1 — `option_install_gpu_nodegroups.sh` (AWS infra)**
- Uses AWS Managed Node Groups (not Karpenter) for EFA multi-NIC support
- IAM role + GPU SG (with EFA self-egress) + Launch Template + NodeGroup
- EFA interface counts:
  - p5.48xlarge: 32 ENIs (1 primary + 31 EFA-only)
  - p5en.48xlarge: 16 ENIs (1 primary + 15 EFA-only)
  - p6-b200.48xlarge: 8 ENIs (1 primary + 7 EFA-only)
  - p6-b300.48xlarge: 17 ENIs (1 primary + 16 EFA-only)
  - g7e.48xlarge: 4 ENIs (1 primary + 3 EFA-only)
- Pricing options (mutually exclusive — choose ONE): OD / Spot / ODCR / CB
- LVM configuration for containerd data volume + Instance Store scratch
- Node labels: `workload-type=gpu`, `gpu-instance-type=<type>`, `purchase-option=<od|spot|odcr|cb>`
- Taints: `nvidia.com/gpu:NoSchedule`

**Layer 2 — `option_install_gpu_stack.sh` (K8s workloads)**
- Two mutually-exclusive modes via `GPU_STACK_MODE`:
  - `standard` (default): nvidia-device-plugin + EFA plugin + dcgm-exporter + node-problem-detector + gpu-health-check DS
  - `operator`: NVIDIA GPU Operator (driver/toolkit/mofed disabled) + EFA plugin
- Mode-switch protected by `GPU_STACK_FORCE_SWITCH=true` to auto-uninstall conflicting releases
- Auto-invoked from layer 1 by default; skip with `SKIP_GPU_STACK_AUTO_INSTALL=true`

## Testing and Validation

Test manifests in `examples/`:
- Test pod scheduling (Graviton/x86)
- Various storage test pods (EBS, EFS, S3)
- Karpenter scaling tests

## Important Notes

- **Always run from bastion**: Cluster uses private API endpoint, requires VPC internal access
- **Source 0_setup_env.sh first**: Provides environment variables and helper functions
- **Check kubectl context**: Use `verify_kubectl_context` before kubectl operations
- **System node labels**: `app=eks-utils` label critical for addon scheduling
- **Multi-AZ support**: Supports 2-4 availability zones (minimum: A/B, optional: C, D)
- **Terraform modules**: Used for VPC endpoints and launch templates, but most deployment is bash-driven
- **Documentation**: See `docs/DEPLOYMENT_SOP.md` for detailed step-by-step procedures, `docs/DESIGN.md` for future features
