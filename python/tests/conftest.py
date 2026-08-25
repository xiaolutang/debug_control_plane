"""Pytest config for debug_control_plane(AD-B2,D8 path 注入删除).

BF007 后:测试依赖经 ``pip install -e .`` 装入,正经包 import,不再走
运行时路径注入(原 D8 monorepo sibling 注入已删;device_discovery +
mcp_plane 都在新 repo debug_control_plane 内,正向包 import)。

保留:本文件作为 pytest fixture/conftest 锚点(未来 plugin 注册点)。
"""

from __future__ import annotations

import pytest


def pytest_addoption(parser: pytest.Parser) -> None:
    """R002-BF005: example app acceptance endpoint 参数(--endpoint)。

    option 优先, env ACCEPTANCE_ENDPOINT 兜底; 消费逻辑见
    tests/test_acceptance_flutter_app_auth.py 的 endpoint fixture。
    """
    group = parser.getgroup("acceptance")
    group.addoption(
        "--endpoint",
        action="store",
        default=None,
        metavar="URL",
        help="Running example app Dart plane endpoint "
        "(falls back to env ACCEPTANCE_ENDPOINT).",
    )


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line(
        "markers", "auth_denied_driver: needs a flutter-side deny driver"
    )
