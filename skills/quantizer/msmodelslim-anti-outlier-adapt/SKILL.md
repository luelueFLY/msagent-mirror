---
name: msmodelslim-anti-outlier-adapt
description: 在适配器接口门禁通过后，依据目标模型真实 forward 生成并验证 final-logits patch，执行单算法 msModelSlim 离群值抑制变换、官方计算图提取和浮点 logits 门禁。
---

# msModelSlim 离群值抑制适配

本 skill 是模型适配之后的独立流程。它使用当前环境已安装的 msModelSlim
`fast_ops_grapher` 提取模型执行图，并让 Agent 根据目标模型源码和已注册 Adapter
生成模型专用的 final-logits capture patch。选定算法分别从干净浮点 checkpoint
开始，只执行一个 anti-outlier processor，再比较同一 patch 采集的变换前后最终 logits。

## 定位与边界

- 不生成 capability matrix、JSON handoff、processor chain、候选阶梯或调优策略。
- 用户未指定算法时处理默认 4 项；用户明确给出算法列表时以该列表为准，不自行增加、组合或替换。
- 允许 anti-outlier processor 执行算法自身必需的校准 forward，但不执行独立量化、任务精度评测或保存量化权重。
- 不修改 `PipelineInterface`、ModelAdapter 基类或 msModelSlim 公共接口。
- 不在 skill 的 `scripts/` 中维护模型 patch、模型注册表或按模型名分支的 finalizer。
- 不根据 `model_type` 名称猜测 final norm、head、residual、MTP、视觉融合或 TP gather。
- Agent 无法可靠生成或验证 patch 时，logits 门禁为 `UNSUPPORTED`，不得使用通用 norm/head 回退。

## 前置证据门禁

启动前必须满足以下条件之一：

- 复用与当前 checkpoint identity、Adapter entry point 和版本匹配的已有适配验证产物；
- 没有可复用产物时，执行本流程需要的定向接口检查，确认 Adapter 已注册且可由
  `PluginModelFactory` 创建，`handle_dataset`、`init_model` 以及所选 Runner/processor
  实际需要的接口可用。

不得因为缺少某个特定 skill 的验证报告而停止，也不要求重跑与本流程无关的完整回归。
前置记录必须说明证据来源、实际检查项和 checkpoint identity。只有缺少本次执行所需接口，
或定向检查实际失败时，才停止 anti-outlier 流程。

## 默认算法

默认实现并验证以下 4 项；用户明确给出算法列表时只验证该子集：

1. `quarot`
2. `flex_smooth_quant`
3. `flex_awq_ssz`
4. `iter_smooth`

参数只读取当前已安装 msModelSlim 自带的
`expert_experience.yaml` 中对应的 `*_default` 项，不在 msAgent 复制默认配置。
必须保留 `flex_awq_ssz_default` 的 `qconfig`；它只用于算法内部误差评估，不表示执行量化。

接口映射验证按 Adapter 接口去重：`quarot` 使用 `QuaRotInterface`，
`flex_smooth_quant` 与 `flex_awq_ssz` 共享一次 `FlexSmoothQuantInterface` 验证，
`iter_smooth` 使用 `IterSmoothInterface`。共享结果写入
`interface_validation.<interface-name>.json`，算法运行记录引用文件及 hash。
接口验证通过不代表对应 processor 的 logits 门禁通过；每个算法仍须独立解析配置并执行。

## Agent 生成的 patch

Agent 必须交叉核对模型 `config.json`、实际 `modeling_*.py`、Adapter 的
`handle_dataset`/`init_model`/`generate_model_forward`、逐层加载与设备迁移能力，以及本次
输入实际覆盖的分支。patch 默认写入输出目录：

```text
<output_dir>/patches/final_logits_capture.<model_type>.py
```

文件必须导出以下元数据和固定签名：

```python
PATCH_METADATA = {
    "schema": "msagent.anti_outlier_logits_capture_patch/v1",
    "model_type": "<model_type>",
    "adapter_class": "<module>:<qualified-class-name>",
    "checkpoint_identity": "<stable identity>",
    "logits_scope": "full_sequence",  # 或 last_token
}


def capture_final_logits(self, model, inputs, device):
    ...
```

`self` 必须是当前 Adapter 实例。patch 不得创建 Adapter、调用 `init_model()`、重新加载
checkpoint 或替换当前模型参数；输入必须来自当前 Adapter 的 `handle_dataset`。它必须使用
`torch.no_grad()` 无梯度推理、正确处理模型特有的最终输出语义，并在 lazy/meta 模型上复用
Adapter 的逐层加载能力。捕获过程可能懒加载或替换持久模型参数，因此不得用
`torch.inference_mode()` 包裹该过程，以免后续 processor/after forward 遇到无版本计数的
inference tensor。

