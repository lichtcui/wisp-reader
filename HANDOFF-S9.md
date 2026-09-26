# HANDOFF-S9 — 数据管理模块（清理缓存统计口径）

日期：2026-09-26
范围：**仅数据管理模块** —— 缓存占用统计与「清理缓存」入口。
基线：`731a842`（S8 收尾）。本轮未提交（见 §7）。

> 构建：`assembleHap` **BUILD SUCCESSFUL**（20 s；仅既有 ArkTS 警告：`audio` syscap、
> 「函数可能抛异常」）。无 Rust 改动 → 未重编 `.so`、未跑 `cargo test`。
> **真机验证已执行**：设备 `33Z0224424136564`，安装 → `force-stop` → 启动，
> 统计与磁盘逐字节对齐、清理后归零、开书后实时增长，`hilog` 无 `JSCRASH`/`CPPCRASH`（§5）。

约束履行：
- **未改任何缓存写入逻辑**：`ChapterCache` / `BookCover` / Rust `download_cover` / TTS 生命周期
  均未改动；本轮只新增**读取统计**（`CacheRepository`）与 UI 展示。
- 统计范围严格限定为：**图片缓存、章节内容缓存、TTS 音频缓存**。
- 未新增 NAPI 导出 / JSON 字段 → `cpp/types/liblegado_core/index.d.ts` 与
  `obfuscation-rules.txt` **无需更新**。

### 开工前判定（对应任务 A/B）

- `ROOT-CAUSE.md` §4-C 的根因是「功能完全未实现」；S3（`HANDOFF-S3.md`）只修了缓存层
  **正确性**（内存 url 校验、封面读穿、in-flight 合并），**未触碰统计口径**。
- 故本 Session 执行 **A**：实现统计读取并与真实写入目录对齐，而非仅验证 B。

---

## 1. 变更清单

### A. 缓存统计（新增 `model/CacheRepository.ets`）

- `CacheCategory { bytes, count }` / `CacheStats { image, chapter, tts, totalBytes, totalCount }`。
- `getCacheStats(ctx)`：只读遍历三类目录，`fileIo.listFileSync` + `fileIo.statSync(f).size` 求和；
  目录不存在 / 读取异常一律回退 `0`，绝不抛异常。
- `clearCache(ctx)`：仅删封面文件（`cover_*`）与 `chapters` / `tts` 目录，**不动** `cacheDir`
  内其它条目；缺失目录为 no-op。
- 证据：`CacheRepository.ets:82`（`getCacheStats`）、`:138`（`clearCache`）。

### B. 设置页右值（`pages/Settings.ets`）

- 新增 `@Local cacheText`，`aboutToAppear` 与 `@Monitor('refreshToken')` 调 `reloadCache()`；
  `reloadCache` = `formatBytes(getCacheStats(ctx).totalBytes)`。
- 「清理缓存」行由写死 `'0 B'` 改为 `this.cacheText`。
- 证据：`Settings.ets:12`、`:39-43`、`:95`（原写死见 `ROOT-CAUSE.md:131`）。
- 刷新时机：切回设置 Tab（`Index.onChange` → `settingsRefresh++`）与从子页返回
  （`onNavBarStateChange`）都会触发重算，**每次展示都重读磁盘**，非缓存值。

### C. 清理缓存页 + 路由（新增 `pages/CacheManage.ets`，`Index.ets`，`Const.ets`）

- 原「清理缓存」落入占位页（`ROOT-CAUSE.md:132`）。新增 `ROUTE_CACHE_MANAGE` 与页面：
  分组展示 **图片缓存 / 章节内容缓存 / TTS 音频缓存 / 合计** 的 `formatBytes` 与文件数；
  「清理全部缓存」按钮（`totalCount===0` 时禁用）执行 `clearCache` 后归零并提示。
- 证据：`CacheManage.ets:88-135`、`Index.ets:63,185-190`、`Const.ets:18`。
- **验证中发现并修复的两点 UI 反应性缺陷**（详见 §5.3）：
  1. V2 下 `@Builder` 传**值参数**不随 `@Local` 重渲染 → 改为子组件 `@ComponentV2 CacheStatRow`
     （`@Param` 单向、可观察），明细行才会随统计变化刷新。
  2. `rmdirSync` 后**同 tick 立即重读**目录可能拿到旧值 → `onClear` 改为直接 `zero()`
     （清理范围确定，归零即准），不再依赖紧邻的一次 `getCacheStats`。

