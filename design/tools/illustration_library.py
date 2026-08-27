# -*- coding: utf-8 -*-
"""青囊书 Vita Liber — 空态插画与 App 图标母版（Fluent 彩色扁平风）。

插画规范：画布 240×180，彩色渐变面 + 白色元素 + 少量描边，
与图标瓷砖体系同一色彩语言（brand 蓝 / success 绿 / warning 琥珀 / danger 红）。
P0 六类空态（ui-ux-spec §3.4 分类复用）+ 1 张 onboarding 主视觉。
"""

ILLUSTRATIONS = {
    "ill-empty-records": (  # 空档案：文档/就诊/观察/指标/疫苗共用
        '<defs>'
        '<linearGradient id="fold" x1="0" y1="0" x2=".8" y2="1">'
        '<stop offset="0" stop-color="#5B8DEF"/><stop offset="1" stop-color="#3A63D6"/></linearGradient>'
        "</defs>"
        '<rect x="158" y="30" width="36" height="46" rx="7" transform="rotate(8 176 53)" fill="#FFFFFF" stroke="#C9D8F2" stroke-width="3"/>'
        '<path d="m168 44 16 2M167 54l12 1.6" transform="rotate(8 176 53)" stroke="#5B8DEF" stroke-width="4" stroke-linecap="round"/>'
        '<path d="M56 96V82a14 14 0 0 1 14-14h30l13 15h57a14 14 0 0 1 14 14v43a14 14 0 0 1-14 14H70a14 14 0 0 1-14-14V96Z" fill="url(#fold)"/>'
        '<path d="M56 100h128v38a14 14 0 0 1-14 14H70a14 14 0 0 1-14-14v-38Z" fill="#1E4CB0" opacity=".18"/>'
        '<path d="M120 138c-14.5-9.6-20.5-16.4-20.5-22.9 0-5.9 4.9-10.5 10.5-10.5 4 0 7.5 2.1 10 5.5 2.5-3.4 6-5.5 10-5.5 5.6 0 10.5 4.6 10.5 10.5 0 6.5-6 13.3-20.5 22.9Z" fill="#FFFFFF"/>'
        '<path d="M42 52h14M49 45v14" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
        '<path d="M198 100h12M204 94v12" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
    ),
    "ill-empty-reminders": (  # 空提醒：预约/用药/随访共用
        '<defs>'
        '<linearGradient id="bell" x1="0" y1="0" x2=".7" y2="1">'
        '<stop offset="0" stop-color="#FFB03A"/><stop offset="1" stop-color="#EF7A0E"/></linearGradient>'
        "</defs>"
        '<path d="M120 40c-26 0-44 19-44 45v14c0 6-3 12-7.5 17.5L62 126h116l-6.5-9.5C167 111 164 105 164 99V85c0-26-18-45-44-45Z" fill="url(#bell)"/>'
        '<path d="M120 40c-26 0-44 19-44 45v6c26-10 62-10 88 0v-6c0-26-18-45-44-45Z" fill="#FFFFFF" opacity=".22"/>'
        '<path d="M103 124a17 17 0 0 0 34 0" fill="none" stroke="#D96F08" stroke-width="7" stroke-linecap="round"/>'
        '<path d="M120 30v-8" stroke="#98A1B3" stroke-width="5" stroke-linecap="round" opacity=".6"/>'
        '<rect x="26" y="112" width="48" height="42" rx="10" fill="#FFFFFF" stroke="#C9D8F2" stroke-width="3"/>'
        '<path d="M26 126h48" stroke="#C9D8F2" stroke-width="3"/>'
        '<path d="M37 106v10M63 106v10" stroke="#5B8DEF" stroke-width="5" stroke-linecap="round"/>'
        '<circle cx="41" cy="141" r="3.5" fill="#5B8DEF"/>'
        '<path d="M192 58h14M199 51v14" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
        '<path d="M182 96h12M188 90v12" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
    ),
    "ill-empty-search": (  # 无搜索结果
        '<circle cx="106" cy="84" r="46" fill="#EAF2FE" stroke="#5B8DEF" stroke-width="8"/>'
        '<path d="M88 70h36M88 84h24" stroke="#B9CFF2" stroke-width="6" stroke-linecap="round"/>'
        '<path d="m140 118 32 32" stroke="#56627D" stroke-width="12" stroke-linecap="round"/>'
        '<path d="M44 42h16M186 54h14M50 136h12" stroke="#C9CFDD" stroke-width="5" stroke-linecap="round"/>'
        '<circle cx="178" cy="118" r="5" fill="#F0A415"/>'
    ),
    "ill-empty-ai": (  # AI 无资料 / 无授权：双半脑 + AI 徽章（参考用户指定样式）
        '<defs>'
        '<linearGradient id="bl" x1="0" y1="0" x2=".7" y2="1">'
        '<stop offset="0" stop-color="#5B8DEF"/><stop offset="1" stop-color="#3A63D6"/></linearGradient>'
        '<linearGradient id="pk" x1="0" y1="0" x2=".7" y2="1">'
        '<stop offset="0" stop-color="#F06A8A"/><stop offset="1" stop-color="#D14D70"/></linearGradient>'
        "</defs>"
        '<g transform="translate(115 159) scale(1.3 1.941) translate(-120 -92)">'
        '<path d="M116 30c-8-7-20-7-27 1-3-2-8-2-11 1-5 4-6 11-3 16-5 3-7 9-5 15 1 5 5 8 10 9-1 5 1 11 6 14 4 3 9 2 12-1 3 4 9 5 13 2 3-2 5-5 5-9V38c0-3-1-6-3-8Z" fill="url(#bl)"/>'
        '<path d="M92 56h16M92 74h12M96 56l16 12" stroke="#FFFFFF" stroke-width="3.5" fill="none" stroke-linecap="round"/>'
        '<circle cx="90" cy="56" r="4" fill="#FFFFFF"/><circle cx="90" cy="74" r="4" fill="#FFFFFF"/><circle cx="112" cy="68" r="4" fill="#FFFFFF"/>'
        '<path d="M124 30c8-7 20-7 27 1 3-2 8-2 11 1 5 4 6 11 3 16 5 3 7 9 5 15-1 5-5 8-10 9 1 5-1 11-6 14-4 3-9 2-12-1-3 4-9 5-13 2-3-2-5-5-5-9V38c0-3 1-6 3-8Z" fill="url(#pk)"/>'
        '<path d="M148 52c8 5 11 14 8 24M160 64c3 6 3 13 0 19" stroke="#FFFFFF" stroke-width="3.5" fill="none" stroke-linecap="round"/>'
        '</g>'
        '<rect x="82" y="67" width="76" height="46" rx="12" fill="#3BB873"/>'
        '<text x="120" y="100" font-family="DejaVu Sans, sans-serif" font-size="32" font-weight="bold" fill="#FFFFFF" text-anchor="middle">AI</text>'
        '<path d="M38 44h14M45 37v14" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
        '<path d="M196 122h12M202 116v12" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
    ),
    "ill-empty-medicine-box": (  # 空药箱与批次
        '<rect x="60" y="68" width="120" height="78" rx="15" fill="#FFFFFF" stroke="#C9D8F2" stroke-width="4"/>'
        '<path d="M104 68V56a15 15 0 0 1 15-15h2a15 15 0 0 1 15 15v12" fill="none" stroke="#C9D8F2" stroke-width="7"/>'
        '<path d="M60 108h120v23a15 15 0 0 1-15 15H75a15 15 0 0 1-15-15v-23Z" fill="#5B8DEF" opacity=".08"/>'
        '<path d="M120 86v34M103 103h34" stroke="#E8475E" stroke-width="10" stroke-linecap="round"/>'
        '<g transform="rotate(-24 42 144)">'
        '<rect x="26" y="138" width="32" height="12" rx="6" fill="#FFB03A"/>'
        '<path d="M42 138v12" stroke="#FFFFFF" stroke-width="3.5"/></g>'
        '<g transform="rotate(18 196 140)">'
        '<rect x="180" y="134" width="32" height="12" rx="6" fill="#2FBDB3"/>'
        '<path d="M196 134v12" stroke="#FFFFFF" stroke-width="3.5"/></g>'
        '<rect x="180" y="38" width="30" height="40" rx="7" fill="#FFFFFF" stroke="#C9D8F2" stroke-width="4"/>'
        '<rect x="184" y="28" width="22" height="12" rx="4" fill="#E8475E"/>'
        '<path d="M42 56h14M49 49v14" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
    ),
    "ill-empty-audit": (  # 空审计与分享记录（P1 备用）
        '<defs>'
        '<linearGradient id="shld" x1="0" y1="0" x2=".75" y2="1">'
        '<stop offset="0" stop-color="#38A3E8"/><stop offset="1" stop-color="#1773C6"/></linearGradient>'
        "</defs>"
        '<path d="M120 28l56 22v44c0 36-22.5 61-56 73-33.5-12-56-37-56-73V50l56-22Z" fill="url(#shld)"/>'
        '<path d="M120 28l56 22v14c-37 12-75 12-112 0V50l56-22Z" fill="#FFFFFF" opacity=".18"/>'
        '<path d="m98 90 15 15 30-32" fill="none" stroke="#FFFFFF" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>'
        '<rect x="20" y="100" width="50" height="58" rx="11" fill="#FFFFFF" stroke="#C9D8F2" stroke-width="4"/>'
        '<path d="M32 118h26M32 131h20M32 144h26" stroke="#5B8DEF" stroke-width="5" stroke-linecap="round"/>'
        '<path d="M196 76h14M203 69v14" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
    ),
    "ill-onboarding-family": (  # Onboarding 主视觉：家庭共创健康档案
        '<circle cx="82" cy="84" r="19" fill="#38A3E8"/>'
        '<path d="M44 154c6.5-24 20-36 38-36 8.5 0 16 2.6 22.5 7.6L98 154Z" fill="#38A3E8"/>'
        '<path d="M98 154l6.5-28.4c6.5-5 14-7.6 22.5-7.6 8 0 15 2.4 21 7L158 154Z" fill="#2FBDB3" opacity="0"/>'
        '<circle cx="158" cy="84" r="19" fill="#E869A9"/>'
        '<path d="M196 154c-6.5-24-20-36-38-36-8.5 0-16 2.6-22.5 7.6L142 154Z" fill="#E869A9"/>'
        '<path d="M142 154l-4.5-28.4a37 37 0 0 0-35 0L98 154Z" fill="#FFFFFF" opacity="0"/>'
        '<circle cx="120" cy="116" r="14" fill="#35C08C"/>'
        '<path d="M92 154c4.8-15.5 14.5-23 28-23s23.2 7.5 28 23Z" fill="#35C08C"/>'
        '<path d="M120 22c-8.2-5.4-11.6-9.4-11.6-13.3 0-3.4 2.8-6.1 6.1-6.1 2.2 0 4.1 1.1 5.5 2.9a7 7 0 0 1 5.5-2.9c3.3 0 6.1 2.7 6.1 6.1 0 3.9-3.4 7.9-11.6 13.3Z" fill="#FF5A6E" transform="translate(0 26)"/>'
        '<path d="M38 46h16M46 38v16" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
        '<path d="M190 116h12M196 110v12" stroke="#F0A415" stroke-width="5" stroke-linecap="round"/>'
    ),
}

