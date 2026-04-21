# cluster_analysis.db 数据库结构参考

## 概述

cluster_analysis.db 是 Ascend 集群性能分析工具 (MSProf) 生成的集群级别性能数据库。

## 表结构

### 1. ClusterStepTraceTime

Step级别的时间统计，记录每个rank在每个step的各项时间指标。

| 字段名 | 类型 | 说明 |
|-------|------|------|
| step | TEXT | Step名称/编号 |
| type | TEXT | 类型，通常为'rank' |
| index | TEXT | Rank索引 |
| computing | REAL | 计算时间（微秒） |
| communication_not_overlapped | REAL | 未重叠通信时间（微秒） |
| overlapped | REAL | 重叠时间（微秒） |
| communication | REAL | 总通信时间（微秒） |
| free | REAL | 空闲时间（微秒） |
| stage | REAL | Stage总时间（微秒） |
| bubble | REAL | Bubble时间 |
| communication_not_overlapped_and_exclude_receive | REAL | 排除接收的未重叠通信时间 |
| preparing | REAL | 准备时间 |
| dp_index | INTEGER | 数据并行索引 |
| pp_index | INTEGER | 流水线并行索引 |
| tp_index | INTEGER | 张量并行索引 |

### 2. ClusterCommunicationBandwidth

通信带宽详细信息。

| 字段名 | 类型 | 说明 |
|-------|------|------|
| step | TEXT | Step名称 |
| rank_id | INTEGER | Rank ID |
| hccl_op_name | TEXT | HCCL操作名称 |
| group_name | TEXT | 通信组名称 |
| band_type | TEXT | 带宽类型（HCCS/RDMA/SDMA/SIO） |
| transit_size | REAL | 传输大小（MB） |
| transit_time | REAL | 传输时间（微秒） |
| bandwidth | REAL | 带宽（GB/s） |
| large_packet_ratio | REAL | 大包比例 |
| package_size | REAL | 包大小 |
| count | INTEGER | 计数 |
| total_duration | REAL | 总持续时间 |

### 3. ClusterCommunicationMatrix

通信矩阵，记录rank之间的通信详情。

| 字段名 | 类型 | 说明 |
|-------|------|------|
| step | TEXT | Step名称 |
| hccl_op_name | TEXT | HCCL操作名称 |
| group_name | TEXT | 通信组名称 |
| src_rank | REAL | 源Rank |
| dst_rank | REAL | 目标Rank |
| transport_type | TEXT | 传输类型（HCCS/RDMA/LOCAL等） |
| op_name | TEXT | 操作名称 |
| transit_size | REAL | 传输大小（MB） |
| transit_time | REAL | 传输时间（微秒） |
| bandwidth | TEXT | 带宽（GB/s，字符串格式） |

### 4. ClusterCommunicationTime

通信时间统计。

| 字段名 | 类型 | 说明 |
|-------|------|------|
| step | TEXT | Step名称 |
| rank_id | INTEGER | Rank ID |
| hccl_op_name | TEXT | HCCL操作名称 |
| group_name | TEXT | 通信组名称 |
| start_timestamp | REAL | 开始时间戳 |
| elapsed_time | REAL | 总耗时（微秒） |
| transit_time | REAL | 传输时间（微秒） |
| wait_time | REAL | 等待时间（微秒） |
| synchronization_time | REAL | 同步时间（微秒） |
| idle_time | REAL | 空闲时间（微秒） |
| synchronization_time_ratio | REAL | 同步时间比例 |
| wait_time_ratio | REAL | 等待时间比例 |

### 5. HostInfo

主机信息。

| 字段名 | 类型 | 说明 |
|-------|------|------|
| hostUid | TEXT | 主机唯一标识 |
| hostName | TEXT | 主机名称 |

### 6. RankDeviceMap

Rank与设备映射关系。

| 字段名 | 类型 | 说明 |
|-------|------|------|
| rankId | INTEGER | Rank ID |
| deviceId | INTEGER | 设备ID |
| hostUid | TEXT | 主机唯一标识 |
| profilePath | TEXT | Profile数据路径 |

### 7. CommunicationGroupMapping

通信组映射信息。

| 字段名 | 类型 | 说明 |
|-------|------|------|
| type | TEXT | 类型（collective等） |
| rank_set | TEXT | Rank集合 |
| group_name | TEXT | 通信组名称 |
| group_id | TEXT | 通信组ID |
| pg_name | TEXT | 进程组名称 |

## 带宽类型说明

| 类型 | 说明 | 典型带宽 |
|-----|------|---------|
| HCCS | 华为芯片间高速互联 | 30-120 GB/s |
| RDMA | 远程直接内存访问（跨节点） | 10-25 GB/s |
| SDMA | 系统DMA | 50-100 GB/s |
| SIO | 串行IO | 50-100 GB/s |

## HCCL操作类型

| 操作类型 | 说明 |
|---------|------|
| allReduce | 全规约操作 |
| allGather | 全收集操作 |
| reduceScatter | 规约散射操作 |
| broadcast | 广播操作 |
| batchSendRecv | 批量发送接收 |
| alltoall | 全对全通信 |