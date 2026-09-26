# HANDOFF-S7 — 书架模块（A–B）

日期：2026-09-26
范围：**仅书架模块**（`pages/Shelf.ets` + 经授权新增的数据层批量接口 `model/ShelfRepository.ets`）。
基线：`cb6f608`（S6 收尾）。HEAD：`cb28032`（本轮提交，见 §2）。

> 构建：`assembleHap` **BUILD SUCCESSFUL**（仅既有 ArkTS 警告）。
> **真机验证已完成**：设备 `33Z0224424136564`，A/B 全项通过（见 §5），无崩溃。

约束履行：
- 未改共享缓存层（`components/BookCover.ets` / `model/ChapterCache.ets` / Rust `.so` 保持 S3 原样）。
- B 评估后判定其书架侧根因需触及数据层接口，**已停下询问**；获授权后仅在 `ShelfRepository` 新增只读批量查询，未自绘、未扩引擎。
- 未改任何搜索 / 听书 / 阅读文件。

---

## 1. 变更清单（按项）

### A. 移除顶部「全部书籍 · N」描述文案

- `pages/Shelf.ets:build()` 删除列表/宫格之上的统计 `Row`（`Text('全部书籍 · ${this.entries.length}')` + `Blank`）及其
  `padding({left:16,right:16,top:12,bottom:8})`；内容列直接以空态 / 列表 / 宫格开始。
- 无导入受影响（`Blank`/`Text` 为内置组件）。

**证据**：`git diff -- entry/src/main/ets/pages/Shelf.ets`（删除 8 行）。

### B. 封面「二次刷新」——按 ROOT-CAUSE §1 同源结论修复（书架放大器）

**同源判定（沿用 ROOT-CAUSE.md §1）**：书架与阅读目录封面走同一 `BookCover` → `downloadCover` → Rust
`download_cover`。S3 已单点修复读穿缓存（`BookCover` 内存 PixelMap/路径缓存 + Rust 磁盘短路面）；书架侧**剩余**根因是
`reload()` 的**逐书串行 `await getProgress`**，它把 `entries` 的赋值推迟到最后一次 DB 往返之后，拖长首帧、
放大整屏（含封面）的延迟与重建观感。

**真机核验（本次，cache 已存在）**：
- 切 Tab 回书架、以及「进阅读页改进度后返回书架」两种情形，`uitest screenCap` 前后帧**逐字节相同**，
  首格封面区域均值恒为真实封面色（`7a557f`），**无**兜底红渐变闪烁；
- `cache/cover_*.img` 文件集合与 mtime **零变化**（无重复下载）。
- 结论：S3 缓存层在书架侧已生效；可见问题即 #1 所述「串行 fanout 阻塞首帧」放大器。

**修复（经授权，仅在数据层新增只读接口）**：
- `model/ShelfRepository.ets`：新增 `getAllProgress(): Promise<Map<string, ReadProgress>>`——一次
  `SELECT * FROM progress`，按 `book_id` 建映射；`store === undefined` 时返回空 `Map`（与既有函数同款守卫）。
  **未改动** `getProgress`（`Reader.ets` 仍按需使用）与任何写路径。
- `pages/Shelf.ets`：`reload()` 改为 `const progressMap = await getAllProgress()` 后一次循环装配 `entries`；
  N 次串行查询降为 1 次批量查询，`entries` 赋值不再被逐书 DB 往返串行阻塞。

**未做（有意）**：`entryKey` 仍含进度签名（`bookId#chapterIndex_percent`）——它保证阅读返回后进度文案刷新；
本轮实测该重挂载在温缓存下不产生可见刷新（见上），故不动，避免引入 V2 响应式列表重构的额外风险。

---

## 2. 变更文件 / 统计

```
entry/src/main/ets/model/ShelfRepository.ets | 24 ++++++++++++++++++++++++
entry/src/main/ets/pages/Shelf.ets           | 14 +++-----------
2 files changed, 27 insertions(+), 11 deletions(-)
```

