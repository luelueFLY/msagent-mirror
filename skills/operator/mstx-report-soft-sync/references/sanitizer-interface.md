# Sanitizer 接口参考（sanitizer_report.h）

来源：`$ASCEND_HOME_PATH/tools/mssanitizer/include/sanitizer_report.h`（CANN mssanitizer 组件头文件）。

## include

```cpp
#include "sanitizer_report.h"
```

编译时需将 `$ASCEND_HOME_PATH/tools/mssanitizer/include` 加入 include 路径（算子工程接入 mssanitizer 时通常已包含）。

## 核心接口

```cpp
namespace Sanitizer {

// 标记软同步逻辑开始/结束，此范围内指令不会被 racecheck 检测
inline [aicore] void SanitizerFuseScopeStart();
inline [aicore] void SanitizerFuseScopeEnd();

// 上报同步语义（模板，按 RecordT 路由到对应 InterfaceType）
template<typename RecordT>
inline [aicore] void SanitizerReport(RecordT const &record);

}
```

> 三个函数仅在 `__MSTX_DFX_REPORT__` 宏定义时真正生效（内部调用 `__mstx_dfx_report_stub`）；未定义时为空实现，不影响普通编译。该宏由 mssanitizer 构建流程注入，算子代码无需自行定义。

## 同步语义结构体

```cpp
// 核间 barrier
struct MstxCrossCoreBarrier {
    uint32_t usedCoreNum;     // 参与同步核数，0 表示所有核
    uint32_t *usedCoreId;     // 预留：参与同步的 blockIdx
    bool isAIVOnly;           // 是否仅 AIV 参与
    bool pipeBarrierAll;      // false=仅 PIPE_S；true=所有流水参与
};

// 核间 set / wait
struct MstxCrossCoreSetFlag {
    int32_t eventId;          // 事件对 ID，<0 不限制配对
    int32_t peerCoreId;       // 对端 coreId，<0 不限制
    bool pipeBarrierAll;
};
struct MstxCrossCoreWaitFlag {
    int32_t eventId;
    int32_t peerCoreId;
    bool pipeBarrierAll;
};

// 卡间 signal（基于 GM 地址）
struct MstxSignalSet {
    uint64_t addr;            // 信号写入的 GM 地址
    int64_t value;            // 写入的值
};
struct MstxSignalWait {
    uint64_t addr;            // 轮询的 GM 地址
    int64_t cmpValue;         // 条件比较值
    CompareOp cmpOp;          // 条件比较方法
};

// 卡间 barrier（隐含全流水 barrier 和核间 barrier）
struct MstxCrossNpuBarrier {
    uint32_t usedDeviceNum;   // 参与同步 device 数，0 表示全部
    uint32_t *usedDeviceId;   // 预留：参与同步 deviceId
    uint32_t usedCoreNum;     // 参与同步 core 数，0 表示全部
    uint32_t *usedCoreId;     // 预留：参与同步 coreId
    bool isAIVOnly;           // 是否仅 AIV 同步
    bool pipeBarrierAll;
};
```

## CompareOp 枚举

```cpp
enum class CompareOp {
    EQ = 0, NE, GT, GE, LT, LE
};
```

与 shmem 的 `aclshmem_cmp_op_type_t`（`ACLSHMEM_CMP_EQ = 0, NE, GT, GE, LT, LE`）数值完全对齐，可直接 `(Sanitizer::CompareOp)ACLSHMEM_CMP_EQ` 或写 `Sanitizer::CompareOp::EQ`。

## InterfaceType 枚举（内部路由，理解用）

```cpp
enum class InterfaceType : uint32_t {
    MSTX_SET_CROSS_SYNC = 0, MSTX_WAIT_CROSS_SYNC,
    MSTX_HCCL, MSTX_HCCLV,
    MSTX_CROSS_CORE_BARRIER = 4,
    MSTX_CROSS_CORE_SET_FLAG,
    MSTX_CROSS_CORE_WAIT_FLAG,
    MSTX_SIGNAL_SET,
    MSTX_SIGNAL_WAIT,
    MSTX_CROSS_NPU_BARRIER,
    MSTX_FUSE_SCOPE_START = 1000,   // 融合范围开始标记
    MSTX_FUSE_SCOPE_END,            // 融合范围结束标记
    // ... 其余为 vec / datacopy 等接口标记
};
```

`SanitizerReport(record)` 通过 `InterfaceTypeTraits<RecordT>` 特化自动路由到对应 InterfaceType，无需手动指定。

## 参数说明

| 结构体 | 字段 | 说明 |
|--------|------|------|
| MstxCrossCoreBarrier | usedCoreNum | 参与同步核数；0 = 所有核，>0 = 指定核数 |
| | usedCoreId | 预留；仅 usedCoreNum>0 时生效，空指针表示不限定 block，先到者参与 |
| | isAIVOnly | 是否仅 AIV 参与同步 |
| | pipeBarrierAll | false=各核仅 PIPE_S 同步；true=各核所有流水同步 |
| MstxCrossCoreSetFlag / WaitFlag | eventId | 同步事件对 ID；<0 不限制配对，>=0 仅相同 ID 配对 |
| | peerCoreId | 配对对端 coreId；<0 不限制，>=0 仅与指定 core 配对 |
| | pipeBarrierAll | 同上 |
| MstxSignalSet | addr | 信号写入的 GM 地址 |
| | value | 写入的值 |
| MstxSignalWait | addr | 信号读取（轮询）的 GM 地址 |
| | cmpValue | 条件比较值 |
| | cmpOp | 条件比较方法（EQ/NE/GT/GE/LT/LE） |
| MstxCrossNpuBarrier | usedDeviceNum | 参与同步 device 数；0 = 全部 |
| | usedDeviceId | 预留：参与 deviceId（长度与 usedDeviceNum 一致） |
| | usedCoreNum | 参与同步 core 数；0 = 全部 |
| | usedCoreId | 预留：参与 coreId |
| | isAIVOnly | 是否仅 AIV 同步 |
| | pipeBarrierAll | 同上 |

## 与 shmem 内部封装的关系

shmem 在 `src/device/utils/mstx/shmemi_mstx_report.h` 中将上述接口封装为 `MSTX_*` 宏（如 `MSTX_FUSE_SCOPE_START()`、`MSTX_SIGNAL_SET_REPORT(addr, val)`、`MSTX_BARRIER_NPU_REPORT(size, core_num)` 等），内部即构造对应结构体并调用 `Sanitizer::SanitizerReport`。

> 算子代码（尤其需移植到其他仓时）**建议直接用 `sanitizer_report.h` 的 `Sanitizer::` 接口**，避免依赖 shmem 内部头文件。
