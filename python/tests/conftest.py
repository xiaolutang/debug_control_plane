"""Pytest config for debug_control_plane(AD-B2,D8 path 注入删除).

BF007 后:测试依赖经 ``pip install -e .`` 装入,正经包 import,不再走
运行时路径注入(原 D8 monorepo sibling 注入已删;device_discovery +
mcp_plane 都在新 repo debug_control_plane 内,正向包 import)。

保留:本文件作为 pytest fixture/conftest 锚点(未来 plugin 注册点)。
"""

from __future__ import annotations
