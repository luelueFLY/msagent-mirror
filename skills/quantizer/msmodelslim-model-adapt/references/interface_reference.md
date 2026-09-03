# 模型适配基础接口参考

本文档只保留模型适配开发所需的基础接口。  
不包含 SmoothQuant、QuaRot、FA3、FlatQuant 等高阶算法接口。

## 1) IModel（基础模型属性）

**位置**: `msmodelslim/model/interface.py`

所有适配器的基础属性接口：

```python
class IModel:
    @property
    def model_type(self) -> str

    @property
    def model_path(self) -> Path

    @property
    def trust_remote_code(self) -> bool
```

实现要求：
- `model_type`：返回模型类型标识。
- `model_path`：返回模型目录路径。
- `trust_remote_code`：返回是否允许远程代码。

## 2) ModelSlimPipelineInterfaceV1（必需）

**位置**: `msmodelslim/core/runner/pipeline_interface.py`

基础量化适配必须实现的核心接口：

```python
class PipelineInterface(IModel):
    @abstractmethod
    def handle_dataset(self, dataset: Any, device: DeviceType = DeviceType.NPU) -> List[Any]:
        ...

    @abstractmethod
    def init_model(self, device: DeviceType = DeviceType.NPU) -> nn.Module:
        ...

    @abstractmethod
    def generate_model_visit(self, model: nn.Module) -> Generator[ProcessRequest, Any, None]:
        ...

    @abstractmethod
    def generate_model_forward(self, model: nn.Module, inputs: Any) -> Generator[ProcessRequest, Any, None]:
        ...

    @abstractmethod
    def enable_kv_cache(self, model: nn.Module, need_kv_cache: bool) -> None:
        ...
```

实现重点：
- `generate_model_visit` 与 `generate_model_forward` 的层顺序必须严格一致。
- `handle_dataset` 输出必须可直接用于前向。
- `init_model` 返回可执行前向且可被逐层访问的模型。

适用：所有模型（LLM / VLM / DiT）。

## 3) ModelInfoInterface（推荐）

**位置**: `msmodelslim/app/naive_quantization/model_info_interface.py`  
（部分场景也在 `msmodelslim/app/auto_tuning/model_info_interface.py` 使用）

用于提供模型基础信息：

```python
def get_model_pedigree(self) -> str
def get_model_type(self) -> str
```

说明：
- 该接口通常与 `TransformersModel + ModelSlimPipelineInterfaceV1` 组合使用。
- 若你的适配流程或导出流程依赖模型家族信息，建议实现。

## 4) 推荐继承组合

基础模型适配（LLM/VLM 文本主干）建议：

```python
class MyModelAdapter(TransformersModel,
                     ModelInfoInterface,
                     ModelSlimPipelineInterfaceV1):
    pass
```

若当前场景不需要模型信息能力，可省略 `ModelInfoInterface`，但 `ModelSlimPipelineInterfaceV1` 不可省略。

DiT模型适配建议：
```python
# DiT 单网络
class MyDiTAdapter(BaseModelAdapter, ModelInfoInterface, MultimodalPipelineInterface):
    pass

# DiT 双/多专家：基类 + 场景子类 + ExpertSubAdapter 三层
class MyDualExpertBase(BaseModelAdapter, ModelInfoInterface, MultimodalPipelineInterface):
    scene_task: ClassVar[str] = ""   # 子类固定
    DUAL_EXPERT_SCENE_TASKS: ClassVar[frozenset[str]] = frozenset()  # 子类固定双专家场景名

class MySceneAdapter(MyDualExpertBase):
    scene_task = "<scene_task>"     # 如 "t2v-A14B"
    class MySceneInferenceConfig(BaseModel): ...    # 含 task 校验
    def get_inference_config_class(self): ...
    def init_model(self, device) -> Dict[str, nn.Module]: ...
    def quantization_context(self): ...
    def _generate_video(self, prompt, image_path, inference_config): ...

class MyExpertSubAdapter(BaseModelAdapter):        # 显式继承
    def __init__(self, parent, expert_name): ...
```

---

## 5) DiT / 多模态生成（`MultimodalPipelineInterface`）

适用：HunyuanVideo、Wan2.2-T2V/I2V/TI2V、FLUX.1-dev、SD3、Sana、HunyuanDiT、CogViewX、**任何新 DiT**。

`MultimodalSDModelslimV1QuantService` 按此接口分发（统一重构路径；不再保留 Legacy）。

### 5.1 必须实现的 6 个方法

