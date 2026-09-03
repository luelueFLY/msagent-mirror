# 官方计算图与 logits 门禁

## 前置证据

启动前必须记录以下两种证据之一：

1. 与当前 Adapter entry point、版本、输入覆盖方案和 checkpoint identity 匹配的已有适配验证；
2. 本次定向接口检查，确认 Adapter 已注册且可由 `PluginModelFactory` 创建，
  `handle_dataset`、`init_model` 及所选 Runner/processor 所需接口可用。

缺少某个特定 skill 的报告不是停止理由。只有本次执行需要的接口缺失或定向检查失败时，
才停止流程；前置证据不要求量化保存、任务精度评测或无关回归。

## 结构提取检查

1. 使用已安装 msModelSlim `fast_ops_grapher` 的官方 Extractor，不运行 msAgent 自研扫描脚本。
2. `extract_dag()` 成功返回 `ComputationGraph`，`graph.format("dot")` 为每个选定算法生成非空
  `anti_outlier_graph.<algorithm>.dot`。
3. 节点、边、tensor dtype/shape 和 traceback 覆盖本次输入实际涉及的路径。
4. 动态分支未覆盖时记录 dummy input 和覆盖限制，不用静态猜测补图；拓扑相同的逐算法图可以共享
  内容，但必须记录同一图 hash。

## Final-logits patch 门禁

Agent 必须根据当前模型 `config.json`、实际 `modeling_*.py`、Adapter forward/逐层加载能力和
官方图生成模型专用 patch。patch 文件必须导出 `PATCH_METADATA` 和
`capture_final_logits(self, model, inputs, device)`，并精确匹配 model type、Adapter 完整类名、
checkpoint identity 和 `logits_scope`。

processor 执行前至少检查：

1. Python 语法、导入和固定签名；
2. patch 不能调用 `init_model()`、重新加载 checkpoint 或替换当前模型参数；
3. 使用 `torch.no_grad()` 而不是 `torch.inference_mode()`，避免 lazy forward 创建的持久参数失去
  version counter；固定输入、`eval()` 和相同 seed 下输出有限、shape/dtype 稳定且可重复；
4. 在有可信完整输出、小模型 fixture 或参考 logits 时做模型专用交叉校验。

结果写入 `final_logits_patch_validation.json`，包括 patch 路径、SHA256、metadata、Adapter 类、
checkpoint identity、输入摘要、输出范围、参考路径、误差指标和 PASS/FAIL。失败时标记
`PATCH_UNSUPPORTED` 或 `PATCH_VALIDATION_FAILED`，禁止使用通用 norm/head 回退。

## 各算法独立 logits 门禁

默认验证 `quarot`、`flex_smooth_quant`、`flex_awq_ssz`、`iter_smooth`；用户明确给出子集时只
验证该子集。对每项算法分别执行：

1. 从同一原始浮点 checkpoint 初始化干净模型和 Adapter，使用固定输入、相同 dtype、`eval()` 和 seed。
2. 用同一份已验证 patch 采集并保存 `final_logits.before.<algorithm>.npy`。
3. 只通过官方 `runner.add_processor(...)` 和 `runner.run(...)` 执行当前一个 anti-outlier processor；
  practice 的 `spec.process` 只能有一个 processor，`spec.save` 必须为空，不追加 `linear_quant`。
4. 不更换模型、输入或 patch，再次 reset seed 并保存 `final_logits.after.<algorithm>.npy`。
5. 写出 `anti_outlier_run.<algorithm>.json`，在开始时创建并在任何失败阶段落盘；记录 patch provenance、
  processor 配置来源、runner、输入摘要、接口验证文件及 hash 和 `quantization_run: false`。
  接口验证文档必须包含并精确匹配当前 checkpoint identity；缺失 identity 不得视为有效证据。
6. 执行
  `scripts/compare_final_logits.py --algorithm <algorithm> --run-record <run-record.json>`（运行前必须已提供
  `--interface-validation <interface_validation.<interface-name>.json>`）。
  比较脚本必须核对 algorithm/processor、patch SHA256、checkpoint identity、输入摘要、before/after
  路径、patch validation、接口验证 SHA256 和 `quantization_run`。数值门禁比较 last-token softmax
  分布，要求 Top-1 一致（baseline Top-1/Top-2 margin 足够小时允许 Top-5 内换位）且 Top-5
  overlap 通过。shape 与有限值是硬检查；JS divergence、max/mean absolute error、raw-logits
  cosine、逐元素容差及绝对/相对误差分位数仅作诊断。所有阈值及自定义 `threshold_reason` 均须记录。

`layer_wise` 或 lazy/meta 模型的最终输出路径必须由模型专用 patch 负责，通用脚本不得推断 final
norm/head，也不得把完整大模型搬入 NPU。processor 的校准输出不能充当 before 或 after logits。
`--runner auto` 默认保持 `layer_wise`；只有用户显式选择并确认资源允许时才使用 `model_wise`。
某项失败不得阻止其他选定算法继续，且每项必须保留独立状态与失败原因。

## 人类可读报告门禁

最终必须生成 `anti_outlier_report.md`，至少包含：

- 模型、checkpoint、前置证据来源、实际检查项、算法列表及其来源；
- patch 文件、SHA256、目标 Adapter 类、验证结论和输入覆盖限制；
- 每项算法一行的 processor 执行状态、logits PASS/FAIL、Top-1、Top-5 overlap、JS divergence、
  raw-logits 诊断指标、阈值和失败阶段；
- 每项算法引用的 `interface_validation.<interface-name>.json` 及 hash，并说明共享接口验证；
- `anti_outlier_graph.<algorithm>.dot` 和 `final_logits_comparison.<algorithm>.json` 链接；
- 未执行、失败或 `UNSUPPORTED` 项的具体原因。报告不得只给机器可读 JSON 路径。
