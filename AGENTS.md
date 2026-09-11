# msagent Agent Guide

This guide is for coding agents working in this repository. Keep changes small,
well-scoped, and verified. Prefer the existing implementation and documentation
patterns over introducing new abstractions, dependencies, or configuration
formats.

## Project Purpose

`msagent` (the `mindstudio-agent` package) is a Python 3.11+ CLI workbench for
Ascend NPU development, debugging, and optimization. It builds domain agents on
top of DeepAgents, LangChain, and LangGraph, and combines LLM providers, MCP
tools, Skills, configuration, session persistence, and audit capabilities.

The public command-line entry point is `msagent`, implemented by
`msagent.cli.bootstrap.app:cli`. The repository's primary users work with
Profiler, Accuracy, Quantizer, Modeling, Operator, and Minos agents. Preserve
their capability boundaries when changing code or bundled configuration.

## Repository Map

| Path | Responsibility |
| --- | --- |
| `src/msagent/cli/` | CLI bootstrap, command dispatch, prompt UI, rendering, and session state. |
| `src/msagent/agents/` | Agent graph construction, runtime context, and local context handling. |
| `src/msagent/configs/` | Pydantic configuration schemas, validation, and config registry. |
| `src/msagent/llms/` | LLM provider creation and compatibility handling. |
| `src/msagent/mcp/` | MCP client and tool integration. |
| `src/msagent/tools/` | Built-in tools, tool catalog, and tool factory. |
| `src/msagent/skills/` | Skill discovery, filtering, and installation. |
| `src/msagent/middlewares/` | Approval, retry, token-cost, and tool-result lifecycle middleware. |
| `src/msagent/audit/` | Audit events, persistence, and user-interaction records. |
| `src/msagent/core/`, `src/msagent/utils/` | Paths, storage, settings, logging, and shared utilities. |
| `resources/configs/default/` | Shipped agents, prompts, LLM/MCP/approval/checkpointer/sandbox configuration. |
| `skills/` | Source Skills packaged into the distribution. |
| `tests/ut/` | Fast unit tests, organized by runtime module. |
| `tests/skills/` | Tests for bundled Skill scripts. |
| `tests/e2e/`, `tests/install/`, `tests/whl_validator/` | End-to-end, installer, and built-wheel validation. |
| `docs/zh/` | Chinese user, agent, and developer documentation. |

Read `docs/zh/developer_guide/arch_overview.md` before changing runtime
composition, and read `docs/zh/user_guide/agent-tool-skill-filter-rules.md`
before changing agent, tool, or Skill visibility.

## Setup And Common Commands

Use `uv` for local development. Do not edit `uv.lock` manually.

```bash
uv sync --dev
uv run msagent --version

# Focused tests while iterating
uv run pytest -q tests/ut/path/to/test_file.py

# Repository unit and Skill tests
bash scripts/run_ut.sh

# Full quality hooks; run on changed files when the full run is impractical
pre-commit run --all-files

# Validate dependency metadata after changing pyproject.toml
uv lock --check

# Build a wheel; include install smoke validation for packaging/resource changes
python3 build.py local
python3 build.py local --extra VERIFY_WHEEL_INSTALL=1
```

`python3 build.py test local` runs `tests/ut` and `tests/skills`. Build output
is intentionally written to ignored `dist/` and `artifacts/` directories.

## Implementation Rules

### Python

- Target Python 3.11 or newer. Keep type annotations accurate at public and
  cross-module boundaries; run `uv run mypy src` for type-sensitive changes.
- Follow nearby code for async behavior, dependency injection, exceptions,
  logging, and configuration modeling. Do not add a new dependency without a
  concrete need and a corresponding `pyproject.toml` and lockfile update.
- Keep business logic out of CLI handlers. CLI code should dispatch and render;
  factories, configuration models, middleware, and utilities own runtime logic.
- Treat compatibility modules in `src/msagent/utils/` as narrow adaptation
  layers. Do not expand them into general-purpose abstractions.
