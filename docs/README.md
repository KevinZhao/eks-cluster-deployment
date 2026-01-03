# EKS 集群部署文档

## 文档目录

| 文档 | 描述 |
|------|------|
| [DEPLOYMENT_SOP.md](DEPLOYMENT_SOP.md) | 完整部署标准操作流程 |
| [DESIGN.md](DESIGN.md) | 架构设计和技术决策 |
| [COLLABORATION.md](COLLABORATION.md) | 协作和贡献指南 |

## CSI 驱动配置

### 相关脚本

| 脚本 | 功能 |
|------|------|
| `scripts/option_install_csi_drivers.sh` | CSI Drivers 统一安装脚本 |
| `scripts/pod_identity_helpers.sh` | Pod Identity 配置函数库 |

### 配置文件

| 文件 | 用途 |
|------|------|
| `manifests/addons/efs-csi-driver.yaml` | EFS CSI Driver 配置 |
| `manifests/addons/fsx-csi-driver.yaml` | FSx CSI Driver 配置 |
| `manifests/addons/s3-csi-driver.yaml` | S3 CSI Driver 配置 |
| `manifests/storage/storageclass.yaml` | StorageClass 定义 |
| `manifests/iam/fsx-csi-policy.json` | FSx IAM 策略模板 |

## CSI Drivers 概述

| Driver | 用途 | 访问模式 |
|--------|------|----------|
| **EBS CSI** | 块存储 | RWO |
| **EFS CSI** | 文件系统 | RWX |
| **FSx Lustre CSI** | 高性能文件系统 | RWX |
| **S3 Mountpoint CSI** | 对象存储 | RWX |

## 外部资源

- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [EFS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html)
- [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/)
- [S3 Express One Zone](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html)
