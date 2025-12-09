# VPC Infrastructure for EKS Cluster

This Terraform configuration creates a highly available VPC infrastructure in AWS Singapore region (ap-southeast-1) with 3 availability zones, designed for EKS cluster deployment.

## Architecture

### Network Design

```
VPC (10.0.0.0/16)
├── ap-southeast-1a
│   ├── Public Subnet (10.0.0.0/24) → Internet Gateway
│   │   └── NAT Gateway A
│   └── Private Subnet (10.0.10.0/24) → NAT Gateway A
│       └── EKS Worker Nodes
├── ap-southeast-1b
│   ├── Public Subnet (10.0.1.0/24) → Internet Gateway
│   │   └── NAT Gateway B
│   └── Private Subnet (10.0.11.0/24) → NAT Gateway B
│       └── EKS Worker Nodes
└── ap-southeast-1c
    ├── Public Subnet (10.0.2.0/24) → Internet Gateway
    │   └── NAT Gateway C
    └── Private Subnet (10.0.12.0/24) → NAT Gateway C
        └── EKS Worker Nodes
```

### Features

- **3 Availability Zones** - High availability across ap-southeast-1a, 1b, and 1c
- **Public Subnets** - For load balancers and NAT Gateways (10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24)
- **Private Subnets** - For EKS worker nodes (10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24)
- **NAT Gateways** - One per AZ for high availability (configurable)
- **Internet Gateway** - For public subnet internet access
- **Kubernetes Tags** - Automatic subnet tagging for EKS integration

## Prerequisites

1. **AWS CLI configured** with credentials
   ```bash
   aws configure
   ```

2. **Terraform installed** (version >= 1.0)
   ```bash
   # Check version
   terraform version
   ```

3. **Appropriate AWS permissions** to create VPC resources

## Quick Start

### 1. Configure Variables

Copy the example configuration:
```bash
cd terraform/vpc
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to customize your configuration:
```hcl
# AWS Region - Singapore
aws_region = "ap-southeast-1"

# Project Configuration
project_name = "my-eks-cluster"
cluster_name = "my-eks-cluster"

# VPC CIDR Block
vpc_cidr = "10.0.0.0/16"

# NAT Gateway Configuration (choose one)
single_nat_gateway = false  # High availability (3 NAT Gateways)
# single_nat_gateway = true   # Cost savings (1 NAT Gateway)
```

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Review the Plan

```bash
terraform plan
```

### 4. Deploy the VPC

```bash
terraform apply
```

Type `yes` when prompted to confirm.

### 5. Get Outputs

After deployment, view the VPC information:
```bash
# View all outputs
terraform output

# View specific output
terraform output vpc_id
terraform output public_subnet_ids
terraform output private_subnet_ids

