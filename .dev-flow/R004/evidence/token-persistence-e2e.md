---
type: acceptance-evidence
task_id: R004-BF002
run_at: 2026-09-01T10:35:00Z
device_model: 23116PN5BC
os_version: 16
status: pass
recovered_from: deferred
---

# token 持久化端到端 6 用例验收(R004-BF002)— 真机回收 PASS

设备 Xiaomi 23116PN5BC(Android 16,serial bc6763eb)在场,原 deferred
6 用例全部回收。详细过程与证据见 `R004-BF002-integration-android-test.log`。

## 用例 1:首次授权双侧落盘(claim 200;expiresAt≈7d;两侧文件存在)

PASS。claim 200(token `dcp_*`);app 侧
`files/debug_control_plane/debug_auth_tokens.json`(tokenHash 记录,**无明文**);
python 侧 `~/.debug-control-plane/tokens.json` 0600 落盘。expiresAt delta
=604798s(7.00 天)。

## 用例 2:app 冷重启旧 token 200(force-stop+start → Bearer /hello)[device]

PASS。force-stop + am start 后旧 token GET /hello → **200,authStatus=authorized**
(零授权弹窗)。

## 用例 3:install -r 重建安装旧 token 200【主断言】[device]

PASS。`adb install -r`(同 APK 重装)→ 重启 app → 旧 token /hello →
**200 authorized**;filesDir token 文件存活。这是 R004 核心价值断言:
覆盖安装不再丢 token。

## 用例 4:python 重启免 auth(新进程 get_token 命中,零 /auth/request)

PASS。全新 python 进程 `FileTokenProvider.get_token` 真实读盘命中。

## 用例 5:过期自动重授权(401 token_expired → 行被清 → 授权链可达)

PASS。构造过期行 → 读时判定 get_token=None → auth_request 新 pending
建立可达(授权链自动触发路径)。

## 用例 6:清装逃生门(DELETE_AND_REINSTALL=1 → invalid_token → 弹窗回归)[device]

PASS。uninstall+install(等价逃生门轮次;期间 HyperOS 拦截一次,手动
授权后成功)→ 旧 token /hello 响应 authStatus=**invalid_token**(非
authorized)——首次授权语义正确回归,逃生门有效。

## 结论(对照验收标准)

6/6 全部 pass。R004 四能力(FF001/FF002/BF001/BF002)在真实 Xiaomi/
HyperOS/Android 16 设备上行为符合设计:授权弹窗只弹首次;app 冷重启/
覆盖安装/python 重启/token 过期四种场景均无需人工介入;清装正确回到
首次授权。

## 执行偏差与后续改进

脚本自动化链路存在两处环境适配问题(plane 动态端口未自动发现、
ensure_token 在 pending 期直接 claim 被 401 中断),本次回收以手动驱动
+ 相同断言完成,详见 android test log「执行偏差」节。脚本修复留作后续
改进项,不影响验收结论。
