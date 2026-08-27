# -*- coding: utf-8 -*-
"""青囊书 × Microsoft Fluent UI System Icons 映射表。

字形来源：@fluentui/svg-icons（MIT License © Microsoft Corporation）。
本表只负责「概念 → 官方字形」映射；瓷砖底/渐变/高光为自有封装层。
未列出的概念（Fluent 无对应）由 icon_library.py 自绘补位。
"""

# our_name -> fluent 包内基础名（生成 _24_regular / _24_filled）
FLUENT = {
    # Tab 五模块（regular + filled 双态，ADR-021 / SP §2.1）
    "ic-tab-home": "home",
    "ic-tab-records": "board_heart",
    "ic-tab-reminders": "alert_badge",
    "ic-tab-me": "person_circle",
    # 通用操作
    "ic-add": "add_circle",
    "ic-search": "search",
    "ic-edit": "edit",
    "ic-delete": "delete",
    "ic-close": "dismiss",
    "ic-chevron-left": "chevron_left",
    "ic-chevron-right": "chevron_right",
    "ic-chevron-down": "chevron_down",
    "ic-more": "more_horizontal",
    "ic-filter": "filter",
    "ic-check-circle": "checkmark_circle",
    "ic-calendar": "calendar_ltr",
    "ic-clock": "clock",
    "ic-camera": "camera",
    "ic-photo": "image_multiple",
    "ic-scan-document": "scan_text",
    "ic-observe-frame": "scan_camera",
    "ic-share": "share_ios",
    "ic-export": "arrow_export_ltr",
    "ic-import": "arrow_import",
    "ic-sync": "arrow_sync",
    "ic-cloud-off": "cloud_off",
    "ic-settings": "settings",
    "ic-info": "info",
    "ic-warning": "warning",
    "ic-error": "error_circle",
    "ic-help": "question_circle",
    "ic-mic": "mic",
    "ic-waveform": "sound_wave_circle",
    "ic-keypad-delete": "backspace",
    "ic-star": "star",
    "ic-archive": "archive",
    "ic-tag": "tag",
    "ic-folder": "folder",
    "ic-bookmark": "bookmark",
    "ic-thumbs-up": "thumb_like",
    "ic-thumbs-down": "thumb_dislike",
    "ic-stop-octagon": "alert_urgent",
    "ic-headset": "headset",
    "ic-person-add": "person_add",
    # 医疗业务（ui-ux-spec §3.4 映射）
    "ic-stethoscope": "stethoscope",
    "ic-lab-clipboard": "clipboard_pulse",
    "ic-imaging-ecg": "heart_pulse",
    "ic-vaccine": "syringe",
    "ic-vitals-chart": "arrow_trending_lines",
    "ic-appointment": "calendar_checkmark",
    "ic-pill": "pill",
    "ic-emergency-card": "contact_card",
    "ic-blood-drop": "drop",
    "ic-timeline": "timeline",
    "ic-thermometer": "temperature",
    # 症状宫格（可复用部分）
    "ic-sym-eye": "eye",
    "ic-sym-secretion": "eyedropper",
    "ic-sym-generic": "temperature",
    "ic-sym-custom": "add_square",
    # 成员
    "ic-member-self": "person",
    "ic-member-partner": "person_heart",
    "ic-member-family": "people_team",
    # 安全与隐私
    "ic-lock": "lock_closed",
    "ic-shield": "shield",
    "ic-faceid": "scan_person",
    "ic-eye": "eye",
    "ic-eye-off": "eye_off",
    "ic-sos": "call",
    "ic-audit-shield": "shield_keyhole",
    "ic-device": "phone",
    # Pro 与订阅
    "ic-pro-diamond": "premium",
    "ic-cloud-subscription": "cloud_sync",
    "ic-family-share": "people_sync",
    "ic-restore-purchase": "arrow_rotate_counterclockwise",
    # 检查设备 / 器官（官方可用优先）
    "ic-xray": "xray",
    "ic-ward-bed": "bed",
    "ic-wheelchair": "wheelchair_access",
    "ic-organ-brain": "brain",
}

# ───────────────────────── Health Icons（CC0 公共领域，48×48 栅格） ─────────────────────────
# 来源：@iconify-json/healthicons / github.com/resolvetosavelives/healthicons

