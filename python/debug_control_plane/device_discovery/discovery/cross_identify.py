"""USB ⊕ LAN 交叉识别服务 (R020-BF006).

职责 (design §3.4 + D7): 把 BF004 USB 身份候选 (UsbCandidate) 与 BF005 LAN
响应候选 (LanCandidate) 做**交叉识别**, 产出 ``DeviceRecord`` 列表供调用方
(BF001/BF007) ``DevicePool.upsert``.

设计要点 (D7 分层兜底链 + D9 device_id 来源 + analysis iOS/Android 差异):

  * **纯函数无 I/O** (decision 5): ``identify`` 只做匹配逻辑, 不触网不调命令.
    所有 I/O 在 BF004 (USB) / BF005 (LAN) 已完成. 输入是 frozen dataclass,
    本服务不改输入 (返回新 list).
  * **device_id 取 USB 身份** (D9): ``DeviceRecord.device_id`` = UsbCandidate
    的 adb serial (Android) / usbmuxd id (iOS). **绝不**用 ``LanCandidate
    .network_target.device_id`` (R019 /hello.deviceId 是固定字符串
    ``gmacro-virtual-iOS``, 多设备撞).
  * **分层兜底** (D7, 逐层降级):
      层 1 — 单设备 1对1 (usb 1 + lan 1 直接合并)
      层 2 — Android serial 强匹配 (android_lan_ip ↔ host 精确 IP)
      层 3 — 多设备桥梁字段匹配 (hardware_name + machine_id 各异)
      层 4 — iOS 同型号同名靠 USB 物理在不在 (插着的优先)
      层 5 — 仍歧义 → ambiguous 标记 (label 加 [ambiguous] 前缀 + note)
  * **ambiguous 不强行猜** (D7 核心): 无法消歧时不随机绑定, 标 ``[ambiguous]``
    交上层 (AI/开发者/BF007 人指认) 决策, 避免错误绑定.

Android vs iOS 身份强度差异 (analysis §设备身份桥梁字段):
  * Android: ``android_lan_ip`` (USB 经 adb ip route 精确拿) ↔ LAN host 强唯一,
    直接闭环. 多设备靠 IP 强匹配, 不依赖 FF001 桥梁字段.
  * iOS: 无 ``android_lan_ip`` (恒 None), 靠 ``hardware_name`` + ``machine_id``
    (FF001) 匹配, 弱唯一 — 多台同型号同名无法区分 → ambiguous.

设计来源:
  - tasks: .dev-flow/R020/mcp-bridge-device-discovery-tasks.md BF006 节
  - design: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-backend.md
            §3.4 CrossIdentify + §5.1 全链路 + D7 + D9
  - analysis: .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery.md
            §设备身份桥梁字段
  - test:  .dev-flow/R020/analysis/2026-08-08--mcp-bridge-device-discovery-test.md §2.1
"""

from __future__ import annotations

from enum import Enum

from ..device_pool import DEFAULT_TTL, DeviceRecord
from .lan_scan import LanCandidate
from .usb_identity import UsbCandidate

# ---------------------------------------------------------------------------
# MatchReason — 标识每条 record 用了哪一层匹配 (诊断/可观测, 非业务依赖)
# ---------------------------------------------------------------------------


class MatchReason(str, Enum):
    """交叉识别命中层级 (D7 分层兜底链).

    继承 ``str`` 让 ``==`` 与字符串比较直通 (诊断日志友好); 不参与业务逻辑,
    仅用于 ``identify_with_reason`` 返回值供上层 (BF001/BF007) 观测/日志.
    """

    SINGLE_DEVICE = "single_device"
    """层 1: 单设备 USB 1 + LAN 1 直接合并 (无歧义)."""

    ANDROID_IP = "android_ip"
    """层 2: Android android_lan_ip ↔ LanCandidate.host 精确 IP 强匹配."""

    BRIDGE_FIELD = "bridge_field"
    """层 3: hardware_name + machine_id (FF001) 桥梁字段精确匹配."""

    AMBIGUOUS = "ambiguous"
    """层 5: 无法消歧 (iOS 同型号同名 / 桥梁字段撞车) → 标记不强行猜."""


# ---------------------------------------------------------------------------
# CrossIdentify 服务
# ---------------------------------------------------------------------------


#: ambiguous 标记前缀 (label/note). D7 核心: 不强行猜, 交上层决策.
_AMBIGUOUS_PREFIX = "[ambiguous]"

#: ambiguous note 说明 (供上层 AI/开发者识别并降级到 BF007 人指认).
_AMBIGUOUS_NOTE = (
    "cross-identify ambiguous: 无法区分多设备 (同型号同名 / 桥梁字段撞车), "
    "请用 register_device 人工指认."
)


