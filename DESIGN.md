# EKS Essential Components & GPU Node Support - Design Document

**Version**: 1.0
**Date**: 2025-12-09
**Status**: Draft - Ready for Review

---

## 1. Executive Summary

### 1.1 Overview

This document describes the design for adding essential Kubernetes components and GPU node support to the existing EKS deployment project. The project currently uses AWS Pod Identity architecture (not IRSA) for all AWS service authentication.

### 1.2 Goals

1. Add mandatory components for production readiness (StorageClass, Metrics Server)
2. Add optional components with flexible configuration (Karpenter, FSx CSI, EFS CSI, S3 CSI)
3. Support GPU workloads with P5 instances (p5.48xlarge, p5en.48xlarge)
4. Maintain clean, modular architecture following existing patterns
5. Enable post-cluster configuration for S3 CSI Driver

### 1.3 Non-Goals

- Support for IRSA (project has fully migrated to Pod Identity)
- GPU instances other than P5 family (can be added later)
- Replacement of Cluster Autoscaler (Karpenter is optional, not replacement)

---

## 2. Background

### 2.1 Current Architecture

The project uses:
- **Pod Identity** for AWS service authentication (no OIDC Provider)
- **Helper function pattern** in `pod_identity_helpers.sh` for component setup
- **Modular script design**: Script 4 (basic cluster), Script 6 (custom nodegroup), Script 7 (optional CSI drivers)
- **Manifest-based deployment**: YAML files in `manifests/addons/` and `manifests/cluster/`
- **Terraform for Launch Templates**: Custom node configuration

### 2.2 Existing Components

**Currently installed (mandatory)**:
- Cluster Autoscaler (CA)
- EBS CSI Driver
- AWS Load Balancer Controller

**Currently optional (script 7)**:
- EFS CSI Driver
- S3 CSI Driver

---

## 3. Requirements

### 3.1 Functional Requirements

#### FR1: Mandatory Components
- **FR1.1**: gp3 StorageClass must be installed and set as default
- **FR1.2**: Metrics Server must be installed for HPA/VPA support
- **FR1.3**: Existing default gp2 StorageClass annotation must be removed

#### FR2: Optional Components
- **FR2.1**: Components controlled by individual boolean flags in .env
- **FR2.2**: io2 StorageClass (high-performance) - optional
- **FR2.3**: Karpenter autoscaler - optional, coexists with Cluster Autoscaler
- **FR2.4**: FSx CSI Driver - optional, for Lustre/ONTAP workloads
- **FR2.5**: EFS CSI Driver - optional (move to .env flag control)
- **FR2.6**: S3 CSI Driver - special case (see FR3)

#### FR3: S3 CSI Driver Special Handling
- **FR3.1**: Must be installable AFTER cluster creation
- **FR3.2**: Must accept specific S3 bucket ARN(s) as parameters
- **FR3.3**: Must support updating existing installation with new buckets
- **FR3.4**: Separate standalone script for production use

#### FR4: GPU Node Support
- **FR4.1**: Support P5 family instances (p5.48xlarge, p5en.48xlarge)
- **FR4.2**: 16 EFA-enabled network interfaces (ENI 0: with IP, ENI 1-15: EFA-only)
- **FR4.3**: ENIs distributed across 3 subnets for optimal performance
- **FR4.4**: NVIDIA driver installation (configurable version)
- **FR4.5**: EFA driver installation
- **FR4.6**: NCCL plugin for multi-GPU communication
- **FR4.7**: NVIDIA Device Plugin for GPU discovery
- **FR4.8**: GPU-specific node labels and taints

### 3.2 Non-Functional Requirements

#### NFR1: Configuration Management
- All optional components configurable via `.env` file
- Clear separation of mandatory vs optional components
- Default values for all optional settings

#### NFR2: Consistency
- Follow existing Pod Identity helper function pattern
- Maintain idempotent operations (safe to re-run)
- Consistent logging and error handling

#### NFR3: Documentation
- Comprehensive .env.example with usage instructions
- README documentation for StorageClass usage
- GPU deployment guide with testing instructions

