# 必需接口检查清单

在跑验证前，确认以下方法已实现并正确接入。

## 基础检查（所有架构）

- [ ] `handle_dataset`
- [ ] `init_model`
- [ ] `generate_model_visit`
- [ ] `generate_model_forward`
- [ ] `enable_kv_cache`

## 对齐检查

- [ ] `generate_model_visit` 与 `generate_model_forward` 遍历的层一致
- [ ] 遍历顺序一致
- [ ] 层间输入输出传递一致
- [ ] LLM/VLM：检查 tokenizer 的 `pad_token` / `pad_token_id`；若为 `None`，已在适配器中重写 `_load_tokenizer` 并设置 `pad_token = eos_token`

## 注册检查

- [ ] `config/config.ini` 的 `[ModelAdapter]` 下已配置模型别名
- [ ] `config/config.ini` 的 `[ModelAdapterEntryPoints]` 下已配置入口
- [ ] 代码修改后已重新安装包（`bash install.sh`）

## DiT / 多模态生成专属检查

### 必备 6 个方法

- [ ] `get_inference_config_class`（返回 Pydantic `BaseModel` 子类，`extra="forbid"`）
- [ ] `configure_runtime`（单次 `sys.argv` 替换 + `quant_overrides` 注入）
- [ ] `inference_dump_calib_data`（`torch.manual_seed` + `stream.synchronize`）
- [ ] `prepare_calib_data`（**读 `dump_config.enable_dump` 短路** —— `enable_dump=False` → 直接返回 `{expert: None}`，即 DiT data-free 默认路径；末尾调 `release_auxiliary_models`）
- [ ] `quantization_context`（`autocast + no_grad + ExitStack`）
- [ ] `get_expert_adapter`（**双专家未绑定时 `InvalidModelError`**，不静默回退父适配器）

### 通用陷阱核对（任何 DiT 必查）

> 12 类陷阱 A-L 详见 [dit/pitfalls.md](dit/pitfalls.md)，每条已逐条核对。

### 推理仓相关

- [ ] 已取得用户提供的 `inference_repo`（与权重目录分离）
- [ ] `init_model` 已将 `inference_repo` 注入 `sys.path` / `PYTHONPATH`
- [ ] `handle_dataset` 输出字段与目标模型 `forward` 签名严格对齐
- [ ] `generate_model_visit` 跨块顺序正确（如双流 → 单流）

### 双/多专家 DiT 额外

- [ ] `scene_task: ClassVar[str]` 子类固定
- [ ] `DUAL_EXPERT_SCENE_TASKS` 已声明
- [ ] 子适配器显式继承扩展接口（P7）
- [ ] `_quantization_context_with_no_sync` 使用 ExitStack 包裹多 expert（H）
- [ ] `_bind_expert_sub_adapters` 在 `init_model` 末尾被调用

## YAML 配置检查（多模态生成）

- [ ] `apiversion: multimodal_sd_modelslim_v1`（不是 `modelslim_v1`）
- [ ] **写** `spec.dataset`（显式写正确短名以便回退/复现；`enable_dump: false` 时不参与 dump，但省略会落到默认 `mix_calib.jsonl` 并失败）
- [ ] **设** `dump_config.enable_dump: false`（DiT data-free 路径不 dump 校准数据，短路 `prepare_calib_data`；`true` 仅在确需浮点推理 dump 时显式开启，见 msmodelslim-adapter-verification/references/dit/README.md 硬约束 #2）
- [ ] 顶层除 `apiversion / metadata / spec` 外无额外字段
- [ ] `inference_config` 字段名命中目标 DiT 推理仓 `parse_args` 的 `--key`

## 验证检查（DiT）

- [ ] step1 加 `--skip-random-model --model-family dit`
- [ ] step3 加 `--reference-weights <model_path>`
- [ ] 四步均 `passed=true`