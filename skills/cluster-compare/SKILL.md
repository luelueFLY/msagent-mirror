---
name: cluster-compare
description: 对比两个 Ascend 集群的 cluster_analysis.db，先提取结构化比对数据，再分析性能劣化原因，并仅输出用于渲染报告的 JSON，最后生成可视化 HTML 报告。用于需要比较正常/异常集群性能、定位退化信号、输出图文分析报告的场景。
---

# Cluster Compare

先运行 `scripts/extract_metrics.py` 提取两个集群的对比数据。再基于提取结果分析性能退化原因，并且只输出一个合法 JSON 对象。最后运行 `scripts/render_report.py`，将 JSON 注入 `assets/report_template.html` 生成 HTML。

## 执行步骤

1. 运行 `scripts/extract_metrics.py` 生成对比数据文件。
2. 阅读提取结果；如需确认字段含义，再查看 `references/db_schema.md`。
3. 生成报告 JSON。
4. 运行 `scripts/render_report.py` 生成最终 HTML。

## 提取数据

```bash
python scripts/extract_metrics.py \
  --normal /path/to/normal/cluster_analysis.db \
  --abnormal /path/to/abnormal/cluster_analysis.db \
  --output /path/to/report_data.json
```

可选参数：

- `--step <step-name>`：只分析指定 step。

## 报告 JSON 约束

如果运行环境支持 JSON mode 或 structured output，启用它。无论是否支持，都只能输出一个 JSON 对象，不要输出 Markdown、代码块、解释性前后缀。

输出对象必须包含以下字段：

- `title`
  - 字符串，报告主标题。
- `summary`
  - 字符串，一句话核心结论。
- `meta_info`
  - 数组，元素为 `{ "label": "...", "value": "..." }`。
- `blocks`
  - 数组，按页面顺序组织组件。

`blocks` 只允许以下三种组件：

### `kpi_grid`

```json
{
  "type": "kpi_grid",
  "items": [
    {
      "name": "Stage 总耗时",
      "value": "11318 ms",
      "baseline": "9821 ms",
      "trend": "down",
      "desc": "↑ 增加 +1496.88 ms (15.2%)"
    }
  ]
}
```

字段要求：

- `items` 为数组。
- `trend` 只使用 `down`、`up`、`neutral`。
- `baseline` 和 `desc` 可为空字符串。

### `chart`

```json
{
  "type": "chart",
  "title": "主要通信算子耗时对比 (ms)",
  "chart_type": "bar",
  "orientation": "horizontal",
  "xAxis_data": ["allGather", "broadcast"],
  "series": [
    { "name": "正常", "data": [1.99, 5.19] },
    { "name": "异常", "data": [3.60, 6.92] }
  ]
}
```

字段要求：

- `chart_type` 目前使用 `bar` 或 `line`。
- `orientation` 可使用 `horizontal` 或 `vertical`；未提供时按 `vertical` 处理。
- `xAxis_data` 为类目数组。
- `series` 为数组，元素至少包含 `name` 和 `data`。

### `analysis_text`

```json
{
  "type": "analysis_text",
  "title": "排查重点建议",
  "content": [
    "RDMA 记录缺失，优先排查跨节点通信链路。",
    "HCCS 和 SDMA 带宽降幅过大，检查通信切分策略和小包碎片化。"
  ]
}
```

字段要求：

- `content` 为字符串数组。

## 生成 JSON 时的要求

- 只基于提取结果中的证据写结论，不要编造数值。
- 优先挑选最重要的 3 到 6 个 KPI。
- 图表只保留最能支撑结论的内容。
- `analysis_text` 聚焦根因判断和排查建议。
- 不要输出 HTML。

## 渲染 HTML

```bash
python scripts/render_report.py \
  --input /path/to/llm_output.json \
  --output /path/to/final_report.html
```

可选参数：

- `--template report_template.html`

`scripts/render_report.py` 会从 `assets/` 目录加载 Jinja2 模板，并执行 `template.render(**json_data)`。