#### NFR4: Performance
- GPU nodes optimized for AI/ML workloads
- High IOPS storage for GPU nodes (16000 IOPS gp3)
- Network optimization for EFA/RDMA traffic

---

## 4. Design

### 4.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     EKS Cluster                              │
│                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐  │
│  │   eks-utils    │  │  app nodegroup │  │ gpu nodegroup│  │
│  │   nodegroup    │  │  (ARM64/x86)   │  │  (P5 + EFA)  │  │
│  │                │  │                │  │              │  │
│  │ • CA           │  │ • User apps    │  │ • GPU apps   │  │
│  │ • ALB Ctrl     │  │ • Workloads    │  │ • 16 ENIs    │  │
│  │ • Metrics Srv  │  │                │  │ • NVIDIA     │  │
│  │ • Karpenter?   │  │                │  │ • EFA        │  │
│  └────────────────┘  └────────────────┘  └──────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │          Storage Classes                              │  │
│  │  • gp3 (default) - General purpose                    │  │
│  │  • io2 (optional) - High performance                  │  │
│  │  • gp2 (existing, not default)                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │          CSI Drivers                                  │  │
│  │  • EBS CSI (mandatory) - Block storage                │  │
│  │  • EFS CSI (optional) - Shared file system            │  │
│  │  • FSx CSI (optional) - High-perf Lustre/ONTAP        │  │
│  │  • S3 CSI (standalone) - Object storage mount         │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ Pod Identity (No OIDC)
                            ↓
                   ┌─────────────────┐
                   │   AWS IAM       │
                   │   Roles         │
                   └─────────────────┘
```

### 4.2 Component Design

#### 4.2.1 StorageClass (Mandatory)

**Design Decision**: Always install gp3 as default, optionally install io2.

**Implementation**:
```yaml
# gp3 (default)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  iops: "3000"
  throughput: "125"
```

**Rationale**:
- gp3 is more cost-effective than gp2 (up to 20% cheaper)
- gp3 provides baseline 3000 IOPS (vs gp2 variable based on size)
- io2 for latency-sensitive workloads (databases, high I/O apps)

**Location**: `manifests/storage/storageclass-gp3.yaml`

#### 4.2.2 Metrics Server (Mandatory)

**Design Decision**: Install Metrics Server with `--kubelet-insecure-tls` for private API servers.

**Implementation**:
- ServiceAccount, RBAC (ClusterRole, ClusterRoleBinding)
- Deployment (2 replicas) with node selector for eks-utils
- APIService registration

**Special Configuration**:
```yaml
args:
  - --kubelet-insecure-tls  # Required for private API server
  - --kubelet-preferred-address-types=InternalIP
