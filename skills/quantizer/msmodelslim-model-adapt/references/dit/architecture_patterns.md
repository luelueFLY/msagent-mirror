# 多模态生成模型（DiT/扩散）通用适配架构模式

> 适用：`MultimodalSDModelslimV1QuantService` + `MultimodalPipelineInterface` 重构路径。
> 目标：让 Agent 在面对**任意**多模态生成模型（HunyuanVideo / Wan2.2 T2V·I2V·TI2V / FLUX / SD3 / Sana / HunyuanDiT / CogViewX / 后续新模型）时，按统一的"决策树 + 代码分区 + 通用陷阱"模板落地适配器，**不**为每个模型硬编码一份样板。

---

## 1. 决策树（先判断，再写代码）

> Agent 接到的请求千变万化，但底层结构只有三种。**先判断再动手**。

### 1.1 第一步：识别 DiT 主干架构

读 inference_repo 的 `modeling_*.py` / `pipeline/*.py`，按下列信号判断：

| 信号 | 单网络 DiT | 双专家 DiT | 单流多模块 DiT |
|------|-----------|-----------|----------------|
| DiT block 类数量 | 1 种 | 1 种或 2 种（如 `MMDoubleStreamBlock` + `MMSingleStreamBlock`） | 多种（如 `double_blocks` + `single_blocks`） |
| `init_model` 暴露的 DiT 数量 | 1（`self.transformer`） | 2（`low_noise_model` + `high_noise_model`） | ≥2（通常拼成 list） |
| 推理入口脚本 | `sample_video.py` / `inference_flux.py` 等单 inference | `generate.py` + `--task` 切换 t2v/i2v/ti2v | 多 inference 入口或单 pipeline 内多 stage |
| 典型模型 | HunyuanVideo、FLUX.1-dev、SD3、Sana | Wan2.2 (A14B 系列) | FLUX.1-dev（双流/单流 block） |

> **关键问题**：模型的 `forward` 是否需要多个 **独立的 DiT Module 实例**（双/多专家），还是只是同一 Module 内多个 block（双/单流）？前者需要 `ExpertSubAdapter` 模式，后者不需要。

### 1.2 第二步：识别原仓 CLI / parse_args 入口

多模态生成模型的推理参数散落在不同入口脚本里。**必查**：

1. inference_repo 的 `README.md` —— 找一条最小推理命令；
2. 推理命令里的入口脚本名（`generate.py` / `sample_video.py` / `inference_flux.py` / ...）；
3. 入口脚本顶部 `import argparse; from xxxx import parse_args` 之类的声明；
4. `parse_args()` 的全部 `--key`，这就是 `InferenceConfig` Pydantic 字段白名单。

> 任何 `inference_config` 字段都必须命中该白名单，否则 `configure_runtime` 校验会 fail-fast。

### 1.3 第三步：识别 DiT block 类名关键字

`generate_model_visit` / `generate_model_forward` 必须按**同一关键字**过滤 `named_modules()`：

| 模型 | block 类名关键字（子串匹配） |
|------|-------------------------------|
| HunyuanVideo | `streamblock` |
| Wan2.2 (A14B) | `attentionblock` |
| FLUX.1-dev | `doubleblock` / `singleblock`（按流分） |
| SD3 | `block`（结合子类名判断） |

> Agent 落盘前必须从已加载模型的 `module.__class__.__name__` 自动探测；探测失败才回退为硬编码。

### 1.4 决策树伪代码

```python
def adapt_multimodal_generation_model(model_family, inference_repo, model_path):
    """返回适配器实现路线（不写死模型名）。"""
    pipeline = load_pipeline_with(inference_repo, model_path)
    dit_modules = enumerate_dit_modules(pipeline)
    block_keyword = auto_detect_block_keyword(dit_modules)

    if len(dit_modules) == 1:
        # 单网络：HunyuanVideo / FLUX.1-dev / SD3 / Sana 路线
        return SingleDiTAdapterPlan(pipeline, dit_modules[0], block_keyword)

    elif len(dit_modules) >= 2 and any_two_have_distinct_weights(pipeline):
        # 双/多专家：Wan2.2 路线
        return DualExpertAdapterPlan(pipeline, dit_modules, block_keyword)

    else:
        raise UnsupportedError("Unknown DiT topology")
```

