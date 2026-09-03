# 多模态生成（DiT / 扩散）适配器实现指南

> 本文件是 DiT 任务的**自包含实现指南**。LLM/VLM 任务不需要读本文件。
> 主路径文件 SKILL.md / core_workflow.md / 父级 implementation_guide.md 在 DiT 扩展节里只放指针。
> 通用架构模式见 [architecture_patterns.md](architecture_patterns.md)；通用陷阱清单见 [pitfalls.md](pitfalls.md)。

## 0. 前置条件（DiT 任务必查）

| 项 | 要求 |
|------|------|
| `inference_repo` | 用户**单独提供**（与权重目录互不包含的独立推理仓）；用 `AskUserQuestion` 强提示；仅校验"路径存在且为目录" |
| 模型族识别 | 复用 `msmodelslim-model-analysis` 结论；信号 `_diffusers_version` / 主仓 `config.ini` 多模态生成族 / 关键词 `文生视频 / 扩散 / Wan / FLUX / SD3` |
| 主架构判断 | 单 DiT / 双专家 / 单流多模块——见 [architecture_patterns.md](architecture_patterns.md) §1 决策树 |

## 1. 目录结构（按子架构）

### 1.1 DiT 单网络（如 HunyuanVideo / FLUX / SD3 / Sana）

```text
msmodelslim/model/<model_type>/
├── __init__.py
├── model_adapter.py       # 主适配器（含分区 1~7）
├── constants.py           # 可选：场景常量
└── loader.py              # <Model>AdapterLoader
```

### 1.2 DiT 双/多专家（如 Wan2.2）

```text
msmodelslim/model/<model_type>/
├── __init__.py                  # 导出基类 + 场景子类 + 子适配器
├── loader.py                    # legacy 入口（保留不动）
├── model_adapter.py             # legacy 单体（如有，保留不动）
├── constants.py                 # EXAMPLE_PROMPT / TASK_TYPES / DUAL_EXPERT_SCENE_TASKS / DEFAULT_SIZE
├── base_model_adapter.py        # 基类：分区 1~8
├── expert_sub_adapter.py        # 子适配器（不注册 model_type）
├── <scene_a>/
│   ├── __init__.py
│   ├── model_adapter.py
│   └── loader.py
├── <scene_b>/
│   └── ...（同上）
```

> **必须**保留 `__init__.py`；新接入模型按"复制场景子目录 → 改 scene_task + InferenceConfig + pipeline 加载"扩展。

## 2. 必实现接口（11 个）

### 2.1 基础 5 个（同 LLM/VLM 语义，但行为差异见 §4）

1. `handle_dataset`
2. `init_model`
3. `generate_model_visit`
4. `generate_model_forward`
5. `enable_kv_cache`

### 2.2 扩展 6 个（`MultimodalPipelineInterface`）

| 类别 | 方法 |
|------|------|
| 配置 | `get_inference_config_class` |
| 运行时 | `configure_runtime` |
| 数据 | `inference_dump_calib_data` / `prepare_calib_data` |
| 上下文 | `quantization_context` |
| 多专家 | `get_expert_adapter` |

签名/字段表详见 [interface_reference.md](../interface_reference.md) §5.1；典型实现模式见 [architecture_patterns.md](architecture_patterns.md) §2。

## 3. 模板选择

| 子架构 | 模板 | 基类 |
|------|------|------|
| DiT 单网络 | `assets/dit_model_adapter_template.py` | `BaseModelAdapter + ModelInfoInterface + MultimodalPipelineInterface + (FA3QuantAdapterInterface + OnlineQuaRotInterface)` |
| DiT 双/多专家 | `assets/dit/skeleton.md` | 基类 + 场景子类 + `ExpertSubAdapter` |

### 3.1 单 DiT 模板要点

- `enable_kv_cache` 默认 no-op（扩散推理不依赖 KV cache）
- `init_model` 返回 `Dict[str, nn.Module]`，单 DiT 为 `{'': self.transformer}`
- `block_keyword` 通过 `_resolve_block_keyword` 自动探测；探测失败时手动赋值
- `inference_dump_calib_data` 是 data-free 的核心 —— 由模型自身浮点推理 dump 校准数据

### 3.2 双/多专家模板要点（三层结构）

