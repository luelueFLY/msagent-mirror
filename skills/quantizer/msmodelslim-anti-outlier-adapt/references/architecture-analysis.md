# 使用 msModelSlim 提取模型结构

模型结构提取以用户当前环境中已安装的 msModelSlim `fast_ops_grapher` 公共 Python API 为
实现依据。用 Python `inspect.signature`、`help` 或实际导入核对可用接口，不依赖 msModelSlim
源码 checkout，也不得引用其 `docs/zh` 文档。msAgent 不维护自研 AST 扫描、hook、FX tracing
或图 formatter 脚本。

## 官方能力

导入入口：

```python
from msmodelslim.core.graph.fast_ops_grapher import (
    NativeModuleExtractor,
    TransformerAutoExtractor,
    TransformerExtractor,
)
```

按模型状态选择：

- 只有模型路径：`TransformerAutoExtractor.create(model_path, trust_remote_code, device, revision)`；
- 已加载 Transformers 模型和 tokenizer：`TransformerExtractor.create(model, tokenizer)`；
- 自定义或非 Transformers `nn.Module`：`NativeModuleExtractor.create(module, args, kwargs)`。

统一调用：

```python
graph = extractor.extract_dag()
dot_str = graph.format("dot")
```

将官方 formatter 的结果按算法保存为 `anti_outlier_graph.<algorithm>.dot`。需要程序内核对时直接使用
`ComputationGraph.iter_nodes()`、`iter_edges()`、`GraphNode.get_successors()` 和
`get_predecessors()`，不得为此新增 msAgent 结构提取脚本。

## 图信息核对

官方图节点提供 operator 记录，边提供 tensor 数据流。核对离群值抑制关系时关注：

- operator name 与 traceback 对应的真实模块；
- tensor varname、dtype 和 shape；
- norm、attention、MLP、expert、残差流之间的前驱/后继；
- GQA/MLA、融合 QKV、VLM merger、MTP 等分支是否实际出现在执行图中。

无法由默认 dummy input 覆盖的动态分支，应调整官方 Extractor 的合法输入或使用
`NativeModuleExtractor`，并在交付说明中记录覆盖限制；不得退回自研静态扫描脚本。