---

## 2. 统计口径与路径对齐

| 类别 | 实际写入方（未改动） | 统计读取目录 / 匹配 |
|---|---|---|
| 图片缓存 | Rust `download_cover` → `format!("cover_{:x}.img")` 写 `dest_dir`；ArkTS 传 `ctx.cacheDir` | `ctx.cacheDir`，文件名前缀 `cover_` |
| 章节内容缓存 | `ChapterCache.putCachedChapter` → `filesDir/chapters/{bookId}_{index}.json` | `ctx.filesDir/chapters`，后缀 `.json` |
| TTS 音频缓存 | **当前无落盘**（AUDIT §2：TTS PCM 仅内存、随播即弃） | `ctx.cacheDir/tts`（预留），现恒 `0 B` |

- 图片：`rust/legado-engine/src/runtime.rs:721,723,739`、`components/BookCover.ets:47`。
- 章节：`model/ChapterCache.ets:24-30,84-89`。
- TTS：`AUDIT.md:53`、`model/TtsController.ets`（无任何 `fileIo` 写盘）。
- `formatBytes` 原为零调用的死工具（`ROOT-CAUSE.md:132`），本轮到「设置页 + 清理页」两处调用。

> `filesDir/local`（本地书）**不计入**：它是用户导入的正文内容（非可重建缓存），
> 且 `T-SHELF-1` 另有清理归属；本轮范围按任务限定为三类缓存。
> 封面 `cacheDir` 中非 `cover_` 前缀的文件不会被统计/删除，避免误伤。

---

## 3. 变更文件 / 统计

| 文件 | 类型 | 说明 |
|---|---|---|
| `entry/src/main/ets/model/CacheRepository.ets` | 新增 | 统计 + 清理（只读遍历，无写入） |
| `entry/src/main/ets/pages/CacheManage.ets` | 新增 | 清理缓存页（三类明细 + 合计 + 清理 + `CacheStatRow`） |
| `entry/src/main/ets/pages/Settings.ets` | 改 | 右值接真实占用；`refreshToken` 重算 |
| `entry/src/main/ets/pages/Index.ets` | 改 | `ROUTE_CACHE_MANAGE` 分发 |
| `entry/src/main/ets/common/Const.ets` | 改 | 新增路由常量 |

```
 entry/src/main/ets/common/Const.ets          |   1 +
 entry/src/main/ets/pages/Index.ets           |  10 +++++++
 entry/src/main/ets/pages/Settings.ets        |  14 +++++++-
 entry/src/main/ets/model/CacheRepository.ets | 141 +++++++++++++++++++++++++++++
 entry/src/main/ets/pages/CacheManage.ets     | 136 ++++++++++++++++++++++++++++
```

> 未动 `entry/libs/arm64-v8a/liblegado_core.so`。`AGENTS.md` / `docs/progress.md` 的改动来自
> 并行 TTS 工作流，与本轮无关，未纳入。

---

