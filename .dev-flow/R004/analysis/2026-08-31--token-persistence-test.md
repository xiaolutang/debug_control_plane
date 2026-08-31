---
date: 2026-08-31
type: test-design
requirement_cycle: R004
topic: token-persistence
source_design: 2026-08-31--token-persistence-design.md
---

# token 持久化 测试设计

## 1. 测试范围与分层

| 层 | 覆盖能力 | 运行环境 |
|---|---|---|
| unit（JVM） | FF001 store 持久化、FF002 TTL 默认值 | flutter plugin android standalone Gradle |
| unit（pytest） | BF001 FileTokenProvider | python/tests |
| integration（cross_stack） | BF001 注入链（server 组装） | python 本地 |
| integration（android 真机） | BF002 端到端 6 用例 | test-override + 真机,deferred 模式 |

## 2. 单元测试设计

### FF001-T：PluginDebugAuthStorePersistenceTest（JVM）

用例矩阵（`@TempDir` 模拟 filesDir）：
1. **roundtrip**：putToken → 新实例同目录 load → token/tokenByHash 命中,
   字段逐一相等（tokenId/tokenHash/createdAt/expiresAt/clientLabel）。
2. **可空往返**：revokedAt=null/clientLabel=null 序列化 → 反序列化保持 null。
3. **截断 JSON 回退空**：写半截文件 → load 不抛 → store 空 → 旧 token 查无。
4. **revoked 持久化**：putToken → markRevoked → 重启 → tokenByHash 命中且
   revokedAt 非空（验证 401 路径跨重启）。
5. **过期清理**：构造 expiresAt 过去记录写盘 → 新实例 load → 记录被丢弃,
   文件被回写为干净版本。
6. **原子写**：persist 后目录中无 .tmp 残留;（可选）mock rename 失败不损原文件。
7. **并发 persist**：两线程交错 putToken → 最终文件为合法 JSON 且含两者。
8. **pending 不落盘**：putPending(含 tokenPlaintext) → persist → 文件内容
   不含明文 token 子串（红线断言）。

### FF002 回归：PluginDebugAuthManagerTest 新用例

9. **默认 TTL**：构造 Manager 不注入 defaultTokenTtlSeconds,approve 不传
   ttlSeconds → expiresAt - now ∈ [604790, 604810]。
10. **显式覆盖不回归**：approve(ttlSeconds=60) → expiresAt = now+60（既有
    用例已覆盖,确保仍绿）。

### BF001-T：test_token_provider.py（pytest,tmp_path）

11. **roundtrip 跨实例**：save_token(dev, token, meta) → 新实例 get_token ==
    token。
12. **0600**：save 后 `stat().st_mode & 0o777 == 0o600`（tmp 与正式文件均验）。
13. **过期判定**：expiresAt 过去 → get_token 返 None;未来/Z 后缀 → 命中;
    非法字符串/缺失 → 视为未过期（命中）。
14. **clear 删盘**：clear_token 后新实例 get_token is None 且文件中行消失。
15. **损坏回退**：写非法 JSON → 新实例 get_token None,不抛。
16. **metadata 并入**：save 的 tokenId/expiresAt 出现在文件行。
17. **版本不符**：version:99 → 回退空。

## 3. 集成测试设计（BF002 端到端）

runner：`.dev-flow/R004/test-overrides/R004-BF002/integration-android.sh`
（fork R003-BF008 脚本 + python 断言段）。用例与 deferred 判定：

| # | 用例 | 断言 | 判定 |
|---|---|---|---|
| 1 | 首次授权双侧落盘 | claim 200;expiresAt≈7d;两侧文件存在 | 真机 |
| 2 | app 冷重启旧 token 200 | force-stop+start → Bearer /hello 200 authorized | 真机 deferred |
| 3 | install -r 旧 token 200 | rebuild+install -r → 同上【主断言】 | 真机 deferred |
| 4 | python 重启免 auth | 新进程 get_token 命中,零 /auth/request | 视可达性,否则 skip(setup_required) |
| 5 | 过期自动重授权 | 构造过期行 → 401 token_expired → 行被清 → 授权链可达 | 半真机 |
| 6 | 清装逃生门 | DELETE_AND_REINSTALL=1 → invalid_token → 弹窗回归 | 真机 deferred |

evidence 双写（deferred 空壳 + 回收翻转）沿用 R003-BF008 模式;
`acceptance.auth.token_status_text` 稳定标识供 dump 断言。

## 4. 回归防线

- 现有 fixtures 零改动（analysis 已排查：PluginDebugAuthManagerTest 全部显式
  ttl/mock 时间戳;dart bridge test mock 回显;python mock 固定值）。
- `ci-check-all` 步 [4]（plugin android JVM test）自动吸收 FF001-T/FF002;
  步 [5]（python pytest）吸收 BF001-T;步 [9] 吸收 cross-stack 回归。
- 401 三码联动（token_expired/token_revoked/invalid_token → clear_token）既有
  测试锁定,provider 落盘行为由用例 14 增强覆盖。

## 5. 测试数据与环境

- JVM：`@TempDir`（JUnit5）,无 Robolectric 依赖（org.json 由 plugin android
  工程既有依赖提供——若无则手写极简 JSON 编解码,由 implementer 判定,plan
  任务里留检查点）。
- pytest：tmp_path fixture;默认 path 不可变全局（测试只传显式 path）。
- 真机：Xiaomi 23116PN5BC（HyperOS/Android 16）;HyperOS 安装弹窗与 auth 弹窗
  分工（快速路径压制前者）写入脚本注释。

## 6. 交付判定

- unit 全绿（新增 17 用例 + 既有回归零红）。
- 真机 6 用例:1/2/3/6 必须 pass;4/5 按 deferred 契约允许 skip(setup_required)
  或 deferred(device_required) 后续回收。
- 红线断言（用例 8:文件无明文）必须 pass,不可 deferred。
