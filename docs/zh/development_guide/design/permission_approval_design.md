# msagent Shell 权限审批设计

> 范围：本文定义无沙箱条件下的本地 Shell 执行审批。它用于降低误操作和确认疲劳，不构成操作系统级的访问控制或隔离边界。

## 1. 目标与边界

Shell 审批需要同时满足三个目标：

- 让常见的只读检查、数据分析和开发流程尽量少被打断。
- 对删除、提权、远端写入等明确高风险行为保持稳定且易懂的确认。
- 让长期授权只在当前 Project 中生效，并可以查看、撤销和跨会话恢复。

本文只覆盖权限审批，不引入文件、网络或进程沙箱。已经获准运行的 Shell、Python 或脚本仍具有宿主用户本来的权限；外部目录授权也不是文件系统隔离。

## 2. 用户可见的心智模型

用户只需要理解以下概念：

- **Manual Mode**：只读操作自动运行；运行代码或其他命令时确认。
- **Auto Mode**：正常命令和内联代码自动运行；明确危险、禁止操作和首次外部目录访问仍受保护。
- **当前项目**：当前 working directory 及其 Git worktree 根目录。
- **外部目录**：当前项目外、但命令明确访问的目录；首次访问需决定是否纳入本项目范围。
- **项目授权**：保存到当前 Project，后续新进程及恢复的 thread 继续生效，可通过 `/permissions` 撤销。

`readonly`、`ordinary`、`opaque` 等是内部分类，只用于实现、审计和 `/permissions explain`，不在常规审批面板中要求用户理解。

## 3. 快速决策表

| 情况 | Manual Mode | Auto Mode | 可持久化授权 |
| --- | --- | --- | --- |
| 可识别的只读命令 | 自动执行 | 自动执行 | 不需要 |
| 正常命令或直接脚本 | 请求确认 | 自动执行 | 精确命令或项目脚本 |
| 内联代码、命令替换、Shell 包装器 | 请求确认 | 自动执行 | 命令族 |
| 明确危险命令 | 每次确认 | 每次确认 | 不提供 |
| 禁止命令 | 直接拒绝 | 直接拒绝 | 不提供 |
| 未授权外部目录 | 先询问目录 | 先询问目录 | 目录及子目录 |

目录边界优先于命令模式：命令明确涉及未授权外部目录时，先完成目录审批；目录被拒绝后，不再显示后续命令审批。

## 4. Manual Mode

Manual 是默认的保守工作方式：

- `ls`、`du`、`head`、`tail`、`sort`、`pwd`、`git status` 等可识别且没有输出写入的只读检查自动执行。
- 运行代码、构建、测试、普通 Shell 命令需要确认。
- 明确危险命令始终需要本次确认，不能通过普通的 Always allow 规则绕过。
- 禁止命令直接拒绝。

在 Manual 的主命令审批框中，可根据命令类型提供下列选项：

| 命令形式 | 选项 |
| --- | --- |
| 普通命令 | Approve、Always allow this exact command for this project、Reject、Always reject this exact command for this project、Switch to Auto Mode |
| 直接项目脚本 | Approve、Always allow this project script、Reject、Always reject this exact command for this project、Switch to Auto Mode |
| 内联代码或命令族 | Approve、Always allow this command family for this project、Reject、Switch to Auto Mode |
| 危险命令 | Approve、Reject |

只读、危险、禁止操作及外部目录边界审批不显示 `Switch to Auto Mode`：前者无需切换，后两者即使切换也不应放宽。

## 5. Auto Mode

Auto 的目标是减少正常开发与分析工作流中的确认：

- 正常命令、直接脚本、`python -c`、heredoc、`bash -c` 和其他内联代码默认执行。
- 已授权外部目录中的正常命令也不再重复询问。
- 明确危险命令仍每次确认；禁止命令仍直接拒绝。
- 未授权外部目录仍必须先做目录审批。

Auto 不是信任代码内容的安全声明，也不是沙箱。动态代码中隐藏的行为不一定能被静态识别，因此用户选择 Auto 等同于接受正常代码执行不逐条确认。

## 6. 外部目录授权