## 4. 构建命令 / 结果

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# → BUILD SUCCESSFUL in 20 s 313 ms（33 tasks：17 executed / 16 up-to-date）
#   新增警告仅 CacheManage.ets「函数可能抛异常」，与既有各页同类（showToast），非错误。
```

API 适配核对（`@ohos.file.fs.d.ts`，`compatibleSdkVersion 5.0.0(12)`）：`listFileSync`（since 9）、
`statSync`（since 9）、`rmdirSync`（since 9，递归删除目录及内容）、`unlinkSync`（since 9）、
`accessSync`（since 9）均可用，签名与用法一致。

---

## 5. 验证结果

设备 `33Z0224424136564`；`install -r` → `aa force-stop` → `aa start`，`uitest dumpLayout` 读取文本
（物理像素 1260 宽）。缓存目录：`.../haps/entry/cache`（封面）与 `.../haps/entry/files/chapters`。

### 5.1 统计与磁盘逐字节对齐 ✅

| 观测点 | UI 值 | 磁盘实测 |
|---|---|---|
| 设置页「清理缓存」右值 | `1.3 MB` | 封面 25 个 = 707400 B（690.8 KB）+ 章节 73 个 = 703673 B（687.2 KB）= 1411073 B |
| 清理页 图片缓存 | `25 个文件 / 690.8 KB` | 25 个 `cover_*.img`，707400 B |
| 清理页 章节内容缓存 | `73 个文件 / 687.2 KB` | 73 个 `*.json`，703673 B |
| 清理页 TTS 音频缓存 | `0 个文件 / 0 B` | `cache/tts` 不存在（无落盘写入） |
| 清理页 合计 | `98 个文件 / 1.3 MB` | 98 个 = 1411073 B |

### 5.2 写入缓存后数字实时变化 ✅

| 步骤 | 设置页右值 | 磁盘 |
|---|---|---|
| 清理全部缓存后 | `0 B` | 封面清空、`chapters` 目录被删 |
| 打开一本书（详情页拉正文）后 | `55.2 KB` | `chapters/*.json` 2 个 = 56521 B |
| 重启后书架渲染封面 | `81.6 KB` | `cover_*.img` 2 个 = 83579 B |

清理页点「清理全部缓存」→ 明细与合计立即变 `0 个文件 / 0 B`，返回设置页右值为 `0 B`；
`hilog` 全程无 `JSCRASH` / `CPPCRASH`。

> 说明：本机 `hdc` 以 `uid=2000(shell)` 运行，应用沙箱 `haps/entry/{cache,files}` 为 `drwxrwx---`
> 应用属主私有，`echo >` 与 `hdc file send` 均 `Permission denied`，无法由宿主机「手动」落文件；
> 故改由**应用真实写缓存**（开书）制造增量，效果等价（§5.2 数值即逐字节核对）。
> 另以**逐行等价移植**（`node fs`）验证统计/清理算法与路径约定：`0 → 650 → 700 → 0`、
> 且清后保留非 `cover_` 文件，`RESULT: PASS`（脚本未入库）。

### 5.3 验证中修复的 UI 反应性缺陷（已随最终包复验 ✅）

1. `@Builder statRow(title, bytes, count)` 传**值参数**在 V2 下不随 `@Local` 刷新，
   清理后明细停留旧值 → 抽成子组件 `CacheStatRow`（`@Param`，可观察）后正常刷新（§5.2 复验）。
2. `rmdirSync` 后立即 `getCacheStats` 可能读到旧值 → `onClear` 先 `zero()` 再提示，归零即时且确定。

---

## 6. 遗留问题 / 已知风险

1. **内存层不随清理失效**：`clearCache` 删盘，但 `ChapterCache` 内存 `Map` 与 `BookCover`
   模块级 `pixmapCache` 为会话级、不重落盘，故清理后**本次会话**仍可能命中内存内容，
   磁盘口径保持 0。符合「不动写入逻辑」约束；如需严格一致，另立任务加内存失效出口。
2. **TTS 音频缓存恒 0 B**：当前系统 TTS 无持久化音频（AUDIT §2）。已预留 `cacheDir/tts`
   作为 `TTS-PLAN` 端侧 TTS 的落盘位置；届时无需改统计代码即自动纳入。
3. **同步遍历**：`getCacheStats` 在 UI 线程同步 `listFileSync/statSync`。v1 缓存文件量级下可接受；
   若章节文件上万，需改异步或加缓存。
4. **清理后需靠已知归零**：`onClear` 直接置 0 而非重读（§5.3-2）。若未来 `clearCache` 出现
   删除失败（权限/占用），界面可能低报；可在后续加「延迟重读对账」。
5. **不做 LRU/上限**（`T-DATA-4`）与 **备份/恢复**（`T-DATA-3`）：本轮范围外，未触碰。
6. **`filesDir/local` 未计入**：见 §2 说明（本地书非缓存，且归属 `T-SHELF-1`）。

---

## 7. 提交状态

未提交（用户未要求）。本轮相关文件：

```
entry/src/main/ets/model/CacheRepository.ets   (新增)
entry/src/main/ets/pages/CacheManage.ets       (新增)
entry/src/main/ets/pages/Settings.ets
entry/src/main/ets/pages/Index.ets
entry/src/main/ets/common/Const.ets
HANDOFF-S9.md
```

`AGENTS.md`、`docs/progress.md`（并行 TTS 工作流）与本文件外的 untracked 文档（`AUDIT.md` /
`ROOT-CAUSE.md` / `TASKS.md` / `UI-SPEC.md` / `HANDOFF-S3..8.md` / `TTS-PLAN.md`）沿旧例不纳入。