#!/usr/bin/env bash
# debug_control_plane 标准发版流程（R026 后固化）
#
# 用法: bash tool/release.sh <stage>
#   preflight        发版前置自检（权限/干净树/版本一致性/本地全量门）
#   push             push 当前分支 + 等线上 CI 绿
#   merge            fast-forward 合入 main + push + 等绿
#   tag              RC 完整性检查 + config 状态推进 + 按 kotlin 版本打 vX.Y.Z
#                    + push tag/main + 等 tag CI 绿
#   jitpack          轮询 JitPack 构建状态 + 验证坐标可解析
#   pubdev-flip      插件切 JitPack 坐标（改 pubspec/gradle，只改不 commit）
#   pubdev-publish   flutter pub publish（dry-run 先行，最终发布交互确认）
#   status           总览：本地/远程/CI/JitPack 状态一行一条
#
# 设计约束：
# - 每阶段幂等可重跑；失败停在原地，修完重跑该阶段即可
# - 不可逆动作（pub publish）前置 --dry-run + 人工确认
# - 版本 SSOT = kotlin/build.gradle.kts 的 version = "X.Y.Z"
# - tag stage 同步推进 .dev-flow/config.json 的 release_management
#   （releases[v]=released + project_version bump + 新 in-progress 占位），
#   config commit 与 tag 分离：tag 指向纯版本号 commit

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="${REMOTE:-origin}"
GITHUB_REPO="xiaolutang/debug_control_plane"
KOTLIN_VERSION="$(grep -m1 '^version = "' "$REPO_ROOT/kotlin/build.gradle.kts" | sed 's/version = "\([^"]*\)".*/\1/')"
TAG="v$KOTLIN_VERSION"
BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"

# 轮询辅助: poll <描述> <命令>  — 命令输出含 ok/PASS/success/HTTP 2xx 即成功
poll() {
  local desc="$1" cmd="$2" i
  for i in $(seq 1 "${POLL_TRIES:-40}"); do
    local out
    out="$(eval "$cmd" 2>/dev/null || true)"
    case "$out" in
      *ok*|*PASS*|*success*|*COMPLETED*) echo "  ✓ $desc"; return 0 ;;
      "HTTP/2 2"*|"HTTP/1.1 2"*) echo "  ✓ $desc"; return 0 ;;  # curl -I 状态行 2xx
      *error*|*FAIL*) echo "  ✗ $desc: $out" >&2; return 1 ;;
    esac
    sleep "${POLL_INTERVAL:-15}"
  done
  echo "  ✗ $desc: 超时（${POLL_TRIES:-40} 次 × ${POLL_INTERVAL:-15}s）" >&2
  return 1
}

wait_ci_green() {  # wait_ci_green <ref>
  local ref="$1" run_id
  sleep 5
  run_id="$(gh run list -R "$GITHUB_REPO" --branch "$ref" --limit 1 --json databaseId,status,conclusion --jq '.[0].databaseId')" || true
  if [[ -z "${run_id:-}" ]]; then echo "  ✗ 找不到 $ref 的 CI run"; return 1; fi
  echo "  … watching run $run_id"
  gh run watch "$run_id" -R "$GITHUB_REPO" --exit-status >/dev/null
  echo "  ✓ CI 绿 ($ref)"
}

