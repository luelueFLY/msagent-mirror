# msSanitizer 告警大全

本文档系统梳理 msSanitizer 工具所有可能输出的告警/错误信息，按检测子工具分类，逐条说明每个参数的具体含义。并给出代码示例说明产生告警可能的错误原因。

---

## 告警级别说明

| 级别 | 含义 | 处理建议 |
|------|------|----------|
| `ERROR` | 确定性错误，必然导致运行异常或结果错误 | 必须修复 |
| `WARNING` | 不确定性风险，是否触发异常取决于实际运行情况 | 强烈建议检查 |
| `INFO` | 信息性输出，用于调试跟踪 | 仅供参考 |

---

## 通用输出元素说明

以下为所有告警输出中的共性元素，在各告警详解中不再重复说明。

### Block 信息格式

Block 索引在输出中有多种展示形式，取决于设备类型：

| 格式 | 含义 | 示例 |
|------|------|------|
| `aiv(N)` | 单个 Vector block | `aiv(0)` |
| `aiv(N-M)` | 连续的 Vector block 范围 | `aiv(0-7)` |
| `aiv(N,M)` | 离散的 Vector block 列表 | `aiv(0,2,5)` |
| `aic(N)` | 单个 Cube block | `aic(0)` |
| `aicore(N)` | 不区分 aiv/aic 场景下的 block | `aicore(0-3)` |

### 调用栈格式

当编译时添加 `-g` 选项，异常报告会包含调用栈：

```
======    #0 <filePath>:<lineNo>:<colNo>   ← 最近的调用帧（异常直接发生处）
======    #1 <filePath>:<lineNo>:<colNo>   ← 上一级调用
======    #2 <filePath>:<lineNo>:<colNo>
======    #3 <userCode>.cpp:<lineNo>:<colNo> ← 最终定位到用户代码
```

无调用栈时的替代格式（仅文件名和行号）：

```
======    code in <fileName>:<lineNo> (serialNo:<serialNo>)
```

### 地址空间枚举

| 输出 | 含义 |
|------|------|
| `GM` | Global Memory（全局内存/外部存储） |
| `UB` | Unified Buffer（统一缓冲区） |
| `L1` | L1 Cache/Buffer |
| `L0A` | L0 Buffer A |
| `L0B` | L0 Buffer B |
| `L0C` | L0 Buffer C |

### 告警级别判定规则

| MemErrorType | 级别 | 原因 |
|---|---|---|
| `OUT_OF_BOUNDS` | WARNING | 多核踩踏是否生效取决于核间实际执行时序 |
| `ILLEGAL_ADDR_READ/WRITE` | ERROR | 确定性越界 |
| `MISALIGNED_ACCESS` | ERROR | 确定性对齐错误 |
| `ILLEGAL_FREE` | ERROR | 确定性释放错误 |
| `MEM_LEAK` | ERROR | 确定性内存泄漏 |
| `MEM_UNUSED` | WARNING | 可能是有意预留，也可能是逻辑错误 |
| `UNINITIALIZED_READ` | ERROR | 确定性脏数据读取 |
| `INTERNAL_ERROR` | ERROR | 内部异常 |

---

## 一、内存检测 (MemCheck)

### 1.1 非法写入 (ILLEGAL_ADDR_WRITE)

**级别**：`ERROR`

```
====== ERROR: illegal write of size <nBadBytes>
======    at <badAddr> on <space> in <kernelName>
======    in block aiv(<blocks>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `nBadBytes` | 非法写入的字节数 |
| `badAddr` | 非法访问的目标内存地址（十六进制） |
| `space` | 地址空间类型：GM（全局内存）、UB（统一缓冲区）、L1、L0A/L0B/L0C |
| `kernelName` | 发生异常的核函数名（仅 Kernel 侧异常显示） |
| `blocks` | 异常涉及的 block 索引，支持范围展示（如 `0-3`）和逗号分隔（如 `0,1,3`） |
| `deviceId` | 昇腾设备编号 |
| `pc` | 异常指令的程序计数器值（十六进制） |
| `serialNo` | 调用 API 行为的序列号，用于追踪指令执行顺序 |
| `#N` | 调用栈帧，从最近到最远，包含文件路径、行号和列号 |

**异常代码示例1 - GM/UB 越界写**：

```cpp
// GM 仅分配 100 字节，memset 写入 1000 字节 → 越界写入
void *aDevice;
aclrtMalloc(&aDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtMemset(aDevice, 1000, 0, 1000);  // count 超出分配大小 900 字节
```

