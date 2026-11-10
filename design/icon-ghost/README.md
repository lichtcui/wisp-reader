# Ghost Icon / 幽灵书本图标（旧版，已退役）

> ⚠️ 本目录是**上一版**手绘幽灵图标，已被 [`design/icon-v2`](../icon-v2/README.md) 的幽灵读书图标（方案 B）取代。
> 工程当前引用的是 v2：`AppScope` / `entry` 的 `foreground.png`、`background.png`、`startIcon.png`
> 均由 `design/icon-v2/src/export.py --apply` 生成。
> **不要再跑本目录的导出命令或 `export_starticon.py --apply`**，否则会把工程资源覆盖回旧图标。
> 以下内容仅作历史与工具参考（`design/icon/src/iconlib.py` 仍被 v2 的导出脚本复用）。

## 目录

```
design/icon-ghost/
  source/
    logo-source.svg        # 200×200 定稿设计源文件
    foreground.svg         # 删除背景矩形后的前景层
    background.svg         # 纯色 #1C2A4A 背景层
  src/
    export_starticon.py    # 由分层图生成启动页 startIcon（复用 design/icon/src/iconlib.py）
  dist/
    foreground.png         # 1024×1024 RGBA 前景层
    background.png         # 1024×1024 RGB 背景层
    preview-32.png         # 32×32 预览图
    startIcon-512.png      # 512×512 RGBA 圆角透明底，启动页图标
```

## 重新生成

```bash
cd design/icon-ghost
rsvg-convert -w 1024 -h 1024 -o dist/foreground.png source/foreground.svg
rsvg-convert -w 1024 -h 1024 -o dist/background.png source/background.svg
rsvg-convert -w 32 -h 32 -o dist/preview-32.png source/logo-source.svg
```

鸿蒙工程实际使用的资源位于：

- `AppScope/resources/base/media/{foreground.png,background.png,layered_image.json}`
- `entry/src/main/resources/base/media/{foreground.png,background.png,layered_image.json}`

同步时把 `dist/foreground.png`、`dist/background.png` 复制到上述两个目录即可。

## 启动页图标（startIcon）

`entry/src/main/module.json5` 的 `startWindowIcon` 是 **`$media:startIcon`**，一张扁平的 512×512 PNG，
**不会**跟着分层图标自动变。只换 `foreground/background` 的话，开屏动画仍是上一版图标。

所以每次改分层图后，必须重新生成并落地 startIcon：

```bash
# 只更新到 dist/startIcon-512.png
python3 design/icon-ghost/src/export_starticon.py

# 同时覆盖 entry/src/main/resources/base/media/startIcon.png（工程实际引用）
python3 design/icon-ghost/src/export_starticon.py --apply
```

处理链：`foreground` 合成到 `background` 上 → 缩到 512 → 22.5% 圆角遮罩（四角透明）→ RGBA PNG。
纯标准库，无第三方依赖（`iconlib.py` 来自 `design/icon/src/`）。

圆角与桌面图标观感一致；开屏没铺满时四角透明也能透出启动背景，不会出现硬边方块。

启动背景 `start_window_background`（`entry/src/main/resources/{base,dark}/element/color.json`）取
**分层背景层同色 `#1C2A4A`**，所以开屏是「深蓝整屏 + 居中奶白书页」，圆角方块的边与背景同色、看不出来。
换背景色时这两处必须一起改，否则开屏会露出一个色块。