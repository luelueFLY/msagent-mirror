# 多模态生成（DiT/扩散）双/多专家适配器骨架

> 单 DiT 模板见 `assets/dit_model_adapter_template.py`。
> 双/多专家场景（如 Wan2.2-T2V/I2V/TI2V 系列）按本骨架走「基类 + 场景子类 + ExpertSubAdapter」三层结构。
>
> 三层结构防御通用陷阱（meta tensor、enable_dump 短路、ExitStack、expert key 校验等）。
> **新模型只改 InferenceConfig（分区 2）+ CLI 桥接（分区 6）+ pipeline 加载（分区 7）即可。**

---

## 文件 1：双/多专家基类骨架

`dual_expert_base_model_adapter.py`（参考 Wan2.2 base_model_adapter）

> 在单 DiT 骨架（见 `assets/dit_model_adapter_template.py`）的基础上额外实现：
> - `scene_task: ClassVar[str]` 子类固定；
> - `_bind_expert_sub_adapters(experts)` / `_create_expert_sub_adapter(name)`；
> - `_quantization_context_with_no_sync(*dit_models)` 用 ExitStack；
> - `get_expert_adapter(name)` 在双专家未绑定时 `InvalidModelError`；
> - `_runtime_value` / `_namespace_to_argv` 与单 DiT 共享。

```python
"""双/多专家 DiT 基类骨架（参考 Wan2.2 base_model_adapter）。

子适配器需求（见文件 2）：每个 expert 必须有独立的 Wan2_2ExpertSubAdapter。
本类负责：bind 子适配器、按 expert_name 调度、ExitStack 量化上下文、release 辅助模型。
"""
from contextlib import ExitStack, contextmanager, nullcontext
from typing import ClassVar, Dict, Optional, Union

import torch
from pydantic import BaseModel
from torch import nn

from .expert_sub_adapter import MyExpertSubAdapter   # 见文件 2


class MyDualExpertBaseAdapter(...):
    """通用多专家 DiT 基类。

    子类只负责：
      1. 固定 scene_task；
      2. 声明 *InferenceConfig（含 task 校验）；
      3. init_model 中按 DUAL_EXPERT_SCENE_TASKS 写出 experts dict 并调 _bind_expert_sub_adapters；
      4. _generate_video 调目标 pipeline；
      5. _load_pipeline 创建目标 pipeline 写出 self.low_noise_model / self.high_noise_model。
    """

    scene_task: ClassVar[str] = ""               # 子类固定
    _GENERATE_CONFIG_KEYS: ClassVar[Optional[frozenset[str]]] = None

    DUAL_EXPERT_SCENE_TASKS: ClassVar[frozenset[str]] = frozenset()  # 子类固定双/多专家场景名

    def __init__(self, model_type, model_path, trust_remote_code=False):
        if not self.scene_task:
            raise SchemaValidateError("Must subclass with scene_task fixed")
        super().__init__(model_type, model_path, trust_remote_code)
        self.low_noise_model = None
        self.high_noise_model = None
        self._expert_adapters: Dict[str, MyExpertSubAdapter] = {}

    def init_model(self, device=DeviceType.NPU) -> Dict[str, nn.Module]:
        """P6 通用：基类提供，子类覆写后末尾必须调 _bind_expert_sub_adapters。"""
        raise NotImplementedError(f"{type(self).__name__} must implement init_model()")

    def get_expert_adapter(self, expert_name: str):
        """P6 通用：双专家未绑定时报 InvalidModelError（不静默回退父适配器）。"""
        a = self._expert_adapters.get(expert_name)
        if a is not None: return a
        if self.scene_task not in self.DUAL_EXPERT_SCENE_TASKS and expert_name == "":
            return self
        raise InvalidModelError(
            f"Expert sub-adapter not found for {expert_name!r} (scene_task={self.scene_task!r}).",
            action="Ensure init_model() calls _bind_expert_sub_adapters with keys matching QuantService expert names.",
        )

    # ===== P8 通用：ExitStack 多 expert 量化上下文 =====
    @contextmanager
    def _quantization_context_with_no_sync(self, *dit_models: nn.Module):
        import torch.cuda.amp as amp
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

    # ===== 分区 5：私有专家子适配器装配 =====
    def _bind_expert_sub_adapters(self, expert_modules: Dict[str, nn.Module]):
        adapters = {}
        for name, module in expert_modules.items():
            sub = self._create_expert_sub_adapter(name)
            sub.bind_module(module)
            adapters[name] = sub
        self._expert_adapters = adapters

    def _create_expert_sub_adapter(self, expert_name: str) -> "MyExpertSubAdapter":
        return MyExpertSubAdapter(self, expert_name)
```

---

## 文件 2：双/多专家子适配器骨架

`expert_sub_adapter.py`

