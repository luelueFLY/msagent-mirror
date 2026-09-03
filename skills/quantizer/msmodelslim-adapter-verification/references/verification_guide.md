# 适配器验证指南

## 设备与卡号选择（NPU 必读）

> **DiT 验证必须读本节。** CPU 路径仅适用于 LLM/VLM 的小模型 smoke 测试。

| 项 | 约定 |
|---|---|
| `--device` | **仅接受字面量 `npu` 或 `cpu`**；不要传 `npu:0` / `npu:x` / `cuda:0` 等带卡号/非 NPU 形态 |
| 卡号选择 | 通过环境变量 `ASCEND_RT_VISIBLE_DEVICES=<idx[,idx,...]>`，**0-indexed 物理卡号** |
| 多卡 | 逗号分隔，如 `ASCEND_RT_VISIBLE_DEVICES=0,1` |
| 单卡优先 | 多卡会引入通信开销，验证阶段优先用单卡（如 `export ASCEND_RT_VISIBLE_DEVICES=0`） |
| 物理 vs 逻辑 | 设置 env var 后，进程内看到的 `npu:0` 是**逻辑卡号**，`ASCEND_RT_VISIBLE_DEVICES` 决定其映射到哪块物理卡 |

### 调用样板（DiT）

```bash
export ASCEND_RT_VISIBLE_DEVICES=0   # 用物理 0 号卡
python scripts/step2_run_quantization_dit.py \
  --model-path /path/to/model \
  --output-path /tmp/quantized_model \
  --model-type Wan2.2-T2V-A14B \
  --device npu \
  --inference-repo /path/to/Wan2.2
```

`--inference-repo` 对 Wan 系**必传**：适配器靠 `WAN_INFERENCE_REPO` 把推理仓插进 `sys.path`，
不传会报 `ImportError: Failed to import WanModel from Wan2.2/wan/modules/model.py`。

不传 `--calib-dataset` 时，脚本会用 `references/dit/index.example.jsonl` 在
`<output-path>/calib_data/` 生成一份自建校准集并写进 `spec.dataset`。
要用 `lab_calib` 现成集就传 `--calib-dataset wan2_2_t2v`。

### 调用样板（LLM/VLM NPU 路径）

```bash
export ASCEND_RT_VISIBLE_DEVICES=2   # 用物理 2 号卡
python scripts/step1_generate_test_model.py \
  --model-path /path/to/model \
  --output-path /tmp/test_model \
  --model-family llm \
  --device npu
```

> 默认 `--device cpu` 仅用于 LLM/VLM 的快速 smoke 验证。DiT 模型本身就需要 NPU 加载，CANN 不支持在 CPU 上做多模态量化推理。

### 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| 跑了 0 号卡（不期望） | 未设置 `ASCEND_RT_VISIBLE_DEVICES`，用了 CANN 默认首张卡 | `export ASCEND_RT_VISIBLE_DEVICES=<目标物理 idx>` 后重跑 |
| "No NPU device available" | env var 指向了不存在的物理卡，或被 `CUDA_VISIBLE_DEVICES` 等其他框架占用 | `npu-smi info` 查可用卡后重设 |
| step1 skip + `--device npu` 误以为必要 | skip 模式只校验 JSON，不接触硬件 | skip 模式下 `--device` 值无作用，可不传 |
| step3 / step4 看似也要 NPU | 这两步只读 .safetensors 不做前向 | 无需 `--device npu`，按字面调用即可 |

> 本约定与 `quant-tuning-quantize-dit` 保持一致（参见该 skill 的 `SKILL.md` "调用差异" / "device" 字段描述）。

## DiT 配置

模板在 `references/dit/`，三条硬约束与 `inference_config` 字段速查见该目录 [`README.md`](dit/README.md)，
非 DiT 任务无需展开。

## 核心验证流程 (必须)

必须按顺序执行以下四步验证：

1. **生成测试模型** (Step 1)
   - 验证模型加载与基本配置
   - 生成随机权重的小型模型用于快速测试（仅 LLM/VLM 可走随机权重；DiT 必须 `--skip-random-model`，详见上文"设备与卡号选择"前的 `SKILL.md` 说明）
2. **全回退量化** (Step 2)
   - 验证量化流程是否能跑通（不涉及具体精度，仅跑通流程）
   - 检查 `model_adapter` 注册是否生效
   - DiT 必须 `--device npu` + `ASCEND_RT_VISIBLE_DEVICES`
3. **全回退模型一致性与可加载/保存验证** (Step 3)
   - 基于 Step2 生成的全回退模型，验证其与 Step1 浮点模型权重严格一致（键、形状、数值）
   - 验证该模型产物具备完整加载/保存能力（可被后续流程读取并继续处理）
   - 若发现全回退权重缺失，优先检查缺失项是否为模型 `buffer`（`msmodelslim` 默认不会保存 buffer 权重）
   - 对必须保留的 buffer 权重，需在适配器中主动转换为 `nn.Parameter` 后再参与验证
   - DiT skip 模式下必须传 `--reference-weights <model_path>` 指回原始模型做基线
