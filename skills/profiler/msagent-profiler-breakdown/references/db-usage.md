# 本 skill 关注的 DB 表/字段速查

> 消费脚本：`scripts/decompose.py`（阶段归因 + step 边界）与 `scripts/db_query.py`（场景确认查询）。
> 只读昇腾 Profiling DB（`ascend_pytorch_profiler_{rank_id}.db`），只用到以下最小子集，不做全量 schema 解析。
> 表/字段变动时先改这里，再同步脚本。

## 用到的最小表子集

| 表                   | 用到的列                               | 用途                                                                                                       |
| ------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `PYTORCH_API`       | `name`, `type`, `startNs`, `endNs` | 推理场景阶段 scope 与 step 锚点事件源（`forward` / `prepare input` / `post process` / `sample_token` / `draft_token`） |
| `MSTX_EVENTS`       | `message`, `startNs`, `endNs`      | verl RL 阶段低开销打点事件源（`actor_update` / `actor_compute_log_prob` / `ref_compute_log_prob` / `train_batch` 等） |
| `STRING_IDS`        | `id`, `value`                      | `PYTORCH_API.name` 与 `MSTX_EVENTS.message`（整数 id）→ 名字符串反查；并用于**框架探测**（见下）                                |
| `SESSION_TIME_INFO` | `startTimeNs`, `endTimeNs`         | 会话整体时间段，用于守恒自检（表缺失时回退到事件跨度）                                                                              |

## 关键字段约定（已核验，schema 1.2.0）

- `PYTORCH_API.name`：**直接**是 `STRING_IDS.id`（稀疏整数，非掩码），`LEFT JOIN STRING_IDS S ON S.id = PY.name` 取 `S.value`。

- `PYTORCH_API.type` 枚举（见 `ENUM_API_TYPE` 表）：`50001` = op（`record_function` scope / 算子）、`50002` = queue（`Enqueue@/Dequeue@` 宿主队列封装，**排除**）、`50004` = mstx（低开销打点，仅 `msprof_tx=True` 时产出）。本 skill 阶段/锚点来源筛 `type IN (50001, 50004)`（op + mstx）。

- `PYTORCH_API.startNs` / `endNs`：**TEXT 数字串，已是 Linux epoch ns**，`CAST(... AS INTEGER)` 后直接当 wall time 用，无需 monotonic→epoch 换算。

- `SESSION_TIME_INFO`：单行，`startTimeNs` / `endTimeNs` 即会话跨度。

- `MSTX_EVENTS`（verl RL 专用）：verl 的低开销打点**不落** **`PYTORCH_API`**，而是独立 `MSTX_EVENTS` 表。其 `message` 列是 `STRING_IDS.id`，`LEFT JOIN STRING_IDS S ON S.id = MX.message` 取 `S.value`。字段：`startNs`/`endNs`（INTEGER，epoch ns，无需 CAST）、`eventType`（见 `ENUM_MSTX_EVENT_TYPE`：`2`=`start/end`）、`message`（打点名 id）、`category`/`rangeId`/`depth`/`connectionId`。每个 Profiling DB 的 message id 是独立 hash，**不可硬编码**，必须运行时 JOIN 反查。

## 框架探测（场景确认，判断一次）

- 规则：`STRING_IDS.value` 列若存在以 `vllm` 开头的字符串（如 `vllm::dsa_forward`），判定数据来自 vLLM；否则若存在 verl worker 侧 MSTX 打点名（`actor_update` / `actor_compute_log_prob` / `ref_compute_log_prob` / `train_batch`），判定来自 verl。

- 落地：`detect_framework()` 先 `SELECT 1 FROM STRING_IDS WHERE value LIKE 'vllm%' LIMIT 1` 命中返回 `vllm`，再 `... WHERE value IN (verl markers) LIMIT 1` 命中返回 `verl`，否则 `None`。

- 优先级：CLI `--framework`（编排层/用户传入）> `STRING_IDS` 探测 > 默认 vllm；结果写入 `stage.json` 的 `framework` + `framework_source`，供下游 layer-decompose 继承（下游不再各自探测）。

## 推理五 stage scope（prepare/forward/post/sample/draft）

| scope 名         | 语义                        | 备注                    |
| --------------- | ------------------------- | --------------------- |
| `prepare input` | 输入准备（token 打包/reshape/拷贝） | 每 step 一轮             |
| `forward`       | 逐 token 自回归前向（模型主体）       | 层内拆解主要依据；step 边界 A 锚点 |
| `post process`  | 前向后处理                     | 每 step 一轮             |
| `sample_token`  | 采样（多为 CPU/轻量 GPU 侧）       | sampling kernel       |
| `draft_token`   | 投机解码草稿 token              | 仅投机解码时出现              |

> 推理场景无法二分 prefill/decode（vLLM-Ascend 无对应打点），按上表五 scope 切分，每个 stage 独立统计 count/累计/均值/最大/最小/首个（见 `resources/scenarios/inference/vllm.json`）。

## 查询模板

```sql
-- 推理：筛某类 scope 事件（op + mstx 两种来源），按 start 升序
SELECT CAST(PY.startNs AS INTEGER), CAST(PY.endNs AS INTEGER)
FROM PYTORCH_API PY
LEFT JOIN STRING_IDS S ON S.id = PY.name
WHERE PY.type IN (50001, 50004) AND S.value IN ('forward', 'prepare input', ...)
  AND PY.startNs IS NOT NULL AND PY.endNs IS NOT NULL
ORDER BY PY.startNs;
```

```sql
-- RL（verl）：筛某阶段低开销打点（MSTX_EVENTS 独立表，JOIN message），按 start 升序
SELECT MX.startNs, MX.endNs
FROM MSTX_EVENTS MX
LEFT JOIN STRING_IDS S ON S.id = MX.message
WHERE S.value IN ('actor_update', 'actor_compute_log_prob', 'ref_compute_log_prob', ...)
  AND MX.startNs IS NOT NULL AND MX.endNs IS NOT NULL
ORDER BY MX.startNs;
```

## 只读打开约定

- profiling DB 常带未 checkpoint 的 `-wal`，**不可用** **`immutable=1`**（会跳过 WAL 恢复导致表缺失）；
  用 `mode=ro`（`file:<path>?mode=ro`），依赖已落盘的 `-shm/-wal` 正常读取。

## 变动点提示

- 若 CANN 版本把 `name` 改为掩码编码或 `startNs` 改为相对时间，需在此处改「字段约定」，脚本的查询函数同步调整。

- 若 verl 打点改回 `PYTORCH_API.type=50004`（而非独立 `MSTX_EVENTS`），需修正 `resources/scenarios/rl/verl.json` 的 `backing` 与 `db_query.query_mstx`。

