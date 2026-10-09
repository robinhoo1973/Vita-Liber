#!/usr/bin/env python3
"""训练调度决策器(2026-10-09 业主四规则;纯 stdlib,可离线单测)。

规则映射:
  ① 远端 sqlite 未更新 → 不启动训练   → sqlite_dataVersion == state.trained_data_version → skip
  ② 每 8h 启动(UTC 00:00 起算)        → maintenance.yml cron '0 0,8,16 * * *' 驱动本决策
  ③ 上次没训练完 → 继续               → state.status == running → continue(优先于一切)
  ④ 训练 ≤6h、临尾收尾                → work budget=330min + 收尾余量(workflow/policy 层)

状态三态 + 数据三态决策表(state=按 corpus sha 分谱系 train-state-train-encoder-<sha8>.json):
  | 链状态            | sqlite 关系            | 决策          |
  | running(未完成)   | 任意                   | continue(③优先)|
  | done/absent       | sqlite == trained      | skip(①)       |
  | done/absent       | sqlite > corpus 版本    | rebuild-corpus(先重建语料,本轮不训) |
  | done/absent       | sqlite == corpus 版本   | start(②)      |
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DECISIONS = ("skip", "start", "continue", "rebuild-corpus")


def decide(*, sqlite_data_version: str, state: dict | None,
           state_corpus_sha: str | None = None) -> str:
    """state: 该 corpus 谱系的训练状态(chunk_chain 格式;None=从未训过)。
    state 内约定字段: status(running/done/stopped), trained_data_version, corpus_sha。"""
    if state is None:
        return "start"          # 无状态=首训(数据已在 corpus 内,无需 rebuild 判定)
    status = state.get("status")
    if status == "running":
        return "continue"       # ③ 未完成优先
    trained_dv = state.get("trained_data_version")
    if trained_dv == sqlite_data_version:
        return "skip"           # ① 远端未更新
    # sqlite 已更新:语料是否同步?——调用方已确保 state 谱系=当前 corpus;
    # 若 state 谱系与当前 corpus 不符,由调用方(维护 job)以 corpus manifest 的
    # catalog_data_version 再判;此处只表达"数据已变且谱系匹配"→ 开新训
    return "start"


def decide_with_corpus(*, sqlite_data_version: str, corpus_data_version: str,
                       state: dict | None) -> str:
    """完整版:额外给 corpus manifest 的 catalog_data_version(语料构建自哪版 sqlite)。
    语料落后于 sqlite(需先重建)或语料无法解析 → rebuild-corpus;否则按 decide()。"""
    if state is None:
        if corpus_data_version and corpus_data_version != sqlite_data_version:
            return "rebuild-corpus"
        return "start"
    if state.get("status") == "running":
        return "continue"
    if state.get("trained_data_version") == sqlite_data_version:
        return "skip"
    if corpus_data_version and corpus_data_version != sqlite_data_version:
        return "rebuild-corpus"   # sqlite 新、语料旧 → 先跑 llm-pipeline
    return "start"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sqlite-data-version", required=True)
    parser.add_argument("--corpus-data-version", default="")
    parser.add_argument("--state", type=Path, default=None, help="谱系状态 JSON(chunk_chain 格式)")
    parser.add_argument("--out", type=Path, default=None, help="写入决策单行(供 workflow 读取)")
    args = parser.parse_args()
    state = json.loads(args.state.read_text(encoding="utf-8")) if args.state and Path(args.state).is_file() else None
    d = decide_with_corpus(sqlite_data_version=args.sqlite_data_version,
                           corpus_data_version=args.corpus_data_version, state=state)
    if args.out:
        args.out.write_text(d + "\n", encoding="utf-8")
    print(d)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
