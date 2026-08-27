# Third-Party Notices — 设计资产字形来源

本目录字形文件按来源分三处 vendor，均为宽松许可、可直接商用：

## 1. Microsoft Fluent UI System Icons — MIT
- 目录：`design/icons/fluent/`
- 来源：npm `@fluentui/svg-icons` / github.com/microsoft/fluentui-system-icons
- 许可：MIT License © Microsoft Corporation（全文见下）

## 2. Health Icons — CC0 1.0（公共领域）
- 目录：`design/icons/healthicons/`
- 来源：npm `@iconify-json/healthicons` / github.com/resolvetosavelives/healthicons
- 许可：CC0 1.0 Universal——无版权限制，无需署名，可商用、修改、再分发

## 3. Tabler Icons — MIT
- 目录：`design/icons/tabler/`
- 来源：npm `@iconify-json/tabler` / github.com/tabler/tabler-icons
- 许可：MIT License © Paweł Kuna

## 4. Lucide — ISC
- 目录：`design/icons/lucide/`
- 来源：github.com/lucide-icons/lucide
- 许可：ISC License © Lucide Contributors（全文见 `design/icons/lucide/NOTICE.md`）
- 用途：`ic-organ-bone`(bone) / `ic-medicine-box`(pill-bottle) / `ic-organ-hand`(hand) /
  `ic-organ-donation`(heart-handshake) / `ic-refill`(package-plus)

## 5. Material Symbols — Apache 2.0
- 目录：`design/icons/materialsymbols/`
- 来源：github.com/google/material-design-icons（symbols/web/…，materialsymbolsoutlined 样式）
- 许可：Apache License 2.0 © Google（全文见 `design/icons/materialsymbols/NOTICE.md`）
- 用途：`ic-member-father`(man) / `ic-member-mother`(woman)

## 6. Font Awesome Free — CC BY 4.0
- 目录：`design/icons/fontawesome/`
- 来源：github.com/FortAwesome/Font-Awesome（6.x，svgs/solid）
- 许可：CC BY 4.0 © Fonticons, Inc.（全文见 `design/icons/fontawesome/NOTICE.md`）
- 用途：`ic-member-son`(child) / `ic-member-daughter`(child-dress)

## MIT 许可全文（适用于 1 与 3）

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE
```

## 自有部分

- 瓷砖底/渐变/高光/内阴影封装层：青囊书项目原创。
- `design/icons/provenance.json` 中 `source: own / own-color` 的字形（含全部插画与 App 图标）为项目原创；
  其中 `ic-organ-foot`（V1.7 版）几何参考自 Lucide（ISC）。
- 上架时请将本文件内容并入 App 的「开源许可与致谢」页（SP-48 已预留）。
