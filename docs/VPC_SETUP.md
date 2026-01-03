# VPC Setup for EKS

This project assumes an existing VPC. Use [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) for VPC creation.

## Recommended Configuration

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false  # Production: one NAT per AZ
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS required tags
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "public_subnets" {
  value = module.vpc.public_subnets
}
```

## EKS Requirements

| Requirement | Description |
|-------------|-------------|
| DNS Support | `enable_dns_support = true` |
| DNS Hostnames | `enable_dns_hostnames = true` |
| Public Subnet Tags | `kubernetes.io/role/elb = 1` |
| Private Subnet Tags | `kubernetes.io/role/internal-elb = 1` |
| NAT Gateway | Required for private subnet internet access |

## After VPC Creation

Update `.env` with VPC outputs:

```bash
VPC_ID=vpc-xxxxxxxxx
PRIVATE_SUBNET_A=subnet-xxxxxxxxx
PRIVATE_SUBNET_B=subnet-xxxxxxxxx
PRIVATE_SUBNET_C=subnet-xxxxxxxxx
PUBLIC_SUBNET_A=subnet-xxxxxxxxx
PUBLIC_SUBNET_B=subnet-xxxxxxxxx
PUBLIC_SUBNET_C=subnet-xxxxxxxxx
```

## References

- [terraform-aws-modules/vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc)
- [AWS EKS VPC Requirements](https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html)
- [EKS Blueprints](https://github.com/aws-ia/terraform-aws-eks-blueprints)