**异常代码示例2 - 非法地址写入**：

```cpp
// 写入到分配块之前（地址偏移 -100）→ 非法写入
void *aDevice;
aclrtMalloc(&aDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtMemset((uint8_t*)aDevice - 100, 100, 0, 100);  // 目标地址在分配块之外
```

**异常代码示例3 - L1 非法写入**：

```cpp
// copy_gm_to_cbuf_v2 写入超出 L1 Buffer 范围 → L1 非法写入
auto cbuf = (__cbuf__ void *)get_imm(524288);  // 超出 L1 大小
auto gm = (__gm__ void *)get_imm(64);
copy_gm_to_cbuf_v2(cbuf, gm, config0, config1);
```

### 1.2 非法读取 (ILLEGAL_ADDR_READ)

**级别**：`ERROR`

```
====== ERROR: illegal read of size <nBadBytes>
======    at <badAddr> on <space> in <kernelName>
======    in block aiv(<blocks>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

参数含义同 [非法写入](#11-非法写入-illegal_addr_write)，区别在于 `read` vs `write`。

**异常代码示例1 - UB越界读**：

```cpp
// DataCopy 反向：UB 未写入即读取 → 非法读取
LocalTensor<half> xLm = tbuf.Get<half>();
GlobalTensor<half> xGm;
xGm.SetGlobalBuffer((__gm__ half*)gm + 32, DMA_MOV_NUM);

