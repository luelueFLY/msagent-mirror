# 适配器注册指南

在 `config/config.ini` 中注册模型与入口。

## 示例

```ini
[ModelAdapter]
my_model = MyModel-7B, MyModel-13B

[ModelAdapterEntryPoints]
my_model = msmodelslim.model.my_model.model_adapter:MyModelAdapter
```

注册完成后，务必执行 `bash install.sh` 安装更新。

## DiT / 多模态生成模型

### 单网络 DiT

```ini
[ModelAdapter]
my_dit = MyDiT-Model

[ModelAdapterEntryPoints]
my_dit = msmodelslim.model.my_dit.model_adapter:MyDiTModelAdapter
```

### 双/多专家 DiT（每个场景一个 loader）

```ini
[ModelAdapter]
my_model_scene_a = MyModel-SceneA
my_model_scene_b = MyModel-SceneB

[ModelAdapterEntryPoints]
my_model_scene_a = msmodelslim.model.my_model.scene_a.loader:MySceneAAdapterLoader
my_model_scene_b = msmodelslim.model.my_model.scene_b.loader:MySceneBAdapterLoader
```

### 注册名与 alias

- 注册名（key）必须命中 `[ModelAdapter]` 中声明的别名之一
- `--model_type` 传 key / alias 任一都可命中

### 与 LLM/VLM 共用注册机制

DiT 与 LLM/VLM 共用同一 `config/config.ini`；不引入新的注册路径。

### 旧版 Legacy 入口（**仅供主仓历史模型保留**）

> **新接入的 DiT 模型必须统一实现 `MultimodalPipelineInterface`**（重构路径）；不再注册到 `LegacyMultimodalPipelineInterface` 入口。
>
> 历史以 Legacy 注册的 `model_type`（如 `flux1` / `wan2_1`）需在本项目中迁移到重构路径，由 `msmodelslim-model-adapt` 改造主仓入口模块。

---

## 重要：注册名必须与主仓一致

- `model_type`（注册 key）必须与 `msmodelslim/config/config.ini` 主仓完全一致
- 新接入模型按 `model_type` 与权重目录 `config.json` 中的字段一致，或使用 `<org>/<model>` 别名