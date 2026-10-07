# 缓存上限策略（T-DATA-4）

> 对应 [`../bugfix/TASKS.md`](../bugfix/TASKS.md) §T-DATA-4、[`../plan.md`](../plan.md) §7。
> 实现：`entry/src/main/ets/model/CacheTrim.ets`（+ `ChapterCache` 的 mtime 刷新、`EntryAbility` 的启动整理）。
> 状态：**已实现并真机验证通过**（2026-10-07，设备 `33Z0224424136564`，debug 包 + 临时压小常量，逐条与沙箱 `ls -l` 对账后已还原常量；记录见 §8）。

## 1. 为什么要定口径（plan §7 原文内部矛盾）

`plan.md` §7 同时要求「章节正文：上限约 200MB」与「已读永久保留、未读超 N 天清理」。但章节缓存是
**读一章写一章 + 预取邻居**，所以「读过的章」占绝大多数；若已读绝对保留，200MB 上限几乎永不触发
（真机实测约 **9.6KB/章**，一本 1441 章的书全读完约 **14MB**），磁盘会无界增长。

处置：**已读降为「软保护」** —— 未读先删；仍超配额才按「最久未访问」删已读；未读另吃 TTL。

## 2. 预算与范围

| 位置 | 预算常量 | 处置 |
|---|---|---|
| `filesDir/chapters/<bookId>_<index>.json` | `CACHE_CHAPTER_QUOTA` 200MB | 配额 + TTL（主战场） |
| `filesDir/tocs/<bookId>.json` | `CACHE_TOC_QUOTA` 16MB | 配额兜底 + 「章被删空的书」连带删 |
| `cacheDir/cover_*.img` | `CACHE_COVER_QUOTA` 64MB | 仅按 mtime 最旧驱逐（见 §5） |
| `cacheDir/tts` | — | 今天 0 B（系统 TTS 链路纯内存）；有写入者时挂同一套策略 |
| `filesDir/local/`、DB、书源 prefs、备份文件 | — | **永不动**（用户数据不是缓存） |

其余常量：`CACHE_TARGET_RATIO` 0.8（滞回目标）、`CACHE_MAX_AGE_DAYS` 30（未读 TTL）、
`CACHE_AVG_CHAPTER_BYTES` 16KB（折算闸门）、`CACHE_FRESH_WINDOW_MS` 5min、`CACHE_TRIM_MIN_INTERVAL_MS` 30min。

## 3. 判定：已读 / 保护

- **已读**：`ShelfRepository.getAllProgress()` → `bookId → chapterIndex`，`index <= chapterIndex` 即已读；
  听书进度写同一张表，天然覆盖。无进度行 = 全未读。
- **绝不删**（`guarded`）：① `mtime` 在 `CACHE_FRESH_WINDOW_MS` 内（正在读/刚预取的章）；
  ② 属于会话保护集 `protectBook(bookId)` 的书 —— Reader 的 `load()` 与 `TtsController.start()` 各登记一次，
  30 分钟未更新自动失效，最多 8 本。
- 已知保守行为：用目录跳到第 500 章 → `progress.chapterIndex=500` → 1–499 章被算「已读」而受保护（多留不多删）。

## 4. 触发与执行（不阻塞 UI）

| 入口 | 时机 |
|---|---|
| `scheduleStartupTrim` | `EntryAbility.onCreate` → `initShelf` 成功后延迟 3s（等首帧），`force=true` 忽略节流 |
| `maybeTrimCaches` | `ChapterCache.putCachedChapter` 每 **20** 次写检查一次：先看会话节流（30min），再做廉价闸门 —— 只 `listFileSync` 数一次文件名，`count > 配额/16KB` 才真整理 |
| `trimCaches(ctx, force)` | 手动/上层调用（当前无 UI 入口） |

执行在主线程**分片**：扫描每 200 个文件、驱逐每 200 次删除 `await` 让出一次事件循环。
**不用 taskpool**：`UIAbilityContext` 不可跨线程传递，本仓库也无 taskpool 先例，收益不值复杂度。

时间信号只用文件 `mtime`（秒），**不新增持久化索引** —— 省掉 `obfuscation-rules.txt` 的 keep 面与整文件重写放大。
`ChapterCache` 命中时会节流（10min/条）刷新 `mtime` 以获得真 LRU（`fileIo.utimes`，注意单位，见 PITFALLS）。

## 5. 驱逐算法

