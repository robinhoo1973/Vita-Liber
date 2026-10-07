#!/usr/bin/env python3
"""生成式 SFT 烟雾训练(CI 侧训练循环验证;抽取/对话两语料共用)。

职责边界(计划文档 §7):托管 CPU 只跑「训练循环/checkpoint/预算停机」的烟雾回归;
全量训练在私仓自托管 GPU 消费本流水线冻结发布的语料(§7.5 dispatch 契约)。
本脚本即烟雾执行体:真实 minimind 模型代码(.github/actions/distill/gen/model_minimind.py,
与训练机正本逐字节同源)+ 真实 ChatML 数据管线(gen/sft_dataset.py)+ 小步数。

纪律:
- 墙钟预算内**优雅停机**(到预算即存 checkpoint 并以 0 退出;CI 的 6h 是强杀,绝不撞线);
- checkpoint 原子写(tmp + rename)+ sha256 sidecar;--resume-from 续训(冒烟覆盖恢复路径);
- 训练指标只作进度信号(评测闸权威 = 部署件在 ubuntu CPU 的打分,§10);
- 模型配置与训练机一致(hidden 768 × 8 层,勿在 CI 侧改动——权重必须能被训练机/导出链消费)。

用法:
  python3 .github/actions/distill/gen/train_sft_smoke.py --corpus extraction_sft.jsonl \
      --out-dir smoke-extraction --max-steps 30 --budget-seconds 600 --batch 8 --seq 512
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import torch  # noqa: E402

from model_minimind import MiniMindConfig, MiniMindForCausalLM  # noqa: E402
from sft_dataset import ChatSFTDataset, collate_pad  # noqa: E402


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save_checkpoint(path: Path, model, optimizer, *, step: int, loss: float, meta: dict) -> None:
    payload = {"state_dict": model.state_dict(), "optimizer": optimizer.state_dict(),
               "step": step, "last_loss": loss, "meta": meta}
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(payload, tmp)
    os.replace(tmp, path)
    (path.with_suffix(path.suffix + ".sha256")).write_text(
        sha256_file(path) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--tokenizer-dir", type=Path, default=_HERE)
    parser.add_argument("--label", default="sft")
    parser.add_argument("--max-steps", type=int, default=30)
    parser.add_argument("--budget-seconds", type=float, default=600.0)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--seq", type=int, default=512)
    parser.add_argument("--lr", type=float, default=1e-5)
    parser.add_argument("--seed", type=int, default=20261007)
    parser.add_argument("--log-every", type=int, default=5)
    parser.add_argument("--resume-from", type=Path, default=None,
                        help="从 checkpoint 续训(冒烟覆盖恢复路径)")
    parser.add_argument("--hidden-size", type=int, default=768)
    parser.add_argument("--layers", type=int, default=8)
    args = parser.parse_args()

    from transformers import AutoTokenizer

    torch.manual_seed(args.seed)

    tokenizer = AutoTokenizer.from_pretrained(str(args.tokenizer_dir))
    dataset = ChatSFTDataset(str(args.corpus), tokenizer, max_length=args.seq)
    loader = torch.utils.data.DataLoader(
        dataset, batch_size=args.batch, shuffle=False,
        collate_fn=lambda batch: collate_pad(batch, pad_token_id=dataset.pad_token_id))

    config = MiniMindConfig(hidden_size=args.hidden_size, num_hidden_layers=args.layers, flash_attn=False)
    model = MiniMindForCausalLM(config)
    params = sum(p.numel() for p in model.parameters()) / 1e6
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)

    start_step = 0
    if args.resume_from is not None:
        payload = torch.load(args.resume_from, map_location="cpu")
        model.load_state_dict(payload["state_dict"])
        optimizer.load_state_dict(payload["optimizer"])
        start_step = int(payload.get("step", 0))
    model.train()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    meta = {"label": args.label, "corpus": str(args.corpus), "corpus_sha256": sha256_file(args.corpus),
            "corpus_records": len(dataset), "model": {"hidden_size": args.hidden_size,
                                                      "num_hidden_layers": args.layers, "params_m": round(params, 2)},
            "seed": args.seed, "resume_from": str(args.resume_from) if args.resume_from else None}
    print(json.dumps({"[smoke]": "start", **meta, "max_steps": args.max_steps,
                      "budget_seconds": args.budget_seconds}, ensure_ascii=False), flush=True)

    started = time.time()
    step = start_step
    last_loss = float("nan")
    stopped_by = "max_steps"
    while step < args.max_steps:
        for input_ids, labels in loader:
            loss = model(input_ids, labels=labels).loss
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            optimizer.zero_grad()
            step += 1
            last_loss = float(loss.detach())
            if step % args.log_every == 0 or step == args.max_steps:
                print(json.dumps({"step": step, "loss": round(last_loss, 4),
                                  "elapsed_s": round(time.time() - started, 1)}), flush=True)
            if step >= args.max_steps:
                break
            if time.time() - started > args.budget_seconds:
                stopped_by = "budget"
                print(json.dumps({"[smoke]": "budget reached", "step": step}), flush=True)
                break
        if step >= args.max_steps or stopped_by == "budget":
            break

    checkpoint = args.out_dir / f"{args.label}-smoke.pt"
    save_checkpoint(checkpoint, model, optimizer, step=step, loss=last_loss, meta=meta)
    summary = {"label": args.label, "steps": step, "started_at_step": start_step,
               "elapsed_s": round(time.time() - started, 1), "last_loss": round(last_loss, 4),
               "stopped_by": stopped_by, "checkpoint": str(checkpoint),
               "checkpoint_sha256": sha256_file(checkpoint)}
    (args.out_dir / f"{args.label}-smoke.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"[smoke]": "done", **summary}, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