- Prefer focused tests alongside the owning module. Add or update a regression
  test whenever behavior changes or a bug is fixed.

### Configuration, Agents, Tools, And MCP

- Default shipped configuration lives under `resources/configs/default/`. User
  overrides are runtime data, normally under `~/.msagent/`; never write user
  credentials or machine-specific paths into repository defaults.
- Keep configuration schemas in `src/msagent/configs/` synchronized with bundled
  YAML or JSON defaults. Validate both load behavior and any filtering semantics
  affected by a change.
- Agent prompt/config changes can alter tool authority. Maintain least privilege:
  expose only the tools, MCP servers, and Skills an agent requires.
- Preserve the documented pattern grammar for tools and Skills. Negative rules
  and wildcard patterns must be covered by a targeted test or smoke case.
- Treat MCP server settings as a trust boundary. Do not broaden network access,
  command execution, file access, or tool approval behavior without an explicit
  requirement and tests.

### Skills And Packaged Resources

- A built-in Skill belongs under `skills/<category>/<skill-name>/` and must have
  a `SKILL.md` with valid front matter. Use kebab-case directory names.
- Put repeatable operational logic in the Skill's `scripts/` directory and test
  it under the matching `tests/skills/` path when feasible.
- Update `skills/README.md` for user-visible Skill additions or removals.
- `hatch_build.py` and `scripts/build_whl.sh` package source Skills into
  `resources/configs/default/skills/`. Run a wheel build with
  `VERIFY_WHEEL_INSTALL=1` after changing Skills, resource paths, package data,
  or build hooks.

### Documentation

- Keep user-facing documentation in `docs/zh/` consistent with implemented CLI
  commands, agent names, configuration keys, and supported providers.
- For installation, quick-start, or onboarding changes, execute the documented
  minimal flow instead of only reviewing the prose.
- Avoid promising hardware, provider, or network behavior that cannot be
  verified from this repository.

## Safety And Data Handling

- Never commit API keys, tokens, internal endpoints, profiling captures, user
  session data, audit logs, or generated test artifacts. Use environment
  variables for credentials.
- Shell, file-system, MCP, and web-search capabilities are security-sensitive.
  Preserve approval and timeout behavior; avoid unsanitized command construction
  and path traversal.
- Maintain TLS certificate verification for HTTP clients unless a narrowly
  scoped, documented test requires otherwise.
- Do not make destructive changes to user configuration, checkpointer data, or
  workspace files as a side effect of a normal code path.

## Validation Expectations

Run the narrowest meaningful check during development, then broaden validation
in proportion to the change. Before handing off a change, report the commands
run and any deliberate gaps.

| Change area | Minimum validation |
| --- | --- |
| Python behavior | Relevant `tests/ut` test file(s). |
| Skill script | Matching `tests/skills` test(s); `bash scripts/run_ut.sh` when practical. |
| CLI behavior | Targeted handler/bootstrap tests; E2E test when public flow changes. |
| Config / agent / prompt filtering | Targeted config, factory, and catalog tests; verify actual loaded defaults. |
| Dependency changes | `uv lock --check`, relevant tests, and build. |
| Packaging / resources / installer | `python3 build.py local --extra VERIFY_WHEEL_INSTALL=1` and applicable installer or wheel-validator tests. |
| Documentation only | Check links, commands, and referenced paths; build docs when changing Sphinx configuration or directives. |

If a check cannot run because the environment lacks credentials, Ascend hardware,
or an external MCP service, run the deterministic local checks and state the
remaining limitation clearly. Do not silently weaken assertions to make a test
pass.

## Change Hygiene

- Inspect `git status --short` before editing. This repository may contain
  unrelated work-in-progress; preserve it.
- Do not use destructive Git commands or rewrite unrelated formatting.
- Keep generated outputs out of commits.
- Use conventional, focused commits. Explain user-visible or compatibility
  implications in the commit/PR description and list validation performed.
- Update documentation and tests in the same change when public behavior,
  configuration, Skill availability, or packaging behavior changes.
