"""checkpoint 序列化 / 原子写 / 恢复自检(计划文档 §7.4 断点续训机制)。

- 内容:模型权重 + optimizer 状态 + scheduler + RNG 状态 + step/epoch + 元数据。
- 原子性:tmp 写入 + rename + sha256 sidecar;恢复前校验 sha256 通过才加载。
- 恢复自检三层(§7.4 第 7 条,2026-10-08 校准):
  L1 loss:同一探测批(probe batch)在保存前与恢复后的 loss 相对偏差 <5%
    ——同数据同权重的确定性对拍。旧版比较"恢复后首步训练 loss vs 断点记录",
    两批不同数据,批次间方差远大于 5%,首跑 CI 37710699326 实证恒红;
  L2 状态:step 严格单调、epoch 精确续接无重放(load 时校验)
  L3 权重:首末层哈希须变化、vocab 不变(由训练循环调用 check_weight_progress)
- 文件名:checkpoint-{step:08d}.pt + checkpoint-latest.json 指针 + *.sha256 sidecar。
"""
from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

CHECKPOINT_DIRNAME = "checkpoints"


@dataclass
class CheckpointMeta:
    step: int
    epoch: int
    loss: float
    dataset_sha256: str
    model_config_sha256: str
    rng: dict                      # torch RNG 状态(CPU tensors)
    extra: dict | None = None
    probe_loss: float | None = None  # L1 同批探测基 loss(2026-10-08;旧 ckpt 缺省 None)