| 项 | 文件 | 说明 |
|---|---|---|
| A | `pages/Shelf.ets` | 删除顶部「全部书籍 · N」统计行 |
| B | `model/ShelfRepository.ets` | 新增 `getAllProgress()` 批量进度查询（经授权） |
| B | `pages/Shelf.ets` | `reload()` 改用批量查询，消除逐书串行 fanout |

> 本轮提交：`cb28032`（含 2 个代码文件 + 本文件）。`build-profile.json5` 等未触碰。`AUDIT.md`/`ROOT-CAUSE.md`/`TASKS.md`/
> `UI-SPEC.md`/`HANDOFF-S3..6.md` 仍 untracked（沿旧例）；`AGENTS.md`/`docs/progress.md` 的改动来自并行 TTS 工作流，未纳入。

---

## 3. 关键文件

- `entry/src/main/ets/pages/Shelf.ets`（A/B）
- `entry/src/main/ets/model/ShelfRepository.ets`（B，新增只读 `getAllProgress`）

---

## 4. 构建命令 / 结果

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# → BUILD SUCCESSFUL in 12 s 937 ms（33 tasks；仅既有 ArkTS 警告：剪贴板权限、函数可能抛异常等）
```

Rust 未改动 → 无需 `ohrs build` / `cargo test`。

---

## 5. 真机验证结果

设备 `33Z0224424136564`；HAP 安装（`install ... successfully`）→ `aa force-stop` → `aa start`（PID `51226`）。

| 项 | 结果 | 依据 |
|---|---|---|
| A | ✅ | 冷启动后及阅读返回后 `uitest dumpLayout` 均 `全部书籍` 命中 **0**；内容列表首个节点直接为书目（`夜的命名术`） |
| B（功能回归） | ✅ | `reload()` 批量查询后进度文案与修复前一致：`11章/1158章`、`5章/1441章`、`已读到最新章`、`27章/28章` |
| B（交互闭环） | ✅ | 点书进阅读页（`996、最后一程（八）（修）`）→ 系统返回 → 书架正常渲染；进程存活、`hilog` 无 `JSCRASH`/`CPPCRASH`/`undefined is not callable` |
| B 现状核验 | ✅（修复前基线） | 温缓存下切 Tab / 阅读返回均无兜底闪烁、封面缓存 mtime 无变化（`screenCap` 逐字节比对） |

> B 的「首帧更早出现」为时序收益（N 次串行 DB 往返 → 1 次），非可断言的画面差异；本轮以功能回归 + 无崩溃闭环为准。

---

## 6. 遗留问题 / 已知风险

1. **B 的范围仅到「消除串行 fanout」**：ROOT-CAUSE §1 另提「书架 DB 只存 `cover_url` 未存本地路径」与
   「TOC 面板常驻 / `BookCover` 变 `@Reusable`」。这些落在共享缓存层，本轮约束内**未做**，如需另立授权。
2. **`getAllProgress` 无分页**：一次拉全部 `progress` 行；书架规模化（数千本）时仍可接受，若将来过大再加 LIMIT/游标。
3. **设备曾中途离线**：验证途中 `hdc list targets` 一度变 `[Empty]`；重连后已完成安装与 §5 全部验证项。
4. **`reload()` 仍可能被多重触发**（`aboutToAppear` / `refreshToken` / `Tabs.onChange` / `onNavBarStateChange`）并重复赋值
   `entries`；因 `ForEach` key 稳定、封面缓存读穿，未观察到可见副作用，本轮不加去重守卫（保持最小改动）。
5. **`getProgress` 保留**：`Reader.ets:162` 仍在用，未删除。

---

## 7. B 决策记录（停下来问 / 授权）

- 评估结论：B 的书架侧根因是 `reload()` 串行 `getProgress`，自然修复需**数据层批量接口**，可能越界，故按约停下询问。
- 用户裁定：**授权改 `ShelfRepository` 加批量查询**（未授权改共享 `BookCover` 缓存层）。
- 落地：`getAllProgress()`（只读）+ `Shelf.ets` 调用；共享缓存层与业务其它页面零改动。