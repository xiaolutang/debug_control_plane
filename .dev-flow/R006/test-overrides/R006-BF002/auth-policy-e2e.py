#!/usr/bin/env python3
"""R006-BF002 — 真机 authPolicy 策略 e2e 断言(E1-E6, app 模式)。

纯标准库 urllib 编排(D6: e2e 脚手架归测试目录,不动 mcp_plane 库)。
fork 自 R004 e2e-token-persistence.py 的端口发现/日志骨架。

策略注入机制(B 方案, 2026-09-04):example/lib/src/android_native_plane.dart
的 AndroidNativePlane.start 已有 opt-in 编译常量注入点
  String.fromEnvironment('R006_AUTH_POLICY') → auto|none 显式声明,
  缺席/其他 = null(default 现状,字节级 0.5.1 兼容)。
本脚本按策略轮转真实 app 会话:
  flutter build apk --debug --dart-define=R006_AUTH_POLICY=<v>
  → adb install -r → am start -W → 端口发现 → adb forward tcp:18080
  → HTTP 断言 → am force-stop → 下一策略。
(plugin Kotlin 侧只在真实 app Activity 启动时由 GeneratedPluginRegistrant
注册;旧 flutter-test driver 路线因此抛 MissingPluginException,已废弃。)

用例:
  E1 auto 直连链    无 token 敏感路由 401 authorization_required →
                    POST /auth/request (clientLabel=r006-e1) 202 且
                    status=approved(auto 即时批准主断言,零人工审批)→
                    POST /auth/claim 200 得 token。
  E2 Bearer 直连    E1 token 直连敏感路由 200。
  E3 冷重启持久化    am force-stop + 同策略 am start → 旧 Bearer /hello
                    200 authStatus=authorized(R004 持久化在 auto 下照常)。
  E4 none 同构      无 token 敏感路由 200;/hello 200 且响应无
                    authRequired 字段(core null 放行语义,主断言)。
  E5 非法策略       app 模式无法注入 fail-fast(switch 注入点只映射
                    auto/none,枚举不可构造非法值,bogus 字符串在 Dart
                    侧就坍缩为 default)→ 双断言:①app 侧实证坍缩行为
                    (401 + pending,与 default 同);②非法值 fail-fast
                    主断言登记 JVM 单测 K5 引用(PluginAuthPolicyTest.K5,
                    2026-09-03 gradlew test PASS: invalid_arguments +
                    plane 不 mount),不虚构 app 侧输出。
  E6 default 回归    R006_AUTH_POLICY 缺席构建启动:无 token 401 +
                    /auth/request 202 status=pending(不 approve,
                    只断言 pending 状态)= 0.5.1 行为回归。

输出(供 shell 侧消费):最后一行 `E2E_STATUS: pass|failed`。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen

REPO = Path(__file__).resolve().parents[4]
EXAMPLE_DIR = REPO / "flutter_debug_control_plane" / "example"
BASE = "http://127.0.0.1:18080"

results: dict[str, str] = {}


# --- HTTP 工具(R004/R005 沿用,纯标准库) ------------------------------------

def http_json(method: str, path: str, body: dict[str, Any] | None = None,
              bearer: str | None = None,
              timeout: float = 5.0) -> tuple[int, Any]:
    req = Request(BASE + path, data=json.dumps(body or {}).encode(),
                  method=method)
    req.add_header("Content-Type", "application/json")
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    try:
        with urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except ValueError:
            return e.code, raw.decode(errors="replace")


# --- adb / app 会话控制 --------------------------------------------------------

def adb(serial: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["adb", "-s", serial, *args],
                          capture_output=True, text=True)


def build_apk(policy: str, log: Path) -> None:
    """按策略构建 APK(策略经 --dart-define 烤进内核)。"""
    define = (f" --dart-define=R006_AUTH_POLICY={policy}" if policy else "")
    cmd = f"cd {EXAMPLE_DIR} && fvm flutter build apk --debug{define}"
    with log.open("w") as f:
        r = subprocess.run(cmd, shell=True, stdout=f,
                           stderr=subprocess.STDOUT, timeout=900)
    if r.returncode != 0:
        tail = log.read_text(errors="replace").splitlines()[-15:]
        raise AssertionError(
            f"flutter build(dart-define={policy!r}) 失败;tail:\n"
            + "\n".join(tail))


def install_apk(serial: str, apk: Path, log: Path) -> None:
    """install -r 覆盖安装;HyperOS 拦截时等 5s 重试一次(交互授权由
    外层 shell 的提示兜底,python 侧不 read)。"""
    r: subprocess.CompletedProcess | None = None
    for attempt in (1, 2):
        r = adb(serial, "install", "-r", str(apk))
        if r.returncode == 0:
            return
        log.write_text(r.stdout + r.stderr, encoding="utf-8")
        if attempt == 1:
            print("  [install] 失败(可能 HyperOS 拦截),5s 后重试一次...")
            time.sleep(5.0)
    raise AssertionError(f"adb install -r 失败: {r.stdout} {r.stderr}")


def launch_app(serial: str, package: str) -> None:
    """冷启动:am start -W(调用方自行决定是否先 force-stop)。"""
    r = adb(serial, "shell", "am", "start", "-W", "-n",
            f"{package}/.MainActivity")
    out = (r.stdout + r.stderr).strip()
    if r.returncode != 0 or "Error" in out:
        raise AssertionError(f"am start 失败: {out[:200]}")


def forward_plane_port(serial: str, package: str, retries: int = 24) -> int:
    """R004 端口发现算法:app uid 的 tcp6 通配 LISTEN 行 → adb forward。

    实测冷启动 plane 就绪可达 40s+,retries=24 × 5s = 120s 上限。
    stat 必须在 adb shell 内执行(宿主 macOS stat 无 -c %u 语义)。
    """
    for _ in range(retries):
        pid = adb(serial, "shell", "pidof", package
                  ).stdout.strip().replace("\r", "")
        if pid:
            uid = adb(serial, "shell", "stat", "-c", "%u",
                      f"/proc/{pid}").stdout.strip().replace("\r", "")
            out = adb(serial, "shell", f"cat /proc/{pid}/net/tcp6").stdout
            for ln in out.splitlines():
                f = ln.split()
                # uid 在 f[7](行首序号列"1:"独立成词,tx:rx 两列合一;
                # 2026-09-04 真机字节级比对:全局视图 == 进程视图,
                # awk 默认空白分列与 python split 一致,但 R004 脚本
                # 写的 $8 是 awk 列号 — 对应 python f[7])。
                if (len(f) > 8 and f[3] == "0A" and f[7] == uid
                        and f[1].startswith(
                            "00000000000000000000000000000000:")):
                    port = int(f[1].split(":", 1)[1], 16)
                    adb(serial, "forward", "--remove", "tcp:18080")
                    adb(serial, "forward", "tcp:18080", f"tcp:{port}")
                    return port
        time.sleep(5.0)
    raise AssertionError("未能发现 plane 监听端口(app uid tcp6 LISTEN)")


def wait_hello(timeout: float = 60.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            st, _ = http_json("GET", "/hello", timeout=2.0)
            if st == 200:
                return
        except Exception:
            pass
        time.sleep(1.5)
    raise AssertionError("/hello 健康探测超时(60s)")


def start_policy_session(serial: str, package: str, policy: str,
                         work: Path) -> None:
    """一轮策略会话:按需重建 APK → install -r → 冷启动 → forward。"""
    apk = EXAMPLE_DIR / "build/app/outputs/flutter-apk/app-debug.apk"
    tag = policy or "default"
    # 构建缓存判定:同策略 APK 已存在则跳过重建。flutter 增量构建对
    # dart-define 常量切换是可靠的,但标记文件把「当前烤入策略」显式
    # 化,避免旧 APK 误判(e2e 第一轮失败的根因就是设备上是策略前旧件)。
    marker = work / f"apk-built-for-{tag}"
    if not marker.exists():
        print(f"  [build] dart-define=R006_AUTH_POLICY={policy or '(absent)'}")
        build_apk(policy, work / f"build-{tag}.log")
        marker.write_text(tag, encoding="utf-8")
        for m in work.glob("apk-built-for-*"):
            if m.name != marker.name:
                m.unlink()
    install_apk(serial, apk, work / f"install-{tag}.log")
    adb(serial, "shell", "am", "force-stop", package)
    time.sleep(2.0)
    launch_app(serial, package)
    port = forward_plane_port(serial, package)
    print(f"  [forward] plane:{port} -> 127.0.0.1:18080")
    wait_hello()


# --- E1-E6 --------------------------------------------------------------------

def e1_e2_auto(serial: str, package: str, work: Path) -> str:
    """E1 auto 直连授权链 + E2 Bearer 直连敏感路由。"""
    start_policy_session(serial, package, "auto", work)
    nonce = f"r006-e1-{uuid.uuid4().hex[:8]}"
    st, body = http_json("POST", "/debug/secure-action", {"via": "r006-e1"})
    assert st == 401 and body.get("code") == "authorization_required", \
        f"E1-1 无 token 应 401 authorization_required: {st} {body!r:.80}"
    st, body = http_json("POST", "/auth/request",
                         {"clientNonce": nonce, "clientLabel": "r006-e1"})
    assert st == 202 and body.get("status") == "approved", \
        f"E1-2 auto 即时批准主断言失败(期望 202 approved): {st} {body!r:.80}"
    st, body = http_json("POST", "/auth/claim",
                         {"requestId": body["requestId"],
                          "clientNonce": nonce})
    assert st == 200 and isinstance(body.get("token"), str) and body["token"], \
        f"E1-3 claim 应 200 得 token: {st} {body!r:.80}"
    token = body["token"]
    results["E1"] = "pass"
    print("  E1 PASS: 401 → /auth/request 202 approved(auto) → claim 200"
          " 全程零人工审批")

    st, body = http_json("POST", "/debug/secure-action",
                         {"via": "r006-e2"}, bearer=token)
    assert st == 200, f"E2 Bearer 直连敏感路由应 200: {st} {body!r:.80}"
    results["E2"] = "pass"
    print("  E2 PASS: Bearer 直连 /debug/secure-action 200")
    return token


def e3_cold_restart(token: str, serial: str, package: str) -> None:
    # 同策略(auto)冷重启:APK/install 复用,直接 force-stop + start
    adb(serial, "shell", "am", "force-stop", package)
    time.sleep(2.0)
    launch_app(serial, package)
    forward_plane_port(serial, package)
    wait_hello()
    st, body = http_json("GET", "/hello", bearer=token)
    assert st == 200 and body.get("authStatus") == "authorized", \
        f"E3 冷重启旧 Bearer /hello 应 200 authorized: {st} {body!r:.80}"
    results["E3"] = "pass"
    print("  E3 PASS: am force-stop + 同策略重启后旧 Bearer /hello 200"
          " authorized(auto 下持久化照常)")


def e4_none(serial: str, package: str, work: Path) -> None:
    start_policy_session(serial, package, "none", work)
    st, body = http_json("POST", "/debug/secure-action", {"via": "r006-e4"})
    assert st == 200, f"E4-1 none 无 token 敏感路由应 200: {st} {body!r:.80}"
    st, body = http_json("GET", "/hello")
    assert st == 200 and "authRequired" not in body, \
        f"E4-2 /hello 应 200 且无 authRequired 字段: {st} {body!r:.80}"
    results["E4"] = "pass"
    print("  E4 PASS: none 无 token 敏感路由 200;/hello 无 authRequired"
          "(core null 放行,两宿主同构主断言)")


def e5_bogus(serial: str, package: str, work: Path) -> None:
    """E5 非法策略:app 侧坍缩断言 + JVM K5 证据引用(双断言)。

    switch 注入点只映射 auto/none(`_ => null`),bogus 字符串在 Dart
    侧就坍缩为 default,无法经 channel 传入非法值(enum 不可构造)。
    ①app 侧实证坍缩行为(401 + pending = default 同构,不 crash 不 auto);
    ②非法值 fail-fast 主断言由 JVM 单测 K5 承担,此处登记引用。
    """
    start_policy_session(serial, package, "bogus", work)
    st, body = http_json("POST", "/debug/secure-action", {"via": "r006-e5"})
    assert st == 401, \
        f"E5-1 bogus 坍缩为 default: 敏感路由应 401(而非 crash/auto): {st}"
    nonce = f"r006-e5-{uuid.uuid4().hex[:8]}"
    st, body = http_json("POST", "/auth/request",
                         {"clientNonce": nonce, "clientLabel": "r006-e5"})
    assert st == 202 and body.get("status") == "pending", \
        f"E5-2 bogus 坍缩为 default: 授权链应 202 pending: {st} {body!r:.80}"
    results["E5"] = "pass"
    print("  E5 PASS(app 侧坍缩断言): bogus --dart-define 坍缩 default"
          "(401 + pending);非法值 fail-fast 主断言由 JVM 单测"
          " PluginAuthPolicyTest.K5 覆盖(invalid_arguments + 不 mount,"
          "2026-09-03 gradlew test PASS)")


def e6_default(serial: str, package: str, work: Path) -> None:
    start_policy_session(serial, package, "", work)
    st, body = http_json("POST", "/debug/secure-action", {"via": "r006-e6"})
    assert st == 401, f"E6-1 default 无 token 应 401: {st}"
    nonce = f"r006-e6-{uuid.uuid4().hex[:8]}"
    st, body = http_json("POST", "/auth/request",
                         {"clientNonce": nonce, "clientLabel": "r006-e6"})
    assert st == 202 and body.get("status") == "pending", \
        f"E6-2 授权链应 202 pending(不 approve): {st} {body!r:.80}"
    results["E6"] = "pass"
    print("  E6 PASS: default 回归 无 token 401 + 授权链 pending 可达")


# --- 入口 ----------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--package", required=True)
    ap.add_argument("--work", default=str(
        Path(__file__).resolve().parent / ".android-work"))
    args = ap.parse_args()
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    try:
        token = e1_e2_auto(args.serial, args.package, work)
        e3_cold_restart(token, args.serial, args.package)
        e4_none(args.serial, args.package, work)
        e5_bogus(args.serial, args.package, work)
        e6_default(args.serial, args.package, work)
    except (AssertionError, Exception) as e:  # noqa: BLE001
        for k in ("E1", "E2", "E3", "E4", "E5", "E6"):
            results.setdefault(k, "failed")
        for k, v in results.items():
            if v == "pass":
                print(f"  {k} PASS")
        print(f"FAILED: {e}")
        print("E2E_STATUS: failed")
        return 1
    finally:
        adb(args.serial, "shell", "am", "force-stop", args.package)
    print("E2E_STATUS: pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
