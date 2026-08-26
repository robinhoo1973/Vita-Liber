# -*- coding: utf-8 -*-
"""青囊书 Vita Liber — 空态插画与 App 图标母版定义。

插画规范（ui-ux-spec §3.4）：单色线条风（monoline），画布 240×180，
描边 4px、圆头圆角；template 渲染，随深浅色模式自动适配。
P0 六类空态（分类复用）+ 1 张 onboarding 主视觉。
"""

ILLUSTRATIONS = {
    "ill-empty-records": (  # 空档案：文档/就诊/观察/指标/疫苗共用
        '<path d="M60 92V80a12 12 0 0 1 12-12h26l12 14h58a12 12 0 0 1 12 12v40a12 12 0 0 1-12 12H72a12 12 0 0 1-12-12V92Z"/>'
        '<path d="M120 132c-13-8.6-18.5-14.9-18.5-20.9 0-5.4 4.5-9.6 9.6-9.6 3.7 0 6.9 1.9 8.9 5 2-3.1 5.2-5 8.9-5 5.1 0 9.6 4.2 9.6 9.6 0 6-5.5 12.3-18.5 20.9Z"/>'
        '<rect x="168" y="36" width="30" height="38" rx="5" transform="rotate(8 183 55)"/>'
        '<path d="m176 48 15 2M175 56l11 1.5" transform="rotate(8 183 55)"/>'
        '<path d="M46 52h12M52 46v12"/>'
        '<path d="M196 96h10M201 91v10"/>'
    ),
    "ill-empty-reminders": (  # 空提醒：预约/用药/随访共用
        '<path d="M120 42c-25 0-42 18-42 43v13c0 6-3 11.5-7.5 17L64 124h112l-6.5-9c-4.5-5.5-7.5-11-7.5-17V85c0-25-17-43-42-43Z"/>'
        '<path d="M102 130a18 18 0 0 0 36 0"/>'
        '<path d="M120 30v-8" opacity=".5"/>'
        '<rect x="28" y="116" width="44" height="38" rx="9"/>'
        '<path d="M38 110v10M62 110v10M28 128h44"/>'
        '<path d="M196 60v12M190 66h12"/>'
        '<path d="M186 100h10M191 95v10"/>'
    ),
    "ill-empty-search": (  # 无搜索结果
        '<circle cx="106" cy="84" r="46"/>'
        '<path d="m140 118 32 32"/>'
        '<path d="M90 72h34M90 86h22" opacity=".45"/>'
        '<path d="M44 44h16M188 56h12M52 138h12"/>'
        '<circle cx="176" cy="120" r="3"/>'
    ),
    "ill-empty-ai": (  # AI 无资料 / 无授权
        '<path d="M76 46h88a16 16 0 0 1 16 16v40a16 16 0 0 1-16 16h-62l-24 20v-20h-2a16 16 0 0 1-16-16V62a16 16 0 0 1 16-16Z"/>'
        '<path d="M108 74c.9 5.9 3.1 8.1 9 9-5.9.9-8.1 3.1-9 9-.9-5.9-3.1-8.1-9-9 5.9-.9 8.1-3.1 9-9Z"/>'
        '<path d="M134 88c.55 3.5 1.9 4.85 5.4 5.4-3.5.55-4.85 1.9-5.4 5.4-.55-3.5-1.9-4.85-5.4-5.4 3.5-.55 4.85-1.9 5.4-5.4Z"/>'
        '<path d="M40 152 200 32" stroke-dasharray="2 14"/>'
    ),
    "ill-empty-medicine-box": (  # 空药箱与批次
        '<rect x="62" y="70" width="116" height="74" rx="14"/>'
        '<path d="M104 70V58a14 14 0 0 1 14-14h4a14 14 0 0 1 14 14v12"/>'
        '<path d="M120 92v30M105 107h30"/>'
        '<g transform="rotate(-24 44 142)"><rect x="30" y="137" width="28" height="10" rx="5"/><path d="M44 137v10"/></g>'
        '<g transform="rotate(18 194 138)"><rect x="180" y="133" width="28" height="10" rx="5"/><path d="M194 133v10"/></g>'
        '<rect x="182" y="40" width="26" height="34" rx="6"/>'
        '<path d="M186 40v-6a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4v6"/>'
    ),
    "ill-empty-audit": (  # 空审计与分享记录（P1 备用）
        '<path d="M120 30l54 21v42c0 35-21.5 59-54 71-32.5-12-54-36-54-71V51l54-21Z"/>'
        '<path d="m100 92 14 14 27-29"/>'
        '<rect x="22" y="104" width="46" height="54" rx="10"/>'
        '<path d="M32 120h26M32 132h20M32 144h26"/>'
        '<path d="M198 78v12M192 84h12"/>'
    ),
    "ill-onboarding-family": (  # Onboarding 主视觉：家庭共创健康档案
        '<circle cx="82" cy="82" r="17"/>'
        '<path d="M46 150c6-22 19-33 36-33 8 0 15 2.4 21 7"/>'
        '<circle cx="158" cy="82" r="17"/>'
        '<path d="M194 150c-6-22-19-33-36-33-8 0-15 2.4-21 7"/>'
        '<circle cx="120" cy="114" r="12.5"/>'
        '<path d="M94 152c4.5-14 13.5-21 26-21s21.5 7 26 21"/>'
        '<path d="M120 26c-7.4-4.9-10.5-8.5-10.5-12 0-3.1 2.6-5.5 5.5-5.5 2 0 3.7 1 4.9 2.6a6.3 6.3 0 0 1 4.9-2.6c2.9 0 5.5 2.4 5.5 5.5 0 3.5-3.1 7.1-10.3 12Z" transform="translate(0 22)"/>'
        '<path d="M40 44h12M46 38v12"/>'
        '<path d="M192 118h10M197 113v10"/>'
    ),
}

# ───────────────────────── App 图标 1024×1024（青囊书：青囊药袋 × 医书） ─────────────────────────

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
      <stop offset="1" stop-color="#DCEBFA"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <path d="M392 430a120 120 0 0 1 240 0" fill="none" stroke="#BFDCf5" stroke-width="40" stroke-linecap="round"/>
  <path d="M512 470c-64-42-146-62-238-62v270c92 0 174 20 238 62 64-42 146-62 238-62V408c-92 0-174 20-238 62Z" fill="url(#page)"/>
  <path d="M512 470v258" stroke="#9CC4EA" stroke-width="14" stroke-linecap="round"/>
  <path d="M330 496c40 4 76 12 106 26M694 496c-40 4-76 12-106 26" stroke="#C9E0F6" stroke-width="12" stroke-linecap="round" fill="none"/>
  <g fill="#2FA35A">
    <rect x="477" y="300" width="70" height="190" rx="26"/>
    <rect x="417" y="360" width="190" height="70" rx="26"/>
  </g>
</svg>
"""
