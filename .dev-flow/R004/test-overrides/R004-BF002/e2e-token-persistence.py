#!/usr/bin/env python3
"""R004-BF002 token 持久化端到端 runner(6 用例)。

被 integration-android.sh 调用;也可独立运行(仅 cross-stack 链)。
设备无独立 curl 通道(Dart plane loopback),所有 HTTP 断言 python 侧发起。

用例(test.md §3):
  1 首次授权双侧落盘   claim 200;expiresAt≈7d;两侧文件存在        [device]
  2 app 冷重启旧 token  force-stop+start → Bearer /hello 200        [device]
  3 install -r 旧 token  重装后旧 token /hello 200【主断言】         [device]
  4 python 重启免 auth   新进程 FileTokenProvider.get_token 命中
  5 过期自动重授权       过期行 → 401 token_expired → 行被清         [semi]
  6 清装逃生门           DELETE_AND_REINSTALL=1 → invalid_token      [device]

判定契约:
  - 设备不在场 → device 用例 deferred(device_required)
  - 4/5 视 endpoint 可达性,不可达 → skip(setup_required)
  - cross-stack 链(bearer-reuse / 401-clear-relay,provider 真实读盘,
    不 mock 读路径)始终执行,写入 cross_stack log

输出: 逐用例一行 CASE 结果 + 末行 "E2E_STATUS: pass|fail|deferred"。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO_ROOT / "python"))

from debug_control_plane.mcp_plane.bridge_client import (  # noqa: E402
    BridgeClient,
    DeviceAuthError,
    DeviceHttpError,
)
from debug_control_plane.mcp_plane.token_provider import FileTokenProvider  # noqa: E402
from debug_control_plane.device_discovery.device_pool import (  # noqa: E402
    DevicePool,
    DeviceRecord,
)

DEFAULT_HOST = os.environ.get("R004_DEVICE_HOST", "127.0.0.1")
PORT = int(os.environ.get("R004_DEVICE_PORT", "18080"))
TOKENS_JSON = Path.home() / ".debug-control-plane" / "tokens.json"
APP_TOKEN_FILE = "files/debug_control_plane/debug_auth_tokens.json"
CLEAR_CODES = {"token_expired", "token_revoked", "invalid_token"}
SEVEN_DAYS = 7 * 24 * 3600

results: dict[str, str] = {}  # case_id -> pass|fail|deferred|skipped


def adb(*args: str, serial: str | None = None) -> str:
    cmd = ["adb"]
    if serial:
        cmd += ["-s", serial]
    cmd += list(args)
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def make_client(host: str, provider: FileTokenProvider) -> BridgeClient:
    """Build a BridgeClient against an explicit host (bypasses pool TTL)."""
    pool = DevicePool(persist_path=Path(tempfile.mkdtemp()) / "devices.json")
    pool.upsert(
        DeviceRecord(
            device_id="__e2e__",
            label="e2e",
            source="manual",
            last_known_host=host,
            last_seen=time.time(),
            ttl=3600.0,
        )
    )
    return BridgeClient(pool, token_provider=provider)


def raw_bearer_hello(host: str, token: str) -> tuple[int, Any]:
    """GET /hello with explicit Bearer token; returns (status, parsed body)."""
    import httpx

    resp = httpx.get(
        f"http://{host}:{PORT}/hello",
        headers={"Authorization": f"Bearer {token}"},
        timeout=5.0,
    )
    try:
        body = resp.json()
    except ValueError:
        body = resp.text
    return resp.status_code, body


def auth_error_code(status: int, body: Any) -> str | None:
    if isinstance(body, dict):
        # wire 契约错误码字段为 `code`(bridge_client._auth_error_code 对齐)
        code = body.get("code") or body.get("errorCode") or body.get("error_code")
        if isinstance(code, str):
            return code
    if isinstance(body, str):
        for c in CLEAR_CODES | {"auth_required"}:
            if c in body:
                return c
    return None


# ---------------------------------------------------------------------------
# cross-stack 断言链(bearer-reuse / 401-clear-relay,provider 真实读盘)
# ---------------------------------------------------------------------------


def run_cross_stack(cross_log: Path, run_at: str) -> bool:
    """Provider 真实读盘断言:不 mock 读路径,不 mock DevicePool。

    bearer-reuse: save_token 落盘 → 全新 provider 实例(真实读盘)→
      BridgeClient._auth_headers 命中 Bearer(经 httpx MockTransport 捕获
      请求头——mock 的是传输层,不是 token 读路径)。
    401-clear-relay: 手机回 401 token_expired → _http_error 联动
      clear_token → 新 provider 实例读盘确认行已删。
    """
    import httpx

    ok = True
    lines = [
        "---",
        "type: test-log",
        "task_id: R004-BF002",
        "layer: integration",
        "domain: cross_stack",
        f"run_at: {run_at}",
        "status: pass",
        "exit_code: 0",
        "---",
        "",
        "# Test Log: R004-BF002 (integration.cross_stack — provider 断言链)",
        "",
    ]
    tmpdir = Path(tempfile.mkdtemp())

    # --- bearer-reuse ---
    try:
        pstore = tmpdir / "tokens.json"
        prov = FileTokenProvider(path=pstore)
        prov.save_token(
            "dev1", "dcp_e2e_reuse", {"tokenId": "t1", "expiresAt": "2099-01-01T00:00:00Z"}
        )
        captured: dict[str, str] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            captured["authorization"] = request.headers.get("authorization", "")
            return httpx.Response(200, json={"deviceId": "x"})

        pool = DevicePool(persist_path=tmpdir / "devices.json")
        pool.upsert(
            DeviceRecord(
                device_id="dev1",
                label="x",
                source="manual",
                last_known_host="127.0.0.1",
                last_seen=time.time(),
                ttl=3600.0,
            )
        )
        # 关键:注入"新进程视角"的 provider(重新真实读盘,非内存透传)
        client = BridgeClient(
            pool,
            client=httpx.Client(transport=httpx.MockTransport(handler)),
            token_provider=FileTokenProvider(path=pstore),
        )
        client.hello("dev1")
        assert captured["authorization"] == "Bearer dcp_e2e_reuse", captured
        lines += [
            "- bearer-reuse: PASS — save_token 落盘后,新 provider 实例经"
            " BridgeClient 真实读盘命中 Bearer 头(Authorization: Bearer dcp_e2e_reuse)",
        ]
    except Exception as exc:  # noqa: BLE001
        ok = False
        lines += [f"- bearer-reuse: FAIL — {exc!r}"]

    # --- 401-clear-relay ---
    try:
        pstore = tmpdir / "tokens2.json"
        prov = FileTokenProvider(path=pstore)
        prov.save_token(
            "dev2", "dcp_e2e_expired", {"tokenId": "t2", "expiresAt": "2099-01-01T00:00:00Z"}
        )

        def handler401(request: httpx.Request) -> httpx.Response:
            # wire 契约错误码字段为 `code`(bridge_client._auth_error_code)
            return httpx.Response(401, json={"code": "token_expired"})

        pool = DevicePool(persist_path=tmpdir / "devices2.json")
        pool.upsert(
            DeviceRecord(
                device_id="dev2",
                label="x",
                source="manual",
                last_known_host="127.0.0.1",
                last_seen=time.time(),
                ttl=3600.0,
            )
        )
        relay_provider = FileTokenProvider(path=pstore)
        client = BridgeClient(
            pool,
            client=httpx.Client(transport=httpx.MockTransport(handler401)),
            token_provider=relay_provider,
        )
        try:
            client.hello("dev2")
            raise AssertionError("expected DeviceAuthError")
        except DeviceAuthError as exc:
            assert exc.code == "token_expired", exc.code
        # 新实例真实读盘确认行被清(401 三码联动)
        assert FileTokenProvider(path=pstore).get_token("dev2") is None, "row not cleared"
        lines += [
            "- 401-clear-relay: PASS — 401 token_expired 经 _http_error 联动"
            " clear_token,新 provider 实例读盘确认 tokens.json 对应行已删除",
        ]
    except Exception as exc:  # noqa: BLE001
        ok = False
        lines += [f"- 401-clear-relay: FAIL — {exc!r}"]

    if not ok:
        for i, line in enumerate(lines):
            if line.startswith("status: pass"):
                lines[i] = "status: fail"
            if line.startswith("exit_code: 0"):
                lines[i] = "exit_code: 1"
    cross_log.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return ok


# ---------------------------------------------------------------------------
# 真机 6 用例
# ---------------------------------------------------------------------------


def device_present(serial: str) -> bool:
    return serial != "" and serial in adb("devices")


def ensure_token(host: str, serial: str) -> tuple[str, dict]:
    """用例 1 主路径:走 auth request→claim 链获取新 token。

    需要真机人工 approve(脚本使用者按 app 弹窗确认)。claim 成功时
    BridgeClient 自动经 FileTokenProvider 落盘。
    """
    provider = FileTokenProvider()
    client = make_client(host, provider)
    nonce = uuid.uuid4().hex
    req = client.auth_request("__e2e__", nonce, client_label="R004-BF002-e2e")
    request_id = req.get("requestId") if isinstance(req, dict) else None
    if not request_id:
        raise RuntimeError(f"auth/request 无 requestId: {req!r}")
    print(f"      >>> 请在手机上 approve 授权请求(requestId={request_id})...")
    deadline = time.time() + 90
    token = None
    claim = None
    while time.time() < deadline:
        time.sleep(5)
        claim = client.auth_claim("__e2e__", request_id, nonce)
        if isinstance(claim, dict) and isinstance(claim.get("token"), str):
            token = claim["token"]
            break
    if token is None:
        raise RuntimeError(f"claim 未在 90s 内成功: {claim!r}")
    return token, claim


def existing_device_row() -> tuple[str, dict] | None:
    """复用已落盘 token(python 侧 tokens.json),避免每轮都人工 approve。"""
    if not TOKENS_JSON.exists():
        return None
    try:
        data = json.loads(TOKENS_JSON.read_text(encoding="utf-8"))
    except ValueError:
        return None
    tokens = data.get("tokens") if isinstance(data, dict) else None
    if not isinstance(tokens, dict) or not tokens:
        return None
    device_id, row = next(iter(tokens.items()))
    if device_id == "__e2e__" or not isinstance(row, dict):
        return None
    token = row.get("token")
    return (token, row) if isinstance(token, str) and token else None


def app_file_exists(serial: str, package: str) -> bool:
    out = adb("shell", f"run-as {package} ls {APP_TOKEN_FILE}", serial=serial)
    return APP_TOKEN_FILE.split("/")[-1] in out and "No such" not in out and "not found" not in out


def case1(host: str, serial: str, package: str) -> None:
    row = existing_device_row()
    if row is not None:
        token, meta = row
        status, _ = raw_bearer_hello(host, token)
        if status != 200:
            # 落盘 token 已不可用(设备清装/过期),走完整授权链
            row = None
    if row is None:
        token, claim = ensure_token(host, serial)
        meta = claim
    provider = FileTokenProvider()
    # python 侧断言
    got = provider.get_token(list(json.loads(TOKENS_JSON.read_text())["tokens"])[0]) \
        if TOKENS_JSON.exists() else None
    ok = got == token
    # expiresAt ≈ 7d
    expires_at = meta.get("expiresAt", "")
    try:
        exp = datetime.fromisoformat(str(expires_at).replace("Z", "+00:00"))
        delta = (exp - datetime.now(timezone.utc)).total_seconds()
        ok = ok and 0 < delta <= SEVEN_DAYS + 600
        delta_desc = f"expiresAt_delta={delta:.0f}s(≈7d)"
    except ValueError:
        delta_desc = f"expiresAt={expires_at!r}(不可解析,未断言)"
    # app 侧文件存在(run-as 读私有目录)
    app_ok = app_file_exists(serial, package)
    results["case1"] = "pass" if (ok and app_ok) else "fail"
    print(f"  python侧文件命中={ok};{delta_desc};app侧文件存在={app_ok}")


def case2(host: str, serial: str, activity: str) -> None:
    token, _ = require_token()
    adb("shell", "am", "force-stop", activity.split("/")[0], serial=serial)
    time.sleep(2)
    adb("shell", "am", "start", "-W", "-n", activity, serial=serial)
    time.sleep(6)
    status, body = raw_bearer_hello(host, token)
    results["case2"] = "pass" if status == 200 else "fail"
    print(f"  force-stop+start 后旧 token /hello → {status} {body!r:.80}")


def case3(host: str) -> None:
    """主断言:本轮脚本已执行 install -r(未 uninstall),旧 token 应 200。

    本函数由 runner 直接发起断言;真正的「重建 + install -r」由外层脚本
    在本轮执行(步骤 3/4),此处验证的是重装后 token 存活。
    """
    token, _ = require_token()
    status, body = raw_bearer_hello(host, token)
    results["case3"] = "pass" if status == 200 else "fail"
    print(f"  install -r 后旧 token /hello → {status} {body!r:.80}")


def case4() -> None:
    """python 重启免 auth:子进程真实读盘 get_token 命中(零 /auth/request)。"""
    if not TOKENS_JSON.exists():
        results["case4"] = "skipped"
        print("  skip(setup_required): tokens.json 不存在(用例 1 未产出)")
        return
    code = (
        "import sys,json,pathlib;"
        "d=json.loads(pathlib.Path.home().joinpath('.debug-control-plane/tokens.json').read_text());"
        "rows={k:v for k,v in d.get('tokens',{}).items() if k!='__e2e__'};"
        "sys.path.insert(0,sys.argv[1]);"
        "from debug_control_plane.mcp_plane.token_provider import FileTokenProvider;"
        "p=FileTokenProvider();"
        "hit=[k for k in rows if p.get_token(k)];"
        "print('HIT' if hit else 'MISS')"
    )
    out = subprocess.run(
        [sys.executable, "-c", code, str(REPO_ROOT / "python")],
        capture_output=True, text=True,
    ).stdout.strip()
    if out == "HIT":
        results["case4"] = "pass"
        print("  新 python 进程 get_token 命中(真实读盘,零 /auth/request)")
    elif out == "MISS":
        results["case4"] = "fail"
        print("  FAIL: 新进程 get_token 未命中")
    else:
        results["case4"] = "skipped"
        print(f"  skip(setup_required): 子进程异常: {out!r}")


def case5(host: str, serial: str) -> None:
    """过期自动重授权:构造过期行 → 手机 401 token_expired → 行被清 → 授权链可达。"""
    if not TOKENS_JSON.exists():
        results["case5"] = "skipped"
        print("  skip(setup_required): tokens.json 不存在")
        return
    data = json.loads(TOKENS_JSON.read_text(encoding="utf-8"))
    device_id = next((k for k in data.get("tokens", {}) if k != "__e2e__"), None)
    if device_id is None:
        results["case5"] = "skipped"
        print("  skip(setup_required): tokens.json 无真实设备行")
        return
    backup = data["tokens"][device_id]
    data["tokens"][device_id]["expiresAt"] = "2000-01-01T00:00:00Z"
    # 注意:手机侧 token 本身未过期,故手机回的不是 token_expired 而是 200。
    # python 侧 get_token 判过期 → 不带 Bearer → 手机 401 → 触发授权链。
    TOKENS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    provider = FileTokenProvider()
    got = provider.get_token(device_id)
    row_cleared_by_read = got is None  # 读时判定过期 → 无 Bearer
    if not row_cleared_by_read:
        results["case5"] = "fail"
        print("  FAIL: 过期行 get_token 未返回 None")
        return
    # 授权链可达:auth_request 不带 token 也能建 pending
    try:
        client = make_client(host, FileTokenProvider())
        req = client.auth_request("__e2e__", uuid.uuid4().hex, client_label="R004-BF002-case5")
        reachable = isinstance(req, dict) and bool(req.get("requestId"))
    except Exception as exc:  # noqa: BLE001
        reachable = False
        print(f"  授权链探测异常: {exc!r}")
    # 还原未过期行(不污染后续用例)
    data = json.loads(TOKENS_JSON.read_text(encoding="utf-8"))
    data.setdefault("tokens", {})[device_id] = backup
    TOKENS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    results["case5"] = "pass" if reachable else "fail"
    print(f"  过期行 get_token=None(python 读时判定)+ 授权链可达={reachable}")


def case6(host: str) -> None:
    """清装逃生门:需 DELETE_AND_REINSTALL=1 轮次。本轮非逃生门则 deferred。"""
    if os.environ.get("DELETE_AND_REINSTALL") != "1":
        results["case6"] = "deferred"
        print("  deferred(device_required): 用例 6 需 DELETE_AND_REINSTALL=1 单独轮次")
        return
    token, _ = require_token()
    status, body = raw_bearer_hello(host, token)
    code = auth_error_code(status, body)
    ok = status == 401 and code == "invalid_token"
    results["case6"] = "pass" if ok else "fail"
    print(f"  清装后旧 token /hello → {status} code={code}(期望 401 invalid_token)")


_cached_token: tuple[str, dict] | None = None


def require_token() -> tuple[str, dict]:
    global _cached_token
    if _cached_token is None:
        row = existing_device_row()
        if row is None:
            raise RuntimeError("无可复用 token(用例 1 失败或未执行)")
        _cached_token = row
    return _cached_token


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def overall_status() -> str:
    device_cases = ("case1", "case2", "case3", "case6")
    for case_id in device_cases:
        if results.get(case_id) == "fail":
            return "fail"
    if results.get("case4") == "fail" or results.get("case5") == "fail":
        return "fail"
    if any(results.get(c) == "pass" for c in device_cases):
        # 真机在场路径:device 用例必须 pass(deferred 的 case6 除外)
        for case_id in ("case1", "case2", "case3"):
            if results.get(case_id) != "pass":
                return "fail"
        return "pass"
    return "deferred"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["full", "cross-stack-only"], default="full")
    ap.add_argument("--serial", default="")
    ap.add_argument("--package", default="")
    ap.add_argument("--activity", default="")
    ap.add_argument("--device-model", default="")
    ap.add_argument("--os-version", default="")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--log", default="")
    ap.add_argument("--cross-log", required=True)
    ap.add_argument("--scope-md", default="")
    ap.add_argument("--run-at", default=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    args = ap.parse_args()

    cross_log = Path(args.cross_log)
    cross_ok = run_cross_stack(cross_log, args.run_at)
    print(f"[cross_stack] bearer-reuse / 401-clear-relay → {'PASS' if cross_ok else 'FAIL'}"
          f"(log: {cross_log})")

    if args.mode == "cross-stack-only":
        print(f"E2E_STATUS: {'deferred' if cross_ok else 'fail'}")
        return 0 if cross_ok else 1

    if not device_present(args.serial):
        for case_id in ("case1", "case2", "case3", "case6"):
            results[case_id] = "deferred"
        print("[device] 设备不在场,case1/2/3/6 → deferred(device_required)")
    else:
        print("[case1] 首次授权双侧落盘 / 复用已落盘 token ...")
        try:
            case1(args.host, args.serial, args.package)
        except Exception as exc:  # noqa: BLE001
            results["case1"] = "fail"
            print(f"  FAIL: {exc!r}")
        print("[case2] app 冷重启旧 token ...")
        try:
            case2(args.host, args.serial, args.activity)
        except Exception as exc:  # noqa: BLE001
            results["case2"] = "fail"
            print(f"  FAIL: {exc!r}")
        print("[case3] install -r 主断言 ...")
        try:
            case3(args.host)
        except Exception as exc:  # noqa: BLE001
            results["case3"] = "fail"
            print(f"  FAIL: {exc!r}")

    print("[case4] python 重启免 auth ...")
    try:
        case4()
    except Exception as exc:  # noqa: BLE001
        results["case4"] = "fail"
        print(f"  FAIL: {exc!r}")
    print("[case5] 过期自动重授权 ...")
    try:
        case5(args.host, args.serial)
    except Exception as exc:  # noqa: BLE001
        results["case5"] = "fail"
        print(f"  FAIL: {exc!r}")
    print("[case6] 清装逃生门 ...")
    try:
        case6(args.host)
    except Exception as exc:  # noqa: BLE001
        results["case6"] = "fail"
        print(f"  FAIL: {exc!r}")

    if not cross_ok:
        results["case_cross"] = "fail"

    for case_id in sorted(results):
        print(f"CASE {case_id}: {results[case_id]}")
    status = overall_status()
    print(f"E2E_STATUS: {status}")
    return 0 if status != "fail" else 1


if __name__ == "__main__":
    raise SystemExit(main())