1. 扫 `chapters/`，分成「未读」「已读」（`guarded` 的不入候选）。
2. 若总字节 > 配额：未读按 `mtime` 最旧先删 → 降到 **80%** 配额；
3. 仍超 → 已读按 `mtime` 最旧先删 → 降到 80%。
4. TTL（与配额无关）：未读且 `now - mtime > 30d` 即删；**已读不吃 TTL**（只吃 LRU）。
5. TOC：先删「本轮被删空且不在保护集」的书的 toc；再按 16MB 预算兜底驱逐。
6. 封面：文件名是 Rust 侧 `DefaultHasher(coverUrl)`（`runtime.rs::download_cover`），**ArkTS 侧不可复现**，
   因此无法识别在架书封面 → 只按 mtime 最旧驱逐到 80% 预算（代价：可能重下在架封面，无数据损失；
   若将来要精确，需 Rust 侧在磁盘命中时刷 `mtime` 或导出「URL→文件名」映射）。

## 6. 刻意不做

- 不新增持久化 JSON 索引（keep 列表与 `make check` 都不用动）。
- 不动 `filesDir/local/` 与 DB；不做 `progress` 孤儿行 GC（有合法来源，见 T-DATA-7）。
- 不加设置页配额档位、不加「立即整理」按钮（2026-10-07 决定：纯自动）。

## 7. 复现方法（压测）

真机沙箱 shell **无写权限**（`touch` 报 Permission denied），伪造不了缓存文件 → 用**真实链路 + 临时改常量**：

1. `make run`（默认常量）→ 看 `hdc shell hilog -x -T SourceReaderCache`：应 `freed=0`。
2. 临时把 `common/Const.ets` 里目标常量压小（章节 2–4KB / 封面 200KB）、`CACHE_FRESH_WINDOW_MS = 0` → `make run`。
3. 对账：`hdc shell "ls -l /data/app/el2/100/base/com.lichtcui.sourcereader/haps/entry/files/chapters"`
   与日志里的 `freedFiles` / `freedBytes`（同路径下 `tocs/`、`haps/entry/cache/cover_*.img` 同理）。
4. 热路径 / 保护集：临时把 `CacheTrim.ets` 的 `PUTS_PER_CHECK` 改 1、`CACHE_TRIM_MIN_INTERVAL_MS` 改 1ms，
   再用 `hdc shell uitest uiInput click <书卡坐标>` 打开一本书（坐标从 `uitest dumpLayout` 取）。
5. **验完必须全部还原**（含 `PUTS_PER_CHECK`）再`make run` 确认 `freed=0`；`hdc shell date` 可用于确认设备时间。

## 8. 真机验证记录（2026-10-07）

设备 `33Z0224424136564`（HarmonyOS NEXT / API 24），debug 包，日志 tag `SourceReaderCache`；
除封面那一项外均用真实链路（真机沙箱 shell **无写权限**，造不了假数据），每次临时压小一个常量后 `make run`，读日志 + `hdc shell ls -l` 对账。

| # | 临时改的常量 | 日志 | 沙箱对账 | 结论 |
|---|---|---|---|---|
| ① | 无（默认） | `scanned=2 freed=0 keptRead=1` | 2 章 + toc 全在 | 默认配额不误删 |
| ② | `CHAPTER_QUOTA=4KB` | `freed=1 files 3765 B` | 只剩 `_0.json`（已读） | **未读先删** |
| ③ | `CHAPTER_QUOTA=2KB` | `freed=2 files 9667 B` | `chapters/`+`tocs/` 皆空；9667 = 2856(已读章)+6811(toc) | 软保护降级 + toc 连带删 |
| ④ | `CHAPTER_QUOTA=2KB`，文件 30s 前刚写 | `freed=0` | 文件完好 | 新鲜窗口保护 |
| ⑤ | `CHAPTER_QUOTA=2KB`+窗口 0+闸门 1，打开在读的书 | 热路径 `scanned=1 freed=0` → `scanned=2 freed=0` | 在读的章与 toc 全在 | `protectBook` 生效（同参数的另一次会话不打开书则 `freed=3 files 14657 B` 全清） |
| ⑥ | 配额恢复 200MB + `MAX_AGE_DAYS=0` | `freed=1 files 3644 B` | 删的是未读 `_1.json`，已读 `_0.json` 留下 | TTL 只吃未读 |
| ⑦ | `COVER_QUOTA=200KB` | `freed=32 files 972410 B` | 剩 6 封 161511 B ≤ 80% 水位 163840 | 封面停在水位内（非清零）；书架随后自动重下封面 6→8 |
| 终 | 全部还原为默认 | `freed=0` | 章节/toc 完好 | 生产常量下行为正常 |

剩余未验（本机无法低成本构造，已由代码路径覆盖）：跨天 TTL（用 `MAX_AGE_DAYS=0` 等价验证过分支）、`cacheDir/tts` 分支（目前该目录无写入者）、单文件超配额的特例。
