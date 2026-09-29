"""实体链接确定性召回核心包(纯 stdlib,Linux 本地可测)。

分层(recall.RecallEngine)与数据流见 scripts/distill/README.md;
设计依据:refactor/2026-09-29-medical-llm-training-scenarios-ci-plan.md(§6 S1/§10 基线对照臂)。

模块边界:
- fold     查询与词条的共同折叠(无损归一:全半角/大小写/标点)
- pinyin   拼音层(lazy 依赖 pypinyin;缺失显式降级)
- fuzzy    字符级容错候选(SymSpell 风格 delete 索引 + 验证距离)
- catalog  四域目录装载(JSONL 适配器 + v4 SQLite 适配器)
- noise    三层合成噪声(形近/同音/繁简,定种子可复现)
- recall   分层召回引擎(唯一对外入口)
"""
