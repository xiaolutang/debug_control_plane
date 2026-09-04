## 0.5.2

- 新增授权策略装配 API(R006):`AuthPolicy` enum(`defaultPolicy`/`auto`/
  `none`,Dart 保留字回避——wire 层仍为 "default")+ `NativeControlPlaneBridge
  .start(authPolicy:)` 可选参数透传;**缺席参数 = 0.5.1 行为逐字节兼容**,
  既有宿主零感知、零迁移。
- `auto`(装配为 `PluginDebugAuthManager(autoApprove=true)`):授权请求落库后
  即时批准——复用既有签发链,宿主审计通知仍发,nonce 重放幂等;适合 CI/
  无人值守设备农场,python 客户端零改动(claim 即时resolve)。
- `none`(装配为 `authManager=null`):与纯 Dart 宿主同构——`/hello` 响应无
  `authRequired` 字段,敏感路由直连 200;适合锁定 debug 构建/本地工具。
- 非法 wire 值 Kotlin 侧 fail-fast `invalid_arguments`(plane 不 mount 不
  静默回退);Dart 闭合 enum 从构造面杜绝非法值。策略为装配期一次性决策,
  start 后不可变(JOIN 不重建)。
- 验收:JVM K1-K8(全套 89 tests 0 failed)+ 真机 e2e E1-E6(Xiaomi
  Android 16,auto 直连链/Bearer/冷重启持久化/none 同构主断言/bogus 坍缩
  +K5 fail-fast/default 回归)+ iOS 模拟器 I1-I5 回归全 PASS。

## 0.5.1

- 版本对齐发布(alignment-only):插件 Android 侧与 Dart API 面本版**零改动**——
  R005 的 Dart plane token 持久化落在 dart core 包(`DebugAuthStore`
  三件套 + `debugAuthTokenHash`),插件经 `flutter_debug_control_plane`
  `^0.5.1` 依赖线自动获得。
- example 验收 app(非发布面)接 store 注入 + TTL 15min→7d 对齐,iOS 模拟器
  I1-I5 集成验证(冷重启旧 Bearer 200 authorized 零弹窗)。
- wire 协议零改动——业务方仅需升级版本号。

## 0.5.0

- 新增 `FileBackedPluginDebugAuthStore`(R004 FF001):token **hash 记录**
  持久化到 `filesDir/debug_control_plane/debug_auth_tokens.json`——
  tmp+rename 原子写、损坏回退空、过期记录清理回写;明文 token 永不落盘
  (pending 组纯内存透传)。`onAttachedToEngine` 惰性升级 InMemory store,
  内存记录零拷贝迁移,覆盖安装后 token 存活。
- token TTL 默认 1h → 7 天(R004 FF002,
  `PluginDebugAuthManager.DEFAULT_TOKEN_TTL_SECONDS = 604800`);显式
  `ttlSeconds` 覆盖通道语义不变。
- Dart API 零改动、wire 协议零改动——业务方仅需升级版本号。
- 真机验收:Xiaomi HyperOS Android 16,6/6 用例(冷重启/覆盖安装/python
  重启/过期重授权/清装逃生门)。

## 0.4.0

- 新增 `PageCapabilityScope` helper:业务按 pageId 注册/释放 page 级
  capability(两段式预检查 + 幂等 + dispose no-op),MethodChannel 透传
  scope identity。
- Android 侧 native registry 解析 scope/pageId payload,page capability
  与 app capability 同 ControlPlane 并存;离开页面即释放,gone 后调用
  返回 `410 page_capability_gone`。
- 示例 app 新增 Page Scope Demo(page A/B 独立 route);Android 侧
  Kotlin 核心依赖升到 `0.4.0`(dart 侧 ^0.4.0)。

## 0.3.0

- 版本对齐: kotlin 核心、dart 核心、本插件统一到 `0.3.0`，同版本号 =
  已验证兼容组合。
- Android 真机验收覆盖认证流程，并修正示例 app 重复启动/停止 native plane
  时的注册去重与清理行为。
- Android 侧 Kotlin 核心依赖升到
  `com.github.xiaolutang:debug_control_plane:0.3.0`。

## 0.2.0

- 版本对齐:整个 debug_control_plane 生态统一版本线——kotlin 0.2.0
  (JitPack)、dart 核心 0.2.0(pub.dev)、本插件 0.2.0。同版本号 =
  已验证兼容组合,升级时三端对齐到同一版本。
- Dart 侧依赖升 debug_control_plane ^0.2.0。

## 0.1.0

- 首个 pub.dev 版本。Android MethodChannel 桥:Dart Capability 注册到原生
  ControlPlane(via NanoHTTPD server),支持正向调用 / SSE 事件流 / 反向
  invoke(native → Dart capability)。
- Kotlin 核心经 JitPack 坐标 `com.github.xiaolutang:debug_control_plane:0.2.0`
  分发(源码 tag v0.2.0,同一 repo)。
- Dart 侧依赖 debug_control_plane ^0.1.1(pub.dev)。
