# verl 框架 Profile —— 打点清单（stage\_taxonomy）

> 消费 skill：`msagent-profiler-breakdown`（decompose.py，阶段归因，backing=MSTX\_EVENTS）
> 承载维度：`stage_taxonomy`（阶段切分差异）
> 范围：强化学习（RL / PPO）场景；以昇腾 NPU 的 MSTX 打点 + PyTorch record\_function 打点为主
> 性质：声明式规则（引擎按字段读取，不感知框架名）
> 源码基线：`D:\code\Training\verl`（verl 仓库）
> 打点实现根文件：`verl/utils/profiler/mstx_profile.py`（NPU）、`verl/utils/profiler/torch_profile.py`（record\_function）

## 0. 打点机制总览

verl 的 RL 阶段打点存在两个视角、两套机制，需区分：

| 机制                        | 底层实现                                  | 打点位置                    | 视角               |
| ------------------------- | ------------------------------------- | ----------------------- | ---------------- |
| MSTX（昇腾 NPU）              | `mstx.range_start` / `mstx.range_end` | worker 方法 + trainer 控制流 | NPU device + CPU |
| record\_function（PyTorch） | `torch.profiler.record_function`      | 引擎前向/反向 + profiler 包装   | CPU              |

- MSTX 打点由 `torch_npu.npu.mstx` 产生，原始 API 为 `mark_start_range` / `mark_end_range`，以及 `marked_timer`（内部调用二者）。`mark_annotate`（`mstx.mstx_range` 装饰器）在生产代码中**未被调用**。

- 同一 RL 阶段在两个视角下有不同命名，例如：`old_log_prob`（trainer/driver 视角）↔ `actor_compute_log_prob`（worker 视角）。

***

## 1. RL 阶段语义（框架视角）

| stage（语义）        | 说明                          |
| ---------------- | --------------------------- |
| rollout / gen    | 采样生成（自回归 decode）            |
| reward           | 奖励计算                        |
| old\_log\_prob   | Actor 旧策略 log\_prob 前向      |
| ref\_log\_prob   | 参考策略（RefPolicy）log\_prob 前向 |
| values           | Critic 估值前向                 |
| adv              | 优势函数计算                      |
| update\_critic   | Critic 网络更新                 |
| update\_actor    | Actor 网络更新（PPO）             |
| update\_weights  | 权重同步到 rollout               |
| save\_checkpoint | checkpoint 保存               |
| testing          | 验证/测试                       |

***

## 2. MSTX 打点清单（昇腾 NPU）

### 2.1 Worker 侧阶段标注（`DistProfiler.annotate` → `NPUProfiler.annotate` → `mark_start_range`）

位于 `verl/workers/engine_workers.py`（另有 Tinker 变体）。打点名 = `role` 参数。

| 打点名称                     | 作用                                                        | 意义 / 归因阶段             | 位置                       |
| ------------------------ | --------------------------------------------------------- | --------------------- | ------------------------ |
| `train_batch`            | 包装 actor 训练的单个 mini-batch（forward + backward + optimizer） | update\_actor 的内层一次迭代 | `engine_workers.py#L341` |
| `ref_compute_log_prob`   | 包装参考策略 log\_prob 前向                                       | ref\_log\_prob        | `engine_workers.py#L693` |
| `actor_compute_log_prob` | 包装 Actor 的 log\_prob 前向                                   | old\_log\_prob        | `engine_workers.py#L700` |
| `actor_update`           | 包装 Actor 的 PPO 更新（内层 mini-batch 循环，`scheduled=True`）      | update\_actor         | `engine_workers.py#L710` |

Tinker 变体（`verl/workers/engine_workers_tinker.py`）：

| 打点名称               | 作用                             | 意义 / 归因阶段                | 位置                              |
| ------------------ | ------------------------------ | ------------------------ | ------------------------------- |
| `forward_backward` | 包装 forward+backward（Tinker 场景） | update（forward+backward） | `engine_workers_tinker.py#L124` |

### 2.2 Trainer/driver 控制流计时（`marked_timer` → `mark_start_range`）

位于 `verl/trainer/ppo/ray_trainer.py`（同步 PPO 主路径；v1 与异步变体命名基本一致但文件不同）。经 `verl/utils/debug/__init__.py` 的 `from ..profiler import *`，在 NPU 上解析为 MSTX 版 `marked_timer`。

