# msagent Harbor 评测集成

通过 [Harbor](https://www.harborframework.com/) 框架对 msagent 做端到端评测：
Harbor 负责容器化环境与 verifier，msagent 作为 installed agent 在容器内
执行 profiling 分析并产出报告，最终导出结构化评测结果。

- 评测对象：[AscendProfileAnalysisBench](https://modelscope.cn/datasets/kali20gakki/AscendProfileAnalysisBench) 数据集
- 评测方式：Harbor 为每个 task 构建容器 → 安装待测 wheel → 运行
  `msagent --agent Profiler` → verifier 打分 → 导出结果

## 一、快速开始

```bash
# 1) 安装 Harbor（harbor 命令进入 ~/.local/bin）
uv tool install harbor==0.22

# 2) 把 adapter 安装进 Harbor 的 Python 环境（editable，改动即时生效）
uv pip install -e tests/harbor \
  --python ~/.local/share/uv/tools/harbor/bin/python \
  --no-deps

# 3) 构建评测基础镜像（网络受限时加 --debian-mirror / --pip-index-url 参数）
tests/harbor/scripts/prepare_base_image.sh

# 4) 配置 API Key，与 configs/msagent.yaml 的 model.provider 对应
export OPENAI_API_KEY='...'

# 5) 先冒烟：只构建容器 + 安装 wheel，不调模型、不跑 verifier
bash tests/harbor/scripts/run_msagent.sh \
  --config tests/harbor/configs/msagent.yaml --install-only

# 6) 跑单个 task 验证全流程，跑通后，产物在 `harbor-output/eval-<时间戳>/`
bash tests/harbor/scripts/run_msagent.sh \
  --config tests/harbor/configs/msagent.yaml --task '0001-*'
```

## 二、环境准备

### 1. 安装 Harbor

```bash
uv tool install harbor==0.22
```

安装后 `harbor` 位于 `~/.local/bin`（已在 PATH 上），直接使用即可。

### 2. 安装 adapter 到 Harbor 的 venv

```bash
uv pip install -e tests/harbor \
  --python ~/.local/share/uv/tools/harbor/bin/python \
  --no-deps
```

可编辑安装：`tests/harbor/msagent_harbor/` 下的改动立即生效，无需重新安装。
安装后 Harbor 可直接 `import msagent_harbor`。

### 3. 构建评测基础镜像

```bash
tests/harbor/scripts/prepare_base_image.sh
```

网络受限时用镜像源（构建参数全部可覆盖）：

```bash
tests/harbor/scripts/prepare_base_image.sh \
  --debian-mirror https://repo.huaweicloud.com \
  --pip-index-url https://repo.huaweicloud.com/repository/pypi/simple \
  --trusted-host repo.huaweicloud.com
```

脚本构建后续评测使用的镜像 `ascend-profiling-eval` 并自动校验所需的三方库已安装。

> 镜像**不预装** msagent 或其依赖：每次评测 wheel 被安装到全新容器，
> 保证干净可复现。

### 4. 准备评测数据集

评测使用 [AscendProfileAnalysisBench](https://modelscope.cn/datasets/kali20gakki/AscendProfileAnalysisBench)
数据集（Ascend NPU profiling 性能分析评测集，45 个 task）。准备步骤：

1. 从 ModelScope 下载数据集到本地（例如 `AscendProfileAnalysisBench/`）；
2. 确认目录结构：每个 task 位于 `tasks/<task-id>/`，含 `task.toml`、
   `instruction.md` 与 `environment/input_data/`（Harbor 会把
   `environment/` 上传为容器内 `/input_data`）；
3. 把 `configs/msagent.yaml` 的 `dataset.path` 改成你环境中的**实际路径**
   （当前为占位符 `/path/to/AscendProfileAnalysisBench`）。

## 三、配置 LLM 与 API Key

LLM 配置都在 `configs/msagent.yaml` 的 `model` 段：

```yaml
model:
  provider: openai            # openai | anthropic | google
  name: deepseek-v4-flash     # 模型名
  base_url: https://api.deepseek.com/v1   # null = 用 provider 默认地址
```

### API Key 环境变量

API key **只通过宿主环境变量注入**，不写入配置文件、不通过 Harbor
`--ae` 传递，也不会出现在导出的 manifest 中。按 `model.provider` 设置
对应变量：

| `model.provider` | 环境变量              |
| ----------------- | --------------------- |
| `openai`         | `OPENAI_API_KEY`    |
| `anthropic`      | `ANTHROPIC_API_KEY` |
| `google`         | `GOOGLE_API_KEY`    |

### 使用 OpenAI 兼容网关

`model.base_url` 指向任意 OpenAI 兼容端点即可，例如内部网关：

```yaml
model:
  provider: openai
  name: deepseek-v4-flash
  base_url: https://your-gateway.example.com/v1
```

```bash
export OPENAI_API_KEY='...'   # 网关下发的 key
bash tests/harbor/scripts/run_msagent.sh \
  --config tests/harbor/configs/msagent.yaml --task '0001-*'
```

## 四、运行配置（configs/msagent.yaml）

所有运行参数集中在此文件。完整示例：

```yaml
dataset:
  path: /path/to/AscendProfileAnalysisBench   # ⚠️ 改成当前环境的实际数据集路径（见「二.4」）
  task_filter: null                             # glob 过滤；null/空 = 全量

agent:
  wheel: ../../../dist/mindstudio_agent-*.whl  # 支持 glob，取最新匹配
  python_bin: python3.11                        # 容器内 Python 可执行文件
  import: msagent_harbor.agent:MsagentHarborAgent

model:
  provider: openai                              # openai | anthropic | google
  name: deepseek-v4-flash
  base_url: https://api.deepseek.com/v1         # null = 用 provider 默认地址

environment:
  image: ascend-profiling-eval                  # Docker 镜像标签
  pip:                                          # 全部可选
    index_url: null
    extra_index_url: null
    trusted_host: null

output:
  dir: ../harbor-output                         # 导出目录（父目录）
  run_id: null                                  # null = 自动: eval-<时间戳>

harbor:
  bin: harbor                                   # 默认从 PATH 查找
  n_attempts: 1                                 # 每个 task 尝试次数（须为 1，导出布局要求）
  install_only: false                           # true = 只装 wheel 不跑 agent
  extra_args: []                                # 透传给 harbor run 的额外参数
```

### 字段说明

| 字段 | 说明 |
| --- | --- |
| `dataset.path` | 数据集根目录；**运行前必须改成当前环境的实际路径**（默认为占位符）；若直接指向 `tasks/` 目录也可 |
| `dataset.task_filter` | glob 过滤要跑的 task，如 `'0001-*'`；null/空 = 全部 45 个 |
| `agent.wheel` | 待测 wheel，支持 glob，取最新匹配；构建见 `python3 build.py local` |
| `agent.python_bin` | 容器内安装/运行 wheel 用的 Python 可执行文件 |
| `agent.import` | Harbor agent 导入路径（`模块:类`），一般不用改 |
| `model.provider/name/base_url` | 见「三、配置 LLM 与 API Key」 |
| `environment.image` | 评测容器镜像标签（先跑 `prepare_base_image.sh`） |
| `environment.pip.*` | 容器内 pip 镜像，全部可选，null = 默认源 |
| `output.dir` | 导出结果父目录（子目录为 run_id） |
| `output.run_id` | null = 自动 `eval-<时间戳>` |
| `harbor.bin` | harbor 可执行文件，默认 PATH 上的 `harbor` |
| `harbor.n_attempts` | 每个 task 尝试次数（导出布局要求为 1） |
| `harbor.install_only` | true = 只装 wheel 不跑 agent（等同 `--install-only`） |
| `harbor.extra_args` | 额外透传给 `harbor run` 的原始参数 |

### 相对路径规则

配置中的相对路径（`wheel`、`dataset.path`、`output.dir`）按**配置文件
所在目录**（`configs/`）解析；用 `--output-dir` 覆盖时按当前工作目录
解析。

### 常见修改场景

| 想做什么 | 改哪里 |
| --- | --- |
| 准备/更换数据集 | `dataset.path` 指向实际数据集路径（见「二.4 准备评测数据集」） |
| 只跑某几个 task | `dataset.task_filter: '0001-*'`（或命令行 `--task`） |
| 换待测版本 | `agent.wheel` 指向新 wheel（glob 自动取最新） |
| 换模型/网关 | `model.provider` + `model.name` + `model.base_url`，并设对应 API key |
| 换输出位置 | `output.dir`（或命令行 `--output-dir`） |
| 容器内 pip 走镜像 | `environment.pip.index_url` / `trusted_host` |
| 调并发 | `harbor.extra_args` 加 `--n-concurrent` / `--n-concurrent-agents` |

## 五、运行评测

```bash
# 冒烟：只构建容器 + 安装 wheel，不调模型、不跑 verifier（推荐先做）
bash tests/harbor/scripts/run_msagent.sh \
  --config tests/harbor/configs/msagent.yaml --install-only

# 单 task 验证全流程
bash tests/harbor/scripts/run_msagent.sh \
  --config tests/harbor/configs/msagent.yaml --task '0001-*'

# 全量 45 个 task（约 57M prompt tokens，注意用量）
bash tests/harbor/scripts/run_msagent.sh \
  --config tests/harbor/configs/msagent.yaml
```

### 命令行覆盖

| 参数                  | 说明                                        |
| --------------------- | ------------------------------------------- |
| `--config FILE`     | YAML 配置文件路径（必填）                   |
| `--task PATTERN`    | 覆盖 `dataset.task_filter`（传空串 `--task ""` 表示全量） |
| `--output-dir PATH` | 覆盖 `output.dir`                           |
| `--install-only`    | 只构建容器 + 安装 wheel，跳过 agent/verifier |

## 六、运行流程与评测产物

### 流程

`run_msagent.sh` 执行步骤：

1. **解析 YAML 配置** — 用 Python 读取配置并导出 shell 变量
2. **校验前置条件** — dataset 目录、wheel 文件、Docker 镜像、容器内
   Python >= 3.11、API key
3. **创建临时工作目录** — Harbor job 目录在 `/tmp`，结束后自动清理
4. **执行 `harbor run`** — 传入 dataset、agent import、wheel、python、
   模型配置、task 过滤等
5. **容器内执行** — 构建容器 → 上传 wheel → pip 安装 → 运行
   `msagent --agent Profiler` → 分析 profiling 数据 → 写
   `/workspace/report.json` → Harbor verifier 评分
6. **导出结果** — `export_results.py` 把 job 目录转为紧凑布局，写入
   `output.dir`

`--install-only` 只执行到第 5 步的容器构建 + wheel 安装，不调模型、不跑
verifier、不导出。

### 产物

```
harbor-output/<run-id>/
├── README.md                   # 人类可读的运行索引
├── manifest.json               # 可复现性标识（版本、SHA256、镜像 digest）
├── summary.json                # 任务状态、reward、耗时
└── tasks/<task-id>/
    ├── msagent.events.jsonl    # msagent CLI 原始事件流
    ├── trajectory.json         # ATIF 格式轨迹（Harbor 标准）
    ├── report.json             # msagent 提交的最终分析报告
    └── verifier.json           # verifier 评分结果和明细
```

- `manifest.json`：Harbor 版本、adapter 代码 SHA256、wheel SHA256、Docker
  镜像 digest、数据集 git commit、模型配置（**不含** API key 值）
- `summary.json`：每个 task 的状态（completed/errored）、reward、时间统计
- `verifier.json`：每个检查项的 expected/reported/pass 明细
- msagent 安装失败、LLM 配置错误、trace 缺失、CLI 非零退出等均视为
  **基础设施失败**，不会作为低分 agent 响应提交给 verifier
