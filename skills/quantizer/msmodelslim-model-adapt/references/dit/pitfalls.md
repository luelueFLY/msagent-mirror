# 多模态生成模型量化通用陷阱清单（适配必查）

> 这份清单从 Wan2.2-T2V-A14B 端到端验收中提取。每条都是**通用**的 —— 任何走 `MultimodalSDModelslimV1QuantService` 的多模态生成模型都会撞到。
> Agent 适配新模型时，**先逐条核对再落盘**。

---

## A. Meta tensor 迁移

### A.1 `Cannot copy out of meta tensor`

**触发**：在 `inference_dump_calib_data` 或 `init_model` 里裸写 `model.to('npu')` 或 `model.to(target_device)`，但模型里有 Parameter 仍落在 meta device。

**通用根因**：diffusers / 推理仓的 `WanModel.from_pretrained` 等加载范式会在量化 hook 注入后**懒**创建部分 Parameter（q/k norm、attn bias 等）。这些 Parameter 在首次 `to('npu')` 时才被复制 —— 但若上游 `materialize` round 没覆盖到它们，就抛 `NotImplementedError`。

**通用修法**（两步）：
1. **materialize**：遍历所有 `Parameter`，对 `device.type == 'meta'` 的走 `module._parameters[name] = nn.Parameter(param.to(target_device), requires_grad=...)`；
2. **safe `.to(device)`**：再调一次 `.to(target_device)`（此时已无 meta 参数）。

> 不要在量化路径任何位置写裸 `.to('npu')`；要么走上面两步，要么用推理仓自带的 `convert_model_dtype` flag。

---

## B. 显存碎片化

### B.1 60 GB HBM 仅占 6 GB 就 OOM

**触发**：dump 完 T5/VAE 没有释放 → 量化阶段 `low_noise_model.to('npu')` 找不到连续 30+ GB。

**通用根因**：`prepare_calib_data` 走完 `inference_dump_calib_data` 后，pipeline 的 `text_encoder` / `vae` 仍占着 NPU 显存。后续 `low/high_noise_model.to('npu')` 要 30+ GB 连续空间，HBM 因碎片化无法分配。

**通用修法**：`prepare_calib_data` 末尾**显式**释放辅助模型：

```python
def release_auxiliary_models(self):
    """任何 DiT 通用：dump 完释放 text_encoder / vae / 等与量化无关的子模块。"""
    pipeline_attrs = ("wan_t2v", "wan_i2v", "wan_ti2v", "pipeline")
    for attr in pipeline_attrs:
        pipeline = getattr(self, attr, None)
        if pipeline is None:
            continue
        for sub_name in ("text_encoder", "vae", "image_encoder", "safety_checker"):
            sub = getattr(pipeline, sub_name, None)
            if sub is not None:
                # 子模块若 .model 是真正的 Module，则先把子模块迁 CPU
                inner = getattr(sub, "model", None)
                if isinstance(inner, nn.Module):
                    inner.cpu()
                del pipeline.__dict__[sub_name]
    if hasattr(torch, "npu") and hasattr(torch.npu, "empty_cache"):
        torch.npu.empty_cache()
    elif torch.cuda.is_available():
        torch.cuda.empty_cache()
```

> 新模型若还有别的"量化无关子模块"（如 `image_encoder` / `safety_checker` / `prompt_extender`），**同样**在此函数里释放。

---

## C. `dump_config.enable_dump` 的语义陷阱

### C.1 `enable_dump=False` 仍触发浮点推理 → 崩

**触发**：适配器 `prepare_calib_data` 没读 `dump_config.enable_dump`，永远调 `inference_dump_calib_data` → `WanT2V.generate` → `low_noise_model.to('npu')` → meta tensor 错误。

**根因**：误以为 `enable_dump=False` = "完全跳过 dump"。

