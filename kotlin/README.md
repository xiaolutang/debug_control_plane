# debug_control_plane (Kotlin core)

Kotlin 实现的调试控制平面核心 —— 纯 JVM 库，零 Android 组件、零业务依赖。
HTTP/SSE 字节级协议以 [../PROTOCOL.md](../PROTOCOL.md) 为准（`protocolVersion=1`，
与 Dart / Python 实现互通）。

## 依赖 / Dependency

Android 原生项目（或任何 JVM 项目）：

```kotlin
// settings.gradle.kts / build.gradle.kts 仓库源（二选一位置）
repositories {
    maven { url = uri("https://jitpack.io") }
}

// 模块依赖
dependencies {
    implementation("com.github.xiaolutang:debug_control_plane:0.3.0")
}
```

传递依赖：`kotlinx-coroutines` / `nanohttpd` / `org.json`（Android 平台自带
org.json，运行时用平台的）。

## 端点 / Endpoints

| 端点 | 方法 | 说明 |
|------|------|------|
| `/hello` | GET | 发现握手：app 身份（appMeta）+ 能力清单 |
| `/state` | GET | 聚合状态：所有 capability 的状态快照平铺 |
| `/events` | GET | SSE 事件流（`event:` / `data:` 帧，无心跳无 resume） |
| `/<cap>/...` | GET/POST | 注册的 capability 资源/命令路由 |

## 启动 / Start

**库不自动启动** —— 纯库形态是刻意设计，宿主全权决定何时起、起不起、
什么构建类型起。典型：Android `Application.onCreate` 里 debug 构建起。

```kotlin
class MyApp : Application() {

    // 挂住 scope，生命周期属于宿主
    private val planeScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var plane: ControlPlane

    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) {          // 生产不带 debug 服务
            val (p, _) = ControlPlaneServer.create(
                scope = planeScope,
                port = 18080,             // 发现契约端口；0 = OS 随机
                appMeta = {
                    mapOf(
                        "app" to "my-app",
                        "deviceName" to Build.MODEL,
                        "platform" to "android",
                    )
                },
            )
            plane = p
            planeScope.launch {
                try {
                    val uri = plane.start(18080)   // start 是 suspend
                    Log.d("plane", "listening on $uri")
                } catch (e: Exception) {
                    // 绑定失败（如端口被占）→ 降级继续跑，别让 debug 服务拖崩 app
                    Log.w("plane", "disabled: $e")
                }
            }
        }
    }
}
```

验证：手机与电脑同网段，`curl http://<手机IP>:18080/hello`。

## 启动语义（重要）/ Start semantics

- `start` 是 **start-once with shared result**：首次调用真正绑定，后续调用
  join（返回同一 URI），不会双绑。
- **失败会被缓存**：首次绑定失败后，后续所有 `start` 重抛同一失败，直到
  `stop()` 清除。不打算重试就 catch 住记日志即可。
- **生命周期属于宿主**：谁创建 scope、谁调用 `start()`，谁就必须在自己的
  生命周期结束时调用 `plane.stop()`，再取消 scope。Activity 关闭、退后台、
  最近任务划掉都不等于进程退出；只要进程或 Service 还活着，`18080` 监听就
  会继续占用。
- 多个业务 app 同时运行 debug plane 时不能共享固定端口。`EADDRINUSE`
  表示当前设备上已有进程占用该端口；停止那个 owner 的 debug plane，或为不
  同 app 分配不同端口。
- 全部聚合 API 是 `suspend`，库内零 `runBlocking`（Android ANR 防护）。

典型 Service owner 的销毁路径：

```kotlin
override fun onDestroy() {
    serviceScope.launch {
        try {
            plane.stop()
        } finally {
            serviceScope.cancel()
        }
    }
    super.onDestroy()
}
```

如果把 plane 放在 `Application` 里，端口生命周期就是进程生命周期；真机上
不要依赖 `Application.onTerminate()` 释放端口。

## 注册 Capability

```kotlin
object CounterCapability : Capability {
    private val events = MutableSharedFlow<DebugEvent>(extraBufferCapacity = 64)

    override val id = "counter"

    override fun resources() = listOf(
        Resource(method = "GET", path = listOf("counter", "value")),
    )

    override fun commands() = listOf(
        Command(method = "POST", path = listOf("counter", "increment")),
    )

    override suspend fun handleResource(r: Resource, ctx: RouteContext) =
        mapOf("ok" to true, "value" to 42)

    override suspend fun handleCommand(c: Command, ctx: RouteContext): Map<String, Any?> {
        events.emit(DebugEvent(type = "incremented", payload = mapOf("by" to 1)))
        return mapOf("ok" to true)
    }

    override fun events(): Flow<DebugEvent> = events
    override suspend fun state() = mapOf("counterKey" to 42)
}

plane.register(CounterCapability)   // 重复 id → IllegalArgumentException
```

路径段支持 `{name}` 单段占位符（`listOf("items", "{id}")` → 匹配
`/items/42` 并注入 `pathParams["id"]`），平面路由无前缀、注册序优先。

## Flutter app 接入

Flutter 项目不要直接用本包 —— 用插件
[`flutter_debug_control_plane`](../flutter_debug_control_plane)（pub.dev
0.3.0，内部依赖 JitPack 坐标的本核心），Dart 侧 Capability 经
MethodChannel 注册到原生平面。

## 版本 / Version

`0.3.0` —— Kotlin/JitPack、Dart core、Flutter plugin 对齐版本，包含
Android 真机认证验收 app 相关修正。协议仍是 `protocolVersion=1`。
