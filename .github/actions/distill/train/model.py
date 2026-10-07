"""字符级双塔编码器(P1 smoke / P3 可换 BGE-small-zh,循环不变)。

为什么字符级:中文目录词条无词边界,char vocab 免 HF tokenizer 依赖、
零额外供应链;P3 换 BGE-small-zh(许可核实 D-6 后)时仅替换 build_encoder,
训练循环/checkpoint/评测闸全部不变(模型配置 sha256 进 checkpoint 元数据)。
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass


@dataclass
class EncoderConfig:
    vocab_size: int = 8000
    hidden: int = 512
    layers: int = 8
    heads: int = 8
    seq: int = 128
    dropout: float = 0.1

    def sha256(self) -> str:
        payload = json.dumps(self.__dict__, sort_keys=True)
        return hashlib.sha256(payload.encode()).hexdigest()


def build_encoder(config: EncoderConfig):
    """双塔共用单编码器:char embed + 位置 + N 层 SDPA transformer + mean pool + 投影。"""
    import torch
    import torch.nn as nn

    class CharEncoder(nn.Module):
        def __init__(self, cfg: EncoderConfig):
            super().__init__()
            self.cfg = cfg
            self.embed = nn.Embedding(cfg.vocab_size, cfg.hidden, padding_idx=0)
            self.pos = nn.Parameter(torch.zeros(1, cfg.seq, cfg.hidden))
            layer = nn.TransformerEncoderLayer(
                d_model=cfg.hidden, nhead=cfg.heads, dim_feedforward=cfg.hidden * 4,
                dropout=cfg.dropout, activation="gelu", batch_first=True, norm_first=True)
            self.encoder = nn.TransformerEncoder(layer, num_layers=cfg.layers)
            self.proj = nn.Linear(cfg.hidden, cfg.hidden)
            nn.init.normal_(self.pos, std=0.02)

        def forward(self, x):
            # x: [B, S] int;padding_idx=0 由 SDPA 的 key_padding_mask 屏蔽
            mask = x.eq(0)
            emb = self.embed(x) + self.pos[:, : x.size(1), :]
            out = self.encoder(emb, src_key_padding_mask=mask)
            pooled = out.masked_fill(mask.unsqueeze(-1), 0.0).sum(dim=1) / mask.logical_not().sum(dim=1, keepdim=True).clamp(min=1)
            return torch.nn.functional.normalize(self.proj(pooled), dim=-1)

    return CharEncoder(config)