// UB→GM 拷贝：xLm 未初始化 → UB 越界读 + GM 越界写
DataCopy(xGm, xLm, DMA_MOV_NUM);
```

**异常代码示例2 - aclrtMemcpy 非法源地址**：

```cpp
void *aDevice, *bDevice;
aclrtMalloc(&aDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtMalloc(&bDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
// 源地址偏移 -100 → 读取越界
aclrtMemcpy(aDevice, 100, (uint8_t*)bDevice - 100, 100, ACL_MEMCPY_DEVICE_TO_DEVICE);
```

**异常代码示例3 - GM 越界读**：

```cpp
// 读取超出 GM 分配范围的地址
auto gm = (__gm__ void *)get_imm(64);
auto cbuf = (__cbuf__ void *)get_imm(0);
copy_gm_to_cbuf_v2(cbuf, gm, config0, config1);  // gm 偏移 64 字节，超出分配范围
```

### 1.3 多核踩踏 (OUT_OF_BOUNDS)

**级别**：`WARNING`

```
====== WARNING: out of bounds of size <nBadBytes>
======    at <badAddr> on <space> when writing data in <kernelName>
======    in block aiv(<blocks>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `nBadBytes` | 发生踩踏的字节数 |
| `badAddr` | 踩踏发生的 GM 内存首地址 |
| `space` | 地址空间（通常为 GM） |
| `kernelName` | 发生异常的核函数名 |
| `blocks` | 涉及的所有 block 索引 |
| `pc` | 异常指令的程序计数器值（十六进制） |
| `serialNo` | 调用 API 行为的序列号 |
| `#N` | 调用栈帧，从最近到最远，包含文件路径、行号和列号 |

> 触发机制：当一块内存被某个核写入后，该内存由该核"所有"。其他核对这块内存再次写入时触发此告警。

**异常代码示例1 - 多核GM踩踏**：

```cpp
// 多核场景：使用 copy_ubuf_to_gm_align_v2 搬运数据，
// 搬运的目标 GM 地址区域可能与其他核的写入区域重叠
copy_ubuf_to_gm_align_v2((__gm__ void*)a, ub, config0, config1);
auto gmData = (__gm__ uint32_t*)a;
gmData[10] = 20;  // 多核同时写入同一 GM 区域 → 踩踏
```

**异常代码示例2 - Cube 核多核踩踏**：

```cpp
// Cube 核通过 copy_cbuf_to_gm 写入 GM，多核间缺少 ffts_cross_core_sync
copy_cbuf_to_gm(gm_output + get_block_idx() * N * 2, l1_buf, 0, N * 2 / 256, 32, 0, 0);
// 缺少 ffts_cross_core_sync → 各核写入区域可能重叠
```

**异常代码示例3 - Vector 核多核踩踏**：

```cpp
// Vector 核通过 copy_ubuf_to_gm 搬运数据后未执行核间同步
copy_ubuf_to_gm(workspace, buf, 0, 1, N / 8, 0, 0);
// 缺少 ffts_cross_core_sync / wait_flag_dev → 多核 GM 踩踏
```


### 1.4 非对齐访问 (MISALIGNED_ACCESS)

**级别**：`ERROR`

```
====== ERROR: misaligned access of size <nBadBytes>
======    at <badAddr> on <space> in <kernelName>
======    in block aiv(<blocks>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `nBadBytes` | 非对齐访问的字节数 |
| `badAddr` | 非对齐的地址 |
| `space` | 地址空间（GM/UB/L1/L0{A,B,C}） |
| `blocks` | 异常涉及的 block 索引 |
| `deviceId` | 昇腾设备编号 |
| `pc` | 异常指令的程序计数器值（十六进制） |
| `serialNo` | 调用 API 行为的序列号 |
| `#N` | 调用栈帧，从最近到最远，包含文件路径、行号和列号 |

> 触发机制：DMA 搬运的地址与内存最小访问粒度不对齐时触发。

**异常代码示例1 - UB 非对齐访问**：

```cpp
// UB 地址偏移应为 32 字节对齐，此处使用 [3] 偏移 → 非对齐
LocalTensor<half> xLm = tbuf.Get<half>();
GlobalTensor<half> xGm;
xGm.SetGlobalBuffer((__gm__ half*)gm, NUM_DATA);

DataCopy(xGm, xLm[3], NUM_DATA);   // 错误：偏移 6 字节，非 32 字节对齐
DataCopy(xGm, xLm[32], NUM_DATA);  // 正确：偏移 64 字节，32 字节对齐
```

**异常代码示例2 - L1 非对齐访问**：

```cpp
// L1 Buffer 上 DataCopy 时源地址未按对齐粒度对齐
LocalTensor<half> xLm = xlm.Get<half>();  // L1 (A1)
GlobalTensor<half> xGm;
xGm.SetGlobalBuffer((__gm__ half*)gm, NUM_DATA);
DataCopy(xGm, xLm[3], NUM_DATA);  // xLm[3] 偏移 6 字节 → L1 非对齐
```

**异常代码示例3 - DBI 动态非对齐检测**：

```cpp
// 动态二进制插桩模式下，mov 指令的 GM↔UB 地址非对齐也会被检测
// 编译器优化后地址可能非 32 字节对齐 → misaligned access
```


### 1.5 非法释放 (ILLEGAL_FREE)

**级别**：`ERROR`

```
====== ERROR: illegal free()
======    at <badAddr> on GM
======    code in <fileName>:<lineNo> (serialNo:<serialNo>)
```

| 参数 | 含义 |
|------|------|
| `badAddr` | 被非法释放的 GM 地址 |
| `fileName` | 执行释放操作的源文件名 |
| `lineNo` | 执行释放操作的源代码行号 |
| `serialNo` | 调用 API 行为序列号 |

> 触发机制：对未分配或已释放的地址执行 free 操作（含 double free）。

**异常代码示例1 - double free**：

```cpp
void* ptr = nullptr;
aclrtMalloc(&ptr, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtFree(ptr);
aclrtFree(ptr);  // double free → 非法释放
```

**异常代码示例2 - 释放非法偏移指针**：

```cpp
void* ptr = nullptr;
aclrtMalloc(&ptr, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtFree((uint8_t*)ptr - 100);  // 指针不在分配块起始 → 非法释放
```

**异常代码示例3 — Host 内存被 Device free**：

```cpp
void* hostPtr = nullptr;
aclrtMallocHost(&hostPtr, 100);
aclrtFree(hostPtr);  // Host 内存不能用 aclrtFree 释放 → 非法释放
```


### 1.6 内存泄漏 (MEM_LEAK)

**级别**：`ERROR`

**单条泄漏信息**：
```
======    Direct leak of <nBadBytes> byte(s)
======      at <badAddr> on GM[ by module <moduleId>]
======      allocated in <fileName>:<lineNo> (serialNo:<serialNo>)
```

**汇总信息**：
```
====== ERROR: LeakCheck: detected memory leaks

<单条泄漏信息 1>
<单条泄漏信息 2>
...
====== SUMMARY: <lenSum> byte(s) leaked in <count> allocation(s)
```

| 参数 | 含义 |
|------|------|
| `nBadBytes` | 本次泄漏的字节数 |
| `badAddr` | 泄漏内存的首地址 |
| `moduleId` | CANN 软件栈模块 ID（仅 `--check-cann-heap=yes` 时显示） |
| `fileName` | 分配该内存的源文件名 |
| `lineNo` | 分配该内存的源代码行号 |
| `serialNo` | 分配操作的序列号 |
| `lenSum` | 泄漏总字节数 |
| `count` | 泄漏发生的分配次数 |

> 需通过 `--leak-check=yes` 开启。

**异常代码示例1 - 分配后未释放**：

```cpp
// 分配后未释放：aclrtMalloc 分配了内存但从未调用 aclrtFree
void *aDevice, *bDevice;
aclrtMalloc(&aDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtMallocCached(&bDevice, 1000, ACL_MEM_MALLOC_HUGE_FIRST);
// 缺少 aclrtFree(aDevice) 和 aclrtFree(bDevice) → 1100 字节泄漏
```

**异常代码示例2 — Cached 内存泄漏**：

```cpp
// aclrtMallocCached 分配的内存也需要显式释放
void *cachedDevice;
aclrtMallocCached(&cachedDevice, 1024, ACL_MEM_MALLOC_HUGE_FIRST);
// 缺少 aclrtFree(cachedDevice) → 1024 字节泄漏
```


### 1.7 分配内存未使用 (MEM_UNUSED)

**级别**：`WARNING`

```
====== WARNING: Unused memory of <nBadBytes> byte(s)
======    at <badAddr> on GM
======    code in <fileName>:<lineNo> (serialNo:<serialNo>)
====== SUMMARY: <bytesNotUse>byte(s) unused memory in <blockNum> allocation(s)
```

| 参数 | 含义 |
|------|------|
| `nBadBytes` | 未使用内存的字节数 |
| `badAddr` | 未使用内存的首地址 |
| `fileName` | 分配该内存的源文件名 |
| `lineNo` | 分配该内存的源代码行号 |
| `serialNo` | 分配操作的序列号 |
| `bytesNotUse` | 未使用内存总字节数 |
| `blockNum` | 未使用的内存块个数 |

> 需通过 `--check-unused-memory=yes` 开启。

### 1.8 未初始化读取 (UNINITIALIZED_READ)

**级别**：`ERROR`

```
====== ERROR: uninitialized read of size <nBadBytes>
======    at <badAddr> on <space> in <kernelName>
======    in block aiv(<blocks>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

参数含义同 [非法读取](#12-非法读取-illegal_addr_read)。

> 触发机制：申请内存后未写入就直接读取。覆盖 GM、UB、L1、L0{ABC}、栈空间。

**异常代码示例1 - GM 未初始化读取**：

```cpp
// GM 未初始化读取：xGm 仅初始化了 NUM_DATA 个 half，但 DataCopy 读取 192 个
GlobalTensor<half> xGm;
xGm.SetGlobalBuffer((__gm__ half*)gm, NUM_DATA);  // NUM_DATA = 128
LocalTensor<half> xLm = xlm.Get<half>();
DataCopy(xLm, xGm, 192);  // 读取 192 个 half，后 64 个未初始化 → GM 脏读
```

**异常代码示例2 - UB 未初始化读取**：

```cpp
LocalTensor<half> xLm = xlm.Get<half>();
GlobalTensor<half> xGm;
xGm.SetGlobalBuffer((__gm__ half*)gm, NUM_DATA);
DataCopy(xGm, xLm, 192);  // xLm 未初始化 → UB 脏读
```

**异常代码示例3 - L0C 未初始化读取**：

```cpp
// L0C 未写入即通过 copy_matrix_cc_to_gm 拷贝到 GM → L0C 脏读
copy_matrix_cc_to_gm((__gm__ int32_t*)gm, (__cc__ int32_t*)get_imm(0),
    sid, nSize, mSize, dstStride, srcStride, 0, 0, 0, 0, 1);
```

**异常代码示例4 - 栈变量未初始化读取**：

```cpp
// 栈变量 a 未初始化即赋值给 GM → PRIVATE 脏读
int a;
*gm = a;  // a 未初始化 → 脏数据写入 GM
```


### 1.9 GM 地址越界 (GM_ADDR_OUT_OF_BOUND)

**级别**：`ERROR`

```
====== ERROR: illegal write of size <nBadBytes> byte(s)
======    Access to <badAddr> on GM is <errDis> byte(s) after the nearest allocation at <baseAddr> of size <baseSize> byte(s)
======    in <kernelName> on device <deviceId>
======    code in <fileName>:<lineNo> (serialNo:<serialNo>)
```

| 参数 | 含义 |
|------|------|
| `nBadBytes` | 越界访问的字节数 |
| `badAddr` | 越界访问的实际地址 |
| `errDis` | 超出最近分配块末尾的偏移量（`badAddr - baseAddr - baseSize`） |
| `baseAddr` | 最近合法分配块的首地址 |
| `baseSize` | 最近合法分配块的大小（字节） |
| `kernelName` | 核函数名，若为 Host 侧则显示函数签名 |
| `deviceId` | 设备编号 |
| `fileName` / `lineNo` | 触发该异常的源代码位置 |

> 该告警专属 aicpu tiling 下沉场景的 GM 内存安全区越界检测。

**异常代码示例1 - GM 地址越界**：

```cpp
// GM 仅分配了 1000 字节（size=1000），但访问地址 0x12c0c00173e8
// 超出了最近分配块（0x12c0c0017000 + 1000 = 0x12c0c00173e8）
// 超出 0 字节（刚好在边界上），触发 GM_ADDR_OUT_OF_BOUND
uint8_t* gm = nullptr;
aclrtMalloc((void**)&gm, 1000, ACL_MEM_MALLOC_HUGE_FIRST);
gm[1000] = 0;  // 写入分配块末尾之后 → GM 地址越界
```

**异常代码示例2 - aclrtMemcpy 拷贝长度越界**：

```cpp
void *aDevice, *bDevice;
aclrtMalloc(&aDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtMalloc(&bDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
// 拷贝 1000 字节但源和目标各只分配了 100 字节 → 越界
aclrtMemcpy(aDevice, 1000, bDevice, 1000, ACL_MEMCPY_DEVICE_TO_DEVICE);
```

**异常代码示例3 — aclrtMemcpy2D 拷贝越界**：

```cpp
// 2D memcpy 时拷贝尺寸超出分配范围
void *aDevice;
aclrtMalloc(&aDevice, 100, ACL_MEM_MALLOC_HUGE_FIRST);
aclrtMemcpy2d(aDevice, 1000, bDevice, 1000, 100, 100, 100, 100, ACL_MEMCPY_DEVICE_TO_DEVICE);
```

### 1.10 寄存器告警

**级别**：`WARNING`

```
[mssanitizer] Warning:Register <regNameStr> was not reset to default in block <blockType>(<coreId>) on kernel <kernelName>. Expected default value is (<expVal>), but current value is (<actVal>)
```

| 参数 | 含义 |
|------|------|
| `regNameStr` | 未回归默认值的寄存器名称 |
| `blockType` | Block 类型（aiv/aic/aicore） |
| `coreId` | Block 索引号 |
| `kernelName` | 算子核函数名称 |
| `expVal` | 期望的寄存器默认值 |
| `actVal` | 当前实际的寄存器值 |

> 内存检测附加功能，当算子运行结束时指定寄存器值未重置时告警。

### 1.11 内部错误 (INTERNAL_ERROR)

**级别**：`ERROR`

```
====== ERROR: internal errors (serialNo:<serialNo>)
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `serialNo` | 触发异常的序列号 |
| `pc` | 异常指令的程序计数器值（十六进制） |
| `#N` | 调用栈帧，从最近到最远，包含文件路径、行号和列号 |

---

## 二、竞争检测 (RaceCheck)

### 2.1 数据竞争 (WAW / WAR / RAW)

**级别**：`ERROR`

```
====== ERROR: Potential <errType> hazard detected at <MemType> in <kernelName>:
======    <PIPE> <Read|Write> at <errType>()+0x<addr> in block <coreId> (<blockType>) on device <deviceId> at pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
======    <PIPE> <Read|Write> at <errType>()+0x<addr> in block <coreId> (<blockType>) on device <deviceId> at pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `errType` | 竞争类型：`WAW`（写后写）、`WAR`（读后写）、`RAW`（写后读） |
| `MemType` | 内存类型：GM（全局内存）、UB（统一缓冲区）等 |
| `kernelName` | 发生竞争的核函数名 |
| `PIPE` | 事件所在的流水：PIPE_MTE2、PIPE_MTE3、PIPE_V、PIPE_S 等 |
| `Read/Write` | 内存访问类型：读或写 |
| `addr` | 竞争内存的偏移地址（相对于 errType 基址，十六进制） |
| `coreId` | Block 索引号 |
| `blockType` | Block 类型（aiv/aic） |
| `deviceId` | 设备编号 |
| `pc` | 程序计数器值 |
| `serialNo` | 指令序列号，serialNo 小的在流水上先执行 |
| `#N` | 调用栈帧

> 竞争类型推导规则（由两个事件的访问类型决定）：
> - 事件1 Write + 事件2 Write → `WAW`
> - 事件1 Read + 事件2 Write → `WAR`（写先于读完成）
> - 事件1 Write + 事件2 Read → `RAW`（读先于写完成）

**异常代码示例1 - WAR 竞争**：

```cpp
// Block 0 先将数据搬到 UB 再 copy_ubuf_to_gm 写入 GM
// Block 1 随后从相同的 GM 地址 copy_gm_to_ubuf 读取
// Block 0 的 MTE3 Write 与 Block 1 的 MTE2 Read 之间缺少核间同步 → WAR

// Block 0 (aiv):
copy_ubuf_to_gm(workspace, buf, 0, 1, N / 8, 0, 0);
// 缺少 ffts_cross_core_sync / wait_flag_dev → 应在此处插入同步

// Block 1 (aiv, 在 block 0 的循环中):
copy_gm_to_ubuf(buf, gm_workspace + i * N, 0, 1, N / 8, 0, 0);  // 与 block 0 形成 WAR
```

**异常代码示例2 - WAW 竞争（AIC↔AIV）**：

```cpp
// Cube 核写入 GM 后未执行核间同步，Vector 核也写入同一 GM → WAW
// Cube (aic):
copy_cbuf_to_gm(gm_output + get_block_idx() * N * 2, l1_buf, 0, N * 2 / 256, 32, 0, 0);
// 缺少 ffts_cross_core_sync

// Vector (aiv):
copy_ubuf_to_gm(gm_output + id * N, ub_buf, 0, N / 256, 32, 0, 0);
// 与 Cube 核写入相同 GM 区域 → WAW
```

**异常代码示例3 — RAW 竞争**：

```cpp
// Block 0 先写 UB 再读，Block 1 先读 UB 再写 → RAW
// Block 0: vadd → V Write | Block 1: vrelu → V Read
// 两者操作同一 UB 区域且缺少同步 → RAW 竞争
```


### 2.2 卡间竞争 (Cross-NPU Race)

**级别**：`ERROR`

输出格式同 [2.1 数据竞争](#21-数据竞争-waw--war--raw)，但 `deviceId` 会跨不同设备编号。

> 需通过 `--check-cross-npu-races=yes` 开启。

**异常代码示例1 - FFTS 跨流水线竞争**：

```cpp
// FFTS 跨流水线竞争：vec 侧执行 copy_ubuf_to_gm（MTE3 读 UB 写 GM），
// 随后 vadd 写 UB，但同步仅等待了 MTE2 而非 MTE3 → MTE3 读 vs V 写形成 WAR
__ubuf__ float *buf = reinterpret_cast<__ubuf__ float *>((uintptr_t)0);
if (block_id == 0) {
    copy_ubuf_to_gm(workspace, buf, 0, 1, N / 8, 0, 0);  // MTE3 Read
}
ffts_cross_core_sync(PIPE_MTE2, config);  // 错误：应同步 MTE3 而非 MTE2
vadd(buf, buf, buf, 1, 1, 1, 1, 1, 1, 1);  // V Write → 与 MTE3 Read 形成 WAR
```

**异常代码示例2 — FFTS Mode 2 跨流水线竞争**：

```cpp
// FFTS Mode 2：Cube 核 SetFlag 后 Vec 核 WaitFlag，
// 但 Cube 的 MTE3 Write 与 Vec 的 MTE2 Read 之间缺少正确同步
// Cube (aic): set_flag → copy_cbuf_to_gm (MTE3 Write)
// Vec (aiv): wait_flag → copy_gm_to_ubuf (MTE2 Read)
// 两者操作同一 GM 区域 → 跨流水线 WAR
```


### 2.3 SIMT 线程间竞争

**级别**：`ERROR`

```
====== ERROR: Potential <errType> hazard detected at <MemType> in <kernelName>:
======     <Read|Write> Thread(<idX>,<idY>,<idZ>) at <errType>()+0x<addr> in block <coreId> (aiv) on device <deviceId> at pc current 0x<pc>
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
======     <Read|Write> Thread(<idX>,<idY>,<idZ>) at <errType>()+0x<addr> in block <coreId> (aiv) on device <deviceId> at pc current 0x<pc>
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

与标准竞争输出的区别：
- 事件来源标识为 `Thread(idX,idY,idZ)` 而非 `PIPE_xxx`
- 线程 ID 从 0 开始计数

| 参数 | 含义 |
|------|------|
| `idX, idY, idZ` | SIMT 线程三维坐标 |
| 其他参数 | 同 [2.1 数据竞争](#21-数据竞争-waw--war--raw) |

**异常代码示例1 - SIMT GM 线程竞争**：
```cpp
// SIMT 模式下，多个线程同时写入同一 GM 地址，缺少线程同步
auto gmPtr = (__gm__ float*)(gm_base + shared_offset);
*gmPtr = threadLocalValue;  // 多线程写入同一地址 → SIMT 线程间竞争
```


---

## 三、未初始化检测 (InitCheck)

未初始化检测与内存检测共享 `UNINITIALIZED_READ` 错误类型，输出格式参见 [1.8 未初始化读取](#18-未初始化读取-uninitialized_read)。

> 注意：由于硬件限制，某些指令仅支持 Block 形式搬运数据，当实际数据量非 Block 整数倍时可能带入无效数据导致误报，需自行判断这些"脏数据"是否影响计算结果。

---

## 四、同步检测 (SyncCheck)

### 4.1 SetFlag 未配对 (MATCH_CHECK)

**级别**：`WARNING`

```
====== WARNING: Unpaired set_flag instructions detected
======    from <srcPipe> to <dstPipe> in <kernelName>
======    in block <blockType>(<coreId>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `srcPipe` | 同步源流水（发出 SetFlag 的流水） |
| `dstPipe` | 同步目标流水（应执行 WaitFlag 的流水） |
| `kernelName` | 核函数名 |
| `blockType` | Block 类型（aiv/aic） |
| `coreId` | Block 索引号 |
| `deviceId` | 设备编号 |
| `pc` | 未配对的 SetFlag 指令的 PC 值 |
| `serialNo` | 指令序列号 |
| `#N` | 调用栈帧，从最近到最远，包含文件路径、行号和列号 |

> 触发机制：存在 SetFlag 指令但没有对应的 WaitFlag 指令来消费。多余 SetFlag 会改变硬件计数器状态，影响后续算子。

**异常代码示例1 - 单核 SetFlag 未配对**：

```cpp
// 多余的 SetFlag：声明了 eventIDSToMTE3 但 WaitFlag 只消费一次
int32_t eventIDSToMTE3 = static_cast<int32_t>(GetTPipePtr()->FetchEventID(HardEvent::S_MTE3));
SetFlag<HardEvent::S_MTE3>(eventIDSToMTE3);    // 第1个 SetFlag
SetFlag<HardEvent::S_MTE3>(eventIDSToMTE3);    // 第2个 SetFlag，多余的！
WaitFlag<HardEvent::S_MTE3>(eventIDSToMTE3);   // 只 Wait 一次 → 第1个 SetFlag 未配对
```

**异常代码示例2 - 多核 SetFlag 未配对**：

```cpp
// 多核场景：Block 0 发出 SetFlag 但其他 Block 未调用对应的 WaitFlag
if (GetBlockIdx() == 0) {
    SetFlag<HardEvent::V_MTE3>(eventID);
}
// 缺少：其他 block 的 WaitFlag<HardEvent::V_MTE3>(eventID) → 未配对
```

**异常代码示例3 — 混合同步未配对**：

```cpp
// MTE2→MTE3 和 S→MTE3 混合同步时，某个 eventID 的 SetFlag 缺少对应的 WaitFlag
int32_t eventM2M3 = FetchEventID(HardEvent::MTE2_MTE3);
int32_t eventSM3 = FetchEventID(HardEvent::S_MTE3);
SetFlag<HardEvent::S_MTE3>(eventSM3);       // SetFlag 发出
SetFlag<HardEvent::MTE2_MTE3>(eventM2M3);
WaitFlag<HardEvent::MTE2_MTE3>(eventM2M3);  // 只 Wait MTE2→MTE3
// 缺少 WaitFlag<HardEvent::S_MTE3>(eventSM3) → S→MTE3 未配对
```


### 4.2 冗余指令 (REDUNDANCY_CHECK)

**级别**：`WARNING`

```
====== WARNING: Redundant <set_flag|wait_flag> instructions detected
======    from <srcPipe> to <dstPipe> in <kernelName>
======    in block <blockType>(<coreId>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `set_flag/wait_flag` | 冗余指令类型 |
| 其他参数 | 同 [4.1 SetFlag 未配对](#41-setflag-未配对-match_check) |

> 触发机制：两个参数完全相同的 SetFlag（或 WaitFlag）连续出现，且中间无对目标流水的任何操作。

**异常代码示例1 - 冗余 SetFlag**：

```cpp
// 冗余 SetFlag：同一 eventID 的 SetFlag 连续出现两次，中间无任何操作
SetFlag<HardEvent::S_MTE3>(eventIDSToMTE3);
SetFlag<HardEvent::S_MTE3>(eventIDSToMTE3);  // 冗余！与上一行参数完全相同
```

**异常代码示例2 — 冗余 WaitFlag**：

```cpp
// 冗余 WaitFlag：同一 eventID 的 WaitFlag 连续出现两次
WaitFlag<HardEvent::MTE2_MTE3>(eventID);
WaitFlag<HardEvent::MTE2_MTE3>(eventID);  // 冗余！中间无任何操作
```

### 4.3 SIMT 线程分歧

**级别**：`ERROR`

```
====== ERROR: Sync error detected. Divergent thread(s) in <kernelName>
======    by thread(<idX>,<idY>,<idZ>) in block <blockType>(<coreId>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
```

| 参数 | 含义 |
|------|------|
| `kernelName` | 核函数名 |
| `idX, idY, idZ` | 发生分歧的 SIMT 线程坐标 |
| `blockType` | Block 类型（aiv/aic） |
| `coreId` | Block 索引号 |
| `deviceId` | 设备编号 |
| `pc` | 异常指令的程序计数器值（十六进制） |
| `serialNo` | 指令序列号 |
| `#N` | 调用栈帧，从最近到最远，包含文件路径、行号和列号 |

> 触发机制：同一 warp/wave 内的线程执行了不同的同步路径。

**异常代码示例1 - if-else 同步发散**：

```cpp
// SIMT 同步发散：不同线程执行不同路径，导致 syncthreads 等待不一致
int tid = get_thread_idx();
if (tid < 16) {
    // 部分线程执行同步
    syncthreads();   // 只有 tid<16 的线程到达此处
} else {
    // 其余线程不执行同步 → 发散！
}
```

**异常代码示例2 - 循环内同步发散**：

```cpp
// 循环内条件同步：不同迭代中线程执行不同路径
for (int i = 0; i < N; i++) {
    if (get_thread_idx() == i % 2) {
        syncthreads();  // 仅部分迭代中部分线程执行 → 发散
    }
}
```

**异常代码示例3 — 嵌套同步发散**：

```cpp
// 嵌套条件同步：外层和内层都有 syncthreads，但不同线程到达不同层级
if (tid < 32) {
    syncthreads();  // 外层同步
    if (tid < 16) {
        syncthreads();  // 内层同步，tid 16-31 的线程不执行 → 发散
    }
}
```

### 4.4 算子卡死检测

**级别**：`ERROR`

```
====== ERROR: Sync error detected. kernel locked up at
======    
======    <instructName> in <kernelName>
======    by <PIPE> in block <blockType>(<coreId>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
======    
======    <instructName> in <kernelName>
======    by <PIPE> in block <blockType>(<coreId>) on device <deviceId>
======    code in pc current 0x<pc> (serialNo:<serialNo>)
======    #0 <filePath>:<lineNo>:<colNo>
======    #1 ...
======    ...
======    
====== SUMMARY: <count> pipe(s) locked up.
```

| 参数 | 含义 |
|------|------|
| `instructName` | 卡住的指令名称（如 `WAIT_FLAG`） |
| `kernelName` | 核函数名 |
| `PIPE` | 卡住的流水类型 |
| `blockType` | Block 类型 |
| `coreId` | Block 索引号 |
| `deviceId` | 设备编号 |
| `pc` | 卡住指令的 PC 值 |
| `serialNo` | 指令序列号 |
| `#N` | 调用栈帧，从最近到最远，包含文件路径、行号和列号 |
| `count` | 卡住的流水总数 |

> 用户可通过 Ctrl-C 终止运行，第一次 Ctrl-C 终止算子进程，第二次 Ctrl-C 强制退出工具。

**异常代码示例1 - SetFlag/WaitFlag 不配对卡死**：

```cpp
// 算子卡死：WaitFlag 等待同步信号但对应的 SetFlag 不存在
int32_t eventID = static_cast<int32_t>(GetTPipePtr()->FetchEventID(HardEvent::MTE2_MTE3));
// 缺少 SetFlag<HardEvent::MTE2_MTE3>(eventID);
WaitFlag<HardEvent::MTE2_MTE3>(eventID); // → 硬件等待信号永不满足 → 卡死
```

**异常代码示例2 - SyncAll 部分参与卡死**：

```cpp
// 多核 SyncAll：仅部分 block 参与 SyncAll → 其余 block 卡死
if (GetBlockIdx() == 0) {
    SyncAll(syncGlobal, workLocal);  // Block 0 参与
} else {
    // 其他 block 未参与 SyncAll → Block 0 等待永不满足 → 卡死
}
```