# 标准测评提示词

以下内容是提供给中文用户的提示词示例。尖括号中的占位符必须替换为真实值。提示词中出现“执行测评”“运行测评”等表达，表示用户的最终目标是实际启动 AISBench，而不只是展示命令；执行者仍应先自行核查可查明的事实，集中询问未明确的关键决定，展示最终配置，并在用户确认后启动测评。

## 通用模板

```text
使用 AISBench 对 <模型或服务> 执行 <基准列表> 精度测评。
模型任务：<AISBench --models 任务名>。
服务地址：<host_ip>:<host_port>；服务端模型名：<model_name>。
范围：<全量或前 N 条>；输出目录：<work_dir>。
其他参数：<可选的 max_out_len、batch_size、generation_kwargs 等>。
请先核查环境并集中询问尚未明确的关键配置，每个问题给出建议答案；形成最终配置和脱敏后的 AISBench CLI 后请我确认，确认后执行到结束，然后返回各数据集指标和结果文件路径。
```

只需提供本次测评涉及的字段。如果模型任务已经配置完成，不必在每次提示词中重复服务地址等信息。

## AIME 2025

```text
使用 AISBench 对 AIME 2025 执行全量精度测评。推理后端使用 vllm_api_general_chat，服务地址为 127.0.0.1:8000，服务端模型名为 <model_name>，max_out_len 为 8192，batch_size 为 8。请核查配置，集中询问仍缺失的关键细节并给出建议答案；展示脱敏后的最终命令供我确认，确认后执行到结束，并返回 accuracy、汇总文件和预测文件路径。
```

核心参数应映射为：

```text
--models vllm_api_general_chat --datasets aime2025_gen_0_shot_chat_prompt --mode all
```

## AIME 2026

```text
运行 AISBench 的 AIME-2026 测评。使用模型任务 vllm_api_general_chat，推理服务是 127.0.0.1:8000，模型名为 <model_name>；先测前 10 条，输出到 <work_dir>。请先确认关键细节和最终命令，得到我的确认后执行，并给出 accuracy 和实际产物路径。
```

核心参数应映射为：

```text
--models vllm_api_general_chat --datasets aime2026_gen_0_shot_chat_prompt --mode all --num-prompts 10
```

## GPQA Diamond

```text
请使用 AISBench 对 GPQA Diamond 做全量精度测评。后端为 vllm_api_general_chat，host_ip=<host_ip>，host_port=<host_port>，model_name=<model_name>，batch_size=4。请先集中询问未明确的关键配置并给出建议，展示最终命令供我确认；确认后运行并等待完成，返回 GPQA_Diamond 的 accuracy/pass@1、summary、results 和 logs 路径。
```

核心参数应映射为：

```text
--models vllm_api_general_chat --datasets gpqa_gen_0_shot_cot_chat_prompt --mode all
```

## 三个验收基准组合测评

```text
使用 AISBench 在同一个 vLLM Chat 服务上依次评测 AIME2025、AIME2026 和 GPQA Diamond。模型任务为 vllm_api_general_chat，服务地址 <host_ip>:<host_port>，模型名 <model_name>，每个数据集先跑 5 条，输出到 <work_dir>。请先核查环境，分轮确认存在依赖关系的关键配置，展示最终方案供我确认；确认后执行完整测评并分别汇报三个数据集的指标与产物路径。
```

数据集参数应映射为：

```text
--datasets aime2025_gen_0_shot_chat_prompt aime2026_gen_0_shot_chat_prompt gpqa_gen_0_shot_cot_chat_prompt --num-prompts 5
```

## MMLU

```text
使用 AISBench 和已配置的 vllm_api_general_chat 模型任务执行 MMLU 5-shot 全量精度测评。请自动解析数据集任务，确认关键细节和最终命令，得到我的确认后运行到结束并返回汇总指标和产物路径。
```

数据集参数应映射为 `mmlu_gen_5_shot_chat_prompt`。

## GSM8K

```text
使用 AISBench 在 127.0.0.1:8000 的 vLLM Chat 服务上运行 GSM8K 4-shot CoT 精度测评，模型名为 <model_name>。只跑前 20 条；请先展示最终配置和脱敏命令供我确认，确认后执行并返回 accuracy 和结果目录。
```

数据集参数应映射为 `gsm8k_gen_4_shot_cot_chat_prompt`。

## HumanEval

```text
使用 AISBench 的 vllm_api_general 模型任务运行 HumanEval 0-shot 全量测评。使用当前已配置的服务参数；请自行核查配置，集中询问不能查明的关键细节，展示最终命令供我确认，确认后执行并返回 pass@1、summary 和 predictions 路径。
```

数据集参数应映射为 `humaneval_gen_0_shot`。该任务使用字符串提示词，因此不能把用户指定的字符串模型任务静默替换成对话模型默认值。