# ── App 图标 1024×1024：翻开的书 + 左页青囊 + 右页笔 ──────────────────────────

APP_ICON_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1583E0"/>
      <stop offset=".55" stop-color="#0A66C2"/>
      <stop offset="1" stop-color="#064B92"/>
    </linearGradient>
    <radialGradient id="glow" cx=".3" cy=".18" r=".9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity=".22"/>
      <stop offset=".55" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="page" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#D7E9FA"/>
    </linearGradient>
    <linearGradient id="pouch" x1="0" y1="0" x2=".6" y2="1">
      <stop offset="0" stop-color="#3BC4B8"/>
      <stop offset="1" stop-color="#0E8A81"/>
    </linearGradient>
    <linearGradient id="pen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1E7AD4"/>
      <stop offset="1" stop-color="#064B92"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>

  <g transform="translate(512 570) scale(1.24) translate(-512 -570)">
  <path d="M512 462C446 420 362 400 232 400l0 276c130 0 214 20 280 62Z"
        fill="#053B72" opacity=".35" transform="translate(0 18)"/>
  <path d="M512 462c66-42 150-62 280-62l0 276c-130 0-214 20-280 62Z"
        fill="#053B72" opacity=".35" transform="translate(0 18)"/>

  <path d="M512 462C446 420 362 400 232 400L232 676C362 676 446 696 512 738Z" fill="url(#page)"/>
  <path d="M512 462c66-42 150-62 280-62l0 276c-130 0-214 20-280 62Z" fill="url(#page)"/>
  <path d="M512 462v264" stroke="#9CC4EA" stroke-width="14" stroke-linecap="round"/>
  <path d="M296 446c58 4 116 16 168 40M728 446c-58 4-116 16-168 40"
        stroke="#C9E0F6" stroke-width="10" stroke-linecap="round" fill="none"/>

  <ellipse cx="372" cy="688" rx="92" ry="15" fill="#064B92" opacity=".28"/>
  <path d="M296 566c0-46 34-76 76-76s76 30 76 76v50c0 54-34 86-76 86s-76-32-76-86Z"
        fill="#0A5F58" opacity=".4" transform="translate(0 12)"/>
  <path d="M296 566c0-46 34-76 76-76s76 30 76 76v50c0 54-34 86-76 86s-76-32-76-86Z" fill="url(#pouch)"/>
  <ellipse cx="340" cy="520" rx="52" ry="30" fill="#FFFFFF" opacity=".12"/>
  <rect x="330" y="458" width="108" height="36" rx="18" fill="#0A5F58"/>
  <circle cx="384" cy="476" r="15" fill="#0A5F58"/>
  <g fill="#FFFFFF">
    <rect x="355" y="530" width="34" height="96" rx="12"/>
    <rect x="324" y="561" width="96" height="34" rx="12"/>
  </g>

  <ellipse cx="650" cy="580" rx="84" ry="12" transform="rotate(28 654 582)" fill="#064B92" opacity=".15"/>
  <g transform="translate(652 567) rotate(28)">
    <path d="M-20 62 0 116 20 62Z" fill="#0A66C2"/>
    <path d="M0 116V80" stroke="#FFFFFF" stroke-width="5" stroke-linecap="round"/>
    <rect x="-21" y="-64" width="42" height="128" rx="19" fill="url(#pen)"/>
    <rect x="-21" y="-64" width="42" height="18" fill="#052F5C"/>
    <rect x="-21" y="-2" width="42" height="12" fill="#FFFFFF" opacity=".35"/>
    <path d="M-9 -46v96" stroke="#FFFFFF" stroke-width="6" stroke-linecap="round" opacity=".28"/>
  </g>
  </g>
</svg>
"""