stage_preflight() {
  echo "== preflight =="
  # 1. gh 登录 + workflow scope（push workflow 文件的硬前置）
  local scopes
  scopes="$(gh auth status 2>&1 | grep -o "Token scopes:.*" || true)"
  echo "  $scopes"
  [[ "$scopes" == *workflow* ]] || { cat <<'EOF'
  ✗ token 缺 workflow scope —— push .github/workflows/ 会被 GitHub 拒绝
    修复: gh auth refresh -s workflow （浏览器输 8 位码授权）
EOF
    return 1; }
  # 2. 工作树干净（未跟踪构建产物豁免）
  local dirty
  dirty="$(git -C "$REPO_ROOT" status --short | grep -v '^??' || true)"
  [[ -z "$dirty" ]] || { echo "  ✗ 工作树有未提交改动:"; echo "$dirty"; return 1; }
  # 3. 版本一致性
  echo "  kotlin version = $KOTLIN_VERSION → tag = $TAG"
  [[ "$KOTLIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "  ✗ 版本号格式不对: $KOTLIN_VERSION"; return 1; }
  # 4. 本地全量门
  (cd "$REPO_ROOT" && bash ci/ci-check-all.sh >/dev/null) && echo "  ✓ ci-check-all 7/7"
  (cd "$REPO_ROOT/flutter_debug_control_plane/android" \
    && "$REPO_ROOT/kotlin/gradlew" -p . testDebugUnitTest >/dev/null 2>&1) \
    && echo "  ✓ plugin testDebugUnitTest"
  echo "  preflight PASS — 可执行: bash tool/release.sh push"
}

stage_push() {
  echo "== push $BRANCH =="
  git -C "$REPO_ROOT" push -u "$REMOTE" "$BRANCH"
  wait_ci_green "$BRANCH"
  echo "  push PASS — 可执行: bash tool/release.sh merge"
}

stage_merge() {
  echo "== merge → main =="
  git -C "$REPO_ROOT" fetch "$REMOTE" main
  git -C "$REPO_ROOT" merge-base --is-ancestor "$REMOTE/main" "$BRANCH" \
    || { echo "  ✗ 不能 fast-forward（main 有分叉），先人工处理"; return 1; }
  git -C "$REPO_ROOT" checkout main
  git -C "$REPO_ROOT" merge --ff-only "$BRANCH"
  git -C "$REPO_ROOT" push "$REMOTE" main
  wait_ci_green main
  git -C "$REPO_ROOT" checkout "$BRANCH"
  echo "  merge PASS — 可执行: bash tool/release.sh tag"
}

stage_tag() {
  echo "== tag $TAG =="
  if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "  tag $TAG 已存在（本机）—— 若是重打请先 git tag -d $TAG"
    return 1
  fi
  # 本阶段在 main 上执行（config commit 直接推 main；merge stage 已回 $BRANCH，这里切回）
  if [[ "$BRANCH" != "main" ]]; then
    git -C "$REPO_ROOT" checkout main
  fi
  # ── 1. RC 完整性 + config 状态检查（xlfoundry release_management）──
  local rel_status rc_ids completed
  read -r rel_status rc_ids completed <<<"$(python3 - "$KOTLIN_VERSION" <<'PYEOF'
import json, sys
v = sys.argv[1]
rel = json.load(open(".dev-flow/config.json"))["release_management"]["releases"].get(v)
if not rel:
    print("MISSING", "", ""); raise SystemExit
print(rel.get("status"), ",".join(rel.get("rc_ids", [])), ",".join(rel.get("completed_rcs", [])))
PYEOF
)"
  if [[ "$rel_status" == "MISSING" ]]; then
    echo "  ✗ releases[$KOTLIN_VERSION] 不存在于 .dev-flow/config.json（先走 xlfoundry 归档/发布准备）"
    return 1
  fi
  if [[ "$rel_status" != "in-progress" ]]; then
    echo "  ✗ releases[$KOTLIN_VERSION].status=${rel_status} (只有 in-progress 可发布)"
    return 1
  fi
  if [[ "$rc_ids" != "$completed" ]] && [[ "${FORCE_RC:-0}" != "1" ]]; then
    echo "  ✗ 未完成 RC：rc_ids=[${rc_ids}] completed=[${completed}]（FORCE_RC=1 可覆盖）"
    return 1
  fi
  echo "  ✓ releases[$KOTLIN_VERSION] in-progress，RC 完整"
  # ── 2. 打 tag（指向当前 HEAD=版本号 commit）+ push + 等 CI ──
  git -C "$REPO_ROOT" tag -a "$TAG" -m "Release $TAG (kotlin core $KOTLIN_VERSION)"
  git -C "$REPO_ROOT" push "$REMOTE" "$TAG"
  # ── 3. config 状态推进（releases[v]=released + project_version bump + 新占位）──
  python3 - "$KOTLIN_VERSION" <<'PYEOF'
import json, sys, datetime
v = sys.argv[1]
p = ".dev-flow/config.json"
c = json.load(open(p))
rm = c["release_management"]
a, b, d = (int(x) for x in v.split("."))
bump = rm.get("version_bump", "minor")
new_v = {"major": f"{a+1}.0.0", "minor": f"{a}.{b+1}.0", "patch": f"{a}.{b}.{d+1}"}[bump]
rm["releases"][v]["status"] = "released"
rm["releases"][v]["released_at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
rm["project_version"] = new_v
rm["releases"][new_v] = {"status": "in-progress", "rc_ids": [], "completed_rcs": [], "released_at": None}
json.dump(c, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
print(f"  ✓ config: {v}=released, project_version→{new_v}")
PYEOF
  git -C "$REPO_ROOT" add .dev-flow/config.json
  git -C "$REPO_ROOT" commit -m "chore(release): v${KOTLIN_VERSION} released (project_version 推进)" >/dev/null
  git -C "$REPO_ROOT" push "$REMOTE" main
  wait_ci_green "$TAG"   # H1: tag push 过同一套 CI 门
  echo "  tag PASS — 可执行: bash tool/release.sh jitpack"
}

stage_jitpack() {
  echo "== jitpack $TAG =="
  # 触发构建（首次 GET 即排队）
  curl -fsSL "https://jitpack.io/com/github/xiaolutang/debug_control_plane/$KOTLIN_VERSION/" >/dev/null 2>&1 || true
  poll "JitPack build $TAG" \
    "curl -fsSL 'https://jitpack.io/api/builds/com.github.xiaolutang/debug_control_plane' | grep -o '\"$KOTLIN_VERSION\"[[:space:]]*:[[:space:]]*\"ok\"'"
  # 坐标验证（实测 v0.2.0 归档形态）:JitPack 单模块 repo 的消费坐标是
  # com.github.{user}:{repo}:{ver}(不是 gradle publication 名 {user}.{repo}:kotlin),
  # pom 落在 /com/github/{user}/{repo}/{ver}/{repo}-{ver}.pom
  poll "maven 坐标可解析" \
    "curl -fsSI 'https://jitpack.io/com/github/xiaolutang/debug_control_plane/$KOTLIN_VERSION/debug_control_plane-$KOTLIN_VERSION.pom' | head -1 | grep 200"
  cat <<EOF
  ✓ JitPack 就绪，消费端坐标:
     implementation("com.github.xiaolutang:debug_control_plane:$KOTLIN_VERSION")
  下一步: bash tool/release.sh pubdev-flip
EOF
}

stage_pubdev_flip() {
  echo "== pubdev-flip =="
  local pub="$REPO_ROOT/flutter_debug_control_plane/pubspec.yaml"
  local gradle="$REPO_ROOT/flutter_debug_control_plane/android/build.gradle.kts"
  local settings="$REPO_ROOT/flutter_debug_control_plane/android/settings.gradle.kts"
  [[ "$KOTLIN_VERSION" != "0.2.0" || -d "$REPO_ROOT/../pantas_launcher" ]] || true
  # 1. pubspec: publish_to 删除 + version 0.1.0
  sed -i.bak -e "/^publish_to: 'none'$/d" -e 's/^version: 0\.0\.1$/version: 0.1.0/' "$pub" && rm -f "$pub.bak"
  # 2. gradle: composite build 坐标 → JitPack maven 坐标（实测归档形态
  #    com.github.{user}:{repo}:{ver}，见 stage_jitpack 注释）
  sed -i.bak "s#implementation(\"com.pantas.debug.controlplane:core\")#implementation(\"com.github.xiaolutang:debug_control_plane:$KOTLIN_VERSION\")#" "$gradle" && rm -f "$gradle.bak"
  # 3. settings: 去 includeBuild substitution;jitpack maven repo 加到 build.gradle.kts
  #    的 allprojects.repositories(依赖解析层)——加在 settings.pluginManagement 只管
  #    插件解析,依赖坐标仍解析不到(flip 编译失败的根因)
  sed -i.bak '/dependencySubstitution/,/^}$/d; /substitute(module/d; /includeBuild("\.\.\/\.\.\/kotlin") {/d' "$settings" && rm -f "$settings.bak"
  grep -q "jitpack.io" "$gradle" || sed -i.bak2 's#^\( *\)repositories {#\1repositories {\n            maven { url = uri("https://jitpack.io") }#' "$gradle" && rm -f "$gradle.bak2"
  echo "  已改 3 文件（未 commit）。本地验证编译："
  (cd "$REPO_ROOT/flutter_debug_control_plane/android" \
    && "$REPO_ROOT/kotlin/gradlew" -p . assembleDebug >/dev/null 2>&1) \
    && echo "  ✓ 插件 android 模块可编译（拉 JitPack 坐标）" \
    || echo "  ✗ 编译失败 —— 检查 JitPack 坐标/settings 仓库顺序"
  echo "  确认 diff 后: git add -A && git commit，然后 bash tool/release.sh pubdev-publish"
}

stage_pubdev_publish() {
  echo "== pubdev-publish =="
  command -v fvm >/dev/null && FLUTTER="fvm stable flutter" || FLUTTER="flutter"
  (cd "$REPO_ROOT/flutter_debug_control_plane" \
    && $FLUTTER pub publish --dry-run) || { echo "  ✗ dry-run 失败"; return 1; }
  read -r -p "  dry-run OK。发布到 pub.dev 不可撤，输入 yes 发布: " ans
  [[ "$ans" == "yes" ]] || { echo "  已取消"; return 1; }
  (cd "$REPO_ROOT/flutter_debug_control_plane" && $FLUTTER pub publish)
  echo "  ✓ pub.dev 发布完成 —— 记得 commit flip 改动 + 更新 CHANGELOG.md"
}

stage_status() {
  echo "== status =="
  echo "  本地分支: ${BRANCH} | kotlin ${KOTLIN_VERSION} | tag ${TAG}"
  local ahead=0
  git -C "$REPO_ROOT" rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null \
    && ahead=$(git -C "$REPO_ROOT" rev-list --count "$REMOTE/$BRANCH..HEAD")
  echo "  待 push: ${ahead} commit(s)"
  gh run list -R "$GITHUB_REPO" --limit 3 2>/dev/null | sed 's/^/  /' || echo "  (gh 不可用)"
  curl -fsSL "https://jitpack.io/api/builds/com.github.xiaolutang/debug_control_plane" 2>/dev/null | head -c 200 | sed 's/^/  jitpack: /' || echo "  jitpack: (不可达)"
  echo
}

case "${1:-}" in
  preflight|push|merge|tag|jitpack) "stage_$1" ;;
  pubdev-flip) stage_pubdev_flip ;;      # 函数名不能带连字符,单独映射
  pubdev-publish) stage_pubdev_publish ;;
  status) stage_status ;;
  *) grep '^#' "$0" | head -14; exit 1 ;;
esac