默认项目范围包括当前 `working_dir` 和最近的 Git worktree 根目录。路径比较使用规范化后的真实父子关系，不能通过 `..`、符号链接或相似字符串前缀绕过。

以下可可靠解析的访问会触发外部目录检查：

- 文件工具的明确 `path`、`file_path`、`directory`、`root` 参数。
- `execute` 的 `cwd` / `workdir`。
- Shell 中明确的 `cd <path>`。
- Shell 参数中的绝对路径，或解析后逃出项目根的相对路径。

对动态字符串、环境变量展开、命令替换、内联代码内部路径和无法可靠解析的控制流，不承诺静态识别。

目录审批提供：

1. **Approve**：只允许当前调用访问该目录。
2. **Always allow this directory for this project**：保存该目录及所有子目录的 Project 授权。
3. **Reject**：拒绝当前调用。

目录授权仅表示该路径属于本项目可涉及的任务范围。目录获准后，命令仍按当前 mode 以及危险/禁止规则决策。

## 7. 可记忆的授权类型

规则保持少量、固定类型，不提供通用 glob、prefix 或用户自定义正则语言。

| 规则 | 匹配范围 | 典型用途 |
| --- | --- | --- |
| 精确命令 | 完整工具调用文本 | Manual 下稳定但无法归类的普通命令 |
| 命令族 | 固定动态执行形式，如 Python inline code、Shell substitution | Manual 下反复使用的内联代码 |
| 项目脚本 | 解释器 + 规范化脚本路径，忽略调用参数 | Agent 编写或反复运行的 Python / Shell 脚本 |
| 外部目录 | 规范化目录及所有子目录 | 将数据目录、工具目录纳入当前 Project |

项目脚本规则适用于可识别的直接 Python 或 Shell 脚本启动。其脚本在项目内时可直接创建规则；位于外部目录时，必须先取得该目录的 Project 授权。规则允许脚本内容在后续发生变化后仍执行，因此审批面板会明确提示这一含义。

无法可靠识别为项目脚本的命令保留精确命令或命令族授权；例如内联 `-c`、命令替换、写入重定向和复杂包装器。

## 8. 配置、持久化与恢复

权限保存在 Project 状态目录中的 `config.approval.json`。配置包含：

- `execute_approval_mode`：Project 默认的 Manual 或 Auto。
- `decision_rules`：精确命令规则。
- `family_rules`：命令族规则。
- `script_rules`：项目脚本规则。
- `external_directories`：递归外部目录授权。

模式解析优先级：

```text
本次 CLI 显式参数
    > Project 保存的 mode
    > 首次执行时询问并保存
```

Project 规则和 mode 跨新进程、`/clear`、新建 thread 与恢复 thread 生效；Allow once 只覆盖当前调用。权限不写入 thread checkpoint，因此规则被删除后，历史 thread 的下一次工具调用立即采用最新配置。

支持以下管理命令：

```text
/permissions
/permissions mode <manual|auto>
/permissions remove <rule-id>
/permissions clear-project
/permissions explain <command>
```

`/permissions explain` 只分析而不执行，可显示内部分类、匹配到的规则和最终决策。

## 9. 命令分类与实现约束

内部分类从严格到宽松如下：

```text
forbidden > dangerous > opaque > ordinary > readonly
```

- **readonly**：可识别的只读操作，且没有输出写入。
- **ordinary**：未命中更严格分类的正常命令。
- **opaque**：动态代码、命令替换或包装器导致行为无法可靠分析。
- **dangerous**：删除、提权、远端写入或明显破坏性操作。
- **forbidden**：灾难性删除或针对系统关键位置的破坏性操作。

复合命令优先采用其中最严格的风险结果。对项目脚本授权，解析器只接受受限的执行链：一个可识别的脚本启动，周围仅允许 `cd`、`time` 和不写入数据的只读后处理步骤，例如 `tail`、`head`、`sort`。链中出现写重定向、未知执行步骤、多个脚本或动态代码包装时，不创建项目脚本规则。

实现必须保持保守：无法可靠识别命令、路径或链结构时，不能扩大授权范围，应回退到常规审批或精确命令规则。
