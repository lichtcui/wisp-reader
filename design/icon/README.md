# App 图标 / App Icon

Source Reader 的图标源文件、导出产物与替换步骤。

## 设计

- 主题：**一本打开的书** + 书页中央的「源」字（品牌字标）。
- 风格：红色轻渐变底 + 白色书页，现代极简，适合深/浅色桌面。
- 构图：书页顶部中间下凹、底部中央收拢，中轴下方留一条「书脊缝」；前景内容集中在画布中央约 69% × 55% 的安全区内。
- 视觉规范：前景内容不越出 1024 画布中央的 690px 安全框，四周留白，保证被系统圆角/胶囊遮罩裁切时不损失内容。
- 色值：底 `#EC6E6E → #DA3838 → #B3272B`（呼应 `brand` `#DA3838` / `brand_grad_a` `#E35A5A` / `brand_press` `#C22F2F`）；书页 `#FFFFFF → #FCF4F2`；「源」字 `#E14A44 → #BE2A2E`。

「源」字轮廓由 `gen_glyph.py` 从系统字体 **Hiragino Sans GB W6** 提取为矢量路径并内联进 `foreground.svg`，因此渲染不依赖字体，跨机器一致。

## 目录

```
design/icon/
  src/
    background.svg       底图源文件（不透明红渐变，1024x1024）
    foreground.svg       前景源文件（透明底白书 + 红「源」，1024x1024，自包含路径）
    gen_glyph.py         从 TTF/TTC 提取字形轮廓 → SVG path（仅重现/换字用）
    iconlib.py           纯标准库 PNG 解码/编码、合成、缩放、圆角遮罩
    export.py            渲染 + 导出 + 替换（入口）
    export.sh            export.py 的薄封装
  build/                 rsvg 中间产物（已被 .gitignore 的 **/build 忽略）
  dist/                  全部导出产物
```

## 重新生成

依赖：`rsvg-convert`（librsvg ≥ 2.50，用于 `feDropShadow`）+ `python3`（仅标准库）。

```bash
# 只导出到 design/icon/dist/
design/icon/src/export.sh

# 导出并替换到 AppScope / entry 资源
design/icon/src/export.sh --apply

# 自定义 rsvg-convert 路径
design/icon/src/export.sh --apply --rsvg /usr/local/bin/rsvg-convert
```

若要替换「源」字或换字体：

```bash
python3 -m venv /tmp/fontenv && /tmp/fontenv/bin/pip install fonttools
/tmp/fontenv/bin/python design/icon/src/gen_glyph.py \
  "/System/Library/Fonts/Hiragino Sans GB.ttc" 2 "源" /tmp/glyph.path
# 把 /tmp/glyph.path 的内容替换 foreground.svg 中 <path ... d="..."> 的值
```

## 产出（dist/）

| 文件 | 说明 |
|---|---|
| `icon-1024.png` | **主图**，1024×1024 不透明合成图 |
| `icon-1024-round.png` | 1024×1024 圆角（squircle，圆角半径 22.5%）透明底版 |
| `icon-{512,256,192,144,96,72,48}.png` | 各尺寸实心版 |
| `icon-{512,256,192,144,96,72,48}-round.png` | 各尺寸圆角透明底版 |
| `background-1024.png` / `foreground-1024.png` | 分层图标原始两层 |
| `startIcon-512.png` | 启动页图标（512 圆角透明底） |

> 鸿蒙分层图标只需要 **1024 的 `background` + `foreground` 两层**，系统会在各场景自动缩放；`dist/` 里的尺寸阶梯供文档、商店、第三方平台或非鸿蒙侧使用。

## 替换现有图标的步骤

1. 生成并替换资源（本仓库已执行）：
   ```bash
   design/icon/src/export.sh --apply
   ```
   该命令覆盖：
   - `AppScope/resources/base/media/background.png`（1024×1024，RGB 不透明）
   - `AppScope/resources/base/media/foreground.png`（1024×1024，RGBA 透明底）
   - `entry/src/main/resources/base/media/startIcon.png`（512×512，RGBA 圆角）

   `layered_image.json`、`app.json5`、`module.json5` 的引用**无需改动**（仍为
   `$media:layered_image` / `$media:startIcon`）。

2. 构建 HAP：
   ```bash
   export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
   export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
   /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
     --mode module -p product=default -p buildMode=debug --no-daemon
   ```

3. 安装并重启，在桌面/启动页确认：
   ```bash
   HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
   $HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
   $HDC shell aa force-stop com.lichtcui.sourcereader
   $HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
   ```

> 桌面图标由系统缓存，替换后若仍是旧图，可卸载重装或换桌面再切回。

## 规范要点

- 分层图标图层尺寸固定 **1024×1024**；背景层须铺满且不透明，前景层须透明底。
- 前景内容建议落在画布中央约 **67%** 的安全区内（Huawei 模板前景实测约 690×690）。
- `startIcon` 是启动页图标，非分层，使用圆角透明底避免在白色启动背景上出现红方块。