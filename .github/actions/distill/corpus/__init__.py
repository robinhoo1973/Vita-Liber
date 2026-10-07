"""语料构建:目录资产 → (正样本对/硬负例/噪声增广) → 冻结 JSONL + manifest。

设计依据:手册 §10.2(REGISTRY/POOLS 注册表可扩展、verbatim 纪律)+
计划文档 §7.6(公开 Release 唯一数据源、冻结可复现)。
"""
