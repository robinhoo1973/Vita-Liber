"""训练工程(计划文档 §7.4):checkpoint 断点续训 / MPS 探测 / 标定 / 编码器训练循环。

torch 为训练期依赖(CI 内 pip 安装,钉版见 requirements-distill.txt);
本包除 checkpoint 的纯 stdlib 部分外,本地(无 torch)仅做语法级验证。
"""
