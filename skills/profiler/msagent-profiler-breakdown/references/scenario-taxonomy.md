# 场景分类规则（推理 / 训练 / RL）+ 单次执行边界

> 消费脚本：`msagent-profiler-breakdown/scripts/decompose.py`（第 2 步执行拆解）
> 作用：先判任务类型（场景确认），再按场景资源文件 `resources/scenarios/<scenario>/<framework>.json`
> 的声明式规则执行阶段归因与 step 边界检测。本文件承载通用规则；框架差异（scope 名 / 锚点）
> 下沉到场景资源文件，详见 `frameworks/README.md`。

## 1. 任务类型三分支

| 任务类型         | 典型框架                        | 阶段划分策略                                                                                                                                           | 本轮状态                             |
| ------------ | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------- |
| 推理 inference | vllm / sglang               | 无法二分 prefill/decode，按顶层 repetitive scope 切 `prepare_input`/`forward`/`post_process`/`sample_token`/`draft_token` 五 stage，统计 count/累计/均值/最大/最小/首个 | 已落地（vllm），sglang 待核验             |
| 训练 train     | megatron / mindspeed / fsdp | LLM 训练**不区分 stage**（逐 step 均质前向+反向），直接下钻 step/layer                                                                                              | 预留（占位）                           |
| RL rl        | verl / slime                | RL **区分不同 stage**（rollout 采样 / actor 训练 / critic 训练 / reward 等），按阶段名切                                                                            | 已落地（verl MSTX\_EVENTS），slime 待核验 |

## 2. 场景确认（任务类型 / 框架判定优先级）

1. CLI / 编排层 `--framework` / `--task-type` 显式指定 → 直接采用，high。
2. 框架映射探测：`FRAMEWORK_SCENARIO` 表（vllm→inference、sglang→inference、megatron→train、
   verl→rl...）→ detected，high。
3. 无法判定 → 默认推理 + 显式告警，提示编排层询问用户，low。

框架自动探测（仅在本 skill 判断一次，结果写 `stage.json` 的 `framework` + `framework_source`，
供下游 layer-decompose 经 `--framework` 继承，不再各自探测）：

- `STRING_IDS.value` 含 `vllm%` 前缀 → vllm（如 `vllm::dsa_forward`）。

- 否则存在 verl worker 侧 MSTX 打点名（`actor_update` / `actor_compute_log_prob` /
  `ref_compute_log_prob` / `train_batch`）→ verl。

- 否则 None → 默认 vllm + 告警。

## 3. 推理阶段清单（vLLM 五 stage）

| stage          | 语义                        | 判定信号（真实 vLLM-Ascend）  |
| -------------- | ------------------------- | --------------------- |
| prepare\_input | 输入准备（token 打包/reshape/拷贝） | `prepare input` scope |
| forward        | 逐 token 自回归前向（模型主体）       | `forward` scope       |
| post\_process  | 前向后处理                     | `post process` scope  |
| sample\_token  | 采样（多为 CPU/轻量 GPU 侧）       | `sample_token` scope  |
| draft\_token   | 投机解码草稿 token              | `draft_token` scope   |

## 4. 单次执行边界（三策略 + 锚点）

| 策略       | 手段                                                       | 置信度    | 代价      |
| -------- | -------------------------------------------------------- | ------ | ------- |
| A 框架已有打点 | `forward` scope（record\_function），每次 decode forward 出现一次 | high   | 零（纯后处理） |
| B 上层注入打点 | execute\_model 前后注入 `record_function("step_N")` / MSTX   | high   | 改采集侧    |
| C 数据推测   | lm\_head/首层锚点 + 层数校验                                     | medium | 零，需交叉验证 |

- 锚点优先级：CLI `--anchor` 显式覆盖 > 场景资源 `step_decompose.anchor`。

- 热身剔除：位置优先——前 2 步（首步图捕获、次步编译）判为热身，写 `warmup_reason`；
  其余步再以 `wall_time > factor×median`（factor 默认 3.0）阈值兜底；`--skip-first-step`
  另将首个 step 标为疑似 prefill 一并剔除稳态统计。

- 图捕获影响：层内 scope 只在捕获步可见，本 skill 只产出 step 边界；层内归因的可行性判断
  交 layer-decompose（见 `frameworks/vllm-instrumentation.md` 图捕获结论）。

## 5. 训练 / RL 分支状态

- 训练（train）：LLM 训练 step 均质，阶段不区分，输出空 children 占位并提示直接下钻 step/layer。

- RL（rl，verl）：阶段名由框架打点提供。verl 低开销打点落在独立 `MSTX_EVENTS` 表
  （JOIN `STRING_IDS` ON `message`），按阶段语义名切分：`rollout`/`reward`/`old_log_prob`/
  `ref_log_prob`/`values`/`adv`/`update_critic`/`update_actor`/`update_weights`/
  `save_checkpoint`/`testing`，复用五 stage 统计口径。两侧命名对齐与信号清单见
  `frameworks/verl.md`。slime 待核验。

## 6. P-D 部署形态对阶段判定的影响

- **P-D 分离（disaggregated）**：prefill 与 decode 跑在不同实例/rank，进程级天然可切，阶段按实例归属，置信度 high。

- **P-D 共部署（colocated / mixed）**：同一 batch 可能同时含 prefill（chunked）与 decode，单次 forward 无法二分 → 退化为按 repetitive scope 五 stage 划分，不做 prefill/decode 二分，置信度 medium。

## 7. 载荷

- 引擎读取 `resources/scenarios/<scenario>/<framework>.json`（声明式规则），不感知框架名。

- 新增框架 / 扩充打点 = 新增或回填场景资源文件，引擎不改（见 `frameworks/README.md`）。

