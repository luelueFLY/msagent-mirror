# 安装脚本测试（tests/install）

本目录守护 `scripts/install.sh` 与 `scripts/install.ps1` 的功能正确性，共三层：

| 文件 | 作用 | 速度 |
| --- | --- | --- |
| `test_install_sh.sh` | install.sh 逻辑测试（mock uv）：静态检查、版本号提前打印、源优先级/`MSAGENT_INDEX` 透传、PyPI 回退重试、`MSAGENT_NO_MODIFY_PATH`、失败提示 | 秒级（仅网络探测） |
| `test_install_ps1.ps1` | install.ps1 等价逻辑测试（mock uv） | 秒级 |
| `smoke_install.sh` | 真实安装冒烟：在一次性 HOME 里完整安装并验证 `msagent --version` 与 msprof-mcp | 分钟级（下载全部依赖） |

`fake_uv.sh` / `fake_uv.ps1` 是 mock uv（PS 版跨平台，Windows PowerShell 与 pwsh 通用）：记录每次调用参数，并按场景控制退出码（
`MSAGENT_TEST_UV_FAIL`、`MSAGENT_TEST_UV_FAIL_PYPI_ONLY`），测试不执行真实安装、
不写真实用户目录。

## 本地运行

```shell
# Linux / macOS / WSL（依赖 bash、curl；shellcheck 可选）
bash tests/install/test_install_sh.sh

# 任意平台（Windows PowerShell / Linux 的 pwsh）
powershell -NoProfile -ExecutionPolicy Bypass -File tests/install/test_install_ps1.ps1
# 或
pwsh -NoProfile -File tests/install/test_install_ps1.ps1

# 真实安装冒烟（可选，较慢）
bash tests/install/smoke_install.sh
```

退出码 0 表示全部通过；输出末尾有 `passed=N failed=M skipped=K` 汇总。

## UT 集成

两套逻辑测试已接入现有 UT（PR CI 每次都会跑 `uv run pytest`）：

- 入口：`tests/ut/install/test_installer.py`；
- `test_install_sh_logic_suite`：POSIX 平台运行（install.sh 拒绝 MSYS/MinGW 壳）；
- `test_install_ps1_logic_suite`：任意平台运行——Linux CI 用 `pwsh`（PowerShell Core），Windows 用 `powershell`；runner 无 PowerShell 时自动 SKIP；
- 失败时 pytest 会输出套件日志；
- 冒烟测试**不**进 UT（全量安装较慢），按需手动执行或放到定时 CI。

说明：

- 含 PyPI 回退重试的用例依赖 `mirrors.huaweicloud.com` 可达；不可达时自动 SKIP（不判失败）。
- 逻辑测试在隔离 HOME + mock uv 下运行，不执行真实安装、不修改真实用户目录。
