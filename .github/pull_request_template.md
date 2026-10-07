## 变更摘要

<!-- 一句话说明本 PR 做什么、为什么 -->

## 依赖钉版变更清单（Package.resolved / project.yml 有 diff 时必填）

<!-- 每条钉逐一列出：包名 | 旧 → 新 | 引入路径（direct/transitive，经谁） | 验证证据（CI 运行号）| 矩阵行更新 -->
- [ ] 无依赖变更
- [ ] `xxx`：`旧` → `新`，经 `yyy` 引入，CI `run-id` 全绿，矩阵行已同 PR 更新

## 门禁检查

- [ ] 本机 `bash .github/actions/gates/l0-static-gate.sh` 全绿（19 节）
- [ ] CoreKit `swift test` 全绿（Linux 可跑面）
- [ ] 依赖变更已过依赖能力矩阵（L0 [18]，`.github/actions/gates/dependency-capability-matrix.tsv`）
- [ ] 新增依赖回答 tech-spec §2.2 准入清单并在表内登记

## 规格/文档

<!-- 涉及规格链变更时列出升版与同步项；涉及代码结构变更时列出 code-function-mapping.md 锚点更新 -->
