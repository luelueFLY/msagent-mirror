# 专用拓扑模式

以下内容只用作分析提示，不得复制其中的路径名称：

- GQA：在 V/O 和 smoothing 元数据中区分 query head 与 KV head 维度。
- 融合 QKV/KV：显式表达每个分区，并验证切分维度之和等于融合维度。
- MLA：识别 low-rank、RoPE 和 non-RoPE 子空间，只旋转代数上兼容的分区。
- Dense gated MLP：将共享输入的 gate/up projection 分组，并连接正确的 up/down
  数据流。
- MoE：枚举 routed expert、shared expert 和 router 路径；packed tensor 必须先拆分
  为可寻址模块。
- VLM：覆盖语言残差流及进入该残差流的视觉 merger 输出，不得把视觉 encoder
  当作 decoder layer。
- MTP/辅助 decoder：覆盖所有相关层，并记录各自不同的路径前缀。
