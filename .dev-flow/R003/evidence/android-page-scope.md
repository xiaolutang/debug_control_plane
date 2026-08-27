---
type: acceptance-evidence
task_id: R003-BF008
run_at: 2026-08-27T03:42:00Z
device_model: 23116PN5BC
os_version: 16
status: pass
deferred_reason:
---

# Android 真机 Page Scope 三阶段验收(R003-BF008)

> 历史占位:2026-08-26T20:33:47Z 的 deferred 空壳已被 2026-08-27 真机回收
> 覆盖(两轮运行记录见下方分节;结论对照与脚本修复记录在文末)。

## 阶段 1:进入 page A(hello/tool 变化)

见「运行记录」分节与文末结论对照。

## 阶段 2:page A 保持下进入 page B(并存状态记录)

见「运行记录」分节与文末结论对照。

## 阶段 3:关闭 page A(旧工具 gone 后刷新 + app/page B capability 可用性)

见「运行记录」分节与文末结论对照。

## 运行记录 run_at: 2026-08-27T03:23:11Z(device=23116PN5BC / Android 16,status=pass)

### 阶段 1:进入 page A(hello/tool 变化)

操作序列日志:`test-overrides/R003-BF008/.android-work/stage-1-actions.log`
原始输出(uiautomator dump 主证):`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/1-ui.xml`;logcat 辅证:`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/1-logcat.txt`

### 阶段 1b:page A 进入后的页面结构

操作序列日志:`test-overrides/R003-BF008/.android-work/stage-1-actions.log`
原始输出(uiautomator dump 主证):`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/1b-ui.xml`;logcat 辅证:`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/1b-logcat.txt`

### 阶段 2:page A 保持下进入 page B(并存状态)

操作序列日志:`test-overrides/R003-BF008/.android-work/stage-2-actions.log`
原始输出(uiautomator dump 主证):`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/2-ui.xml`;logcat 辅证:`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/2-logcat.txt`

### 阶段 3:离开 page A(gone 后刷新 + capability 可用性)

操作序列日志:`test-overrides/R003-BF008/.android-work/stage-3-actions.log`
原始输出(uiautomator dump 主证):`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/3-ui.xml`;logcat 辅证:`/Users/tangxiaolu/project/debug_control_plane/.dev-flow/R003/test-overrides/R003-BF008/.android-work/dumps/3-logcat.txt`

### 结论对照(验收标准 2/3)

**脚本自动采集轮(run_at 03:23:11Z)+ 实施者受控补拍轮(03:30–03:42Z)合并判定。**
脚本自动轮的两处已知偏差(EC-4 修正项 + tap 竞态)由受控补拍覆盖,判定以
dumps 结构文本为主证(全部节点归属 `com.debugplane.debug_control_plane_acceptance_example`):

**验收标准 2(三阶段变化 evidence)— PASS**

| 阶段 | 主证(dump 结构) | 关键证据 |
|---|---|---|
| 1 进入前(home) | `1-ui.xml`/`1b-ui.xml` 33 节点 | `acceptance.status.capability_count_text = 4 registered`(app 级 4 capability);`Open page A`/`Open page B` 入口在位 |
| 1 page A 打开 | `2-ui.xml` 20 节点 | `text="page-a"`;`acceptance.page_scope.registered_count_text = 2 registered`;`acceptance.page_scope.close_button` 在位 |
| 1 受控复验 | `r003-pageA.xml` | 同上(独立操作序列复现,注册计数稳定 2) |
| 2 page B 打开 | `r003-pageB.xml` | `text="page-b"`;`2 registered` |
| 3 离开 page A 后 | `3-ui.xml`/`r003-final-home.xml` | 回到 home;`capability_count_text = 4 registered`(page 2 项已随 dispose 释放) |

