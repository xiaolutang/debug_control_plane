---
type: acceptance-evidence
task_id: R004-BF002
run_at: 2026-08-31T13:50:18Z
device_model: null
os_version: null
status: deferred
deferred_reason: device_required
---

# token 持久化端到端 6 用例验收(R004-BF002)

> **未执行声明**:本次运行(`2026-08-31T13:50:18Z`)`adb devices` 无 device,
> 6 用例**均未执行**。以下各节仅为空壳结构占位,不存在任何实际运行
> 产生的命令输出或推定性结论。待设备可用时重跑 integration-android.sh
> 补齐内容并翻转 status。

## 用例 1:首次授权双侧落盘(claim 200;expiresAt≈7d;两侧文件存在)

(未执行)

## 用例 2:app 冷重启旧 token 200(force-stop+start → Bearer /hello)[device]

(未执行)

## 用例 3:install -r 重建安装旧 token 200【主断言】[device]

(未执行)

## 用例 4:python 重启免 auth(新进程 get_token 命中,零 /auth/request)

(视 endpoint 可达性,未执行)

## 用例 5:过期自动重授权(401 token_expired → 行被清 → 授权链可达)

(视 endpoint 可达性,未执行)

## 用例 6:清装逃生门(DELETE_AND_REINSTALL=1 → invalid_token → 弹窗回归)[device]

(未执行)

## 结论(对照验收标准)

(未执行——1/2/3/6 需真机采集后逐条对照登记;4/5 按 deferred 契约允许
skip(setup_required)。)

## Deferred 与回收指引

- deferred_reason: device_required
- 回收动作: 开启设备 USB 调试与(HyperOS)「USB 安装」授权后重跑
  `bash .dev-flow/R004/test-overrides/R004-BF002/integration-android.sh`;
  用例 6 需以 `DELETE_AND_REINSTALL=1` 环境变量单独重跑一轮。
