---
name: harmony-device-run
description: 改完 source-reader（bundle com.lichtcui.sourcereader）代码后在真机验证的完整闭环流程（判定改动范围 → 编译 → 安装 → force-stop → 启动 → 抓日志），含改动范围判定、hdc/uitest 无 GUI 验证、构建与日志的输出卫生。用于本仓库任何代码改动后的验证，或用户反馈"改了没生效 / 设备上跑的是旧版"时。
---

# 真机验证闭环（source-reader）

> 下面两个代码块来自项目根 `.harmony-skill.env`，由 `setup-codex.sh` 渲染；
> 改命令后跑一次 `setup-codex.sh --force .`。

## 1. 判定改动范围

| 改了什么 | 要额外构建 native 吗 | 后续 |
|---|---|---|
| 只有 `entry/src/main/ets/**`（ArkTS / ArkUI） | 否 | 直接编译 + 安装 + 启动 |
| `entry/src/main/resources/**`、`module.json5` | 否 | 同上 |
| 仓库自带 native / Rust（视本仓库而定） | 是 | 先跑本仓库单测，再重新生成产物 |

**没有把握时的第一动作：不要先改代码**——先确认「设备上跑的是不是这次构建」，再决定重装还是排查。

## 2. 执行

### 本仓库构建

```bash
make hap > /tmp/build.log 2>&1   # 改了 Rust / NAPI 先 make test && make rust
```

### 本仓库安装 / 启动 / 日志

```bash
make install          # 安装最新 HAP
make restart          # aa force-stop + 启动（aboutToAppear 才会重跑）
make log              # 按 bundle 名筛 hilog；可加 Q=关键词
```

### 验证闭环

1. **编译**：上一步命令成功，产物时间戳是新的（不是旧 HAP）。
2. **安装**：覆盖安装成功（失败先查签名 / 设备 UDID，见 `harmonyos-release-signing`）。
3. **force-stop**：不 `aa force-stop`，`aboutToAppear` 不会重跑，界面看起来「没变化」。
4. **启动**：`aa start` 后确认进程存在、窗口出现。
5. **取证**：按 bundle 名筛日志 / dump 布局；只把关键行带回对话。

## 3. 输出卫生（避免刷爆上下文）

- 构建：把构建命令输出重定向到 `/tmp/build.log`，然后 `rg -n "ERROR|error\[|error:|FAILED" /tmp/build.log`。
  **不要**把完整构建日志贴回来。
- 日志：先 `hdc shell hilog -r` 清，再 `hdc shell hilog -x | grep com.lichtcui.sourcereader | tail -n 200`。
  **不要用 `-T <tag>`**：tag 通常按文件拆，猜错只会拿到空结果。
  不要裸 `hilog -x | grep`（会刷屏）。
- 中间产物留在 `/tmp`，只把**结论**带回对话。

## 4. 无 DevEco GUI 时的 UI 验证

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC shell uitest dumpLayout -p /data/local/tmp/l.json -a
$HDC file recv /data/local/tmp/l.json /tmp/l.json      # 再用 rg 提取需要的 node，别整份贴回
$HDC shell "uitest uiInput click <x> <y>"              # bounds 是物理像素，按设备分辨率换算
$HDC shell "uitest uiInput inputText <x> <y> <text>"
```

**读瞬时 UI（toast 等）**：`dumpLayout` **不导出系统 toast 窗口**，逐帧 dump 抓不到，别据此判定「没弹」。
用截图 + 主机 OCR（本机已装 `chi_sim`）：

```bash
$HDC shell "uitest screenCap -p /data/local/tmp/w1.png"        # 连拍 6–10 张，每张 ~0.5s
$HDC file recv /data/local/tmp/w1.png /tmp/w1.png
cd /tmp && tesseract w1.png w1 -l chi_sim --psm 6 && rg -N "检查中|新章|未检查" /tmp/w1.txt
```

- **`tesseract` 必须 `cd` 到图片目录用相对名**：leptonica 按 cwd 找文件，给绝对路径同样报 `fopenReadStream: failed to open locally`（仓库 cwd / `$HOME` cwd 都失败）。`screenCap` 的 RGBA PNG 能直读，不必转灰度。
- **连拍要在「点击」之前就起**：toast 只活 ~2s，先点后拍常常只能拍到它消失后的画面。稳妥做法是后台起连拍循环（每张 ~0.45s，拍 20+ 张）再发 click，收工后统一 OCR。

**核对 DB 写入（真机，若本仓库有本地库）**：RDB 跑 WAL，**只 recv 主库会漏掉未 checkpoint 的写** ⇒ 主库 + `-wal` + `-shm` 三件套一起拉，再 `sqlite3` 查：

```bash
DB=/data/app/el2/100/database/com.lichtcui.sourcereader/entry/rdb
mkdir -p /tmp/db && cd /tmp/db
for f in <库名>.db <库名>.db-wal <库名>.db-shm; do $HDC file recv $DB/$f /tmp/db/$f; done
sqlite3 /tmp/db/<库名>.db "<查询>"
```

**对时**（确认 toast 真的弹过、以及何时弹）：`hdc shell hilog -x | rg "Capture event: toastShow"`。

其他要点：
- `uitest uiInput` 支持 `click / doubleClick / longClick / swipe / drag / fling / keyEvent(Back|Home|Power) / inputText`；**长按是 `longClick`**（不是 `longPress`），`inputText` 不会触发 `onSubmit`（补 `keyEvent 2054`）。
- **每次 `dumpLayout` 都要确认命令成功**：失败时 `/data/local/tmp/*.json` 会留着上一次的内容，看起来像「点了没反应 / 菜单没弹出」。
- **`dumpLayout` 卡死会连累后面所有 dump**（症状：突然每次都报 `Wait for subscribe uitest.broadcast.command.reply timeout`）——设备侧残留进程占着广播，`hdc shell "ps -ef \| grep 'uitest dumpLayout'"` 取 pid `kill -9` 即恢复。写循环脚本时加看门狗（>8s 未返回就 kill 进程 + 清残留），别让一次卡死污染整轮验证。
- 想验「点击机制本身通不通」，先拿一个已知会变的控件（tab / 按钮）点一下做**对照**，再解释 null 结果；别把「太快没抓到」当成「功能没触发」。
- 失败注入优先用 App 内可控开关（如设置页的开关），别指望系统控制中心的飞行模式断网。

## 5. 汇报格式

`改动文件 → 真机现象（截图 / 关键日志 ≤3 行）→ 结论 → 未验证项`。
不复述命令、不贴完整日志、不贴整份 dumpLayout。

## 相关

- 通用 harmony skill（API/离线文档查询 `harmony-next`、构建诊断 `harmonyos-build-doctor`、
  项目基线审计 `harmonyos-project-audit`、发布签名与门禁 `harmonyos-release-*`）：
  真源在 `~/Documents/skills.harmony/`，项目内以 `.agents/skills/` 软链随仓库提供。
  中央库更新后，在项目根跑一次 `~/Documents/skills.harmony/setup-codex.sh .` 刷新；
  项目专属的本文件不会被覆盖（除非 `--force`）。
- 本项目的构建 / 安装 / 日志约定以 `AGENTS.md`、`README.md` 与 `.harmony-skill.env` 为准。