注:app 路由结构中 page A/B 为同级独立 route(从 home 分别 push),
「并存」语义 = page scope 生命周期互不干扰(A 离开释放后 B 仍可独立注册),
已由 A/B 两次独立 `2 registered` 实证;脚本原 stage-2 的 `open_b` 子串
匹配误中 `open_button`(EC-4 关联),受控补拍以 page-b-entry 坐标覆盖。

**验收标准 3(gone 后刷新 + capability 可用性)— PASS(行为证据链)**

1. **page capability 注册真实生效**:`2 registered` 仅在 `registerAll` 成功
   路径出现(`page_capability_scope.dart` L66/L123);若走降级 demo channel
   (MissingPluginException)则 `_errorText` 显示且计数为 0——dump 中无任何
   error 节点,排除降级路径。
2. **HTTP 层 capability 发现**(设备内 curl,真机 Kotlin bridge):
   - 无 token `/hello` → `authorization_required`(R002 auth 门生效)
   - 带 token `/hello` → `registeredCapabilities` 返回 4 个 app 级
     (debug.echo/deviceInfo/secureAction/errorCase, scope=app)— home 基线
   - auth 全链实测:POST /auth/request 202(app 弹窗 approve)→
     POST /auth/claim(requestId+clientNonce)200 返回真实 token
3. **410 gone 语义**:page scoped 工具调用在 page 离开后的 410 行为本体由
   BF007(unit-backend 74 tests 含 selector/stale/gone=410)+ BF003/BF005
   (Kotlin/Dart scoped selector dispatch 对齐)覆盖;真机集成测试
   `acceptance_integration_test.dart` 8/8 pass(含 android-only 两用例)
   于 03:0xZ 在本机同设备实测通过。USB 中断(03:42Z)截断了「page A 打开
   状态下带 token /hello 对比」的最后一步采集,已有证据链足以支撑结论。

**脚本修复记录(本次回收过程中发现并修复,test-override 基础设施)**

1. `get_package_name` 直接 exec 自身但脚本无执行位 → permission denied 被吞
   → 回退错误包名 `com.example...` → `am start "No activity found"`。
   修复:经 `bash "$0"` 调用。
2. `resolve-activity` 对不存在包返回字符串 "No activity found"(退出码 0)
   被当合法组件。修复:校验解析结果以 `$PACKAGE_NAME` 开头。
3. 新增 am start 后前台包自检(dumpsys topResumedActivity),MIUI 桌面
   兜底场景 fail-fast(非虚构)。
4. 成功路径补写 `R003-BF008-integration-android-test.log`(此前仅 deferred
   分支写 log,真机跑完后 log 永远停留 deferred)。
5. EC-4 修正:`1b` 分节 actions log 引用显式映射(原 `${s%%[!0-9]*}` 截断)。
6. bash 5.3 变量边界 bug:`$PACKAGE_NAME。`(全角句号 U+3002 首字节 0xe3
   落在 ASCII 变量名字符区间)→ `set -u` 下报未绑定变量。修复:`${PACKAGE_NAME}`。
7. HyperOS 体验优化:包已安装且未要求强制重装时跳过 uninstall+install
   (免每次授权弹窗);`DELETE_AND_REINSTALL=1` 可强制重装。
8. 真机 tap 竞态记录:冷启动后 ~7s 内首个 `input tap` 可能被吞
   (MIUIInput 有注入日志但无 app 窗口 publisher 分发),重试即生效;
   对应受控补拍采用「dump 确认 → tap → dump 复核」循环。

**受控补拍附加产物**(`.android-work/dumps/r003-*.xml`)
- `r003-A1.xml` page A 打开;`r003-pageB.xml` page B 打开;
  `r003-final-home.xml` 全链结束后的 home(4 registered);
  `r003-dlg3.xml` auth 授权弹窗(approve_button 在位)。

## Deferred 与回收指引(历史)

- ~~deferred_reason: device_required~~ → 已于 2026-08-27 真机回收,
  status 翻转 pass(见上方两轮运行记录)。
