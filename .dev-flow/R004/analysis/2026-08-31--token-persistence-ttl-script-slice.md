---
type: analysis
slice_id: S03-ttl-and-acceptance-script
round: R004
topic: token-persistence
date: 2026-08-31
---

# S03 — TTL 提升至 7 天 + 验收脚本 install -r 改造 + 端到端验收场景

## 概述

本片覆盖 SCN-AUTOLOOP-ONE-APPROVE 的最后两块：①token TTL 默认值 1h → 7 天（plugin 行为层常量）；②R003-BF008 验收脚本的清装路径改为 `adb install -r` 覆盖安装（保留 DELETE_AND_REINSTALL=1 强制清装逃生门），并设计端到端真机验收场景。

依赖关系（按边界事实，不读 S01/S02 文档）：
- **S01（app 侧 FileBackedPluginDebugAuthStore）**：token hash 记录落 `filesDir/debug_auth_tokens.json`，app 重启 / `install -r` 后可验证。本片验收用例 2/3 直接消费该能力——若 install -r 抹掉数据，验收即失败。
- **S02（python FileTokenProvider）**：`~/.debug-control-plane/tokens.json`（0600 明文，device_id 键），`get_token` 读 `expiresAt` 判定复用。本片验收用例 4/5 消费该能力；本片只负责保证 `expiresAt` 的来源（TTL）与协议语义不变。

---

## 一、交互链（用户平面）— SCN-AUTOLOOP-ONE-APPROVE 时间线

**第 1 轮（首次）**
1. 脚本：`flutter build apk --debug` → `adb install`（HyperOS 弹「USB 安装」授权，属安装弹窗，人工确认）
2. `am start` 起 app → Dart plane endpoint 起来（loopback）
3. python 新进程：`FileTokenProvider.get_token` 读 `tokens.json` → 无记录 → `POST /auth/request`（带 clientNonce）
4. app 弹授权请求（pending）→ 人点 approve（**全场景唯一一次 auth 弹窗**；验收 app 里为 driver 驱动的 approvePending）
5. python 轮询 `/auth/status` → approved → `/auth/claim` → 拿到 token + `expiresAt`（现为 7 天后）
6. 双侧落盘：app 侧存 token hash（S01）+ python 侧存明文 token/expiresAt（S02）
7. python 带 Bearer 调敏感路由 → 200

**第 N 轮（代码改动后）**
1. 脚本：build → **`adb install -r`**（不清数据，app 侧 token 文件保留；HyperOS 仍弹安装授权——安装弹窗，与本需求无关）
2. app 冷启动 → S01 store 从 filesDir 恢复 token hash 记录
3. python 重启（新进程）→ provider 读 `tokens.json` 命中（未过期）→ 直接带旧 Bearer 调用 → **200，零 auth 弹窗**

**7 天后**
1. python provider 判 `expiresAt` 已过 → 不复用，走 auth request（弹一次窗）——客户端前置拦截
2. 若绕过客户端（直接带旧 token 调用）：app 侧 `DebugAuth.validateToken` → 401 `token_expired`（PluginDebugAuth.kt:145 一带的过期拒绝路径）→ python `clear_token` → 重新走授权链

**逃生门**
- `DELETE_AND_REINSTALL=1` → 脚本执行 `adb uninstall` 清装 → filesDir 抹除 → app 侧等价首次（auth 弹窗回归一次，用于排查/演示首次流程）

---

## 二、逻辑树（系统平面）

### TTL 层（FF002）

**改动点选择：`PluginDebugAuthManager.defaultTokenTtlSeconds` 3600 → 604800**

PluginDebugAuth.kt:79 构造参数 `defaultTokenTtlSeconds: Long = 3600`，唯一消费点 L169：

```kotlin
val tokenTtlSeconds = ttlSeconds?.toLong() ?: defaultTokenTtlSeconds
```

构造点在 DebugControlPlaneFlutterPlugin.kt:60/81，均用默认值（不传该参数）。改默认值即全宿主生效。

**为什么不改 Dart 层 / app 层：**
- `approveAuthorization(requestId, {ttl, clientLabel})`（native_control_plane_bridge.dart:354-365）是显式 ttl 通道，语义是「宿主想覆盖默认」——默认值不属于它。
- example app `android_native_plane.dart:130-131` `approveAuthorization(requestId)` 不传 ttl，自动继承新默认——**确认调用链**：Dart approve（无 ttlSeconds 键）→ Kotlin `kMethodAuthApprove` handler → `approve(requestId, ttlSeconds=null, ...)` → L169 回落 `defaultTokenTtlSeconds` → 604800。无需改 app 代码。
- 默认值放 plugin 行为层，所有宿主 app 免配置受益；这是 debug 工具，7 天长时效符合「自动化循环少打扰」的产品语义。安全代价（明文 7 天）已在 brainstorm 拍板接受。

**wire 影响：** claim 响应 `expiresAt` 从 now+1h 变 now+7d。协议字段语义本来就是动态值，wire 零改动。

