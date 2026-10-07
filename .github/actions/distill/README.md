# .github/actions/distill/ —— 蒸馏/实体链接训练簇

> 设计依据:`refactor/2026-09-29-medical-llm-training-scenarios-ci-plan.md`(V1.2,本地规格)
> 本簇属 CI 辅助脚本(workflows/README.md 分簇纪律);训练代码公开无损——数据仅合成/公开。

## 目录

```
distill/
├── entlink/              确定性召回核心(纯 stdlib,Linux 本地可测)
│   ├── fold.py           查询/词条共同折叠(全半角/大小写/标点;繁简不在此层)
│   ├── fuzzy.py          CharSymSpell(delete 索引+验证距离,暴力对拍测试)
│   ├── pinyin.py         拼音层(lazy pypinyin;缺失显式降级并写入报告)
│   ├── catalog.py        四域目录装载(JSONL 适配器 + v4 SQLite 适配器,schema 闸 fail-closed)
│   ├── noise.py          三层合成噪声(形近/同音/繁简+结构;定种子)
│   ├── confusion_miner.py 混淆对动态挖掘(变体对/同音池从目录数据派生,非手写 hardcode)
│   └── recall.py         分层召回引擎 L0-L4(唯一对外入口)
├── corpus/               语料构建(§7.6 冻结纪律)
│   ├── builder.py        正对/硬负例/噪声增广/金标碰撞守卫/实体级切分
│   └── manifest.py       语料 manifest(sha256/许可义务/noise_model/自哈希校验)
├── gate/                 评测闸(§10)
│   ├── wording.py        BR-006 措辞负清单同源导出(解析 AlertEngine.swift,零复刻)
│   └── entlink_gate.py   SU-M15-ENTLINK:数据基线对照臂 + 模型五层闸 + tripwire
├── train/                训练工程(§7.4;torch 为 CI 期依赖)
│   ├── model.py          字符级双塔编码器(P3 可换 BGE-small-zh,循环不变)
│   ├── corpus_loader.py  语料装载/字符 vocab/定长 tokenize
│   ├── checkpoint.py     原子写+sha256 sidecar+恢复自检三闸(L1 loss/L2 状态/L3 权重)
├── build_corpus.py       prepare CLI
├── download_corpus.py    Release 资产下载/校验/age 解密/SQLite 闸 CLI
├── eval_entlink.py       评测闸 CLI(baseline/verdict 落盘)
├── probe_mps.py          MPS 探测段(真分配+matmul 对拍;不信任 is_available)
├── calibrate.py          100 步标定(真实训练步口径)
├── train_encoder.py      训练循环(墙钟预算优雅停机/断点续训/smoke)
├── run_tests.sh          本地测试入口(stdlib 测试 + 全簇语法验证)
（assets.json 已迁 .github/config/distill/assets.json —— prepare 用 Release 资产清单）
└── tests/                unittest 53 例(无 torch 依赖)
```

## 本地验证

```bash
bash .github/actions/distill/run_tests.sh                     # 单元测试 + py_compile(零第三方依赖)
python3 .github/actions/distill/build_corpus.py \
  --catalog-jsonl drug=a.jsonl,hospital=b.jsonl,department=c.jsonl,exam=d.jsonl \
  --out /tmp/corpus.jsonl --min-eval-entities 3        # 端到端冒烟(小目录调低 tripwire 下限)
python3 .github/actions/distill/eval_entlink.py --corpus /tmp/corpus.jsonl \
  --catalog-jsonl drug=a.jsonl,... --min-accepts 1 \
  --write-baseline /tmp/baselines --write-verdict /tmp/verdict.json
```

注意:**小/退化目录(2 字别名)会如实触发 tripwire 判红**——这是闸门在履行
"缺证据当有证据"纪律(ERR#27 族),生产目录(药 40k/院 7.8k 别名)不受影响。

## CI(workflow: llm.yml)

`tests(零依赖:53 例单测+全簇语法)→ prepare → calibrate(ubuntu CPU + macOS MPS 探测段)
→ smoke(≤30 步+断点续训回归)→ eval(基线臂+五层闸,verdict=fail 阻断 publish)
→ publish(内容寻址 append-only)`。

- 依赖钉版:`.github/config/requirements/requirements-distill-train-{linux,macos}.txt`
  (S-M6 哈希钉版纪律;torch 2.11.0,linux 走 pytorch.org CPU 索引,macos 走 PyPI arm64)。
  eval job 另钉 `requirements-distill-eval-linux.txt`(仅 pypinyin)——基线臂须与
  prepare 构建语料时同拼音层可用性(§10 复现纪律),不拖入 torch 训练依赖。
- `MEDICAL_DATA_AGE_IDENTITY` secret(名与私仓 provision 工具链一致)(公开仓 release 环境,dispatch-only):P1 未配置时
  prepare job 响亮失败并指引——本地原型用 dev 侧文件跑通 build/eval 不受影响。
- MPS 探测段输出 `MPS_USABLE=` 机器可读行;失败自动回落 CPU(§7.2 裁决自带回落条款)。
- 权限纪律:仅 publish job 持有 `contents: write`(gh release 上传,失败即炸 job,
  不做静默吞错);其余 job 默认 read。

## 纪律速记

- 训练数据零 PHI(合成+公开目录);TFDA OGDL v1 顯名义务随 manifest;
- 评测闸唯一权威 = 部署件在 ubuntu CPU 打分;训练侧(MPS)指标只作进度信号;
- checkpoint 存 Release(artifact 500MB 会爆);语料内容寻址 append-only;
- BR-006 词表从 AlertEngine.swift 同源导出,禁止 Python 复刻第二套。
