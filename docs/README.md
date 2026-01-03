# EKS 集群部署文档索引

本目录包含 EKS 集群部署、配置和 CSI Drivers 的完整文档。

## 📚 主要文档

### 🚀 部署指南（推荐从这里开始）

| 文档 | 描述 | 状态 |
|------|------|------|
| [CSI_Drivers_Deployment_Guide.md](CSI_Drivers_Deployment_Guide.md) | **CSI Drivers 完整部署指南**<br>包含 EBS、EFS、FSx、S3 的完整部署方法 | ✅ 最新 |
| [s3-express-onezone-guide.md](s3-express-onezone-guide.md) | **S3 Express One Zone 详细指南**<br>创建、配置、使用 S3 Express directory buckets | ✅ 最新 |

### 📊 测试和验证

| 文档 | 描述 | 状态 |
|------|------|------|
| [CSI_Drivers_Testing_Summary.md](CSI_Drivers_Testing_Summary.md) | **CSI Drivers 测试总结**<br>所有 CSI Drivers 的测试结果和验证报告 | ✅ 已更新 |
| [FSx_Lustre_AL2023_Compatibility_Testing.md](FSx_Lustre_AL2023_Compatibility_Testing.md) | **FSx Lustre AL2023 兼容性测试**<br>详细的兼容性测试结果和发现 | ✅ 有效 |

---

## 🎯 快速导航

### 我想...

#### 部署 CSI Drivers
→ 阅读 [CSI_Drivers_Deployment_Guide.md](CSI_Drivers_Deployment_Guide.md)

这是最全面的部署指南，包含：
- 所有 CSI Drivers 的自动化部署方法
- 详细的配置说明
- 完整的使用示例
- 故障排查指南

#### 使用 S3 Express One Zone
→ 阅读 [s3-express-onezone-guide.md](s3-express-onezone-guide.md)

专门针对 S3 Express One Zone 的完整指南：
- 创建 directory bucket
- 配置 IAM 权限
- 挂载和使用
- 性能优化建议

#### 了解测试结果
→ 阅读 [CSI_Drivers_Testing_Summary.md](CSI_Drivers_Testing_Summary.md)

查看所有 CSI Drivers 的：
- 测试状态
- 性能数据
- 已知问题
- 配置细节

#### 部署 FSx Lustre
→ 阅读 [CSI_Drivers_Deployment_Guide.md](CSI_Drivers_Deployment_Guide.md) 第 3 节

FSx Lustre 完整部署流程：
- 前置条件
- 自动化部署
- 使用示例
- 性能测试

#### 排查 FSx Lustre 兼容性问题
→ 阅读 [FSx_Lustre_AL2023_Compatibility_Testing.md](FSx_Lustre_AL2023_Compatibility_Testing.md)

了解：
- AL2023 与 Lustre 版本兼容性
- 常见错误和解决方案
- 内核要求

---

## 📖 文档状态说明

| 状态 | 含义 |
|------|------|
| ✅ 最新 | 文档反映当前最新配置，推荐使用 |
| ✅ 已更新 | 文档已根据最新部署更新 |
| ✅ 有效 | 文档内容仍然有效和准确 |
| ℹ️ 参考 | 文档提供参考信息，但可能有更新的方法 |

---

## 🔑 关键概念

### CSI Drivers 概述

本项目支持以下 CSI Drivers：

| Driver | 用途 | 访问模式 | 性能特点 |
|--------|------|----------|----------|
| **EBS CSI** | 块存储 | RWO | 低延迟，高 IOPS |
| **EFS CSI** | 文件系统 | RWX | 弹性扩展，共享访问 |
| **FSx Lustre CSI** | 高性能文件系统 | RWX | 极高吞吐量（500+ MB/s） |
| **S3 Mountpoint CSI** | 对象存储 | RWX | S3 Express: 低延迟 |

### 认证方式

所有 CSI Drivers 使用 **EKS Pod Identity** 进行认证：
- 无需管理 IAM User credentials
- 自动轮换凭证
- 细粒度权限控制
- 审计友好