def atomic_write_bytes(path: Path, data: bytes) -> str:
    """tmp + rename 原子写,返回 sha256;同时原子写 {path}.sha256 sidecar。

    sidecar 由 _write_file_atomic 直接写——不得递归调用本函数,否则
    sidecar-of-sidecar 无限递归(历史教训:smoke 最终保存必崩)。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(data).hexdigest()
    _write_file_atomic(path, data)
    _write_file_atomic(path.with_suffix(path.suffix + ".sha256"),
                       f"{digest}  {path.name}\n".encode())
    return digest


def _write_file_atomic(path: Path, data: bytes) -> None:
    """单文件 tmp + rename 原子写(不含 sidecar 语义)。"""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save_checkpoint(checkpoint_dir: Path, payload: dict, meta: CheckpointMeta) -> Path:
    """payload 由调用方序列化(含 torch state_dict);本函数负责原子落盘与指针。"""
    import io

    import torch  # 延迟导入:本模块 stdlib 部分可离线测试

    blob = {
        "meta": {
            "step": meta.step, "epoch": meta.epoch, "loss": meta.loss,
            "dataset_sha256": meta.dataset_sha256,
            "model_config_sha256": meta.model_config_sha256,
            "rng": meta.rng, "extra": meta.extra or {},
            "probe_loss": meta.probe_loss,
        },
        "payload": payload,
    }
    buffer = io.BytesIO()
    torch.save(blob, buffer)
    return _write_checkpoint(checkpoint_dir, meta.step, meta.dataset_sha256, buffer.getvalue())


def _write_checkpoint(checkpoint_dir: Path, step: int, dataset_sha256: str, data: bytes) -> Path:
    # 文件名携带数据集身份(计划文档 §7.4 ②:命名含 dataset-sha256 + step 号):
    # chunk 链式续跑/Release 上传时文件名即身份,不用解开 blob 才知属哪个数据集。
    path = checkpoint_dir / f"ckpt-{dataset_sha256[:12]}-{step:08d}.pt"
    digest = atomic_write_bytes(path, data)
    pointer = checkpoint_dir / "checkpoint-latest.json"
    pointer_payload = json.dumps({"step": step, "path": path.name, "sha256": digest},
                                 ensure_ascii=False, indent=2) + "\n"
    atomic_write_bytes(pointer, pointer_payload.encode())
    return path


def load_checkpoint(checkpoint_dir: Path, expected_step: int | None = None,
                    expected_dataset_sha256: str | None = None,
                    expected_model_config_sha256: str | None = None) -> tuple[dict, CheckpointMeta]:
    """加载 latest checkpoint 并做 L2 状态校验 + sha256 校验。"""
    import io

    import torch

    pointer_path = checkpoint_dir / "checkpoint-latest.json"
    if not pointer_path.exists():
        raise FileNotFoundError(f"无 checkpoint 指针: {pointer_path}")
    pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
    path = checkpoint_dir / pointer["path"]
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != pointer["sha256"]:
        raise ValueError(f"checkpoint sha256 校验失败: {path}——拒绝恢复(fail-closed)")
    blob = torch.load(io.BytesIO(data), weights_only=False)
    meta_raw = blob["meta"]
    meta = CheckpointMeta(
        step=meta_raw["step"], epoch=meta_raw["epoch"], loss=meta_raw["loss"],
        dataset_sha256=meta_raw["dataset_sha256"],
        model_config_sha256=meta_raw["model_config_sha256"],
        rng=meta_raw["rng"], extra=meta_raw.get("extra"),
        probe_loss=meta_raw.get("probe_loss"),
    )
    if expected_step is not None and meta.step != expected_step:
        raise ValueError(f"L2 状态闸: checkpoint step={meta.step} != 期望 {expected_step}(续接非精确)")
    if expected_dataset_sha256 is not None and meta.dataset_sha256 != expected_dataset_sha256:
        raise ValueError(f"L2 数据集闸: checkpoint 数据 sha256={meta.dataset_sha256} != 当前 {expected_dataset_sha256}")
    if expected_model_config_sha256 is not None and meta.model_config_sha256 != expected_model_config_sha256:
        raise ValueError(f"L2 配置闸: checkpoint 模型配置 sha256={meta.model_config_sha256} != "
                         f"当前 {expected_model_config_sha256}——跨配置恢复会静默错配(fail-closed)")
    return blob["payload"], meta


def check_resume_loss(recorded_loss: float, first_step_loss: float, tolerance: float = 0.05) -> None:
    """L1 恢复自检:同一探测批在保存前与恢复后的 loss 相对偏差 < tolerance。

    调用契约(2026-10-08 校准):两侧 loss 必须来自**同一批数据、同一权重语义**——
    保存侧=save 前对该 probe batch 的 eval-mode loss,恢复侧=load 后同批再算一次。
    旧契约比较"恢复后首个训练步 loss vs 断点记录"(不同批次),批次方差远大于
    容差,闸近恒红(首跑 CI 37710699326 实证 0.0429 vs 0.1374,68.8%)。
    """
    if recorded_loss <= 0:
        raise ValueError(f"L1 恢复自检: 断点 loss 非法({recorded_loss})")
    deviation = abs(first_step_loss - recorded_loss) / recorded_loss
    if deviation >= tolerance:
        raise ValueError(
            f"L1 恢复自检: 同批探测基 loss 相对偏差 {deviation:.4f} ≥ {tolerance}——"
            f"恢复后 {first_step_loss:.4f} vs 保存前 {recorded_loss:.4f},拒绝续训(device-lost 教训闸)")


def weight_fingerprint(model, vocab: int) -> dict:
    """L3 权重指纹:首层(embedding + 首 transformer 层)/末层(投影)权重 sha256 + 参数量。

    训练循环前后对比。匹配须用参数名的**片段**而非后缀——transformer 层参数名
    形如 `encoder.layers.0.self_attn.in_proj_weight`,永不以后缀 `layers.0` 结尾
    (历史教训:旧 endswith 条件全为死代码,指纹只剩 embedding 一项)。
    """
    import torch

    hashes = {}
    for name, param in model.named_parameters():
        if "embed" in name or ".layers.0." in name or name == "proj.weight":
            hashes[name] = hashlib.sha256(param.detach().cpu().float().numpy().tobytes()).hexdigest()[:16]
    return {"fingerprints": hashes, "param_count": sum(p.numel() for p in model.parameters()), "vocab": vocab}


def check_weight_progress(before: dict, after: dict) -> None:
    """L3:首末层哈希须变化、参数量与 vocab 不变。"""
    if before["param_count"] != after["param_count"] or before["vocab"] != after["vocab"]:
        raise ValueError("L3 恢复自检: 参数量/vocab 漂移——checkpoint 与模型配置不一致")
    if before["fingerprints"] == after["fingerprints"]:
        raise ValueError("L3 恢复自检: 训练步后权重无变化——梯度未生效,拒绝继续(device-lost 教训闸)")