HEALTH_MAP = {
    # 器官
    "ic-organ-heart": "heart-organ",
    "ic-organ-lungs": "lungs",
    "ic-organ-liver": "liver",
    "ic-organ-stomach": "stomach",
    "ic-organ-kidney": "kidneys",
    "ic-organ-intestine": "intestine",
    "ic-organ-ear": "ear-outline",
    "ic-organ-foot": "foot",
    "ic-organ-mouth": "mouth",
    "ic-organ-nose": "nose",
    "ic-organ-tooth": "tooth",
    "ic-organ-joints": "joints",
    "ic-organ-spine": "spine",
    "ic-organ-skull": "skull",
    "ic-organ-blood-cells": "blood-cells",
    "ic-organ-thyroid": "thyroid",
    "ic-organ-throat": "ear-nose-throat",
    "ic-organ-prostate": "prostate",
    "ic-organ-bladder": "bladder",
    # 器械与设备
    "ic-blood-pressure": "blood-pressure-monitor",
    "ic-ultrasound": "ultrasound-scanner",
    "ic-prescription": "prescription-document",
    "ic-herbal": "medicine-mortar",
    "ic-hospital": "hospital",
    "ic-thermometer-digital": "thermometer-digital",
    "ic-medicines": "medicines",
    "ic-medicine-bottle": "medicine-bottle",
    "ic-syringe-vaccine": "syringe-vaccine",
    "ic-hearing-aid": "hearing-aid",
    "ic-intravenous-drip": "intravenous-drip",
    "ic-ventilator": "ventilator",
    "ic-oxygen-tank": "oxygen-tank",
    "ic-ambulance": "ambulance",
    "ic-crutches": "crutches",
    "ic-pulse-oximeter": "pulse-oximeter",
    "ic-test-tubes": "test-tubes",
    "ic-microscope": "microscope",
    "ic-bandage-adhesive": "bandage-adhesive",
    "ic-ppe-mask": "ppe-mask",
    "ic-ppe-gloves": "ppe-gloves",
    "ic-urine-sample": "urine-sample",
    # 成员 pictogram（CC0）
    # 检查类
    "ic-blood-sugar": "diabetes-measure",
}

# ───────────────────────── Tabler Icons（MIT，24×24 栅格） ─────────────────────────
# 注：ic-organ-bone 已迁移至 Lucide 源（V2.2），本表暂空。

TABLER_MAP = {
}

# ───────────────────────── Lucide Icons（ISC，24×24 栅格） ─────────────────────────
# 来源：github.com/lucide-icons/lucide（Feather 后继，ISC 许可，商业免费）

LUCIDE = {
    "ic-organ-bone": "bone",
    "ic-medicine-box": "pill-bottle",
    "ic-organ-hand": "hand",
    "ic-organ-donation": "heart-handshake",
    "ic-refill": "package-plus",
    # V2.6 交互与点缀（批次1 P0+主题）
    "ic-check": "check",
    "ic-bell": "bell",
    "ic-phone": "phone",
    "ic-undo": "undo-2",
    "ic-retry": "refresh-cw",
    "ic-minus": "minus",
    "ic-pin": "pin",
    "ic-send": "send",
    "ic-message": "message-square",
    "ic-ignore": "circle-x",
    "ic-sun": "sun",
    "ic-moon": "moon",
    # V2.6 语音/关怀（批次2）
    "ic-headphone": "headphones",
    "ic-volume": "volume-2",
    "ic-volume-off": "volume-x",
    "ic-ban": "octagon-x",
    "ic-replay": "rotate-ccw",
    "ic-pause": "pause",
    "ic-play": "play",
    "ic-language": "globe",
    "ic-skip": "skip-forward",
    # V2.6 指标/设备/Pro/点缀（批次3）
    "ic-weight": "scale",
    "ic-pulse": "activity",
    "ic-chart": "chart-column",
    "ic-flash": "zap",
    "ic-brush": "brush",
    "ic-attach": "link",
    "ic-copy": "copy",
    "ic-external-link": "external-link",
    "ic-exclamation": "circle-alert",
    "ic-bluetooth": "bluetooth",
    "ic-unlink": "unlink",
    "ic-backup": "cloud-upload",
    "ic-snooze": "alarm-clock",
    "ic-swap": "arrow-left-right",
    "ic-unlock": "lock-open",
    "ic-crown": "crown",
}

# ───────────────────────── Material Symbols（Apache-2.0，960 栅格实心） ─────────────────────────
# 来源：github.com/google/material-design-icons（symbols/web/…，materialsymbolsoutlined 样式）

MATERIAL = {
    "ic-member-father": "man",
    "ic-member-mother": "woman",
    "ic-member-son": "boy",
    "ic-member-daughter": "girl",
}

# ───────────────────────── Font Awesome Free（CC BY 4.0，512 栅格实心） ─────────────────────────
# 来源：github.com/FortAwesome/Font-Awesome（6.x，svgs/solid）；
# 子女图标优先级高于 Material Symbols（用户指定 CC BY 4.0）

FONTAWESOME = {
    "ic-member-son": "child",
    "ic-member-daughter": "child-dress",
}

# ───────────────────────── Material Design Icons（Apache 2.0，24×24 栅格） ─────────────────────────
# 来源：@iconify-json/mdi / github.com/Templarian/MaterialDesign（Pictogrammers）

MDI_MAP = {}