### 部署方式

- **EBS**: EKS Managed Addon (AWS 管理)
- **EFS**: 自定义 Manifest + Pod Identity
- **FSx**: 自定义 Manifest + Pod Identity
- **S3**: 官方 Kustomize + Pod Identity

---

## 🛠️ 相关脚本

### 主要脚本

| 脚本 | 功能 |
|------|------|
| `scripts/option_install_csi_drivers.sh` | CSI Drivers 统一安装脚本 |
| `scripts/pod_identity_helpers.sh` | Pod Identity 配置函数库 |
| `scripts/6_create_system_nodegroup.sh` | 节点组创建（包含 Lustre 客户端） |

### 配置文件

| 文件 | 用途 |
|------|------|
| `manifests/addons/efs-csi-driver.yaml` | EFS CSI Driver 配置 |
| `manifests/addons/fsx-csi-driver.yaml` | FSx CSI Driver 配置 |
| `manifests/storage/storageclass.yaml` | StorageClass 定义 |
| `iam-policies/fsx-csi-policy.json` | FSx IAM 策略模板 |

---

## 📝 最佳实践

### 1. 存储类型选择

- **数据库**: EBS io2 (高 IOPS) 或 gp3 (均衡)
- **共享文件**: EFS (通用) 或 FSx Lustre (高性能)
- **ML 训练**: FSx Lustre (大文件，高吞吐)
- **对象存储**: S3 Express (低延迟) 或 Standard (成本优化)

### 2. 部署建议

1. **先阅读文档**: 从 [CSI_Drivers_Deployment_Guide.md](CSI_Drivers_Deployment_Guide.md) 开始
2. **使用自动化脚本**: 避免手动配置错误
3. **测试验证**: 部署后运行验证命令
4. **查看日志**: 出现问题时检查 pod 日志

### 3. 安全建议

- 使用 Pod Identity 替代 IRSA
- 遵循最小权限原则
- 启用加密（EBS、EFS、FSx 支持）
- 定期审计 IAM 权限

---

## 🔗 外部资源

### AWS 官方文档

- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [EFS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html)
- [FSx for Lustre](https://docs.aws.amazon.com/fsx/latest/LustreGuide/)
- [S3 Express One Zone](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html)

### GitHub Repositories

- [aws-ebs-csi-driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [aws-efs-csi-driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)
- [aws-fsx-csi-driver](https://github.com/kubernetes-sigs/aws-fsx-csi-driver)
- [mountpoint-s3-csi-driver](https://github.com/awslabs/mountpoint-s3-csi-driver)

---

## 📅 更新历史

| 日期 | 更新内容 |
|------|----------|
| 2026-01-03 | 移除过时文档，整合文档结构 |
| 2026-01-02 | 创建文档索引和完整部署指南 |
| 2026-01-02 | 更新 S3 CSI Driver 到 v2.2.2 |
| 2026-01-02 | 添加 S3 Express One Zone 完整指南 |
| 2026-01-02 | 验证所有 CSI Drivers 自动化部署 |

---

## ✨ 贡献

如发现文档问题或需要补充，请：
1. 检查现有文档是否已包含相关信息
2. 参考 [CSI_Drivers_Deployment_Guide.md](CSI_Drivers_Deployment_Guide.md) 的格式
3. 确保包含实际测试的命令和输出

---

## 📧 支持

遇到问题？

1. **检查文档**: 大多数问题在部署指南中都有解决方案
2. **查看日志**: 使用 `kubectl logs` 和 `kubectl describe`
3. **参考故障排查**: [CSI_Drivers_Deployment_Guide.md](CSI_Drivers_Deployment_Guide.md) 包含常见问题
4. **查看测试结果**: [CSI_Drivers_Testing_Summary.md](CSI_Drivers_Testing_Summary.md) 包含已知问题

---

**最后更新**: 2026-01-03
**版本**: 2.1
