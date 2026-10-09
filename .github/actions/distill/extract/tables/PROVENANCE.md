# 混淆表来源与许可(PROVENANCE)

本目录两张表为**外部数据入仓**件,供 `extract/confusion.py` 装载(噪声 v2 的
形近/同音混淆主源;round5 仲裁席 α 终案)。

## same_pinyin.txt / same_stroke.txt

- 来源:pycorrector v1.1.4(PyPI wheel `pycorrector-1.1.4-py3-none-any.whl`,
  `pycorrector/data/`),上游仓库 https://github.com/shibing624/pycorrector
- 许可:Apache License 2.0(上游声明;随本目录使用时须保留本文件作为署名)
- 获取:2026-10-08,经 PyPI wheel 解包取原字节(上游 raw 通道当日不可达)
- 内容:same_pinyin.txt 3,513 行(首字符 + 同音同调组 + 同音异调组,制表符分隔,
  `#` 开头为表头);same_stroke.txt 831 行(形近组,制表符分隔)
- sha256:
  - same_pinyin.txt `39f9a93a68386ce6…`(完整值见 `confusion.py --sha256` 或 CI 断言)
  - same_stroke.txt `c9e31dac045484b1…`
- 使用纪律:只做**噪声合成采样源**(每字符按层优先取 ≤K=3 镜像,确定性排序);
  不用于评测金标;表变更=语料字节变更=独立 dataVersion 批(round5 §2.2)。

## ASR 模糊音族

`confusion.py::ASR_FUZZY_FAMILIES` 为项目自维护常量(声母/韵母/声调模糊对,
来源:round5 外研席引证的中文 ASR 纠错族 + 常识对表),不属外部数据。