```python
"""子适配器骨架（按 expert 调度的代理）。

P7 通用：必须显式继承 OnlineQuaRotInterface / FA3QuantAdapterInterface / IterSmoothInterface，
不能仅靠 __getattr__ 委托 —— LayerWiseRunner 的 isinstance 会失败（详见 pitfalls.md §G）。
"""
from typing import TYPE_CHECKING, Any, Callable, Optional

from torch import nn

from msmodelslim.model.base import BaseModelAdapter
from msmodelslim.model.interface_hub import (
    FA3QuantAdapterInterface, OnlineQuaRotInterface, IterSmoothInterface,
)

if TYPE_CHECKING:
    from .dual_expert_base_model_adapter import MyDualExpertBaseAdapter


class MyExpertSubAdapter(
    BaseModelAdapter,
    OnlineQuaRotInterface,        # P7: 显式继承
    FA3QuantAdapterInterface,     # P7
    IterSmoothInterface,          # P7
):
    def __init__(self, parent: "MyDualExpertBaseAdapter", expert_name: str):
        self._parent = parent
        self.expert_name = expert_name
        self._module: Optional[nn.Module] = None

    def bind_module(self, module: nn.Module): self._module = module
    def __getattr__(self, item): return getattr(self._parent, item)   # 默认代理其它方法

    def quantization_context(self):
        return self._parent._quantization_context_with_no_sync(self._module)

    def generate_model_forward(self, model, inputs):
        return self._parent.generate_model_forward(model, inputs)

    def generate_model_visit(self, model):
        return self._parent.generate_model_visit(model)

    def enable_kv_cache(self, model, need_kv_cache):
        return self._parent.enable_kv_cache(model, need_kv_cache)

    def get_online_rotation_configs(self, model=None):
        return self._parent.get_online_rotation_configs(model or self._module)

    def inject_fa3_placeholders(self, root_name, root_module, should_inject):
        return self._parent.inject_fa3_placeholders(root_name, root_module, should_inject)

    def get_adapter_config_for_subgraph(self):
        return self._parent.get_adapter_config_for_subgraph(self._module.num_layers)
```

---

## 文件 3：场景子类骨架（每个 scene 一份）

`dual_expert_scene_model_adapter.py`（参考 Wan2.2 t2v/model_adapter）

```python
"""场景子类骨架（T2V / I2V / TI2V / 任一具体场景）。

每个具体场景复制此骨架 → 改 scene_task / InferenceConfig / validate_calib_samples /
init_model / quantization_context / _generate_video / _build_<id>_pipeline。
"""
from typing import Any, Dict, Literal, Optional

import torch.nn as nn
from pydantic import BaseModel, ConfigDict, field_validator, model_validator

from msmodelslim.core.const import DeviceType
from msmodelslim.infra.dataset_loader.vlm_dataset_loader import VlmCalibSample
from msmodelslim.utils.exception import SchemaValidateError

from ..dual_expert_base_model_adapter import MyDualExpertBaseAdapter


class MySceneModelAdapter(MyDualExpertBaseAdapter):
    """<scene_task> 场景适配器骨架。"""

    scene_task = "<scene_task>"             # 子类固定（如 "t2v-A14B"）
    DUAL_EXPERT_SCENE_TASKS = frozenset({"<scene_task>"})  # 标明双专家

    class MySceneInferenceConfig(BaseModel):
        model_config = ConfigDict(extra="forbid")
        # 按目标 parse_args 字段重写
        size: Optional[str] = "<default_size>"
        sample_steps: Optional[int] = <default_steps>
        sample_guide_scale: Optional[float] = None
        base_seed: Optional[int] = None
        task: Optional[str] = "<scene_task>"           # I9: 必须含 task 与 scene_task 一致

        @field_validator("sample_guide_scale", mode="before")
        @classmethod
        def _reject_non_cli_guide_scale(cls, value):
            if isinstance(value, (tuple, list)):
                raise ValueError("sample_guide_scale must be a single float")
            return value

        @model_validator(mode="before")
        @classmethod
        def _reject_mismatched_task(cls, data):         # I9: 拒绝跨场景串扰
            expected = "<scene_task>"
            if isinstance(data, dict) and data.get("task") not in (None, expected):
                raise ValueError(f"task {data.get('task')!r} does not match {expected!r}")
            return data

    def get_inference_config_class(self): return self.MySceneInferenceConfig

    def validate_calib_samples(self, samples):          # J: 场景规则
        for idx, s in enumerate(samples):
            if not (isinstance(s.text, str) and s.text.strip()):
                raise SchemaValidateError(f"<scene_task> sample[{idx}] requires non-empty text")
            if s.image is not None:                     # T2V 禁图；I2V 强图 / TI2V 可选
                raise SchemaValidateError(f"<scene_task> sample[{idx}] must not include image")
        return samples

    def init_model(self, device=DeviceType.NPU) -> Dict[str, nn.Module]:
        _ = device
        self._load_pipeline()
        experts = {"low_noise_model": self.low_noise_model, "high_noise_model": self.high_noise_model}
        self._bind_expert_sub_adapters(experts)         # P6
        return experts

    def quantization_context(self):                     # H: 子类直接 return 基类 ExitStack 上下文
        return self._quantization_context_with_no_sync(self.low_noise_model, self.high_noise_model)

    def _generate_video(self, prompt, image_path, inference_config):
        # 子类调目标 pipeline（如 wan_t2v.generate / hunyuan_video.predict / ...）
        self.<scene_pipeline>.generate(prompt, ...)

    def _build_<id>_pipeline(self, args, cfg, device, rank):
        # 子类创建目标 pipeline 实例
        self.<scene_pipeline> = <ScenePipelineClass>(...)
        self.low_noise_model = self.<scene_pipeline>.low_noise_model
        self.high_noise_model = self.<scene_pipeline>.high_noise_model
        self._setup_<id>_dit_runtime(args, self.low_noise_model, self.high_noise_model)
```

---

## 落地步骤（任何新多模态生成模型）

1. 复制对应骨架 → `msmodelslim/model/<model_id>/`；
2. 替换 `<...>` 占位符为目标模型字段（按 `references/dit/architecture_patterns.md §1.2` 列出的方法识别 parse_args 与 block_keyword）；
3. 在 `__init__.py` 导出基类 + 场景子类 + 子适配器；
4. 在 `config.ini` 注册新 `model_type` 与 `[ModelAdapterEntryPoints]`；
5. 跑 `bash install.sh`；
6. 走 `msmodelslim-adapter-verification` 四步验证（DiT 必加 `--skip-random-model`）；
7. 落盘前先过 `references/dit/pitfalls.md` 的 12 类通用陷阱。