**fixtures 硬编码断言检查（关键检查点）：**
- `flutter_debug_control_plane/test/native_control_plane_bridge_test.dart` L542/548/555/560/576/618/658：全是 mock channel 回显固定 ISO 时间戳的解析断言，**不涉及默认 TTL 计算，无需改**。L594 `'ttlSeconds': 300` 是显式传参路径测试，不受默认值影响。
- `PluginDebugAuthManagerTest.kt`：所有用例显式传 `ttlSeconds=60`（L39/71/96/119/136/152），仅 L67 显式注入 `defaultTokenTtlSeconds = 60`——**无一依赖 3600 默认值**。需要**新增**一个用例：不传 ttlSeconds 时 expiresAt ≈ now+604800（默认值回归测试，防止未来误改回）。
- `python/tests/test_bridge_client.py` L535/555/587、`test_cross_lang_kotlin_plane.py` L182（`ttl=3600.0` 是请求侧参数）：均 mock 固定值，与默认 TTL 解耦，无需改。
- `test_acceptance_flutter_app_auth.py` L206 只断言 expiresAt 非空——天然兼容。

结论：**现有 fixtures 无需同步修改，仅需新增一个 JVM 默认值回归用例**。

### 脚本层（BF002）

**现状分析（R003-BF008 integration-android.sh）：**
- L174-178：`APK_ALREADY_INSTALLED` 快速路径——包已在设备且 APK 未变时跳过 uninstall+install，解决「每轮重跑都触发 HyperOS 安装授权弹窗」。
- 但代码改动后 APK 必变 → 快速路径不命中 → L179-181 走 `adb uninstall` → **抹掉 app 侧 debug_auth_tokens.json → token 丢失 → auth 弹窗重来**。这正是本片要修的主路径。
- L212 `install_apk()` 已经是 `adb install -r`——问题不在安装命令，在 uninstall 前置清理。

**改动方案：**
1. **删除/绕过 L179-182 的无条件 uninstall**：仅在 `DELETE_AND_REINSTALL=1` 时执行 uninstall（逃生门保留）。
2. **安装统一 `install -r`**：install -r 幂等，包在不在都能覆盖装。
3. **APK_ALREADY_INSTALLED 快速路径保留**——理由：HyperOS 对 **install -r 仍弹「USB 安装」授权**（memory 实测：每次安装必弹）。分工表述：本需求只消灭 **auth 弹窗**（靠 token 持久化），**安装弹窗**靠快速路径继续压制（APK 未变就不装）。两者是不同弹窗、不同机制，脚本注释需把这一分工写清楚，避免误解「install -r 就不弹窗」。
4. **头部注释 L12 同步改**：「可重入: 开头 uninstall 旧包容错清理」→「可重入: install -r 覆盖安装保留 app 数据（token 持久化前提）; DELETE_AND_REINSTALL=1 强制清装」。
5. 可选简化评估：既然主路径改 install -r，快速路径的语义从「避免清数据」变为「避免安装弹窗+省构建时间」——保留价值仍成立（HyperOS 现实约束），**建议保留**，但把 L177 的提示文案从「免授权弹窗」精确为「免 HyperOS 安装授权弹窗」。
6. 注意 L412-413 test-log 里的执行路径描述「uninstall 清理」也要同步。

**新验收断言（install -r 后旧 token 仍 200，依赖 S01）：**
- 脚本内做设备侧断言复杂度高（token 在 python 侧明文、app 在真机）；**推荐走 python 侧 runner**：参照 R002 acceptance runner 模式，验收脚本（或独立 test-override 脚本）串联「python 拿 token → 脚本 install -r → app 重启 → python 新进程用旧 token Bearer 调 /hello 或 /debug/secure-action → 断言 200」。设备上没有独立 curl 通道（Dart plane 是 loopback），必须由 python 侧发起。

### 端到端验收设计（BF002 验收用例清单）

参照 R002 acceptance runner（endpoint 解析双通道 + skip(setup_required) 不误报 pass + 稳定单行失败原因）+ R003 三阶段采集（deferred 双写 evidence + uiautomator dump 主证）模式：

| # | 用例 | 断言 | 依赖 |
|---|------|------|------|
| 1 | 首次授权后 token 落盘双侧 | claim 200 + expiresAt ≈ 7d；app filesDir 与 ~/.debug-control-plane/tokens.json 均存在记录 | S01+S02 |
| 2 | app 冷重启（am force-stop + am start）→ 同 token 200 | python 复用旧 token Bearer 调敏感路由 200，无新 auth request | S01，**真机** |
| 3 | install -r 覆盖安装 → 同 token 200 | build 改动后 install -r → app 重启 → 旧 token 200 | S01，**真机** |
| 4 | python 重启（新进程读 tokens.json）→ 不重新 auth | 新 python 进程 get_token 命中，不发 /auth/request | S02，可本地（pairing/adb reverse 可用时真机，否则 mock endpoint） |
| 5 | 过期 token（构造已过期记录）→ 401 → 自动重新授权 | 手工写 tokens.json 过期行 → provider 判过期走 auth 链；或旧 token 直调 → 401 token_expired → clear_token | S02 + app 过期路径，半真机 |
| 6 | DELETE_AND_REINSTALL=1 → 等价首次 | uninstall 后 app 侧无 token 记录，下次调用 401 → 重新弹授权 | **真机** |

