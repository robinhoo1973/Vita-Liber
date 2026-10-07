"""语料装载与字符级 tokenize(纯 torch 依赖,CI 内运行)。"""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

# 单一实现:corpus.manifest 为 sha256_file 唯一出处(manifest/语料/资产校验同源)
from corpus.manifest import sha256_file  # noqa: E402

PAD_IDX = 0
UNK_IDX = 1


def load_samples(path: Path, split: str = "train", limit: int | None = None) -> list[dict]:
    """读取语料 JSONL 指定 split 的样本(原始 query 不做 fold——噪声即信号)。"""
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("split") != split:
                continue
            out.append(row)
            if limit is not None and len(out) >= limit:
                break
    return out


def build_vocab(samples: list[dict], min_freq: int = 1) -> dict[str, int]:
    counter: Counter = Counter()
    for row in samples:
        counter.update(row["query"])
        # 金标词条字也入词表:只统计 query 会把「仅在金标出现、在全部 query 中
        # 被噪声替换/删除」的字打成 <unk>,正样本锚点静默降级(历史教训)。
        gold = row.get("gold") or {}
        if isinstance(gold.get("term"), str):
            counter.update(gold["term"])
    vocab = {"<pad>": PAD_IDX, "<unk>": UNK_IDX}
    for char, freq in counter.most_common():
        if freq >= min_freq:
            vocab[char] = len(vocab)
    return vocab


def tokenize(samples: list[dict], vocab: dict[str, int], seq: int):
    """字符级定长 tokenize(固定 seq——无动态填充,MPS graph cache 纪律)。

    行内 gold 键可选:纯 query 行(如训练循环里金标词条单独 tokenize)gold
    返回 None——历史教训:曾无条件 row["gold"] 使纯 query 行 KeyError 崩训练。
    """
    import torch

    queries = torch.zeros(len(samples), seq, dtype=torch.long)
    golds = []
    for i, row in enumerate(samples):
        chars = row["query"][:seq]
        for j, ch in enumerate(chars):
            queries[i, j] = vocab.get(ch, UNK_IDX)
        golds.append((row.get("gold") or {}).get("entity_id"))
    return queries, golds


class CorpusDataset:
    """定种子可复现的样本集(epoch 边界打乱由训练循环以 epoch seed 控制)。"""

    def __init__(self, queries, golds):
        import torch
        from torch.utils.data import TensorDataset

        self._set = TensorDataset(queries, torch.arange(len(golds)))
        self.golds = golds
        self.queries = queries

    def __len__(self):
        return len(self._set)

    def __getitem__(self, idx):
        return self._set[idx]