```

**Rationale**:
- Required for HPA (Horizontal Pod Autoscaler)
- Required for VPA (Vertical Pod Autoscaler)
- Provides `kubectl top nodes/pods` functionality
- No IAM permissions needed (Kubernetes-native)

**Location**: `manifests/addons/metrics-server.yaml`

#### 4.2.3 Karpenter (Optional)

**Design Decision**: Optional alternative/complementary autoscaler, coexists with Cluster Autoscaler.

**IAM Requirements**:
- Custom IAM policy for EC2, ASG, SSM, Pricing APIs
- Karpenter Node Role (for EC2 instances it launches)
- Instance Profile

**Integration Method**: Helm chart + custom NodePool/EC2NodeClass

**Pod Identity Setup**:
```bash
setup_karpenter_pod_identity() {
    # 1. Create IAM role with custom policy
    # 2. Create Karpenter Node Role (for instances)
    # 3. Create Instance Profile
    # 4. Create Pod Identity Association
}
```

**Configuration**:
- `.env` flag: `INSTALL_KARPENTER=true|false`
- Version configurable: `KARPENTER_VERSION=1.1.0`

**Location**:
- IAM policy: `iam-policies/karpenter-policy.json`
- NodePool: `manifests/addons/karpenter-nodepool.yaml`

#### 4.2.4 FSx CSI Driver (Optional)

**Design Decision**: Support FSx Lustre for high-performance computing workloads.

**IAM Requirements**: Custom policy for FSx operations (DescribeFileSystems, CreateFileSystem, etc.)

**Pod Identity Setup**:
```bash
setup_fsx_csi_pod_identity() {
    # 1. Create IAM role with FSx policy
    # 2. Create ServiceAccount
    # 3. Create Pod Identity Association
}
```

**Integration**: Add to script 7 menu (option 3)

**Location**:
- IAM policy: `iam-policies/fsx-csi-policy.json`
- Manifest: `manifests/addons/fsx-csi-driver.yaml`

#### 4.2.5 S3 CSI Driver (Standalone)

**Design Decision**: Separate standalone script for post-cluster installation with specific bucket permissions.

**Why Standalone**:
- Production deployments need specific bucket ARNs (not wildcard)
- Buckets may not exist at cluster creation time
- Different environments need different bucket access

**Script**: `scripts/add_s3_csi.sh`

**Usage**:
```bash
./scripts/add_s3_csi.sh arn:aws:s3:::my-bucket-1 arn:aws:s3:::my-bucket-2
```

**Features**:
- Accept bucket ARN(s) as command-line arguments
- Validate cluster access
- Support updating existing installation
- Reuse `setup_s3_csi_pod_identity()` helper

#### 4.2.6 GPU Launch Template (New Terraform Module)

**Design Decision**: Separate Terraform module for GPU-specific configuration.

**Directory Structure**:
```
terraform/launch-template-gpu/
├── main.tf          # Launch template with 16 ENIs
├── variables.tf     # GPU-specific variables
├── outputs.tf       # Template ID, ARN, IAM roles
└── userdata.tpl     # Bootstrap script
```

**Network Interface Configuration**:
```hcl
# ENI 0 - Primary with IP assignment
network_interfaces {
  device_index       = 0
  network_card_index = 0
  subnet_id          = var.gpu_subnet_a
  interface_type     = "efa"
  # Gets IP assignment for Kubernetes networking
}

# ENI 1-15 - EFA-only mode (no IP)
dynamic "network_interfaces" {
  for_each = range(1, 16)
  content {
    device_index       = network_interfaces.value
    network_card_index = network_interfaces.value
    subnet_id          = local.eni_subnet_mapping[network_interfaces.value]
    interface_type     = "efa"
    # No IP assignment - pure RDMA traffic
  }
}
```

**ENI Distribution Strategy**:
- ENI 0: Subnet A (primary, with IP)
- ENI 1-7: Subnet B (EFA-only)
- ENI 8-15: Subnet C (EFA-only)

**Rationale**: Distribute ENIs across subnets for:
- Fault tolerance
- Network bandwidth optimization
- Reduced contention on single subnet

**Security Group Configuration**:
- Allow all traffic within security group (required for EFA RDMA)
- Allow traffic from cluster security group

**Volume Configuration**:
- Root volume: 200GB minimum (for drivers and dependencies)
- Optional data volume: 1TB (for models and datasets)
- Type: gp3 with 16000 IOPS, 1000 MB/s throughput

#### 4.2.7 GPU User Data Bootstrap

**Design Decision**: Install drivers during instance launch via user data.

**Bootstrap Steps**:
1. Install NVIDIA driver (configurable version)
2. Install EFA driver
3. Install AWS OFI NCCL plugin (for multi-GPU over EFA)
4. Configure containerd for NVIDIA runtime
5. Configure NCCL environment variables
6. Mount data volume (if exists)
7. Optimize network settings (TCP, BBR)
8. Bootstrap EKS with GPU labels and taints

**NCCL Configuration**:
```bash
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_PROTO=simple
export NCCL_SOCKET_IFNAME=^docker,lo
```

**GPU Labels**:
- `nvidia.com/gpu=true`
- `node.kubernetes.io/instance-type=<type>`
- `eks.amazonaws.com/compute-type=gpu`

**GPU Taints**:
- `nvidia.com/gpu=true:NoSchedule`

**Location**: `terraform/launch-template-gpu/userdata.tpl`

#### 4.2.8 GPU Nodegroup Deployment Script

**Design Decision**: Orchestration script that combines Terraform and eksctl.

**Script**: `scripts/9_create_gpu_nodegroup.sh`

**Workflow**:
```
1. Load .env configuration
2. Verify cluster accessibility
3. Check for existing GPU nodegroup
4. Run Terraform to create launch template
5. Generate eksctl GPU nodegroup manifest
6. Deploy nodegroup with eksctl
7. Wait for nodes to be ready
8. Deploy NVIDIA Device Plugin DaemonSet
9. Verify GPU availability
```

**NVIDIA Device Plugin**:
- DaemonSet deployed to kube-system
- Node selector: `nvidia.com/gpu=true`
- Toleration: `nvidia.com/gpu`
- Exposes GPU resources to Kubernetes scheduler

### 4.3 Configuration Management

#### 4.3.1 .env Configuration

**Structure**:
```bash
# ============================================
# Optional EKS Components Configuration
# ============================================

