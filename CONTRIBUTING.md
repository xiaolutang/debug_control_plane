# Contributing to debug_control_plane / 贡献指南

`debug_control_plane` is a personal project maintained by **tangxiaolu**. External
contributions are welcome, but **please read and agree to the terms below before
submitting** — submitting a pull request (or any other form of contribution)
counts as agreement.

`debug_control_plane` 是 **tangxiaolu** 维护的个人项目。欢迎外部贡献，但**提交前请阅读并同意以下条款**——提交 PR（或任何形式的贡献）即视为同意。

## Contributor agreement (CLA) / 贡献者协议（CLA）

By contributing, you agree to the following:
贡献即表示你同意以下条款：

### 1. License grant / 许可授权

You retain the copyright of your contribution, **but you grant tangxiaolu a
perpetual, worldwide, royalty-free, irrevocable license** to use, modify,
distribute, and **sublicense** your contribution under:

- the project's current license (the [MIT License](LICENSE)), **and/or**
- **any future license** that the project may adopt.

This lets the project evolve its licensing later without chasing down every
contributor for re-licensing consent.

你保留贡献代码的版权，**但授予 tangxiaolu 永久、全球范围、免版税、不可撤销的许可**，可按以下许可使用、修改、分发、**再授权**你的贡献：

- 项目当前许可（[MIT License](LICENSE)），**和/或**
- 项目未来采用的**任何许可**。

这一条让项目以后能演进许可政策，不必回头找每位贡献者逐个征得再授权同意。

### 2. You have the right to contribute / 你有权贡献

You confirm that your contribution is your original work (or that you have the
rights to submit it), and that it does not violate any third-party rights or any
agreement you are bound by — **in particular, your employer's IP terms**. If your
contribution was created within the scope of your employment, or using your
employer's resources, you confirm that **your employer has authorized its
submission under these terms, or that an appropriate corporate CLA covering the
contribution is on file with the maintainer**.

你确认贡献是你原创（或你有权提交），且不违反任何第三方权利或你所受约束的协议——**特别是雇主 IP 条款**。若贡献是在你受雇范围内、或使用雇主资源创作的，你确认**雇主已书面授权按本条款提交，或已向维护者存档相应的企业 CLA**。

### 3. Your contribution will be MIT-licensed / 贡献按 MIT 授权

Your contribution is licensed under the [MIT License](LICENSE) (or whatever
license the project adopts at merge time).

你的贡献按 [MIT License](LICENSE)（或合并时项目采用的许可）授权。

## How to contribute / 如何贡献

1. **Open an issue first** for non-trivial changes — discuss scope and approach
   before writing code, so effort isn't wasted.
   **非小改动先开 issue** —— 写代码前先讨论范围和方向，避免白费力气。
2. **Keep PRs focused** — one concern per pull request.
   **PR 聚焦** —— 每个 PR 只解决一个问题。
3. **No business dependencies** — `debug_control_plane` must stay business-agnostic.
   See the *Dependency invariant* section of [README.md](README.md); the
   `ci/zero-business-dep-check.sh` gate enforces this.
   **不引业务依赖** —— `debug_control_plane` 必须保持业务无关。见 [README.md](README.md) 的 *Dependency invariant* 章节；`ci/zero-business-dep-check.sh` 门会强制检查。
4. **Add or update tests** / **增补或更新测试**:
   - Dart: `cd dart && flutter test`
   - Python: `cd python && pytest`
5. **Lint clean** / **lint 通过**:
   - Dart: `cd dart && flutter analyze`
   - Python: `cd python && ruff check .`
6. **Commit style** — follow the existing convention (`type(scope): subject`).
   **提交风格** —— 遵循现有约定（`type(scope): subject`）。

## Project layout / 项目结构

- `dart/` — Flutter package (Transport / ControlPlane / Capability)
- `python/` — Python package (device_discovery + mcp_plane)
- `ci/` — repo-level checks / repo 级检查

---

Thanks for helping improve `debug_control_plane`! / 感谢帮助改进 `debug_control_plane`！
