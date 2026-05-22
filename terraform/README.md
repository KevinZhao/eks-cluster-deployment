# Terraform — EKS Cluster Deployment

Terraform-native equivalent of the bash scripts under `../scripts/`.
Same end state (private/public EKS cluster, system nodegroup with LVM,
core addons, optional CSI drivers, Karpenter, GPU nodegroups with EFA
multi-NIC), expressed declaratively.

## Layout

```
terraform/
├── bootstrap/                     # Run ONCE per account/region: S3 + DynamoDB for backend
├── backend.tf                     # S3 backend (configured via -backend-config flags)
├── providers.tf                   # aws / kubernetes / helm with EKS exec auth
├── versions.tf
├── variables.tf                   # Mirrors .env.example
├── main.tf                        # Wires modules together
├── outputs.tf
├── terraform.tfvars.example       # Copy to terraform.tfvars
└── modules/
    ├── vpc-endpoints/             # Replaces 1_enable_vpc_dns.sh + 3_create_vpc_endpoints.sh
    ├── eks-cluster/               # Replaces 4_install_eks_cluster.sh
    ├── eks-system-nodegroup/      # Replaces 6_create_system_nodegroup.sh (LVM userdata)
    ├── eks-addons/                # Replaces 7_install_eks_addon.sh (CoreDNS/Metrics/CA/ALB)
    ├── eks-csi-drivers/           # Replaces option_install_csi_drivers.sh (EBS/EFS/FSx/S3)
    ├── eks-karpenter/             # Replaces option_install_karpenter.sh
    └── eks-gpu-nodegroup/         # Replaces option_install_gpu_nodegroups.sh (EFA multi-NIC)
```

## Quick start

```bash
# 0. Bootstrap state backend (once per account/region)
cd terraform/bootstrap
terraform init
terraform apply -var="bucket_name=my-eks-tfstate" -var="region=us-west-2"

# 1. Init root stack with backend config
cd ..
terraform init \
  -backend-config="bucket=my-eks-tfstate" \
  -backend-config="key=eks-cluster-deployment/dev/terraform.tfstate" \
  -backend-config="region=us-west-2" \
  -backend-config="dynamodb_table=my-eks-tfstate-lock"

# 2. Configure variables
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 3. Apply (must be run from inside the cluster's VPC for private mode)
terraform plan
terraform apply
```

Total apply time: ~25-35 minutes (control plane 8-10m, system NG 8-12m,
addons 5-8m, optional GPU NG 10-15m).

## Apply order / module dependencies

Terraform handles ordering automatically via `depends_on` and resource
graph edges, but logically:

1. `vpc-endpoints` (verifies VPC DNS, creates SG + 13 endpoints + S3 gateway)
2. `eks-cluster` (control plane + OIDC + base addons: vpc-cni, kube-proxy, pod-identity-agent)
3. `eks-system-nodegroup` (managed NG with LVM userdata)
4. `eks-addons` (CoreDNS + Metrics Server addons; CA + ALB Controller helm releases)
5. `eks-csi-drivers` (EBS always; EFS/FSx/S3 optional)
6. `eks-karpenter` (optional)
7. `eks-gpu-nodegroup` (optional; AWS-side: IAM/SG/LT with multi-NIC EFA + EKS Managed NodeGroup)
8. `eks-gpu-stack` (optional; K8s-side: device-plugin / EFA / monitoring **or** GPU Operator)

## GPU nodegroups

Replaces the bash `DEPLOY_GPU_OD/SPOT/ODCR/CB` toggles with an explicit
list. Each entry produces one EKS managed node group + matching Launch
Template (with the right number of `efa-only` NICs for the instance type).

```hcl
gpu_nodegroups = [
  { gpu_type = "p5.48xlarge",      purchase_option = "od" },
  { gpu_type = "p5en.48xlarge",    purchase_option = "spot",
    subnet_ids = [var.private_subnet_c] },
  { gpu_type = "p6-b200.48xlarge", purchase_option = "odcr",
    suffix = "-1", subnet_ids = [var.private_subnet_c],
    capacity_reservation_id = "cr-xxxx", placement_group = "cluster" },
  { gpu_type = "p5.48xlarge",      purchase_option = "cb",
    subnet_ids = [var.private_subnet_c],
    capacity_reservation_id = "cr-yyyy" },
]
```

EFA NIC layout per instance type is built into the module (see
`modules/eks-gpu-nodegroup/main.tf` — `local.efa_layout`). Currently
registered:

| Instance | NIC0 type | Extra EFA-only NICs | Notes |
|---|---|---|---|
| `p5.48xlarge` | `efa` | 31 | H100, full multi-NIC |
| `p5en.48xlarge` | `efa` | 15 | H200 |
| `p6-b200.48xlarge` | `efa` | 7 | B200 |
| `p6-b300.48xlarge` | `interface` | 16 | B300; NIC 0 = ENA only |
| `g6e.8xlarge` / `12xlarge` / `16xlarge` | `efa` | 0 | L40S, single NIC |
| `g6e.24xlarge` | `efa` | 1 | L40S, 2 NICs |
| `g6e.48xlarge` | `efa` | 3 | L40S, 4 NICs |
| `g7e.8xlarge` / `12xlarge` | `efa` | 0 | RTX PRO 6000, EFAv4 |
| `g7e.24xlarge` | `efa` | 1 | 2 NICs, EFAv4 |
| `g7e.48xlarge` | `efa` | 3 | 4 NICs, EFAv4, GPUDirect RDMA |