# Storage
INSTALL_IO2_STORAGECLASS=false
IO2_IOPS=10000

# Autoscaling
INSTALL_KARPENTER=false
KARPENTER_VERSION=1.1.0

# File Systems
INSTALL_EFS_CSI=false
INSTALL_FSX_CSI=false
INSTALL_S3_CSI=false  # Basic setup only, use add_s3_csi.sh for production

# ============================================
# GPU Nodegroup Configuration (Optional)
# ============================================

GPU_INSTANCE_TYPE=p5en.48xlarge
GPU_NODE_GROUP_NAME=gpu-compute

# Driver Versions
NVIDIA_DRIVER_VERSION=550.127.05
EFA_DRIVER_VERSION=latest
NCCL_VERSION=2.22.3

# Volumes
GPU_ROOT_VOLUME_SIZE=200
GPU_DATA_VOLUME_SIZE=1000

# Network (16 ENIs)
GPU_SUBNET_A=${PRIVATE_SUBNET_A}
GPU_SUBNET_B=${PRIVATE_SUBNET_B}
GPU_SUBNET_C=${PRIVATE_SUBNET_C}
```

#### 4.3.2 Configuration Validation

**Location**: `scripts/0_setup_env.sh`

**Validation Functions**:
```bash
# Normalize boolean flags
normalize_bool() {
    local val="${1,,}"
    case "$val" in
        true|1|yes) echo "true" ;;
        *) echo "false" ;;
    esac
}

# Validate io2 IOPS range
if [ "$INSTALL_IO2_STORAGECLASS" = "true" ]; then
    if [ "$IO2_IOPS" -lt 1000 ] || [ "$IO2_IOPS" -gt 64000 ]; then
        warn "IO2_IOPS out of range, using default: 10000"
    fi
fi

# Validate GPU ENI count for P5
if [[ "$GPU_INSTANCE_TYPE" == p5* ]] && [ "$GPU_NUM_ENIS" -ne 16 ]; then
    warn "P5 instances require 16 ENIs, adjusting"
    export GPU_NUM_ENIS=16
fi
```

### 4.4 Integration Points

#### 4.4.1 Script 4 & 6 Integration

**Location**: After EBS CSI setup (around line 86 in script 4, line 170 in script 6)

**Integration Flow**:
```bash
# 6. Setup EBS CSI Driver
setup_ebs_csi_pod_identity

# 6.5. Configure StorageClasses (MANDATORY)
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl apply -f "${PROJECT_ROOT}/manifests/storage/storageclass-gp3.yaml"

if [ "$INSTALL_IO2_STORAGECLASS" = "true" ]; then
    envsubst < "${PROJECT_ROOT}/manifests/storage/storageclass-io2.yaml" | kubectl apply -f -
fi

# 6.6. Install Metrics Server (MANDATORY)
setup_metrics_server

# 6.7. Install Karpenter (OPTIONAL)
if [ "$INSTALL_KARPENTER" = "true" ]; then
    setup_karpenter_pod_identity
    helm install karpenter ...
fi

# 6.8. Install FSx CSI Driver (OPTIONAL)
if [ "$INSTALL_FSX_CSI" = "true" ]; then
    setup_fsx_csi_pod_identity
    kubectl apply -f "${PROJECT_ROOT}/manifests/addons/fsx-csi-driver.yaml"
