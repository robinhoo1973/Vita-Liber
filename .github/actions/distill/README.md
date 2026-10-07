# .github/actions/distill/ —— 蒸馏/训练簇(实体链接 + 抽取 + 接地对话)

> 设计依据:`refactor/2026-09-29-medical-llm-training-scenarios-ci-plan.md`(§7 训练落点/§10 评测闸)
> 数据源(2026-10-07):CNB `robinhoo1973/Resources` release `medical-data`(匿名只读;
> 本地 producer 唯一写者;信封解密用 App 内嵌公开包钥,全链零密钥)。见
> `refactor/discussions/2026-10-07-distill-ci-medical-data-v2.md`。
> 本簇属 CI 辅助脚本(workflows/README.md 分簇纪律);训练代码公开无损——数据仅合成/公开。

## 目录

```
distill/
├── entlink/              确定性召回核心(纯 stdlib,Linux 本地可测)
│   ├── fold.py           查询/词条共同折叠(全半角/大小写/标点;繁简不在此层)
│   ├── fuzzy.py          CharSymSpell(delete 索引+验证距离,暴力对拍测试)
│   ├── pinyin.py         拼音层(lazy pypinyin;缺失显式降级并写入报告)
│   ├── catalog.py        目录装载(JSONL/实体导出/v4–v7 SQLite 适配器;group_by_name 合并;fail-closed)
│   ├── noise.py          三层合成噪声(形近/同音/繁简+结构;定种子)
│   ├── confusion_miner.py 混淆对动态挖掘(变体对/同音池从目录数据派生,非手写 hardcode)
│   └── recall.py         分层召回引擎 L0-L4(唯一对外入口)
├── corpus/               实体链接语料(§7.6 冻结纪律)
│   ├── builder.py        正对/硬负例/噪声增广/金标守卫/实体级切分/确定性抽样层
│   └── manifest.py       语料 manifest(sha256/许可义务/noise_model/自哈希校验)
├── extract/              抽取语料(ASR/OCR 文本 → span JSON;构建器自训练机正本迁入)
│   ├── build_extraction_corpus.py  正本迁入(改动仅:数据源注记/datamatrix 同目录/默认路径)
│   ├── extraction_noise.py         OCR/ASR 段级噪声(与训练机逐字节一致纪律)
│   ├── datamatrix.py               「类型×地区」矩阵(CELLS 逐字保留;裁掉 TUI)
│   ├── catalog_source.py           目录 SQLite → data-dir 物化适配层(CI 侧唯一新焊点)
│   ├── export_prompts.sh           从 CoreKit Domain 编译导出提示词/卡种规格(训练/推理同分布)
│   └── export_extraction_prompts/  导出器(main.swift,与 training/shared 正本同源)
├── dialogue/             接地转述对话语料(计划文档 §6 S6 合规形态)
│   ├── builder.py        四态(restate/clarify/refuse/emergency)合成 + 全量闸
│   ├── grounding.py      接地校验(逐字片段 + 残余连接词字表;构建与复验共用)
│   └── safety_lexicon.py 急救/高风险词表同源导出(解析 AILocal.swift,零复刻)
├── gate/                 评测闸(§10)
│   ├── wording.py        BR-006 措辞负清单同源导出(解析 AlertEngine.swift,零复刻)
│   └── entlink_gate.py   SU-M15-ENTLINK:数据基线对照臂 + 模型五层闸 + tripwire
├── gen/                  生成式训练(与训练机 minimind 栈同源;smoke job 执行面)
│   ├── model_minimind.py 模型正本迁入(逐字节同源;权重跨机消费)
│   ├── tokenizer.json / tokenizer_config.json   编码器与 ChatML 模板
│   ├── sft_dataset.py    ChatML 数据集(100% 剥离空 think 帧;assistant 段掩码;截断守卫)
│   └── train_sft_smoke.py 烟雾训练(预算优雅停机/checkpoint 原子写+sha256/续训回归)
├── train/                编码器训练工程(§7.4;torch 为 CI 期依赖)
│   ├── model.py          字符级双塔编码器(P3 可换 BGE-small-zh,循环不变)
│   ├── corpus_loader.py  语料装载/字符 vocab/定长 tokenize
│   ├── checkpoint.py     原子写+sha256 sidecar+恢复自检三闸(L1 loss/L2 状态/L3 权重)
├── fetch_catalog.py      CNB 医疗数据获取(v3):manifest.json 指针 → package-<版本>.bin → 信封解密 → SQLite
├── build_corpus.py       实体链接语料 CLI(抽样/规范名/域名排除/实体导出)
├── eval_entlink.py       实体链接评测闸 CLI(baseline/verdict 落盘)
├── eval_corpora.py       抽取/对话冻结产物独立复验 CLI(verdict=fail 阻断 publish)
├── probe_mps.py          MPS 探测段(真分配+matmul 对拍;不信任 is_available)
├── calibrate.py          100 步标定(真实训练步口径)
├── train_encoder.py      编码器训练循环(墙钟预算优雅停机/断点续训/smoke)
├── run_tests.sh          本地测试入口(stdlib 测试 + 全簇语法验证)
└── tests/                unittest(含解密往返/物化契约/对话接地/目录 v7 等)
```