- `base_model_adapter.py`：通用 11 接口 + 双专家管理（`_bind_expert_sub_adapters` / `get_expert_adapter` / `_quantization_context_with_no_sync`）
- `expert_sub_adapter.py`：子适配器，**不**注册 `model_type`
- 每个 `<scene>/`：场景子类，只覆写 `scene_task` / `InferenceConfig` / `init_model` / `quantization_context` / `_generate_video` / `_build_<id>_pipeline`
- 子适配器**必须显式继承** `OnlineQuaRotInterface` / `FA3QuantAdapterInterface` / `IterSmoothInterface`（避免 `isinstance` 失败）

## 4. 接口功能说明（DiT 行为差异）

### 4.1 `handle_dataset(dataset, device) -> List[Any]`

- **职责**：dump 前仅做**场景校验**，**不**执行 forward；返回 `List[Any]` 供 `inference_dump_calib_data` 消费
- **与 LLM/VLM 差异**：LLM/VLM 走 `_get_tokenized_data` 转成 tokenized inputs；DiT 不需要这一步
- **实现建议**：校验样本含必需字段（如 prompt / image），不实际送模型

### 4.2 `init_model(device) -> nn.Module | Dict[str, nn.Module]`

- **职责**：返回 DiT Module 集合
- **输出**：
  - 单 DiT：`Dict[str, nn.Module]`，形如 `{'': self.transformer}`
  - 双专家：`Dict[str, nn.Module]`，形如 `{"low_noise_model": ..., "high_noise_model": ...}`
- **双专家末尾必须调** `_bind_expert_sub_adapters(experts)`，完成 expert key 与子适配器的绑定
- **典型陷阱**：meta tensor 迁移（B.1 详见 pitfalls.md A 类）；必须走两步 materialize + safe `.to(device)`，不要在量化路径写裸 `.to('npu')`

### 4.3 `generate_model_visit(model) -> Generator[ProcessRequest]`

- **职责**：按真实 DiT block 顺序逐 block 输出 `ProcessRequest`
- **实现路径**：自动探测 `block_keyword` + `generated_decoder_layer_visit_func_with_keyword`
- **探测失败时手动赋值** `block_keyword`（如 `'blocks'` / `'transformer_blocks'` / `'double_blocks'` 等）
- **与 `generate_model_forward` 严格一致**——同一 block 在两边语义、索引、输入输出对齐

### 4.4 `generate_model_forward(model, inputs) -> Generator[ProcessRequest]`

- **职责**：与 visit 对齐的分段前向
- **实现机制**：在**首个 block** 注册 `forward_pre_hook`，截获 `(args, kwargs)` 后中断完整前向；逐 block `yield ProcessRequest`，上一 block 输出作为下一 block 输入
- **典型陷阱**：见 pitfalls.md（enable_dump 短路 / parse_args 双次 / quant_overrides 等）

### 4.5 `enable_kv_cache(model, need_kv_cache) -> None`

- **职责**：扩散推理**不**依赖 KV cache，**默认 no-op**
- **与 LLM/VLM 差异**：LLM 复用基类 `_enable_kv_cache`；DiT 不需要
- **若误实现**：可能引入 cache 污染（详见 pitfalls.md）

### 4.6 `MultimodalPipelineInterface` 6 方法

| 方法 | 核心职责 |
|------|------|
| `get_inference_config_class` | 返回该模型场景的 `InferenceConfig` 子类（字段映射见 [inference_config_field_map.md](inference_config_field_map.md)） |
| `configure_runtime` | 注入运行时参数（如 `ASCEND_RT_VISIBLE_DEVICES`、`dtype`） |
| `inference_dump_calib_data` | **data-free 核心**——调用推理仓浮点推理，dump 校准数据 |
| `prepare_calib_data` | dump 完成后**释放 text_encoder/vae** 等非 DiT 部分，腾出连续 HBM |
| `quantization_context` | 提供量化上下文（`QuantConfigV2` / `qmap` / hook 注入）；双专家走 `_quantization_context_with_no_sync` |
| `get_expert_adapter` | 返回 expert name → `ExpertSubAdapter` 映射（仅双专家） |

完整签名见 [interface_reference.md](../interface_reference.md) §5.1；通用模式见 [architecture_patterns.md](architecture_patterns.md) §2；陷阱见 [pitfalls.md](pitfalls.md)。

## 5. 特殊情况（按子架构）

### 5.1 单 DiT

- `init_model` 返回 `Dict[str, nn.Module]`（单 DiT 为 `{'': self.transformer}`）
- `enable_kv_cache` 是 no-op
- `block_keyword` 自动探测失败时手动赋值
- `inference_dump_calib_data` 是 data-free 的核心

