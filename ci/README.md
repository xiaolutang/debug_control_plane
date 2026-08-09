# CI — repo 级零业务依赖门

> 守护 `debug_control_plane` repo 的硬约束:**repo 级零业务依赖**。

## 这个门守什么

`debug_control_plane` 是从一个内部 Flutter 应用抽出的横向基础设施 repo(debug HTTP 协议 + MCP 工具表面 + 设备发现)。它的核心契约是**零业务知识**:只允许依赖标准库 + 声明依赖(pyproject/pubspec)+ 自身,绝不 import 任何业务包,也不在 dart lib / python 包里出现业务类名。

业务装配(注册业务 semantic provider、绑业务工具)留在业务侧应用,control_plane 只暴露**通用 hook**(SemanticProvider 协议、tool_handlers 注入参数)。一旦有人不小心把业务知识写回 control_plane,本门立即 FAIL。

## 三件套

| 套件 | 命令 | 守什么 | 实现 |
|------|------|--------|------|
| **[1/3] dart analyze** | `fvm flutter analyze --no-fatal-infos` | dart package 静态正确性;pubspec 仅依赖 flutter sdk,故 dart 包天然零外部业务依赖 | `fvm`(系统 Flutter 是 OHOS 分支不可用) |
| **[2/3] python 依赖白名单** | python AST | 只允许标准库 + 声明依赖 + 自身 | AST 精确抓 import 语句(注释/docstring/字符串字面量不命中) |
| **[3/3] python ruff** | `ruff check --select E9,F401,F811` | python 致命级(语法错/未用 import/重复定义) | 只守致命级,格式类归后续收尾 task |

### 为什么 [2/3] python 用 AST 而不是 grep

control_plane 的源码里有大量**反向证明注释**,例如:

```python
# 零业务依赖: 不 import 任何业务包(业务留在应用侧).
```

```python
logger = logging.getLogger("debug_control_plane.mcp_plane.server")  # 字符串字面量,不是 import
```

纯 grep 命中业务串会**误报 CI FAIL**。AST 只解析真实 `import` / `from ... import` 语句,注释、docstring、字符串字面量一律不命中;白名单只放行标准库 + pyproject 声明依赖 + `debug_control_plane` 自身。

### 为什么 [3/3] ruff 只守致命级

迁移初期 python 子包可能留少量格式 errors(I001 未排序 import / F541 f-string 无占位符 / UP037 单引号),归后续收尾 task 清。本门只守**会让 Python 启动失败或语义错乱**的致命级:

- `E9` — 语法错(`SyntaxError` / `IndentationError`)
- `F401` — 未使用 import(死代码,常意味着 import 错或重构未完)
- `F811` — 重复定义(同名函数/类被重定义)

格式类回归由后续 ruff 全量门守。

## 本地跑

```bash
bash ci/zero-business-dep-check.sh
```

退出码 `0` = PASS(三件套全过),非 `0` = FAIL。

环境要求:

- `fvm`(Flutter Version Manager)— dart analyze 用
- `/usr/local/bin/python3.13` — AST + ruff 用(可用 `PYTHON_BIN=...` 覆盖)

## CI 接入

### GitHub Actions

```yaml
# .github/workflows/zero-business-dep.yml
name: zero-business-dep

on:
  push:
    branches: [main]
  pull_request:

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - uses: actions/setup-python@v5
        with:
          python-version: "3.13"
      - name: Install ruff
        run: pip install ruff
      - name: Run zero-business-dep gate
        run: bash ci/zero-business-dep-check.sh
```

> 注:GitHub-hosted runner 没有 fvm,上面用 `subosito/flutter-action` 装 Flutter,然后脚本里 `fvm flutter` 需改成 `flutter`(或脚本检测 fvm 缺失时回退到 PATH 里的 flutter)。本地 macOS 开发仍须用 fvm。

### Git pre-commit hook

```bash
# .git/hooks/pre-commit (chmod +x)
#!/usr/bin/env bash
# 提交前跑零业务依赖门
bash ci/zero-business-dep-check.sh
```

或用 `pre-commit` 框架(`.pre-commit-config.yaml`):

```yaml
repos:
  - repo: local
    hooks:
      - id: zero-business-dep
        name: zero-business-dep gate
        entry: bash ci/zero-business-dep-check.sh
        language: system
        pass_filenames: false
        files: \.(dart|py|yaml|toml)$
```

## 允许清单(白名单)

[2/3] python AST 的允许清单:

- **Python 标准库**(`sys.stdlib_module_names`)
- **pyproject 声明依赖**(`[project].dependencies`,当前 `mcp`、`httpx`、`anyio`——改这份清单须同步脚本里的 `declared`)
- **`debug_control_plane` 自身**

任何不在此清单的 import 即 FAIL。新增依赖须同时改 pyproject + 脚本 `declared`。

dart 侧由 [1/3] analyze 保证(pubspec 声明 + 类型检查)。

## 故障排查

| 症状 | 原因 | 处理 |
|------|------|------|
| `[1/3]` FAIL `fvm: command not found` | fvm 未装 | `brew install fvm`(系统 Flutter 是 OHOS 分支,不可用) |
| `[2/3] python 白名单` FAIL | import 了非标准库/非声明依赖的业务或第三方包 | 看脚本输出指出的文件 + import 语句,把业务知识移回业务侧应用;若确实需要新依赖,同步加进 pyproject + 脚本 `declared` |
| `[3/3] ruff` FAIL E9/F401/F811 | python 致命错(语法/死 import/重复定义) | 修代码;格式类 I001/F541/UP037 不在本门范围 |