# Get formatted output for .env file
terraform output -raw env_file_format
```

### 6. Update EKS Configuration

Copy the subnet IDs to your EKS `.env` file:
```bash
# From terraform/vpc directory
terraform output -raw env_file_format >> ../../.env
```

Or manually copy from terraform output:
```bash
VPC_ID=vpc-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_A=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_B=subnet-xxxxxxxxxxxxxxxxx
PUBLIC_SUBNET_C=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_A=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_B=subnet-xxxxxxxxxxxxxxxxx
PRIVATE_SUBNET_C=subnet-xxxxxxxxxxxxxxxxx
```

## Configuration Options

### NAT Gateway Options

**High Availability (Recommended for Production)**
```hcl
single_nat_gateway = false
```
- Creates 3 NAT Gateways (one per AZ)
- Higher cost (~$0.045/hour × 3 = $97/month)
- Full redundancy - if one AZ fails, others continue working

**Cost Optimized (Development/Testing)**
```hcl
single_nat_gateway = true
```
- Creates 1 NAT Gateway in first AZ
- Lower cost (~$0.045/hour = $32/month)
- Single point of failure - if AZ fails, all private subnets lose internet

### Custom CIDR Blocks

Modify the VPC and subnet CIDR blocks:
```hcl
vpc_cidr = "10.0.0.0/16"
```

The configuration automatically creates:
- Public subnets: `10.0.0.0/24`, `10.0.1.0/24`, `10.0.2.0/24`
- Private subnets: `10.0.10.0/24`, `10.0.11.0/24`, `10.0.12.0/24`

## Resources Created

| Resource | Count | Purpose |
|----------|-------|---------|
| VPC | 1 | Main network container |
| Internet Gateway | 1 | Public internet access |
| Public Subnets | 3 | Load balancers, NAT Gateways |
| Private Subnets | 3 | EKS worker nodes |
| NAT Gateways | 1-3 | Private subnet internet access |
| Elastic IPs | 1-3 | NAT Gateway public IPs |
| Route Tables | 4 | Network routing (1 public, 3 private) |

## Cost Estimation

**Monthly costs in ap-southeast-1 region:**

### High Availability Configuration (3 NAT Gateways)
| Resource | Monthly Cost |
|----------|--------------|
| NAT Gateways (3) | ~$97 |
| Data Processing (500GB) | ~$45 |
| **Total** | **~$142** |

### Cost Optimized Configuration (1 NAT Gateway)
| Resource | Monthly Cost |
|----------|--------------|
| NAT Gateway (1) | ~$32 |
| Data Processing (500GB) | ~$45 |
| **Total** | **~$77** |

**Note:** Data transfer costs vary based on usage.

## Outputs

The configuration provides the following outputs:

### VPC Information
- `vpc_id` - VPC ID
- `vpc_cidr` - VPC CIDR block
- `vpc_arn` - VPC ARN

### Subnet Information
- `public_subnet_ids` - List of public subnet IDs
- `private_subnet_ids` - List of private subnet IDs
- `public_subnet_1a`, `public_subnet_1b`, `public_subnet_1c` - Individual public subnet IDs
- `private_subnet_1a`, `private_subnet_1b`, `private_subnet_1c` - Individual private subnet IDs

### Network Components
- `internet_gateway_id` - Internet Gateway ID
- `nat_gateway_ids` - NAT Gateway IDs
- `nat_gateway_public_ips` - NAT Gateway Elastic IPs

### Formatted Output
- `env_file_format` - Formatted output ready for `.env` file

## Integration with EKS

This VPC is designed to work with the EKS cluster deployment in this repository:

1. Deploy the VPC using this Terraform configuration
2. Copy the outputs to `../../.env` file
3. Run the EKS deployment script: `../../scripts/install_eks_cluster.sh`

The subnets are automatically tagged for EKS integration:
- Public subnets: `kubernetes.io/role/elb=1`
- Private subnets: `kubernetes.io/role/internal-elb=1`
- All subnets: `kubernetes.io/cluster/<cluster-name>=shared`

## Validation

### Verify VPC Creation
```bash
# Get VPC ID
VPC_ID=$(terraform output -raw vpc_id)

# Describe VPC
aws ec2 describe-vpcs --vpc-ids $VPC_ID --region ap-southeast-1

# List all subnets
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region ap-southeast-1
```

### Test NAT Gateway Connectivity
```bash
# Launch a test instance in private subnet
# SSH to instance
# Test internet connectivity
curl -I https://www.google.com
```

### Check VPC Flow Logs
```bash
# View flow logs
aws logs tail /aws/vpc/flowlogs/eks-cluster --follow --region ap-southeast-1
```

## Cleanup

To destroy all VPC resources:

```bash
# Review what will be destroyed
terraform plan -destroy

# Destroy resources
terraform destroy
```

**Warning:** Ensure no EKS cluster or other resources are using this VPC before destroying.

## Troubleshooting

### Error: Insufficient NAT Gateway Capacity

If you see capacity errors:
```bash
# Retry the apply
terraform apply
```

NAT Gateway creation can sometimes hit capacity limits. Terraform will retry automatically.

### Error: Subnet CIDR Conflicts

If changing CIDR blocks:
```bash
# Destroy and recreate
terraform destroy
terraform apply
```

### VPC Flow Logs Not Working

Check IAM role permissions:
```bash
# View IAM role
aws iam get-role --role-name eks-cluster-vpc-flow-logs-role
```

## Security Best Practices

- ✅ **Private subnets for worker nodes** - EKS nodes not directly exposed
- ✅ **NAT Gateways for outbound traffic** - Controlled internet access
- ✅ **VPC Flow Logs enabled** - Network traffic monitoring
- ✅ **No hardcoded credentials** - Uses AWS CLI credentials
- ✅ **Least privilege routing** - Separate route tables per subnet type
- ✅ **Multi-AZ deployment** - High availability

## Next Steps

After VPC deployment:

1. ✅ Update `.env` file with VPC and subnet IDs
2. 📝 Review [../../README.md](../../README.md) for EKS deployment
3. 🚀 Deploy EKS cluster: `../../scripts/install_eks_cluster.sh`
4. 🔒 Configure additional security groups as needed
5. 📊 Set up CloudWatch alarms for monitoring

## References

- [AWS VPC Documentation](https://docs.aws.amazon.com/vpc/)
- [EKS VPC Requirements](https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [NAT Gateway Pricing](https://aws.amazon.com/vpc/pricing/)

## Support

For issues related to:
- **VPC configuration**: Check this README and Terraform documentation
- **EKS deployment**: See [../../README.md](../../README.md)
- **AWS costs**: Use [AWS Pricing Calculator](https://calculator.aws/)