**通用语义**：
- `enable_dump=False`（**DiT data-free 默认**）：完全跳过 dump，返回 `{expert_name: None}`
- `enable_dump=True`：走 `inference_dump_calib_data`（用模型自身浮点推理产 calib_data；仅在确需 dump 校准数据时显式开启）

**通用修法**（必须）：

```python
def prepare_calib_data(self, models, dump_config, save_path, dataset, inference_config):
    if not dump_config.enable_dump:
        return {expert_name: None for expert_name in models}   # P1 短路
    # ... 正常路径
```

---

## D. parse_args 单次调用

### D.1 `__init__` + `configure_runtime` 双次 parse_args

**触发**：基类 `__init__` 与 `configure_runtime` 都各自调一次原仓 `parse_args()`。

**根因**：parse_args 内部用 `argparse.ArgumentParser.parse_args()`，其默认会读 `sys.argv[1:]`。双次调用可能在分布式 / 多线程场景下污染全局。

**通用修法**（单次 + 安全包装）：

```python
def _parse_args_from_<repo>(self, cli_args: List[str]):
    """通用：临时改写 sys.argv → finally 恢复 → 单次调用 parse_args。"""
    original_argv = sys.argv
    try:
        sys.argv = ["<entry>.py", *cli_args]
        return <repo>._parse_args()
    finally:
        sys.argv = original_argv
```

**调用约定**：
- 基类 `__init__` **不**预解析（避免污染 model_args）；
- 仅 `configure_runtime` 调一次；
- 字段白名单探测（`_allowed_*_config_keys`）也在这次解析时一并拿到。

---

## E. 量化固定 flag 缺失

### E.1 量化时受并行 / cache 干扰 → 不收敛 / OOM

**触发**：YAML 写得不完整 → 原仓 CLI 默认打开 `dit_fsdp=True` / `use_attentioncache=True` / `ulysses_size>1` 等 → 量化 stage 触发 DDP 初始化或多卡并行 → 卡死 / OOM。

**通用修法**（注入量化固定覆盖）：

```python
quant_overrides = {
    # 通用：分布式并行
    "cfg_size": 1, "ulysses_size": 1, "ring_size": 1, "tp_size": 1,
    # 通用：并行开关
    "vae_parallel": False, "t5_fsdp": False, "dit_fsdp": False,
    # 通用：cache / fusion
    "use_attentioncache": False, "use_rainfusion": False,
    # 按模型加：如 Wan2.2 不需要 use_prompt_extend（避免 dashscope 依赖）
    "use_prompt_extend": False,
}
argv.extend(self._namespace_to_argv(quant_overrides))
argv.extend(["--task", self.scene_task, "--ckpt_dir", str(self.model_path)])
```

> **字段名按目标 DiT 推理仓 parse_args 实际支持的 key 调整**；找不到对应 key 时 Pydantic/白名单校验会 fail-fast，可定位。

---

## F. 双专家 key 一致性

### F.1 `init_model` dict key 与 `calib_data` key 不一致 → `SchemaValidateError`

**触发**：`init_model` 返回 `{"low_noise_model": ..., "high_noise_model": ...}`，但 `prepare_calib_data` 写出 `calib_data_<task>_low.pth`（key 是 `low` 而非 `low_noise_model`）。

**根因**：expert key 必须全链路一致（`init_model` → `_bind_expert_sub_adapters` → `get_expert_adapter` → `prepare_calib_data` 的 pth 文件名）。

**通用修法**：
1. 基类定义 `DUAL_EXPERT_SCENE_TASKS = frozenset({"<scene_a>", "<scene_b>"})`；
2. 子类 `init_model` 构造 dict 时**完全按 DUAL_EXPERT_SCENE_TASKS 中的 key**；
3. 基类 `get_expert_adapter` 在双专家未绑定时报 `InvalidModelError`（不静默回退父适配器，避免 quantize 走错 context）。

---

## G. 子适配器接口继承

### G.1 QuaRot / FA3 静默失效