fi
```

#### 4.4.2 Script 7 Integration

**Update**: Add FSx as option 3

**Menu**:
```
Available drivers:
  1. EFS CSI Driver
  2. S3 CSI Driver
  3. FSx CSI Driver  <-- NEW
  4. Install multiple drivers
  5. Exit
```

#### 4.4.3 Helper Functions

**Location**: `scripts/pod_identity_helpers.sh`

**New Functions**:
```bash
setup_metrics_server()
setup_karpenter_pod_identity()
setup_fsx_csi_pod_identity()
```

**Pattern**:
```bash
setup_<component>_pod_identity() {
    log "Setting up <component> with Pod Identity"

    local role_name="${CLUSTER_NAME}-<component>-role"
    local namespace="kube-system"
    local service_account="<component>-sa"

    create_pod_identity_role "${role_name}"
    attach_managed_policy "${role_name}" "<policy-arn>"
    create_service_account "${namespace}" "${service_account}"
    create_pod_identity_association "${namespace}" "${service_account}" "${role_name}"

    log "✓ <component> Pod Identity setup complete"
}
```

---

## 5. Data Models

### 5.1 Environment Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `INSTALL_IO2_STORAGECLASS` | boolean | false | Install io2 StorageClass |
| `IO2_IOPS` | integer | 10000 | IOPS for io2 volumes (1000-64000) |
| `INSTALL_KARPENTER` | boolean | false | Install Karpenter autoscaler |
| `KARPENTER_VERSION` | string | 1.1.0 | Karpenter version |
| `INSTALL_EFS_CSI` | boolean | false | Install EFS CSI Driver |
| `INSTALL_FSX_CSI` | boolean | false | Install FSx CSI Driver |
| `INSTALL_S3_CSI` | boolean | false | Install S3 CSI Driver (basic) |
| `GPU_INSTANCE_TYPE` | string | p5en.48xlarge | GPU instance type |
| `GPU_NODE_GROUP_NAME` | string | gpu-compute | GPU nodegroup name |
| `GPU_MIN_SIZE` | integer | 0 | Minimum GPU nodes |
| `GPU_DESIRED_SIZE` | integer | 0 | Desired GPU nodes |
| `GPU_MAX_SIZE` | integer | 10 | Maximum GPU nodes |
| `NVIDIA_DRIVER_VERSION` | string | 550.127.05 | NVIDIA driver version |
| `EFA_DRIVER_VERSION` | string | latest | EFA driver version |
| `NCCL_VERSION` | string | 2.22.3 | NCCL version |
| `GPU_ROOT_VOLUME_SIZE` | integer | 200 | Root volume size (GB) |
| `GPU_DATA_VOLUME_SIZE` | integer | 1000 | Data volume size (GB) |
| `GPU_SUBNET_A` | string | ${PRIVATE_SUBNET_A} | Subnet for ENI 0 |
| `GPU_SUBNET_B` | string | ${PRIVATE_SUBNET_B} | Subnet for ENI 1-7 |
| `GPU_SUBNET_C` | string | ${PRIVATE_SUBNET_C} | Subnet for ENI 8-15 |

### 5.2 IAM Policies

#### 5.2.1 Karpenter Controller Policy

**Permissions**:
- EC2: RunInstances, CreateFleet, TerminateInstances, Describe*
- IAM: PassRole, CreateInstanceProfile, TagInstanceProfile
- SSM: GetParameter
- Pricing: GetProducts
- SQS: ReceiveMessage, DeleteMessage (for interruption queue)
- EKS: DescribeCluster

**Resource Restrictions**:
- EC2 instances: Tag-based (`karpenter.sh/cluster`)
- Launch templates: Tag-based
- IAM roles: Specific role name pattern

#### 5.2.2 FSx CSI Driver Policy

**Permissions**:
- FSx: CreateFileSystem, DeleteFileSystem, DescribeFileSystems, UpdateFileSystem, TagResource
- EC2: DescribeSubnets, DescribeNetworkInterfaces, CreateNetworkInterface, DeleteNetworkInterface
- S3: GetObject, PutObject (for FSx Lustre data repository)

**Resource Restrictions**: None (wildcard allowed for FSx)

---

## 6. Implementation Plan

### 6.1 Phase 1: Environment Configuration
**Priority**: High
**Estimated Effort**: 2-3 hours

**Tasks**:
1. Update `.env.example` with all new configuration options
2. Add validation logic to `scripts/0_setup_env.sh`
3. Test configuration loading and validation

**Deliverables**:
- Updated `.env.example` (~80 new lines)
- Updated `scripts/0_setup_env.sh` (~60 new lines)

### 6.2 Phase 2: Mandatory Components
**Priority**: High
**Estimated Effort**: 4-5 hours

**Tasks**:
1. Create `manifests/storage/` directory
2. Create StorageClass manifests (gp3, io2)
3. Create Metrics Server manifest
4. Add helper function for Metrics Server
5. Integrate into scripts 4 & 6

**Deliverables**:
- `manifests/storage/storageclass-gp3.yaml`
- `manifests/storage/storageclass-io2.yaml`
- `manifests/storage/README.md`
- `manifests/addons/metrics-server.yaml`
- Updated `scripts/pod_identity_helpers.sh`
- Updated `scripts/4_install_eks_cluster.sh`
- Updated `scripts/6_install_eks_with_custom_nodegroup.sh`

### 6.3 Phase 3: Optional Components
**Priority**: Medium
**Estimated Effort**: 6-8 hours

**Tasks**:
1. Create Karpenter IAM policy
2. Create Karpenter helper function
3. Create Karpenter NodePool manifest
4. Create FSx IAM policy
5. Create FSx CSI Driver manifest
6. Create FSx helper function
7. Update script 7 with FSx option
8. Integrate optional components into scripts 4 & 6

**Deliverables**:
- `iam-policies/karpenter-policy.json`
- `manifests/addons/karpenter-nodepool.yaml`
- `iam-policies/fsx-csi-policy.json`
- `manifests/addons/fsx-csi-driver.yaml`
- Updated `scripts/pod_identity_helpers.sh` (2 new functions)
- Updated `scripts/7_install_optional_csi_drivers.sh`
- Updated scripts 4 & 6 (optional component integration)

### 6.4 Phase 4: S3 CSI Standalone Script
**Priority**: High
**Estimated Effort**: 3-4 hours

**Tasks**:
1. Create standalone S3 CSI installation script
2. Add command-line argument parsing
3. Add cluster validation
4. Add update support
5. Test with single and multiple buckets

**Deliverables**:
- `scripts/add_s3_csi.sh` (~250 lines)

### 6.5 Phase 5: GPU Launch Template
**Priority**: High
**Estimated Effort**: 8-10 hours

**Tasks**:
1. Create Terraform module directory
2. Create `main.tf` with 16 ENI configuration
3. Create `variables.tf` with GPU-specific variables
4. Create `outputs.tf`
5. Create `userdata.tpl` with driver installation
6. Test launch template creation
7. Verify ENI attachment
8. Test driver installation

**Deliverables**:
- `terraform/launch-template-gpu/main.tf` (~400 lines)
- `terraform/launch-template-gpu/variables.tf` (~150 lines)
- `terraform/launch-template-gpu/outputs.tf` (~100 lines)
- `terraform/launch-template-gpu/userdata.tpl` (~250 lines)

### 6.6 Phase 6: GPU Nodegroup Script
**Priority**: High
**Estimated Effort**: 4-5 hours

**Tasks**:
1. Create GPU nodegroup deployment script
2. Add Terraform orchestration
3. Add eksctl integration
4. Add NVIDIA Device Plugin deployment
5. Add verification steps
6. Test end-to-end GPU node deployment

**Deliverables**:
- `scripts/9_create_gpu_nodegroup.sh` (~300 lines)

### 6.7 Phase 7: Testing & Documentation
**Priority**: High
**Estimated Effort**: 4-6 hours

**Tasks**:
1. Test each component individually
2. Test integration flows
3. Test GPU deployment
4. Update README
5. Create GPU deployment guide
6. Add troubleshooting guide

**Deliverables**:
- Test results documentation
- Updated README
- GPU deployment guide

---

## 7. Testing Strategy

### 7.1 Unit Testing

**StorageClass**:
```bash
# Test gp3 is default
kubectl get storageclass gp3 -o yaml | grep "is-default-class: \"true\""

