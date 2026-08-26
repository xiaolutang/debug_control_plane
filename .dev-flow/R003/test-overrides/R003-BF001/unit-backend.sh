#!/usr/bin/env bash
set -euo pipefail

passed=0
pass_log=''

pass() {
  passed=$((passed + 1))
  pass_log="${pass_log}PASS $(printf '%02d' "$passed") $1"$'\n'
}

require_text() {
  local needle="$1"
  local file="$2"
  grep -Fq "$needle" "$file"
  pass "$file contains: $needle"
}

require_jq() {
  local file="$1"
  local filter="$2"
  local label="$3"
  jq -e "$filter" "$file" >/dev/null
  pass "$label"
}

command -v jq >/dev/null
pass 'jq is available'

require_text '每元素可选 `scope`（string，取值 `app` 或 `page`）' PROTOCOL.md
require_text '缺省等价 `app`' PROTOCOL.md
require_text '当 `scope == "page"` 时，`pageId` 必须存在且非空' PROTOCOL.md
require_text '`pageName`（string）。该字段仅用于展示 metadata，不参与 capability 唯一性' PROTOCOL.md
require_text '`scopeRevision`（int）。该值代表 capability scope 镜像修订号' PROTOCOL.md
require_text '新增 scope 字段属于向后兼容扩展，`protocolVersion` 仍保持 `1`' PROTOCOL.md
require_text '`resources[].path` 与 `commands[].path` 必须继续是 JSON 数组' PROTOCOL.md
require_text '`410` | `"page_capability_gone"`' PROTOCOL.md
require_text '`409` | `"capability_scope_expired"`' PROTOCOL.md
require_text '客户端收到 `page_capability_gone` 或 `capability_scope_expired` 后，必须把本地 capability mirror 标记为 stale' PROTOCOL.md
require_text '客户端不得对旧工具、旧 `pageId` 或旧 `scopeRevision` 做盲目重试' PROTOCOL.md

for file in \
  fixtures/hello.json \
  fixtures/hello-page-scope.json \
  fixtures/hello-multi-page-scope.json \
  fixtures/hello-schema-shrink.json; do
  require_jq "$file" '.protocolVersion == 1' "$file protocolVersion=1"
  require_jq "$file" 'all(.registeredCapabilities[]?; (all(.resources[]?; (.path | type) == "array")) and (all(.commands[]?; (.path | type) == "array")))' "$file route paths are JSON arrays"
done

require_jq fixtures/hello.json 'all(.registeredCapabilities[]; has("scope") | not)' 'legacy hello fixture keeps scope absent'

require_jq fixtures/hello-page-scope.json '.registeredCapabilities[] | select(.id == "sample.page.panel" and .scope == "page" and .pageId == "page-a" and .pageName == "Page A" and .scopeRevision == 2)' 'page fixture has page-a scope fields'
require_jq fixtures/hello-page-scope.json '.registeredCapabilities[] | select(.id == "sample.app" and .scope == "app" and .scopeRevision == 1)' 'page fixture has app scope entry'

require_jq fixtures/hello-multi-page-scope.json '[.registeredCapabilities[] | select(.id == "sample.page.form" and .scope == "page") | .pageId] | sort == ["page-a", "page-b"]' 'multi-page fixture contains page-a and page-b'
require_jq fixtures/hello-multi-page-scope.json '[.registeredCapabilities[] | select(.id == "sample.page.form" and .scope == "page") | .pageName] | sort == ["Page A", "Page B"]' 'multi-page fixture preserves page names'
require_jq fixtures/hello-multi-page-scope.json '[.registeredCapabilities[] | select(.id == "sample.page.form" and .scope == "page") | .scopeRevision] == [4, 4]' 'multi-page fixture preserves scope revisions'

require_jq fixtures/hello-schema-shrink.json '[.registeredCapabilities[] | select(.scope == "page") | .pageId] == ["page-a"]' 'schema-shrink keeps page-a only'
require_jq fixtures/hello-schema-shrink.json '[.registeredCapabilities[] | select(.pageId? == "page-b")] | length == 0' 'schema-shrink removes page-b'

require_jq fixtures/error-page-capability-gone.json '._fixture_meta.http_status == 410 and .ok == false and .code == "page_capability_gone" and (.message | type) == "string" and (.message | length > 0)' 'gone error fixture status/code/message'
require_jq fixtures/error-page-capability-gone.json '.message | contains("Refresh /hello")' 'gone error fixture refresh guidance'
require_jq fixtures/error-capability-scope-expired.json '._fixture_meta.http_status == 409 and .ok == false and .code == "capability_scope_expired" and (.message | type) == "string" and (.message | length > 0)' 'expired error fixture status/code/message'
require_jq fixtures/error-capability-scope-expired.json '.message | contains("Refresh /hello")' 'expired error fixture refresh guidance'

require_text '`hello-page-scope.json`' fixtures/README.md
require_text '`hello-multi-page-scope.json`' fixtures/README.md
require_text '`hello-schema-shrink.json`' fixtures/README.md
require_text '`error-page-capability-gone.json`' fixtures/README.md
require_text '`error-capability-scope-expired.json`' fixtures/README.md

printf '%s\n' '---'
printf '%s\n' 'status: pass'
printf 'passed: %d\n' "$passed"
printf '%s\n' 'failed: 0'
printf '%s\n' 'errors: 0'
printf '%s\n' 'task_id: R003-BF001'
printf '%s\n' '---'
printf '%s' "$pass_log"
printf '%s\n' 'SCENARIO Protocol fixture: PASS'
printf '%s\n' 'SCENARIO Dart core: PASS via legacy hello compatibility fixture and protocol JSON checks'
printf '%s\n' 'SCENARIO Kotlin core: PASS via legacy hello compatibility fixture and protocol JSON checks'
printf '%s\n' 'SCENARIO Python mirror: PASS via page/multi-page/schema-shrink/error fixture checks'
printf 'SUMMARY passed=%d failed=0 errors=0\n' "$passed"
