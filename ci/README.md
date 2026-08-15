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

---

# R025 扩展:CI 全量守卫(BF004-3)

R025 起 repo 含 Kotlin 核心 + Flutter 插件 + 跨语言 fixtures,CI 从「零业务依赖三件套」扩展为
**7 步全量门**,统一入口 `ci/ci-check-all.sh`(本地与 GitHub Actions 共用):

| 步 | 套件 | 守什么 | 实现 |
|----|------|--------|------|
| 1 | kotlin build+test | root aggregator `./gradlew build`(76+ JVM 测试:路由/SSE 字节契约/事件总线/golden fixture) | gradle wrapper 8.14 + JDK17 |
| 2 | dart test | `dart/` 黄金 fixture 断言(72+ 测试,`$$unstable` 归一化) | fvm stable |
| 3 | flutter plugin test | `flutter_debug_control_plane/` Dart 桥接(26+ 测试;插件 android 23 测试归消费侧 gradle) | fvm stable |
| 4 | python pytest | `python/tests/`(317+ 测试,含 BF003-2 真实起 JVM 的跨语言交叉验证) | python3.13 + pytest |
| 5 | zero-business-dep-check | 上述三件套(dart analyze / python AST / ruff) | 同 R021 |
| 6 | protocol-version-guard | `protocolVersion=1` 四点同值(kotlin const / dart const / hello.json / discovery-python.json) | grep + python json |
| 7 | gradle-publish-check | JitPack 发版前置 4 条:maven-publish 显式启用 + publication 声明 + nanohttpd 坐标 + 根聚合器/wrapper | grep 静态扫描 |

## 本地跑(全量门)

```bash
bash ci/ci-check-all.sh
```

## protocolVersion 守卫(步骤 6)

`protocolVersion=1` 是跨语言硬常量(PROTOCOL.md §6),**独立于各包版本线**(dart 0.1.x /
python 0.1.x / kotlin 0.2.0)。协议未变就不 bump;任何一端单方面改值 → drift FAIL。
python 端无独立常量(按字段解析,值由服务端决定),运行时断言在 BF003-2
`test_cross_lang_kotlin_plane.py::test_hello_protocol_version_and_endpoint`。

## gradle 发布守卫(步骤 7,spike-b §1.4 硬约束)

JitPack 线上构建跑 `./gradlew build publishToMavenLocal`;子模块 `kotlin/build.gradle.kts`
若未**显式启用 maven-publish plugin + 声明 publication**,publishToMavenLocal task 不存在 →
线上发布失败。本门静态断言该前置条件(秒级,零 JDK)。**R025-C 决策:本次不打 tag 不发版,
仅备好通道**;发版动作(future task)见 `.dev-flow/R025/design/spike-b-jitpack.md` §5 清单。

## CI 接入

### GitHub Actions

R025 起仓库带正式 workflow:`.github/workflows/ci.yml`(7 步全量门,入口 `ci/ci-check-all.sh`)。
runner 环境差异已处理:无 fvm → workflow 注入 fvm→flutter 转发 shim;无
`/usr/local/bin/python3.13` → workflow 给门禁步注入 `PYTHON_BIN=python3.13`
(setup-python 把 3.13 放 PATH)。脚本本体不改。

```yaml
# .github/workflows/ci.yml 概要(以仓库文件为准)
- uses: actions/setup-java@v4     # JDK 17(kotlin jvmToolchain)
- uses: subosito/flutter-action@v2 # stable(替代本地 fvm)
- uses: actions/setup-python@v5   # 3.13
- run: pip install -e "./python[test]"
- run: bash ci/ci-check-all.sh    # 7 步全量门(env: PYTHON_BIN=python3.13)
```

> 注:GitHub-hosted runner 没有 fvm,workflow 在 `$HOME/.local/bin/fvm` 注入 shim 转发到
> PATH 的 flutter;runner 也没有 `/usr/local/bin/python3.13`(本地默认路径),门禁步注入
> `PYTHON_BIN=python3.13`。`ci/zero-business-dep-check.sh` / `ci/ci-check-all.sh` /
> `ci/protocol-version-guard.sh` 共用同一 `PYTHON_BIN` 覆盖约定,本体不改。
> 本地 macOS 开发仍须用真 fvm stable(系统 Flutter 是 OHOS 分支,不可用)。

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
