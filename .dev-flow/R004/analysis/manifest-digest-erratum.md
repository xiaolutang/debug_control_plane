---
date: 2026-09-01
type: erratum
requirement_cycle: R004
topic: token-persistence
supersedes_digest: efd0e801f958597aab9c3baf80db40ac4fa57eea3f1cc20136860a58750cb668
corrected_digest: 91ddf0e7c9ecab6003901681184618619e8fdc6e7e275a2f87127710a3d66465
---

# R004 manifest_digest 勘误（revision 5）

## 偏差事实

R004 manifest（revision 4 及之前）存在两项 schema 缺陷：

1. **缺 `integration` 字段**：integration 产物文件
   （`2026-08-31--token-persistence-integration.md`）与 `artifact_slots.integration`
   均存在，但 manifest 顶层从未写入 `integration` 对象（R001-R003 同位置均有）。
2. **缺 `bootstrap_legacy` 字段**（§6.2 projection 必含键）。
3. **`manifest_digest` 停留在登记时刻的中间态**：R004 manifest 分多轮写入
   （rev2 slices → rev3 slots → rev4 review），digest 登记于 rev2 时期的某个
   未存档工作区形态，此后内容演进未重算——对 3 个历史 commit 快照、全部
   2104 个 git blob raw SHA-256、128 种跨 revision 组合投影均无法复现。

## 排除「系统性算法偏差」

用 BF002 contract §6.2 算法（formal v1 projection + canonical JSON：
键按 Unicode code point 递归升序、compact、UTF-8 不转义中文）精确复算：

| RC | manifest_digest 复现 |
|---|---|
| R001 | PASS（8547495e…） |
| R002 | PASS（030e1b3d…） |
| R003 | PASS（caa27b26…） |
| R004 | FAIL（单例偏差，即本勘误对象） |

算法本身正确；R004 是唯一偏差源。

## 修正内容（revision 5）

- 补 `integration` 对象（path/digest/summary/capabilities/split_required/open_issues，
  digest 为 integration 文件 raw SHA-256：`d188af18…`）。
- 补 `bootstrap_legacy: false`。
- 重算 `manifest_digest = 91ddf0e7c9ecab6003901681184618619e8fdc6e7e275a2f87127710a3d66465`
  （§6.2 projection，自检 PASS）。

## 历史记录处置

以下文件中的旧 digest `efd0e801…` 是登记时刻的事实快照，**保持原样不改**
（历史快照只写不改原则）：

- `reviews/2026-08-31T12-00-00-analysis-PASS.md`
- `reviews/2026-08-31T13-30-00-design-PASS.md`
- `reviews/2026-08-31T18-10-00-plan-PASS.md`
- `token-persistence-tasks.md` frontmatter `analysisManifestDigest`

下游以本勘误 + manifest revision 5 为准。