4. **实际量化流程验证** (Step 4)
   - 运行实际 W8A8 静态/动态量化流程（非回退流程）并产出量化结果
   - 验证量化描述文件是否符合预期规则，检查线性层量化标签是否正确

## 验证命令

```bash
# 1) 生成测试模型
python scripts/step1_generate_test_model.py \
  --model-path /path/to/your/model \
  --output-path /tmp/test_model

# 2) 全回退量化
python scripts/step2_run_quantization.py \
  --model-path /tmp/test_model \
  --output-path /tmp/quantized_model \
  --model-type YourModelType \
  --model-family llm

# 多模态模型请使用:
#   --model-family vlm
# DiT 模型请加 --skip-random-model + --device npu，详见上文 NPU 节

# 3) 全回退模型一致性验证（与浮点权重严格对齐）
python scripts/step3_verify_weights.py \
  --original-path /tmp/test_model \
  --quantized-path /tmp/quantized_model \
  --tolerance 1e-5
```

### Step 4：全模型量化检查

执行全模型 W8A8 静态量化并检查描述文件：

```bash
# 执行量化
msmodelslim quant \
  --model_type <your_model_type> \
  --model_path /tmp/test_model \
  --save_path /tmp/quantized_w8a8_static \
  --device cpu \
  --config_path references/llm/w8a8_static_full_model.yaml \
  --trust_remote_code True

# 验证描述文件
python scripts/step4_verify_quant_description.py \
  --desc-path /tmp/quantized_w8a8_static \
  --rules-path /path/to/your_verify_rules_static.json
```

执行全模型 W8A8 动态量化并检查描述文件：

```bash
# 执行量化
msmodelslim quant \
  --model_type <your_model_type> \
  --model_path /tmp/test_model \
  --save_path /tmp/quantized_w8a8_dynamic \
  --device cpu \
  --config_path references/llm/w8a8_dynamic_full_model.yaml \
  --trust_remote_code True

# 验证描述文件
python scripts/step4_verify_quant_description.py \
  --desc-path /tmp/quantized_w8a8_dynamic \
  --rules-path /path/to/your_verify_rules_dynamic.json
```

多模态模型（VLM）建议使用以下配置模板（含校准数据字段）：

```bash
references/vlm/w8a8_static_full_model.yaml
references/vlm/w8a8_dynamic_full_model.yaml
```

DiT 使用（INT8 动态 / MXFP8）：

```bash
references/dit/w8a8_dynamic_full_model.yaml
references/dit/w8a8_mxfp8_full_model.yaml
```

DiT 不提供 static 模板 —— 该阶段默认 W8A8 动态量化，量化方案由 YAML（`--config_path`）给定，无需传 `--quant_type`（见 `quant-tuning-quantize-dit/SKILL.md`）。
用这个模板前必须替换 `_CALIB_DATASET_` 占位符、并按目标推理仓补齐 `inference_config`
（step4 要真跑浮点推理 dump，不能留 `{}`）。

说明：不再内置 `verify_rules_w8a8_static.json` / `verify_rules_w8a8_dynamic.json`，请 agent 按目标模型层名自行生成规则文件并传入 `--rules-path`。

## 通过标准

- **核心验证**：Step 1/2/3/4 均成功执行无报错。
- **Step 3 通过条件**：全回退模型与浮点模型权重检查 PASS，且量化产物可被后续流程正常加载/使用。
- **Step 4 通过条件**：实际量化流程执行成功，描述文件规则校验通过。

## 快速排错 / 失败分流

- **Step 1 失败**：
  - 模型加载失败：检查 `transformers` 版本或 `trust_remote_code` 设置
  - 类型不支持：检查 `model_type` 是否在支持列表中
- **Step 2 失败**：
  - 找不到适配器：检查 `config.ini` 注册是否正确，是否执行了 `install.sh`
  - 量化入口报错：检查 `handle_dataset` 数据处理是否正确
  - `requires non-empty text` / `Input should be a valid string`：`spec.dataset` 漏写或写成字典，见 `dit/README.md` 硬约束 #1
  - `ImportError: Failed to import WanModel`：漏传 `--inference-repo`，见 `dit/README.md` 「推理仓注入」
- **Step 3 失败 (全回退模型与浮点不一致/不可完整加载)**：
  - 检查量化前后权重键名、形状与映射关系（应一一对应）
  - 检查数值差异是否超出阈值（默认 `tolerance=1e-5`）
  - 检查量化目录内权重与必要配置文件是否完整，确保可被后续流程读取
  - 若报“缺少权重键”，检查该键在原模型中是否是 `buffer`；若是，需在适配器中将其转成 `nn.Parameter`
  - **MoE 模型**：若使用 packed 权重，检查 `packed -> unpacked` 拆分逻辑是否正确（维度、转置）
- **Step 4 失败 (实际量化流程或描述文件异常)**：
  - 检查实际量化配置是否正确（W8A8 静态/动态、校准参数等）
  - 检查是否误用了回退配置
  - 检查验证规则 JSON 中的关键字是否覆盖了模型实际层名