**deferred 判定：**
- 必须真机：2、3、6（install/force-stop/弹窗均为设备行为）
- 可 JVM/单测覆盖：TTL 默认值 604800（PluginDebugAuthManagerTest 新用例）、provider 过期判定（S02 已有单测模式）、脚本路径逻辑（bash 语法 + dry 检查）
- 4/5 视 endpoint 可达性：可达走真机，不可达 skip(setup_required)——沿用 R002 契约

---

## 三、功能编号与网络定位

### FF002 — TTL 默认值提升 1h → 7 天

延续 S01 的 FF001 序列（plugin 行为层能力）。

| 项 | 内容 |
|---|------|
| 能力 | approve 无显式 ttl 时 token 有效期默认 7 天 |
| 文件落点 | `flutter_debug_control_plane/android/src/main/kotlin/com/pantas/debug/controlplane/flutter/PluginDebugAuth.kt` L79（`604800`，提常量 `DEFAULT_TOKEN_TTL_SECONDS` 更佳）+ `PluginDebugAuthManagerTest.kt` 新增默认值回归用例 |
| 验收要点 | 不传 ttlSeconds 的 approve → expiresAt = now + 604800s；显式 ttl 通道仍覆盖默认；现有显式 ttl 用例不回归 |

### BF002 — 验收脚本 install -r 改造 + 端到端验收场景

**BF vs FB 判定**：参照 R003-BF008 先例——集成分页（integration 层）验收归 BF。本项虽是测试基础设施（脚本无 UI），但其本质是**端到端集成验收**（真机安装/重启/跨进程链路），且直接改写 R003-BF008 产出的脚本，归 **BF** 序列更符合仓库惯例。整合定号 **R004-BF002**（BF001 已由 S02 FileTokenProvider 占用，本片按全局 BF 序号顺延）。

| 项 | 内容 |
|---|------|
| 能力 | ①验收脚本默认 install -r 保留数据，DELETE_AND_REINSTALL=1 保留清装逃生门；②端到端验收 runner（用例 1-6） |
| 文件落点 | `.dev-flow/R004/test-overrides/R004-BF002/integration-android.sh`（fork 或直接改 R003 脚本视 R004 基线策略）+ 验收 runner 脚本/py；若直接改 R003-BF008 脚本则 L12/L170-182/L212/L412 同步 |
| 验收要点 | 用例 3（install -r 后旧 token 200）为主断言；用例 6 逃生门；evidence 双写（deferred 时 device_required 空壳结构）沿用 R003 模式 |

---

## 四、边界接口

- **与 S01**：脚本断言「install -r 后旧 token 仍 200」完全依赖 FileBackedPluginDebugAuthStore 生效（install -r 保留 filesDir）。若 S01 实现/接线有缺陷，本片用例 3 失败——失败即正确定位到 S01 层，本片不兜底。
- **与 S02**：python 侧验收用 provider 真实读盘（不 mock tokens.json 的读取逻辑；用例 5 允许手工构造文件内容但读路径走真实 provider）。
- **wire 协议零改动确认**：`expiresAt` 本来就是动态值（claim/helloAuthState 均回显 record 值），仅数值范围变化；`ttlSeconds` 显式通道保留；无新增字段/方法。

---

## 五、结论

**实现顺序：**
1. FF002：TTL 常量 3600 → 604800 + PluginDebugAuthManagerTest 默认值回归用例（纯 JVM，先行无依赖）
2. BF002-a：脚本改造（uninstall 仅逃生门、install -r 主路径、注释同步）
3. BF002-b：端到端验收 runner + 真机回收（用例 1→3→2→4→5→6 顺序执行，deferred 双写）

**风险点：**
1. **fixtures 硬编码断言**：已排查——现有 Kotlin/Dart/python 测试均用显式 ttl 或固定 mock 时间戳，无一依赖 3600 默认值；唯一新增需求是默认值回归用例本身。风险低但排查结论必须写进 plan 防 review 重复怀疑。
2. **HyperOS 安装弹窗与 auth 弹窗的分工表述**：install -r **不**免除安装授权弹窗（实测每次安装必弹）。脚本注释、evidence、验收结论中必须明确：本需求 KPI 是「auth 弹窗只一次」，安装弹窗由 APK_ALREADY_INSTALLED 快速路径（APK 未变不装）继续压制，两者不可混淆；代码每改一轮 APK 必变，安装弹窗仍会出现——这是 HyperOS 现实约束，不视为本需求失败。
3. **expiresAt 数值漂移**：7 天跨设备时钟偏差敏感度高于 1h；python 侧判定建议留少量 clock-skew 容差（属 S02 范围，边界提示）。
4. R003 脚本是共享资产，直接改会影响 R003 复跑路径——建议 R004 内 test-override 副本先行，回收集成时再决定是否回写 R003 脚本。
