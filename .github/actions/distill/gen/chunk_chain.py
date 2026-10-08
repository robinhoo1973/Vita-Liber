#!/usr/bin/env python3
"""CPU 分块训练链状态机(2026-10-09;无私仓/无 GPU 决策——训练落点=公开仓 ubuntu CPU)。

职责(纯 stdlib,零 torch):给定「训练状态 JSON + 本次 chunk 执行结果」→ 决策
  next / done / stop。workflow 只做三件事:读状态→按决策 dispatch(或停)→回写状态。

状态文件(Release asset `train-state-<task>.json`;原子覆盖写):
  {"task","total_steps","done_steps","chunks_done","max_chunks",
   "status": "running"|"done"|"stopped",
   "stop_reason": null|"max_chunks"|"failed"|"no_progress"|"budget",
   "last_loss": float|null,"updated_at": iso}

决策表(失败即停——不吞红;防失控三重闸):
  - chunk 失败           → stopped(failed)
  - done_steps>=total    → done
  - chunks_done>=max     → stopped(max_chunks)
  - 本 chunk 零进度      → stopped(no_progress:done_steps 未前进)
  - 其余                 → next
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

STATUSES = ("running", "done", "stopped")


def new_state(task: str, total_steps: int, max_chunks: int,
              corpus_sha: str | None = None,
              trained_data_version: str | None = None) -> dict:
    """谱系字段(2026-10-09 调度四规则):corpus_sha=状态谱系键(文件名 <sha8>);
    trained_data_version=本条链针对的 sqlite/corpus dataVersion(规则①数据门禁用;
    done 后即成"已训版本"标记)。"""
    return {"task": task, "total_steps": int(total_steps), "done_steps": 0,
            "chunks_done": 0, "max_chunks": int(max_chunks), "status": "running",
            "stop_reason": None, "last_loss": None,
            "corpus_sha": corpus_sha, "trained_data_version": trained_data_version,
            "updated_at": _now()}


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_state(path: Path) -> dict:
    state = json.loads(Path(path).read_text(encoding="utf-8"))
    missing = [k for k in ("task", "total_steps", "done_steps", "chunks_done",
                           "max_chunks", "status") if k not in state]
    if missing:
        raise ValueError(f"训练状态缺字段: {missing}")
    if state["status"] not in STATUSES:
        raise ValueError(f"非法 status: {state['status']}")
    if state["done_steps"] > state["total_steps"]:
        raise ValueError("done_steps > total_steps(状态损坏,人工裁决)")
    return state


def decide(state: dict, *, chunk_failed: bool, chunk_steps: int, last_loss=None) -> tuple[dict, str]:
    """并入本 chunk 结果 → (新状态, 决策)。决策 ∈ next/done/stop。"""
    if state["status"] != "running":
        return state, "stop"   # 已终态的幂等:重复触发不再续链
    prev_done = state["done_steps"]
    state["done_steps"] = min(state["total_steps"], prev_done + max(0, int(chunk_steps)))
    state["chunks_done"] += 1
    if last_loss is not None:
        state["last_loss"] = float(last_loss)
    state["updated_at"] = _now()

    if chunk_failed:
        state["status"], state["stop_reason"] = "stopped", "failed"
        return state, "stop"
    if state["done_steps"] >= state["total_steps"]:
        state["status"], state["stop_reason"] = "done", None
        return state, "done"
    if state["chunks_done"] >= state["max_chunks"]:
        state["status"], state["stop_reason"] = "stopped", "max_chunks"
        return state, "stop"
    if state["done_steps"] == prev_done:
        state["status"], state["stop_reason"] = "stopped", "no_progress"
        return state, "stop"
    return state, "next"


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p0 = sub.add_parser("init")
    p0.add_argument("--out", type=Path, required=True)
    p0.add_argument("--task", required=True)
    p0.add_argument("--total-steps", type=int, required=True)
    p0.add_argument("--max-chunks", type=int, required=True)
    p0.add_argument("--corpus-sha", default=None)
    p0.add_argument("--data-version", default=None)

    p1 = sub.add_parser("decide")
    p1.add_argument("--state", type=Path, required=True)
    p1.add_argument("--out", type=Path, required=True)
    p1.add_argument("--chunk-steps", type=int, required=True)
    p1.add_argument("--failed", action="store_true")
    p1.add_argument("--last-loss", type=float, default=None)

    args = parser.parse_args()
    if args.cmd == "init":
        args.out.write_text(json.dumps(
            new_state(args.task, args.total_steps, args.max_chunks,
                      corpus_sha=args.corpus_sha, trained_data_version=args.data_version),
            ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("initialized")
        return 0
    state, decision = decide(load_state(args.state), chunk_failed=args.failed,
                             chunk_steps=args.chunk_steps, last_loss=args.last_loss)
    args.out.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(decision)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
