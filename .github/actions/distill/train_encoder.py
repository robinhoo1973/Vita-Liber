#!/usr/bin/env python3
"""编码器对比学习训练循环(计划文档 §7.4 执行体)。

机制清单(逐条对应 §7.4):
- 墙钟预算优雅停机:--budget-seconds(默认 19800=5.5h),到预算即保存 checkpoint
  退出码 0——托管 6h 是强杀无钩子,绝不撞线;
- checkpoint = 权重+optimizer+scheduler+RNG+step/epoch+元数据,原子写+sha256 sidecar;
- 恢复自检三层:加载时 L2(数据集 sha 精确续接)+ L1(同批探测基 loss 对拍——
  2026-10-08 校准:固定 probe batch 保存前/恢复后各以 eval-mode 算一次,同数据
  同权重),恢复后首步 L3(首末层权重指纹变化、参数量/vocab 不变);
- 逐 epoch 种子打乱:恢复不重放;pin_memory 关闭(XPU 教训)、固定 seq(无动态填充);
- 训练侧指标只作进度信号(计划文档 §10):评测闸唯一权威=部署件 CPU 打分。
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from corpus.manifest import verify_manifest  # noqa: E402
from train.checkpoint import (CheckpointMeta, check_resume_loss,  # noqa: E402
                              check_weight_progress, load_checkpoint,
                              save_checkpoint, weight_fingerprint)
from train.corpus_loader import (build_vocab, load_negative_terms,  # noqa: E402
                                 load_samples, negative_terms_for_samples,
                                 sha256_file, tokenize)
from train.model import EncoderConfig, build_encoder  # noqa: E402

DEFAULT_BUDGET_SECONDS = 19800  # 5.5h(托管 6h 强杀前留边)


def build_scheduler(optimizer, warmup_steps: int, total_steps: int):
    import math

    import torch

    def lr_lambda(step):
        if step < warmup_steps:
            return step / max(warmup_steps, 1)
        progress = min((step - warmup_steps) / max(total_steps - warmup_steps, 1), 1.0)
        return max(0.1, 0.5 * (1 + math.cos(progress * math.pi)))

    return torch.optim.lr_scheduler.LambdaLR(optimizer, lr_lambda)


def contrastive_loss(q_emb, d_emb, temperature, neg_emb=None, neg_valid=None, gold_ids=None):
    """InfoNCE;可选负例列拼接与同实体假负例掩蔽(2026-10-08 仲裁席 β 代码方案)。

    - 默认路径(probe 用)逐字节不变:probe_loss 语义/记录不受影响;
    - neg_emb (B,K,D) 与 neg_valid (B,K) 拼为 (B,B+K) 的附加列(零重构);
    - gold_ids (B,):batch 内同实体(≠自身)的行在正例矩阵中掩 -inf——
      每实体 ≤3 词条×4 带≈12 行,batch=64 下同实体重复正例必然成串,
      现状把它们当负例=已存在的假负例源。
    """
    import torch
    import torch.nn.functional as F

    scores = q_emb @ d_emb.t() / temperature
    if gold_ids is not None:
        same = gold_ids.unsqueeze(0) == gold_ids.unsqueeze(1)
        eye = torch.eye(scores.size(0), dtype=torch.bool, device=scores.device)
        scores = scores.masked_fill(same & ~eye, float("-inf"))
    if neg_emb is not None:
        neg_scores = torch.einsum("bd,bkd->bk", q_emb, neg_emb) / temperature
        if neg_valid is not None:
            neg_scores = neg_scores.masked_fill(~neg_valid, float("-inf"))
        scores = torch.cat([scores, neg_scores], dim=1)
    labels = torch.arange(scores.size(0), device=scores.device)
    return F.cross_entropy(scores, labels)


def _rng_state(torch, random) -> dict:
    return {"torch": torch.get_rng_state(), "python": random.getstate()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--resume-dir", type=Path, default=None)
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "mps"])
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--accum", type=int, default=1)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--max-steps", type=int, default=None, help="smoke: ≤30 步训练回归")
    parser.add_argument("--budget-seconds", type=int, default=DEFAULT_BUDGET_SECONDS)
    parser.add_argument("--seq", type=int, default=128)
    parser.add_argument("--hidden", type=int, default=512)
    parser.add_argument("--layers", type=int, default=8)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--temperature", type=float, default=0.05)
    parser.add_argument("--seed", type=int, default=20260929)
    parser.add_argument("--negatives", choices=["off", "corpus"], default="off",
                        help="off=只看 in-batch(旧行为);corpus=拼入语料负例词面"
                             "(阶段 1;阶段 2 挖掘负例另批——round5 仲裁席 β)")
    parser.add_argument("--amp", action="store_true", help="bf16 autocast(仅 MPS;禁 GradScaler,PR#184286)")
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--log-interval", type=int, default=20)
    parser.add_argument("--checkpoint-every", type=int, default=500)
    args = parser.parse_args()

    try:
        import torch
        from torch.utils.data import DataLoader, TensorDataset
    except ImportError:
        print("FAILED: torch 不可用——训练仅在 CI(requirements-distill.txt 钉版)", file=sys.stderr)
        return 1

    manifest_path = args.manifest or args.corpus.with_suffix(args.corpus.suffix + ".manifest.json")
    try:
        manifest = verify_manifest(manifest_path, args.corpus)
    except (ValueError, OSError) as exc:
        print(f"FAILED manifest 校验: {exc}", file=sys.stderr)
        return 1
    dataset_sha = sha256_file(args.corpus)

    device = args.device
    if device == "auto":
        # MPS 由 calibrate 探测结果裁决后显式传入;auto 一律 CPU(§7.2 回落条款)
        device = "cpu"
    if device == "mps" and not torch.backends.mps.is_available():
        print("FAILED: --device mps 但 is_available()=False——按 §7.2 回落 CPU 或先跑探测段", file=sys.stderr)
        return 1

    samples = load_samples(args.corpus, "train")
    if not samples:
        print("FAILED: 训练集为空", file=sys.stderr)
        return 1
    if len(samples) < args.batch:
        print(f"FAILED: 训练集 {len(samples)} 行 < batch {args.batch}——drop_last 下 "
              f"批数为 0,训练会静默空转假绿(历史教训),fail-closed", file=sys.stderr)
        return 1
    vocab = build_vocab(samples)
    config = EncoderConfig(vocab_size=len(vocab), hidden=args.hidden, layers=args.layers,
                           heads=max(args.hidden // 64, 1), seq=args.seq)
    queries, _golds = tokenize(samples, vocab, args.seq)
    gold_terms = [row["gold"]["term"] for row in samples]
    gold_tokens, _ = tokenize([{"query": t} for t in gold_terms], vocab, args.seq)

    # 负例词面表(--negatives corpus;阶段 1)与同实体掩蔽索引(恒开——假负例修复)。
    neg_terms: list[list[str]] = [[] for _ in samples]
    neg_stats: dict = {}
    if args.negatives == "corpus":
        term_map = load_negative_terms(args.corpus)
        neg_terms, neg_stats = negative_terms_for_samples(samples, term_map)
        expected = sum(len(r.get("negatives") or []) for r in samples)
        resolve_rate = 1.0 - neg_stats["neg_resolve_missing"] / max(expected, 1)
        if resolve_rate < 0.95:
            print(f"FAILED: 负例词面解析率 {resolve_rate:.3f} < 0.95——拒绝训练(fail-closed)",
                  file=sys.stderr)
            return 1
        neg_stats["neg_resolve_rate"] = round(resolve_rate, 4)
        neg_stats["neg_per_sample"] = round(
            sum(len(t) for t in neg_terms) / max(len(samples), 1), 3)
    eid_index: dict[str, int] = {}
    entity_ids: list[int] = []
    for i, row in enumerate(samples):
        eid = (row.get("gold") or {}).get("entity_id")
        if eid is None:
            entity_ids.append(-(i + 1))  # 无金标实体:唯一负值,永不与他行同实体
            continue
        if eid not in eid_index:
            eid_index[eid] = len(eid_index) + 1
        entity_ids.append(eid_index[eid])
    gold_ids_t = torch.tensor(entity_ids, dtype=torch.long)

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    model = build_encoder(config).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    batches_per_epoch = max(len(queries) // args.batch, 1)
    total_steps = args.epochs * batches_per_epoch
    scheduler = build_scheduler(optimizer, warmup_steps=max(total_steps // 10, 1), total_steps=total_steps)

    # L1 同批探测基(2026-10-08 修复):固定取数据集前 batch 行作为 probe——语料 sha
    # 冻结 ⇒ 跨进程重建确定;保存前与恢复后各以 eval-mode 算一次 loss,同数据同
    # 权重,5% 容差才有判别力。旧判据比较"恢复后首步训练 loss vs 断点记录"(不同
    # 批次),批次方差远大于容差,首跑 CI 37710699326 实证恒红(0.0429 vs 0.1374)。
    probe_xq = queries[:args.batch].to(device)
    probe_xd = gold_tokens[:args.batch].to(device)

    def compute_probe_loss() -> float:
        was_training = model.training
        model.eval()
        with torch.no_grad():
            probe = contrastive_loss(model(probe_xq), model(probe_xd), args.temperature)
        if was_training:
            model.train()
        return float(probe.detach().cpu())

    def neg_batch(bidx) -> tuple:
        """按批现 tokenize 负例词面(不预张量化:37 万样本×4×128 预张量≈1.5GB 会爆)。"""
        rows = [neg_terms[i] for i in bidx.tolist()]
        k_max = max(1, max((len(r) for r in rows), default=1))
        flat, valid = [], []
        for r in rows:
            for k in range(k_max):
                if k < len(r):
                    flat.append({"query": r[k]})
                    valid.append(True)
                else:
                    flat.append({"query": r[0] if r else ""})
                    valid.append(False)  # 占位列,掩 -inf,不参与损失
        n_tokens, _ = tokenize(flat, vocab, args.seq)
        neg_emb = model(n_tokens.to(device)).view(len(rows), k_max, -1)
        neg_valid = torch.tensor(valid, dtype=torch.bool,
                                 device=device).view(len(rows), k_max)
        return neg_emb, neg_valid

    start_step, start_epoch, recorded_loss = 0, 0, None
    if args.resume_dir is not None:
        payload, meta = load_checkpoint(args.resume_dir, expected_dataset_sha256=dataset_sha,
                                        expected_model_config_sha256=config.sha256())
        model.load_state_dict(payload["model"])
        optimizer.load_state_dict(payload["optimizer"])
        scheduler.load_state_dict(payload["scheduler"])
        torch.set_rng_state(payload["rng"]["torch"])
        random.setstate(payload["rng"]["python"])
        start_step, start_epoch, recorded_loss = meta.step, meta.epoch, meta.loss
        print(f"RESUMED step={start_step} epoch={start_epoch} loss={recorded_loss}")
        if meta.probe_loss is not None:
            resumed_probe = compute_probe_loss()
            check_resume_loss(meta.probe_loss, resumed_probe)  # L1:同批探测基对拍
            print(f"L1 同批探测基: {meta.probe_loss:.6f} -> {resumed_probe:.6f}(通过)")
        else:
            print("WARN: checkpoint 无 probe_loss(旧格式)——L1 同批对拍跳过", file=sys.stderr)
        fingerprint_before = weight_fingerprint(model, len(vocab))  # L3 基线(恢复首步后对比)
    else:
        fingerprint_before = None

    # 恢复不重放(§7.4 第 7 条):续接 epoch 内已完成的 batch 直接跳过(前提
    # accum=1,step 与 batch 一一对应;accum>1 时为近似偏移,由 L1/L3 自检兜底)。
    # 注:续训正确性现由"同批探测基" L1 保证(加载时对拍);旧"首步 loss 与断点
    # 记录比"因两批不同数据方差远超容差,已按 2026-10-08 校准移除。
    skip_batches = (start_step - batches_per_epoch * start_epoch) if args.resume_dir is not None else 0

    args.out_dir.mkdir(parents=True, exist_ok=True)
    log_path = args.out_dir / "train-log.jsonl"
    start_wall = time.monotonic()
    deadline = start_wall + args.budget_seconds
    step = start_step
    last_loss = recorded_loss if recorded_loss is not None else 0.0
    graceful = False
    model.train()

    def save(epoch: int, extra: dict | None = None) -> None:
        save_checkpoint(
            args.out_dir / "checkpoints",
            {"model": model.state_dict(), "optimizer": optimizer.state_dict(),
             "scheduler": scheduler.state_dict(), "rng": _rng_state(torch, random)},
            CheckpointMeta(step=step, epoch=epoch, loss=last_loss,
                           dataset_sha256=dataset_sha,
                           model_config_sha256=config.sha256(),
                           rng=_rng_state(torch, random),
                           extra=extra or {"device": device, "amp": args.amp},
                           probe_loss=compute_probe_loss()))

    try:
        for epoch in range(start_epoch, args.epochs):
            if graceful:
                break
            g = torch.Generator()
            g.manual_seed(args.seed + epoch)
            dataset = TensorDataset(queries, gold_tokens, torch.arange(len(queries)))
            loader = DataLoader(dataset, batch_size=args.batch, shuffle=True, generator=g,
                                num_workers=args.workers, pin_memory=False, drop_last=True)
            for batch_idx, (xq, xd, bidx) in enumerate(loader):
                if epoch == start_epoch and batch_idx < skip_batches:
                    continue  # 续训跳过已完成的 batch(无重放纪律)
                if args.max_steps is not None and step - start_step >= args.max_steps:
                    graceful = True
                    break
                if time.monotonic() > deadline:
                    graceful = True
                    break
                xq, xd = xq.to(device), xd.to(device)
                gids = gold_ids_t[bidx].to(device)

                def _forward():
                    q_emb, d_emb = model(xq), model(xd)
                    neg_emb = neg_valid = None
                    if args.negatives == "corpus":
                        neg_emb, neg_valid = neg_batch(bidx)
                    return contrastive_loss(q_emb, d_emb, args.temperature,
                                            neg_emb, neg_valid, gids)

                if args.amp and device == "mps":
                    with torch.autocast(device_type="mps", dtype=torch.bfloat16):
                        loss = _forward()
                else:
                    loss = _forward()
                (loss / args.accum).backward()
                if (batch_idx + 1) % args.accum == 0:
                    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                    optimizer.step()
                    optimizer.zero_grad(set_to_none=True)
                    scheduler.step()
                    step += 1
                    last_loss = float(loss.detach().cpu())
                    if step == start_step + 1 and fingerprint_before is not None:
                        check_weight_progress(fingerprint_before, weight_fingerprint(model, len(vocab)))  # L3
                    if step % args.log_interval == 0:
                        row = {"step": step, "epoch": epoch, "loss": last_loss,
                               "wall_s": round(time.monotonic() - start_wall, 1),
                               "lr": scheduler.get_last_lr()[0]}
                        with open(log_path, "a", encoding="utf-8") as fh:
                            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
                    if step % args.checkpoint_every == 0:
                        save(epoch)
            if device == "mps":
                torch.mps.empty_cache()  # graph cache 无淘汰纪律(计划文档 §7.2 风险⑤)
    except Exception as exc:
        print(f"TRAIN_FAILED step={step}: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    final_epoch = min(args.epochs - 1, start_epoch + (step - start_step) // batches_per_epoch)
    save(final_epoch, extra={"device": device, "amp": args.amp, "budget_stop": graceful})
    summary = {"status": "budget_stop" if graceful else "complete", "steps": step - start_step,
               "total_steps": step, "loss_last": last_loss, "device": device, "amp": args.amp,
               "vocab_size": len(vocab), "dataset_sha256": dataset_sha,
               "negatives_mode": args.negatives, **neg_stats,
               "note": "训练侧指标只作进度信号;评测闸唯一权威=部署件 CPU 打分(计划文档 §10)"}
    (args.out_dir / "train-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