---

## 2. 代码分区模式（统一骨架）

> 任何多模态生成模型适配器都按下面这套"分区"组织代码。新模型只换分区内的具体实现，不动分区边界。

### 2.1 单网络 DiT（如 HunyuanVideo、FLUX、SD3）

```text
msmodelslim/model/<model_id>/
├── __init__.py
├── model_adapter.py    # 全部 6+5=11 个方法，单类实现
├── constants.py        # DEFAULT_SIZE / EXAMPLE_PROMPT（可选）
└── loader.py           # <Model>AdapterLoader
```

| 分区 | 方法（按顺序） |
|------|----------------|
| 1 | `validate_calib_samples` / `handle_dataset` / `init_model` / `generate_model_visit` / `generate_model_forward` / `enable_kv_cache` |
| 2 | `InferenceConfig` (Pydantic) / `get_inference_config_class` / `configure_runtime` |
| 3 | `prepare_calib_data` / `inference_dump_calib_data` / `quantization_context` |
| 4 | 运行时通用辅助（`_runtime_value`） |
| 5 | 私有参数桥接（`_parse_args_from_*` / `_build_default_*_cli` / `_namespace_to_argv`） |
| 6 | 私有运行时与缓存装配（`_load_pipeline` / `_setup_cache`） |

### 2.2 双/多专家 DiT（如 Wan2.2 A14B 系列）

```text
msmodelslim/model/<model_id>/
├── __init__.py                  # 导出全部类
├── model_adapter.py             # legacy 单体（如有），保留不动
├── loader.py                    # legacy 入口（保留不动）
├── constants.py                 # EXAMPLE_PROMPT / TASK_TYPES / DUAL_EXPERT_SCENE_TASKS / DEFAULT_SIZE
├── base_model_adapter.py        # 基类：分区 1~8（不直接实例化）
├── expert_sub_adapter.py        # 子适配器（不注册 model_type）
├── <scene_a>/                   # 场景子类（T2V / I2V / TI2V / ...）
│   ├── __init__.py
│   ├── model_adapter.py         # Wan2_2T2VModelAdapter(基类)
│   └── loader.py                # Wan2_2T2VAdapterLoader
├── <scene_b>/
│   ├── __init__.py
│   ├── model_adapter.py
│   └── loader.py
└── <scene_c>/
    └── ...（同上）
```

**新增场景的最小成本**：复制一份 `<scene_*/>` 子目录 → 改 `scene_task` + `InferenceConfig` + `_build_<id>_pipeline` → 在 `config.ini` 加注册项。

| 分区 | 方法 | 在基类/子类? |
|------|------|-------------|
| 1 | `validate_calib_samples` / `handle_dataset` / `init_model` / `generate_model_visit` / `generate_model_forward` / `enable_kv_cache` / `get_expert_adapter` | 基类 + 子类覆写 |
| 2 | `InferenceConfig` / `get_inference_config_class` / `configure_runtime` | 子类声明 config / 基类实现 configure_runtime |
| 3 | `prepare_calib_data` / `inference_dump_calib_data` / `quantization_context` | 基类 dump / 子类 context |
| 4 | `_runtime_value` / `_quantization_context_with_no_sync` | 基类 |
| 5 | `_bind_expert_sub_adapters` / `_create_expert_sub_adapter` | 基类 |
| 6 | `_allowed_*_config_keys` / `_build_default_*_cli` / `_namespace_to_argv` / `_parse_args_from_*` | 基类 |
| 7 | `_check_import_dependency` / `_load_pipeline` / `_setup_*_dit_runtime` / `_build_<id>_pipeline` | 基类私有方法 + 子类覆写 |
| 8 | `get_online_rotation_configs` / `inject_fa3_placeholders` / `_attach_attention_cache_to_blocks` | 基类 |

---

## 3. 通用陷阱清单

