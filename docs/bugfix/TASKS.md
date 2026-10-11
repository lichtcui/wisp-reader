> **2026-10-11 第十六次同步**：⑮ **T-READ-3 真机复验通过（`[~]` → `[x]`）** —— 设备 `33Z0224424136564` 上以「`uitest uiInput doubleClick` 连点『下一章』」复现同一 `bookId#index` 的并发索要：
> 修复后 key `5b4fad87#11` = **2 次 miss + 1 次 join + 仅 1 次 engine**；**修复前对照**（临时旁路 `inflight.set`）同手势下 key `#39` / `#45` = **2 次 miss + 2 次 engine**、`join` 0 次。
> 插桩与对照改动已还原（`git checkout`，工作区干净、`rg TEMP` 无残留），还原后重装复跑：清空全部缓存 → 打开《剑来》第五十章正文由引擎重新拉取并渲染、点「上一章」→ 第四十九章正常，0 JS 错误 / 0 崩溃。
> 证据：条目内「真机验证」段与 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §15。
>
> **2026-10-08 第十五次同步**：⑭ **T-TTS-6 路线 A（声纹匹配）跑完 = 阴性且决定性** —— `fanchen-C` 的 187 个声线**不是**原神角色；
> 关键是**方法有效性已做真阳性对照**（ZipVoice 零样本克隆官方中配参考音频，声纹自比 **0.76–0.88 / 7-7 全中**），排除了「合成声↔真实录音域差」造成的假阴性。
> **同时重新测量了路线 B 并推翻上一轮的 RTF 判据**：参考音频裁到 6 s 后 `num_steps=3` 的 **RTF = 0.655–0.962**（上一轮 1.04–1.53 是 8 s 长 prompt 所致），
> 音色 **7/7 声纹命中** → **只剩「few-step 毛刺能不能听」这个听感问题**。试听包 `~/Desktop/tts-原神克隆/`（steps 3 vs 6）。
> 文档：[`../research/TTS-VOICE-SOURCES.md`](../research/TTS-VOICE-SOURCES.md) §10（路线 A）/ §11（路线 B）；T-TTS-6 状态 `[ ]` → `[~]`。
>
> **2026-10-08 第十四次同步**：⑬ 登记 **T-TTS-6（P1）远端 TTS 音色：中文原神模型到底有没有** —— 调查完成，结论是「**有，但进不了现有 CPU 管线**」。
> 同时**修正 T-TTS-5 的两处记录**：① 上线声线用的 sid（胡桃 119 / 甘雨 111 / 刻晴 115 / 雷电将军 125 / 钟离 104）在刚拿到的原神 sid 表里**是没有名字的空洞号**，
> 「804 底模自带原神声线」的说法降级为**未验证**；② 「像日本人说话」**不是词典没修好，而是模型基座中/日混训**（`zh_ja_mixture_cleaners` + `uma_genshin_genshinjp_bh3`）——
> 用**正确** sid（钟离 106 / 甘雨 161 / 胡桃 160 / 刻晴 165 / 雷电将军 107 / 魈 115）重测 CER **反而更差（14.36% vs 12.62%）**，且 F0 与角色完全对不上。
> 调查全文、模型清单与可选路线见 [`../research/TTS-VOICE-SOURCES.md`](../research/TTS-VOICE-SOURCES.md)。

> **2026-10-08 第十三次同步**：⑫ **T-TTS-5 服务端部分完成** —— 远端 TTS 已切到 VITS 并上线，服务端三个真 bug（词典 / 数字 / 停顿）修复，`/health` 返回 `{ok,engine,version,sample_rate,voices,speed_scale,post,eq}`。
> 关键转折：**不需要微调** —— 804 说话人底模自带原神声线（含钟离/胡桃/甘雨/刻晴/雷电将军），F0 正常；原先规划的「微调 VITS」路线作废。
> 线上实测 RTF **0.576**（硬约束 <1 达标）、RSS 441MB 零增长、24kHz 契约与旧音色名兼容均保持不变。剩余：真机端到端 + `readTimeout` 整改（设备离线）。

> **2026-10-08 第十二次同步**：⑪ 登记 **T-TTS-5（P1）远端 TTS 引擎切换**（即 T-TTS-4 删除时所指的「整体重做」）。
> 本轮实测把「杂音 + 跟不上」两个症状收敛到同一个根因：ZipVoice 在本机**没有任何一档 `num_steps` 能同时实时与不浑浊**；
> 同时实测出唯一可行替代（`sherpa-onnx-vits-zh-ll` RTF 0.40 / RSS 250MB），结论与训练链路见 [`../research/TTS-ENGINE-COMPARISON.md`](../research/TTS-ENGINE-COMPARISON.md)。
> 已顺带上线 v1.1.0 后处理（EQ + 限幅 + 响度归一），不依赖换引擎也先把音质拉起来。

# TASKS.md — 跨模块 Bug 修复任务清单

