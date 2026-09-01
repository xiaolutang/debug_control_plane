#!/bin/bash
# release.sh — 发布操作一键化（xlfoundry-archive「发布操作」+ git tag + push）
# 用法: release.sh <版本号>
#   release.sh 0.5.0     # 发布 0.5.0：config 状态推进 + 四端版本校验 + tag + push
# 前置:
#   - .dev-flow/config.json 存在 release_management
#   - releases[v].status == "in-progress" 且 completed_rcs == rc_ids
#   - 工作区干净（版本 commit 已提交）
# 步骤:
#   1. 完整性检查（未完成 RC 需 --force）
#   2. config 更新: releases[v]=released + released_at + project_version 推进 + 新占位
#   3. 四端版本号一致性校验（kotlin/dart/flutter/python vs v）
#   4. git tag v{v}（annotated，指向当前 HEAD）+ push tag
#   5. git push origin main（连同 config commit 一起推）
set -euo pipefail

VERSION="${1:-}"
FORCE=0
[[ "${2:-}" == "--force" ]] && FORCE=1

if [ -z "$VERSION" ]; then
    echo "用法: release.sh <版本号> [--force]"
    echo "  例: release.sh 0.6.0"
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/.dev-flow/config.json"

fail() { echo "❌ $1" >&2; exit 1; }

# ============================================================
# 1. 前置检查
# ============================================================
command -v python3 >/dev/null || fail "缺 python3"
[[ -f "$CONFIG" ]] || fail "config.json 不存在"

# 工作区必须干净（版本号 commit 已完成）
if ! git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet; then
    fail "工作区有未提交改动，先提交版本号变更再发布"
fi

# config 状态检查
read -r STATUS RC_IDS COMPLETED <<<"$(python3 - "$VERSION" <<'EOF'
import json, sys
v = sys.argv[1]
c = json.load(open(".dev-flow/config.json"))
rel = c.get("release_management", {}).get("releases", {}).get(v)
if not rel:
    print("MISSING", "", ""); sys.exit(0)
print(rel.get("status"), " ".join(rel.get("rc_ids", [])), " ".join(rel.get("completed_rcs", [])))
EOF
)"
[[ "$STATUS" != "MISSING" ]] || fail "releases[$VERSION] 不存在于 config.json"
[[ "$STATUS" == "in-progress" ]] || fail "releases[$VERSION].status=${STATUS} (只有 in-progress 可发布)"
if [[ "$RC_IDS" != "$COMPLETED" ]] && [[ $FORCE -eq 0 ]]; then
    echo "❌ 未完成 RC：rc_ids=[${RC_IDS}] completed=[${COMPLETED}]"
    echo "   确认仍要发布请加 --force"
    exit 1
fi

# ============================================================
# 2. 四端版本号一致性校验
# ============================================================
echo "== 四端版本校验 =="
ACTUAL_KOTLIN=$(grep -oE 'version = "0\.[0-9]+\.[0-9]+"' "$ROOT/kotlin/build.gradle.kts" | head -1 | grep -oE '0\.[0-9]+\.[0-9]+')
ACTUAL_KOTLIN2=$(grep -oE 'debug_control_plane:[0-9.]+' "$ROOT/flutter_debug_control_plane/android/build.gradle.kts" | head -1 | grep -oE '[0-9.]+$')
ACTUAL_DART=$(grep -m1 '^version:' "$ROOT/dart/pubspec.yaml" | awk '{print $2}')
ACTUAL_FLUTTER=$(grep -m1 '^version:' "$ROOT/flutter_debug_control_plane/pubspec.yaml" | awk '{print $2}')
ACTUAL_PY=$(grep -m1 '^version' "$ROOT/python/pyproject.toml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

for pair in "kotlin=$ACTUAL_KOTLIN" "plugin-gradle=$ACTUAL_KOTLIN2" "dart=$ACTUAL_DART" "flutter=$ACTUAL_FLUTTER" "python=$ACTUAL_PY"; do
    name="${pair%%=*}"; val="${pair#*=}"
    if [[ "$val" != "$VERSION" ]]; then
        fail "版本不一致: $name=${val} 期望 ${VERSION} (检查各端版本号 commit 是否完成)"
    fi
    echo "  ✓ $name=$val"
done

# ============================================================
# 3. tag + 推送（在 config 变更 commit 之前打 tag，
#    tag 指向纯版本号 commit，不带 config 状态文件）
# ============================================================
TAG="v$VERSION"
if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "⚠️  tag $TAG 已存在，跳过打 tag"
else
    HEAD_MSG=$(git -C "$ROOT" log -1 --format=%s)
    git -C "$ROOT" tag -a "$TAG" -m "Release $VERSION

$HEAD_MSG"
    echo "== tag $TAG → $(git -C "$ROOT" rev-parse --short HEAD) =="
    git -C "$ROOT" push origin "$TAG"
fi

# ============================================================
# 4. config 更新: released + project_version 推进 + 新占位
# ============================================================
python3 - "$VERSION" <<'EOF'
import json, sys, datetime
v = sys.argv[1]
p = ".dev-flow/config.json"
c = json.load(open(p))
rm = c["release_management"]
c["releases"] = rm["releases"]
# bump 规则: minor → 第 2 位 +1; patch → 第 3 位 +1; major → 第 1 位 +1
a, b, d = (int(x) for x in v.split("."))
bump = rm.get("version_bump", "minor")
new_v = {"major": f"{a+1}.0.0", "minor": f"{a}.{b+1}.0", "patch": f"{a}.{b}.{d+1}"}[bump]
c["releases"][v]["status"] = "released"
c["releases"][v]["released_at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
c["project_version"] = new_v
c["releases"][new_v] = {"status": "in-progress", "rc_ids": [], "completed_rcs": [], "released_at": None}
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
print(f"config: {v}=released, project_version→{new_v}")
EOF

git -C "$ROOT" add "$CONFIG"
git -C "$ROOT" commit -m "chore(release): v${VERSION} released (project_version 推进)

Co-Authored-By: Claude <noreply@anthropic.com>" >/dev/null
git -C "$ROOT" push origin main

echo ""
echo "✅ $VERSION 发布完成: config=released | tag=$TAG 已推送 | main 已推送"
echo "   （pub.dev ×2 / PyPI / JitPack 的包发布仍需手动执行）"