| 方法 | 说明 |
|------|------|
| `get_inference_config_class()` | 返回 Pydantic `BaseModel` 子类（`extra="forbid"`） |
| `configure_runtime(inference_config)` | 把已校验的 `inference_config` 落到 `model_args`（单次 parse_args） |
| `inference_dump_calib_data(dataset, inference_config)` | 浮点推理 dump 校准数据 |
| `prepare_calib_data(models, dump_config, save_path, dataset, inference_config)` | 按 expert_name 构造/加载 `calib_data` 缓存；**必须**读 `dump_config.enable_dump` 短路；末尾调 `release_auxiliary_models` |
| `quantization_context()` | `autocast + no_grad + ExitStack` 上下文 |
| `get_expert_adapter(expert_name)` | 按 `expert_name` 返回子适配器；**双专家未绑定时报 `InvalidModelError`**，不静默回退父适配器 |

### 5.2 代码分区（双/多专家 DiT）

| 分区 | 内容 |
|------|------|
| 1 | 公共流水线接口（`validate_calib_samples` / `handle_dataset` / `init_model` / `generate_model_visit` / `generate_model_forward` / `enable_kv_cache`） |
| 2 | 公共运行时配置（`*InferenceConfig` / `get_inference_config_class` / `configure_runtime`） |
| 3 | 公共校准执行（`prepare_calib_data` / `inference_dump_calib_data` / `quantization_context`） |
| 4 | 运行时通用辅助（`_runtime_value` / `_quantization_context_with_no_sync`） |
| 5 | 私有专家子适配器装配（`_bind_expert_sub_adapters` / `_create_expert_sub_adapter`） |
| 6 | 私有参数桥接（`_allowed_*_config_keys` / `_build_default_*_cli` / `_namespace_to_argv` / `_parse_args_from_*`） |
| 7 | 私有运行时与缓存装配（`_check_import_dependency` / `_load_pipeline` / `_setup_*_dit_runtime` / `_build_<id>_pipeline`） |
| 8 | 量化扩展接口（`get_online_rotation_configs` / `inject_fa3_placeholders` / `_attach_attention_cache_to_blocks`） |

### 5.3 单 DiT 适用精简分区

单 DiT（无 `expert` 概念）只保留分区 1~7，无分区 5（不需要 ExpertSubAdapter）。

### 5.4 双专家约束

- `init_model()` 返回的每个 expert 必须在 `calib_data` 中有对应 **key**；
- 缺 key 时量化服务 fail-fast 抛 `SchemaValidateError`；
- `calib_data[expert]=None` 表示无 dump 数据的全动态量化，仍算有效 key；
- **不支持**仅量化部分 expert（如只量化 `low_noise_model`）。

### 5.5 `InferenceConfig` 字段命名规范

**字段名必须与目标 DiT 推理仓的 `parse_args` argparse key 一一对应**——这是 Pydantic 校验 → CLI argv 桥接的基础。

| 字段语义 | HunyuanVideo (`hyvideo.config`) | Wan2.1/Wan2.2 (`generate.py`) | FLUX.1-dev (`inference_flux.py`) |
|---------|--------------------------------|-------------------------------|----------------------------------|
| 采样步数 | `infer_steps` | `sample_steps` | `num_inference_steps` |
| CFG 引导 | `cfg_scale` / `embedded_cfg_scale` | `sample_guide_scale` | `guidance_scale` |
| 调度偏移 | `flow_shift` | `sample_shift` | （视模型） |
| 分辨率 | `model_resolution` / `video_size` | `size`（字符串 `WxH`） | `height` / `width` |
| 帧数 | `video_length` | `frame_num` | （不适用） |
| 种子 | `seed` | `base_seed` | `seed` |

> 推理入口脚本名因仓而异（`generate.py` / `sample_video.py` / `inference_flux.py` 等）。**定位方法**：在 `inference_repo` 的 `README.md` 找推理示例命令，再到 `<repo>/config.py` / `<repo>/hyvideo/config.py` 等位置找 `parse_args` 的 `--<key>` 列表。

### 5.6 关键路径字段差异

| 路径字段 | HunyuanVideo | Wan2.2 | FLUX |
|---------|--------------|--------|------|
| 入口脚本 | `sample_video.py` | `generate.py` | `inference_flux.py` |
| parse_args 模块 | `hyvideo.config.parse_args` | `generate._parse_args` | `inference_flux` |
| 推理仓库主类 | `HunyuanVideoSampler` | `WanT2V` / `WanI2V` / `WanTI2V` | 自定义 sampler |
| 主 DiT | `self.transformer` | `self.low_noise_model` + `self.high_noise_model` | `self.transformer` |
| block 类名关键字 | `streamblock` | `attentionblock` | `doubleblock` / `singleblock` |

---

## 6) 推荐模板（按架构）

- LLM：`assets/model_adapter_template.py`
- VLM：`assets/vlm_model_adapter_template.py`
- DiT 单网络：`assets/dit_model_adapter_template.py`
- DiT 双/多专家（**通用**，推荐）：`assets/dit/skeleton.md`
- 通用多模态生成架构模式：[dit/architecture_patterns.md](dit/architecture_patterns.md)
- 通用多模态生成陷阱清单：[dit/pitfalls.md](dit/pitfalls.md)