12 类陷阱（meta tensor / 显存碎片 / enable_dump 短路 / parse_args 单次 / quant_overrides /
双 expert key / 子适配器接口继承 / ExitStack / task 串扰 / 样本校验 / KV cache / block_keyword）
详见 [`pitfalls.md`](pitfalls.md)，落盘前必查。

---

## 4. 通用执行约束（端到端 SOP）

### 4.1 CLI / 环境变量（与模型无关）

| 项 | 通用约束 |
|----|---------|
| `--device` | **仅** 字面量 `npu`；不要带卡号 |
| 物理卡号 | 通过 `ASCEND_RT_VISIBLE_DEVICES=<idx>` 指定；**优先单卡**（避免多卡切分 HBM） |
| `--trust_remote_code` | DiT 默认 `True`；模型来源必须可信 |
| `inference_repo` | **必须**用户单独提供（与权重目录互不包含）；适配器在 `init_model` 注入 `sys.path` |
| Python 环境 | `PYTHONPATH` / `sys.path` 必须含 `inference_repo` 根目录 |

### 4.2 四步验证（DiT 专属约束）

| Step | 必选 flag | 备注 |
|------|-----------|------|
| step1 | `--skip-random-model --model-family dit` | DiT 无统一随机权重工厂；强制 skip |
| step2 | `--model_type <registered> --device npu --config_path <dit_fallback.yaml>` | env 注入 `ASCEND_RT_VISIBLE_DEVICES=<idx>` |
| step3 | `--reference-weights <model_path>` | DiT skip 模式下必须显式指 |
| step4 | `--rules-path <auto-generated-from-inference-repo>` | 由 subagent 按 modeling_*.py 实际层名生成 |

### 4.3 量化 YAML

通用模板见 [`diagram_fallback.yaml`](../../../assets/dit/diagram_fallback.yaml)；
具体模型首次 exclude 空、按 inference_repo parse_args 填 `inference_config` 字段。

---

## 5. 注册 / 配置文件改动清单

> 任何新增多模态生成模型都遵循同一份清单。

### 5.1 `msmodelslim/config/config.ini`

```ini
[ModelAdapter]
<model_id> = <RegisteredModelType>, <alias1>, <alias2>

[ModelAdapterEntryPoints]
# 单网络 / 单场景
<model_id> = msmodelslim.model.<model_id>.loader:<ModelId>AdapterLoader

# 双专家 / 多场景（每个场景一个 loader，config.ini 一个注册项）
<model_id>_<scene_a> = msmodelslim.model.<model_id>.<scene_a>.loader:<ModelId><SceneA>AdapterLoader
<model_id>_<scene_b> = msmodelslim.model.<model_id>.<scene_b>.loader:<ModelId><SceneB>AdapterLoader
```

### 5.2 install

```bash
bash install.sh    # msModelSlim 重新注册 entry_points
```

---

## 6. 验收 checklist（落盘前自检）

完整 checklist 见 [`../interface_checklist.md §DiT / 多模态生成专属检查`](../interface_checklist.md)；
本节不重复列出。核心：结构（单 / 三层）+ CLI 桥接 + Pydantic + 12 类陷阱 + 四步验证全 passed。

---

## 7. 反模式（不要做）

| 反模式 | 为什么错 |
|--------|---------|
| 把 `Wan2_2T2VModelAdapter` / `HunyuanVideoModelAdapter` 直接复制粘贴到新模型 | 模型名/字段名硬编码；扩展性差 |
| 把 `enable_kv_cache` 在 DiT 中启用 | DiT 不依赖 KV cache；开启反而浪费显存 |
| 把 `inference_dump_calib_data` 写成空 / `pass` | data-free 的核心是浮点推理 dump；这是必须的 |
| 在 `prepare_calib_data` 直接 `inference_dump_calib_data` 而不读 `enable_dump` | 全动态量化路径会因此崩 |
| 用通用名（`num_inference_steps`）硬编码字段名 | 不同 DiT 仓命名差异极大；必须按 parse_args |
| 把双专家场景的 `init_model` 直接返回 `nn.Module` 而非 `Dict` | 量化服务 fail-fast |
| 子适配器只继承 `BaseModelAdapter` + `__getattr__` 代理 | `isinstance` 检查失败 → QuaRot/FA3 静默失效 |