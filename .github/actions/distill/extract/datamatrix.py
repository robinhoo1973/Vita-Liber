"""「数据类型 × 地区」矩阵 —— 训练/语料构建共用的单一事实源(CI 裁剪版)。

来源:refactor/tools/training/shared/trainlib/datamatrix.py(工作区正本,2026-09-27)。
2026-10-07 迁入 CI 簇(.github/actions/distill/extract/):**CELLS 表逐字保留**,仅移除交互菜单/
TUI 部分(select_matrix/tui/scan 的菜单消费面),保留 --cells 解析与文件解析纯函数——
CI 侧数据来自 catalog_source.py 物化出的 data-dir(不是本机抓取工作区)。

裁剪面记录:上游的菜单/键盘选择/scan CLI 不进 CI(CI 无终端、无本机数据存在性概念);
本文件与上游以 CELLS/CELL_BY_KEY/resolve_cells 语义一致为纪律。
"""
from __future__ import annotations

import os
from dataclasses import dataclass

TYPES = ("drugs", "hospitals", "departments", "diagnoses", "exams")
TYPE_LABELS = {"drugs": "药品", "hospitals": "医院/机构", "departments": "科室", "diagnoses": "疾病/诊断", "exams": "检查检验"}
REGIONS = ("cn", "hk", "tw")
REGION_LABELS = {"cn": "内地 CN", "hk": "香港 HK", "tw": "台湾 TW"}
# 语料构建器无条件需要的 canonical 药品合并产物(下界;CI 由 catalog_source.py 物化)
BASELINE_FILES = ("medical_details.jsonl", "medical_index.json")


@dataclass(frozen=True)
class Cell:
    type: str
    region: str
    files: tuple          # 相对 data/ 的文件;任一存在且非空即"可用"
    fetch: str            # fetch_drug_data | fetch_ref_data | manual | none(CI 侧仅作来源注记)
    how: str              # 直白说明:数据是什么、怎么获得
    sources: tuple = ()   # fetch_drug_data.sh 的源键(tw/hk/cn/nhsa)
    nmpa: bool = False    # 是否附带 NMPA 详情抓取
    derive: str = ""      # 非空 = 本格子没有独立文件,从 files 里的别家文件派生(如 hospital_tw.jsonl 的 depts 字段)


CELLS = (
    Cell("drugs", "cn", ("drugs_cn.jsonl", "drugs_nhsa.jsonl", "raw/nmpa/nmpa_rows.jsonl"), "fetch_drug_data",
         "大陆医保目录 PDF(约 4 千条)+ 国家医保局 NHSA 编码目录(27 万条)+ NMPA 详情(CAPTCHA 闸门,量小)", sources=("cn", "nhsa"), nmpa=True),
    Cell("drugs", "hk", ("hk_records.jsonl",), "fetch_drug_data", "香港卫生署注册药品(1.4 万条,多为英文名)", sources=("hk",)),
    Cell("drugs", "tw", ("tw_records.jsonl",), "fetch_drug_data", "台湾 TFDA 药品许可证(2.6 万条,繁体名 + 用法文本)", sources=("tw",)),
    Cell("hospitals", "cn", ("ref/hospital_cn.jsonl",), "manual", "卫健委医疗机构名录在 WAF 后无公开接口:手动导出 xlsx 转 NDJSON 放 data/ref/hospital_cn.jsonl"),
    Cell("hospitals", "hk", ("ref/hospital_hk.jsonl",), "fetch_ref_data",
         "香港醫健通 eHealth 登記機構 7,400+(診所/集團/私院/NGO)+ 衞生署私家醫院名單 + 醫管局設施目錄(fetch_ref_data.sh 自动)"),
    Cell("hospitals", "tw", ("ref/hospital_tw.jsonl",), "fetch_ref_data", "台湾健保特约医事机构 5 个数据集(fetch_ref_data.sh;info.nhi.gov.tw 需代理或在 CI 抓取)"),
    Cell("departments", "cn", ("ref/department_cn.jsonl",), "manual", "《医疗机构诊疗科目名录》:手动整理为 NDJSON 放 data/ref/department_cn.jsonl"),
    Cell("departments", "hk", ("ref/department_hk.jsonl",), "fetch_ref_data",
         "香港醫務委員會專科醫生名冊 66 專科(繁英)+ 醫管局專科門診/專職醫療部門(fetch_ref_data.sh 自动)"),
    Cell("departments", "tw", ("ref/department_tw.jsonl", "ref/hospital_tw.jsonl"), "fetch_ref_data",
         "台湾健保特约机构数据集的「診療科別」字段:随 hospitals/tw 一起抓取,从 hospital_tw.jsonl 的 depts 派生", derive="depts"),
    Cell("diagnoses", "cn", ("ref/diagnosis_cn.jsonl",), "manual", "医保版 ICD-10 在登录墙后:手动导出放 data/ref/diagnosis_cn.jsonl"),
    Cell("diagnoses", "hk", ("ref/diagnosis_hk.jsonl",), "fetch_ref_data",
         "衞生署住院病人疾病類別(ICD-10 分組 300+)+ 主要死因 + 衞生防護中心法定須呈報傳染病(fetch_ref_data.sh 自动;完整詞彙 HKCTT 為授權件)"),
    Cell("diagnoses", "tw", ("ref/diagnosis_tw.jsonl",), "fetch_ref_data", "台湾健保 ICD-10-CM 查询 API(fetch_ref_data.sh;需代理或 CI)"),
    Cell("exams", "cn", ("ref/exam_cn.jsonl",), "manual", "《医疗机构临床检验项目目录》(卫医发 180 号 .xls):手动转 NDJSON 放 data/ref/exam_cn.jsonl"),
    Cell("exams", "hk", ("ref/exam_hk.jsonl",), "manual",
         "香港無公開檢驗項目目錄:HKCTT 化驗術語(LOINC 對應)需 eHealth 授權下載,導出 NDJSON 放 data/ref/exam_hk.jsonl"),
    Cell("exams", "tw", ("ref/exam_tw.jsonl",), "fetch_ref_data", "台湾健保支付标准(检查检验项目,fetch_ref_data.sh;需代理或 CI)"),
)
CELL_BY_KEY = {f"{c.type}/{c.region}": c for c in CELLS}
# 药品格子 → fetch_drug_data.sh 源键 / 构建器 load_drugs 的 sources;旧 --sources 键 → 格子
DRUG_SOURCES_BY_REGION = {"cn": ("cn", "nhsa"), "hk": ("hk",), "tw": ("tw",)}
SOURCE_TO_CELL = {"cn": "drugs/cn", "nhsa": "drugs/cn", "hk": "drugs/hk", "tw": "drugs/tw"}


