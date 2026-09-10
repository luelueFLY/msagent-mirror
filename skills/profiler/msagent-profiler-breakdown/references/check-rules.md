# 校验与判定规则（守恒 / 阈值 / 置信度）

> 消费脚本：`msagent-profiler-breakdown/scripts/decompose.py`（阶段/step 拆解 + 报告生成）
> 作用：把「结果是否正确、多慢算异常、可不可信」的判据集中为可配置规则。

## 1. 守恒自检阈值

- 缺口定义：`conservation_gap = parent.wall_time − Σ children.self_time`。

- 分类：重叠（overlap）/ 未归因（custom/unknown）/ rounding。

- 告警阈值（默认）：`gap > parent.wall_time × 5%` → 显式告警「归属不完整」。

- 范围：端到端\~层内各做一次，逐级上报，缺口值写入 `confidence`。

## 2. 异常/漂移阈值（可配置）

- 最差 step/层 outlier：`duration > P50 + k·σ`（k 默认 3）或 `> P99`。

- 漂移：`CV = σ/μ > 0.20` 告警（同卡跨 step）。

- 跨 run：均值 ± σ 区间对比。

- 稳态口径：剔除首 step 热身/编译噪声 + ±1 tail。

## 3. 置信度分级

| 级别     | 依据                                   | 呈现        |
| ------ | ------------------------------------ | --------- |
| high   | 框架打点 / record\_function / STEP\_TIME | 正常呈现      |
| medium | 锚点 + 层数校验 / 序列对齐                     | 标注方法      |
| low    | C 策略推测 / custom/unknown / 守恒缺口超阈值    | 逐条 + 提示复核 |

## 4. 配置方式

- 阈值集中于此文件；引擎读取，允许用户按场景覆盖（如放宽/收紧 outlier 的 k 与漂移 CV）。