**触发**：`Wan2_2ExpertSubAdapter` 只继承 `BaseModelAdapter`，靠 `__getattr__` 把扩展方法代理到父类。结果 `LayerWiseRunner` 的 `isinstance(sub, OnlineQuaRotInterface)` 返回 `False`，量化 service 直接跳过 QuaRot/FA3 算子。

**根因**：isinstance 检查不识别 `__getattr__` 委托。

**通用修法**：子适配器**显式继承**所有扩展接口：

```python
class MyExpertSubAdapter(
    BaseModelAdapter,
    OnlineQuaRotInterface,
    FA3QuantAdapterInterface,
    IterSmoothInterface,
):
    def __init__(self, parent, expert_name): ...
    def get_online_rotation_configs(self, model=None): return self._parent.get_online_rotation_configs(model)
    def inject_fa3_placeholders(self, root_name, root_module, should_inject):
        return self._parent.inject_fa3_placeholders(root_name, root_module, should_inject)
```

---

## H. `_quantization_context_with_no_sync` 多 expert 包装

### H.1 单层 `with A, B, C` 写死 expert 数量

**触发**：基类量化上下文写 `with self.low_noise_model.no_sync(), self.high_noise_model.no_sync()`，但单专家 / 三专家模型上不存在对应 attribute → AttributeError。

**通用修法**（ExitStack 动态 enter）：

```python
@contextmanager
def _quantization_context_with_no_sync(self, *dit_models: nn.Module):
    import torch.cuda.amp as amp
    # 模块迁移：非 blocks → npu，blocks → cpu（推理仓 block 名通常含 'blocks'）
    for m in dit_models:
        if m is None: continue
        for name, module in m.named_modules():
            if not name: continue
            (module.to('cpu') if name.startswith('blocks') else module.to('npu'))
    with amp.autocast(dtype=self.model_args.param_dtype), torch.no_grad(), ExitStack() as stack:
        for m in dit_models:
            if m is None: continue
            stack.enter_context(getattr(m, "no_sync", nullcontext)())
        yield
```

> 子类 `quantization_context` 直接 `return self._quantization_context_with_no_sync(*experts)` 即可。

---

## I. Pydantic 校验链与跨场景串扰

> YAML `multimodal_sd_config` 的校验分**两级**（真相源：主仓 `msmodelslim/core/quant_service/multimodal_sd_v1/quant_config.py` 的 `MultimodalSDConfig`）：
>
> 1. **YAML schema 层**：`MultimodalSDConfig`（`extra="allow"`，迁移期兼容）。声明字段只有 `dump_config`（必选）和 `inference_config`（Optional dict）；任何其它 key 落入 `model_extra`。
> 2. **适配器字段层**：`validate_inference_config` 取 `resolve_inference_raw()` 的 dict，用适配器 `get_inference_config_class()` 的 `InferenceConfig`（`extra="forbid"`）做 `model_validate`。
>
> 两级校验对**任何** YAML 都恒定生效；区别在字段选择：
>
> - YAML 写 `inference_config` → 两级都严格校验（第 1 级 schema + 第 2 级适配器字段，`extra="forbid"` fail-fast）
> - YAML 写 `model_config`（迁移期旧字段）→ 第 1 级经 `extra="allow"` 宽容收纳 + deprecation warning；第 2 级 `validate_inference_config` 仅接受 `MultimodalPipelineInterface`（新接口）适配器，legacy 适配器不经过它

### I.1 `inference_config` 与迁移期 `model_config` 互斥

**触发**：YAML `multimodal_sd_config` 同时写 `inference_config` 和 `model_config`（迁移期旧字段）→
`SchemaValidateError: inference_config and model_config are mutually exclusive; please keep only one.`

**根因**：`MultimodalSDConfig.validate_inference_config_exclusive`（`model_validator`）强制两者互斥。`extra="allow"` 只保证 `model_config` 能**落进** `model_extra` 不报 unknown field，但与 `inference_config` 并存即 fail-fast。

