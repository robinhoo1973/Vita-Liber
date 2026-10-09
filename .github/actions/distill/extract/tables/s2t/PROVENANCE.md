# s2t/ 简繁转换表来源与使用纪律

**来源**：OpenCC 词典数据（<https://github.com/BYVoid/OpenCC>，Apache-2.0），经 PyPI 包
`opencc-python-reimplemented==0.1.7`（wheel SHA256 `41b3b92943c7bed291f448e9c7fad4b577c8c2eae30fcfe5a74edf8818493aa6`）
一次性导出。**导入日期**：2026-10-08（workspace 本地执行，随 fetch 一次性导入批）。

**文件与 sha256**：

| 文件 | 用途 | sha256 |
|---|---|---|
| STCharacters.txt | 简→繁主表（3980 行；多候选取首） | 9207708da9f2e2a248f39c457b2fccad26ec42e7efaf47a860e6900464f4cac5 |
| TWVariants.txt | 繁→台湾正体变体（裏→裡 等 39 行） | 30e6f8395edbfdd74e293fd8b9c62105d787c849fbb208d2a7832eac696734d7 |
| HKVariants.txt | 繁→香港变体 | c3c93c35885902ba2b12a3235a7761b00fb2b027f36aa8314db2f6b6ad51d374 |

**纪律**：
- 本目录为**入仓钉版数据件**（同 `../tables/` pycorrector 先例）：CI 只读，不做网络访问。
- 转换链：CN=恒等；TW=STCharacters→TWVariants；HK=STCharacters→HKVariants。
  表缺失时构建器回落内联 `_S2T_PAIRS`（训练机旧布局兼容），回落即 manifest 无证据——
  CI 侧表必须在场（L0/测试断言覆盖）。
- 版本变更（OpenCC 升级/表增删）= 语料字节变更 = 独立 dataVersion 批。
- Apache-2.0 §4(c)：保留本声明与来源链接（本文件即满足）；包内 `opencc/NOTICE.txt`
  另有 OpenCC 项目署名。
