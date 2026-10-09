
### 2026-10-08 · 生成链实弹三缺陷（丢件/dir 干扰/自检立功）

- **丢件族**（3ed65450）：重填 files 直接替换 → 金样 url 基件（无 member,如 whisper 外部 LICENSE）丢失 → 7 档自检漂移。修：按金样序合并（member 实测重填+url 件原位+多余追加）。
- **dir 判定干扰**（a04fe8bd）：apply_template 的 dir 集合把 url 基件（path 带档位子目录 whisper/tiny/LICENSE）算入 → len≠1 → member 件不重排 → path 前缀漂移（4 档）。修：dir 只取 member 件。
- **方法论**：候选自检步（generate&diff,在册漂移=红）在两轮内把「模糊漂移」压到「字段级精确 diff」——先上自检再修根因,比盲改高效一数量级。**检查清单**：重填/合并类操作必想「哪些件不在操作面内（url 基/外部件）」;目录约定类判定必排除非约定件。
