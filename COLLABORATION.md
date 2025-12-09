# 协作指南

本项目使用 GitHub 协作者（Collaborators）方式进行团队协作。

## 🔐 添加协作者（项目维护者操作）

### 步骤：

1. 访问项目设置页面：
   https://github.com/KevinZhao/eks-cluster-deployment/settings/access

2. 点击 **"Collaborators"** → **"Add people"**

3. 输入协作者的 GitHub 用户名或邮箱

4. 选择权限级别：
   - **Write** (推荐) - 可以推送代码，管理 issues
   - **Maintain** - 可以管理项目设置（不常用）
   - **Admin** - 完全控制（慎用）

5. 点击 **"Add to this repository"**

6. 协作者会收到邮件邀请

---

## 👥 协作者入门指南

### 1. 接受邀请

- 查看 GitHub 邮箱收到的邀请链接
- 点击 "Accept invitation"
- 现在你可以直接访问项目

### 2. 克隆仓库

```bash
git clone https://github.com/KevinZhao/eks-cluster-deployment.git
cd eks-cluster-deployment
```

### 3. 配置 Git 身份

```bash
git config user.name "你的名字"
git config user.email "你的邮箱"
```

### 4. 开始工作

#### 方式 A: 直接在 master 分支工作（小改动）

```bash
# 拉取最新代码
git pull origin master

# 进行修改
vim scripts/some_script.sh

# 提交
git add .
git commit -m "fix: 修复某个问题"

# 推送
git push origin master
```

#### 方式 B: 使用功能分支（推荐用于大改动）

```bash
# 创建新分支
git checkout -b feature/add-monitoring

# 进行修改
vim scripts/monitoring.sh

# 提交
git add .
git commit -m "feat: 添加监控功能"

# 推送到远程
git push origin feature/add-monitoring

# 在 GitHub 上创建 Pull Request 合并到 master
```

---

## 📋 工作流程规范

### 提交前检查

- [ ] 测试你的修改
- [ ] 确保脚本可以正常运行
- [ ] 遵循项目代码风格
- [ ] 写清晰的提交信息

### 提交信息规范

```bash
# 格式
类型: 简短描述

# 类型：
feat:     新功能
fix:      Bug 修复
docs:     文档修改
refactor: 代码重构
test:     测试相关

# 示例
git commit -m "feat: 添加 EFS CSI Driver 支持"
git commit -m "fix: 修复 Pod Identity 超时问题"
git commit -m "docs: 更新 README 安装说明"
```

### 冲突解决

如果推送时遇到冲突：

```bash
# 拉取最新代码
git pull origin master

# 解决冲突（编辑冲突文件）
vim conflicted_file.sh

# 标记冲突已解决
git add conflicted_file.sh

# 完成合并
git commit -m "merge: 解决冲突"

# 推送
git push origin master
```

---

## 🔄 保持代码同步

每次开始工作前，先同步最新代码：

```bash
# 查看当前状态
git status

# 如果有未提交的修改，先提交或暂存
git stash  # 暂存当前修改

# 拉取最新代码
git pull origin master

# 恢复暂存的修改
git stash pop
```

---

## 🚫 注意事项

### 不要提交的文件

- `.env` - 包含敏感配置
- `*.pem` - SSH 密钥
- `*.tfstate` - Terraform 状态文件
- `*_final.yaml` - 临时生成的文件

这些文件已在 `.gitignore` 中配置。

### 敏感信息处理

如果需要配置文件：
1. 使用 `.env.example` 作为模板
2. 创建自己的 `.env` 文件（不提交）
3. 在文档中说明配置方法

---

## 🧪 测试建议

修改脚本后的测试流程：

```bash
# 1. 配置测试环境
cp .env.example .env
vim .env  # 填写测试配置

# 2. 运行脚本
./scripts/4_install_eks_cluster.sh

# 3. 验证集群
kubectl get nodes
kubectl get pods -A

# 4. 验证 Pod Identity
aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME}

# 5. 测试完成后清理
eksctl delete cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION}
```

---

## 📚 项目结构

```
eks-cluster-deployment/
├── scripts/
│   ├── 0_setup_env.sh              # 环境变量加载
│   ├── 4_install_eks_cluster.sh    # 标准部署（最常用）
│   ├── 6_install_eks_with_custom_nodegroup.sh  # Launch Template 部署
│   ├── 7_install_optional_csi_drivers.sh       # 可选 CSI
│   └── pod_identity_helpers.sh     # Pod Identity 核心函数
├── manifests/
│   ├── cluster/                    # 集群配置
│   └── addons/                     # 组件配置
├── terraform/
│   ├── vpc/                        # VPC 模块
│   └── launch-template/            # Launch Template 模块
└── README.md                       # 主文档
```

---

## ❓ 常见问题

### Q: 推送时提示没有权限？
A: 确认已接受协作邀请，并且使用正确的 GitHub 凭证。

### Q: 如何撤销错误的提交？
```bash
# 撤销最后一次提交（保留修改）
git reset --soft HEAD^

# 撤销最后一次提交（删除修改）
git reset --hard HEAD^

# 如果已经推送，需要强制推送（慎用）
git push -f origin master
```

### Q: 如何查看其他人的修改？
```bash
# 查看最近的提交
git log --oneline -10

# 查看某个提交的详细内容
git show 提交SHA

# 查看某个文件的修改历史
git log -p scripts/4_install_eks_cluster.sh
```

---

## 📞 联系方式

遇到问题可以：
1. 在 GitHub 创建 Issue
2. 联系项目维护者: kevin8093@126.com
3. 查看文档: [README.md](README.md)

---

## ✅ 快速参考

```bash
# 日常工作流
git pull origin master                    # 1. 拉取最新代码
git checkout -b feature/my-feature        # 2. 创建分支（可选）
# 进行修改...                              # 3. 修改文件
git add .                                 # 4. 添加修改
git commit -m "feat: 添加新功能"           # 5. 提交
git push origin master                    # 6. 推送（或推送分支）
```

**欢迎加入协作！** 🎉