# Test PVC with default
kubectl apply -f test-pvc.yaml
kubectl get pvc test-pvc

# Test io2 if enabled
kubectl get storageclass io2
```

**Metrics Server**:
```bash
# Test metrics API
kubectl top nodes
kubectl top pods -A

# Test with HPA
kubectl autoscale deployment test-app --cpu-percent=50 --min=1 --max=10
kubectl get hpa
```

**Karpenter**:
```bash
# Verify controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# Test provisioning
kubectl scale deployment inflate --replicas=10
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

### 7.2 Integration Testing

**Full Cluster Deployment**:
```bash
# Test script 4
./scripts/4_install_eks_cluster.sh

# Verify all mandatory components
kubectl get storageclass
kubectl get deployment metrics-server -n kube-system
kubectl get pod-identity-associations
```

**GPU Deployment**:
```bash
# Deploy GPU nodegroup
./scripts/9_create_gpu_nodegroup.sh

# Verify GPU nodes
kubectl get nodes -l nvidia.com/gpu=true

# Test GPU access
kubectl run gpu-test --rm -it --image=nvidia/cuda:12.3.0-base-ubuntu22.04 -- nvidia-smi

# Test EFA
kubectl exec -it gpu-pod -- fi_info -p efa
```

### 7.3 Performance Testing

