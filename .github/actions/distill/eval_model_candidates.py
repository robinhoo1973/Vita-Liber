#!/usr/bin/env python3
"""编码器候选生成器(闭合 --model-candidates 入口;round5 E0 最后件)。

职责:训练好的编码器 checkpoint + 冻结语料(eval 切分) + 实体模型 →
逐查询候选 JSONL(candidates 行),供 eval_entlink 的五层闸消费:
  {"id": ..., "candidates": [{"entity_id","score","matched_term","source"}]}

语义(与红队裁定一致):
- rank1 = **纯模型**打分;--union-engine(默认开)把确定性引擎 top-k 追加在后
  (仅抬高 recall@10/@3,不触碰 rank1——错链硬零类判据不受影响);
- 词面=实体名(canonical 优先),matched_term 供 BR-006 词表复检;
- 可复现:同 checkpoint+同语料 sha+同 entities sha ⇒ 逐字节同输出(排序确定)。

torch 路径仅在真跑时导入(纯函数部分 stdlib 可测:tests/test_eval_model_candidates.py)。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_entity_terms(entities_path: Path) -> list[tuple[str, str]]:
    """entities.jsonl → [(entity_id, 词面)];词面=规范名优先(name_zh→short_name→name_en)。"""
    terms: list[tuple[str, str]] = []
    with open(entities_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if "_meta" in row and "entity_id" not in row:
                continue  # 首行 _meta 携带 dataVersion
            names = row.get("names") or {}
            term = names.get("name_zh") or names.get("short_name") or names.get("name_en")
            if row.get("entity_id") and term:
                terms.append((row["entity_id"], term))
    return terms


def merge_candidates(model_top: list[dict], engine_top: list[dict], k: int = 10) -> list[dict]:
    """纯模型 top-k + 引擎 top-k 并集(模型在前;引擎独有项追加;去重)。

    rank1 语义:除非模型候选全空,否则 rank1 必为模型候选(引擎不做 rank1 兜底,
    错链硬零类判据不受并集影响);k 仅作调用方文档参数保留。
    """
    seen = {c["entity_id"] for c in model_top}
    merged = list(model_top)
    for cand in engine_top:
        if cand["entity_id"] in seen:
            continue
        merged.append(cand)
        seen.add(cand["entity_id"])
    return merged


def _load_eval_queries(corpus: Path) -> list[dict]:
    rows = []
    with open(corpus, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("split") == "eval":
                rows.append(row)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--entities", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True,
                        help="训练输出目录(含 checkpoints/checkpoint-latest.json)或 .pt 文件")
    parser.add_argument("--out", type=Path, required=True, help="候选 JSONL 输出")
    parser.add_argument("--top-k", type=int, default=10)
    parser.add_argument("--batch", type=int, default=256)
    parser.add_argument("--hidden", type=int, default=512)
    parser.add_argument("--layers", type=int, default=8)
    parser.add_argument("--seq", type=int, default=128)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--no-union-engine", dest="union_engine", action="store_false")
    args = parser.parse_args()

    try:
        import torch
    except ImportError:
        print("FAILED: torch 不可用——候选生成仅在带 torch 的执行面运行", file=sys.stderr)
        return 1

    from entlink.recall import RecallEngine  # 引擎并集(零 torch 依赖)
    from corpus.builder import BuildConfig  # noqa: F401  (仅为保持与 build 侧同锚:目录加载走 entities)
    from train.corpus_loader import build_vocab, load_samples, tokenize
    from train.model import EncoderConfig, build_encoder

    queries_rows = _load_eval_queries(args.corpus)
    if not queries_rows:
        print("FAILED: eval 切分为空", file=sys.stderr)
        return 1
    entity_terms = load_entity_terms(args.entities)
    if not entity_terms:
        print("FAILED: entities 无有效实体", file=sys.stderr)
        return 1

    # vocab 必须与训练时逐同:同一冻结语料 train 切分重建(语料 sha 冻结保证)
    train_samples = load_samples(args.corpus, "train")
    vocab = build_vocab(train_samples)
    eids = [e for e, _ in entity_terms]
    etexts = [t for _, t in entity_terms]
    e_tokens, _ = tokenize([{"query": t} for t in etexts], vocab, args.seq)
    q_tokens, _ = tokenize(queries_rows, vocab, args.seq)

    state_path = args.checkpoint
    if state_path.is_dir():
        pointer = json.loads(
            (state_path / "checkpoints" / "checkpoint-latest.json").read_text(encoding="utf-8"))
        state_path = state_path / "checkpoints" / pointer["path"]
    payload = torch.load(state_path, map_location="cpu")
    state = payload["model"] if "model" in payload else payload
    vocab_size, hidden_dim = state["embed_tokens.weight"].shape
    config = EncoderConfig(vocab_size=vocab_size, hidden=hidden_dim, layers=args.layers,
                           heads=max(hidden_dim // 64, 1), seq=args.seq)
    model = build_encoder(config)
    model.load_state_dict(state)
    model.eval()

    def encode(tokens) -> "torch.Tensor":
        embs = []
        with torch.no_grad():
            for i in range(0, tokens.size(0), args.batch):
                chunk = tokens[i:i + args.batch].to(args.device)
                embs.append(model(chunk).detach().cpu())
        return torch.cat(embs, dim=0)

    e_emb = encode(e_tokens)
    q_emb = encode(q_tokens)

    engine = None
    if args.union_engine:
        from entlink.catalog import load_entities_dump
        engine = RecallEngine().build(load_entities_dump(args.entities))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        for qi, row in enumerate(queries_rows):
            scores = q_emb[qi] @ e_emb.t()
            top = torch.topk(scores, k=min(args.top_k, scores.numel()))
            model_top = [{"entity_id": eids[int(idx)], "score": round(float(score), 6),
                          "matched_term": etexts[int(idx)], "source": "model"}
                         for score, idx in zip(top.values, top.indices)]
            merged = model_top
            if engine is not None:
                hits = engine.search(row["query"], domain=row.get("domain"),
                                     top_k=args.top_k)
                engine_top = [{"entity_id": h.entity_id, "score": round(h.score, 6),
                               "matched_term": h.matched_term, "source": "engine"}
                              for h in hits]
                merged = merge_candidates(model_top, engine_top, args.top_k)
            fh.write(json.dumps({"id": row["id"], "candidates": merged},
                                ensure_ascii=False) + "\n")

    summary = {"rows": len(queries_rows), "entities": len(entity_terms),
               "corpus_sha256": sha256_file(args.corpus),
               "entities_sha256": sha256_file(args.entities),
               "checkpoint": str(state_path), "top_k": args.top_k,
               "union_engine": args.union_engine,
               "note": "候选=纯模型 rank1;引擎并集仅追加在后(不触碰 rank1)"}
    (args.out.with_suffix(args.out.suffix + ".summary.json")).write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
