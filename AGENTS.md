## XLFoundry 工作流（本项目 AI 辅助开发流程）

本项目用 xlfoundry 体系编排开发，管线：
brainstorm（可选）→ analysis → analysis-review → design → design-review
→ plan → plan-review → execute → evaluate → archive

- **驱动目录** `.dev-flow/`：执行期当前 RC 指针在 `config.json:active_rc`；制定/审查新需求时先确定 `target_rc`，每需求包一个 `{rc_id}/`（analysis/design/plan/evidence/contracts）
- **权威文档（工作前读）**：`.dev-flow/architecture.md`（架构宪法：管线拓扑/文件所有权/不变量）/ `.dev-flow/feature-map.md`（模块依赖+能力关系）/ `.dev-flow/summary.md`（变更历史）/ `rules/xlfoundry-*/SKILL.md`（管线 skill 规范）
- **代码地图**：`.dev-flow/code-map.md`（模块→目录→文件职责索引，AI 进项目先读此文件建立全局认知）
- **持续消费队列快捷入口**：用户输入 `$xlfoundry-execute queue-consumer` 时，按 `rules/xlfoundry-shared/references/queue-consumer-goal-template.md` 展开为显式 queue-consumer goal，持续消费 `rc_queue`
- **进项目第一件事**：读 `.dev-flow/config.json` + `rules/loading-protocol.md`；执行/归档阶段按 `active_rc` 定位当前 RC，brainstorm/analysis/design/plan 及其 review 阶段按 `target_rc` 定位目标 RC，不得把新需求默认写入当前 active RC
- **质量门触发**：命中 xlfoundry 的 review/evaluate/simplify/visual/contract 类 skill（如 analysis-review/design-review/plan-review/evaluate/simplify/visual-verify/contract-negotiate）时，标准流程必须按该 skill 的 SubagentContract 启动独立 subagent；无法启动时按 contract 输出 degraded 或 blocked，不得把主会话自审当作标准通过。
- **触发授权**：用户触发这些 skill 即表示授权按标准流程调度，无需额外说“用 subagent”。
- **边界**：保留 `target_rc` 与 `active_rc` 分离规则；不启用额外自动衔接机制，执行阶段仍由 `/xlfoundry-execute` 或用户明确输入触发。
- **触发**：`run-xlfoundry-skill.mjs <skill>` 调用，或用户直接请求对应 xlfoundry skill；执行阶段使用 `/xlfoundry-execute` 或用户输入“开始执行/继续”触发当前轮；每轮结束后由用户决定是否再次调用。