| 打点名称                       | 作用                                              | 意义 / 归因阶段        | 位置                     |
| -------------------------- | ----------------------------------------------- | ---------------- | ---------------------- |
| `step`                     | 包住整个 RL 训练 step                                 | 顶层周期             | `ray_trainer.py#L1508` |
| `gen`                      | 包装 rollout 采样/生成                                | rollout / gen    | `ray_trainer.py#L1510` |
| `reward`                   | 包装奖励计算                                          | reward           | `ray_trainer.py#L1561` |
| `old_log_prob`             | 包装 Actor 旧策略 log\_prob                          | old\_log\_prob   | `ray_trainer.py#L1585` |
| `ref`                      | 包装参考策略 log\_prob（`str(Role.RefPolicy)`=`"ref"`） | ref\_log\_prob   | `ray_trainer.py#L1620` |
| `values`                   | 包装 Critic 估值                                    | values           | `ray_trainer.py#L1626` |
| `adv`                      | 包装优势函数计算                                        | adv              | `ray_trainer.py#L1630` |
| `update_critic`            | 包装 Critic 更新                                    | update\_critic   | `ray_trainer.py#L1678` |
| `update_actor`             | 包装 Actor 更新                                     | update\_actor    | `ray_trainer.py#L1689` |
| `update_weights`           | 包装权重同步到 rollout                                 | update\_weights  | `ray_trainer.py#L1715` |
| `save_checkpoint`          | 包装 checkpoint 保存                                | save\_checkpoint | `ray_trainer.py#L1711` |
| `testing`                  | 包装验证/测试                                         | testing          | `ray_trainer.py#L1730` |
| `dump_rollout_generations` | 包装 dump 采样结果                                    | dump（非训练主路径）     | `ray_trainer.py#L524`  |
| `start_profile`            | profiler 开启标记                                   | 工具开销             | `ray_trainer.py#L1472` |
| `stop_profile`             | profiler 关闭标记                                   | 工具开销             | `ray_trainer.py#L1736` |

v1 / 异步变体额外打点（语义同类，文件不同）：

| 打点名称                                                                                                                                            | 作用 / 归因阶段      | 位置                                                              |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | --------------------------------------------------------------- |
| `step` `gen` `reward` `old_log_prob` `ref` `values` `adv` `update_critic` `update_actor` `save_checkpoint` `testing` `dump_rollout_generations` | 同 §2.2 主表      | `trainer/ppo/v1/trainer_base.py`                                |
| `generate_async`                                                                                                                                | 异步生成           | `experimental/one_step_off_policy/ray_trainer.py#L234`          |
| `sync_rollout_weights`                                                                                                                          | 同步 rollout 权重  | `experimental/one_step_off_policy/ray_trainer.py#L398`          |
| `switch_to_trainer`                                                                                                                             | 切换到 trainer    | `trainer/ppo/v1/trainer_separate_async.py#L229`                 |
| `switch_wait`                                                                                                                                   | 切换等待           | `trainer/ppo/v1/trainer_separate_async.py#L254`                 |
| `switch_to_rollout`                                                                                                                             | 切换到 rollout    | `trainer/ppo/v1/trainer_separate_async.py#L342`                 |
| `update_weights`                                                                                                                                | 权重同步           | `trainer/ppo/v1/trainer_sync.py#L36`                            |
| `wait_for_enough_samples`                                                                                                                       | 等待足够样本         | `experimental/fully_async_policy/fully_async_trainer.py#L567`   |
| `rollouter/validate_time`                                                                                                                       | rollouter 验证计时 | `experimental/fully_async_policy/fully_async_rollouter.py#L651` |

***

## 3. PyTorch record\_function 打点清单

### 3.1 Profiler 包装（`Profiler.annotate`）

位于 `verl/utils/profiler/torch_profile.py`，包装同一批 worker 方法，打点名与 §2.1 相同：

| 打点名称                     | 作用                              | 归因阶段                |
| ------------------------ | ------------------------------- | ------------------- |
| `train_batch`            | 连续/离散模式下包装 worker `train_batch` | update\_actor（内层迭代） |
| `ref_compute_log_prob`   | 包装 `compute_ref_log_prob`       | ref\_log\_prob      |
| `actor_compute_log_prob` | 包装 `compute_log_prob`           | old\_log\_prob      |
| `actor_update`           | 包装 `update_actor`               | update\_actor       |

### 3.2 mini-batch / micro-batch 级别

| 打点名称                           | 作用                          | 归因阶段                                           | 位置                                                                    |
| ------------------------------ | --------------------------- | ---------------------------------------------- | --------------------------------------------------------------------- |
| `mini_batch{batch_idx}`        | update 循环中每个 mini-batch 打一个 | update\_actor / update\_critic 的 mini-batch 边界 | `engine_workers.py#L312`                                              |
| `micro_batch{micro_batch_idx}` | 引擎前向/反向的每个微批次               | 前向（含 log\_prob）与反向的 micro-batch 边界             | `fsdp/transformer_impl.py#L736`、`torchtitan/transformer_impl.py#L388` |

***

## 4. 判定优先级（阶段归因）

1. worker 侧 MSTX / record\_function 打点（§2.1 / §3.1）：直接按 `role` 名称切阶段，置信度 high。
2. trainer/driver 侧 `marked_timer` 打点（§2.2）：作为 RL 宏观周期切分依据，置信度 high；与 worker 侧命名有重叠但视角不同，做对齐映射后再归因。
3. `mini_batch{i}` / `micro_batch{i}`（§3.2）：用于 update 阶段内部的子切片，不作为阶段边界，置信度 high（仅限子粒度）。
4. 无打点兜底：按算子序列特征（attention / GEMM / 通信）区分，置信度降级为 medium/low。

## 5. 交叉引用

- `stage_taxonomy` 通用阶段规则：见同目录 `../stage-taxonomy.md`。

- 事件归一化契约：已取消（各 skill 直连 DB，`PYTORCH_API.startNs/endNs` 即 epoch ns），表/字段见 `../db-usage.md`。

- 两层命名对齐映射：`old_log_prob`↔`actor_compute_log_prob`、`ref`↔`ref_compute_log_prob`、`update_actor`↔`actor_update`、`training mini-batch`↔`train_batch`。