### 5.2 双/多专家 DiT

- `init_model` 返回双 expert dict；末尾必须调 `_bind_expert_sub_adapters(experts)`
- 子适配器**必须显式继承**扩展接口（避免 `isinstance` 失败）
- expert key 必须全链路一致（详见 pitfalls.md 第 7 类）
- 场景子类只覆写：`scene_task` / `InferenceConfig` / `init_model` / `quantization_context` / `_generate_video` / `_build_<id>_pipeline`
- 多场景注册：每个 `scene_task` 一个 loader 注册项（详见主 SKILL.md E3）

## 6. 关键实现原则

### 1) `generate_model_visit` 与 `generate_model_forward` 必须严格一致

DiT 同样适用；这是最容易出错、也最影响量化正确性的部分。

### 2) 不要靠模型名猜结构

必须读 inference_repo 的 `modeling_*.py` / `pipeline/*.py`，按 §0 决策树判断子架构后再写代码。

### 3) 通用陷阱必查

[pitfalls.md](pitfalls.md) 列了 12 类任何 DiT 都会撞到的陷阱（meta tensor / 显存碎片 / enable_dump 短路 / parse_args 双次 / quant_overrides / 双 expert key / 子适配器接口继承 / ExitStack / task 串扰 / 样本校验 / KV cache / block_keyword）。**落盘前必查**。

### 4) 双专家专属约束

- expert key 全链路一致（注册名 → `init_model` 返回 dict → `_bind_expert_sub_adapters` → 子适配器访问路径）
- 子适配器显式继承 `OnlineQuaRotInterface` / `FA3QuantAdapterInterface` / `IterSmoothInterface`
- `quantization_context` 走 `_quantization_context_with_no_sync`（双 expert 间无梯度同步）

## 7. 注册

```ini
[ModelAdapter]
my_dit = MyDiT

[ModelAdapterEntryPoints]
# DiT 单网络：一个 loader
my_dit = msmodelslim.model.my_dit.loader:MyDiTAdapter

# DiT 双/多专家：每个场景一个 loader（每个 scene_task 一个注册项）
my_dit_scene_a = msmodelslim.model.my_dit.scene_a.loader:MySceneAAdapterLoader
my_dit_scene_b = msmodelslim.model.my_dit.scene_b.loader:MySceneBAdapterLoader
```

注册名必须与主仓 `msmodelslim/config/config.ini` 的 `[ModelAdapter]` 一致。

注册后**必须**执行：

```bash
bash install.sh
```

## 8. 四步验证 flag

调用 `msmodelslim-adapter-verification` 时，DiT 任务必加：

| flag | 含义 |
|------|------|
| `--skip-random-model` | DiT 不接受随机权重生成 |
| `--model-family dit` | 标识 DiT 族 |
| `--inference-repo <path>` | 推理仓路径 |
| `--reference-weights <path>` | 参考权重路径 |
| `--rules-path <path>` | 描述文件规则路径 |

每步 `passed=true` 才视为通过；任一失败即中止并回传 `status: failed`。

## 9. 落盘前自检 checklist

- [ ] `inference_repo` 已提供且为独立目录
- [ ] 模板与子架构匹配（DiT-单 / DiT-双）
- [ ] 必实现接口齐全（11 个）
- [ ] `config/config.ini` 已注册（含 scene_task loader）
- [ ] `bash install.sh` 已执行
- [ ] 四步验证全 passed（含 DiT 必选 flag）
- [ ] [pitfalls.md](pitfalls.md) 12 类陷阱已逐条核对
- [ ] 双专家 DiT：expert key 全链路一致 + 子适配器显式继承扩展接口
- [ ] `inference_dump_calib_data` 与 `prepare_calib_data` 的 dump/release 顺序正确（避免显存碎片）
- [ ] `block_keyword` 探测已验证（自动探测失败时手动赋值）

## 10. 参见

- [architecture_patterns.md](architecture_patterns.md)：决策树 + 代码分区 + 通用陷阱
- [pitfalls.md](pitfalls.md)：12 类通用陷阱清单
- [inference_config_field_map.md](inference_config_field_map.md)：InferenceConfig 字段映射
- [diagram_fallback.yaml](diagram_fallback.yaml)：DiT 适配器类关系图（YAML 描述）
- [interface_reference.md](../interface_reference.md) §5.1：`MultimodalPipelineInterface` 完整签名