> 由早期只读审计（原 `AUDIT.md`，已归档删除）派生；按模块分组。
> 状态：`[ ]` 未开始（含显式顺延）· `[~]` 已实现待复验 / 部分缓解 · `[x]` 完成。
> **2026-10-07 两次同步**：① 与文末「S10 回归验收状态」表对齐（21 项已修但仍标 `[ ]`，一并更正）；
> ② release 包首次真机冒烟（T-VER-6）+ 逐项核代码：T-SRC-1 真机复验通过、T-DATA-3 备份往返验证通过（原记「M6 未开始」有误）。
> 行的 `证据` 行号多为审计时快照，可能已漂移。
> **2026-10-07 第三次同步**：③ T-DATA-7（导入非「全量覆盖」）已修复并真机复验 —— 导入改为真覆盖（`replaceShelf`）。
> **2026-10-07 第四次同步**：④ T-DATA-4（缓存上限策略）已实现 ——
> 口径、算法与验证步骤见 [`../research/CACHE-LIMIT-PLAN.md`](../research/CACHE-LIMIT-PLAN.md)。
> **2026-10-07 第五次同步**：④ T-DATA-4 已**真机六项压测通过**（含未读先删 / 软保护降级 / toc 连带删 / 新鲜窗口 / 会话保护集 / TTL / 封面水位，逐字节与沙箱对账，常量已还原）；
> 证据见条目内「验证」段与 [`../research/CACHE-LIMIT-PLAN.md`](../research/CACHE-LIMIT-PLAN.md) §8。
> **2026-10-07 第六次同步**：⑤ T-CROSS-3（R3）不再是「仅缓解」——改为「**播放中音频独占进度写**」归属仲裁（新增 `model/ProgressOwner.ets`），
> 并顺带修 `Reader.onTtsProgress` 跨章缺段落锚点；真机四场景（含**修复前对照**）验证通过，证据见条目内「验证」段与 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §11。
> **2026-10-07 第七次同步**：⑥ T-SHELF-3（P2）边界加固落地——反推收敛到 `Format.deriveTotalChapters`，脏值/退化值不再编造总数；
> 真机取证：三态（含新加一本书看到的「未读过」）+ 沙箱 DB 对账 + **临时插桩的脏值旁排对照**（修复前「已读到最新章」误报 / 「28章/28000000000章」→ 修复后「第153章」/「第28章」），插桩已还原、测试书已删、DB 逐字节复原；
> 证据见条目内「验证」段与 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §12。并登记 T-SHELF-6（`toc.length` ↔ `percent` 反推的口径分歧）。
> **2026-10-07 第八次同步**：⑦ T-SHELF-6（P2）已修**真根因**——不是文档口径问题，而是 TOC 缓存**事实上永久**（`CachedToc.fetchedAt` 写了从没人读）→ 连载书新章永不出现；
> 现加 6h 新鲜期 + 打开书时**后台重爬**（失败静默回退缓存，章数变化时用新分母重写 `percent` 让书架自愈）。文档口径同步改为「快照」；
> 真机 8 项证据见条目内「验证」段与 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §13。
> **2026-10-08 第九次同步**：⑧ T-SHELF-5（P2）已修并真机复验——不是「缓存文件损坏」或取用路径问题，而是**引擎把非图片正文（详情页 / 防盗链 HTML）写进了 `cover_*.img` 且命中缓存即早退**，中毒 slot 永不复检（封面永久占位 + 每次渲染刷 `ImageSource` 62980118）；
> 现改为「写盘前嗅探图片签名 + 缓存命中先验头 64 B（旧毒文件则删除重下）+ ArkTS 解不开就删文件」。修复后启动 8s 内该组错误 **15 行 → 0 行**，真机证据见条目内「验证」段与 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §14。
> **2026-10-08 第十次同步**：⑨ T-READ-1（R7）**统一正文清洗**已落地（纯重构、无行为变更）——`Reader` 的私有 `sanitize` 删除，阅读页与听书共用 `BookContent.sanitizeText`；真机复核段落下标一致（`start para=7` = 阅读页 `paragraphIndex`，`play para=8/9/10` 连续推进），详见条目内「验证」段。
> **2026-10-08 第十一次同步**：⑩ T-READ-3（P2，原顺延）已实现并转入 `[~]` —— `Reader.fetchContent` 加单飞表（`inflight: Map<bookId#index, Promise<string>>`，引擎请求 + 写盘下沉到 `fetchRemote`），
> 频繁切章时同一章只发一次引擎请求、只写一次盘（内存 LRU 挡不住并发：`warmNeighbors` 只判「已解析缓存」，两条路径在缓存都未命中时并发进来）；
> 顺带删除死代码 `prefetch`（全仓库无调用）。本机已验（编译 / `make check` / 转译产物 / 调用面 `rg`），**真机待复验**（设备未连接）→ [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §15。
> 同时：**T-TTS-4 条目已按用户决定移除**（远端 TTS 链路后续会整体重做，不再单独治理其并发预取的 RTF 劣化；相关部署事实已记入 [`../remote-tts-deploy.md`](../remote-tts-deploy.md) §0/§3）。
> 当时 open：**1 项 `[~]`**（T-READ-3 已实现，待真机复验）+ **1 项 `[~]`**（T-TTS-6：路线 A 已证伪、路线 B 已实测可行，待听感/路线决策；T-TTS-5 剩余真机项受设备离线阻塞）。
> **（T-READ-3 已于 2026-10-11 真机复验通过 → `[x]`，见文首第十六次同步；设备现已在线，T-TTS-5/6 的真机项可做。）**
> 优先级：P0（阻断/高影响）→ P1 → P2。每项给出证据位置与验证方式。

---

## 跨模块 / 高优先（P0）

- [x] **T-CROSS-1（R1）阅读 ↔ 听书跨书串扰**：`Reader.onTtsProgress` 与 `isSpeaking` 增加 `bookId` 守卫，仅同书才滚动/高亮。
  - 证据：`entry/src/main/ets/pages/Reader.ets:53-66`、`:348-352`
  - 验证：真机「听书 A 时打开 B」→ B 不跳章、B 进度不被写成 A 的章节号。
- [x] **T-CROSS-2（R2）听书后台任务泄漏**：`pause()` 与自然播完（`onParagraphEnd` 末章）时调用 `stopBackground()`；恢复播放再 `startBackground()`。
  - 证据：`entry/src/main/ets/model/TtsController.ets:203`（仅 stop 调）、`:705-721`、`:725-744`、`:429-437`
  - 验证：播完/暂停后 `hidumper` 或任务列表确认 `AUDIO_PLAYBACK` 长时任务已结束。
- [x] **T-CROSS-3（R3）进度写竞争**：为 `progress` 写入加归属/`updatedAt` 防覆盖（如仅当前活动模块可写，或写入前比较 `updatedAt`）。
  - 状态（2026-10-07）：**已修复**——口径为「**播放中音频独占，阅读页只读**」（用户选定）。新增 `model/ProgressOwner.ets`（纯状态、无 import，避免循环依赖）：
    `ProgressWriter{NONE,READER,TTS,RESTORE}` + `claimProgress` / `releaseProgress` / `canWriteProgress` / `forgetProgressOwner`；
    `saveProgress(p, writer)` 的 `writer` 为**必填**参数，归属检查在 `lastWriteAt` 时间戳守卫**之前**（被拒的写不得污染时间戳）；
    `TtsController.setPlaying` 成为 `playing` 的**唯一**写入口：起播 `claim`，暂停/播完/出错 `persistProgress()` 后 `release`；
    `removeBooks` 连带 `forgetProgressOwner`；`replaceShelf` 以 `RESTORE` 绕过仲裁且**不**清归属（导入不得劫持进行中的听书会话）。
  - 归属绑 `playing` 而非 `active`：`active` 含「暂停 / 播完」，那两种状态下 TTS 已不再写，绑它会静默吞掉阅读页写入。
  - **顺带修复**：`Reader.onTtsProgress` 跨章跟随缺段落锚点（`loadChapter(tts.chapterIndex)` 默认 `paragraphIndex=0`）——音频在本章第 N 段时阅读页会落到章首，修复前还会把章首写进库；现传 `this.tts.paragraphIndex`。
  - 证据：`model/ProgressOwner.ets`（新增）、`model/ShelfRepository.ets:181-200`、`model/TtsController.ets:322-338`（`setPlaying`）、`pages/Reader.ets:121-131`
  - 验证（2026-10-07 真机 `33Z0224424136564`，debug 包，含**修复前对照**）：逐场景证据见 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §11——
    ① 修复前：音频在 ch0 播放时阅读页点「下一章」→ 库被写成 ch1（复现覆盖）；修复后同一操作库仍留音频章，阅读页在音频下一次推进段落时被拉回音频段（含长段落所在页，非第 1 页）；
    ② 播放中暂停 → 立即落盘（`STATE_PUSH_MS` 临时抬到 60s 仍见写入，证明走的是新 `setPlaying(false)` 路径；常量已还原 1000）；
    ③ 暂停后阅读页跳章写入恢复（归属已释放）；④ 无 TTS 会话的书照常写进度。

---

## 书架（Shelf）

- [x] **T-SHELF-1（R5）删除书籍清理关联缓存**：`removeBook` 后一并删除 `filesDir/chapters/{bookId}_*`、`filesDir/tocs/{bookId}.json` 与 `filesDir/local/{bookId}`（本地书），并 evict `ChapterCache`/`TocCache`/`LocalBook` 内存层。
  - 证据（修复前）：`model/ShelfRepository.ets:80-87`、`model/ChapterCache.ets:24-30`、`model/TocCache.ets:34-45`、`model/LocalBook.ets:49-59`
  - **处置（2026-10-07，SHELF-EDIT-PLAN §8 S2）**：`removeBook` → `removeBooks(bookIds)`（批量，含 `lastWriteAt.delete`，连过时 TODO doc comment 一起替换）；新增 `ChapterCache.deleteBookChapters`、`TocCache.deleteBookToc`、`LocalBook.deleteLocalBookData`，由新增 `model/BookRemoval.ets::deleteBooks(ctx, bookIds)` 编排（DB 先删 → 再清三类缓存；删除前 `tts.isActiveFor → stop()`；封面文件刻意不删，见该文件注释）。
  - 集成：`Index.confirmDelete()`（二次确认弹窗）+ `Index.doDelete()`（`deleting` 防重入 → `deleteBooks` → `edit.exit()` → `shelfRefresh+1` → Toast）。
  - 验证：真机项见 `SHELF-EDIT-PLAN.md` §8 S2 验证 / §10 D6–D12。【**2026-10-07 已真机验证**】删「夜的命名术」（播放 TTS 中）：书架 4→3、重启仍 3；DB `books` 4→3 / `progress` 7→6；`chapters/` 13→6、`tocs/` 4→3（应用内「目录缓存」235.5→73.8KB = 差值与文件字节对得上）；TTS 停（之后无 `play para=`）+ FAB 消失；双击「删除」防重入只删一次；0 JS error。**D10（本地书）/D12（删空）经用户同意跳过。** 编译 ✅ debug + release（含签名）均 `BUILD SUCCESSFUL`（见 `RELEASE-NOTES.md` §1.3）。
  - 触发路径方案（含书架编辑模式 / 多选删除）：[`../archive/SHELF-EDIT-PLAN.md`](../archive/SHELF-EDIT-PLAN.md)（§8 S2）
  - 方案状态：已经**五轮审计**（§1.1–§1.4）。第四轮关闭 R2（官方 V2 文档同形示例）；第五轮用**本机 release 混淆产物**取证：
    ArkUI struct 成员被自动保留、`@ObservedV2` 类成员会被改名 → 新增 K15/§5.5「禁字符串式属性访问」约束（`obfuscation-rules.txt` 不必改）；
    另修一处计划缺口（`ShelfRepository.ets:79-86` 的过时 TODO 注释需在 S2-1 连注释一起替换）；S1/S2 逐行对账通过 = **代码零修改**。
    带完整代码与逐步验证清单，可直接按 §8 S1 开工。
- [x] **T-SHELF-2（R10）数据层懒初始化**：`ShelfRepository` 在 `store===undefined` 时补初始化，避免书架 Tab 初始化前进度丢写。
  - 证据：`model/ShelfRepository.ets:20-36,130-145`、`pages/Shelf.ets:42`
- [x] **T-SHELF-3 进度三态**：核对 `progressText` 的 `total` 反推在 `percent` 为 0/极小值时是否正确。
  - 状态（2026-10-07）：**已完成**（主机复算 + 真机三态 + 真机脏值对照）。
  - **核对结论**：正常区间**零误差** —— `percent` 恒为 `(chapterIndex+1)/章节数`，`Math.round((ci+1)/percent)` 在 `len ≤ 20000` 的**全部**章序×章数组合（2.0 亿组）下都等于真实章数。
    有问题的只有**应用自己不会写**的脏值：① `percent ≤ 0 / NaN / Infinity`（旧码已自然落到「第N章」）；
    ② **极小值** —— `1e-9` → 「**7章/7000000000章**」、次正规 `5e-324` → 「**7章/Infinity章**」；
    ③ **`percent > 1`** —— 旧码反推出 `total < 已读章数` → 误报「**已读到最新章**」。
  - **处置**：反推从 `Shelf.ets` 的内联表达式收敛到 `common/Format.ets::deriveTotalChapters(chapterIndex, percent)`（单点、可复算、可复验）；
    越界/退化值回 `0` → `shelfProgressText` 降级为「第N章」（**总数不可信时不编造数字**）；正常值路径与三段文案**逐字节不变**。无新增 JSON 字段（未动混淆 keep）。
    兜底阈值 `MAX_DERIVED_CHAPTERS = 100000`（`percent < 1/1e5` 即判不可信）、并拒收 `total < 已读章数` 的反推结果。
  - 验证（2026-10-07 **主机 + 真机 `33Z0224424136564`**，debug 包 `make run`）：
    ① 主机：把 `Format.ets` 拷成 `.ts` 后用 `node --experimental-strip-types` **直接 import 真实函数**复算（脚本 `/tmp/tshelf3/check.ts`）——9 项退化值 + 8 项正常值 + `len ≤ 20000` 全枚举 = **0 FAIL**；
    ② 真机三态（`uitest dumpLayout`）：剑来 `3章/50章`、大唐 `153章/1441章`、天堂向左 `已读到最新章`，搜索→加入书架 的第 4 本（未打开过）显示 `未读过`；
    拉沙箱 `shelf.db` 对账：`percent` 0.06→50 / 0.106176…→1441 / 1.0→末章，与文案逐条相符；
    ③ 真机脏值对照（沙箱**不可写** —— `uid=2000(shell)`，`/data/app/el2/...` 与共享存储均 `Permission denied`，无 root —— 改用与 T-CROSS-3 同型的**临时插桩**：
    对两本书注入脏 percent 并把「修复前表达式 ｜ 修复后函数」并排渲染）：大唐（`percent=1.5`）`已读到最新章 ｜ 第153章`（**修复前误报已完成**）、天堂向左（`percent=1e-9`）`28章/28000000000章 ｜ 第28章`；未注入的剑来 `3章/50章 ｜ 3章/50章`（零回归）；
    插桩已还原（`git diff` 无 TEMP 残留）并复验回三态原文案；全程 **0 JS 错误 / 0 崩溃**。
  - 数据复原：测试用第 4 本「赘婿」经编辑模式删除；沙箱 DB 回到 `books 3 / progress 7`，三行 `percent`/`chapter_index` 与验证前逐字节一致。
  - 未覆盖：无法用**真实脏行**验证（沙箱写不进、备份导入=全量覆盖），脏值分支靠临时插桩；`make check` 通过（无新增 JSON 字段）。
  - 证据：`common/Format.ets:1-40`（新增 `MAX_DERIVED_CHAPTERS` + `deriveTotalChapters`）、`pages/Shelf.ets:302-310`（原 `:307` 内联反推已删除）。
- [x] **T-SHELF-6 进度总数口径分歧 → 真根因：新章永不出现**：原登记为「文档写 `chapterIndex >= toc.length-1`、实现走 `percent` 反推」的口径分歧；
  逐路径核代码后发现**真正的问题是 TOC 缓存没有过期条件**：`TocCache` 只比 `tocUrl`（`CachedToc.fetchedAt` 有写入、**全仓库从未被读**）→ 缓存事实上永久，
  而 `Reader.loadToc` 命中即返回、全仓库无刷新入口 ⇒ `tocUrl` 不变的连载书**首次打开之后新章永远不出现**（目录少章 + 书架永远「已读到最新章」），
  只有清缓存 / 配额驱逐 / 换源才重爬。原登记里「重新打开即刷新」的前提不成立（打开会重写 `percent`，但用的是同一份陈旧目录）。
  - 处置（用户选定「修根因 + 后台异步刷新」）：`common/Const.ets::TOC_REFRESH_AFTER_MS = 6h`；`TocCache` 导出 `CachedToc` + 新增 `isTocStale`（`fetchedAt` 缺失/≤0 视为过期，老文件首次打开即补时间戳）；
    `Reader.loadToc` 命中缓存**先返回**、过期则 fire-and-forget `refreshToc`（失败静默；独立会话令牌 `tocSession` 防换书/销毁后写状态；目录为空或短到不含当前章→**连缓存都不覆盖**；
    章数未变不动列表，变化则重绑 + `buildTocItems()` + `persistProgress()` **用新分母重写 `percent` → 书架下次加载自愈**）；本地书不联网。
  - 附带修：`buildTocItems` 的 `this.dataSource = next` 改为复用同一实例 `setItems()` —— **LazyForEach 只在创建时读一次数据源**，换实例不会让已挂载的目录抽屉重渲染（真机曾观察到「目录 · 29 章」但列表仍 28 行）。
  - 文档口径同步：「书架三态」改为**快照口径**（`architecture.md` §领域模型、`plan.md` §进度语义）；`PITFALLS.md` 增两条（永久缓存 / LazyForEach 换实例不刷新）；`CACHE-LIMIT-PLAN.md` §2 注明 toc 另有新鲜期。
  - 验证（2026-10-07 真机 `33Z0224424136564`，debug 包 + `uitest dumpLayout`）：基线（28 章 / 书架「已读到最新章」）→ ① TTL=0 → 日志 `toc refreshed 28 → 29 chapters` → ② 插桩伪造新章：目录「· 29 章」+ 末行 `【临时插桩】新章`，阅读位置不动 → ③ 返回书架 `28章/29章`（**自愈**）→ ④ TTL=2000ms（正值 + 时间流逝）→ 日志 `toc refresh: 28 chapters (cached 28)` → ⑤ 还原 6h：无任何 toc 日志（新鲜期不重爬）、目录回 28 章 → ⑥ 正序/倒序仍生效 → ⑦ 应用侧 0 条 error → ⑧ `rg TEMP` 无残留、沙箱 toc 缓存未插桩污染（伪造章在 `putCachedToc` 之后只进内存）。
  - 证据：`common/Const.ets`、`model/TocCache.ets`、`pages/Reader.ets`（`loadToc`/`refreshToc`/`tocSession`/`buildTocItems`）；完整表见 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §13；`make check` / `make doctor` 均 ✓。
  - 未覆盖：release 包；「源返回不完整目录」未构造真实场景（仅代码守卫）；6h 未长跑（只验 TTL = 0 / 2s / 6h 三档）。
- [x] **T-SHELF-4（真机）长按手势被静默丢弃**：`Shelf.ets` 按计划 §8 S1-3e 写成 helper 返回 gesture（`longPressToEdit(entry): GestureType`）+ `.gesture(this.longPressToEdit(entry))` → **真机长按从不触发**（编译无错、无告警）。
  - 证据（转译产物）：`entry/build/.../esmodule/debug/entry/src/main/ets/pages/Shelf.ts` 里该参数位退化为 `globalThis.Gesture.create(GesturePriority.Parallel); globalThis.Gesture.pop();`（**空手势**）；真机 `uinput -T -d x y -i 900 -u x y` 实测 Down/Up 间隔 935ms 但无任何 gesture 回调。
  - **处置（2026-10-07）**：改为内联手势字面量 `.parallelGesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => this.onLongPress(entry)))`（grid/list 两分支同形），helper 改名 `onLongPress(entry): void`（只留 `longPressFired=true` + `edit.enter`）。理由：`.gesture()/.parallelGesture()` **只接受内联手势字面量**；且 `.gesture()` = `GesturePriority.Low` 会输给祖先识别器。
  - 验证：✅ 真机长按 +498ms 进编辑态（D1/D19）；已回写计划 §1.6 #42/#43、§5 K16、§5.2。
- [x] **T-SHELF-5（R12）封面解码失败日志（2026-10-08 真机修复）**：根因**不是**「缓存文件损坏」也不是 `BookCover`/`pixelMap` 取用路径，而是 **Rust `download_cover` 只校验正文非空、完全不校验是不是图片**（详情页 / 防盗链 HTML 照样落盘），且 `if path.exists() { return Ok(path) }` **命中即早退** ⇒ 中毒 slot 永不复检/永不重下。
  定性：**既是日志噪音也是用户可见空封面**（该封面永久停在红渐变占位，且每次组件重建都重试解码 → 错误刷屏）。
  - 取证链（真机 + 主机双向）：① `62980118` 在 SDK `@ohos.multimedia.image.d.ts` = **Failed to create the image plugin**（数据不是可识别的图片格式），非「文件损坏」的笼统码；
    ② `hdc file recv` 拉回沙箱 28 个 `cover_*.img` 逐个 `file` 检查：**仅 `cover_abfeec91b5ff5574.img` 是 HTML**（《天堂向左 深圳往右》详情页 10936 B）；自建 rustc 小程序复算 `DefaultHasher` 确认 `abfeec91b5ff5574 == hash("https://tiantangxiangzuoshenzhenwangyou.qwyd.net/")`，与该书 DB 行 `books.cover_url`（`8200e532`）一致；
    ③ `uitest dumpLayout`：`剑来` 封面区无 Text（图片正常渲染），《天堂向左》《大唐》（封面 URL 为空）封面区各有书名 Text → 走占位分支 ⇒ 失败是**用户可见空封面**；
    ④ 该书的 page-as-cover 值属 DB 历史行（现源 `🔖天堂向左 深圳往右` 的 ruleSearch / ruleBookInfo **都没有 coverUrl 规则**，`make probe … search/info` 现版都返回 `coverUrl: ""`），但**源规则改动 / 防盗链返回 HTML 页面（200 + text/html）是现实常见情形**，且一旦中毒永不自愈 ⇒ 修的根本价值在「不再可能被毒化 + 自愈既有中毒项」。
  - 处置（Rust `runtime.rs`，封面段）：抽出 `cover_cache_path`；新增 `has_image_magic`（JPEG / PNG / GIF87a·89a / BMP / ICO / `RIFF….WEBP` / offset 4 处 `ftyp` 的 HEIC·HEIF·AVIF）、`starts_like_markup`（跳 UTF-8 BOM 与空白后首字节是 `<` / `{` / `[`，或全空白）、`looks_like_image`（markup 直接否；有 magic 直接是；否则只认 `image/*` 且非 text）、`cached_cover_is_usable`（读头 64 B）；
    `download_cover` = 「缓存命中需 `cached_cover_is_usable` 才复用（否则删除旧文件重下 = **自愈**）」+「写盘前 `looks_like_image` 校验，不是图片则**删文件 + 不落盘**，返回 `not_image`」；`status.rs::fail_message` 加 `not_image` 文案（不新增 `FailReason` 变体）。
  - 处置（ArkTS `components/BookCover.ets`）：新增会话级 `failedCache`（上限 128）⇒ 同一 URL 每会话只尝试一次（失败 URL 原本不进任何缓存，故每次重渲染都重试、重复刷屏）；catch 里清 `pathCache` 并 `fileIo.unlinkSync` 掉解不开的文件（下个会话可重下），保留一条 `hilog.warn`（带 url + 原因，现在每 URL 每会话恰一次）。
  - 验证（2026-10-08 · 设备 `33Z0224424136564` · debug · `make test` → `make rust` → `make run`）：
    ① `make test` **56 项全过**（新增 `test_looks_like_image` + `test_download_cover_validates_and_self_heals`，后者含「拒绝 HTML 不落盘 / content-type 说谎也拒 / 接受 PNG 且字节相符 / **预置毒文件 → 自愈重下**」）；
    ② 启动后 8s 抓 `hilog`：`62980118` / `failed to create decoder object` / `Create PixelMap error` **0 行**（修复前基线 15 行 = 3 次尝试 × 5 行）；
    ③ 恰一条 `SourceReaderCover: cover unavailable url=https://tiantangxiangzuoshenzhenwangyou.qwyd.net/ err=not_image`（基线插桩为 `err=undefined`，说明现在引擎能说清原因）；
    ④ 沙箱中毒文件 `cover_abfeec91b5ff5574.img` 已消失；`hdc file recv` 全部 38 个 `cover_*.img` 经 `file` 检查**全为合法 JPEG，无一 HTML**；
    ⑤ `uitest dumpLayout` 与修复前**逐行一致**（`剑来` 仍无占位 Text = 正常封面未回归；另两本仍占位 = 预期）；
    ⑥ 书架↔搜索来回切 3 轮：**0 条封面日志**（负缓存生效，不再重复下载/解码）；
    ⑦ 搜索「剑来」107 条结果 + 5 个新下载封面全部解码成功（新下载路径未被守卫误杀）。
  - 未覆盖：release 包未复跑；跨启动不重下需要持久负标记 `cover_*.miss`，**故意不做**（会破坏 `CacheTrim` 的 `cover_` 前缀 + `.img` 后缀扫描 → 变成永不被清理的泄漏），接受「每次启动对该 URL 一次无效请求」；`ImageSource.release()` 未加（无法无截图验证渲染，风险大于收益）。
  - 证据：`rust/legado-engine/src/runtime.rs`（`cover_cache_path` / `looks_like_image` / `download_cover` / tests）、`rust/legado-engine/src/status.rs`、`entry/src/main/ets/components/BookCover.ets`；完整修复说明见 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §14。

## 搜索（Search）

- [x] **T-SEARCH-1（R9）引擎边界参数透传**：确认 `opts.concurrency` 是否需要传给 native（当前被丢弃）。
  - 证据：`entry/src/main/ets/engine/BookEngineNapi.ets:19-24`
- [x] **T-SEARCH-2 搜索代次 guard 回归**：核对连续重搜/返回时的 `searchGen` 与 `pending` 计数无残影。
  - 证据：`pages/SearchResult.ets:64-135`

## 阅读（Reader）

- [x] **T-READ-1（R7）统一正文清洗**：`Reader.sanitize` 与 `BookContent.sanitize` 合并为单一实现，保证 TTS 段落索引与阅读页一致。
  - 状态（2026-10-08）：**已完成**，**纯重构、无行为变更**（改动前先 `diff` 两处函数体：**逐字节一致**，只有上方注释换行不同）。
  - 为什么值得顺手做：阅读页首章进听书时 TTS 直接用 `Reader.paragraphs`（`openListening` 传引用），但**跨章**走的是 `TtsController` → `loadChapterParagraphs` → `BookContent.sanitizeText`；两份副本一旦分头改（例如只给阅读页加一条噪音行过滤），跨章后的段落下标就会与阅读页错位。合并后该风险结构性消失，不必再靠「记得同步两份」。
  - 修法：删除 `Reader.ets` 的 `private sanitize`（连重复注释），改 `import { sanitizeText } from '../model/BookContent'`，两个调用点（`applyChapter`、`warmNeighbors`）改调 `sanitizeText`；`BookContent.sanitizeText` 注释标明「**唯一实现**」及漂移后果；`Reader.ets` 顶部文件索引同步去掉 `sanitize`。
  - 验证（2026-10-08 · 设备 `33Z0224424136564` · debug · `make run`）：① `make doctor` 无阻断项、`BUILD SUCCESSFUL`；② 打开《剑来》第三章：阅读页标题 + 6 条正文段落节点正常渲染（`uitest dumpLayout`）；③ 底栏「听书」→ `hilog`：`SourceReaderTts: start book=剑来 chapter=2 para=7` + `begin para=7`（= 阅读页 `paragraphIndex`，听书页显示第 8 段），随后 `play para=8/9/10/…` 连续推进，无加载失败；
    ④ **跨章路径（本次改动真正覆盖的那条）**：本段播完后自然跳入下一章 —— `begin para=0` 后继续 `play para=1/2/…`（该章正文由 `loadChapterParagraphs` → 合并后的 `sanitizeText` 产出），回到阅读页 `uitest dumpLayout`：章名同为《第一卷 笼中雀 第四章 黄鸟》、页首 para 0 = 章名标题、正文段落与 TTS 正在读的第 3 段一致（段落下标两边同序）。
  - 未覆盖：release 包未复跑；未单独构造「两份实现漂移」的对照实验（重构后已不存在第二份实现）。
  - 证据：`entry/src/main/ets/model/BookContent.ets:6-19`、`entry/src/main/ets/pages/Reader.ets:51,457,503`
- [x] **T-READ-2（R8）章节缓存内存上限**：为 `ChapterCache` 内存层加 LRU/上限；清理死代码 `hasCachedChapter`。
  - 证据：`model/ChapterCache.ets:18,92-94`、`plan.md:270`
- [x] **T-READ-3 预取去重**：频繁切章时避免对同一 `bookId#index` 重复预取/重复写盘。
  - 状态（2026-10-11）：**已完成**（实现 2026-10-08 + **真机正/反对照复验 2026-10-11**，设备 `33Z0224424136564`）。
  - 根因核对：内存 LRU（T-READ-2）只降低了「写盘撞车」的概率，**挡不住并发**——`warmNeighbors` 的判重是
    `paraCache.has(n)`（已解析缓存），两条路径在**缓存都未命中**时并发进来，于是同一 `bookId#index` 发两次引擎请求、
    写两次 `putCachedChapter`；后到的那份还会被 `loadChapter` 的 `loadGen` 守卫直接丢弃（`Reader.ets` 里 `if (gen !== this.loadGen) return;`）= 纯浪费。
  - 修法（纯 ArkTS）：`fetchContent` 加单飞层 —— 缓存查询不变，未命中则按 `bookId#index`（与 `ChapterCache.memoryKey` 同形）
    查 `inflight: Map<string, Promise<string>>`，命中返回同一 promise，未命中入表、`finally` 出表（失败仍可重试）；
    引擎请求 + 写盘下沉到新的 `fetchRemote`（只被 `fetchContent` 调用）。key 带 `bookId` ⇒ 跨书复用实例也不串。
  - 顺带：删除死代码 `prefetch(index)`（全仓库无调用；`HANDOFF-S10.md` §6.1 记的「保留未删，无碍」随之失效），
    `warmNeighbors` 已覆盖「暖邻居进文件缓存」；文件索引行同步改为 `fetchContent / fetchRemote`。无新增 JSON 字段 ⇒ 未动 keep。
  - 验证（2026-10-08 · 本机）：`make hap` `BUILD SUCCESSFUL`（`Reader.ets` 零 ArkTS 告警）；`make check` ✓（145 个 keep 名字覆盖不变）、`make doctor` 无阻断项；
    转译产物核对 `entry/build/.../esmodule/debug/.../pages/Reader.ts:443-454` —— `inflight.get` 早退 + `set` + `delete` 均在，未被编译期改写，`prefetch` 无残留；
    `rg` 复核全部取正文入口（`loadChapter` / `warmNeighbors`）均经 `fetchContent` ⇒ 无绕过去重的路径。
  - **真机验证（2026-10-11 · 设备 `33Z0224424136564` · debug · `make run` · 临时插桩已还原）**：《剑来》（`bookId=5b4fad87`，联网源）上用
    `uitest uiInput doubleClick 1159 2434`（连点底栏「下一章」）制造并发，插桩三行 = `fetchContent` 缓存未命中（`miss`）/ 命中在飞表（`join`）/ `fetchRemote` 真正打引擎（`engine`）：
    ① **修复后**：key `5b4fad87#11` = `miss`×2 + **`join`×1** + **`engine`×1** ⇒ 两个调用方共享同一 promise，只发一次引擎请求、只写一次盘；
    ② **修复前对照**（临时注释 `this.inflight.set(key, task)`，同手势、同一本书）：key `#39` = `miss`×2 + **`engine`×2**、key `#45` = `miss`×2 + **`engine`×2**，全程 **`join` 0 次** ⇒ 对照确凿（修复前同一章确实请求两次、写盘两次）。
    ③ 还原（`git checkout` + `rg TEMP` 无残留）后重装复跑：应用内「清理全部缓存」（四类缓存归零）→ 打开《剑来》：**第五十章正文由引擎重新拉取并渲染**（缓存为空，证明取正文链路完好）、点「上一章」→ **第四十九章正文正常**；
    全程 **0 JSCRASH/CPPCRASH、0 条应用级 error**（仅框架噪音 `AceStateMgmt: No views to update`）。
  - 顺带观察（与本次改动无关，未定性）：同一台设备上《大唐：李世民求我造反》打开时目录显示「目录加载失败」——TOC 拉取失败，该路径（`loadToc`/`engine.toc`）**不经过** `fetchContent`；如需排查另立任务。
  - 未覆盖：release 包（不涉混淆面）；TTS 侧 `BookContent.loadChapterParagraphs` 有同型「未命中即打引擎」写法，
    但与阅读页是两条独立调用链、无共享单飞表，本次**不合并**（要合并需引入共享模块，另立任务）。
  - 证据：`pages/Reader.ets`（`inflight` 字段 / `fetchContent` / `fetchRemote`、`prefetch` 已删）、[`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §15

## 听书（Listening / TTS）

- [x] **T-TTS-1（R6）单例与引擎释放**：`stop()` 释放 `engine`（`shutdown`）并考虑重置单例；`onDestroy` 后不复用失效 `ctx`。
  - 证据：`model/TtsController.ets:68-75,190-212`、`entryability/EntryAbility.ets:17-20`
- [x] **T-TTS-2 定时器与自然结束**：自然播完时 `clearTimer()`，避免定时器空转。
  - 证据：`model/TtsController.ets:705-721`、`:880-907`
- [x] **T-TTS-3 错误态恢复**：`onError` 后 `playing=false`，确认 UI 与 `AVSession` 状态一致、可重试。
  - 证据：`model/TtsController.ets:585-590`、`pages/Listening.ets:359-374`
- [~] **T-TTS-5（P1）远端 TTS：ZipVoice → VITS 架构切换** —— **服务端已完成并上线（v2.0.0），真机验证待设备上线**。
  - 根因回顾：ZipVoice 在本机（4C Xeon / 3.9G）**没有任何一档 `num_steps` 同时做到实时与不浑浊** ——
    steps=2 RTF 0.558 / 200–300Hz 占 47.3%；steps=3 RTF 0.834 / 47.8%（吞吐余量仅 1.2×）；steps=6 RTF 1.485 已不能实时。
    用户反馈的「大量杂音」与「朗读跟不上」是**同一个架构根因**。
  - **实际落地（与计划不同）**：计划是「5 说话人之一 → 或微调 VITS」，**实际发现 804 说话人预导模型自带原神声线，零训练、零微调**。
    模型 `vits-hf-zh-jp-zomehwh.onnx`（804 说话人，原生 22050Hz，经 `_resample_fft()` 升到 24000Hz，**客户端零改动**）。
  - **上线声线**：胡桃 119 / 甘雨 111 / 刻晴 115 / 雷电将军 125 / 钟离 104（4 女 + 1 男）。
    ⚠️ **2026-10-08 修正**：这 5 个 sid 在社区公开的 804 说话人表里**没有名字**（是空洞号），所以「这个 sid 对应这个角色」**未经验证**；
    同期发现**即使换成表里有名字的原神 sid，CER 也反而更差**（见 T-TTS-6 与 [`../research/TTS-VOICE-SOURCES.md`](../research/TTS-VOICE-SOURCES.md) §3）。音色名目前只是**标签**，不代表真实角色。
    旧名别名兜底（App 端未改也能播）：**流萤→甘雨、花火→胡桃、卡芙卡→雷电将军**。
  - **期间修掉的三个上游真 bug**（详见 [`../research/TTS-ENGINE-COMPARISON.md`](../research/TTS-ENGINE-COMPARISON.md) §4.2–4.4）：
    1. **「发音像日本人」= 词典**：模型自带 lexicon 是「中文单字表（21,287）+ 日文词表（15,500）」两遍拼接，**没有一个中文词组**，
       14,150 个词只能查到日文读音（`追求` → ついきゅう、`分裂` → ぶんれつ）**且不打任何警告**。
       修法：换成自制纯中文 `lexicon_final.txt`（66,790 条 = 纯中文 66,395 + 补 395 罕用单字，日文段整段丢弃），加载期 **重复 0 / OOV 0**。
    2. **数字被整段吞掉**：模型符号表无 0-9，不加载 FST 时 `第2024章⋯12.5元⋯13800138000` 全被静默丢弃。
       修法：`rule_fsts=date.fst,number.fst,phone.fst` → 该句时长 3.31s→**6.59s**。（`new_heteronym.fst` 实测无效果，不加载。）
    3. **句末停顿只有 80ms（无呼吸感）**：`silence_scale` 在 VITS 路径**完全无效**（0.2→1.0 输出时长一字不差）；
       实测**去掉标点后内部停顿直接变 0** → 标点驱动分句，绝不能清。修法：服务端按 `。！？…` 切句 + 自插 `SENTENCE_PAUSE_MS=320`，
       逗号沿用模型自己的短停顿。实测长段落：句末 **0.41/0.50/0.49s** + 逗号 0.06–0.21s。
  - **服务端实测（`POST /tts` 端到端）**：24kHz✓ / −18.0 dBFS / 峰值 0.48–0.89 / **0% 削顶** /
    长段落（123 字 / 4 段）22.96s **RTF 0.576**（ZipVoice steps=3 是 0.834，降 31% 且长文不再掉速）。
  - **内存**：加载 196→317MB，soak 稳态 441MB，**100 次请求零增长**（干净 soak 确证），**无逐请求泄漏**。
    「6 天涨到 2513MB」的元凶是 v1.1.0 之前**每请求**新建重采样器（已修）。
  - **保留回滚**：`ENGINE=zipvoice` 可切回旧引擎（代码分支完整保留）。
  - 证据：`server/app.py`（v2.0.0）、`server/tts.service`（`ENGINE`/`VITS_*`/`SPEED_SCALE`/`SENTENCE_PAUSE_MS`）、
    [`../remote-tts-deploy.md`](../remote-tts-deploy.md)、VPS `/root/tts/genshin-vits/`（`mklex2.py` / `lexcheck.py` / `smoke.py` / `out_live/`）、
    试听包 `~/Desktop/tts-abtest7-换引擎/`（线上成品，5 音色 × 3 用例）。
  - **待办（设备上线后）**：① 真机端到端听感验收；② `RemoteTtsClient.ets` 的 `readTimeout: 60000 → ≥120000`；
    ③ `Const.ets` 的 `TTS_REMOTE_VOICE_OPTIONS` 由 `[流萤,花火,卡芙卡]` 换成 5 个新音色名；④ 用户确认后定 `SPEED_SCALE` 终值（当前 0.85 ≈ 325–368 字/分）。

- [~] **T-TTS-6（P1）远端 TTS 音色：中文原神角色音色到底拿不拿得到** —— **路线 A 已跑完并证伪；路线 B 已实测可行，卡在听感决策**。
  - **答「有没有」：有，而且很多** —— ModelScope `aihobbyist/GPT-SoVITS_Model_Collection`：
    **原神/中文 263 角色 / 56.1 GB**（钟离·甘雨·胡桃·刻晴·雷电将军·魈·迪卢克·派蒙·可莉·纳西妲·八重神子… **重点角色 40/40 全在库**）、
    **星穹铁道/中文 118 角色 / 36.0 GB（含 `流萤` / `花火` / `卡芙卡`）**，另有日语/英语/韩语，原神共 877 文件；作者 红血球AE3803 与 白菜工厂1145号员工，License CC-BY-NC。
    VPS 可直连 ModelScope（HTTP 200 / 0.54 s），实测下载 `钟离_ZH.zip` 213MB / 18.8 s、`流萤.zip` 305MB / 25.9 s。
  - **但格式是 GPT-SoVITS，进不了 sherpa 管线**：sherpa-onnx 只支持 VITS/Matcha/Kokoro/ZipVoice/Kitten/Pocket/Supertonic；
    且 GPT-SoVITS 在本机 **RTF ≈ 4.5**（i5-8250U 10 s 语音需 45 s；官方 M4 CPU 0.526；CPUFast 分支再 −45%）→ 与「RTF<1」硬约束**直接冲突**，要上就必须换 GPU 服务器。
    唯一的纯 VITS 原神模型（Gitee `TimeRainStarSky/GenshinVoice`，51 角色）**模型与 API 均已停止发布**，只留数据集。
  - **这台 Mac 不能自训**：`MacBookPro16,2` = Intel i5-1038NG7 + Iris Plus，**无 CUDA、也无 Apple Silicon 的 MPS**（MPS 只支持 Apple Silicon/AMD），
    GPT-SoVITS 与 VFFT 均要求这类 Mac 只能 CPU 推理；估算 20–50 h/角色。替代：租 GPU（¥1–2/h，~1 h/角色）。
  - **顺带修正上一轮结论**：现用 804 模型**本身就是原神模型**（`G_CJ.json` 的 `training_files: filelists/uma_genshin_genshinjp_bh3_train.txt.cleaned`；
    sid 92–230 = 原神中文 144 角色），但**中/日混训的基座决定了它出不了干净普通话**，换 sid 无效。
  - **路线 A（声纹匹配）结论：阴性，而且是决定性的**。从 263 个原神角色包里用 HTTP Range 只抽 `reference_audios/`（150 MB / 224 s，否则 56 GB），
    对 `fanchen-C` 的 187 个 sid 做声纹比对（`wespeaker_zh_cnceleb_resnet34` + `campplus_zh_en` 交叉）：
    - `within` 同一人（多段真实录音）= **0.784**；`between` 不同人 = 均值 0.539 / p95 0.778 / 最大 0.911；
    - **187 个 sid → best 真实角色**：中位 **0.547**、p90 0.664、**最大 0.767 且与次高打平**（sid175 对莱欧斯利和荒泷一斗都是 0.767）→ 直方图单峰、无可贴近 `within` 的簇；
    - **⇒ `fanchen-C` 的 187 个声线不是原神角色**；`G_C.json` 的 `training_files` 也无 genshin 字样（对比 `G_CJ` 明写），F0 分布 144 女/24 男/19 中性也与角色名单不符。
    - **关键：方法有效性做了真阳性对照** —— 用 ZipVoice 零样本克隆官方中配参考音频，其产物与其自身参考音频相似度 **0.76–0.88，7/7 全部正确命中** ⇒ 声纹法**能**跨「合成声 ↔ 真实录音」域差，上面的阴性不是假阴性。
    - 细节：[`../research/TTS-VOICE-SOURCES.md`](../research/TTS-VOICE-SOURCES.md) §10。
  - **路线 B 重新测量：推翻上一轮的 RTF 判据**。ZipVoice + 官方中配参考音频，音色同样 **7/7 声纹命中**；
    把参考音频裁到 6 s 后 `num_steps=3` 的 **RTF = 0.655–0.962（重新满足 RTF<1）**，而上一轮 steps=4 的 1.04–1.53 是 8 s 长 prompt 撑上去的。
    产物套用线上同款后处理（−18 dBFS / 限幅 −1 dBFS / 15+40 ms 淡入淡出）后实测 **0% 削顶**。
    - 唯一剩余争议：**few-step flow-matching 的毛刺**（上一轮就是被它否掉的）—— 属**听感判断**，已出试听包 `~/Desktop/tts-原神克隆/`（steps 3 vs 6 同批角色 A/B）。
    - 细节：同文档 §11。
  - **现状（待用户听感决策）**：能接受 steps=3 的毛刺 → 直接切 ZipVoice + 原神中配参考音频（真·角色音色 + 口音问题天然消失 + RTF 达标）；
    不能接受 → 只剩租 GPU（路线 C 跑 GPT-SoVITS / D 自训 VITS 导 ONNX 回灌 sherpa）。
    旁注：路线 A 阴性并**不**杀死 `fanchen-C`（纯中文 / CER 4.80% / RTF 0.462 / 187 声线），它只是**不能贴角色标签**，选声线得靠人耳。
  - 证据：[`../research/TTS-VOICE-SOURCES.md`](../research/TTS-VOICE-SOURCES.md)（§4 清单 / §5 慢速证据 / §6 不能自训 / §10 路线 A / §11 路线 B）；
    VPS `/root/tts/gsv/getrefs.py`、`/root/tts/genshin-vits/{cer_gen,spk_match,spk_diag,zip_gen,pp}.py`、`/root/tts/gsv/refs/`、`/root/tts/gsv/{zs3,zs6,pp3,pp6}/`；
    旧入口 `/root/tts/gsv/{钟离_ZH,流萤}.zip`、`/root/tts/dlchars.sh`。
  - 验证：路线 B 以「`POST /tts` 端到端 RTF < 1 + 24 kHz/−18 dBFS 契约 + 人耳听感」判定。

## 书源管理（BookSourceManage）

- [x] **T-SRC-1 导入持久化回归**：核对「启停/删除/恢复内置」后的 `preferences` 落盘与列表 key 稳定性。
  - 状态（2026-10-07）：**已实现 + release 真机复验通过**——key = `bookSourceUrl#index#enabled`（`pages/BookSourceManage.ets:661`）。
    取证：先从本机 release 导出的备份 JSON 确认库内确有同 URL 两条（`bbiquge8` / `笔趣阁8` → `http://m.bbiquge8.net`，均 `enabled`），
    再在 release 包「设置 → 书源管理」滚动确认**两行分别渲染**（修复前 ForEach 同 key 会静默少一行）；列表头「书源（7/13 启用）」与备份 JSON 逐条对账一致。
  - 证据（2026-10-06 补充，已确认真实触发）：`:657` 原用 `source.bookSourceUrl + '#' + enabled` 作 ForEach key，
    用户库内 `bbiquge8` / `笔趣阁8` 指向同一 URL → 同 key 被静默去重，**列表少显示一行**，且启停/删除可能误伤另一条。
  - **修法（已实施 2026-10-06）**：key 改为 `bookSourceUrl + '#' + index + '#' + enabled` —— 保留 `enabled`
    （否则启停后 key 不变、ForEach 不重建该行、开关显示旧值，见 `596f16a`），补 `index` 以区分同 URL 的两条。
    搜索侧同族问题已修：`SearchResult.ets` 的 `StatusRow.id`（见 `docs/progress.md` §「源状态抽屉内容整改」）
    与搜索前 `SourceRepository.dedupeByUrl()`（见 §「选择来源抽屉整改」）。
  - 验证：导入两条同 URL 不同名的书源 → 列表显示两行、各自可启停/删除。**2026-10-07 release 真机复验通过**：同 URL 两条（`bbiquge8` / `笔趣阁8`）分别渲染，列表头计数与备份 JSON 逐条对账一致（[`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §9）（原先记「待补」是设备离线时快照，已更正）。
  - 残留语义（非缺陷）：一键「关闭/删除全部不可用」仍按 `bookSourceUrl` 聚合，同 URL 的两条会一起处理。
  - 证据：`pages/BookSourceManage.ets:65-70,175-198,343-386`、`model/SourceRepository.ets:39-47`
- [x] **T-SRC-2 检测并发/超时**：确认 `detect`（并发 4）无源级串扰，`busy` 态防重入。
  - 证据：`pages/BookSourceManage.ets:200-222`

## 数据管理（缓存 / 备份，M6）

- [x] **T-DATA-1（R4/R5）封面缓存读穿**：`BookCover.load` 先查 `ctx.cacheDir/cover_{hash}` 是否已存在（或加内存 PixelMap 缓存），避免重复下载。
  - 证据：`components/BookCover.ets:22-39`、`rust/legado-engine/src/runtime.rs:653-658`
- [x] **T-DATA-2（R5）清理缓存页实现**：统计并清理 `filesDir/chapters`、`filesDir/local`（可选）、`ctx.cacheDir/cover_*`；设置页用 `formatBytes` 展示真实占用。
  - 证据：`pages/Settings.ets:82-86`、`common/Format.ets:48-61`、`pages/Index.ets:62-64`
- [x] **T-DATA-3（R5）备份/恢复**：导出 JSON（书源 + 书架 + 进度，带 `schemaVersion`）并支持导入恢复。
  - 状态（2026-10-07 更正）：**已实现**——原记「M6 未开始」有误，页面 `entry/src/main/ets/pages/BackupManage.ets`（271 行）随 `f898a23`（2026-10-02）落地；
    **release 真机导出 → 清库 → 导入 → 重启复读已验**（详见 T-VER-6）。残留「覆盖」语义另立 T-DATA-7。
  - 证据：`plan.md:272`、`pages/Settings.ets:88-93`
- [x] **T-DATA-4 缓存上限策略**：落实 plan §7「已读永久保留、未读超 N 天清理 / LRU ~200MB」。
  - 状态（2026-10-07）：**已实现并真机验证通过**（设备 `33Z0224424136564`，debug 包）。
  - **口径修正（重要）**：plan 原文两项要求互相矛盾 —— 章节缓存按「读一章写一章 + 预取邻居」增长，
    若「已读永久保留」是绝对的，200MB 上限几乎永不触发（实测 ~9.6KB/章，1441 章的书全读完仅 ~14MB），磁盘无界增长。
    已按「**已读 = 软保护**」落地：未读先删；仍超配额才按最久未访问（`mtime`）删已读；未读另吃 30 天 TTL。
  - **实现**：新增 `model/CacheTrim.ets`（`protectBook` / `maybeTrimCaches` / `scheduleStartupTrim` / `trimCaches`）；
    `CacheRepository` 导出 `chapterDir`/`tocDir`（路径单一来源）；`ChapterCache` 写入后 `maybeTrimCaches` + 命中时节流刷新 `mtime`（真 LRU）；
    `EntryAbility.onCreate` 在 `initShelf` 成功后延迟 3s 首扫；`Reader.load` / `TtsController.start` 各调一次 `protectBook`。
    预算常量 8 个进 `common/Const.ets`（200MB / 16MB / 64MB / 0.8 / 30d / 16KB / 5min / 30min）。
  - **刻意不做**：不新增持久化索引（keep 列表与 `make check` 均无需改）；不动 `filesDir/local` 与 DB；不加设置页配额档位与手动整理入口（纯自动）。
  - **封面限制**：`cover_<DefaultHasher(url)>.img` 在 ArkTS 侧不可复现 → 无法识别在架书封面，只按最旧 `mtime` 驱逐（重下即恢复）。
  - 证据：`plan.md:312`（原要求）、`rust/legado-engine/src/runtime.rs:729-733`（封面命名不可复现）
  - 方案 / 算法 / 验证步骤（含常量压测法）：[`../research/CACHE-LIMIT-PLAN.md`](../research/CACHE-LIMIT-PLAN.md)
  - 验证：`make check` ✅（keep 扫描全绿）、`make hap` / `make hap-release` ✅。**真机压测（临时压小常量，逐条与沙箱 `ls -l` 对账，验完已全部还原）**：
    ① 默认常量 `trim scanned=2 freed=0 keptRead=1` → 不误删；
    ② 配额 4KB → `freed=1 files 3765 B`，删的正是**未读** `_1.json`，**已读** `_0.json` 留下（未读先删）；
    ③ 配额 2KB → `freed=2 files 9667 B` = 已读章 2856 + 连带删的 toc 6811（逐字节对上），两目录皆空（软保护降级 + toc 联动）；
    ④ 配额 2KB 但文件 30s 前刚写 → `freed=0`（新鲜窗口保护）；
    ⑤ 配额 2KB + 窗口 0 + 闸门 1，打开在读的书 → 热路径 `freed=0`（同一会话不打开书则 `freed=3 files 14657 B` 全清）→ `protectBook` 按书生效；
    ⑥ 配额 200MB + TTL 0 天 → `freed=1 files 3644 B` 只删未读，已读不吃 TTL；
    ⑦ 封面预算 200KB → `freed=32 files 972410 B`，剩 6 封 161511 B ≤ 滞回线 163840（停在水位内，非清零；书架随后自动重下 6→8）。
  - 已知代价（设计取舍）：封面文件名不可与 `coverUrl` 互推 → 只按最旧 `mtime` 驱逐，可能重下在架封面（无数据损失）；用目录跳到第 500 章会把 1–499 章算「已读」而受保护（多留不多删）。
- [x] **T-DATA-5 目录缓存未纳入统计**：`filesDir/tocs/<bookId>.json`（`TocCache` 写入）不在 `CacheStats` 任何分类内，「清理缓存」页显示的数字偏小。
  - **处置（2026-10-07）**：`CacheStats` 增 `toc` 分类；`isChapterFile` **改名**为 `isJsonFile`（chapters 与 tocs 共用，未新增重复函数）；`getCacheStats()` 计入 `toc` 并加入合计；`CacheManage` 增「目录缓存」行 + 文案补「目录」（`CacheRepository.ets`、`CacheManage.ets`）。真机数字比对见 §10 D15（设备离线，待补）。
  - 证据：`model/TocCache.ets:37-45`、`model/CacheRepository.ets:20-56`
  - 方案：`CacheStats` 增 `toc` 分类 + `CacheManage` 增一行 → [`../archive/SHELF-EDIT-PLAN.md`](../archive/SHELF-EDIT-PLAN.md) §8 S4
- [x] **T-DATA-6 清理缓存漏删目录缓存**：`clearCache()` 只删 `cover_*` / `chapters` / `tts`，`filesDir/tocs` 永不被清 → 真实磁盘泄漏（无任何 UI 入口可清）。
  - **处置（2026-10-07）**：`clearCache()` 增 `removeDir(tocDir(ctx))`（`CacheRepository.ets`）。真机见 §10 D15（设备离线，待补）。
  - 证据：`model/CacheRepository.ets:128-132`、`model/TocCache.ets:37-45`
  - 方案：`clearCache()` 增 `removeDir(tocDir(ctx))` → 同上 §8 S4
- [x] **T-DATA-7 导入不是「全量覆盖」**：页面文案与确认弹窗都写「将从备份文件覆盖当前书源、书架与阅读进度」，但 `doImport` 只做 `saveSources` + `upsertBook` / `saveProgress`，**不删除备份中不存在的行**。
  - 证据（2026-10-07 release 真机）：导入前书架 0 本 / 进度 4 条（删书后残留的孤儿行），导入「3 本 / 7 条」的备份后 = 3 本 / **7 条**（4 + 3）——孤儿行未清，与文案不符。
  - **处置（2026-10-07，用户选「真覆盖」口径）**：`ShelfRepository` 新增 `replaceShelf(books, progress)`——`DELETE FROM books` / `DELETE FROM progress` 后再复用既有 `upsertBook` / `saveProgress` 写入；`doImport` 改为 `saveSources` + `replaceShelf`，**全部格式校验仍在清表之前**。
    其中 **`lastWriteAt.clear()` 是必需的**：`saveProgress` 的单调守卫是**会话级**的，不清会让备份里 `updatedAt` 更旧的进度被静默丢弃。
    书源无需改动（`saveSources` 走 `putString` 整体替换，本来就是覆盖语义）；文案保留「覆盖」并补明「备份中不存在的书源、书籍与进度将被删除」，恢复后 toast 带实际计数。
  - **真机证据（2026-10-07，debug 包，`make run`，设备 `33Z0224424136564`）**：13 源 / 3 本 / 7 条 → 导入「1 书 1 进度」fixture → **1 本 / 1 条**（修复前会保持 3 / 7）；`aa force-stop` 重启后仍 1 本 / 1 条（确认落盘）；同会话内先导入 `updatedAt = now+1 天`（书架 6章/300章）再导入旧时间戳 fixture → 书架回到 **1章/50章**（证明 `lastWriteAt.clear()` 生效，否则该写会被拒绝）；0 条 JS 错误。验证后已导回全量备份，设备状态复原，fixture 已删。
  - **更正原「顺带发现」**：孤儿进度行**不能**做全局 GC。`BookDetail` 的「立即阅读」不要求已上架（`pages/BookDetail.ets:233` 常驻可点），`Reader.persistProgress()` 会为**未上架**的书写进度 → 「`progress` 有行而 `books` 无行」有合法来源；`DELETE FROM progress WHERE book_id NOT IN books` 会删掉用户真实阅读位置。改真覆盖后 DB 与备份已自洽，无需 GC。
  - 证据：`model/ShelfRepository.ets`（`replaceShelf`）、`pages/BackupManage.ets`（`doImport` / `confirmImport` 文案）

---

## 验证 / 构建（横切）

- [x] **T-VER-1 clean 构建复验**：执行一次非增量的 `hvigorw assembleHap ... --no-daemon`，确认冷构建可复现。
- [x] **T-VER-2 Rust 回归**：若改动引擎，`cd rust/legado-engine && cargo test`（当前记录 54 passed）并重出 `.so`。
- [x] **T-VER-3 真机闭环**：每个修复按 `docs/development.md` 走「编译 → 安装 → `aa force-stop` → 重启 → hilog `SourceReaderTts`/`SourceReaderPoC` 观察」（流程清单见 skill `harmony-device-run`）。
- [x] **T-VER-4 混淆确认**：已机械化为 `make check`（`scripts/check-keep-props.sh` 扫描 `types.ets` + 所有含 `JSON.parse/stringify` 的 `.ets` 的 interface 字段 ↔ keep 列表）。
  - 2026-10-07 补齐漏掉的 9 个：`Book.addedAt/bookId/inShelf`、`ReadProgress.chapterIndex/chapterTitle/charOffset/paragraphIndex/percent/updatedAt`——这些字段会经备份 JSON 往返，漏 keep 会让 release 写出的备份键名与格式不符（跨版本读不回）。
- [x] **T-VER-6 release 包真机 smoke（首次）**：`make run-release` 装上 release 包，跑一遍搜索 / 阅读 / 听书 / **备份导出 → 清库 → 导入**（混淆类问题只在这里现形）。
  - 静态证据（2026-10-07 早先）：release HAP 的 `modules.abc` 里 `addedAt` **完全不出现**（被改名）、`bookSourceUrl` 保留 → `-enable-property-obfuscation` 确实在这些模型字段上生效，非理论风险。
  - 静态复测（`e660a3b` 补齐 9 个 keep 字段之后）：`addedAt` / `paragraphIndex` / `schemaVersion` **已保留**（= keep 生效），`isActiveFor`（方法，未进 keep）仍被改名。
  - **动态结果（2026-10-07，设备 `33Z0224424136564`，release HAP 17:58 构建、混淆开启）**：见文末「release 冒烟结果（T-VER-6）」。
- [x] **T-VER-5 文档补齐**：补 `docs/bug.md`（progress.md 引用但缺失）或在 progress.md 去除引用。

---

## 回归验收状态（S10 回归 / 发布，2026-09-27）

> 逐项核对源码 + 构建复核。图例：`✅ 已修复/已核验` · `🟡 已实现待真机复验` · `➖ 缓解` · `⏭ 顺延/范围外` · `🚫 受阻（设备离线）`。
> （`🚫` 目前无条目，保留供以后使用；`🟡` 见 T-READ-3。）
> 修复均已通过 **clean debug 构建** 与 **release 构建**（`BUILD SUCCESSFUL`）。

| 任务 | 状态 | 处置 / 证据 |
|---|---|---|
| T-CROSS-1 阅读↔听书串扰 | ✅ | `Reader.onTtsProgress` / `isSpeaking` 增加 `tts.isActiveFor(bookId)` 守卫（`Reader.ets:65-77`、`:450-457`） |
| T-CROSS-2 后台任务泄漏 | ✅ | `pause()` 与自然播完末章分支调用 `stopBackground()`，恢复播放再 `startBackground()`（`TtsController.ets:855`、`:825-838`） |
| T-CROSS-3 进度写竞争 | ✅ | 2026-10-07 落地「播放中音频独占」仲裁：新增 `model/ProgressOwner.ets`，`saveProgress(p, writer)` 归属检查**先于**时间戳守卫，`TtsController.setPlaying` 为 `playing` 唯一写入口（claim / release），`replaceShelf` 以 `RESTORE` 绕过、`removeBooks` 连带 `forgetProgressOwner`；顺带修 `Reader.onTtsProgress` 跨章缺段落锚点。真机四场景 + 修复前对照见 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §11（旧 `lastWriteAt` 守卫保留，作为第二道防线） |
| T-SHELF-1 删除书籍清缓存 | ✅ | 2026-10-07 落地：`removeBooks` + `ChapterCache.deleteBookChapters` / `TocCache.deleteBookToc` / `LocalBook.deleteLocalBookData` + 新增 `model/BookRemoval.ets` 编排；`Index` 二次确认弹窗 + `deleting` 防重入。**真机已验证（D6–D9/D11/D13/D17）**：书架 4→3 且重启仍 3、DB 4/7→3/6 行、`chapters/` 13→6、`tocs/` 4→3、TTS 播放中删除即停播 + FAB 消失；D10/D12 经用户同意跳过 |
| T-SHELF-4 长按手势被编译成空手势 | ✅ | 2026-10-07 真机发现：helper 返回 gesture + `.gesture()` → 转译为 `Gesture.create; Gesture.pop();` 空手势，真机永不触发 → 改内联 `.parallelGesture(LongPressGesture(...))` + helper 只留业务（`onLongPress`）。计划 §1.6 #42/#43、K16 |
| T-SHELF-2 数据层懒初始化 | ✅ | `EntryAbility.onCreate` 预调 `initShelf`，搜索直达阅读也能落进度（`EntryAbility.ets:14-19`） |
| T-SHELF-3 进度三态 | ✅ | 2026-10-07 边界加固（`Format.deriveTotalChapters`）：`percent` ≤0 / NaN / Infinity / >1 / 极小值 → 回 0，降级「第N章」；正常区间 `len ≤ 20000` 全枚举 0 误差。**主机复算 + debug 构建 + 真机三态 + 真机脏值对照均已通过**（插桩已还原、DB 已复原）；当时顺带登记的口径分歧已由 T-SHELF-6 修完（[`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §12 / §13） |
| T-SHELF-6 新章永不出现 | ✅ | 2026-10-07 真根因：TOC 缓存只比 `tocUrl`（`fetchedAt` 写了没人读）→ 事实上永久。修法：`TOC_REFRESH_AFTER_MS = 6h` + 打开书时**后台重爬**（失败静默回退缓存；章数变化则采新目录并用新分母重写 `percent` 让书架自愈）；顺带把 `buildTocItems` 改成 `setItems()`（LazyForEach 换实例不刷新）。真机 8 项证据（TTL=0 触发 / 插桩伪造新章 → 目录 29 章 + 书架 `28章/29章` / TTL=2000ms / 6h 不重爬 / 排序不回归 / 0 异常 / 插桩已还原）见 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §13 |
| T-SEARCH-1 concurrency 透传 | ✅ | `BookEngineNapi.search` 现传 `concurrency`（`BookEngineNapi.ets:23-26`） |
| T-SEARCH-2 搜索代次 guard | ✅ | S6 实现并真机验证；本轮静态复核无残影 |
| T-READ-1 统一正文清洗 | ✅ | **2026-10-08 落地**：`Reader.sanitize` 删除，阅读页与听书共用 `BookContent.sanitizeText`（改动前 `diff` 复核两副本逐字节一致 → 纯重构）；真机验证 `start para=7` = 阅读页 `paragraphIndex`、`play para=8/9/10` 连续推进 |
| T-READ-2 缓存内存上限 + 死码 | ✅ | `ChapterCache` 加 24 条 LRU（`touchMemory`）；删除死码 `hasCachedChapter`；`BookCover` 加 64 条 PixelMap LRU |
| T-READ-3 预取去重 | ✅ | 2026-10-08 **已实现**：`fetchContent` 加单飞表 `inflight: Map<bookId#index, Promise<string>>`（引擎请求 + 写盘下沉到 `fetchRemote`），所有取正文入口都走它 ⇒ 同一章只请求一次、只写一次盘；顺带删死代码 `prefetch`。**2026-10-11 真机正/反对照复验通过**：修复后 key `#11` = miss×2 + join×1 + engine×1；修复前对照（旁路 `inflight.set`）key `#39`/`#45` = miss×2 + engine×2、join 0 次 → [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §15 |
| T-TTS-1 引擎释放 | ✅ | `stop()` 增 `engine.shutdown()` 并置空、复位日志位（`TtsController.ets:226-243`） |
| T-TTS-2 定时器自然结束 | ✅ | 末章播完 `clearTimer()`，避免 1s 定时器空转（`TtsController.ets:825-830`） |
| T-TTS-3 错误态恢复 | ✅ | `onError` 清 in-flight、停 flush/progress 定时器、停后台；新增 `queueExhausted()`，播完后 `resume()` 可从章首重播 |
| T-SRC-1 导入持久化回归 | ✅ | 列表 key 改为 `bookSourceUrl#enabled`（去 index），启停/一键清理即时刷新；**2026-10-06 补**：同 URL 重复源会撞 key → 再改为 `bookSourceUrl#index#enabled`（`BookSourceManage.ets:657`）；**2026-10-07 release 真机复验通过**：`bbiquge8` / `笔趣阁8`（同 `m.bbiquge8.net`）两行分别渲染 |
| T-SRC-2 检测并发/超时 | ✅ | `runDetect` 加 `busy` 重入守卫并复位 `statusVisible`（`BookSourceManage.ets:292-308`）；引擎每源独立 Client（复核） |
| T-DATA-1 封面读穿 | ✅ | S3 已实现：`pathCache` + `accessSync` 校验，命中不重下（`BookCover.ets:58-62`） |
| T-DATA-2 清理缓存页 | ✅ | S9 已实现并真机核对（`CacheManage.ets`、`CacheRepository.ets`）；本轮增 `cover_*.img` 后缀精确匹配 |
| T-DATA-3 备份/恢复 | ✅ | **2026-10-07 首次 release 真机往返**：导出 31.83KB（键名全未混淆）→ 清库 → 导入 → 书源 13 / 书架 3 本 / 进度 7 条，重启仍对（见下方「release 冒烟结果」）；原记「M6 未开始」有误（`f898a23`） |
| T-DATA-4 缓存上限策略 | ✅ | 2026-10-07 落地并真机压测通过：`model/CacheTrim.ets`（配额 + TTL + 新鲜窗口 + 会话保护集，口径改为「已读=软保护」）+ `Const.ets` 8 常量 + `EntryAbility` 启动首扫 + `ChapterCache` mtime 刷新；六项分支逐字节与沙箱对账，方案与证据见 [`../research/CACHE-LIMIT-PLAN.md`](../research/CACHE-LIMIT-PLAN.md) |
| T-DATA-5 目录缓存未统计 | ✅ | 2026-10-07：`CacheStats.toc` + `CacheManage`「目录缓存」行（`isChapterFile`→`isJsonFile` 改名） |
| T-DATA-6 清理缓存漏 `tocs` | ✅ | 2026-10-07：`clearCache()` 增 `removeDir(filesDir/tocs)` |
| T-VER-1 clean 构建 | ✅ | `hvigorw clean` + `assembleHap debug --no-daemon` → `BUILD SUCCESSFUL`（全量任务） |
| T-VER-2 Rust 回归 | ✅ | `cargo test` → `54 passed; 0 failed`（无 Rust 改动，未重出 `.so`） |
| T-VER-3 真机闭环 | ✅ | 设备已连接（`33Z0224424136564`）：release + debug 安装/启动、书架→阅读→目录→听书全链路冒烟通过，无 `JSCRASH`/`CPPCRASH`。详见 `RELEASE-NOTES.md` §5；跨书串扰因设备仅一本本地书可读未覆盖 |
| T-VER-4 混淆确认 | ✅ | 本轮未新增 JSON 字段，`obfuscation-rules.txt` 无需变更 |
| T-VER-6 release 冒烟 | ✅ | 2026-10-07 首次：装包/书架/搜索/详情/阅读/听书/备份导出→清库→导入/重启复读/书源列表全通过；0 JS 错误 + 0 崩溃。详见下方同名节与 `RELEASE-NOTES.md` §9 |
| T-VER-5 文档补齐 | ✅ | 移除 `docs/progress.md` 对不存在的 `docs/bug.md` 的引用 |

---

## release 冒烟结果（T-VER-6，2026-10-07）

包：`entry/build/default/outputs/default/entry-default-signed.hap`（17:58 构建，`buildMode=release` + 属性混淆；`modules.abc` 内 `addedAt`/`paragraphIndex`/`schemaVersion` 保留、`isActiveFor` 被改名）。
设备：`33Z0224424136564`。全程用 `uitest dumpLayout` + `hilog -x` 取证（无 GUI）。

| 环节 | 边界类型 | 结果 |
|---|---|---|
| 装包 / 启动 | — | ✅ `hdc install -r` + `aa force-stop` → `aa start`；无 JSCRASH / CPPCRASH |
| 书架列表 | relationalStore 读 | ✅ 3 本 + 进度文字 `153章/1441章`、`27章/28章` 正确 |
| 搜索 | NAPI JSON（`BookSearchItem`） | ✅ 「剑来」→ 57 条结果、可见 5 条含 书名/作者·最新章节/来源数；状态栏「源 2/7 成功」 |
| 选择来源抽屉 | 抽屉 + 列表 key | ✅ 「选择来源 · 2」两行（`bbiquge8` / `m.bbiquge8.net`） |
| 详情页 | NAPI JSON（`bookInfo`） | ✅ 书名/作者/来源(只读)/目录「最新：第83章 今日无事」/简介 |
| 加入书架 | relationalStore 写 | ✅ 备份页计数 2 本 → 3 本 |
| 阅读页 | NAPI JSON（`content`）+ 分页 | ✅ 章节名 + 正文 + `(第1/3页)` |
| 听书 | TTS → PCM → `AudioRenderer` → AVSession | ✅ 听书页 `00:12 / 03:39` 持续推进、`远端音色 · 流萤`；`hidumper AVSessionService` → `is the topsession: true`；系统日志可见本应用 `AudioLogUtils` 音频帧 |
| 长按进编辑态 | 手势 + DB 删 | ✅ `已选择 1 本书` → 全选 3 → 确认弹窗 → 删除 → 书架空，且 AVSession top session 让出（删正在播的书即停 TTS） |
| 备份导出 | JSON.stringify（**keep 面**） | ✅ `sourcereader_backup_2026-10-07.json` 31.83 KB 落到 `Docs/Download/`；**键名全部未混淆**：sources 23 / books 13 / progress 7 字段 + `schemaVersion`/`exportedAt` 全对 |
| 清库 → 导入 | JSON.parse（**keep 面**） | ✅ 3 本 → 0 本；导入该文件后回到 书源 13 / 书架 **3 本** / 进度 **7 条**，书架显示值与备份前一致 |
| 重启复读 | DB 读写跨进程 | ✅ force-stop + 重启后仍 3 本、进度文字不变（混淆进程写 → 新进程读） |
| 书源管理 | preferences JSON | ✅ 「书源（7/13 启用）」+ 同 URL 两条分别渲染（T-SRC-1 复验通过） |
| 异常面 | — | ✅ 全量 `hilog -x` 扫描：0 条 JS/ArkTS 错误、0 崩溃；应用级 error 仅 `AceStateMgmt: No views to update` / `PARAM_WATCHER: Read result failed`（框架噪音） |

**未覆盖 / 新发现**
1. 备份「全量覆盖」语义与文案不符 → 新立 **T-DATA-7**（已于同日修复并真机复验，见该条目）。
2. release 包下应用自己的 `hilog`（domain 0x0000）被系统过滤，`hilog -T SourceReaderTts` 恒为空 → release 冒烟只能靠系统侧日志 + `dumpLayout`（已记入 [`../PITFALLS.md`](../PITFALLS.md)）。
3. 启动即出现的 `ImageSource` / `62980118` 噪音在 release 同样复现 → **2026-10-08 已定位并修复**（T-SHELF-5）：是引擎把 HTML 正文当封面缓存 + 命中早退，非 release 特有；修后 debug 真机 0 行，release 未复跑。
4. 规则调试器页本轮未跑（不在冒烟范围；该页确实已存在，见 `pages/RuleDebugger.ets`）。