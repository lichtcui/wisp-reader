# Ghost Icon / 幽灵书本图标

当前定稿的鸿蒙分层图标源文件与本地构建产物。

## 目录

```
design/icon-ghost/
  source/
    logo-source.svg      # 200×200 定稿设计源文件
    foreground.svg       # 删除背景矩形后的前景层
    background.svg       # 纯色 #1C2A4A 背景层
  dist/
    foreground.png       # 1024×1024 RGBA 前景层
    background.png       # 1024×1024 RGB 背景层
    preview-32.png       # 32×32 预览图
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
