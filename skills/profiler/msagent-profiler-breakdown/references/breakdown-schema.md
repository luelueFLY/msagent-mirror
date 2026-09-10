# 拆解树节点契约（原 schemas/breakdown.schema.json）

> 本契约描述 msagent-profiler-breakdown（decompose.py）产出的分级别耗时节点（阶段 / 单次执行），
> 以及后续 layer-decompose 消费时的字段口径。层级用 `level` 字段表达（不靠目录），
> 结论阶梯深度见设计方案 §3.7。

## level 枚举

| level  | 语义                                                                                        | 由谁产出                                                                |
| ------ | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `端到端`  | 会话整体跨度                                                                                    | msagent-profiler-breakdown（breakdown.json 顶层）                       |
| `阶段`   | 推理五 stage（prepare\_input / forward / post\_process / sample\_token / draft\_token）或 RL 阶段 | msagent-profiler-breakdown（breakdown.json children）                 |
| `单次执行` | 一次 forward（decode step）                                                                   | msagent-profiler-breakdown（breakdown.json children 中 level=单次执行 分支） |
| `单层`   | transformer 第 N 层                                                                         | layer-decompose（暂缓，经 --framework 继承场景）                              |
| `层内`   | 层内子模块（attention / MLP(MoE) / 通信 / 归一化 / 量化反量化）                                            | layer-decompose（暂缓）                                                 |

## 节点通用字段

| 字段                 | 类型           | 语义                                                       |
| ------------------ | ------------ | -------------------------------------------------------- |
| `level`            | string（上表枚举） | 拆解层级                                                     |
| `name`             | string       | 节点名：阶段名 / step 序号 / 层名 / 子模块名                            |
| `start` / `end`    | number（ns）   | 起始 / 结束时间                                                |
| `wall_time`        | number（ns）   | 墙钟耗时 = end - start                                       |
| `self_time`        | number（ns）   | 净自耗 = wall\_time - Σ children.wall\_time（主排序用）           |
| `overlap`          | number（ns）   | 并行/重叠收益 = wall\_time - self\_time（单独列示）                  |
| `children`         | array        | 子节点（递归本契约）                                               |
| `confidence`       | object       | `{method(A/B/C), level(high/medium/low), detail}`        |
| `conservation_gap` | number（ns）   | 守恒缺口 = wall\_time - Σ children.self\_time                |
| `stats`            | object       | 同类节点跨 occurrence 聚合时填充：count/p50/p99/min/max/variance/cv |
| `anomaly`          | object       | 异常/漂移标记（is\_outlier / is\_drift / threshold\_ref）        |

> 阶段节点（msagent-profiler-breakdown 的 breakdown.json children 中 level=阶段）额外带 `count`（次数）、`wall_mean` / `wall_max` / `wall_min`（单次均值/最大/最小）、`first`（首个起止/wall），供报告展示阶段统计；`--inspect-index` 时再带 `inspect`。

## confidence

- `method`：A = 框架打点 / B = 注入打点 / C = 数据推测 / `with_modules` / `sequence_align`。

- `level`：`high` / `medium` / `low`（判据见 check-rules.md 与设计方案 §3.7）。

## 约束

- msagent-profiler-breakdown 输出为独立 JSON（breakdown.json 统一拆解树，stage.json 为同内容别名；layers.json 由 layer-decompose 后续产出），**不经过统一事件 JSON 中间层**，
  数据源为昇腾 Profiling DB 直查（见 `references/db-usage.md`）。

- 字段口径以本契约为准；scripts 仅用 Python 标准库，不依赖 JSON Schema 校验库。

