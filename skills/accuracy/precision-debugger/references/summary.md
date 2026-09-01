# 精度问题汇总

记录既往精度问题，供SKILL参考。

| ID | 问题场景 | 问题现象 | 问题根因 | 必要触发条件 |
|----|----------------------|----------------------|----------------------|----------------------|
| KB-001 | 推理，vLLM-Ascend | 持续输出'\n' | xgrammary对JSON格式的要求与模型对输出内容完整性的要求产生了冲突 | 发动请求时要求格式化输出 |
| KB-002 | 推理，vLLM-Ascend | 同一请求的第一次回复与第二次回复的差异大，但从第二次开始每次回复相同 | 从第二次请求开始命中了Prefix Cache，计算KV时，本应从KV Cache中读取公共前缀的KV值，但实际却未读取 | enable-prefix-caching |
| KB-003 | 推理，vLLM-Ascend | 指令不遵循 | FlashCommon与DSA_CP特性同时使能 | FlashCommon与DSA_CP特性同时使能 |
| KB-004 | 推理，vLLM-Ascend | 使用量化权重时，短序列输出便复读；使用浮点权重，输出正常 | 量化权重遗漏了bias参数 | 量化权重 |
| KB-005 | 推理，vLLM-Ascend | Qwen3.5模型，描述图片时输出乱码 | npu_causal_conv1d_custom算子存在精度问题 | npu_causal_conv1d_custom算子 |
| KB-006 | 推理，vLLM-Ascend | 短序列输出便出现乱码或复读 | moe_token_unpermuted的sorted_indices参数传入前进行了取绝对值处理，导致无效专家被标记为有效专家 | MOE模型、token_compile时没有过滤无效专家 |
| KB-007 | 推理，vLLM-Ascend | DeepSeek-V4-Pro模型，输出空 | _C_ascend.compressor算子内存越界 | _C_ascend.compressor算子 |
| KB-008 | 推理，vLLM-Ascend | DeepSeek-V4-Flash模型，长序列输出中后段开始复读 | npu_scatter_nd_update_v2算子线性地址精度丢失 | 长序列，npu_scatter_nd_update_v2算子 |
| KB-009 | 推理，vLLM-Ascend | Qwen3.5模型，多并发，部分case出现空回复和乱码输出 | KV Cache打满时，触发了重计算，使得所有DP上的处理token数都变成了Prompt长度，token总数超出FusedMC2算子（_C_ascend.dispatch_ffn_combine）可处理上限， 导致部分token被丢弃| KV Cache使用率高、MoECommType为FUSED_MC2、使用了_C_ascend.dispatch_ffn_combine算子 |
| KB-010 | 推理，vLLM-Ascend | 开启图模式后，精度评测得分下降，但bad cases语义通顺 | 图模式下自动使能了fuse_qknorm_rope pass融合优化，使用了有精度问题的split_qkv_rmsnorm_rope_kernel Triton算子 | split_qkv_rmsnorm_rope_kernel Triton算子 |
| KB-011 | 推理，vLLM-Ascend | GLM-5.1模型，首token起乱码("!") | quant_sparse_flash_attention算子不支持mxFP8的KV值 | quant_sparse_flash_attention算子、mxFP8数据类型的KV |
| KB-012 | 推理，vLLM-Ascend | 多并发，某条请求的回复输出中包含其它请求的内容 | bad case的Prompt被污染，写入了其它请求的Prompt | PP并行、Chunked Prefill、异步调度 |
| KB-013 | 推理，vLLM-Ascend | PD分离，首token起乱码，但不是"!" | P节点使用了基于QuaRot算法生成的量化权重，生成的V Cache与D节点的V Cache相似度低 | PD分离、权重不同、QuaRot算法 |
| KB-014 | 推理，vLLM-Ascend | 量化权重，TP8输出正常，TP16第2个token起输出乱码 | npu_dequant_swiglu_quant算子在小shape下的tiling有bug | npu_dequant_swiglu_quant算子 |
| KB-015 | 推理，vLLM-Ascend | PD分离时文本数据集评测得分较低，部分bad cases复读，PD混部得分正常 | PD节点TP不对等时D节点需要在拉取完所有卡上的KV Cache后做一次重排，因为各卡通过多线程同时拉取，所以问题版本上“最后一张卡拉取完后开始重排”的逻辑不能保证所有KV Cache拉取完成 | PD分离、TP不对等 |
| KB-016 | 推理，vLLM-Ascend | 长输出、大并发场景下，部分请求输出乱码 | 多DP时，空闲DP组运行_dummy_run过程中，直接复用了上一次forward的slot值，导致_dummy_run产生的无意义KV Cache被写入到了分配给正常请求的KV Cache slot中 | 多DP、图模式、KV Cache使用率高 |
| KB-017 | 推理，vLLM-Ascend | 输出中出现与Prompt无关内容 | vllm-ascend的NPUModelRunner覆盖_prepare_inputs()时遗漏写回 self.discard_request_mask,导致PP模式下chunked prefill的broadcast错误发送过早采样token,污染下一个chunk的最后一个输入tokken,使第一个输出token损坏 | PP并行、Chunked Prefill、异步调度 |
