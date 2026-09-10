# 报告与明细模板（stage + step）

> 消费脚本：`msagent-profiler-breakdown/scripts/decompose.py`（第 3 步生成报告）
> 作用：把阶段归因 + 单次执行边界两级产物组织成「结论先行」的人读报告（HTML 自包含），
> 并输出 findings（8 字段）与明细 CSV。报告格式定义在本 skill 的资源/模板中，
> 不再依赖独立 breakdown-report skill。

## 呈现形式

主呈现用 **HTML（单文件自包含，离线可开/可归档/可分享）**；明细与 findings 导出 **CSV / JSON**；多 run 对比用 `scripts/compare_runs.py`（xlsx，openpyxl 缺失时降级 CSV）。

| 呈现物      | 载体                             | 内容                                                                                           |
| -------- | ------------------------------ | -------------------------------------------------------------------------------------------- |
| 结论报告     | HTML（自包含单文件）                   | 结论先行：一句话结论 → 逐级耗时 → 阶段统计表 → TOP-N 下钻链 → per-step 明细 → 稳态统计 → 异常/漂移 → 低置信度 → 建议下一步 → findings |
| 明细数据     | CSV（`<prefix>_detail.csv`）     | per-step 序列（index/start/end/wall\_time/热身/prefill）                                           |
| 结构化结论    | JSON（`<prefix>_findings.json`） | findings 数组（8 字段：问题/证据/影响/根因/优化动作/预期收益/验证路径/置信度）                                             |
| 交接清单     | CSV（`<prefix>_handoff.csv`）    | 层时间边界（layer-decompose 暂缓期间仅表头 + 未启用说明）                                                       |
| 多 run 对比 | xlsx（`compare_runs.py`）        | 多 sheet A/B 对比（端到端/阶段/稳态 step）                                                               |

> 用户已知信息（框架/任务类型等场景信息）不再出现在报告中；未出现的级别（无阶段数据 / 无 step 数据）在「逐级耗时」中不列行；守恒自检不做独立章节（缺口告警保留在 findings 中）。

## 报告结构（结论先行）

1. **一句话结论**：最慢阶段 + 稳态单步 P50/P99。
2. **逐级耗时表**（端到端 \~ 单次执行）：每级标 wall\_time / self\_time / 占比 / 置信度等级；仅列出现过的级别。
3. **阶段统计表**：stage 维度 `次数 / 累计 / 均值 / 最大 / 最小 / 首个`（推理五 stage 或 RL 阶段）。
4. **TOP-N 下钻链**：最慢阶段 → 最慢 step，逐级串成一条主线（表格）。
5. **per-step 明细表**：每 step 的 wall\_time / 是否热身 / 热身原因 / 是否 prefill。
6. **稳态统计表**：count / mean / P50 / P99 / min / max / CV（剔除热身 + prefill）。
7. **异常 / 漂移**：outlier step（>P50+3σ）、CV 漂移告警（>0.20）。
8. **低置信度清单**：C 策略 / 兜底默认 / 规则回退逐条列出，标注「需人工复核」。
9. **建议下一步**（不做根因判定）：确认场景 / 下钻 outlier / 补采打点 / 待 layer-decompose 恢复后下钻层内。
10. **findings（8 字段）**：结构化结论，向工作流层 / 下游交接的最小单元。

## 阶段统计表模板（推理五 stage / RL 阶段）

| stage          | 次数 | 累计   | 均值   | 最大   | 最小   | 首个   |
| -------------- | -- | ---- | ---- | ---- | ---- | ---- |
| prepare\_input | N  | x ms | x ms | x ms | x ms | x ms |
| forward        | N  | x ms | x ms | x ms | x ms | x ms |
| post\_process  | N  | x ms | x ms | x ms | x ms | x ms |
| sample\_token  | N  | x ms | x ms | x ms | x ms | x ms |
| draft\_token   | N  | x ms | x ms | x ms | x ms | x ms |

> 口径：每个 stage 独立统计 `count`（次数）、累计 `wall_time`、单次 `wall_mean / wall_max / wall_min`、`first`（首个起止/wall）；`--inspect-index N` 时另列第 N 次起止。

## per-step 明细表模板

| step   | wall\_time | 热身 | 原因             | prefill |
| ------ | ---------- | -- | -------------- | ------- |
| step.0 | x ms       | 是  | graph\_capture | -       |
| step.1 | x ms       | 是  | compile        | -       |
| step.2 | x ms       | 否  | -              | 否       |

## 稳态统计表模板

| count | mean | P50  | P99  | min  | max  | CV    |
| ----- | ---- | ---- | ---- | ---- | ---- | ----- |
| N     | x ms | x ms | x ms | x ms | x ms | x.xxx |

## 置信度呈现约定

- high：正常呈现；medium：标注方法；low：逐条 + 提示复核，不与 high 混排为确定结论。

## 交接清单字段

| 层/模型     | start | end | device | 置信度  | 备注  |
| -------- | ----- | --- | ------ | ---- | --- |
| layer\_0 | ...   | ... | 0      | high | ... |

> 算子名 / Op ID / 依赖边 / Stream 不在交接清单内——融合 Skill 按时间窗自切 DB 获取（交接契约见设计方案 §1）。layer-decompose 暂缓期间仅输出表头 + 未启用说明。

