# EKS 上的 GPU 工作负载:节点、网络与高性能存储的架构实践

**摘要：** 本文是《企业级 EKS 集群生产环境配置最佳实践》系列第二篇,承接第一篇搭建的生产级 EKS 基础,聚焦 GPU 工作负载链路的深度架构实践。文章围绕 GPU 工作负载的三层架构 —— **计算节点、网络邻近性、高性能存储** —— 展开,覆盖 P5 / P5en / P6 / G7e 四个 GPU 实例系列的 EFA 多网卡精确摆位(含 p6-b300 非对称拓扑)、四种定价模式的 Launch Template 设计、基于 `topology.k8s.aws/network-node-layer-N` 的 AWS 原生拓扑感知调度,以及 FSx for Lustre(PERSISTENT_2)与 S3 Express One Zone + Mountpoint CSI Driver 这两类高性能存储按访问模式的选型,并提供完整的自动化部署脚本。

**目录**

01 [一、引言:GPU 工作负载的架构挑战](#section1)
02 [二、GPU 节点组:EFA 多网卡设计](#section2)
03 [三、四种定价模式的 Launch Template 架构](#section3)
04 [四、网络邻近性:基于 AWS 原生拓扑标签的调度](#section4)
05 [五、节点本地存储:Instance Store 与容器运行时的解耦](#section5)
06 [六、训练场景存储:FSx for Lustre 架构](#section6)
07 [七、S3 Express One Zone + Mountpoint:低延迟、高 TPS 的对象存储选项](#section7)
08 [八、端到端验证与最佳实践清单](#section8)
09 [九、总结:能力沉淀与取舍原则](#section9)

---

## 一、引言:GPU 工作负载的架构挑战

### 1.1 系列定位
本文是《企业级 EKS 集群生产环境配置最佳实践》**系列第二篇**,承接第一篇搭建的生产级 EKS 基础,聚焦 GPU 工作负载链路的深度架构实践。

### 1.2 三层架构挑战

第一篇给出了"能跑起来"的通用集群,本篇聚焦其上的 GPU 工作负载,让集群"能训练、能推理"。随着生成式 AI 与大模型训练在企业环境的快速落地,GPU 工作负载对**计算、网络、存储**三层都提出了超越通用节点的要求:

* **计算层**:GPU 驱动、EFA 多网卡、Device Plugin 协同
* **网络层**:allreduce 延迟对网络拓扑敏感,需要感知 bottom-layer network node 邻近性
* **存储层**:训练需要高聚合吞吐,S3 Express One Zone 作为低延迟、高 TPS 的对象存储选项按访问模式选型,而不是按"训练 vs 推理"简单二分

GPU 节点组采用 Managed Node Groups 而非 Karpenter,以便在 Launch Template 中精确控制 EFA 多网卡配置与定价模式。第一篇概览了 EBS / EFS / FSx / S3 四种 CSI Driver 的接入方式,本文将深入 FSx for Lustre 与 S3 Express One Zone 这两类高性能存储的特征、适用访问模式、架构设计与已知限制。

### 1.3 本文能带走什么
读完本文,读者能够:
- 按实例型号正确配置 EFA 多网卡,避免 `AttachmentLimitExceeded` 等常见启动错误
- 为分布式训练场景选择合适的邻近性调度方案(Placement Group vs Topology Label)
- 按访问模式为 GPU 工作负载选择合适的高性能存储并规避已知的版本兼容性问题
- 使用本系列开源的自动化脚本一键部署 GPU 节点组

### 1.4 架构总览图
```
┌─────────────────────────────────────────────────────────────┐
│                 GPU Workload Architecture                    │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐  │
│  │            Compute Layer                              │  │
│  │  GPU Nodes (P5 / P5en / P6 / G7e)                     │  │
│  │  + NVIDIA Driver / EFA / NCCL / Device Plugin         │  │
│  │  + Instance Store NVMe → /data (training scratch)     │  │
│  └───────────────────────────────────────────────────────┘  │
│                           │                                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │            Network Layer                              │  │
│  │  EFA 多网卡 (p5/p5e 最多 32 张,其它机型见 §2.3/2.4)     │  │
│  │  + Topology-aware scheduling (AWS network-node-layer)  │  │
│  └───────────────────────────────────────────────────────┘  │
│                           │                                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │            Storage Layer                              │  │
│  │  ┌──────────────────┐   ┌──────────────────────────┐  │  │
│  │  │ FSx for Lustre   │   │ S3 Express One Zone      │  │  │
│  │  │ (高聚合吞吐并行   │   │ + Mountpoint CSI         │  │  │
│  │  │  文件系统)        │   │ (低延迟 / 高 TPS 对象存储)│  │  │
│  │  └──────────────────┘   └──────────────────────────┘  │  │
│  │  按访问模式选型,不绑定具体工作负载                      │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、GPU 节点组:EFA 多网卡设计

### 2.1 EFA 在 GPU 训练中的作用
- Elastic Fabric Adapter:AWS 专用的 HPC 互联,支持 OS-bypass
- 为 NCCL allreduce 提供低延迟、高带宽的集合通信通道
- 多网卡并行为大规模分布式训练提供极高的聚合带宽(以 p5.48xlarge 为例,总聚合网络带宽 3,200 Gbps,其中 EFA 最高 3,200 Gbps,IP 流量最高 800 Gbps,两者共享同一条 3,200 Gbps 总管道;参见 [EFA configuration for accelerated instance types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-acc-inst-types.html))

### 2.2 ENI 配置的三元组
每张 EFA 网卡在 Launch Template 中由三个字段精确定位:
- **NetworkCardIndex**:对应物理 NIC 卡槽(0..N)
- **DeviceIndex**:每张 NIC 卡内的设备序号。AWS 文档对所有当前 EFA-capable GPU 实例的次卡均推荐 `DeviceIndex=0`(参考 [EFA configuration for accelerated instance types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-acc-inst-types.html))
- **InterfaceType**:`interface`(纯 ENA)/ `efa`(ENA+EFA)/ `efa-only`(仅 EFA)

### 2.3 通用拓扑模式
对 p5、p5en、p6-b200、g7e 四种实例类型,采用统一模式:
```
ENI 0:    NetworkCardIndex=0, DeviceIndex=0, InterfaceType=efa
          (主 IP + EFA,承载管理流量与第一张 EFA 通道)
ENI 1..N: NetworkCardIndex=1..N, DeviceIndex=0, InterfaceType=efa-only
          (纯 EFA,专供 NCCL 使用;DeviceIndex 是每张 NIC 卡内的序号,
           次卡的 DI=0 与主卡 DI=0 不冲突)
```
各型号 N 的取值(脚本 `gpu_efa_only_nic_count` 按实例类型返回;数字对应每张 Network Card 上挂一个 ENI 的部署模式):

| 实例类型 | NIC 卡总数 | 主卡(NCI=0) | EFA-only NIC(NCI=1..N) |
|---|---|---|---|
| p5.48xlarge | 32 | 1 | 31 |
| p5en.48xlarge | 16 | 1 | 15 |
| p6-b200.48xlarge | 8 | 1 | 7 |
| g7e.48xlarge | 4 | 1 | 3 |

### 2.4 p6-b300.48xlarge 的特殊拓扑
p6-b300 具有 `MaximumNetworkCards=17` 但 `MaximumEfaInterfaces=16` 的非对称结构,其 NIC 0 仅支持 ENA,不接受 EFA。直接套用上述通用模式会在实例启动时触发 `AttachmentLimitExceeded`。

脚本针对此型号使用独立分支:
```
ENI 0:     NetworkCardIndex=0,  DeviceIndex=0, InterfaceType=interface  (纯 ENA)
ENI 1..16: NetworkCardIndex=1..16, DeviceIndex=0, InterfaceType=efa-only (EFA)
```

**架构启示**:LT 代码不能对所有 EFA-capable 实例一刀切,需要按实例型号维护一张拓扑表。

### 2.5 EFA Userspace 的完整性
EKS GPU AMI 默认仅包含 kernel-side EFA 模块(驱动和 ibverbs 支持),不包含 `/opt/amazon/efa/` 下的 userspace 工具链(libfabric、openmpi、`fi_info` 诊断工具等)。对于依赖 host libfabric 的工作负载以及需要在节点级别做 EFA 诊断的场景,userspace 是必须的。

脚本通过 `GPU_INSTALL_EFA_USERSPACE=true` 在节点 userdata 中调用 `efa_installer.sh`(不带 `--minimal`,以确保包含 libfabric),在实例启动阶段自动补齐完整 userspace。

### 2.6 EFA 与 Pod ENI 的关系澄清
第一篇介绍过 VPC CNI 的 Pod ENI(branch ENI)机制,用于 Pod 级别安全组。EFA 多网卡使用的是 primary / secondary ENI(trunk ENI),与 Pod ENI 属于**不同的 ENI 子系统**,两者的额度独立计算、互不占用。GPU 节点即使启用了 `ENABLE_POD_ENI=true`,EFA 网卡数量也不会受影响。

### 2.7 GPU 安全组的 EFA 自引用要求
AWS 对 EFA 启用的安全组有一条**硬性要求**(参见 [Get started with EFA — Step 1: Prepare an EFA-enabled security group](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html#efa-start-security)):

> An EFA requires a security group that allows all inbound and outbound traffic **to and from the security group itself**.

也就是 GPU 节点的安全组**必须同时**包含两条**自引用规则**:

| 方向 | 协议 | 来源 / 目的 |
|---|---|---|
| Inbound | All (`-1`) | 自身 SG ID |
| Outbound | All (`-1`) | 自身 SG ID |

为什么是"自引用"?跨节点的 EFA / NCCL 流量走的是 RDMA over EFA(基于 ibverbs),既不是标准 TCP/UDP 端口、也不在 VPC 内常规的"放行整个子网 CIDR"规则覆盖范围内。**只有显式让 SG 信任自己**,同 SG 内不同节点之间的 EFA 流量才能通过。这个失败模式的特点是**单节点测试完全正常**(`fi_pingpong` 单机能通、单卡 NCCL 单机 all-reduce 能跑),**只有跨节点 NCCL 会卡死或回退到 TCP fallback**,排查难度高。

新创建的 SG 默认 outbound 是 `0.0.0.0/0`,EFA 通信表面上能跑通,但企业环境通常通过 SCP / 合规策略**收紧默认 outbound**;一旦默认规则被改动而没有显式 self-egress,EFA 就会断。脚本 `create_gpu_security_group` 函数因此**显式写入两条自引用规则**(inbound + outbound),作为防御性最佳实践,与 AWS 文档对齐。

Launch Template 把 GPU SG 与 EKS cluster security group 一起赋给所有 ENI(主 NIC + 全部 EFA-only NIC),保证 K8s control plane 通信与 EFA 数据面共存。

---

## 三、四种定价模式的 Launch Template 架构

### 3.1 四模式设计
为覆盖生产环境中多样的成本与可用性需求,脚本提供 4 个互斥开关:
- `DEPLOY_GPU_OD` — On-Demand
- `DEPLOY_GPU_SPOT` — Spot Instance
- `DEPLOY_GPU_ODCR` — On-Demand Capacity Reservation
- `DEPLOY_GPU_CB` — Capacity Block for ML

脚本在启动时校验互斥性(只允许一个开关启用),避免定价模式冲突。

### 3.2 LT 与 EKS 节点组层的协同

定价模式在两个层面共同表达：Launch Template 设置实例市场属性，EKS Managed Node Group 通过 `--capacity-type` 参数选择对应的容量类型。

| 模式 | LT `InstanceMarketOptions` | LT `CapacityReservationSpecification` | EKS NG `--capacity-type` |
|---|---|---|---|
| On-Demand | 不设置 | 不设置 | `ON_DEMAND` |
| Spot | 不设置 | 不设置 | `SPOT` |
| ODCR | 不设置 | 指向目标 `CapacityReservationId` | `ON_DEMAND` |
| Capacity Block | `MarketType=capacity-block` | 指向目标 `CapacityReservationId` | `CAPACITY_BLOCK` |

**关键点**：Spot 模式下 LT 不写入 `InstanceMarketOptions`，由 EKS 托管层的 `capacity-type=SPOT` 控制；Capacity Block 必须在 LT 中显式设置 `MarketType=capacity-block` 并嵌入 `InstanceType`，与 ODCR 的 LT 配置不同。

### 3.3 多 NG 共存
生产中常常需要同一账户、同一集群内并存多个 GPU 节点组(例如不同 ODCR、不同 AZ、不同型号)。脚本提供两个机制:
- `GPU_NG_SUFFIX`:手工指定后缀,避免 (gpu_type, purchase_option) 元组的命名冲突
- `GPU_TARGET_AZ`:收敛到单 AZ,用于 ODCR(ODCR 本身是 AZ 级别的资源)或精细化调度

用法示例:
```bash
# 同型号 p5 在不同 AZ 各部署一组,通过 SUFFIX 区分
GPU_TARGET_AZ=c GPU_NG_SUFFIX="-az3-p5" \
  ./scripts/option_install_gpu_nodegroups.sh

GPU_TARGET_AZ=d GPU_NG_SUFFIX="-az4-p5" \
  ./scripts/option_install_gpu_nodegroups.sh
```

ODCR 和 Capacity Block 路径会根据预留 ID 自动加后缀,无需手动设置。

---

## 四、网络邻近性:基于 AWS 原生拓扑标签的调度

第一篇聚焦在"把集群跑起来",未涉及跨节点训练的网络拓扑问题。对于分布式训练,节点间网络距离直接影响 allreduce 性能,本章展开这一维度的架构设计。

### 4.1 训练工作负载的拓扑敏感性
按 [AWS EC2 instance topology 文档](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-ec2-instance-topology-works.html),`DescribeInstanceTopology` 返回的 `NetworkNodes` 是一个**自上而下**的网络节点列表,其中**最后一项是连到实例的那个网络节点(bottom layer)**。两个实例的 `NetworkNodes` 共享的层级越低(越接近末尾),它们之间的跳数越少;只有都共享 bottom layer 的实例距离最近。

对于数十节点规模的分布式训练,把所有节点收敛到同一 bottom-layer network node 是重要的性能优化目标。

### 4.2 两种方案对比:Placement Group vs 直接读 AWS 拓扑标签
AWS 提供 `cluster` 策略的 Placement Group,目标是把实例放到"低延迟的网络分组"。但实测表明,在 p5 类型实例上,cluster PG 与"实例之间是否共享 bottom-layer network node"之间存在差异 —— **同一 PG 内的多个实例可能落在不同的 bottom-layer network node,只保证共享上一层**。对训练工作负载而言,这一保证并不足以带来显著的 allreduce 性能提升,而 PG 约束反而可能加剧 `InsufficientInstanceCapacity` 的发生概率。

基于此,脚本默认采用**直接读 AWS 原生拓扑标签**的方案,不写任何自定义标签:
1. 不使用 Placement Group(`GPU_PG_STRATEGY=none` 为默认)
2. 节点 Ready 后,直接读取 cloud-controller-manager 注入的 `topology.k8s.aws/network-node-layer-N` 与 `topology.k8s.aws/zone-id`
3. 按 NG 打印 topology inventory,按 bottom-layer network node 分组
4. 由工作负载通过 `nodeAffinity` 直接绑定到 AWS 原生标签

### 4.3 拓扑数据来源：K8s 节点标签

AWS cloud-controller-manager 在节点 `Initialize` 阶段就把每个 GPU 实例的网络层级写入节点标签,脚本只需 `kubectl get nodes` 一次即可拿到全部数据,无需调用 `ec2:DescribeInstanceTopology`,也不依赖 `eks:DescribeNodegroup` / `autoscaling:DescribeAutoScalingGroups` 等额外 IAM 权限(在 SCP 受限环境中尤其重要)。

每个 GPU 节点上由 cloud-controller-manager 写入的标签示意(自上而下,最后一项连到实例):

```
topology.k8s.aws/network-node-layer-1 = nn-aaaa   # top layer
topology.k8s.aws/network-node-layer-2 = nn-bbbb   # 中间层
topology.k8s.aws/network-node-layer-3 = nn-cccc   # 3-node 拓扑上是 bottom layer
topology.k8s.aws/network-node-layer-4 = nn-dddd   # 仅 4-node 拓扑存在,是 bottom layer
topology.k8s.aws/zone-id              = usw2-az1
```

每种实例类型固定返回 3 个或 4 个 NetworkNodes,详见 [AWS Prerequisites for Amazon EC2 topology](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-topology-prerequisites.html):

| NetworkNodes 长度 | 实例类型 | bottom layer |
|---|---|---|
| 3 | p3dn / p4d / p4de / p5 / p5e / **p5en** / p6e-gb200 / g6e / g7e / hpc 系列 / trn1 / trn1n / trn2 / trn2u | `network-node-layer-3` |
| 4 | **p6-b200.48xlarge** / **p6-b300.48xlarge** | `network-node-layer-4` |

### 4.4 脚本不再叠加自定义标签
脚本不写任何自己的 label,只读 AWS 原生标签后打印 inventory。

为什么不再做反向编号或别名:
- AWS 文档使用的术语就是 `network nodes` / `top layer` / `bottom layer`,自创 `leaf` / `spine` / `aggregator` / `depth` 概念会引入与 AWS 文档不一致的 terminology
- p5/p5en 与 p6-b300 的 NetworkNodes 长度本来就不同(3 vs 4),任何"反向统一编号"都是脚本层的额外抽象,而不是 AWS 的客观事实
- 直接面对 AWS 原生 layer-N 编号,workload YAML 与 AWS 文档的字段一一对应,任何阅读 [AWS topology API 文档](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/how-ec2-instance-topology-works.html) 的人都能立即对得上

### 4.5 工作负载端的使用
直接使用 AWS 原生 label。一个 NG 内的实例类型固定,因此 `network-node-layer-N` 的 N 也固定,只要按机型选对应的层即可。

```yaml
# p6-b300 节点组(NetworkNodes 长度=4,bottom layer 是 layer-4)
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.k8s.aws/network-node-layer-4
              operator: In
              values: ["nn-dddd"]
            - key: topology.k8s.aws/zone-id
              operator: In
              values: ["usw2-az1"]
```

如果 NG 跑的是 p5 / p5en(NetworkNodes 长度=3),把 `network-node-layer-4` 改为 `network-node-layer-3`。

脚本提供 `option_show_nodegroup_topology.sh` 命令,按 NG 打印每个节点的 `layer-1..N` 链路并按 bottom-layer network node 分组,便于挑出含 N 个以上节点的同 bottom-layer 子集。

### 4.6 Gate 模式(可选)
脚本通过 `GPU_TOPOLOGY_MODE` 控制 4 种行为：`inventory`（默认,只打印拓扑清单）、`gate`（校验后再决定）、`both`（校验 + 打印清单）、`off`（跳过）。

对于要求所有节点严格共享同一 bottom-layer network node 的严苛场景,设置 `GPU_TOPOLOGY_MODE=gate` + `GPU_TOPOLOGY_GATE=strict` + `GPU_TOPOLOGY_GATE_LAYER=auto`(默认值,等于该 NG 实例类型的 bottom layer);节点创建后校验拓扑,不满足则将 NG 缩到 `minSize=0,maxSize=1,desiredSize=0`(EKS API 不接受 `maxSize=0`,因此保留 1 作为容量上限),实际节点数缩为 0,作为"软暂停"状态。如果需要在更高一层做校验,可以把 `GPU_TOPOLOGY_GATE_LAYER` 设为具体的层编号(如 `=2`,对应 AWS 自上而下的第 2 层)。

---

## 五、节点本地存储:Instance Store 与容器运行时的解耦

第一篇介绍了系统节点通过双 EBS + LVM 把 `/var/lib/containerd` 从根盘剥离,解决容器 I/O 与系统 I/O 竞争问题。GPU 节点继承该设计,但由于 `*d / i4g` 系列自带 Instance Store NVMe,需要额外引入一层本地 scratch 存储 `/data`,并严格区分两者用途——容器运行时必须留在 EBS,本地 scratch 才挂 Instance Store。本章展开这一设计的细节。

### 5.1 训练场景的本地 I/O 需求
大规模训练过程中,checkpoint 写入、dataset shuffle、中间 tensor 缓存等对本地 I/O 带宽要求极高。EBS 虽然稳定,但带宽和延迟受网络限制;GPU 实例自带的 Instance Store NVMe 是更合适的 scratch 层。

### 5.2 Instance Store 的特殊性
- **临时存储**:实例 stop/start 时 Instance Store 数据完全丢失,每次启动都需要重新格式化,因此无法通过 `/etc/fstab` 使用稳定 UUID 挂载
- **无需付费**:容量包含在实例价格中
- **不同 GPU 实例系列的配置差异较大**:p5 / p5en / p5e 全系标配多块 NVMe SSD;g6 系列通过 `d` 后缀变体(如 `g6d.48xlarge`)提供 Instance Store;部分 GPU 型号(如 g7e 某些规格)则不带 Instance Store。脚本通过 `disk_detection_lib.sh` 动态检测磁盘 model 字段,而非依赖实例名约定。

### 5.3 脚本实现
- `GPU_ENABLE_LOCAL_LVM=true` 时（默认开启），在 userdata 中扫描所有 Instance Store NVMe
- 通过 LVM 把多块盘 stripe 成 `vg_local/lv_scratch`,挂载到 `/data`(挂载点、卷组名、逻辑卷名均可通过 `GPU_LOCAL_LVM_VG_NAME` / `GPU_LOCAL_LVM_LV_NAME` / `GPU_LOCAL_LVM_MOUNT` 覆盖)
- 使用 **systemd oneshot** 单元而非 `/etc/fstab`:每次启动都重新扫描、初始化、挂载,避免磁盘 UUID 变化导致 fstab 失效

### 5.4 与容器运行时 LVM 的严格隔离
第一篇介绍过系统节点用双 EBS + LVM 把 `/var/lib/containerd` 从根盘剥离。GPU 节点也继承这个设计,但面临新的风险:**绝不能把容器运行时放到 Instance Store 上**,否则节点重启后镜像和容器状态全丢。

脚本通过 `disk_detection_lib.sh` 按设备 model 字段识别 EBS 数据盘(而非磁盘序号或大小),确保 `/var/lib/containerd` 永远挂在 EBS 上,`/data` 永远挂在 Instance Store 上,两者互不交叉。

---

## 六、训练场景存储:FSx for Lustre 架构

### 6.1 Lustre 在训练链路中的定位
- **高聚合吞吐**:PERSISTENT_2 文件系统按 `PerUnitStorageThroughput` 线性扩展,单系统可达数百 GB/s
- **并行 I/O**:多节点同时读写不互相阻塞
- **与 S3 深度集成**:通过 Data Repository Association(DRA)把冷数据存 S3,热数据 lazy-load 到 Lustre,显著降低成本

### 6.2 典型训练数据流
```
┌──────────┐   async lazy    ┌──────────────┐   parallel read    ┌──────────┐
│   S3     │ ◄──────────────►│ FSx Lustre   │ ──────────────────►│ GPU Pods │
│ (cold)   │   export/import │ (hot, GB/s)  │    (NCCL, MPI)     │          │
└──────────┘                 └──────────────┘                    └──────────┘
```

### 6.3 DeploymentType 与 Lustre 版本选型
FSx for Lustre 当前支持 Lustre LTS **2.10 / 2.12 / 2.15** 三个版本,可通过 `aws fsx update-file-system --file-system-type-version` 在已有文件系统上升级版本(详见 [Managing Lustre versions](https://docs.aws.amazon.com/fsx/latest/LustreGuide/managing-lustre-version.html))。各 DeploymentType 创建时的**默认 Lustre 版本**对照如下:

| DeploymentType | 默认 Lustre 版本 | 适用场景 |
|---|---|---|
| SCRATCH_1 / SCRATCH_2 | 2.10 | 短期临时文件系统 |
| PERSISTENT_1 | 2.10 | 长期持久化(已被 PERSISTENT_2 取代) |
| **PERSISTENT_2**(无 metadata configuration) | **2.12** | 长期持久化,推荐 |
| **PERSISTENT_2** + metadata configuration | **2.15** | 需要更高 metadata 性能时 |

**重要兼容性要求**:本方案在节点 user-data 中通过 `dnf install lustre-client` 安装客户端,AL2023 仓库当前提供的版本为 **2.15.x**,与 Lustre 2.10 服务端不兼容,与 2.12 服务端可兼容。若 FSx 使用 SCRATCH_2 或 PERSISTENT_1(默认 2.10)创建,挂载会失败并报告:
```
mount.lustre: mount ... failed: Invalid argument
LustreError: Server MGS version (2.10.x.x) refused connection
  from this client with an incompatible version (2.15.x).
```

因此 EKS + AL2023 环境下应始终选择 **PERSISTENT_2**;若已存在的 SCRATCH_2 / PERSISTENT_1 文件系统不可重建,可先用 `aws fsx update-file-system --file-system-type-version "2.12"`(或 `"2.15"`)把服务端升到客户端兼容的版本。

### 6.4 推荐的 FSx 创建命令
```bash
aws fsx create-file-system --file-system-type LUSTRE \
  --storage-capacity 1200 \
  --subnet-ids "$PRIVATE_SUBNET_A" \
  --security-group-ids "$FSX_SG" \
  --lustre-configuration \
      DeploymentType=PERSISTENT_2,PerUnitStorageThroughput=125
```

### 6.5 CSI Driver 集成
- EKS Managed Addon:`aws-fsx-csi-driver`
- 使用 Pod Identity 替代 IRSA(延续第一篇的身份管理方案)
- StorageClass 示例(扩写正文时放完整 yaml):
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: fsx-training
  provisioner: fsx.csi.aws.com
  parameters:
    subnetId: ${PRIVATE_SUBNET_A}
    securityGroupIds: ${FSX_SG}
    deploymentType: PERSISTENT_2
    perUnitStorageThroughput: "125"
    dataRepositoryAssociations: s3://my-training-bucket/
  ```

---

## 七、S3 Express One Zone + Mountpoint:低延迟、高 TPS 的对象存储选项

### 7.1 S3 Express One Zone 的特征
S3 Express One Zone 是 AWS 在 2023 年底推出的高性能 S3 存储类,使用一种新的 **directory bucket** 桶类型,与 Standard S3 桶在 ARN 格式与部分 API 行为上均不同。核心特征:

- **个位数毫秒延迟**:与计算资源**同 AZ 共置(co-located)**,首字节读写延迟约 4 ms;Standard S3 通常 10–30 ms
- **单桶高 TPS**:默认 200K reads/s + 100K writes/s,可申请到 2M reads/s + 200K writes/s,且不需要按前缀分片
- **单 AZ**:数据只在一个 AZ 内冗余,**不跨 AZ**,失去多 AZ 容灾,换取计算就近
- **成本曲线相反**:每 GB-月存储费率高于 Standard,但每请求费率低 50% 左右(超过 512 KB 才按数据传输额外计费),适合"高频请求、短期保留"
- **AWS 官方 use cases**:[产品页](https://aws.amazon.com/s3/storage-classes/express-one-zone/) 列出 **ML training / interactive analytics / streaming / HPC / media**;推理服务并不在主推用例中

判断是否适合用 S3 Express,可以从三个问题入手:
1. 工作负载是否对**首字节延迟**或**聚合 TPS** 敏感?如否,Standard 桶就够
2. 数据是否能容忍**单 AZ 不可用**的风险?如否,不可选(没有跨 AZ 模式)
3. 数据保留时长是否较短?如长期保留,Standard 在存储费上更划算

### 7.2 Standard S3 与 S3 Express One Zone 对比
| 维度 | Standard S3 | S3 Express One Zone |
|---|---|---|
| 延迟 | 10–30 毫秒 | 个位数毫秒(同 AZ 约 4 ms) |
| 请求吞吐 | 按桶限流(5500 RPS/前缀,可申请提升) | 默认 200K reads/s,可申请到 2M reads/s |
| 可用区 | 多 AZ 冗余 | 单 AZ |
| 成本结构 | 存储费率低、请求费率较高 | 存储费率高、请求费率低 |
| 适合的访问模式 | 大文件顺序读、跨 AZ 共享、数据湖、备份、长期保留;**常驻推理服务的模型加载** | 高 TPS 小对象 random read、低延迟写、跨 Pod 并发拉同一对象(scale-out 模型分发)、训练 checkpoint 高频写、训练数据 shuffle |

> **常驻推理服务的模型加载** 这一行特意放在 Standard 一列:模型加载完即驻留 GPU 显存、推理过程不再访问 S3,这是大文件一次性顺序读,Standard 已经够用,继续用 S3 Express 反而每月多付存储费。

### 7.3 ARN 格式差异
两类存储在 IAM 策略和 CSI Driver 配置中的 ARN 格式不同,混用会导致 Pod Identity 配置失败:

```
Standard S3:
  arn:aws:s3:::my-bucket

S3 Express One Zone:
  arn:aws:s3express:{region}:{account}:bucket/{name}--{zone-id}--x-s3

示例:
  arn:aws:s3express:us-east-1:123456789012:bucket/my-model--use1-az1--x-s3
```
S3 Express 的 ARN 结构包含 zone-id(如 `use1-az1`)和强制后缀 `--x-s3`。

### 7.4 Mountpoint 的 POSIX 语义限制
Mountpoint for S3 基于对象存储,不提供完整 POSIX 文件系统语义。以下操作不被支持:
- 随机写(写入仅支持顺序 append)
- rename
- hard link

**实践意义**:
- 适合 —— 大文件只读挂载(如模型权重、数据集分片)、顺序写入(训练 checkpoint、日志 append)
- 不适合 —— shuffle/swap、数据库文件、需要随机写或 rename 的工作负载

### 7.5 CSI Driver 与 Pod Identity
- EKS Managed Addon:`aws-mountpoint-s3-csi-driver`
- 脚本通过 `setup_s3_csi_pod_identity` 动态生成 bucket policy,仅授权指定 bucket
- 避免广泛权限(如 `AmazonS3ReadOnlyAccess`),符合最小权限原则

### 7.6 何时不用 S3 Express One Zone
不要把 S3 Express 当成"性能更好的 S3"无脑替换。以下场景不适合或不必要:

- **数据需要跨 AZ 容灾**:Express 是单 AZ 存储类,生产 critical 数据用 Standard
- **长期保留 / 数据湖 / 冷数据**:存储费率劣势会随保留时长指数放大
- **Standard 桶已满足需求**:大文件顺序读上 Express 与 Standard 性能差距很小,迁移收益不抵成本
- **常驻推理服务的模型加载**:这是 Pod 启动阶段的一次性顺序读,Standard + Mountpoint 已经够用;只有 scale-out 时多 Pod 并发拉同一权重才有 Express 的并发优势

---

## 八、端到端验证与最佳实践清单

### 8.1 两种 K8s GPU 栈部署模式:Standard vs Operator

GPU 节点本身只是基础设施(driver + nvidia-container-toolkit + EFA + LVM),要让 K8s 真正"看到 GPU 并能调度",还需要在集群里装一套 K8s GPU stack(device plugin、Feature Discovery、监控、健康检查等)。脚本通过 `option_install_gpu_stack.sh` 提供**两种互斥模式**,使用者按需选择:

```bash
# 默认模式
GPU_STACK_MODE=standard ./scripts/option_install_gpu_stack.sh

# 或切换到 NVIDIA GPU Operator 模式
GPU_STACK_MODE=operator ./scripts/option_install_gpu_stack.sh
```

#### Standard 模式(默认)

逐组件用上游 Helm chart 部署,职责清晰、与 EKS NVIDIA AMI 已预装的 driver / toolkit 自然分工:

| 组件 | Chart / 资源 | 作用 |
|---|---|---|
| nvidia-device-plugin | `nvdp/nvidia-device-plugin`(含 GFD sidecar) | 暴露 `nvidia.com/gpu` 资源 + 节点 GPU 属性标签 |
| aws-efa-k8s-device-plugin | DaemonSet | 暴露 `vpc.amazonaws.com/efa` 资源 |
| **dcgm-exporter** | `nvidia/dcgm-exporter` | **Pod 级 GPU 指标**(利用率、显存、温度、功耗、ECC、XID 错误等),Prometheus `:9400/metrics` |
| **node-problem-detector** | `deliveryhero/node-problem-detector` | **节点级 GPU XID / kernel 事件** 上报为 NodeCondition / Event |
| gpu-health-check | 内置 DaemonSet | 节点启动时执行 `nvidia-smi`,失败则给节点打 taint,阻止误调度 |

特点:
- 与 EKS NVIDIA AMI 直接配合 —— AMI 已经装好 driver / toolkit / NVIDIA Container Toolkit,Standard 模式只补 K8s 层组件,**不重复装 driver**
- 组件少、依赖浅、helm release 个数可控,适合**已有自建 Prometheus 栈**或希望对每个组件版本独立掌控的团队
- 出问题时排查路径短:每个组件是单独的 helm release / DaemonSet,日志聚焦

#### Operator 模式(NVIDIA GPU Operator)

由 NVIDIA 官方维护的 [GPU Operator](https://github.com/NVIDIA/gpu-operator) 一个 helm chart 全包,内部以 CRD + controller 方式拉起 device-plugin / GFD / NFD / dcgm-exporter / validator 等子组件。脚本里启用方式:

```bash
GPU_STACK_MODE=operator \
GPU_OPERATOR_VERSION=v25.3.4 \
  ./scripts/option_install_gpu_stack.sh
```

针对 EKS NVIDIA AMI 的关键 chart values(脚本默认值):
```
driver.enabled = false      # AMI 已预装,不让 Operator 再装一遍 driver
toolkit.enabled = false     # AMI 已预装 nvidia-container-toolkit
mofedDriver.enabled = false # AWS EFA Device Plugin 接管 /dev/infiniband/uverbs*
mig.strategy = none         # MIG 仅 A100/H100/B200 启用,默认关
```

特点:
- 一个 chart 拉起整套 GPU stack,**升级时跟随 NVIDIA 官方版本节奏**,跨云一致(GKE / AKS / on-prem 都能用)
- 内置 dcgm-exporter / GFD / NFD / validator,**监控开箱即用**
- 适合**纯 NVIDIA 工具链**、希望统一管理面、未来可能切换 cloud provider 的团队
- 注意:driver / toolkit 必须显式禁用,否则会与 AMI 预装版本冲突

#### 两种模式都自带 GPU 监控

无论选哪种,都会向集群部署 dcgm-exporter,以 Prometheus `:9400/metrics` 暴露 Pod 级 GPU 指标,标准 Prometheus + Grafana 栈直接抓取即可:

```yaml
# Prometheus ServiceMonitor / PodMonitor 抓取示意
- port: metrics
  path: /metrics
  interval: 30s
```

关键 metrics:
- `DCGM_FI_DEV_GPU_UTIL` —— GPU 利用率
- `DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_FREE` —— 显存使用
- `DCGM_FI_DEV_GPU_TEMP` / `DCGM_FI_DEV_POWER_USAGE` —— 温度 / 功耗
- `DCGM_FI_DEV_ECC_DBE_AGG_TOTAL` / `DCGM_FI_DEV_XID_ERRORS` —— 硬件 ECC / XID 故障

Standard 模式额外提供 node-problem-detector,把 GPU XID / 内核错误转成 K8s `NodeCondition` 与 `Event`,可被 K8s 原生告警链路(Alertmanager / EventRouter)直接消费。Operator 模式下,XID 监控由其自带的 nvidia-validator + dcgm-exporter 完成,event 化需要再叠加 NPD 或自定义 webhook。

#### 两种模式互斥(脚本会 fail-fast)

下列资源在两种模式下会冲突,脚本检测到对侧的 helm release 或 DaemonSet 会直接报错并要求清理:
- `nvidia.com/gpu` 资源 advertise(两边都注册同名 device plugin)
- DCGM `:9400` 端口(两边都跑 dcgm-exporter)
- GFD 节点标签(两边都打 `nvidia.com/gpu.product` 等)

切换模式前必须 `helm uninstall` 对侧组件;脚本支持 `GPU_STACK_FORCE_MODE_SWITCH=true` 自动清理对侧 release。

#### 选择建议

| 团队画像 | 推荐 |
|---|---|
| 已有自建 Prometheus + Grafana,希望最小 footprint | **Standard** |
| 希望未来跨云保持一致(EKS / GKE / AKS / on-prem) | **Operator** |
| 已经在用 NVIDIA AI Enterprise / NIM 等 NVIDIA 商业栈 | **Operator** |
| 团队不熟悉 GPU Operator CRD,出问题需要短链路排查 | **Standard** |
| 需要 MIG 自动配置(A100 / H100 / B200) | **Operator**(`mig.strategy=mixed/single`) |

本系列文档与脚本的端到端验证以 **Standard 模式** 为主完成,因为它对 AMI 已有组件的耦合更轻、调试链路更短;Operator 模式作为可选路径完整提供且**所有 chart values 对齐 EKS NVIDIA AMI 的预装栈**,可在生产环境直接选用。

### 8.2 两个 Device Plugin 的协同
GPU + EFA 工作负载依赖**两个独立的 Device Plugin**,职责边界清晰但容易漏配:

| Device Plugin | 暴露资源 | 部署方式 | 作用 |
|---|---|---|---|
| NVIDIA Kubernetes Device Plugin | `nvidia.com/gpu` | Helm chart(`nvdp/nvidia-device-plugin`) | 让 Pod 申请 GPU 并挂载 `/dev/nvidia*` |
| AWS EFA Kubernetes Device Plugin | `vpc.amazonaws.com/efa` | DaemonSet(`aws-efa-k8s-device-plugin-daemonset`) | 让 Pod 申请并独占 EFA 网卡 |

分布式训练的工作负载必须**同时申请两类资源**:
```yaml
resources:
  limits:
    nvidia.com/gpu: 8
    vpc.amazonaws.com/efa: 32   # 常见漏写,导致 NCCL 走 TCP fallback 而非 EFA
```

NVIDIA Device Plugin 部署方式与关键开关:

- **EKS-optimized AL2023 NVIDIA AMI 已预装** NVIDIA driver + NVIDIA Container Toolkit,nodeadm 已把 `nvidia` 注册为 containerd 默认 runtime——因此 device plugin 容器启动时由 nvidia-container-toolkit 自动注入 NVML/CUDA 库与设备节点,**不需要 hostPath 挂载、库 symlink 或自定义 RuntimeClass**。
- **采用上游 Helm chart 部署**(参考 [Manage NVIDIA GPU devices on EKS](https://docs.aws.amazon.com/eks/latest/userguide/device-management-nvidia.html)),以 helm release 形式运行;脚本默认 `NVIDIA_DEVICE_PLUGIN_VERSION=v0.19.1`(2026-04-23 最新稳定版),在 nvcr.io 不可达的区域(如 cn-*)通过 `NVIDIA_DEVICE_PLUGIN_REPO` 指向私有 ECR 镜像。
- **关键 chart values**:
  - `mofedEnabled=false` —— **关键**:从 v0.19.0 起 NVIDIA Device Plugin 默认会挂载所有 `/dev/infiniband/uverbs*` 设备到申请 GPU 的 Pod 内,这与 AWS EFA Device Plugin 管理 uverbs 设备的职责冲突,导致 Pod 取不到全部 EFA 网卡或 EFA Device Plugin 无法暴露资源。两类 plugin 共存时**必须显式关闭**该开关,详见 [AWS EKS 文档](https://docs.aws.amazon.com/eks/latest/userguide/device-management-nvidia.html)。
  - `gfd.enabled=true` —— 启用 GPU Feature Discovery sidecar,自动给节点贴 `nvidia.com/gpu.product`、`nvidia.com/gpu.memory`、`nvidia.com/cuda.driver-version` 等属性标签,便于工作负载按 GPU 型号选择节点。
- **不再设置** `compatWithCPUManager=true`:在 nvidia-container-toolkit 1.18 之前,该选项让 device plugin 跑成 privileged,以绕开 legacy hook 注入路径在非特权容器上的限制。toolkit 1.18+ 默认走 just-in-time CDI(jit-cdi),由 `nvidia-container-runtime` 在 OCI spec 上直接生成 device 注入,plugin 与 workload pod 都不再需要 privileged。继续显式开启反而让 plugin pod 长期保持过高权限,无安全收益。AWS EKS NVIDIA AL2023 AMI 已预装 toolkit 1.19+,本方案直接信任 jit-cdi 默认路径。
- **Blackwell 架构(p6-b200 / p6-b300)的版本要求**:NVIDIA Device Plugin 对 Blackwell 架构的 `nvidia.com/gpu.product` 标签识别由 [PR #1240](https://github.com/NVIDIA/k8s-device-plugin/pull/1240) 引入,backport 到 release-0.17,因此**生产部署 Blackwell GPU 节点应使用 v0.17.2 或更新版本**。

**关于启动竞态(为什么不再需要"手动 bounce")**:

GPU 节点首次启动时,nvidia-device-plugin 容器与 nvidia 内核模块加载存在潜在竞态——plugin 先起、`/dev/nvidia*` 后创建,plugin 看不到 GPU。NVIDIA 官方推荐通过 `failOnInitError=true`(env `FAIL_ON_INIT_ERROR`,helm chart 同名 value)解决:**plugin init 失败时立即 crash,kubelet 触发 `CrashLoopBackOff` 自动重启,几秒后下一次启动等到设备就绪自然恢复**。这是 helm chart 的默认行为,我们不 override。

下面两层防护进一步收紧竞态窗口:
- **AMI 层**:EKS AL2023 NVIDIA AMI 提供 `nvidia-kmod-load.service`,声明 `Before=containerd.service`,在 host 层把驱动加载排在 containerd 之前(参见 [amazon-eks-ami install-nvidia-driver.sh](https://github.com/awslabs/amazon-eks-ami/blob/main/templates/al2023/provisioners/install-nvidia-driver.sh))
- **Plugin 层**:v0.19.0 的两条修复 "Honor fail-on-init-error when no resources are found"、"Ensure FAIL_ON_INIT_ERROR boolean env is quoted" 进一步堵住了 silent block 的 corner case

> **历史背景**:本仓库脚本早期版本曾用一段"扫描所有 GPU 节点 + grep `No devices found` + `kubectl delete pod` 强制重启"的兜底逻辑,因为彼时手写 DaemonSet 显式设了 `FAIL_ON_INIT_ERROR=false`,plugin 在 stuck 时会 silent block 而非 crash。切换到 helm chart 后该 env 默认 `true`,kubelet 接管自愈,bounce 逻辑已经从脚本里删除。

排查思路(plugin 看似 `Running` 但 `nvidia.com/gpu` allocatable 仍为 0):
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin --tail=50
# 关注:"No devices found. Waiting indefinitely." → 命中 NVIDIA upstream issue #1080 / bug 5129637
# 进一步:登录节点 ls /dev/nvidia* 看驱动是否真的加载
#         journalctl -u nvidia-kmod-load.service 看 kmod 加载日志
```

**关于 cgroupsPath 与 containerd config 重载(AMI v20260512 及之前必备)**:

EKS NVIDIA AL2023 AMI 在 nvidia-ctk 配置 containerd 时,`[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]` 下的 `SystemdCgroup` 可能丢失为默认 `false`,与 kubelet 的 systemd cgroup driver 不一致,导致 pod sandbox 创建报:

```
runc create failed: expected cgroupsPath to be of format
"slice:prefix:name" for systemd cgroups
```

同时,nodeadm 在 AMI v20260516 之前的版本里 `EnsureRunning()` 调用 `StartUnit`,对已运行的 containerd 是 no-op,导致它写下的 `/etc/containerd/config.toml` 永远不会被加载(参见 [awslabs/amazon-eks-ami#2705](https://github.com/awslabs/amazon-eks-ami/pull/2705),2026-05-13 已 merged)。

GPU 节点 userdata 因此做两件事:

1. **`NodeConfig.spec.containerd.config` 注入 `SystemdCgroup=true`**,nodeadm 会把它 merge 在 nvidia-ctk overlay 之上,确保最终落盘的 config 总带 `SystemdCgroup=true`。
2. **`nodeadm init` 之后显式 `systemctl restart containerd && systemctl restart kubelet`**,强制加载新写的 config。

上游 AMI 含 #2705 fix(v20260516+)的版本可以移除 (2);(1) 可以在 nvidia-container-toolkit 解决该 SystemdCgroup drop 问题后移除。

### 8.3 Workload pod 镜像选择

nvidia-container-toolkit 1.18+ 的默认 jit-cdi 路径下,workload pod **不需要镜像 bake driver libs**,也不需要 privileged。容器启动时由 `nvidia-container-runtime` 把 host 的 driver libs(`libnvidia-ml.so.580.x` 等)和工具(`nvidia-smi`)通过 OCI 设备注入到容器 rootfs。

经验证可工作的 workload pod 形态:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  containers:
  - name: app
    image: nvcr.io/nvidia/cuda:12.4.1-runtime-ubuntu22.04   # 任何 stripped CUDA 镜像
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
  tolerations:
  - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
```

容器内 `nvidia-smi` 直接可用,输出的 driver / CUDA 版本与 host 一致(实测 `NVIDIA-SMI 580.159.03 / Driver Version: 580.159.03 / CUDA Version: 13.0`)。对于自建镜像,只需在 Dockerfile 内声明:

```dockerfile
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
```

并在 K8s manifest 中申请 `nvidia.com/gpu` 资源即可。

> **历史背景**:在 toolkit 1.18 之前的 legacy 注入路径下,曾流行的"workaround 三件套"——把 `nvidia-container-runtime` mode 强制改成 `legacy`、关闭 `enable_cdi`、再给 device plugin 设 `compatWithCPUManager=true` 让它跑成 privileged——在 jit-cdi 时代反而是 anti-pattern,会把工作路径强制退回到已 deprecated 的 prestart-hook,触发 containerd 2.x 上的若干 corner case。本方案完全不动 toolkit / containerd 配置(除上一节 SystemdCgroup overlay 与 restart),让 jit-cdi 默认路径自然工作。

### 8.4 GPU 节点就绪验证
```bash
# GPU 可见
kubectl get nodes -o=custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

# NVIDIA Device Plugin 健康(helm chart 起的 daemonset 用 app.kubernetes.io 标签)
kubectl get pods -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin

# GPU Feature Discovery 自动贴的标签
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.memory,nvidia.com/cuda.driver-version

# EFA Device Plugin 健康
kubectl get pods -n kube-system -l name=aws-efa-k8s-device-plugin
```

### 8.5 EFA 链路验证
EFA 用户态工具(`fi_info`、`fi_pingpong`)由 host 上的 `/opt/amazon/efa/` 提供,**前提是节点 user-data 启用了 `GPU_INSTALL_EFA_USERSPACE=true`**(脚本默认开启)。
```bash
# 在节点上(通过 kubectl debug)
fi_info -p efa          # 期望看到每张 EFA 网卡
fi_pingpong -p efa      # 端到端 EFA 通信测试
```

### 8.6 拓扑标签验证
```bash
kubectl get nodes -L topology.k8s.aws/network-node-layer-1,topology.k8s.aws/network-node-layer-2,topology.k8s.aws/network-node-layer-3,topology.k8s.aws/network-node-layer-4,topology.k8s.aws/zone-id
```

### 8.7 端到端 GPU + EFA 验证脚本(单节点 + 跨节点)
仓库提供 `option_verify_gpu_efa.sh` 一键验证脚本,基于 AWS 官方 [`public.ecr.aws/hpc-cloud/nccl-tests`](https://gallery.ecr.aws/hpc-cloud/nccl-tests) 镜像(自带 EFA installer、AWS-OFI-NCCL、NCCL、nccl-tests、sshd、Open MPI),支持两种模式:

**单节点模式**(默认,验证本机 GPU + EFA stack 的可用性):
```bash
./scripts/option_verify_gpu_efa.sh <ng_name>
```
检查项:① `nvidia-smi` 看到全部 GPU;② `/dev/nvidia[0-9]*` 设备节点数与 GPU 数一致;③ `fi_info -p efa` 列出全部 EFA 卡;④ `/dev/infiniband/uverbs*` 数与 EFA 数一致;⑤ AWS-OFI-NCCL plugin (`libnccl-net.so`) 存在;⑥ 单节点 NCCL `all_reduce_perf` 跑通。

**跨节点模式**(`--multi N`,N≥2):
```bash
./scripts/option_verify_gpu_efa.sh <ng_name> --multi 2
```
脚本会:在 NG 内挑 N 个 Ready 节点,创建 headless Service + N 个 Pod(每个 Pod 钉到一个节点上,共消耗 `N × GPUs/node` 个 GPU 与 `N × EFAs/node` 个 EFA),通过 Open MPI + sshd 启动跨节点 `all_reduce_perf -b 8 -e 1G -f 2 -g 1 -np <N×GPU>`。验证项:

- mpirun 跨节点完成,所有 ranks 加入并 ring/tree formed
- NCCL_DEBUG 输出含 `NET/AWS Libfabric` 或 `NET/Plugin/Loaded`(确认走 AWS-OFI-NCCL → EFA,而非 `NET/Socket` 的 TCP fallback)
- (可选)通过 `VERIFY_BUSBW_THRESHOLD=<GB/s>` 设置带宽底线,低于阈值时报 FAIL

**为什么必须做跨节点验证?** §2.7 描述的 GPU 安全组自引用规则错误属于**单节点测试无法发现**的故障——单节点 NCCL all-reduce 永远在同一台机器内,SG 只过滤跨节点流量。只有跨节点 NCCL 真正发起 host-to-host EFA 通信时,SG 配置不全的故障才会暴露。脚本 `--multi` 模式专门用于覆盖这一类。

失败时脚本会打印典型排查方向:GPU SG 自引用规则缺失、`mofedEnabled=false` 是否设置、AWS-OFI-NCCL plugin 是否加载。

### 8.8 FSx / S3 挂载验证
仓库内已带可直接使用的示例 manifest:[`examples/fsx-app.yaml`](https://github.com/KevinZhao/eks-cluster-deployment/blob/master/examples/fsx-app.yaml) 与 [`examples/s3-app.yaml`](https://github.com/KevinZhao/eks-cluster-deployment/blob/master/examples/s3-app.yaml),分别覆盖 FSx for Lustre PERSISTENT_2、Standard S3 桶与 S3 Express One Zone 三种挂载场景。两个 YAML 都使用 `envsubst` 占位符,用法见各文件头部注释。

```bash
# FSx for Lustre 静态挂载(两个 Pod 共享读写,验证 RWX)
export FSX_ID=fs-xxxxxxxxxxxxxxxxx
export FSX_DNS=fs-xxx.fsx.us-east-1.amazonaws.com
export FSX_MOUNT_NAME=xxxxx
envsubst < examples/fsx-app.yaml | kubectl apply -f -
kubectl logs fsx-test-1   # 期望:在 /data 写入 100MB 测试文件
kubectl logs fsx-test-2   # 期望:从同一 PVC 读到 Pod 1 写的文件

# Standard S3 + S3 Express One Zone 挂载
source scripts/0_setup_env.sh
export S3_BUCKET_NAME=your-standard-bucket
export S3_EXPRESS_BUCKET_NAME=your-bucket--use1-az1--x-s3
export AWS_REGION=us-east-1
envsubst < examples/s3-app.yaml | kubectl apply -f -
kubectl logs s3-test          # Standard 桶
kubectl logs s3-express-test  # S3 Express directory bucket
```

### 8.9 生产就绪清单
- [ ] GPU 节点的 EFA 网卡数量与实例类型匹配
- [ ] `GPU_INSTALL_EFA_USERSPACE=true` 已启用(若工作负载依赖 host libfabric)
- [ ] Instance Store 已 stripe 至 `/data`,且不承载容器运行时
- [ ] 拓扑 label 已贴,工作负载已配置 `nodeAffinity`
- [ ] **GPU 安全组同时包含 inbound + outbound 自引用规则**(EFA 跨节点通信硬性要求,见 §2.7)
- [ ] **跨节点 NCCL 验证已通过**(`option_verify_gpu_efa.sh --multi 2`),NCCL_DEBUG 显示走 AWS-OFI-NCCL 而非 TCP fallback
- [ ] FSx for Lustre 使用 PERSISTENT_2
- [ ] S3 Express bucket ARN 格式与 Pod Identity 策略一致
- [ ] GPU 工作负载使用 Pod Identity,而非静态凭证

---

## 九、总结:能力沉淀与取舍原则

### 9.1 能力沉淀
本文在第一篇的集群基础上,把 GPU 工作负载的**计算、网络、存储**三层架构一次性打通:
- **计算层**:覆盖 P5 / P5en / P6 / G7e 四个系列,包含 p6-b300 的非对称拓扑处理,EFA userspace 自动补齐
- **网络层**:直接使用 cloud-controller-manager 写入的 `topology.k8s.aws/network-node-layer-N` 进行调度,让工作负载按 bottom-layer network node 粒度选择节点
- **存储层**:训练高聚合吞吐用 FSx for Lustre(PERSISTENT_2,GB/s 级吞吐);S3 Express One Zone 作为低延迟、高 TPS 的对象存储选项,按访问模式(高 TPS 小对象 random read、低延迟写、scale-out 模型分发)选用,而不是按工作负载类型简单归类

### 9.2 三组关键取舍
- **Placement Group vs Topology Label**:在 p5 类型上,PG 的行为需要验证后再投入生产;标签化调度给工作负载更多控制权
- **ODCR vs Capacity Block**:ODCR 适合长期稳定的训练集群,Capacity Block 适合有明确时间窗口的短期大规模训练
- **FSx vs S3 Express One Zone**:按访问模式选——大文件聚合顺序读 + Lustre 并行语义选 FSx;小对象高 TPS random read、低延迟写、跨 Pod 并发拉同一对象选 S3E1;大文件一次性顺序读且能容忍 10–30 ms 延迟用 Standard S3 即可

### 9.3 系列回顾:两篇文章的定位
- **第一篇**《企业级 EKS 集群生产环境配置最佳实践》—— 通用生产级集群的"**地基**":私有 API、Pod Identity、LVM 运行时隔离、四种 CSI Driver、自动化部署脚本
- **第二篇**(本文)—— GPU 工作负载的"**上层建筑**":EFA 多网卡、拓扑感知调度、按访问模式的高性能存储选型(FSx for Lustre + S3 Express One Zone)

两篇构成一套可落地、可复制、从零到 GPU 生产的完整参考实现。

**下一步行动：**

* 克隆开源仓库 [eks-cluster-deployment](https://github.com/KevinZhao/eks-cluster-deployment)，先按照第一篇完成基础集群部署。
* 在 VPC 内的堡垒机上执行 `./scripts/option_install_gpu_nodegroups.sh` 创建 GPU 节点组，按需选择 On-Demand / Spot / ODCR / Capacity Block 四种定价模式。
* 通过 `./scripts/option_show_nodegroup_topology.sh` 打印每个 GPU 节点组的 AWS 原生拓扑清单(按 bottom-layer network node 分组),用于拓扑感知调度的决策。
* 高聚合吞吐顺序读场景挂载 FSx for Lustre（PERSISTENT_2）；高 TPS 小对象 random read、低延迟写或 scale-out 模型分发等访问模式挂载 S3 Express One Zone + Mountpoint CSI Driver。

**相关产品：**

* [Amazon EKS](https://aws.amazon.com/cn/eks/)
* [Amazon EC2 P5 实例](https://aws.amazon.com/cn/ec2/instance-types/p5/)
* [AWS Elastic Fabric Adapter（EFA）](https://aws.amazon.com/cn/hpc/efa/)
* [Amazon FSx for Lustre](https://aws.amazon.com/cn/fsx/lustre/)
* [Amazon S3 Express One Zone](https://aws.amazon.com/cn/s3/storage-classes/express-one-zone/)
* [Mountpoint for Amazon S3](https://aws.amazon.com/cn/s3/features/mountpoint/)
* [NVIDIA Device Plugin for Kubernetes](https://github.com/NVIDIA/k8s-device-plugin)

**相关文章：**

* 系列第一篇：《企业级 EKS 集群生产环境配置最佳实践》
* [Amazon EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
* [Amazon EC2 Instance Topology API](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-topology.html)
* [Accelerate machine learning model training with Amazon SageMaker and Amazon S3 Express One Zone](https://aws.amazon.com/about-aws/whats-new/2024/02/machine-learning-model-training-amazon-sagemaker-s3-express-one-zone/)
* [Choosing an S3 connector for ML training with S3 Express One Zone (AWS re:Post)](https://repost.aws/articles/AROs3zfLYxT56d3MAKp28Tqg/choosing-an-s3-connector-for-ml-training-with-s3-express-one-zone)

**本篇作者**

**Kevin Zhao**
AWS 解决方案架构师，专注于 Amazon EKS 与 GPU 工作负载的生产级落地实践，包括 EFA 多网卡配置、拓扑感知调度、按访问模式选型的高性能存储等。完整的部署脚本已在 [GitHub](https://github.com/KevinZhao/eks-cluster-deployment) 开源。
