# App 图标 v2 / 幽灵读书（当前定稿）

> 本目录是**当前工程正在使用**的图标源。选型过程稿在 `design/icon-v2-preview/`、
> 上一版（手绘幽灵）在 [`design/icon-ghost/`](../icon-ghost/README.md)、最早的红底「源」字版已退役于 [`design/icon/`](../icon/README.md)。

## 设计

- 图形：用户提供的两段 SVGRepo 24×24 path —— 幽灵（`fill-rule="evenodd"`，两只圆眼睛镂空）+ 摊开的书；
  选型方案 **B**（书放大居中，成为第二主视觉）。
- 配色**完全沿用**上一版 ghost 图标，未引入新色：

  | 用途 | 色值 |
  |---|---|
  | 背景层 / 眼洞 / 书脊 | `#1C2A4A` |
  | 幽灵 | `#F2F0E8` |
  | 书本 | `#C8543F` |

- 构图（200×200 设计画布）：幽灵 `translate(100 86) scale(5.8)`、书本 `translate(100 132) scale(3.8)`，
  书本压在幽灵身前；前景整体落在中央安全区内。
- **书脊必须补**：新书本 SVG 两页之间自带 1.5 单位缝隙，若不填色，叠在奶白幽灵上会透出一道白线把书切成两块。
  `foreground.svg` 里的 `rect x=11.25 w=1.5 y=5.2 h=15.2`（24 图标局部坐标系）填 `#1C2A4A`，
  与旧图标 `logo-source.svg` 的书脊做法一致。改书本缩放时这个 rect 会跟着 `<g transform>` 一起缩，不用改数值。

## 目录

```
design/icon-v2/
  source/
    background.svg      1024×1024 纯色不透明背景层
    foreground.svg      1024×1024 透明底前景层（含 defs 路径 + 书脊）
  src/
    export.py           渲染 + 合成 + --apply 落地（复用 design/icon/src/iconlib.py）
  dist/
    background.png      1024 分层背景
    foreground.png      1024 分层前景
    icon-1024.png       方形不透明合成图（人工核对用）
    startIcon-512.png   512 圆角透明底，启动页图标
```

## 重新生成

```bash
# 只导出到 dist/
python3 design/icon-v2/src/export.py

# 导出并覆盖工程资源
python3 design/icon-v2/src/export.py --apply
```

依赖 `rsvg-convert`（librsvg ≥ 2.50）+ `python3` 标准库。

## 落地清单（--apply 已覆盖，改图形时别漏）

1. `AppScope/resources/base/media/{background,foreground}.png`
2. `entry/src/main/resources/base/media/{background,foreground}.png`
3. `entry/src/main/resources/base/media/startIcon.png` —— `module.json5` 的 `startWindowIcon` 是**独立扁平 PNG**，
   不会跟着分层图标自动变；只换前两步会让开屏仍是旧图标。
4. `start_window_background`（`entry/src/main/resources/{base,dark}/element/color.json`）须与背景层同色 `#1C2A4A`。
   旧工程是 `#FFFFFF` / `#121212`（浅色/深色），本次已同步为 `#1C2A4A`；**换背景色时必须同步**，否则开屏会露出色块。

`layered_image.json` / `app.json5` / `module.json5` 的引用不变，无需改。
改完跑 `make hap` 编译验证；真机桌面图标有缓存，必要时卸载重装。