**通用修法**：新模型 YAML 一律只写 `inference_config`。`model_config` 仅主仓历史 YAML 迁移期使用（`resolve_inference_raw` 回退读取时打 deprecation warning），不要出现在任何模板 / 文档 / 新生成的 YAML 里。

> **撞名警告**：适配器 `InferenceConfig` 类体内的 `model_config = ConfigDict(extra="forbid")` 是 **Pydantic 类属性**，与 YAML 的 `model_config` 段毫无关系。排查报错时不要把类属性"补"进 YAML——那正是触发互斥报错的最短路径。

**合法写法对照**：

```yaml
multimodal_sd_config:
  dump_config:                 # 必选
    capture_mode: "args"
    dump_data_dir: ""
  inference_config:            # ✅ 新路径：经适配器 InferenceConfig 校验
    size: "1280*720"
    sample_steps: 40
  # model_config: {...}        # ❌ 迁移期旧字段；与 inference_config 互斥，勿写
```

### I.2 YAML `task` 字段覆盖 `scene_task`

**触发**：用户用 `Wan2.2-T2V-A14B` 注册名（指向 T2V 适配器），但 YAML `inference_config.task="i2v-A14B"` → 跨场景串扰 → I2V pipeline 被错误地按 T2V 配置加载。

**通用修法**：

```python
class MyInferenceConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    task: Optional[str] = "t2v-A14B"        # 必须有默认值 + 校验

    @model_validator(mode='before')
    @classmethod
    def _reject_mismatched_task(cls, data):
        expected = "<this_scene_task>"
        if isinstance(data, dict) and data.get("task") not in (None, expected):
            raise ValueError(
                f"task {data['task']!r} does not match this adapter (expected {expected!r}). "
                f"Use model_type <other_model_type> for {data['task']!r}."
            )
        return data
```

---

## J. 样本校验规则

### J.1 T2V 校准收到带 image 的样本

**触发**：dataset 同时含 T2V 校准样本（无 image）和 I2V 校准样本（带 image），T2V 适配器误消费带 image 的 → 推理路径上 image 为空 / 类型错误。

**通用规则**（按场景分类）：

| 场景 | text 必填 | image 必填 | image 可选 |
|------|----------|-----------|-----------|
| 文本生视频/图像 (T2V/T2I) | ✅ | ❌ 禁 | — |
| 图生视频/图像 (I2V/I2I) | ✅ | ✅ | — |
| 文本+图像生 (TI2V/TI2I) | ✅ | — | ✅ |

**通用实现模板**：

```python
def validate_calib_samples(self, samples):
    rule = self._SAMPLE_RULE  # 子类 ClassVar
    for idx, sample in enumerate(samples):
        if not (isinstance(sample.text, str) and sample.text.strip()):
            raise SchemaValidateError(f"{self.scene_task} sample[{idx}] requires non-empty text")
        if rule.image_required and sample.image is None:
            raise SchemaValidateError(f"{self.scene_task} sample[{idx}] requires image")
        if rule.image_forbidden and sample.image is not None:
            raise SchemaValidateError(f"{self.scene_task} sample[{idx}] must not include image")
    return samples
```

---

## K. KV cache 不应在 DiT 启用

### K.1 启用 KV cache 导致量化时显存爆炸

**触发**：Agent 为"统一"在 DiT 路径启用 KV cache。

**通用原则**：DiT 推理**不依赖 KV cache**（扩散去噪是全序列并行）。模板默认 `pass` 写日志，禁止启用。

---

## L. block_keyword 探测失败

### L.1 自动探测找不到非平凡类名

**触发**：模型 block 类名短 / 不含 "block" / 全部 module 类名都是 trivial（Linear/LayerNorm/...）。

**通用兜底**：子类在 `_load_pipeline` 后直接赋值 `self.block_keyword = "<从 modeling_*.py 读到的子串>"`；不要纯靠自动探测。