**GPU Performance**:
- Multi-GPU training test with NCCL
- EFA bandwidth test
- RDMA latency test

**Storage Performance**:
- io2 IOPS verification
- gp3 throughput test

---

## 8. Security Considerations

### 8.1 IAM Permissions

**Principle of Least Privilege**:
- Karpenter: Tag-based restrictions on EC2 resources
- FSx CSI: Only necessary FSx operations
- All roles use Pod Identity trust policy (no OIDC)

### 8.2 Network Security

**GPU Nodes**:
- Security group allows all traffic within itself (required for EFA)
- No public IP assignment
- All communication over private subnets

**EFA**:
- RDMA traffic isolated to cluster security group
- No external access to EFA interfaces

### 8.3 Secrets Management

**Driver Installation**:
- No hardcoded credentials
- All resources fetched from public repositories
- Instance metadata (IMDSv2) used for AWS credentials

---

## 9. Operational Considerations

### 9.1 Monitoring

**Metrics to Monitor**:
- GPU utilization per node
- EFA network throughput
- StorageClass PVC provisioning success rate
- Karpenter provisioning latency

**Tools**:
- Metrics Server for basic metrics
- NVIDIA DCGM for GPU metrics (future enhancement)
- CloudWatch for AWS-level monitoring

### 9.2 Troubleshooting

**Common Issues**:

1. **gp2 still default**: Check annotation removal, verify gp3 has default annotation
2. **Metrics Server TLS errors**: Verify `--kubelet-insecure-tls` flag set
3. **Karpenter not provisioning**: Check IAM PassRole, Node Role exists, EC2NodeClass subnets correct
4. **GPU ENI attachment fails**: Verify subnets have IPs, security group allows all traffic
5. **EFA not working**: Check `fi_info -p efa`, verify NCCL env vars, ensure plugin installed

### 9.3 Maintenance

**Upgrades**:
- Metrics Server: Update image version in manifest
- Karpenter: Update Helm chart version
- CSI Drivers: Update image versions in manifests
- GPU Drivers: Update versions in `.env`, recreate launch template

**Backup/Recovery**:
- All configuration in Git
- IAM roles can be recreated from policies
- Launch templates versioned (no data loss)

---

## 10. Future Enhancements

### 10.1 Short Term (Next 3 months)

1. Support for additional GPU families (P4, G5, G6)
2. NVIDIA DCGM integration for GPU monitoring
3. Automatic driver updates via DaemonSet
4. Multi-AZ GPU nodegroup support

### 10.2 Medium Term (3-6 months)

