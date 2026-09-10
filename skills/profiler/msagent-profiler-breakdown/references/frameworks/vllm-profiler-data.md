# vLLM / vLLM-Ascend PyTorch Profiler 采集数据与打点（torch.profiler · torch\_npu.profiler · MSTX）

> 消费 skill：`msagent-profiler-breakdown`（decompose.py，阶段归因 + 单次执行边界；prefill/decode 判别）；DB 数据接入见 `references/db-usage.md`
> 性质：采集侧**事实清单**（非规则），与 `vllm-instrumentation.md`（`record_function_or_nullcontext` scope 清单）互补。
> 来源：代码静态梳理（vLLM 主仓库 + vLLM-Ascend）。**不含** MS Service Profiler、**不含**可观测性/OpenTelemetry traces 打点。
> 范围：可用于拆解的采集字段（`record_function` scope · `PYTORCH_API` / `STEP_TIME` / `CANN_API` 等 DB 字段）；**不含** profiler 配置（activities / schedule / experimental\_config 等）。
> 对应原分析条目：**② PyTorch Profiler / torch\_npu.profiler 采集数据**。

***

## 1. 已核验不可用的打点通路（昇腾侧无实际采点，不再展开）

| 通路                    | 昇腾实际状态                                                                                                     |
| --------------------- | -------------------------------------------------------------------------------------------------------------- |
| `annotate_profile`（execute\_\* 注解） | **无**：`worker.py:740` 的 `execute_model` 不打注解，且 `TorchNPUProfilerWrapper` 未覆写 `annotate_context_manager` → 返回 `nullcontext()` |
| MSTX 打点               | **默认无采点**：vLLM-Ascend `torch_npu_profiler.py:53` `msprof_tx=False`，`PYTORCH_API` 表不会出现 `type='mstx'` 记录                       |

- 结论：prefill/decode 判别与 step 边界**不依赖以上通路**，改走 §2 的 `STEP_TIME` / `inputShapes` / attention kernel 类型 / `record_function` scope（见 `vllm-instrumentation.md`）。
- 若确需启用 MSTX 作精确锚点：把 `msprof_tx` 改为 `True` 重采，`PYTORCH_API.type='mstx'` 即可用。

***

## 2. 采集数据与字段 → 拆解维度映射（②「有哪些数据/字段」）

落地表结构全量见各 skill 的 `references/db-usage.md`（本 skill 关注的表/字段最小子集），本节只列**与拆解直接相关**的字段（避免重复全表）。

| 拆解维度              | 可用字段来源                                                                                                                      | 备注                                                    |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| step 边界           | `STEP_TIME.startNs/endNs`（A 策略直接来源）；`record_function_or_nullcontext` scope（见 `vllm-instrumentation.md`） | 主用 `STEP_TIME` / `forward` scope |
| prefill/decode 判别 | `PYTORCH_API.inputShapes`（batch/token 维）；attention kernel 类型                                                       | Ascend 无 prefill/decode 注解，靠 shape + kernel 类型      |
| 单层归属              | `PYTORCH_API.name` + `sequenceNumber` + `fwdThreadId` + `inputShapes` 序列对齐                                                  | module\_path 仅开模块层级采集才有                               |
| 层内归因              | `PYTORCH_API.name / inputShapes / inputDtypes`（`STRING_IDS` 反查）→ 命名/数据流推断                                                   | 见 `layer-decompose/references/layer-mapping.md`       |
| 通信归因              | `CommAnalyzerTime`（wait/sync/transit/idle）/ `CommAnalyzerMatrix`（rank 对）                                                    | `analysis.db`                                         |
| overlap 守恒        | `StepTraceTime.overlapped / communication_not_overlapped / bubble / free`                                                   | `analysis.db`，官方预拆                                    |
| 多卡映射              | `RANK_DEVICE_MAP`（rank→device）                                                                                              | PP 分层 / TP·EP 通信点                                     |

***

## 3. 关键澄清

1. `annotate_profile` 不是 `record_function_or_nullcontext` 通路——前者是 `torch.profiler.record_function`，后者是 `torch.autograd.profiler.record_function / nvtx / nullcontext`（详见 `vllm-instrumentation.md` §0）。
2. **Ascend 无** **`execute_*`** **注解**（`annotate_context_manager` 未覆写 → `nullcontext`），不要拿 `execute_context_*` 去昇腾 trace 里匹配；prefill/decode 改走 §2 的 shape / kernel 类型 / `STEP_TIME`。

