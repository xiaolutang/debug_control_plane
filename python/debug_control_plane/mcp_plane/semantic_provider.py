"""SemanticProvider — pluggable hook for known-capability sugar (BF002).

R020 capability_mirror 语义糖接口固化。
本轮(R021-BF002)将 R020 既有 Protocol 抽出固化到独立 repo,作为契约源头迁移
(非新设计 — R020 BF010 hook 已落地代码)。

E 方案(OI-B1 resolved):平面 legacy 路径对每 capability tag 生成 sentinel
``CapabilitySchema``(``capability_id=tag``, 空 ``resources``/``commands``)交
``provider.matches`` 认领;业务 provider 内部按 tag→capability 映射产 tools。
本契约**不扩** ``propose_schemas`` 钩子(YAGNI)。

类型引用说明:
    ``CapabilitySchema`` / ``ToolSpec`` 已迁入 ``capability_mirror.py``(BF007)。
    本模块用 ``TYPE_CHECKING`` 守卫 import 它们供静态分析器解析(消除 ruff F821);
    运行时签名靠 ``from __future__ import annotations`` 字符串化,守卫块不执行,
    不产生循环 import(``capability_mirror`` 不反向 import 本模块)。
"""
from __future__ import annotations

from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from .capability_mirror import CapabilitySchema, ToolSpec


class SemanticProvider(Protocol):
    """Builds semantic-sugar tools for a known capability.

    业务侧(BF010)实现此协议，并通过 ``providers`` 构造参数把实例注册到
    :class:`CapabilityMirror`。BF009 不内置 provider —— 钩子本身由 BF009 自己
    的测试用 stub 验证。

    Contract:
        * :meth:`matches` is called once per parsed schema; return ``True`` if
          this provider owns the capability (it then gets to build tools for
          it). ``legacy_capabilities`` is the static ``/hello.capabilities``
          frozenset (legacy/degrade mode); providers may match on it when no
          structured schema is present (e.g. ``virtual_input`` heuristic).
        * :meth:`build_tools` returns the manifest entries for the matched
          capability. The schema is the structured mirror (when present) or a
          synthetic legacy schema (capability_id set, empty resources/commands)
          so providers don't have to special-case legacy mode.
    """

    def matches(
        self,
        schema: CapabilitySchema,
        *,
        legacy_capabilities: frozenset[str] | None = None,
    ) -> bool:
        """Return True if this provider owns the given capability."""
        ...

    def build_tools(self, schema: CapabilitySchema) -> list[ToolSpec]:
        """Return the semantic-sugar tools for the matched capability."""
        ...