1. GPU node auto-healing
2. Custom Karpenter provisioner for GPU nodes
3. FSx Lustre integration examples
4. S3 CSI performance optimization

### 10.3 Long Term (6-12 months)

1. Multi-cluster GPU scheduling
2. GPU time-slicing support
3. MIG (Multi-Instance GPU) support for A100/H100
4. Ray/Kubeflow integration

---

## 11. Risks & Mitigations

### 11.1 Technical Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| EFA driver installation timeout | High | Medium | Use Deep Learning AMI with pre-installed drivers |
| P5 ENI attachment failures | High | Low | Comprehensive subnet validation, clear error messages |
| Karpenter conflicts with CA | Medium | Low | Clear documentation on coexistence, separate node groups |
| GPU driver incompatibility | High | Low | Pin specific driver versions, test before deployment |
| S3 CSI performance issues | Medium | Medium | Clear documentation on use cases, recommend EFS for high IOPS |

### 11.2 Operational Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Incorrect .env configuration | Medium | Medium | Validation in 0_setup_env.sh, clear examples in .env.example |
| User installs conflicting components | Low | Low | Documentation on component compatibility |
| Insufficient subnet IPs for 16 ENIs | High | Medium | Pre-deployment validation, clear error messages |

---

## 12. Appendices

### 12.1 File Structure

```
eks-cluster-deployment/
├── .env.example (updated)
├── DESIGN.md (this document)
├── iam-policies/
│   ├── karpenter-policy.json (new)
│   └── fsx-csi-policy.json (new)
├── manifests/
│   ├── addons/
│   │   ├── metrics-server.yaml (new)
│   │   ├── karpenter-nodepool.yaml (new)
│   │   └── fsx-csi-driver.yaml (new)
│   └── storage/ (new directory)
│       ├── storageclass-gp3.yaml (new)
│       ├── storageclass-io2.yaml (new)
│       └── README.md (new)
├── scripts/
│   ├── 0_setup_env.sh (updated)
│   ├── 4_install_eks_cluster.sh (updated)
│   ├── 6_install_eks_with_custom_nodegroup.sh (updated)
│   ├── 7_install_optional_csi_drivers.sh (updated)
│   ├── pod_identity_helpers.sh (updated)
│   ├── add_s3_csi.sh (new)
│   └── 9_create_gpu_nodegroup.sh (new)
└── terraform/
    └── launch-template-gpu/ (new directory)
        ├── main.tf (new)
        ├── variables.tf (new)
        ├── outputs.tf (new)
        └── userdata.tpl (new)
```

### 12.2 References

**AWS Documentation**:
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [EFA User Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [P5 Instances](https://aws.amazon.com/ec2/instance-types/p5/)
- [EBS Volume Types](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)

**Kubernetes Documentation**:
- [Metrics Server](https://github.com/kubernetes-sigs/metrics-server)
- [StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)

**Third-Party Tools**:
- [Karpenter](https://karpenter.sh/)
- [EBS CSI Driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [EFS CSI Driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)
- [FSx CSI Driver](https://github.com/kubernetes-sigs/aws-fsx-csi-driver)
- [S3 CSI Driver](https://github.com/awslabs/mountpoint-s3-csi-driver)

### 12.3 Glossary

- **CA**: Cluster Autoscaler
- **CSI**: Container Storage Interface
- **EBS**: Elastic Block Store
- **EFA**: Elastic Fabric Adapter
- **EFS**: Elastic File System
- **ENI**: Elastic Network Interface
- **FSx**: Amazon FSx (File System)
- **HPA**: Horizontal Pod Autoscaler
- **IOPS**: Input/Output Operations Per Second
- **IRSA**: IAM Roles for Service Accounts (deprecated in this project)
- **NCCL**: NVIDIA Collective Communications Library
- **RDMA**: Remote Direct Memory Access
- **VPA**: Vertical Pod Autoscaler

---

## 13. Approval

**Document Status**: Draft - Ready for Review

**Reviewers**:
- [ ] Project Lead
- [ ] DevOps Team
- [ ] Security Team
- [ ] Platform Engineering Team

**Approval Date**: _____________

**Approved By**: _____________

---

**End of Design Document**
