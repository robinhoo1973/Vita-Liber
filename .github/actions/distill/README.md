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
│   ├── catalog.py        目录装载(JSONL/实体导出/legacy4–7 与 unified9 SQLite;v9 使用 catalog_entry 身份)
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
│   └── export_extraction_prompts/  导出器(main.swift,与 training/tools/export-prompts 正本同源)
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
├── fetch_catalog.py      CNB 医疗数据获取(v3):manifest.json 指针(Ed25519 2-of-2 验签) → package-<版本>.bin → 信封解密 → SQLite
├── catalog_contract.py   fetch/entlink/extract 共用的只读 storage gate、R/文件 SHA/descriptor 绑定
├── unified-contract-v1.json  与 CoreKit/producer/bridge 版本化同源的公共契约(不另造 schema mapper)
├── pinned-root.json      医疗信任根(公开信封:仅公钥+2-of-2 自签;**非秘密**)——2026-10-11 根投放批
│                         三处逐字节同源(CI 本目录/训练载荷 scripts/exchange//发布方 provision 源)
├── build_corpus.py       实体链接语料 CLI(抽样/规范名/域名排除/实体导出)
├── eval_entlink.py       实体链接评测闸 CLI(baseline/verdict 落盘)
├── eval_corpora.py       抽取/对话冻结产物独立复验 CLI(verdict=fail 阻断 publish)
├── probe_mps.py          MPS 探测(真分配+matmul 对拍)——**已退役**(2026-10-08);M4 本地执行面备用件,CI 零调用
├── calibrate.py          100 步标定(真实训练步口径;ubuntu CPU 吞吐基准;逐步落盘+SIGTERM 部分落盘)
├── train_encoder.py      编码器训练循环(墙钟预算优雅停机/断点续训/smoke)
├── run_tests.sh          本地测试入口(stdlib 测试 + 全簇语法验证)
└── tests/                unittest(含解密往返/物化契约/对话接地/目录 v7/指针验签契约等)
```

## 本地验证

```bash
bash .github/actions/distill/run_tests.sh                     # 单元测试 + py_compile(零第三方依赖即可跑)
# 数据面端到端(需 cryptography/pypinyin/tokenizers,见 requirements-distill-prepare-linux):
python3 .github/actions/distill/fetch_catalog.py --out-dir corpus-assets            # CNB 匿名 + 指针验签 + 信封解密(约 288MB 下载)
python3 .github/actions/distill/fetch_catalog.py --local-sqlite /path/catalog.sqlite --out-dir corpus-assets   # 离线输入,不绕过 storage gate
python3 .github/actions/distill/extract/catalog_source.py --catalog-sqlite corpus-assets/catalog.sqlite \
    --source-json corpus-assets/source.json --out-dir extract-data
bash .github/actions/distill/extract/export_prompts.sh                              # 需 swiftc(CI runner 预装)
python3 .github/actions/distill/extract/build_extraction_corpus.py --data-dir extract-data \
    --prompts-dir .github/actions/distill/extract/prompts --out-dir extraction-out --dry-run
python3 .github/actions/distill/dialogue/builder.py --catalog-dir extract-data --out-dir dialogue-out --dry-run
python3 .github/actions/distill/build_corpus.py --catalog-sqlite corpus-assets/catalog.sqlite \
    --source-json corpus-assets/source.json \
    --out entlink-out/corpus.jsonl --group-by-name --include-canonical-names --exclude-domains department \
    --max-terms-per-entity 3 --max-samples-per-domain "drug=200000,hospital=80000,diagnosis=60000,exam=30000" \
    --dump-entities corpus-assets/entities.jsonl
```

注意:**小/退化目录(2 字别名)会如实触发 tripwire 判红**——这是闸门在履行
"缺证据当有证据"纪律(ERR#27 族),生产目录(药 4 万唯一名/院 5.6 万)不受影响。

## unified9 消费契约与本地验收

- wire 保持 **pointer3 / embedded manifest2**，不升级也不改已签 legacy7 摘要算法。
  包名版本必须是正整数且 `<= catalogVersion`；续签可复用旧包，`catalogVersion`
  只用于防回滚序号，不能当内容身份。
- SQLite 接受显式无 marker 的 legacy physical4–7，以及 **physical9 / graph2 / App4**；
  physical8、9 缺失/损坏 `unified-medical-kg/v1` marker 均拒绝，不降级猜 legacy。
  9 必须同时满足 `catalog_meta.catalog_ready=true`、`content_scope=full`、
  `graph_release.scope=full`、`metadata.lifecycle=versioned`。
  partial/empty/development 研发库不能冒充可安装、可 serving 的正式快照。
- 逻辑内容身份 `R` 必须是小写 SHA64，且
  `signed dataVersion == signed contentSha256 == catalog_meta.data_version ==
  metadata.release_id == graph_release.release_id/content_sha256`。
  `metadata.activation_id` 绑定 `graph_activation.activation_id` 主键及当前 R；
  A→B→A 复用内容但生成新的 activation。KG-only 审核改变 R；历史/重封装可令
  **同 R 的文件 SHA 不同**，两者不可互代或只凭 R 跳过安装。
- 发布方负责公共 JSON 定义的完整逻辑摘要；首个 `serving_state` query 将 ready/scope/
  App/graph schema 纳入 R，另含 active aliases、identity、campus、当前审核等内容。
  当前 producer input/version 必须命中 `producer_import`，但这些输入指针不是逻辑 R。
  `producer_state_history` 是必需的输入生命周期审计表，绑定 `producer_import`；
  合法重试/状态变化的审计不进入逻辑摘要，可能只改变 SQLite 文件 SHA，不改变 R。
  `catalog_relation` 八列（含 `active`）仅表达目录关系，不扩展临床 `effective_facts`
  的七 relation 闭集合；active approved assertion 必须有绑定的非空 actor/rationale
  当前审核，不能自动批准旧事实。本批不新增临床 UI/API。
- App 共用 `MedicalCatalogStorageContract`：安装、最终路径、journal 恢复、两 Store
  复用 shape/current binding/release gate。安装/打开时做文件 SHA、integrity/FK、固定
  App 列与 region-scoped unique key 检查；不在每次查询重 hash 多 GB 文件或全扫历史 revision。
  `current_revision_uid` 可以指旧 revision，但必须属于同一个 entry，行数及当前绑定必验。
  `MedicalCatalogReadAccess` 稳定 DI 对象只在 journal 收尾成功后一次切换药品/四域读面；
  失败保留两旧读面；generation 栅栏拒绝迟到结果，同步清匹配缓存和刷新搜索状态。
  两池共用持锁的私有只读文件 pin（优先硬链接），避免 lazy reader 在 active 路径 rename
  后提前打开新代；最后一个读任务释放后清理，崩溃孤儿仅在可获得 lease 锁时回收。
  journal schema1 保持兼容，9 的已签 content/SQLite SHA 不得缺失。
- CI fetch 只接受 ZIP 内**唯一普通文件** `medical-catalog.sqlite`，拒目录/链接/额外成员，
  通过包/SQLite SHA、完整性、签名版本与 storage gate 后才替换输出。
  `source.json` 贯穿 physical/graph/App/marker/R/content/activation/ready/full/lifecycle/
  SQLite SHA 和原始已签 payload digest；离线模式显式标为 `local-sqlite`，不伪称签名验证。
  extraction 和 entlink 在一致只读 snapshot 内复核 descriptor；reference/detail 用
  `(region,source_id)`，索引 opaque ID 为 JSON `[region,source_id]`。
  `aliases_json` 的 `{text,type}` 对象数组与 legacy 字串数组均只投影文本，`type` 不设闭枚举；
  未知字段保留在原始只读 JSON，不将对象转为词面。App 四域解码/别名查询、CI 的 SQLite/
  JSONL/实体 dump 与训练负例回退均遵守此纪律，未知元数据不能作为别名查询命中。
  v9 entlink JOIN `catalog_entry` 读取真实 `entity_uid`，忽略 `--group-by-name`，绝不从
  source ID 反猜；legacy 合并也必须区分 region。
- `--dump-entities` 的 `_meta.storage_identity` 与 corpus manifest 可选
  `catalog_storage_identity` 保留上述身份并纳入 manifest 自哈希，评测拒绝同 R 但文件
  SHA/来源 trace 漂移或丢失。旧无此字段的 manifest1.0 仍兼容，不强制升级旧资产。
  评测用实体 dump 即可保留 trace；若改用 `--catalog-sqlite`，须与构建侧同传
  `--source-json`（构建侧有该输入时），不能默默丢弃签名来源。

共享夹具在 `CoreKit/Tests/CoreKitTests/Fixtures/unified/`：
`schema.sql`/`catalog.sql` 是公共 DDL 原字节副本；`app-consumer.sql` 仅用于消费者
负例/跨地区数据测试，不是发布方摘要证明。`bridge-full-v9.sqlite` 与
`bridge-reviewed-v9.sqlite` 通过授权的公开 `producer_fixture → build_unified → review`
API 生成，公共 JSON/DDL、R、activation、物理 SHA 锁在 `expected.json`。
两者 App 七张 typed 表逐值相同、KG-only 审核产生不同 R/文件 SHA；这些 **TEST-ONLY
合成 golden 不是实际 producer 发布/三仓生产验收已完成的声明**，不含患者数据。

Windows 可在项目内设置 `TEMP/TMP/TMPDIR` 后运行相关 unittest：
`tests.test_catalog_contract` / `tests.test_catalog_unified_pipeline` 覆盖真实
Ed25519 2-of-2、AES-GCM、固定 ZIP、descriptor、entlink/dump/eval/extract；
仅 mock 网络和时钟，不 mock 验签/解密/storage gate。加密测试需要既有钉版 cryptography，
缺失时明确 skip。现有 Swift heuristic 仅静态检查，不等于 Swift 编译。
**macOS 的 CoreKit/GRDB/CryptoKit 真编译与 iOS `MedicalCatalogStateTests` 必须另行验收**；
不通过 dispatch 发布工作流来冒充本地测试。

## CI(workflow: llm.yml,name: distill-llm;task=llm-pipeline)

`tests/tests-torch/export-prompts(前置并联) → fetch-catalog(CNB v3 零密钥取数+信封解密) →
materialize-catalog(SQLite→data-dir) → build-extraction/build-entlink/build-dialogue(三构建并联)
/ calibrate(ubuntu CPU 吞吐基准;记录面——不进裁决器 needs,不阻断完成时刻)
/ smoke-encoder/smoke-extraction/smoke-dialogue(三冒烟并联) / eval-entlink/eval-corpora(双闸)
→ acceptance(唯一裁决器:13 必需 job 全绿且 entlink∧corpora verdict=pass 才 go;未达=run 判红)
→ publish-corpus(内容寻址 append-only 到 Release distill-corpus;裁决器放行才翻转可见)`。

- 依赖钉版:`.github/config/requirements/requirements-distill-{prepare-linux,train-linux,train-macos}.txt`
  (S-M6 哈希钉版;train-macos = M4 本地执行面备用件,CI 零调用(2026-10-08 MPS 腿退役);
  生成脚本 `.github/actions/distill/make-requirements.sh`)。
- **零 secrets**:医疗数据匿名读取;信封主钥 = App 内嵌公开常量(与
  `ASRPackageCrypto.swift` 同值断言见 tests/test_fetch_catalog.py);指针 Ed25519 验签的
  信任根 `pinned-root.json` = 公开信封(仅公钥+自签;缺省解析=脚本同目录;缺根/无签名默认拒)
  ——其 TEST-ONLY 测试夹具在 `CoreKit/Tests/CoreKitTests/Fixtures/medical/`,严禁入生产位
  (契约见 tests/test_fetch_catalog_trust.py)。
- 语料产物:`corpus.jsonl`(实体链接)/`extraction_*.jsonl`(抽取)/`dialogue_*.jsonl`(对话)
  三面齐全(2026-10-08 起:对话面**发布暂缓**——构建/复验照常进 artifact,publish 清单在
  D-1(FR25.10/D3)裁决前不含 dialogue_*);`--dump-entities` 导出的实体模型随语料走
  (eval 据此重建索引,免二次下载 3.4GB 目录)。
- 训练落点(§7.5):托管 CPU 只跑烟雾;全量生成式训练在私仓自托管 GPU 消费本流水线发布的冻结语料。
- 权限纪律:仅 publish 与 llama-xcframework job 持有 `contents: write`(gh release 上传,失败即炸 job,
  不做静默吞错);其余 job 默认 read。

## 纪律速记

- 训练数据零 PHI(合成+公开目录);TFDA OGDL v1 顯名义务随 manifest;用户数据进训练永久禁止;
- 评测闸唯一权威 = 冻结语料/部署件在 ubuntu 的复验与打分;训练侧(私仓 GPU / M4 本地)指标只作进度信号;
- checkpoint 存 Release(artifact 500MB 会爆);语料内容寻址 append-only;
- BR-006 词表从 AlertEngine.swift 同源导出、BR-012/高风险词表从 AILocal.swift 同源导出,禁止 Python 复刻第二套;
- 对话语料的 assistant 事实片段必须逐字引用资料(dialogue/grounding.py 机械复验);
- 与训练机逐字节同源文件:extract/{build_extraction_corpus,extraction_noise}.py、gen/model_minimind.py、
  gen/tokenizer*.json——任何修改两侧同步(训练/推理同分布的组成部分)。