class CrossIdentify:
    """USB ⊕ LAN 交叉识别服务 (纯函数, 无 I/O).

    入口:
      * :meth:`identify` — 返回 ``list[DeviceRecord]`` (主入口)
      * :meth:`identify_with_reason` — 返回 ``list[tuple[DeviceRecord, MatchReason]]``
        (诊断层, 供观测哪一层命中)

    本服务**不**直接调 ``DevicePool.upsert`` (BF006 只产 DeviceRecord 供调用方
    upsert). ``last_seen`` / ``ttl`` 由 ``DevicePool`` 构造时填 (BF006 留 None
    + DEFAULT_TTL 默认值, 见 device_pool.DeviceRecord 字段默认).

    Example::

        svc = CrossIdentify()
        records = svc.identify(usb_candidates, lan_candidates)
        for rec in records:
            pool.upsert(rec)  # 调用方负责入池
    """

    def identify(
        self,
        usb: list[UsbCandidate],
        lan: list[LanCandidate],
    ) -> list[DeviceRecord]:
        """USB ⊕ LAN 交叉识别 → ``DeviceRecord`` 列表 (D7 分层兜底).

        Args:
            usb: BF004 产出的 USB 身份候选列表 (frozen, 本方法不改).
            lan: BF005 产出的 LAN 响应候选列表 (frozen, 本方法不改).

        Returns:
            新建的 ``DeviceRecord`` 列表 (与输入列表独立, 不共享引用).
            ``device_id`` = USB 身份 (D9). ``source="auto"``. ambiguous 的 record
            label 加 ``[ambiguous]`` 前缀 + note 说明 (D7 不强行猜).
        """
        return [rec for rec, _ in self.identify_with_reason(usb, lan)]

    def identify_with_reason(
        self,
        usb: list[UsbCandidate],
        lan: list[LanCandidate],
    ) -> list[tuple[DeviceRecord, MatchReason]]:
        """交叉识别 (含 MatchReason 诊断层).

        实现按 D7 分层兜底链逐层抽取已匹配的 (usb, lan) 对, 剩余无法消歧的进
        ambiguous (层 5). **关键**: 每层从剩余池中**移除**已匹配的项, 不重复配.

        Returns:
            ``[(DeviceRecord, MatchReason), ...]``. 列表长度 = 成功合并的对数 +
            ambiguous 标记的 record 数 (ambiguous 仍入池供上层决策, 但带标记).
        """
        # 不动输入列表, 用本地工作副本 (frozen dataclass 本身不可变, 但列表可变;
        # 我们不修改入参 list, 拷贝一份).
        remaining_usb: list[UsbCandidate] = list(usb)
        remaining_lan: list[LanCandidate] = list(lan)
        results: list[tuple[DeviceRecord, MatchReason]] = []

        # ----- 层 2: Android android_lan_ip ↔ host 强匹配 (先于层 1 判定,
        # 因 Android IP 强匹配比单设备 1对1 兜底更精确, reason 应标 ANDROID_IP) -----
        results.extend(
            self._match_android_ip_strong(remaining_usb, remaining_lan)
        )

        # 单边耗尽 (USB 或 LAN 全已配) → 提前返回
        if not remaining_usb or not remaining_lan:
            return results

        # ----- 层 1: 单设备 1对1 直接合并 (退化兜底, 无 Android IP 强匹配时) -----
        # 注意: Android 有 android_lan_ip 但与所有 LAN host 都不符 (USB 缓存陈旧)
        # 时, 不强行合并 — 让上层降级 (手机切了 WiFi, 等 TTL 重发现).
        # 此处两侧均非空 (上面已判 not remaining_*), 若都是单元素则 1对1 合并;
        # 否则 (如 2+2) 落到层 3 桥梁字段匹配.
        if len(remaining_usb) == 1 and len(remaining_lan) == 1:
            sole_usb = remaining_usb[0]
            if (
                sole_usb.platform == "android"
                and sole_usb.android_lan_ip is not None
                and sole_usb.android_lan_ip != remaining_lan[0].host
            ):
                # Android USB 报的 IP 与 LAN host 不符, 不强行猜 → 返回已匹配的
                return results
            results.append(
                self._merge(
                    sole_usb,
                    remaining_lan[0],
                    MatchReason.SINGLE_DEVICE,
                )
            )
            return results

        # ----- 层 3: 桥梁字段 (hardware_name + machine_id) 精确匹配 -----
        results.extend(
            self._match_bridge_fields(remaining_usb, remaining_lan)
        )

        if not remaining_usb or not remaining_lan:
            return results

        # ----- 层 4/5: iOS 同型号同名 / 无桥梁字段 → ambiguous 不强行猜 -----
        # 多对多剩余无法消歧: 不随机绑定, 把 USB 身份标 ambiguous 入池 (D7 核心).
        # 注意: 只为剩余 USB 建 record (LAN 候选没绑定就用不上), 给 AI/开发者
        # 看到设备存在但需要人指认 IP.
        for cand in remaining_usb:
            results.append((self._make_ambiguous(cand), MatchReason.AMBIGUOUS))

        return results

    # ------------------------------------------------------------------
    # 层 2: Android IP 强匹配
    # ------------------------------------------------------------------

    def _match_android_ip_strong(
        self,
        usb_pool: list[UsbCandidate],
        lan_pool: list[LanCandidate],
    ) -> list[tuple[DeviceRecord, MatchReason]]:
        """Android android_lan_ip ↔ LanCandidate.host 精确匹配 (层 2).

        从两个池中抽出 android_lan_ip == lan.host 的对, 移出池, 返回合并结果.
        Android 独有强匹配层 (iOS android_lan_ip 恒 None, 跳过).
        """
        matched: list[tuple[DeviceRecord, MatchReason]] = []
        # 收集要移除的索引 (不在迭代中改 list)
        usb_remove: list[int] = []
        lan_remove: list[int] = []

        for i, u in enumerate(usb_pool):
            if u.platform != "android" or u.android_lan_ip is None:
                continue
            for j, lc in enumerate(lan_pool):
                if j in lan_remove:
                    continue
                if lc.host == u.android_lan_ip:
                    matched.append(
                        self._merge(u, lc, MatchReason.ANDROID_IP)
                    )
                    usb_remove.append(i)
                    lan_remove.append(j)
                    break  # 一台 USB 只配一台 LAN

        # 倒序移除避免索引错位
        for i in sorted(set(usb_remove), reverse=True):
            usb_pool.pop(i)
        for j in sorted(set(lan_remove), reverse=True):
            lan_pool.pop(j)
        return matched

    # ------------------------------------------------------------------
    # 层 3: 桥梁字段 (hardware_name + machine_id) 精确匹配
    # ------------------------------------------------------------------

    def _match_bridge_fields(
        self,
        usb_pool: list[UsbCandidate],
        lan_pool: list[LanCandidate],
    ) -> list[tuple[DeviceRecord, MatchReason]]:
        """hardware_name + machine_id (FF001) 桥梁字段精确匹配 (层 3).

        匹配键: ``network_target.hardware_name`` 与 ``UsbCandidate.model`` (机型
        显示名) 或 machine_id 对应. 由于 USB 侧只有 model 显示名 (Android
        ``model:SM-G991B`` / iOS ``name:iPhone X``), 用 LAN 报的 hardware_name +
        machine_id 联合匹配, 要求两者都能区分 (任一不同即视为不同设备).

        简化策略 (避免误绑): 要求 LAN 报的 (hardware_name, machine_id) 在 lan_pool
        中唯一 (不重复), 才视为可区分; 否则归 ambiguous (层 5).
        """
        matched: list[tuple[DeviceRecord, MatchReason]] = []
        usb_remove: list[int] = []
        lan_remove: list[int] = []

        # 先统计每个 (hw_name, machine_id) 在 lan_pool 出现次数, 多次出现的不参与
        # (无法区分, 留给层 5 ambiguous).
        key_count: dict[tuple[str | None, str | None], int] = {}
        for lc in lan_pool:
            key = self._bridge_key(lc)
            key_count[key] = key_count.get(key, 0) + 1

        for i, u in enumerate(usb_pool):
            for j, lc in enumerate(lan_pool):
                if j in lan_remove:
                    continue
                key = self._bridge_key(lc)
                if key_count.get(key, 0) != 1:
                    continue  # 此 key 在 lan_pool 不唯一, 跳过留给 ambiguous
                if not self._bridge_matches(u, lc):
                    continue
                matched.append(self._merge(u, lc, MatchReason.BRIDGE_FIELD))
                usb_remove.append(i)
                lan_remove.append(j)
                break

        for i in sorted(set(usb_remove), reverse=True):
            usb_pool.pop(i)
        for j in sorted(set(lan_remove), reverse=True):
            lan_pool.pop(j)
        return matched

    @staticmethod
    def _bridge_key(lc: LanCandidate) -> tuple[str | None, str | None]:
        """LAN 候选的桥梁字段联合键 (hardware_name, machine_id)."""
        return (lc.network_target.hardware_name, lc.network_target.machine_id)

    @staticmethod
    def _bridge_matches(usb: UsbCandidate, lan: LanCandidate) -> bool:
        """USB 候选与 LAN 候选的桥梁字段是否匹配 (层 3 核心).

        匹配键: ``UsbCandidate.model`` (机型显示名) ↔ ``network_target.machine_id``
        (机型标识, FF001). 归一化后做前缀/子串匹配, 容忍空格与大小写差异:

          * iOS: USB model ``"iPhone 13"`` ↔ machine_id ``"iPhone13,2"``
            (去空格小写后 ``iphone13`` 是 ``iphone13,2`` 的前缀).
          * Android: USB model ``"SM-G991B"`` ↔ machine_id ``"SM-G991B"``
            (完全相等).

        ``hardware_name`` (用户自定义设备名) **不直接比对** USB model (用户可改),
        但作为 ``_bridge_key`` 联合键参与唯一性判定 (见 ``_match_bridge_fields``).

        老 app 无桥梁字段 (hardware_name=None & machine_id=None) → 返回 False,
        让上层降级到层 5 ambiguous (多设备) 或层 1 (单设备 1对1 已先判定).
        """
        mid = lan.network_target.machine_id
        if mid is None:
            # 无 machine_id (老 app 或 iOS 未报机型) → 无法机型级匹配
            return False
        return _normalize_model(usb.model) in _normalize_model(mid)

    # ------------------------------------------------------------------
    # 合并 (单台 USB + 单台 LAN → DeviceRecord)
    # ------------------------------------------------------------------

    @staticmethod
    def _merge(
        usb: UsbCandidate,
        lan: LanCandidate,
        reason: MatchReason,
    ) -> tuple[DeviceRecord, MatchReason]:
        """合并 USB 身份 + LAN 响应 → DeviceRecord (D9: device_id=USB 身份).

        字段填充:
          * device_id = UsbCandidate.device_id (D9, 绝不用 /hello.deviceId)
          * label = LAN hardware_name (FF001 真实设备名) 或 USB model (fallback)
          * source = "auto"
          * last_known_host = LanCandidate.host
          * last_seen = None (时间由 DevicePool 在 upsert 时填, BF006 不持久化时间)
          * ttl = DEFAULT_TTL (DevicePool 默认, BF006 不自定义)
          * platform / hardware_name / machine_id 从 LAN network_target 填
        """
        nt = lan.network_target
        # label: FF001 hardware_name 优先 (用户可读设备名), 否则 USB model
        label = nt.hardware_name or usb.model
        return (
            DeviceRecord(
                device_id=usb.device_id,
                label=label,
                source="auto",
                # memory-only IP state (BF006 不持久化时间, last_seen 留 None)
                last_known_host=lan.host,
                last_seen=None,
                ttl=DEFAULT_TTL,
                # FF001 桥梁字段 (从 LAN network_target)
                hardware_name=nt.hardware_name,
                machine_id=nt.machine_id,
                platform=usb.platform,
                # network_target 留 None: BF006 只产身份+IP, 运行时标签由 BridgeClient
                # 在第一次 /hello probe 时填 (BF001 节点定义, 不在 BF006 范围).
            ),
            reason,
        )

    # ------------------------------------------------------------------
    # 层 5: ambiguous 标记 (不强行猜)
    # ------------------------------------------------------------------

    @staticmethod
    def _make_ambiguous(usb: UsbCandidate) -> DeviceRecord:
        """无法消歧的 USB 候选 → ambiguous 标记的 DeviceRecord (D7 核心).

        device_id 仍来自 USB 身份 (稳定), 但 label 加 ``[ambiguous]`` 前缀 + note
        说明, 让上层 (AI/开发者/BF007) 看到设备存在但需人指认 IP. **不**随机绑定
        LAN 候选 (避免错误绑定, D7 核心原则).
        """
        return DeviceRecord(
            device_id=usb.device_id,
            label=f"{_AMBIGUOUS_PREFIX} {usb.model}",
            source="auto",
            # 无 LAN 绑定 → host/last_seen 留 None (待 BF007 人指认)
            last_known_host=None,
            last_seen=None,
            ttl=DEFAULT_TTL,
            platform=usb.platform,
            note=_AMBIGUOUS_NOTE,
        )


def _normalize_model(s: str) -> str:
    """机型字符串归一化: 去空格 + 小写, 用于 model ↔ machine_id 模糊匹配.

    例: ``"iPhone 13"`` → ``"iphone13"``; ``"iPhone13,2"`` → ``"iphone13,2"``;
    ``"SM-G991B"`` → ``"sm-g991b"``. iOS model 是 machine_id 的前缀时即视为
    同机型 (用户 buy iPhone 13 → machine_id 是 iPhone13,x 之一).
    """
    return s.replace(" ", "").lower()


__all__ = [
    "CrossIdentify",
    "MatchReason",
]
