# 自实现软同步识别与归类样例

以下样例来自 shmem 仓 examples 的真实代码模式，用于说明如何识别自实现软同步并判断其同步语义。

## 1. 卡间 signal（set/wait，基于 GM 地址）

典型特征：一个 rank 通过 RDMA put / 直接写 GM 地址发信号，另一个 rank 轮询该 GM 地址直到值满足条件。

```cpp
// set 侧（rank 0 向对端写 flag）
MSTX_SOFT_SYNC_FUSE_SCOPE_START();
aclshmem_uint8_put_nbi(flag_addr, src, sizeof(uint32_t), peer);
MSTX_SOFT_SYNC_FUSE_SCOPE_END();
MSTX_SOFT_SYNC_SIGNAL_SET_REPORT(flag_addr, rank + MAGIC_VAL);

// wait 侧（rank 1 轮询本地 flag）
MSTX_SOFT_SYNC_FUSE_SCOPE_START();
while (*(__gm__ uint32_t*)flag_addr != peer + MAGIC_VAL) {
    dcci_cachelines(flag_addr, sizeof(uint32_t));
}
MSTX_SOFT_SYNC_FUSE_SCOPE_END();
MSTX_SOFT_SYNC_SIGNAL_WAIT_REPORT(flag_addr, Sanitizer::CompareOp::EQ, peer + MAGIC_VAL);
```

> 宏 `MSTX_SOFT_SYNC_FUSE_SCOPE_START/END`、`MSTX_SOFT_SYNC_SIGNAL_SET_REPORT`、`MSTX_SOFT_SYNC_SIGNAL_WAIT_REPORT` 在算子文件顶部按 [sanitizer-interface.md](sanitizer-interface.md) 的模式自行封装（基于 `Sanitizer::` 原始接口，宏名以 `MSTX_` 开头、以 `SOFT_SYNC` 与 shmem 内部 `MSTX_*` 宏区分）。

- 归类：`MstxSignalSet` / `MstxSignalWait`
- 配对：set 与 wait 通过 `addr` 配对，对称内存下数值相同。

## 2. 核间 set/wait（计数型）

典型特征：同卡内 AIC↔AIV，生产者用 `AtomicAdd` 累加计数，消费者轮询计数达到目标值。

```cpp
// 生产者（AIV 完成某 wave 的 dispatch 后累加计数）
AtomicAdd(waveReadyFlags + w, dispatchedRows);

// 消费者（AIC 轮询计数到目标值）
while (AscendC::ReadGmByPassDCache(readinessFlag) != targetValue) {
    /* spin */
}
```

- 归类：核间 set/wait（`MstxCrossCoreSetFlag` / `MstxCrossCoreWaitFlag`）
- 注意：本质是「一方发布、另一方等待计数达到目标」，非 barrier（不是所有核到齐才释放）。

## 3. 卡间 barrier（跨 rank 所有核到达才继续）

典型特征：跨 rank 写远端 flag + 轮询自己 flag，所有参与核到达后继续。

```cpp
// SynchronizeRanks 简化示意（AIV only，跨 rank）
int count = ReadGmByPassDCache(syncCount) + 1;
for (int i = 0; i < rankCount_; i++) {
    WriteGmByPassDCache(remoteFlag[i], count);   // 写远端 flag
    WaitForRankGeneration(localFlag[i], count);  // 轮询本地 flag
}
WriteGmByPassDCache(syncCount, count);
```

- 归类：卡间 barrier（`MstxCrossNpuBarrier`），`isAIVOnly = true`。
- 隐含全流水 barrier 与核间 barrier 语义。

## 4. 同卡核间 barrier（生产者-消费者，allgather 实测）

典型特征：同一张卡内，生产者 core 写完数据后写 flag 通知，消费者 core 用 `get_nbi` 读 flag 轮询、就绪后再读数据。racecheck 误报的是「生产者写数据 vs 消费者读数据」的**数据区** RAW hazard。

```cpp
// 消费者侧（block 8-15，自行实现轮询）
MSTX_SOFT_SYNC_FUSE_SCOPE_START();
aclshmem_int32_get_nbi(flags_ub2[group_idx], gva_sync_gm + group_idx * SYNC_FLAG_INTERVAL, 1, x); // 读 flag
MSTX_SOFT_SYNC_FUSE_SCOPE_END();
AscendC::PipeBarrier<PIPE_ALL>();
if ((*flags_ub2[group_idx] >> 10) != (magic >> 10)) continue;          // 轮次不匹配
int64_t ready_num = *flags_ub2[group_idx] - magic;
if (ready_num <= 0 || *flags_ub1[group_idx] >= ready_num) continue;    // 未就绪
// wait 成功（就绪）后再上报，而非在“读 flag”处上报
MSTX_SOFT_SYNC_CROSS_CORE_BARRIER_REPORT(aivNum);
aclshmemx_mte_get_nbi(output_gm + ..., gva_data_gm + ..., ...);          // 读数据
```

- 归类：**同卡多核 → `MstxCrossCoreBarrier`（核间 barrier）**。
- 关键经验：
  1. 该场景用 `MstxSignalSet`/`Wait` 上报**无效**（signal 的 happens-before 按地址，只覆盖 flag 区，跨不到数据区）；核间 barrier 的 happens-before 全局，可消除数据区写-读误报。
  2. 上报时机应在 **wait 成功（就绪）后**，而不是「读 flag」处。
  3. `usedCoreNum` 取参与同步的核数（如 `aivNum`）。

## 识别要点速查

| 代码模式 | 是否软同步 | 归类 |
|----------|-----------|------|
| `while (*(__gm__ T*)a != v)` + `dcci_cachelines` | 是（跨卡/跨核轮询） | signal wait 或核间 set/wait |
| `*(__gm__ T*)a = v` / `WriteGmByPassDCache` | 是（写 flag） | signal set 或核间 set |
| `AtomicAdd(flag, n)` + 对端轮询计数 | 是（计数型） | 核间 set/wait |
| 跨 rank 写 flag + 轮询 + 计数回写 | 是 | 卡间 barrier |
| 同卡 get_nbi 读 flag 轮询 + 数据写/读（生产者-消费者） | 是 | 核间 barrier（signal 无效，按地址不跨数据区） |
| `SetFlag` / `WaitFlag` / `PipeBarrier` | 否（核内硬同步） | 不处理 |
| `CrossCoreSetFlag` / `CrossCoreWaitFlag` | 否（硬件核间同步） | 不处理 |
| `aclshmem_signal_wait_until` / `aclshmemx_signal_op` 等 | 否（已封装并内部上报） | 不处理 |