## 本地验证

```bash
bash .github/actions/distill/run_tests.sh                     # 单元测试 + py_compile(零第三方依赖即可跑)
# 数据面端到端(需 cryptography/pypinyin/tokenizers,见 requirements-distill-prepare-linux):
python3 .github/actions/distill/fetch_catalog.py --out-dir corpus-assets            # CNB 匿名 + 信封解密(约 288MB 下载)
python3 .github/actions/distill/fetch_catalog.py --local-sqlite /path/catalog.sqlite --out-dir corpus-assets   # 开发旁路
python3 .github/actions/distill/extract/catalog_source.py --catalog-sqlite corpus-assets/catalog.sqlite --out-dir extract-data
bash .github/actions/distill/extract/export_prompts.sh                              # 需 swiftc(CI runner 预装)
python3 .github/actions/distill/extract/build_extraction_corpus.py --data-dir extract-data \
    --prompts-dir .github/actions/distill/extract/prompts --out-dir extraction-out --dry-run
python3 .github/actions/distill/dialogue/builder.py --catalog-dir extract-data --out-dir dialogue-out --dry-run
python3 .github/actions/distill/build_corpus.py --catalog-sqlite corpus-assets/catalog.sqlite \
    --out entlink-out/corpus.jsonl --group-by-name --include-canonical-names --exclude-domains department \
    --max-terms-per-entity 3 --max-samples-per-domain "drug=200000,hospital=80000,diagnosis=60000,exam=30000" \
    --dump-entities corpus-assets/entities.jsonl
```

注意:**小/退化目录(2 字别名)会如实触发 tripwire 判红**——这是闸门在履行
"缺证据当有证据"纪律(ERR#27 族),生产目录(药 4 万唯一名/院 5.6 万)不受影响。

## CI(workflow: llm.yml,name: distill-llm;task=llm-pipeline)

`tests(单测+语法;轻依赖同装) → prepare(CNB 取数+解密+三面语料冻结) → calibrate(ubuntu CPU +
macOS MPS 探测段)/ smoke(编码器 30 步 + 生成式 SFT 两语料 20 步 + 续训回归) /
eval(entlink 基线闸 + 抽取/对话复验闸,双闸合一 verdict=fail 阻断 publish)
→ publish(内容寻址 append-only 到 Release distill-corpus)`。

- 依赖钉版:`.github/config/requirements/requirements-distill-{prepare-linux,train-linux,train-macos}.txt`
  (S-M6 哈希钉版;生成脚本 `.github/actions/distill/make-requirements.sh`)。
- **零 secrets**:医疗数据匿名读取;信封主钥 = App 内嵌公开常量(与
  `ASRPackageCrypto.swift` 同值断言见 tests/test_fetch_catalog.py)。
- 语料产物:`corpus.jsonl`(实体链接)/`extraction_*.jsonl`(抽取)/`dialogue_*.jsonl`(对话)
  三面齐全(2026-10-08 起:对话面**发布暂缓**——构建/复验照常进 artifact,publish 清单在
  D-1(FR25.10/D3)裁决前不含 dialogue_*);`--dump-entities` 导出的实体模型随语料走
  (eval 据此重建索引,免二次下载 3.4GB 目录)。
- 训练落点(§7.5):托管 CPU 只跑烟雾;全量生成式训练在私仓自托管 GPU 消费本流水线发布的冻结语料。
- 权限纪律:仅 publish 与 llama-xcframework job 持有 `contents: write`(gh release 上传,失败即炸 job,
  不做静默吞错);其余 job 默认 read。

## 纪律速记

- 训练数据零 PHI(合成+公开目录);TFDA OGDL v1 顯名义务随 manifest;用户数据进训练永久禁止;
- 评测闸唯一权威 = 冻结语料/部署件在 ubuntu 的复验与打分;训练侧(MPS)指标只作进度信号;
- checkpoint 存 Release(artifact 500MB 会爆);语料内容寻址 append-only;
- BR-006 词表从 AlertEngine.swift 同源导出、BR-012/高风险词表从 AILocal.swift 同源导出,禁止 Python 复刻第二套;
- 对话语料的 assistant 事实片段必须逐字引用资料(dialogue/grounding.py 机械复验);
- 与训练机逐字节同源文件:extract/{build_extraction_corpus,extraction_noise}.py、gen/model_minimind.py、
  gen/tokenizer*.json——任何修改两侧同步(训练/推理同分布的组成部分)。