def cell_key(cell):
    return f"{cell.type}/{cell.region}"


def default_cells():
    return ["drugs/cn", "drugs/hk", "drugs/tw"]


def _split(value):
    if isinstance(value, str):
        return tuple(t.strip() for t in value.split(",") if t.strip())
    return tuple(t for t in (value or ()) if t)


def normalize_cells(cells):
    """表序、去重;未知键抛 ValueError。"""
    wanted = set(_split(cells))
    bad = sorted(wanted - set(CELL_BY_KEY))
    if bad:
        raise ValueError(f"unknown data cell(s): {bad} (expected <type>/<region>, types {TYPES}, regions {REGIONS})")
    return tuple(key for key in (cell_key(c) for c in CELLS) if key in wanted)


def resolve_cells(cells="", regions="", types="", sources=""):
    """训练入口 / 语料构建器共用的取舍规则:--cells > --regions/--types(交叉积)> 旧 --sources(药品格子)> 默认三地药品。
    参数为逗号串或序列;返回表序 tuple。"""
    cells, regions, types, sources = (_split(v) for v in (cells, regions, types, sources))
    if cells:
        return normalize_cells(cells)
    if regions or types:
        bad = [r for r in regions if r not in REGIONS] + [t for t in types if t not in TYPES]
        if bad:
            raise ValueError(f"unknown region/type value(s): {bad} (regions: {REGIONS}, types: {TYPES})")
        return normalize_cells(f"{t}/{r}" for t in (types or ("drugs",)) for r in (regions or REGIONS))
    if sources:
        bad = [t for t in sources if t not in SOURCE_TO_CELL]
        if bad:
            raise ValueError(f"unknown --sources value(s): {bad} (legacy keys: {tuple(SOURCE_TO_CELL)}; prefer --cells drugs/cn,...)")
        return normalize_cells(SOURCE_TO_CELL[t] for t in sources)
    return tuple(default_cells())


def drug_sources_for(cells):
    """选中格子里的药品源键(构建器 load_drugs / fetch_drug_data.sh)。"""
    return tuple(src for key in normalize_cells(cells) if key.startswith("drugs/") for src in DRUG_SOURCES_BY_REGION[key.split("/")[1]])


def cells_to_regions_types(selected):
    regions = tuple(r for r in REGIONS if any(k.endswith("/" + r) for k in selected))
    types = tuple(t for t in TYPES if any(k.startswith(t + "/") for k in selected))
    return regions, types


def cells_to_files(selected, data_dir):
    """选中格子里 data-dir 实际存在的文件(相对 data/)+ baseline。"""
    data_dir = str(data_dir)
    files = []
    for key in selected:
        cell = CELL_BY_KEY.get(key)
        if cell is None:
            continue
        for rel in cell.files:
            path = os.path.join(data_dir, rel)
            if os.path.isfile(path) and os.path.getsize(path) > 0 and rel not in files:
                files.append(rel)
    for rel in BASELINE_FILES:
        if rel not in files:
            files.append(rel)
    return files