## 工作流

1. 记录前置证据并确认 Adapter、版本、checkpoint identity 与本次任务一致。
2. 使用已安装 msModelSlim 的官方 `fast_ops_grapher` Extractor 调用 `extract_dag()` 和
   `graph.format("dot")`。每个选定算法保留 `anti_outlier_graph.<algorithm>.dot`；拓扑相同时
   记录共享 hash，动态分支记录 dummy input 和覆盖限制。
3. 阅读模型源码、配置、Adapter 和官方图，核对 anti-outlier 映射、source/target、subgraph、
   channel dimension、路径、重复/冲突条目及输入覆盖限制。
4. 生成并保存模型专用 `final_logits_capture.<model_type>.py`，所有选定算法复用同一份已验证 patch。
5. 在 processor 执行前验证 patch：语法、导入、固定签名、目标 model/Adapter/checkpoint identity，
   以及固定输入下的有限值、shape/dtype 稳定性和相同 seed 可重复性。在有可信正式输出或小模型 fixture
   时做交叉校验；结果写入 `final_logits_patch_validation.json`。
6. 按 Adapter 接口去重执行映射验证，共享 Flex 接口只验证一次，并为每个算法记录引用关系。
   接口验证文件必须包含与本次运行完全一致的 checkpoint identity；缺失 identity 或来自其他
   checkpoint 的证据均无效。
7. 对每项选定算法从同一原始浮点 checkpoint 初始化干净模型，使用固定输入采集变换前最终 logits，
   只添加当前一个 processor，再用同一模型、输入、seed 和 patch 采集变换后最终 logits。不得复用上一算法修改过的模型。
8. 调用 `scripts/apply_one_anti_outlier.py` 时必须提供
   `--logits-capture-patch <generated_patch.py>`。公开方法
   `apply_one_anti_outlier_and_record_logits(algorithm, model_path, fixed_input, output_dir)`
   也必须通过可选参数接收同一 patch，以及匹配的
   `--interface-validation <interface_validation.json>` 证据。脚本动态加载并校验 patch，只对当前 Adapter
   实例临时绑定 `capture_final_logits`，通过官方 `runner.add_processor(...)` 与 `runner.run(...)`
   执行 processor；`--runner auto` 保持 msModelSlim 单设备的 `layer_wise` 语义，只有显式选择
   `model_wise` 时才完整加载模型。不推断或回退到通用 final norm/head。运行记录必须在开始时创建，
   且在失败时仍落盘。
9. 对每项调用 `scripts/compare_final_logits.py --algorithm <algorithm> --run-record <run.json>`。
   比较脚本只消费 logits 和 provenance，核对 processor、patch SHA256、checkpoint identity、
   输入摘要、before/after 路径及 `quantization_run: false`。PASS/FAIL 只使用最后位置的 Top-1
   一致性与 Top-5 overlap；JS divergence、raw-logits cosine、逐元素容差及误差分位数只作为
   诊断信息，不单独阻断结果。
10. 汇总 `anti_outlier_report.md`，逐项说明 patch 来源与 hash、接口验证引用、干净模型/单 processor
    事实、before/after provenance、DOT 链接和失败阶段。

## 独立运行状态

每个算法必须独立留痕。失败不得阻止其他已选算法继续执行。运行记录至少区分：

- `PATCH_UNSUPPORTED`
- `PATCH_VALIDATION_FAILED`
- `BEFORE_CAPTURE_FAILED`
- `PROCESSOR_FAILED`
- `AFTER_CAPTURE_FAILED`
- `COMPARISON_FAILED`
- `PASS`

只有 patch 验证通过、processor 实际执行、比较脚本 provenance 校验通过且数值结果通过时，
该算法的 logits 门禁才算 `PASS`。

## 输出

- `patches/final_logits_capture.<model_type>.py`
- `final_logits_patch_validation.json`
- `interface_validation.<interface-name>.json`
- `anti_outlier_graph.<algorithm>.dot`
- `final_logits.before.<algorithm>.npy`
- `final_logits.after.<algorithm>.npy`
- `anti_outlier_run.<algorithm>.json`
- `final_logits_comparison.<algorithm>.json`
- `anti_outlier_report.md`

DOT 只表示本次输入覆盖的模型执行路径，不代表 processor 执行轨迹。未执行、失败或
`UNSUPPORTED` 的算法必须在运行记录和人类可读报告中说明具体阶段与原因。
