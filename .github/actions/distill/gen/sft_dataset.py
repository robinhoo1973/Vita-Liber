"""ChatML SFT 数据集(CI 版;语义与训练机 minind-style SFTDataset 对齐)。

与训练机正本(refactor/tools/training/{macos,windows}/scripts/dataset/lm_dataset.py)的
对齐点(逐条):
  1) 会话经 tokenizer.apply_chat_template(..., add_generation_prompt=False) 渲染;
  2) **100% 剥离**模板对 assistant 段注入的空 think 帧('<think>\\n\\n</think>\\n\\n')
     ——App 推理侧无 think 契约,训练侧必须逐字同形(手册 §10.8);
  3) labels 掩码 = 只训 <|im_start|>assistant\\n … <|im_end|>\\n 之间的 token,
     其余 -100(多轮 assistant 段各自开窗);
  4) 动态填充由 collate 统一(batch 内最长 + multiple_of 对齐;labels 以 -100 填充)。

差异(如实登记):不依赖 HF `datasets` 库(CI 依赖面最小化;jsonl 逐行读),
字段形状校验等价(roles/至少一个 assistant/末条为 assistant)。
"""
from __future__ import annotations

import json

import torch

VALID_ROLES = {"system", "user", "assistant"}
EMPTY_THINK = "<think>\n\n</think>\n\n"


def validate_conversations(conversations) -> tuple[bool, str]:
    if not isinstance(conversations, list) or not conversations:
        return False, "missing conversations"
    for index, message in enumerate(conversations):
        if not isinstance(message, dict):
            return False, f"message {index} is not an object"
        if message.get("role") not in VALID_ROLES:
            return False, f"message {index} has invalid role"
        if not isinstance(message.get("content", ""), str):
            return False, f"message {index} has non-string content"
    if not any(m["role"] == "assistant" for m in conversations):
        return False, "missing assistant message"
    if conversations[-1]["role"] != "assistant":
        return False, "last message must be assistant"
    return True, ""


class ChatSFTDataset(torch.utils.data.Dataset):
    def __init__(self, jsonl_path, tokenizer, max_length: int = 1024):
        self.tokenizer = tokenizer
        self.max_length = max_length
        self.samples = []
        with open(jsonl_path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                record = json.loads(line)
                valid, reason = validate_conversations(record.get("conversations"))
                if not valid:
                    raise ValueError(f"{jsonl_path}:{lineno} Invalid SFT record: {reason}")
                self.samples.append(record["conversations"])
        if not self.samples:
            raise ValueError(f"SFT 语料为空: {jsonl_path}")
        self.bos_id = tokenizer(f"{tokenizer.bos_token}assistant\n", add_special_tokens=False).input_ids
        self.eos_id = tokenizer(f"{tokenizer.eos_token}\n", add_special_tokens=False).input_ids
        self.pad_token_id = tokenizer.pad_token_id if tokenizer.pad_token_id is not None else 0

    def __len__(self):
        return len(self.samples)

    def render(self, conversations) -> str:
        prompt = self.tokenizer.apply_chat_template(conversations, tokenize=False, add_generation_prompt=False)
        if EMPTY_THINK in prompt:
            prompt = prompt.replace(EMPTY_THINK, "")   # 100% 剥离(训练/推理同分布)
        return prompt

    def generate_labels(self, input_ids):
        labels = [-100] * len(input_ids)
        i = 0
        while i < len(input_ids):
            if input_ids[i:i + len(self.bos_id)] == self.bos_id:
                start = i + len(self.bos_id)
                end = start
                while end < len(input_ids):
                    if input_ids[end:end + len(self.eos_id)] == self.eos_id:
                        break
                    end += 1
                for j in range(start, min(end + len(self.eos_id), len(input_ids))):
                    labels[j] = input_ids[j]
                i = end + len(self.eos_id) if end < len(input_ids) else len(input_ids)
            else:
                i += 1
        return labels

    def __getitem__(self, index):
        input_ids = self.tokenizer(self.render(self.samples[index])).input_ids[: self.max_length]
        labels = self.generate_labels(input_ids)
        if all(label == -100 for label in labels):
            # 截断把 assistant 段整个切掉 → 该样本零监督信号(全 -100 的 loss 是 nan,
            # 静默毒化训练)。历史教训:盲目砍 max_length 时此族只会以 loss=nan 现身。
            raise ValueError(
                f"样本 {index} 监督信号被截断(max_length={self.max_length} 下 assistant 段不可见)——"
                f"提高 --seq 或缩短 system 段")
        return (torch.tensor(input_ids, dtype=torch.long),
                torch.tensor(labels, dtype=torch.long))


def collate_pad(batch, pad_token_id: int = 0, multiple_of: int = 8):
    """动态填充:batch 内最长 + multiple_of 对齐;labels -100(不参与 loss)。"""
    max_len = max(x.size(0) for x, _ in batch)
    max_len = ((max_len + multiple_of - 1) // multiple_of) * multiple_of
    ids, labels = [], []
    for x, y in batch:
        pad = max_len - x.size(0)
        ids.append(torch.cat([x, x.new_full((pad,), pad_token_id)]))
        labels.append(torch.cat([y, y.new_full((pad,), -100)]))
    return torch.stack(ids), torch.stack(labels)