Anything else falls back to `{ efa_only_count = 0, primary_efa = false }`
— LT will provision a plain ENA NIC and skip EFA scaffolding.

## GPU K8s stack (`eks-gpu-stack`)

The K8s-side components live in a separate module so the stack can be
swapped or upgraded without touching nodegroup infra. Two **mutually
exclusive** modes via `gpu_stack_mode`:

| Mode | What it installs |
|---|---|
| `standard` (default) | nvidia-device-plugin · aws-efa-k8s-device-plugin · dcgm-exporter · node-problem-detector · gpu-health-check DS |
| `operator` | NVIDIA GPU Operator (driver/toolkit/mofed disabled to coexist with EKS GPU AMI + AWS EFA plugin) · aws-efa-k8s-device-plugin |

Why mutual exclusion is enforced:

| Conflict | `standard` provides | `operator` provides |
|---|---|---|
| `nvidia.com/gpu` | helm `nvidia-device-plugin` DS | Operator's plugin DS |
| Port 9400 metrics | helm `dcgm-exporter` | Operator's `nvidia-dcgm-exporter` |
| GFD labels | chart-internal GFD sidecar | Operator's GFD DS |
| `/dev/infiniband/uverbs*` | AWS EFA plugin (sole owner) | mofedDriver (forced off) |

Decision table:

| Need | Pick |
|---|---|
| Training, integer GPU requests, EFA + NCCL | `standard` |
| `standard` + Prometheus + boot health-check | `standard` (defaults already cover this) |
| MIG slicing, vGPU, GDS, Confidential Computing | `operator` |
| Don't know yet | `standard` (you can switch later) |

Switching modes:

```bash
# bash
GPU_STACK_MODE=operator GPU_STACK_FORCE_SWITCH=true bash scripts/option_install_gpu_stack.sh

# terraform — flip the variable, plan/apply will retire stale resources of the old mode
gpu_stack_mode = "operator"
```

## What is intentionally NOT in Terraform

These remain as bash scripts under `../scripts/` because they are
verification/operational tools, not infrastructure declarations:

| Script | Why |
|---|---|
| `option_verify_gpu_efa.sh` | Live NCCL benchmark; runs after apply |
| `option_show_nodegroup_topology.sh` | Reads K8s labels and prints inventory |
| `option_create_bastion.sh` | Bastion lifecycle is operator-driven |
| `topology gate` from `option_install_gpu_nodegroups.sh` | Post-create assertion + scale-to-0 rollback is imperative by nature |

Run these against the cluster Terraform created.

## Tearing down — use `scripts/safe-destroy.sh`

The `kubernetes` and `helm` providers in `providers.tf` authenticate
against the cluster via `aws eks get-token` exec auth. This creates an
**implicit coupling**: provider configuration depends on
`module.eks_cluster` outputs, but Terraform's dependency graph does not
treat provider config as an ordinary edge. If the cluster is destroyed
or its API becomes unreachable while there are still helm releases /
K8s resources in state, those resources fail to delete (auth error)
and state gets stuck with orphans.

**Always tear down with the wrapper:**

```bash
cd terraform
./scripts/safe-destroy.sh --var-file terraform.tfvars.test --auto-approve
```

The script:

1. `helm uninstall` every managed release in reverse install order
   (karpenter-pools → karpenter → nvidia-device-plugin → dcgm-exporter →
   node-problem-detector → aws-load-balancer-controller →
   cluster-autoscaler → aws-fsx-csi-driver), plus gpu-operator from
   ns/gpu-operator and the gpu-health-check DaemonSet
2. `kubectl delete serviceaccount` the SAs Terraform created
   (karpenter / cluster-autoscaler / aws-load-balancer-controller /
   fsx-csi-controller-sa) — Pod Identity associations vanish with TF,
   but lingering SAs with stale annotations confuse re-applies
3. `kubectl delete nodepool / ec2nodeclass` (in case the bedag/raw
   helm chart left orphans)
4. `terraform destroy`

**Manual fallback** if the script gets stuck:

```bash
# Find K8s-API-dependent resources still in state
terraform state list | grep -E 'helm_release|kubernetes_'

# If the cluster API is already dead, drop them from state by hand
terraform state rm 'module.eks_addons.helm_release.cluster_autoscaler'
# ...then retry destroy
```

Don't forget the separate `bootstrap-vpc/` stack:
`cd bootstrap-vpc && terraform destroy`.

> **Long-term fix (not in scope for v1)**: split helm/k8s resources
> into a separate Terraform stack that consumes cluster outputs via
> `terraform_remote_state`. This makes destroy ordering explicit (k8s
> stack first, cluster stack second) and decouples plan-time provider
> auth from cluster lifecycle. See the `## What is intentionally NOT
> in Terraform` section for the rationale.

## State and secrets

- All state lives in S3, encrypted, versioned.
- DynamoDB lock prevents concurrent apply.
- KMS key for Secrets envelope-encryption is configured via `kms_key_arn` (recommended).
- Plan/apply must run from a host that can reach the private API endpoint (bastion or VPN).

## Differences vs the bash scripts

The Terraform port deliberately drops a few bash-only features:

- No interactive prompts; all behavior is variable-driven.
- IAM role propagation retries (the `sleep 10` loops) are handled by the AWS provider.
- "Already exists" idempotency hacks disappear — Terraform tracks state.
- Launch Template version management is automatic; bash had to branch on `describe` first.
- The bash topology gate (`verify_topology` with strict scale-to-0 rollback) is not ported.
  Use `option_verify_gpu_efa.sh` after apply instead.
