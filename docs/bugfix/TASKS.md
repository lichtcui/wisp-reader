> **2026-10-19 第三十六次同步**：㊱ **主机侧读路径与备份 I/O 优化（设备 `33Z0224424136564` 真机部分已验）** ——
> `ShelfRepository.getShelfBooks()` 用一条 `books LEFT JOIN progress` 返回书架快照；`CacheTrim` 改读
> `getChapterPositions()`，只取 `book_id + chapter_index`。`SourceStore.sourcesForUrls()` 只按书架 URL
> 去空去重后 400 个一组读取完整源，按输入顺序返回；同 URL 优先最早启用行、否则最早可解析行，坏 JSON
> 不提前占位。完整读统一用 `enabled` / `confidence` 索引列覆盖 JSON 旧副本。`BackupManage` 导入导出
> 改为异步文件 API + 1 MiB 分块，流式 UTF-8 解码、`encodeIntoUint8Array()` 编码并处理短写与代理对边界。
> 静态守卫补上 URL 批读、400 分块、`enabled` 覆盖和备份同步 I/O 禁用检查。
> **主机侧收尾通过**：`make test` 73 passed、`make test-pregen` 114 条、`make test-detect` 135 条、
> `scripts/shelf-updater-sim.py` ALL PASS、`make native-fresh` / `make check` / `make docs-toc` /
> `make hap` 全绿，`git diff --check` 无空白错误。
> **真机补充**：书架 4 本及进度 / 章数正常；「更新」完整走到 `没有发现新章节，1 本未检查`；启动日志
> `SourceReaderCache: trim scanned=5 freed=0 files 0 B keptRead=4`；备份页显示 `13 个 / 4 本 / 9 条`，
> 导出 `sourcereader_backup_2026-10-19.json`（33.26 KB）成功，导入该同一份备份后计数不变，
> force-stop 重启后仍为 `13 / 4 / 9`、书架 4 本正常；相关日志无应用 JS 异常或 RDB 失败。
> 未验：并发封面单飞、换源抽屉固定行的实际排版 / 点击穿透、批量删除耗时、检测结果批量回写耗时。
>
> **2026-10-19 第三十五次同步**：㉟ **主机侧批量写优化（设备未连接，真机待补）** ——
> `ShelfRepository.removeBooks()` / `replaceShelf()` 改为单事务；`SourceStore` 新增
> `setEnabledMany()` / `removeMany()` / `patchDetects()`（400 id 分块，一批一次 commit）；
> 书源页「关闭 / 删除不可用源」与检测作业的批次回写不再逐行 await。
> 另将 `sourcesForEngine()` 的稳定 id 批读按 400 个一组分块，避免大批次 `IN (...)` 触发 SQLite
> 绑定变量上限；结果仍按去重后的输入 id 顺序返回，缺失 / 坏 JSON 行保持跳过语义。
> **主机侧收尾通过**：`make test` 73 passed、`make test-pregen` 114 条、`make test-detect` 135 条、
> `scripts/shelf-updater-sim.py` ALL PASS、`make native-fresh` / `make check` / `make docs-toc` /
> `make hap` 全绿，`git diff --check` 无空白错误；真机事务行为与耗时仍待设备连接后补验。
>
> **2026-10-17 第三十四次同步**：㉞ **T-CROSS-4 真机 10 分钟验收通过（P0 关闭）** ——
> 设备 `33Z0224424136564`、debug 包、PID `62344`，《剑来》第十三章系统 TTS 实时路线。亮屏基线约 1 分 40 秒正常；
> `17:22:19` 息屏，`17:22:21` 记录 `Ability onBackground` + `TTSStateObserver--OnPageHide`。其后 `play para=` 持续推进：
> `17:22:27 para=83` → `17:23:46 para=93` → `17:27:45 para=120`；`17:27:55` 自动跨到下一章（`render rate 16000 -> 24000`），
> `17:28:03 para=1` → `17:32:45 para=13`。全程 `/proc/62344/cgroup` 为 `cpu:/key-background` + `freezer:/`，
> **无 `freezer:/Frozen`、无 `HandleOnContinuousTaskStop`、无 `standby`**；`continuous task probe` 在 `bg+25s / +45s / +60s`
> 均为 `id=573 modes=audioPlayback suspend=false`。⇒ 顺序修复有效，息屏冻结不再复现。
> **通知侧结论更正**：`bm dump -n com.lichtcui.sourcereader` 仍显示 `allowEnableNotification: false`，但本次 10 分钟播放**未受影响**
> ⇒「通知总开关为 false 是冻结必要条件」的主嫌不成立；通知相关问题若还要追，应另立条目，不能再作为 T-CROSS-4 的阻塞。
> **锁屏媒体卡/媒体键**：OCR 截图（`/tmp/lock1.png`）识别出 `第一卷 笼中雀 第十四章...` 与 `剑来 · 烽火戏诸侯`；
> `hidumper -s AVSessionService -a -show_session_info` 显示本 App `is active=true`、`is the topsession=true`（`pid 62344`，
> tag `source-reader-listen`）；`-show_metadata` 同样回 `title=第一卷 笼中雀 第十四章 五月初五` / `artist=剑来 · 烽火戏诸侯` / `duration=849400`。
> 媒体键：`keyEvent 10` → 日志 `pause`，再按 → `resume` 且 `play para` 继续；`keyEvent 12/13` 分别触发媒体 next/prev
> （两次均出现新的 `begin para=0 route=cache`，key13 后 AVSession metadata 回到第十四章）⇒ 路由可用。
> 本轮**未改业务代码**，只更新验收记录与文档目录。
>
> **2026-10-16 第三十三次同步**：㉝ **T-TTS-7 阶段二「听感验收」通过（bug① 无白噪/无爆音 主观确认）+ 登记 1 个打磨项 + 记 3 个新坑** ——
> **听感（设备 `33Z0224424136564` · 本地书《短章测试》`bookId=c9af6cb1` · 第三章缓存 key `0e7542fe7b66c631`，服务端 `audioMs=11700` / `561644 B`）**：在**缓存章内**用段落滑杆 **1.5x ↔ 1.0x 来回拖 + 切变速**共 8 次落点，用户判定 **无白噪、无爆音 ✓**；**「听到的正文 == 屏上章」✓**（bug② 主观闭环）。日志逐次 `preg play para=1 base=1733.333333 rate=1.50` / `para=2 base=5200`（交替）+ `preg playing key=0e7542fe7b66c631`，章尾 `preg chapter end` → `preg cache delete code=204`（「听完即删」如预期）。⇒ bug ①/② **主观 + 客观均已闭环**（客观证据见第三十 / 第三十二次同步）。
> **打磨项（P2，本轮只登记不修）**：**拖动体感「声音重复 + 顿挫」** —— 滑杆是 `step: 1` 的**段落滑杆**（`pages/Listening.ets::progressBlock`，`value = paragraphIndex + 1`）⇒ 落点即段落起点，来回拖必然**重听整段**（设计粒度，非 bug）；且重启用 `pause() → flush() → start()`（`TtsController::startPregRenderer`），渲染器里排队的旧字节被**整段丢掉** ⇒ 中间有一小段静音 = 顿挫。要更丝滑：① 滑杆改连续（段内按 ms / 字节精确 seek，需全链路重测）；② 压缩 flush 后的静默窗口。
> **新坑 ①（取音频的接口，别再瞎试）**：`GET /audio/<key>` 才是取音频（`server/app.py:728`）；`/cache/<key>` **只有 `DELETE`**（`server/app.py:758`）⇒ 拿 GET 探存在性会得 **405**（不是 404），别据此判定「缓存文件没了」。客户端契约注释在 `model/TtsPregen.ets` 顶部。
> **新坑 ②（排队 + 单章时长 ⇒ 别提前判失败）**：job 从提交到**开跑**实测排 **~14 min**（`6ad231608aee8e`：14:00 UTC 提交、14:14 才落 `cache/jobs/*.json`），单章合成 **3.7 min**（`synthMs=221750`、`RTF=16.979`）⇒ **提交后 5 min 内 `GET /audio/<key>` 回 404 是正常的**（本轮据此误判过一次）。判「算好了」只看 `GET /job/status?jobId=`：`state=ready` + `audioMs`。
> **新坑 ③（被「听完即删」的章能再算回来）**：客户端 `DELETE /cache/<key>` → 204 后，服务端 **meta 仍留着**（`cache/meta/<key>.json` 里 `bytes` / `audioMs` 都在），只是音频 404 ⇒ 客户端于是 `preg key kept … why=notfound` → `preg fallback=realtime`（退实时，正确）；此时**重新提交同一章会真的重新合成**（实测 meta `createdAt` 被刷新，不是复用旧文件）⇒ 被消费掉的章可以「退到前一章再提交」补回来。
> **2026-10-15 第三十二次同步**：㉜ **T-TTS-7 阶段二 bug ② 修复真机验证通过（键↔章逐条对上）+ 记三个新坑** ——
> **验证（决定性证据）**：22:52 从第 1 章提交 `[第2章, 第3章]`（job `6ad0e8ad36e7fb`），服务端回显
> `[{key:94d8cae1bcb725fb, title:'第二章 香蕉测试'}, {key:0e7542fe7b66c631, title:'第三章 樱桃测试'}]`；设备
> `files/pregkeys/c9af6cb1_1.json` = `{"url":"local://c9af6cb1/1","pregKey":"94d8cae1bcb725fb"}`（index 1 = 第 2 章 ✓）、
> `c9af6cb1_2.json` = `…0e7542fe7b66c631`（第 3 章 ✓）；worker 日志里 `94d8cae1` 正在合成的文本正是
> `['第二章 香蕉测试。','香蕉的第一句，',…]` ⇒ **键 ↔ 章节文本一一对应，「缓存章读出别章正文」已消失**。
> 旁证：`preg submit jobId=… items=2 stored=2 evicted=0`；`preg key kept key=94d8cae1… why=notfound pending=1`
> （**pending=1** 也保住键）；`preg fallback=realtime why=notfound para=0`（第 1 章无预生成，退实时正确）。
> **新坑 ①（会挡住任何「重提交」测试）**：runner 认为上一个 job 仍在飞时，「开始」是**禁用态**且 UI 显示**陈旧**进度行
> （本轮显示「排队中 0/2」）——此时点击**不会**发出提交。本轮就踩了：第 ② 步 `aa force-stop` 因 hdc 瞬断失败 ⇒ App 没重启 ⇒
> 点击无效，**服务端 `jobs/` 里根本没有新 jobId**（据此反推确认）。⇒ 重提交前必须 `aa force-stop` + 重启，且**以服务端 `jobs/` 出现新 jobId 为准**，别信 UI 那行字。
> **新坑 ②（性能下限）**：57 字/章 ⇒ 音频 12–13 s，但**单章端到端 ~3.5–4 min**（真机：提交 14:52:29 → ch2 音频 14:56:21 → ch3 音频 15:00:06）
> ⇒ 「缩短正文」杠杆有**固定开销下限 ~3.5 min/item**；2 章小书实测 7.5 min（原书 852 字约 16 min）。后续按 **item 数**估时长，别按字数。
> **新坑 ③（离线切引擎）**：`tts_engine` 枚举是 **`SYSTEM=0` / `REMOTE=2`**（**不是 1**）；偏好文件
> `haps/entry/preferences/source_reader_settings` 是明文 XML（`<double key="tts_engine" value="0.000000"/>`），可 `file recv` → 改 → `file send` 离线切换，
> 但**必须在 App 停止时改**（运行中会被内存值回写）。另确认 `tts_pregen_wifi_only = false` ⇒ Wi-Fi 门禁一直是关的，此前预生成被拦与门禁无关。
> **验证 ②（强制乱序，已通过）**：删掉 ch2 的键（服务端只剩 ch3 的 `0e7542fe`）+ 清空设备 sidecar 后重提交 ⇒ 服务端 `jobs/6ad1fe9df173d2` 回的**响应顺序确实被打乱**：
> `[{ready 第三章 樱桃测试 0e7542fe…}, {queued 第二章 香蕉测试 94d8cae1…}]`（ready 的排前面）；而设备 sidecar 仍为
> `c9af6cb1_1.json → 94d8cae1`（第 2 章 ✓）、`c9af6cb1_2.json → 0e7542fe`（第 3 章 ✓），日志出现
> **`preg keys out-of-order n=2（按标题对齐，勿改回按下标）`** ⇒ 按 title 配对生效（旧代码此刻必然把第 2 章记成第 3 章的键）。
> 同期：`preg submit jobId=6ad1fe9df173d2 items=2 stored=2 evicted=0`、`preg key kept key=94d8cae1… why=notfound pending=1`、`preg fallback=realtime why=notfound para=0`。
> **验证 ③（缓存章端到端，已通过）**：同一会话里第三章走缓存播出：
> `preg audio ready key=0e7542fe7b66c631 bytes=561644`（**与服务端文件字节数一致**）→ `preg rate=1.50` → `preg play para=0 base=0 rate=1.50` →
> `preg playing key=0e7542fe7b66c631` → `preg chapter end key=0e7542fe…` → `preg cache delete key=0e7542fe… code=204`（听完即删）。
> 屏上章 = 第三章 樱桃测试、所用键 = `0e7542fe` = `c9af6cb1_2.json` 里那条 = 服务端由**樱桃**文本合成的那条
> ⇒ **听到的正文 == 屏上高亮的章**，页面标签为「预生成缓存 · 24 kHz」。
> **更正一处误记**：**缓存路线与引擎无关**（`tts_engine=0` 系统 TTS 下照样命中缓存）⇒ 不需要先切远端引擎；`tts_engine` 枚举（REMOTE=**2**）只影响实时路线。
> **未完成**：仅剩**听感**确认（缓存章内拖动进度条是否还有白噪）——只有耳朵能拍板；日志侧已证 `preg play … base=<ms>` 正常推进。
> **验证 ④（乱序那章走缓存播出，18:45，byte-exact）**：第 2 章（= 乱序提交里配到 `94d8cae1` 的那章）播放：
> `preg audio ready key=94d8cae1bcb725fb bytes=626924`（= 服务端该键文件字节数，**逐字节一致**）→ `preg rate=1.50` → `preg play para=0 base=0 rate=1.50` →
> `preg playing key=94d8cae1…` → `preg chapter end key=94d8cae1…` → `preg cache delete key=94d8cae1… code=204`；页面为「第二章 香蕉测试」+「预生成缓存 · 24 kHz」
> ⇒ 同一会话里 **ch2 / ch3 两章都走缓存播出、各自命中正确的键** ⇒ bug ② 端到端闭环。
> **测试侧注意**：`uitest uiInput drag` 在听书页段落进度条（`[94,1667][1166,1802]`）上**没生效**（试过一次，未产生新的 `preg play`）⇒ 拖动 seek 需**手指**拖（或从滑块处起拖）；且缓存章**听完即删**（204）⇒ 每次听感验收都要重新合成（单章 ~3.5 min，可用「重试」按钮只补那一章）。
> **听感验收的物料已备好（续验；设备断开后仍有效）**：为让听感验收有缓存章可听，从第 1 章重提交 job `6ad20093323d88` ⇒ 两章均已算完且**受保护**：
> `94d8cae1bcb725fb.wav` 626924 B（第二章 香蕉）、`0e7542fe7b66c631.wav` 561644 B（第三章 樱桃）；`/cache/stats` = `files 6 / protected 4 / played 2 / queue{done 7, fail 0}`。
> 单章实测：`chars=57 audio=11.7s synth=195.4s RTF=16.70`（≈3.3 min/章）⇒ 小章由**固定开销主导**，「缩短正文」的收益有下限。
> **下次接上设备后的 1 分钟验收流程**：`aa force-stop`（清掉本章的 `cacheFailed` 标记）→ 开书 → 用底栏章节滑杆到**第 2 章**（或第 3 章）→ 点「听书」⇒ 页面应显示「预生成缓存 · 24 kHz」→ **用手指**拖段落进度条（y≈1735）⇒ 听有无刺耳白噪，并确认念的是香蕉/樱桃那三句。缓存章**听完即删** ⇒ 尽量别让它自然播完（拖不影响缓存保留，但不要跑到 `chapter end`）。
> **设备状态**：用户手动断开手机（USB）⇒ 本轮真机验收到此；**代码与文档均已落定**，只剩上述人工听感确认。
> **验后加固（同一 bug 类的根治；`make test-pregen` 104→114 条、`make hap` 通过）**：提交响应只回 `{key,state,title}`（服务端 `create_job` 就回这三个），按标题配对仍有「同名章 / 无标题章」猜错的余地。
> ① `matchPregKeys` 改成：只有标题**在提交侧与返回侧都恰好出现一次**时才配对，否则留空（该章退实时）+ `preg keys unmapped n=…`；**删掉**原来的「无标题 ⇒ 按下标对齐」分支（那正是 bug ② 的成因）与「同名按响应顺序各取一次」（同样是猜）。
> ② 新增 `healPregKeys`：`/job/status` 回带 `bookId` + `chapterIndex`（服务端存的就是提交时的 meta，**精确标识**）⇒ 每次轮询把 `state=ready` 的键**按章号**写回旁路文件（日志 `preg key healed n=…`）。同名章由此也能配上，历史上配错的键也会自愈；`collected` 为空（重启/换书）时不纠不猜。
> **路由取证**（toybox 无 `ip`，用 `/proc/net/route`）：仅 `wlan0`(192.168.10.110) 与 `ancowlan0` 有 IPv4 路由、**主表里无 `rmnet*`**（默认路由不在主表，`getDefaultNetSync().bearer` 判据仍待用别的方式核）；且 `tts_pregen_wifi_only=false` ⇒ 门禁本来就没拦。
> **阻塞**：设备 USB 掉线（`hdc list targets` `[Empty]`、系统 USB 树里看不到设备）；Wi-Fi 可达（`ping 192.168.10.110` 0% 丢包）但**无线调试端口未开**（8710/8711/5555 均不可连）⇒ 需**重插 USB 线**（或开发者选项开「无线调试」）。
> 门禁：`make test-pregen` ✓ 104/104、`make hap` ✓、`check-keep-props` ✓、`check-hilog-format` ✓。
>
> **2026-10-15 第三十一次同步**：㉛ **`T0.1` 长时任务真机门禁出结论（A1 已定）+ 顺手挖到一个 P0：TTS 的长时任务根本没成立** ——
> **A1（已回写 `SPEC-DETECT-JOB.md` §3.6、plan §2 A1、`BOOKSOURCE-REVAMP-TODO.md` T0.1）**：
> ① `BackgroundMode.DATA_TRANSFER` **存在且可用**（真机 `startBackgroundRunning` 成功 + 通知栏常驻通知；`module.json5` 已加 `dataTransfer`）；
> ② **息屏 606 秒零丢 tick**（07:46:38→07:56:39，应用 PID 未变、每 5 s 一次），停表恰在 **10 分 03 秒** —— 与 SDK 原文规则
> 「`DATA_TRANSFER` 进度超过 **10 分钟**不更新即取消，且进度通知必须是**实况窗（live view）**」吻合 ⇒ 作业必须
> **按 ≤10 分钟节奏更新进度**（3000 源单轮 c=16 ≈4.4 min 落在窗口内，多轮/超长须分片）；
> ③ **同一 UIAbility 不能同时持两个长时任务**（第二个 `startBackgroundRunning` 报 `9800005 The application has applied for a
> continuous task`），共存正解是**一个任务带多类型**：`startBackgroundRunning(ctx, bgModes: string[], wantAgent)` /
> `updateBackgroundRunning(ctx, bgModes[])`（**均 @since 12**，可用；@since 21 的 `ContinuousTaskRequest` 多任务形态本工程用不了）。
> 降级路径（仅前台推进，2026-10-14 已批准）**未触发**，Phase 4 范围不变。
> 证据全文：[`T0.1-LONG-TASK-EVIDENCE.md`](../research/T0.1-LONG-TASK-EVIDENCE.md)（含 SDK `.d.ts` 原文摘引）。
>
> **P0（本轮新发现，独立于 T0.1）：TTS 的 `AUDIO_PLAYBACK` 长时任务约 24 秒后即被系统停掉 ⇒ 听书息屏会被冻结**。
> 真机取证（2026-10-15 13:17，PID 49386，设备 `33Z0224424136564`）：
> ```
> 13:17:03.700 av_session/AVSession: [UpdateFrontSession] AVSessionNotifyUpdateNotification failed, uid = 20020278, pid = 49386, ret = 980000502
> 13:17:03.712 SourceReaderTts: background task started              ← startBackgroundRunning 返回成功（误导）
> 13:17:03.787 CONTINUOUS_TASK: [CancelNotification:159] CancelNotification error label , id -1
> 13:17:27.296 sceneboard/CONTINUOUS_TASK: HandleOnContinuousTaskStop  ← 24 秒后任务被停
> 13:17:58.500 CONTINUOUS_TASK: [UpdateBackgroundRunningInner:1170] continuous task is not exist: 20020278_EntryAbility_10437, use start befor update
> ```
> 独立复现（同日 08:05→08:07，上一进程 1755）：TTS 播放中息屏 → **50 秒后应用整体被冻结**（`play para=` 停在同段），
> 系统侧 `SUSPEND_MSG: [20020278] standby because of being frozen`；冻结前应用侧已持续报
> `AVSession: [operator()]SetAVPlaybackState:2 in syncExecutor timeout after err:0`。与 SDK 明示的挂起原因吻合：
> `ContinuousTaskSuspendReason.SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_USE_AVSESSION = 5` / `_NOT_RUNNING = 6`
> ⇒ **系统认为「接了任务但没接有效 AVSession / 没在播」**，于是不豁免冻结。**这与 M5 记录的「锁屏控件/媒体键可控、
> 切后台不断」矛盾**：M5 走的是自持音频焦点路线，D17 改系统 TTS 后音频焦点归引擎，App 的 AVSession 不再被认作 front session。
> **影响**：① 听书的后台/息屏播放（v1 承诺能力）在真机上不成立；② Phase 4「边听书边跑预检」不能靠 TTS 的任务保命。
> **待办**：查 `980000502` 语义（SDK `.d.ts` 无此码，需靠 `av_session` 源码/文档）→ 确认是「AVSession 未成 front session」
> 还是「未发布媒体通知」→ 按 M5 路线核对 D17 前后差异 → 修完再跑「TTS + 息屏 10 分钟」。
> 门禁：`make hap` ✓、`make check` ✓（`make test`/`make probe` 本任务未改 Rust）。
>
> **2026-10-17 P0 定性完成 + 补丁已落盘（真机验收待设备重连）**：
> **① `980000502` 已解码 = `ERR_BGTASK_OBJECT_NOT_EXIST`**（`resourceschedule_background_task_mgr/frameworks/common/include/bgtaskmgr_inner_errors.h:47-48`，
> 接在 `ERR_BGTASK_OBJECT_EXISTS = 980000501` 之后顺延）。**调用链**：
> `multimedia_av_session/.../avsession_service.cpp:844-857 AVSessionService::UpdateFrontSession(sessionItem, isAdd=true)`
> → `BackgroundTaskMgrHelper::AVSessionNotifyUpdateNotification(uid, pid, true)` →
> `bg_continuous_task_mgr.cpp:1709-1741` 在 `continuousTaskInfosMap_` 里查不到该 uid 的任务 ⇒ 返回该码。
> **即：AVSession 先成为 front 并把「长时任务通知」职责移交后台任务模块那一刻，我们的 `AUDIO_PLAYBACK` 任务还没申请出来。**
> 日志 `.700`（失败）与 `.712`（`background task started`）相隔 **12 ms** ⇒ **确定性顺序竞态，首次进听书必命中**。
> **② 更致命的是这个副作用**：`bg_continuous_task_mgr.cpp:1733` 把 `avSessionNotification_[uid] = true` 写在「任务是否存在」检查
> **之前**（不可逆）⇒ 即使这次调用失败，BTM 此后也认定「该 uid 的通知由 AVSession 负责」而**自己不再发通知**
> （`:2331-2341 GetNotificationText()` 对 `AUDIO_PLAYBACK && isPublish==true` 直接跳过文案生成）。
> **③ `CancelNotification error label , id -1` 是设计行为**：上述分支把空文案当「无通知可撤」并置 `notificationId_ = -1`，
> 含义是「这块不归我」，**不是根因**；真风险是「两边都没发出去」。
> **④ 冻结机制有 SDK 原文**：`@ohos.resourceschedule.backgroundTaskManager.d.ts` 的 `on('continuousTaskSuspend')`（@since 20，
> 本工程 `compatibleSdkVersion=12` **不可直接调**）明写「系统检测到应用未真正执行对应业务时**不直接取消**任务，而是标记 suspended；
> **长时任务被挂起后，应用切到后台就会被挂起（冻结）**」；实现 `bg_continuous_task_mgr.cpp:1787-1820 HandleSuspendContinuousAudioTask`
> 先撤通知，再 `HandleAppContinuousTaskStop(uid)`，后者（`:2264-2279`）只回调**非 hap** 的系统订阅者 ⇒ 正是抓到的
> `sceneboard/CONTINUOUS_TASK: HandleOnContinuousTaskStop`。另 `SuspendContinuousTask`（`:1445-1468`）对**未注册
> `on('continuousTaskSuspend')` 的应用直接按 stop 处理** ⇒ 一个 `on(...)` 监听本可改命（但 API 不可用，故只能靠修时序+通知侧）。
> ⇒ **一个因三个症状**：任务被判「未真正执行」→ 撤通知 + 通知系统「该应用长时任务已停」→ 退后台/息屏后被冻结 →
> 应用进程内的 AudioRenderer `writeData` 回调饿死 → `play para=` 停在同一段。挂起原因只有 `SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_USE_AVSESSION = 5`
> / `…_NOT_RUNNING = 6` 两个枚举，本工程 API 受限无法直接从应用侧读。
> **本轮改动（`entry/src/main/ets/model/TtsController.ets`，+60/-6，`make hap` ✓ 7.6 s）**：
> ① **顺序修复**：`start()` 改为 `ensureEngine → **startBackground** → ensuresession → ensureRenderer`（转正内嵌在 `ensureSession` 之前；
>    `beginFrom()` 里的 `startBackground()` 靠 `bgRunning` 守卫变成幂等空操作）；
> ② **探针（只读，无行为变更）**：`activate` / `setLaunchAbility` / `setAVMetadata` / `setAVPlaybackState` 的错误码**不再吞**
>    （`… failed code=… msg=…`）；AVSession 调用 >300 ms 打 `setAVMetadata|setAVPlaybackState slow <ms>`（历史 `syncExecutor timeout`
>    在应用侧的回声）；`notificationManager.isNotificationEnabledSync()` → `notify enabled=… where=session-ready|bg-started`；
>    `background task started dt=<ms> ms`；`avsession ready id=…`。**未动 NAPI / 落盘 JSON 字段** ⇒ 无需改 `obfuscation-rules.txt`。
> **待真机验收（设备重连后一次跑完，约 8 min）**：`make run` → 听书出声 → 息屏前后来回各查一次
> `hdc shell hidumper -s 1903 -a "--get 20020278"`（**SA 1903 = `bgtaskmgr_service`**，`sa_profile/1903.json`；
> `bg_continuous_task_dumper.cpp` 的 `--get <uid>`，另有 `--all` 可列全部记录含 `suspendState` / `notificationId`）
> ⇒ **回 `No running continuous task` = 任务已被取消（记录已 erase）；仍在且 `suspendState: true` = 只是被挂起**（两种都会冻结，但修法不同）。
> 判据：① `980000502` 应**消失**（时序已修）；② `setAVPlaybackState slow/failed` 是否在冻结前扎堆（H2）；
> ③ `notify enabled=false`（H1）；④ 最终验收 = **息屏 10 分钟 `play para=` 持续推进 + 锁屏媒体卡/媒体键可用 + 无 `HandleOnContinuousTaskStop`**。
> **修正原猜测**：原以为「D17 后 App 的 AVSession 不再是 front session」，但 D17 只换了 PCM 来源、输出层（自建 AudioRenderer +
> AVSession**未**变）⇒ 这个猜测不成立；当前主嫌是「通知职责被双失 + 时序竞态」。且 M5 只验过「Home 后不断」，**从未验过「息屏 N 分钟」**
> ⇒ 按现有证据**不能判定为 D17 回归**。
>
> **2026-10-14 第三十次同步**：㉚ **修两个 T-TTS-7 阶段二真机 bug（缓存章拖动白噪 / 缓存键张冠李戴）+ 设备再次掉线** ——
> **bug ① 拖动 seek 后整章白噪（已修，日志侧已见生效，听感待用户确认）**：`PregAudioSource` 把「毫秒 → 字节」四舍五入，会落到**奇数字节**；16 bit mono 下等于把采样高低字节互换 ⇒ 刺耳白噪。修法：新增纯函数 `pregSeekBytes(ms, sampleRate, bytesPerFrame)` 一律折成**整帧**字节（本例 2 B）；`make test-pregen` +3 条断言（含「200 个零碎 ms 全部帧对齐」）。真机日志：`preg rate=1.50`（变速 1.5× 出声）与 `preg play … base=711.78 rate=1.50`（缓存章内拖到 711.78 ms 后继续出声、其后 `play para=` 正常推进）。
> **bug ② 缓存章读出**别章**的正文（键张冠李戴；代码已改、真机待验）**：`storePregKeys` 原在「响应条数 == 提交条数」时**按下标对齐**，而服务端 `server/app.py::create_job` 把**已 ready/queued 的条目在循环内 append、新条目循环外 append** ⇒ 响应顺序 = 「旧的先、新的后」，与提交顺序无关。
> 真机取证（2026-10-14，`/job/6acf92d45a4d26`）：提交 `[第二章, 第三章, 第四章]`，服务端回 `[{第三章 ready ec27bbff…}, {第四章 ready e059f05a…}, {第二章 queued 50b7313d…}]` ⇒ 设备 `files/pregkeys/c9af6cb1_1.json`（第二章）里存的其实是**第三章**的键（`c9af6cb1_3.json` 存的是第二章的）⇒ 听第二章放的是第三章正文；两章句子骨架几乎一样（只差「第二篇/第三篇」），**耳朵几乎发现不了**。
> **修法**：抽出纯函数 `matchPregKeys(collected, result)` —— **只按 `title` 配对**（同名章按出现顺序各取一次；配不上就留空、**不写键**（宁缺勿错）），顺序未被打乱时走「同下标 + 标题一致」快速路径，服务端不回标题（老版本）才退回按下标；错位条数进日志 `preg keys out-of-order n=…`。`scripts/tts-pregen-sim.py` +8 条断言（**104/104**，含「响应 [三,四,二] 时第二章仍拿 k2」「同文本去重导致响应更短时只留空不误配」）。
> **待验（设备重连后，按序做）**：① 删掉被污染的 `files/pregkeys/c9af6cb1_{1,2,3}.json` 与 `files/chapters/*.json`（本轮 `rm` 没跑到——命令发出时设备已掉线）；② `make run` 后重新提交，核对 sidecar 的 `{url, pregKey}` 与 `/job/status` 里的 `(chapterIndex, key)` 一致；③ 听一整章缓存章，确认**听到的正文 == 屏上高亮的章**；④ 上轮的 `notfound` 保键已在同期真机复现 ✓（`preg key kept key=50b7313d7274e5f0 why=notfound pending=0`——**新进程 pending 为空**仍保住，正是「never invalidate」设计的实证）。
> **设备**：`hdc list targets` 又 `[Empty]`；这次走 Wi-Fi（上次记录 `192.168.10.110`）而 IP 已 100% 丢包 ⇒ 需**设备侧重连 Wi-Fi/唤醒**（非 USB 物理问题）。HAP 已编译通过（`make run` 的编译段 `BUILD SUCCESSFUL`），只差安装。
> 门禁：`make test-pregen` ✓ **104/104**、`make hap` ✓。
>
> **2026-10-14 第二十九次同步**：㉙ **T-TTS-7 阶段二真机贯通（缓存章路线全线跑通）+ 修两个真 bug** ——
> **真因（首轮「拿不到缓存章」的真解答）**：本地书走 `LocalBook`，**正文不进 `ChapterCache`**（直接读导入文件），而 `setChapterPregKey` 要求章节条目已在缓存里 ⇒ 键被**静默丢弃**、每章都退实时；首轮日志的 `stored=2` 只是「尝试了 2 次」，看着像已经落盘。
> **修法（本轮，4 文件）**：`model/ChapterCache.ets` 加 **sidecar** `filesDir/pregkeys/<bookId>_<index>.json`（`{url, pregKey}`，`url` 对不上即失效——换源/目录重排自动作废；`sweepBookFiles` 改成同时扫 `chapters` / `pregkeys` 两目录）；**权威顺序 = 正文条目在就只信条目**，没条目（本地书）才读旁路，条目回来时顺手删残留 sidecar；`setChapterPregKey` 改**返回 `boolean`**；`model/TtsPregen.ets` 按返回值计 `stored`（不再数尝试）；`model/TtsPregenRunner.ets` 文案区分全落盘 / 部分失败（`已提交 N 章（M 章没记下缓存键，下次仍走实时）`）；`scripts/tts-pregen-sim.py` 同步把声明改成 `boolean`（否则 `tsc` 报 `TS1345`）。
> **第二个真 bug**：`TtsController.ets` 的 `preg play … rate=%{public}f` 真机打成 `rate=}f` —— **hilog 不支持 `%f`**（不报错、值直接丢）⇒ 改 `toFixed(2)` + `%{public}s`；新增 `scripts/check-hilog-format.sh`（机械核对 56 个 `.ets`，跳过注释行）接进 `make check`，并进 `docs/PITFALLS.md`。
> **真机证据（2026-10-14，`33Z0224424136564` · debug · `make run` 闭环 · 自造短章本地书《短章测试》bookId `c9af6cb1`）**：`preg submit jobId=6acf54abc6c6f1 items=2 stored=2 evicted=0`（本次 `stored` 是真落盘数）→ 设备 `files/pregkeys/c9af6cb1_2.json` = `{"url":"local://c9af6cb1/2","pregKey":"ec27bbff1308dcb4"}`（第 3 章同形）；进章 `begin para=0 route=cache` → `preg playing key=ec27bbff1308dcb4` → `play para=1..6`（~5.6 s/段）⇒ **缓存章 24 kHz 命中**；章末 `preg chapter end key=…` → `preg cache delete key=… code=204`，设备 `pregkeys/` 清空、`cache/pregen/` 空 ⇒ **听完即删**；第三章末**无人干预自动接着**播第四章（同走缓存）；未算完的章进章时：`render rate 16000 -> 24000` → `renderer ready rate=24000` → `begin para=0 route=cache` → `preg audio failed kind=notfound` → `preg fallback=realtime why=notfound para=0` → `render rate 24000 -> 16000` ⇒ **跨章 16k↔24k 双向重建渲染器 + 出声前才退实时，同章不混声线也不混采样率**；服务端 `queue/run` 里出现的 key 与首轮**完全一致**（`ec27bbff…` / `e059f05a…`）⇒ 内容寻址再次实证。
> **第三个真 bug（本轮真机发现，代码已改、真机待验）**：提交后立刻进章时 `GET /audio/<key>` 必然是 404（worker 还没算完），而旧逻辑把这种 `notfound` 当成「音频已失效」**把键抹了** ⇒ 刚付了算力的缓存永久丢掉（本地书尤其致命）。改法：`notfound` **一律保留键**（内容寻址 ⇒ 算好了 / 重新提交还是同一条 key；**不跳过下载**，同一 job 里已算好的章照样命中）；「已提交没算完」用 `model/TtsPregen.ets` 的 `markPregKeyPending` / `isPregKeyPending`（进程内 `Set`）登记、`TtsPregenRunner` 在 job 到终态时撤销，**只用来把日志区分成 `pending=1`（job 还没算完）/ `0`（真没了）**，不改变行为。仿真 +4 条断言（**91/91**）。
> **未跑**：拖动 / 变速的逐项拍照（`rate=` 可读性本次已修）、锁屏媒体卡、`expired`（服务端清理）分支、Wi-Fi 门禁取证（本轮未触发，`ip route` 仍欠）。**设备在续测前从 USB 总线消失**（`ioreg -p IOUSB` 只有 Apple 内置、`hdc list targets -v` = `[Empty]`、`hdc kill -r` 与轮询 30 s 均无用 ⇒ 需**物理重插**，不是软件问题）；服务端已把 ch3/ch4 算完（`queue/done` 两条 + `/cache/stats files` 6），重插后可直接验缓存命中与 pending 两条日志。
> 门禁：`make hap` ✓、`make test-pregen` ✓ **91/91**、`make check` ✓（新增第 4 步 hilog 格式核对）。
>
> **2026-10-13 第二十八次同步**：㉘ **D17 落地：停用远端 VITS 实时链路**，实时朗读改系统 TTS，VPS 只留给预生成缓存 ——
> 起因：真机试听实时远端（VITS·甘雨）被用户主观判为「非常差」，而立项要用的 GSV 声线只在离线预生成链路上。用户拍板 **“只停实时、保住 GSV 缓存”**，且**不打算再听 A/B**。
> 代码（4 文件）：`model/TtsPregen.ets`（`chapterAudioRoute(preferCache, pregKey)` **去掉 `engineKind` 参**：路由只看「缓存优先 + 有 `pregKey`」）、`model/TtsController.ets`（新增 `renderRate` + `ensureRenderRate(rate)`：**进章按路线重建渲染器**（缓存 24 kHz / 实时 16 kHz）；`sampleRate` getter 从「按引擎」改「按路线」；`beginFrom` / `abandonCachePath` 改**异步等渲染器就位** + `seq` 守卫防换章竞态；`start()` 恒 `ensureEngine()`；预取下一章不再要 REMOTE）、`pages/Listening.ets`（声线行/菜单只剩系统音色，实时来源文案「系统 TTS 实时（这一章没有预生成音频）」，预生成行**常显**）、`pages/ListeningSettings.ets`（删「朗读引擎」chip 与远端音色 chip；服务器地址/API Key 移进新分组「预生成音频（电脑端 VPS 后台合成）」且**常显**；语速档位不再置灰）。`engineKind` 字段与 REMOTE 分支保留但**不可达**（一处开关可恢复）。
> 静态验证：`make hap` ✓（ArkTS 严格模式，`CompileArkTS` 真跑 2.7 s，`Listening*.ets` 零告警）；`make test-pregen` ✓ **87/87**（路由真值表由 5 条收到 2 参 4 条；新增 Python 侧**回归门**：`chapterAudioRoute` 源码里出现 `engine`/`TTS_ENGINE` 即 fail）。变量测试依旧有效（改 `TTS_PREGEN_SPEED_SCALE` 或块尾判定即红）。
> **首轮真机（2026-10-13 夜，设备 33Z0224424136564 · debug · `make run` 闭环）**：
> ① **系统 TTS 实时（16 kHz）跑通**：`tts engine migrated remote->system (D17)`（存量偏好确为 REMOTE 2）→ `engine ready voice=13` → `renderer ready rate=16000` → `begin para=0 route=realtime` → `play para=1..5`；且章节自然续播时（第二→三→四章）恒为 `route=realtime`、**不重建渲染器**（同路线）。
> ② **听书页 UI 与 D17 一致**：显示「系统 TTS 实时（这一章没有预生成音频）」、音色行只剩「朗读音色 · 聆小珊（女声）」、预生成行**常显**（「预生成后续 10 章」+「开始」）。
> ③ **未完成（卡在拿不到缓存章）**：缓存章 24 kHz 命中播放、**跨章 16k↔24k 重建渲染器**、拖动/变速/听完即删/锁屏。
> **卡点 = 「仅 Wi-Fi 时预生成」拦下提交**（原文案「「仅 Wi-Fi 时预生成」已开启：连上 Wi-Fi 或到听书设置里关掉」）。但当时 **wlan0 已拿到 192.168.10.110**，而 `onWifi()` 看的是**默认网络的 bearer**（`connection.getDefaultNetSync()` + `bearerTypes`）⇒ 推断当时默认网络仍是蜂窝（那条 Wi-Fi 无外网 / 系统未切路由）。**下次先取证**：`ip route` 看默认路由走 `wlan0` 还是 `rmnet*`；若走 wlan0 而 `onWifi()` 仍 false，则是要改的 bug（判据应由 bearer 改为「路由出口」）。
> **未解的旧账**：拿不到缓存章是因为手头没有 key 对得上的缓存（见下方补记③）；今日自造短章书因门禁未提交，按 6 min/章估算也来不及。
> **环境坑（已修/已记）**：① `make log` 原用 `-T SourceReaderPoC` 过滤——**应用日志的 tag 是每文件各自一个**（TTS 用 `SourceReaderTts`），拿错 tag 只会得到空结果、看着像「功能没触发」；已改为按 **bundle 名** 筛（`Makefile` log 目标 + `docs/PITFALLS.md` + `docs/development.md` + skill `harmony-device-run` 四处同步）。② 本机 **USB 反复 `Offline`/`Empty`**（`hdc kill/start` 偶尔能救回，与软件无关）：判「线通不通」用 `ioreg -p IOUSB`（看不到手机 = 物理层没通），别在 hdc 上干耗。
>
> **补记：第二十七次同步的真机欠账（2026-10-13 真机段）** ——
> ① §4.2① 设置页渲染 ✓；② 提交被「仅 Wi-Fi 时预生成」**正确挡下**（蜂窝网；原文案「「仅 Wi-Fi 时预生成」已开启：连上 Wi-Fi 或到听书设置里关掉」），**未提交、未烧 VPS 算力**；③ **缓存键口径取证**：`sha256(canonical_text | voice | 1.0 | engine | v1)[:16]` 是**纯内容寻址**（与 bookId/章节序号无关），设备上那章缓存的 meta 标题（「第51章 今日无事」）与书架 index 51 的实际标题（「对峙」）不符，且拿设备 6 个章节缓存用 4 种切分变体重算 key **无一命中** ⇒ 手头真缓存无法当命中样本；重生成《剑来》8709 字单章 ≈ **3.3 h**（不可接受）。
> ④ 改用**自造短章 TXT 本地书**《短章测试》（4 章 120/272/391/150 字；`hdc file send` → `/storage/media/100/local/files/Docs/Download/` → App「导入本地书籍」）：第 2 章 ≈ **6 min** 即可命中，等待从 3.3 h 压到分钟级；⑤ 手法沉淀：`bindMenu` 菜单/toast 这类系统弹层 `dumpLayout` **读不到**，改用 `uitest screenCap` + `tesseract --psm 6 tsv` 抠坐标；⑥ 引擎归属澄清：实时远端 = **VITS**（804 speakers；UI 显示「远端音色 · 甘雨」= 旧名 `流萤` 经 `REMOTE_VOICE_RENAMES` 归一），GSV 只在预生成链路——两表同名不同模型，D17 后歧义消失。
>
> **2026-10-13 第二十七次同步**：㉗ **T-TTS-7 阶段二（App 侧接入）已实现，`make hap` + `make check` 通过；真机验收未做（设备未连，`hdc list targets` 空）** ——
> 新增 3 文件：`model/TtsPregen.ets`（数据契约 + 纯函数 `chapterAudioRoute`/`pregTimeline`/`pregPlaybackRate` + 6 个 HTTP 调用 + 章节缓存 `pregKey` 读写）、`model/TtsPregenRunner.ets`（**进程级单例**：提交 / 5 s 轮询 / 重试失败，收起听书页不丢跟踪状态）、`model/PregAudioSource.ets`（WAV 头解析 + 24 kHz mono S16LE 读盘 + `seekMs`）；
> 改动 5 文件：`model/TtsController.ets`（**章级原子切换**：进章取 `pregKey` → 整章下载到盘 → 渲染器只喂文件、`setSpeed` 变速、块锚点时间轴、出声那一刻锁路线、听完 `DELETE` + 删本地 + 抹键、下一章预取）、`model/ChapterCache.ets`（`pregKey` 随正文失效一并作废）、`pages/Listening.ets`（预生成行：开始/停止查看/重试失败 + 进度行 + 失败清单）、`pages/ListeningSettings.ets`（远端引擎下新增「预生成」分组：音色 3 档 / 提前章数 4 档 / 仅 Wi-Fi / 缓存优先）、`entry/obfuscation-rules.txt`（+27 个 keep 名）。
> **与 IMPL §3.4 的两处实现偏差（已写进 §3.6）**：① 不是 `Range` 边下边播，而是**整章先落盘再播**（可 seek / 可离线重听 / 进度锚点用文件时钟）；② 服务端 meta 的 `chunks[].p0/p1` 给了**块级段落下标**，段内再按字数插值 ⇒ 高亮误差从「块内 ±20%」降到「段内 ±1 段」。
> **静态验证**：`make hap` 成功（ArkTS 严格模式）；`scripts/check-keep-props.sh` ✓ 172 个 keep 名覆盖全部 JSON 往返字段；**新增主机仿真 `make test-pregen`（`scripts/tts-pregen-sim.py`，真源码机械切片 + `tsc` + `node`）88 条断言全通过** —— 覆盖路由真值表（含「系统 TTS 引擎不用缓存」「关掉缓存优先」）、块锚点→段落时间轴（含无锚点/坏锚点/越界/超长段切两块/空段落 NaN）、倍速夹取（并锁死**不**套 VITS 的 0.75）、进度与失败文案、`expired` 必须进失败清单（否则「重试失败」按钮死掉——本轮仿真抓出的真 bug，已修）。
> **未验证**：§4.2 全部真机项（整章下载播放 / 拖动 / 变速 / 窄带兜底 / 听完删 / 锁屏）。
>
> **2026-10-13 第二十六次同步**：㉖ **T-TTS-7（P1）TTS 预生成「阶段一」已实现并全项验收通过（7/7）** —— 服务端落盘缓存 + 独立 job worker 已上 VPS（`/root/tts/{server,gsv}` + `/etc/systemd/system/tts-job.service`，**unit 默认 disabled**，线上 `/tts` 一行未改）。
> 新增 4 文件：`server/tts_cache.py`（键/布局/状态机/淘汰，**纯 stdlib**，API 与 worker 共用）、`server/job_worker.py`（独立进程，`import gsv_batch.synth_native` 作唯一合成口径；单 worker 单音色；超长段句末切开的安全阀）、
> `server/tts-job.service`（`Nice=19`/`CPUWeight=20`/idle IO/`MemoryMax=3800M`/启动自检 swap ≥4 G）、`server/pregen_test.py`（验收客户端）+ `app.py` 新增 6 个端点（`/job`、`/job/status`、`/audio/{key}`、`DELETE /cache/{key}`、`/cache/stats`、`/cache/probe`，`/health` 增 `lastTtsAgeMs`/`cacheBytes`/`queue`）。
> **验收证据**（IMPL §4.1.1，日志 `journalctl -u tts-job`、`/root/tts/r1_s*.log`、`/root/tts/yield_probe*.log`）：① 285 字样本 `audio 63.76 s / RTF 5.03 / 峰值 −2.0 dBFS / 0% 削顶 / 硉时差 0.00%`；② 幂等 `createdAt` 不变；③ 并发 `/tts` **16 次全 3.1–3.8 s 成功**，门闸在探针窗内打 `yield … sleeping 15s`；
> ④ **整章 8709 字 / 41 段 = 7 块，音频 1777.5 s（29.6 min）/ 合成 12025 s（3.34 h）/ RTF 6.76 / HWM 3638 MB**（比立项基准 2.78 h/5.57 慢 20%，**工程记账改用 3.3 h / 8709 字**）；⑤ 淘汰与保护（`4M` 上限下已播放项被淘汰、未播放项存活、新 item `409 cache_full_wait_playback`）；⑥ Range 206 + `kill -9` 恢复 + SIGTERM 退条不留半章；⑦ 线上未重启、`/health` <0.5 s、无 5xx。
> **三个反直觉的实测**（现已写进代码/文档）：**块数不是契约**（同章按原始行切 = 6 块、按真实段数组切 = 7 块，只保证 ≤1500 字/块）；**段边界是切点** ⇒ 单段 >1500 字（整章被当一行的情形）必须句末切否则单块 8741 字直接 OOM；**批块会被线上拖慢**（302 字块 7 min → 10 min）而线上探针不变慢 —— 这是设计取舍。
> 磁盘先回收 **3.6 G**（删 GSV 里用不到的 `hifigan_do`/`gsv-v2final`/`s1bert25hz`，引擎加载正常）；另修两处：`gsv_batch.py` 导入即跑 `main()`（已加 `__main__` 守卫）、worker 启动自检 swap（现 6.1 G）。**阶段二（App 侧 `流萤` 音色 + `/audio` 整章播放 + 变速 + 听完 `DELETE`）未开工。**
> 同期另一个 session 的第㉕次同步（T-SHELF-7 两项残留真机补齐）与本项无耦合，保留原结论。
>
> **2026-10-13 第二十五次同步**：㉕ **T-SHELF-7 两项残留真机补齐（设备 `33Z0224424136564` · debug · `make run` 闭环）**：① 收尾小迭代的进度文案两种形态都拍到 —— 无失败 `检查中 1/2`（dump 实测 `[658,190][869,241]`）、有失败 `检查中 1/2 · 1 本未检查`（靠停用 `bbiquge8` + 同 URL 孪生 `笔趣阁8` 注入，开关已还原 13/13）；② **「有新章」分支首次真机走通**：一次性调试版只给《剑来》的落库值打 `[T-MARK]` → DB 见 `第83章 今日无事 [T-MARK]`（真 `upsertBook` 写库）→ **还原代码**复跑 → toast `1 本有新章节` 且基线前移回 `第83章 今日无事` → 再点一次 toast `没有发现新章节，1 本未检查` 且整库逻辑 diff 为空（幂等）。③ 顺带抓到三个坑：`dumpLayout` 卡死会连累其后所有 dump、**只 recv `shelf.db` 会漏 WAL**（差点误判「没写库」）、`tesseract` 必须 `cd` 到图片目录用相对名 —— 已进 [`../PITFALLS.md`](../PITFALLS.md) 与 skill `harmony-device-run` §4。
> **2026-10-13 第二十四次同步**：㉔ **T-SHELF-7 收尾小迭代（进行中进度行显示未检查数）**：进度回调由 `(done,total)` 扩为 `(done,total,failed)`（`failed` 是累计值），新导出纯函数 `shelfProgressText(done,total,failed)` —— 无失败 `检查中 1/2`、有失败 `检查中 1/2 · 1 本未检查`、无网络书 `检查中…`；`pages/Index.ets` 只把拼串改成调该函数（令牌/字号/热区/`accessibilityText` 未动）。
> 主机仿真 `scripts/shelf-updater-sim.py` **25 → 30 断言 `ALL PASS`**（新增 4 条文案形态 + 1 条「失败数必须在**进行中**就上报」的确定性序列；顺带订正旧文档写的「27 断言」笔误）；`make hap` 通过。
> **真机本轮未重跑（用户明确暂停设备工作）** ⇒ 新文案的真机截图证据待补；「有新章」分支真机不可造的结论不变（见下）。**（两项均已由同日 ㉕ 关闭：文案两形态真机拍到，「有新章」分支经一次性调试版真机走通）**
>
> **2026-10-13 第二十三次同步**：㉓ **T-SHELF-7 真机验收完成（设备 `33Z0224424136564` · debug · `make run` 闭环）⇒ 置 `[x]`**。
> 真机实证 12 项：进度文案 `检查中 0/2` → `1/2`；**`total = 2`（本地书《大唐：李世民求我造反》被正确排除）**；结束 toast `没有发现新章节，1 本未检查`；失败静默（《天堂向左 深圳往右》源站点已失效 ⇒ 计 `failed`、**基线保持空值不被建立、其余书不受影响**）；
> **全程 DB 逐列零写入**（反复点击 / 注入 / 复跑后 `shelf.db` 与开始时 `diff` 无输出）；连点两次只跑一轮（`shelfUpdating` 守卫）；幂等（再点 → 同文案 + DB 不变）；编辑态顶栏 `"text":"更新"` 计数 0；**全失败分支 toast `检查失败，请检查网络或书源`**（停用 `bbiquge8` 及其同 URL 孪生 `笔趣阁8` ⇒ `checked = 0`）；随后把两个开关恢复启用并复跑，行为与注入前一致。
> **「有新章」分支真机不可造（已证伪两条注入路径，勿再试）**：① 沙箱 DB 对 shell 只读（`touch` / `hdc file send` 均 `Permission denied`）⇒ 无法手工改基线；② App 内唯一写基线的路径（换源 `SourceSwitch.ets:206` / 加入书架 `BookDetail.ets:71`）写的是**同一个源的详情页值**，而「更新」比对的就是这个值 ⇒ 除非站点自然更章，否则必然相等。
> 该分支当前只由主机仿真覆盖（`scripts/shelf-updater-sim.py` 的「基线前移 / 等价对齐不误报 / 幂等」三组）；**残留未验 = 真机上一次真实的 `upsertBook` 写库**（同一函数已被加入书架 / 换源 / 本地导入 4 处调用；且它抛错会被计 `failed`、出现在 toast 的「N 本未检查」里，不会静默）。
> 顺带产出两条可复用技法（已进 [`PITFALLS.md`](../PITFALLS.md) 与 skill `harmony-device-run` §4）：**`uitest dumpLayout` 不导出系统 toast 窗口** ⇒ 读 toast 用 `uitest screenCap` 连拍 + 主机 `tesseract -l chi_sim`；**「停用某本书的源」不是可靠的失败注入**（内置集 `bbiquge8` / `笔趣阁8` 同指 `m.bbiquge8.net`）。
> 设备侧另记：`hdc list targets -v` 显示 `USB Offline` 时 **`hdc kill -r` 能当场恢复**，裸 `hdc kill` 会把设备从列表里抹掉；本机 USB 链路自身会隔几分钟掉一次（表现：`file recv` 报 `need connect-key`）。
>
> **2026-10-13 第二十二次同步**：㉒ **T-SHELF-7（P2）书架「更新」代码已落地**（新 `model/ShelfUpdater.ets` + 书架顶栏入口，按方案 ① 零 schema 改动）。
> 与立项方案不同的三个设计点（均为复核/实测后改，理由写在条目里）：**基线比较走 `cleanChapter` 归一化**（同一章在详情页 `第83章 今日无事`、搜索结果里 `最新：第83章 今日无事` ⇒ 直接比字符串会把没更新的书报成有新章）、
> **无基线时静默建基线**（没有可比对的信息时报「有新章」是纯误报）、**单本超时 6s → 15s**（当时 `bookInfo` 没有独立预算，只能容下 search + bookInfo 两次请求；2026-10-19 已改由引擎整段超时接管，见本项「实现」③）。
> 主机侧新增 `scripts/shelf-updater-sim.py`：从**真源码机械切片** + 只打桩 3 个外部依赖（引擎/DB/本地书判定）→ `tsc` + `node`，**27 条断言全通过**（含并发上限 3 / 预算耗尽 / 单本 15s 超时护栏 15002ms）。
> ⚠️ 本节当时的「真机验收未做」**已由同日 ㉓ 关闭**（条目已置 `[x]`，证据见该条目「验证」③④）；本节其余结论（三个设计点 + 主机仿真）仍然有效。
>
> **2026-10-13 第二十一次同步**：㉑ 登记并修复 **T-SWITCH-1（P1）换源：候选被静默丢掉 + 每轮白等 13 源**（主机侧 + **真机均已完成**）；同日按用户需求立项 **T-SHELF-7（P2）书架「更新」：批量检查在架书籍是否有新章节**（代码未开工，方案与已知坑已写进条目）；
> 同日按用户提问**复核 5 层缓存**（抽屉 30min 候选 / 预热 10min / TOC 6h / 正文 URL 键 / 书架标签）→ 结论 **A/C/D 与「读到末尾自动重爬」全部决定不改**，两条已知残留（末章「下一章」静默、< 6h 看不到刚更的章）写入 **T-SHELF-6 后续评估**。
> 真机「《剑来》换源只有 1 个候选」的根因**不是书源太少**，而是 `isSameBook` 比作者时没削页面标签（`normalizeKey` 只删空白）：
> `probe search 剑来 --json`（13 源 / 560 条）同名 8 条里 `小说` / `黑炎小说` 的 author 是 `作者：烽火戏诸侯` → 被当「另一本书」静默丢掉（命中 **6/8 → 8/8**）。
> 同批四个改动：**同域去重**（`m.bbiquge8.net` 两条书源 + 行级按域名，5 行 → 7 行）、**检索预算**（单源超时 10s→6s / 全局派发 10s / 候选够 3 条收尾 + 「继续检索」）、
> **30 分钟会话缓存**（重开抽屉直接上屏 + 「重新检索」）、**换源预热**（新 `model/SourcePrefetch.ets`：行上屏即爬最靠前 2 个候选的详情 + 目录，切换 7s → 命中即省；只放内存）。
> 主机侧验证：`probe search 剑来 --json` 逐条对帐 + `make hap` 通过。**真机复验（2026-10-13）通过**：候选 **2 → 7 行**、3s 上屏、`已检索 12/12`、预热命中切换 **≤1s**、重开抽屉秒上屏并正确标记当前源；
> 真机另逼出两个主机侧看不到的问题并一并修掉：① 候选行 `ForEach` 的 key 不含 `chapter` → 预热回填的「最新：xxx」**不上屏**；② 「重新检索」被自己的会话缓存原样命中 → **点了没反应**。
>
> **2026-10-12 第二十次同步**：⑳ 登记 **T-TTS-7（P1）TTS 预生成**（服务端内容寻址缓存 + job worker）—— 用户已拍板**立项**：
> 默认引擎 **GPT-SoVITS v2ProPlus（流萤微调）**、缓存 **WAV 直出 + 严格淘汰**、素材**先手动喂**（客户端入口后置）。
> 当日实测（同机同文本）：整章 8741 字 = 6 块 / 音频 1802.5 s / 合成 9992.4 s / **RTF 5.57** / 常驻 **3.29 GB** ⇒ 一章 3000 字 ≈ **57 min 算力 / 31 MB**，
> 100 章 ≈ **95 h + 3.1 GB**；`v4`（钟离_ZH）RTF **115.3** ⇒ CPU 上出局；零样本底座（花火/卡芙卡）5.86–7.17 可用。
> 反直觉的两条实测：**`cut3` 比 `cut5` 慢 1.75×**（长段让 AR 单段吐 612 token，也正是整章 `cut3` 被 OOM 的直接原因）、
> **`fragment_interval=0` 与 `0.3 s` 算力完全相同**（只少 14% 段间静音）。硬约束 = **磁盘（`/` 剩 1.2 G，需先回收 ~1.5 G）+ 内存（3.3 GB 与线上 VITS 抢）**。
> 施工图 [`../research/TTS-PREGEN-IMPL.md`](../research/TTS-PREGEN-IMPL.md)（§1 数据契约 / §2 服务端 / §2.5 磁盘 / §3 App 侧「填写方式」/ §4 验收 / §6 下个 session 的启动 prompt）；
> 判据改写与实测明细 [`../research/TTS-PREGEN-PLAN.md`](../research/TTS-PREGEN-PLAN.md)。**阶段一代码未开工**，仓库与线上行为未改一行。
>
> **2026-10-11 第十九次同步**：⑱ 新登记并**当日修复** **T-READ-4（P1）Legado `text.` 前缀未实现** —— 按「不接设备的主机侧任务」复验多页目录时查出**真 bug**：
> 引擎规则 DSL 只认 `class.` / `id.` / `tag.`，`text.下一页@href` 被当成 CSS 选择器 → **0 结果且无诊断** → 目录/正文翻页循环在第一页后 `break`。
> 影响 **9 条规则 / 8 个内置源**（`ruleToc.nextTocUrl` × 3、`ruleContent.nextContentUrl` × 5、`ruleBookInfo.tocUrl` × 1）。决定性证据（《剑来》@ bbiquge8，`info` 报最新章节「第83章 今日无事」）：
> 修复前 `toc` = **50 条**（末条「第50章 天行健」），站点侧实为 **1308 章**；修复后 = **1308 条**（末条即最新章）。对照实验（唯一变量）：爱下书 `nextTocUrl` 置空 → **20 条**，规则原样 → **58 条**；bbiquge8 首章正文「(第1/3页)」现拼到**第 3/3 页**结尾。
> 修法（纯 Rust）：`rule_dsl/parser.rs` 加 `RuleToken::TextContains`（必须在裸 CSS 兜底**之前**判断）+ `rule_dsl/html_extractor.rs` 加 `apply_text_filter`（自身文本包含关键字、大小写不敏感、排除 fragment 包装 `<html>`）。
> 验证（纯主机侧，未上设备）：`make test` **56 → 58 项全过**、`probe search 剑来` 逐源零回归（588 条 / 11-13 与修复前一致）、`make rust` 交叉编译成功；**设备侧复跑待设备上线**（本轮 `hdc list targets` = `[Empty]`）。
> 顺带定性第十六次同步里 T-READ-3 记的「《大唐》目录加载失败」：主机侧 `probe toc` **正常返回 1449 条**（页面 30 KB / 0.7 s）⇒ 无法复现，非引擎缺陷（详见 T-READ-3 条目）。
> 证据见条目内「验证」段与 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §17。
>
> **2026-10-11 第十八次同步**：⑰ **T-TTS-6 条目已按用户决定移除** —— 结论：**在当前 VPS（4C Xeon / 无 GPU）上无解，后续不做**。
> 三条路线逐条撞墙：**A 声纹匹配**（证伪：`fanchen-C` 的 187 声线不是原神角色，真阳性对照已排除假阴性）、
> **B ZipVoice + 官方中配参考音频**（音色 7/7 命中、RTF<1，但 `num_steps=3` 的 few-step 毛刺属**听感**风险，用户不采用）、
> **C/D 租 GPU 跑 GPT-SoVITS 或自训 VITS 导 ONNX**（需换机器，不在当前硬件约束内）。
> 决定与理由已固化进 [`../decisions.md`](../decisions.md) **D14**；调研证据**整篇保留**在 [`../research/TTS-VOICE-SOURCES.md`](../research/TTS-VOICE-SOURCES.md)（§4/§5/§6/§10/§11，纯参考、不再跟进）。
> 远端 TTS 声线继续用 804 底模的 5 个 **标签名**（不代表真实角色，见 T-TTS-5 条目），本仓库不再投入「贴角色标签」。
>
> **2026-10-11 第十七次同步**：⑯ **T-TTS-5 客户端收尾四项已落地** —— ② `RemoteTtsClient.ets` `readTimeout` 60000→**120000**；
> ③ `Const.ets` 的音色选项换成 5 个新名（默认 **钟离**，旧值 `流萤/花火/卡芙卡` 由 `normalizeRemoteVoice()` 读取时归一，用户无需重选）；
> 语速由「服务端空转」改为**客户端真下发**（有效 = `clamp(client,0.5,2.0) × SPEED_SCALE`），④起点值取 **0.75**（≈5.2 字/秒，与客户端 `CHARS_PER_SECOND=5` 巧合对齐）。
> ① 真机端到端**已跑通**（远端引擎连播 5 段、无回退；服务端日志 `speed=0.750/1.500` 与 UI 档位逐条对得上；旧 pref `流萤` 在界面显示为「远端音色 · 甘雨」），
> **但 5 音色的真机切换与 ④ 终值仍待用户听感结论** —— 本轮验收中途设备掉线（`hdc list targets` 为空），5 音色真机切换未走完（服务端 5 音色已逐个 200 验证，样本在 `~/Desktop/tts-abtest-tts5/`）。
> 顺带修掉一个**真机才暴露的服务端 500**：纯标点分段（`：“”` / `——`）sherpa 返回 `sample_rate=0` 的空音频 → `_resample_fft` 除零 → **每个对白段都 500** → App 中途回退系统 TTS。
> 证据见条目内「验证」段与 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §16。
>
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
> **（T-READ-3 已于 2026-10-11 真机复验通过 → `[x]`，见文首第十六次同步；设备现已在线，T-TTS-5/6 的真机项可做（T-TTS-6 后于同日按用户决定整体移除，见文首第十八次同步）。）**
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

- [x] **T-CROSS-4（P0）听书（系统 TTS 实时路线）息屏后被整体冻结**：`AUDIO_PLAYBACK` 长时任务约 24 s 即被系统停/挂起 ⇒ 退后台冻结（`play para=` 停在同一段）。**2026-10-17 真机 10 分钟验收通过，已关闭。**
  - 根因（2026-10-17 已定性）：`980000502 = ERR_BGTASK_OBJECT_NOT_EXIST` —— **AVSession 先 `activate()` 成为 front、`startBackgroundRunning` 后到**（12 ms 竞态），
    且 BTM 此后认为「通知归 AVSession」自己不发 ⇒ 两边都不发通知 ⇒ 任务被判「未真正执行」⇒ 撤通知 + `HandleAppContinuousTaskStop` ⇒ 冻结。
  - 证据：本条 §第三十一次同步 的 P0 段 + 其后「2026-10-17 P0 定性」段（含系统侧源码行号）；日志 `.700 / .712 / .787 / 13:17:27.296`；
    `entry/src/main/ets/model/TtsController.ets`（`start()` 顺序修复 + 错误码/通知/耗时探针）
  - 状态（2026-10-17，已关闭）：顺序修复后 `980000502` 消失；此前「约 50 s 后 `freezer:/Frozen`」在本轮完整 10 分钟复测中**未复现**。
    `allowEnableNotification` 仍为 `false`，但播放、锁屏媒体卡与媒体键均正常 ⇒ 通知总开关不是本 P0 的必要条件。
    10 分钟窗口内 `play para=` 从 `83` 推进到 `120`，跨章后继续到新章 `13`；cgroup 保持 `freezer:/`，无任务停止/挂起日志。
  - 验证：`make run` → 听书 → 息屏 10 分钟 ⇒ `play para=` 持续推进、无 `HandleOnContinuousTaskStop`、锁屏媒体卡/媒体键可用
    （本轮证据见 §第三十四次同步）；另可**不改代码**地用 `hdc shell hidumper -s 1903 -a "--get <uid>"` 读任务记录
    （`No running continuous task` = 已取消 / `suspendState: true` = 被挂起）。

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
  - **后续评估（2026-10-13，按用户提问「缓存还需要改吗」复核全部 5 层缓存 → 结论：都不改）**：
    ① 换源写盘刷新新鲜期（原选项 A）**不改** —— `switchSource` 写进去的目录就是 ≤10 min 的预热结果（超 TTL 即走网络新爬），「刚查过 → 6h 不查」与正常打开书**语义一致**，残余风险只有那 10 分钟窗口；
    ② 抽屉 30 min 候选缓存（原选项 C）**不改** —— 只影响「最新：xxx」这个**选源参考**信息，命中时静默改写会让行文案跳变 + 请求翻倍，要准确时有「重新检索」；
    ③ 启动后排查书架（原选项 D）**不改** —— 已由 T-SHELF-7（手动「更新」，用户选定）取代；
    ④ 「打开书就重爬」（原选项 B 原样）**不改**（每次打开都爬目录的请求量不划算，且 `Const.ets:126-129` 已记录 6h 是刻意折中）；其精确版「**读到末尾才重爬**」经用户 2026-10-13 明确决定**也不改**（同时选定：若将来修，**只提示不跳转**）。
  - **已知残留（2026-10-13 用户确认接受，暂不修）**：
    ① **读到缓存目录最后一章后再点「下一章」/ 翻过最后一页是彻底静默的** —— `Reader.nextChapter` → `nextReadable()` 返回 `-1` → `loadChapter(-1)` → `isReadable` 为假**直接 return**（无 toast、无刷新、无任何反馈），证据 `pages/Reader.ets:368-375` / `471-474`；
    ② 同一天内第二次打开且间隔 < 6h 时，看不到这期间刚更新的章（要等到下一次超过 6h 的打开）。
    将来若要修，落点即上述 ① 处：`nextReadable() === -1` 时按限流窗口（建议 10–30 min）复用 `Reader.refreshToc` 重爬，有新章**只 toast「已更新 N 章」、不自动跳转**；无新章 toast「已是最新章」。
    两个同源限制：`refreshToc` **只在章数变化时**采纳目录；听书期间 `TtsController` 持有开启听书那刻的 `chapters` 引用（注释已写明），刷新对 TTS 不生效。
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
    ⑥ **2026-10-23 混合书架与目录兜底修正（已真机验证）**：真实书架证据为 2 本，其中一本 `source_url=local://`，另一本《中国少了一味药》来自 qwyd。主机探针确认该源搜索/详情可用、详情章节名为空、目录 38 章末章为 `第三十七章`。修正后主机仿真 **48 断言 `ALL PASS`**，新增覆盖本地书分母、结束文案、详情缺章名时目录兜底、卷标题跳过、`info.tocUrl` → 书架 `tocUrl` → 搜索 `bookUrl` 三级回退、目录 45s 预算与目录失败不写库；`make hap` 与 `make check` 通过。**真机（设备 `33Z0224424136564` · debug · `make hap` → `make install` → `make restart`）**：首轮截图 OCR 得到 `检查中 1/2 · 本地书 1 本跳过`，结束 toast 为「没有发现新章节，1 本本地书跳过」；DB 中 qwyd 书基线写为 `第三十七章`，本地书行与进度不变；第二次点击后 `shelf.db` 逻辑 `dump` 哈希前后均为 `8c1464d2…` ⇒ 幂等、0 误写。
    ⑦ **2026-10-23 本地 TXT 文件名拆书名/作者（已真机验证）**：本地书架行《大唐：李世民求我造反 作者：天下乐》实际来源为 `local://`，导入时旧逻辑只去扩展名，导致书名残留作者标签，无法得到可搜索的规范书名/作者。新增 `common/Format.ets::splitTitleAuthor()`，只识别尾部 `作者：` / `作者:` / `作家：`（含括号形式），从文件名取作者时优先于正文探测；书架加载时对旧 `local://` 行原地修复，保留 `bookId`、来源、添加时间和进度，并尽力同步本地 `toc.json` 的元数据。仿真增至 **55 断言 `ALL PASS`**（新增全角/半角冒号、括号、无作者、标题中间含“作者”、多个作者标签与只有作者标签六类）；`make hap` / `make check` / `git diff --check` 通过。**真机复验**：书架与 DB 中旧行已变为 `name=大唐：李世民求我造反` / `author=天下乐`，`bookId=155886f3`、`added_at=1790260398161` 和第 152 章阅读进度不变；`toc.json` 同步为同名同作者、1441 章。
    ⑧ **2026-10-24 混合书架进度去重并精简（已真机验证）**：用户指出 `检查中 2/3 · 本地书 2 本跳过` 容易被理解为两本正在检查，随后要求继续缩短。`shelfProgressText()` 现只显示网络书进度，本地书仅保留数量：`网络 0/1 · 本地 2`；失败时为 `网络 1/1 · 1 本未检查 · 本地 2`，仅本地书为 `本地 2`，纯网络书架仍为 `检查中 x/y`，结束 toast 口径不变。主机仿真“仅本地书”及混合书架断言全过；真机 `33Z0224424136564` 截图 OCR 确认新进度文案。
  - 未覆盖：release 包未复跑；跨启动不重下需要持久负标记 `cover_*.miss`，**故意不做**（会破坏 `CacheTrim` 的 `cover_` 前缀 + `.img` 后缀扫描 → 变成永不被清理的泄漏），接受「每次启动对该 URL 一次无效请求」；`ImageSource.release()` 未加（无法无截图验证渲染，风险大于收益）。
  - 证据：`rust/legado-engine/src/runtime.rs`（`cover_cache_path` / `looks_like_image` / `download_cover` / tests）、`rust/legado-engine/src/status.rs`、`entry/src/main/ets/components/BookCover.ets`；完整修复说明见 [`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §14。
- [x] **T-SHELF-7（P2）书架「更新」：批量检查所有书籍是否有新章节 —— 2026-10-13 落地并真机验收**（进度 / 两个 toast 分支 / `total` 排除本地书 / 零误写 / 防重入 / 幂等 / 编辑态隐藏，共 13 项，含 **「有新章」分支**（2026-10-13 由一次性调试版真机走通，证据见「验证」④）；同日**收尾小迭代**：进行中进度行显示未检查数，两种形态真机已拍到（见「验证」⑤）；**2026-10-23 修正混合书架分母与无 `lastChapter` 源误报失败，并已完成真机复验（见「验证」⑥）；2026-10-24 修正混合书架进度重复计数（见「验证」⑧）**）。
  - **2026-10-23 修正**：用户反馈书架有 2 本，更新却显示 `检查中 0/1`，随后报「检查失败，请检查网络或书源」。实际一本是 `local://` TXT（应跳过），另一本《中国少了一味药》所在 qwyd 源可用，但源规则没有 `lastChapter`：详情和搜索的章节名都为空，旧逻辑因此把整本书误判为失败。现在进度只统计网络书，本地书显示为 `本地 N`；章节名缺失时按 `info.tocUrl` → 书架 `book.tocUrl` → 搜索命中 `bookUrl` 的顺序拉一次目录，取末个非卷非空章节；全部失败且存在本地书时提示「网络书检查失败」，不再把本地书也算成网络故障。
  需求（用户 2026-10-13 原话：「书架中也需要一个更新的功能（更新所有书籍，查看是否有新章节）」）。
  - **现状（为什么现在看不到）**：书架 `reload()` 只读 DB + 进度、**零网络 I/O**（`pages/Shelf.ets:44-79`，`@Monitor('refreshToken')` 也只是重读 DB）；
    「最新：xxx」/「N章/M章」全靠 Reader 打开书时写入（`refreshToc` 重写 `progress.percent` 分母，见 T-SHELF-6）⇒ **不打开书就永远不动**。
  - **已拍板（2026-10-13，用户选定）**：① 入口 = 书架顶栏标题右侧**独立「更新」按钮**（与 `MoreMenuButton` 并排，`pages/Index.ets:188 shelfNormalHeader`）——
    顶栏改动要过 [`specs/UI-SPEC.md`](../specs/UI-SPEC.md)（间距 / 字号 / 颜色令牌 / 无障碍 `accessibilityText`）；
    ② 探测深度 = **详情优先**（立项时以为 1 请求/书，实际因书架行缺 `bookUrl` 通常变成 **2 请求/书**，见「实现」）；2026-10-23 起只在详情与搜索结果都没有章节名时追加一次目录请求，**不遍历整本目录**；③ 触发 = **仅手动**，不做启动自动检查 / 定时任务。
  - **实现（2026-10-13）**：新 `model/ShelfUpdater.ets`（编排 + 两个导出的纯函数 `chapterKey(title)` / `hasNewChapter(baseline, latest)`）+ `pages/Index.ets` 顶栏入口。
    每本书**通常 2 请求、缺章节名兜底时 3 请求**（`books` 表没有 `bookUrl`，`bookId` 是 `computeBookId` 哈希不可逆，`tocUrl` 在 7/13 个内置源里指的是目录页 ≠ 详情页）：
    `bookEngine.search([source], book.name, {timeoutMs: 6000, concurrency: 1})` → 复用换源的 `isSameBook` 命中拿 `item.bookUrl` → `bookInfo(source, bookUrl)`；
    章节名取详情页优先、回落搜索结果 `item.lastChapter`；两者都为空时再拉一次目录，取末个非卷非空章节。与基线不同 ⇒ 记「有新章」+ `upsertBook` **前移基线**，相同 ⇒ 只计数。
    常量：`SEARCH_TIMEOUT_MS = 6000`（与 T-SWITCH-1 单源超时对齐）、`ENGINE_INFO_TIMEOUT_MS = 15000`、`ENGINE_TOC_TIMEOUT_MS = 45000`、`CHECK_CONCURRENCY = 3`、`CHECK_BUDGET_MS = 90000`；
    返回 `ShelfUpdateOutcome { total, local, checked, failed, skipped, updated: Book[] }`，进度回调 = 起始 `(0,N,0,local)` + 每本结束一次 `(done,N,failed,local)`（第三个参数是**累计**失败数，第四个是本地书数）。
    UI：入口 `shelfUpdateAction()`（`@Builder` **0 参数直读 `@Local`**，与 `deleteAction()` 同形——本文件 §5.3：`@Builder` 传 2+ 参数不动态刷新）插在 `shelfNormalHeader()` 的 `Blank()` 与 `MoreMenuButton` 之间（编辑态不显示）；
    「更新」用 `brand` 令牌 + 44 热区 + `accessibilityText`，进行中显示 `shelfProgressText(done,total,failed,local)`（如 `网络 1/2 · 本地 2`；实现放在 `ShelfUpdater.ets` 的**导出纯函数**里，好让主机仿真能断言字符串）并防重入；结束 toast 统一由 `shelfUpdateResultText(outcome)` 生成，覆盖有新章 / 无新章 / 部分未检查 / 网络书全失败 / 无可检查网络书 / 更新本身异常。
  - **与立项方案不同的三个设计点（复核/实测后改，勿改回去）**：
    ① **基线比较必须走 `cleanChapter` 归一化**，不能直接比字符串：同一本书的同一章在不同位置写法不同——详情页 `第83章 今日无事`、搜索结果/换源 `最新：第83章 今日无事`。
       直接比会把**没更新**的书报成有新章；归一化后**相等但原串不同**时**静默对齐**基线（不回显「有新章」），让下次比较退化成纯字符串相等 ⇒ 幂等。
    ② **无基线（`last_chapter_title` 为空）时不当「有新章」**，而是静默写入当前值**建基线**：否则加书后第一次更新会把**整架书**报成有新章（立项时想的「首轮只提示不落标」同样不落标，但没有基线 ⇒ 每次点击都重复误报，更糟）。
       **保留的已知代价**：加入书架后到第一次更新之间章节变过的书，基线还停在加入那天 ⇒ 会被报成有新章，写一次后即准。
    ③ **单本超时 6s → 15s**：原先 ArkTS 侧用 `Promise` 竞速兜底；2026-10-19 起 `bookInfo` 接受
       `timeoutMs`，`ShelfUpdater` 直接传 `ENGINE_INFO_TIMEOUT_MS = 15s`，由 Rust 对整个详情操作统一计时，
       不再维护竞速定时器。搜索那一步另有 6s 源级预算（Rust 侧 clamp 到 [3s, 20s]）；整轮仍保留 90s 预算。
    **未动的**：不加 `book_url` 列（方案 ②：幂等 ALTER + 3 个写入点 + 存量回填，且 `initShelf` 没有 migration 机制），继续复用 `books.last_chapter_title` 当基线（它只在「加入书架」与「换源」时写入、Reader 的后台重爬不写、全仓无 UI 读它）。
  - **失败语义**：搜索失败 / 没匹配到同一本书 / `bookInfo` 失败 / 单本超时 / 详情、搜索与目录均无章节名 / 书源缺失或停用 ⇒ 一律计 `failed`，**不写库、不动基线、不影响其余书**；本地书不参与网络检查（不计入 `total`，单独计入 `local` 并参与展示分母）；
    整体预算耗尽而未开始的书计 `skipped`（不改基线，下次点击继续）。`updated === 0 && checked === 0`（且 `total > 0`）才提示「检查失败」。
  - **刻意不做**：无条件连目录一起刷（长书每本 10+ 请求，《剑来》13 页 ⇒ 20 本可能上百请求）；2026-10-23 的目录兜底只限详情和搜索都没有章节名的源，每次仍最多额外 1 次请求。每次更新顺带修正「N章/M章」的分母（交给打开书时的 6h 新鲜期逻辑自愈，T-SHELF-6）；后台/定时自动检查。
  - **验证（2026-10-13）**：
    ① **主机侧仿真（已做，可复跑）**：新增 `scripts/shelf-updater-sim.py` —— 从真源码**机械切片**（`common/Format.ets` 的 `AUTHOR_LABELS`/`CHAPTER_LABELS`/`stripLabel`/`cleanAuthor`/`cleanChapter`
       + `model/ShelfUpdater.ets` 去掉 `import` 行的**全文**）+ 只打桩 3 个外部依赖（`bookEngine` / `upsertBook` / `isLocalBook`）→ DevEco 自带 `tsc` 编 JS → `node` 跑断言。
       **被测的是真编排 + 真 `chapterKey`**，没有重写被验逻辑。**断言全通过**（`ALL PASS` / exit 0）：计数（`total`/`checked`/`failed`/`skipped`/`updated`）、本地书排除、基线前移、
       **等价对齐不误报**、**幂等**（连点第二次 0 新章 + 0 写库）、并发上限 ≤ 3（打桩计数 `maxInFlight`）、进度序列（首尾 `0/N`→`N/N`、条数 = N+1）、预算耗尽（deadline 在过去 ⇒ 全部 `skipped`、0 请求 0 写库）、
       书源缺失/停用（`failed`、0 写库）、**搜索 6s / 详情 15s 预算确实传入引擎**（引擎超时仍按单本失败处理，其余书不受影响）。样本字符串取自 `make probe` 真实输出（`第83章 今日无事` vs `最新：第83章 今日无事`）。
       **计数（2026-10-13 收尾小迭代后）**：**30 条**（旧的「27 条」是文档笔误，改前实测 25 条）—— 新增 4 条 `shelfProgressText` 文案形态 + 1 条「失败数必须在**进行中**就上报」的确定性序列（一本搜索 0ms 即败、一本 150ms 才回 ⇒ 期望序列 `检查中 0/2` → `检查中 1/2 · 1 本未检查` → `检查中 2/2 · 1 本未检查`）。
       复跑：`python3 scripts/shelf-updater-sim.py`。
    ② **构建/门禁（已做）**：`make hap` 通过（`make doctor` 显示 signed HAP 10-13 09:25 晚于全部 ets 源）+ `make check` 全绿（TOC / 相对链接 / 混淆 keep：145 名字覆盖全部 JSON 字段，无遗漏；本轮未新增跨 NAPI 或落盘 JSON 字段）。
    ③ **真机验收（2026-10-13 · 设备 `33Z0224424136564` · debug · `make run` 闭环，12 项全部符合预期）**：
       a) **进度 + 本地书排除**：点顶栏「更新」后截图 OCR 得 `检查中 0/2` → `检查中 1/2`；**`total = 2` 而架上有 3 本** ⇒ 本地书《大唐：李世民求我造反》（`source_url = local://`）按设计不计入；
       b) **无新章 + 失败静默**：结束 toast OCR = `没有发现新章节，1 本未检查`；《天堂向左 深圳往右》的源站点已失效 ⇒ 计 `failed`，其 `books.last_chapter_title` **保持空**（不误建基线），《剑来》行不受影响；
       c) **零误写**：整轮反复点击（含失败注入、连点、复跑 6 次以上）后 `hdc file recv` 的 `shelf.db` 与会话开始时**逐列一致**（`select * from books` diff 无输出）；
       d) **防重入**：`uitest uiInput click` 连点两次只出现**一轮**进度 + 一个 toast；
       e) **幂等**：再次点击 ⇒ 同一文案、DB 不变；
       f) **编辑态**：长按书架行进入多选后顶栏为 `全选 / 已选择 1 本书 / 完成`，`dumpLayout` 里 `"text":"更新"` **计数 0**；
       g) **全失败分支**：停用 `bbiquge8` **及其同 URL 孪生** `笔趣阁8`（两者都指 `m.bbiquge8.net`）后点击 ⇒ 截图 OCR 得 `检查失败，请检查网络或书源`（`checked === 0` 分支）；停用源即时计失败（不崩、不写库）；随后把两个开关**恢复为启用**并复跑，行为与注入前一致。
       **读 toast 的手段**：`uitest dumpLayout` **不导出系统 toast 窗口**（逐帧 dump 抓不到），改用 `hdc shell "uitest screenCap -p ..."` 连拍 + 主机 `tesseract -l chi_sim --psm 6` OCR 才拿到文案（`hilog` 里 `uitest/UiTestKit_Server: Capture event: toastShow` 可用于对时）。
    ④ **「有新章」分支真机已走通（2026-10-13）** —— 该分支需要「基线落后于源最新章」的初始状态，两条**常规**注入路径都已证伪：
       ① **沙箱 DB 只读**：`hdc shell "touch .../rdb/x"` 与 `hdc file send` 均 `Permission denied`（读得到、写不了）；
       ② **App 内没有能造出旧基线的路径**：唯一写基线的两处是换源（`SourceSwitch.ets:206`，优先 `info.lastChapterTitle`）与加入书架（`BookDetail.ets:71`，写 `d.lastChapterTitle`）——写的都是**同一个源详情页的值**，而「更新」比对的就是这个值（`BookDetail.ets:297-298` 的「最新：」只是显示层前缀）⇒ 除非站点自己更章，否则必然相等。
       ③ 于是用**一次性调试版**（只在 `ShelfUpdater.probeBook` 里临时插 6 行：`book.name === '剑来'` 时把落库值写成 `latest + ' [T-MARK]'` 并 `return PROBE_SAME`，**比较逻辑不动**）走完，实测四步：
          a. 标记版 `make run` → 点「更新」→ 拉 DB 得 `剑来|第83章 今日无事 [T-MARK]` ⇒ **真机 `upsertBook` 写库路径通**（toast 仍是 `没有发现新章节，1 本未检查`，因为返回 `PROBE_SAME`）；
          b. `git checkout` 还原该文件（`git diff` 干净、`rg T-MARK` 无残留）→ `make run` → 点「更新」→ 截图 OCR 得 **`1 本有新章节`**，DB 基线前移回 `第83章 今日无事` ⇒ 即本条一直缺的真机证据（`chapterKey` 把 `[T-MARK]` 认成新章）；
          c. 紧接着再点一次 → OCR 得 `没有发现新章节，1 本未检查`，且**整库逻辑 diff（`shelf.db` + `-wal` 合并 `.dump`）为空** ⇒ 幂等、0 误写；
          d. 收尾：整库 dump `rg T-MARK` 无残留、书源「13/13 启用」、工作树对该文件干净（`git status` 无该文件）。
       代价与注意：只在**一次性调试版**里改、跑完立即 `git checkout`；`[T-MARK]` 会污染该书基线一次（a 步写的），b 步即被真实比对修正。
    ⑤ **收尾小迭代：进行中进度行显示未检查数（2026-10-13，主机侧 30 断言 + 真机两形态均已验证）** —— 动机：检查中只显示 `检查中 done/total`，失败数要等结束 toast 才知道，而失败的书正是用户最想中途知道的（源失效）。
       改法：进度回调加第三个参数（累计 `failed`）+ 新导出纯函数 `shelfProgressText(done,total,failed)`（`检查中 done/total`，`failed > 0` 时追 ` · N 本未检查`；`total = 0` 时 `检查中…`），`pages/Index.ets` 只把拼串换成调用它（13fp `text_3` / 无新令牌 / 热区与 `accessibilityText` 未动，见 [`specs/UI-SPEC.md`](../specs/UI-SPEC.md) §1.7）。
       口径说明：进行中的 `N 本未检查` **只算已结束的失败书**（`failed`），不含 `skipped`（整体预算耗尽后没开始的书要等所有 lane 收尾才知道）；结束 toast 的 `N 本未检查` 仍是 `failed + skipped`，两者不冲突。
       验证：`python3 scripts/shelf-updater-sim.py` **30 断言 `ALL PASS`** + `make hap` 通过；**真机（2026-10-13，`make run` 闭环，截图连拍 + 主机 `tesseract` OCR）**：
         a. 无失败形态 `检查中 1/2`（`dumpLayout` 实测 `[658,190][869,241]`，宽 211px = 105.5vp）；
         b. 有失败形态 `检查中 1/2 · 1 本未检查` —— 注入方式：停用 `bbiquge8` + 同 URL 孪生 `笔趣阁8`（该源**不请求即计失败**），另一本仍要走网络 ⇒ 失败数在**进行中**就上屏（这正是本迭代的目的；对照：不注入时同一位置只有 `检查中 1/2`）；注入后两个开关已还原，复检「书源（13/13 启用）」；
         c. 该注入轮 DB 无写入（13 轮请求全失败 ⇒ 不该有 `upsertBook`，用 `shelf.db`+`-wal` 合并比对）；
         d. 宽度/截断：以实测字宽外推最长形态 `检查中 20/20 · 19 本未检查` ≈ 550px，可用区间 ≈ 710px（标题右缘 190 → 「更新」按钮左缘 ~900）⇒ 余量 ≈ 160px（~80vp），**未截断**；但该最长形态本身未在真机出现（架上只有 2 本网络书），仍是外推。
    ⑥ **2026-10-23 混合书架与目录兜底修正（已真机验证）**：真实书架证据为 2 本，其中一本 `source_url=local://`，另一本《中国少了一味药》来自 qwyd。主机探针确认该源搜索/详情可用、详情章节名为空、目录 38 章末章为 `第三十七章`。修正后主机仿真 **48 断言 `ALL PASS`**，新增覆盖本地书分母、结束文案、详情缺章名时目录兜底、卷标题跳过、`info.tocUrl` → 书架 `tocUrl` → 搜索 `bookUrl` 三级回退、目录 45s 预算与目录失败不写库；`make hap` 与 `make check` 通过。**真机（设备 `33Z0224424136564` · debug · `make hap` → `make install` → `make restart`）**：首轮截图 OCR 得到 `检查中 1/2 · 本地书 1 本跳过`，结束 toast 为「没有发现新章节，1 本本地书跳过」；DB 中 qwyd 书基线写为 `第三十七章`，本地书行与进度不变；第二次点击后 `shelf.db` 逻辑 `dump` 哈希前后均为 `8c1464d2…` ⇒ 幂等、0 误写。
    ⑦ **2026-10-23 本地 TXT 文件名拆书名/作者（已真机验证）**：本地书架行《大唐：李世民求我造反 作者：天下乐》实际来源为 `local://`，导入时旧逻辑只去扩展名，导致书名残留作者标签，无法得到可搜索的规范书名/作者。新增 `common/Format.ets::splitTitleAuthor()`，只识别尾部 `作者：` / `作者:` / `作家：`（含括号形式），从文件名取作者时优先于正文探测；书架加载时对旧 `local://` 行原地修复，保留 `bookId`、来源、添加时间和进度，并尽力同步本地 `toc.json` 的元数据。仿真增至 **55 断言 `ALL PASS`**（新增全角/半角冒号、括号、无作者、标题中间含“作者”、多个作者标签与只有作者标签六类）；`make hap` / `make check` / `git diff --check` 通过。**真机复验**：书架与 DB 中旧行已变为 `name=大唐：李世民求我造反` / `author=天下乐`，`bookId=155886f3`、`added_at=1790260398161` 和第 152 章阅读进度不变；`toc.json` 同步为同名同作者、1441 章。
  - 涉及文件：新 `model/ShelfUpdater.ets`、`pages/Index.ets`（顶栏入口 + 进度/结果反馈）、新 `scripts/shelf-updater-sim.py`（主机侧仿真）；`bookEngine.search` / `bookInfo`、`isSameBook`、`upsertBook`、`isLocalBook` 均复用既有实现。
  - 未覆盖：~~「有新章」分支的真机写库~~（④，**2026-10-13 已用一次性调试版真机走通**；原「结构性不可造」的判断已被该调试版绕过，两条常规注入路径仍不可用）；release 包未复跑（本轮无新增 JSON 契约 ⇒ 混淆面未变）；**2026-10-23 的本地书分母 / 目录兜底**（⑥，已真机复验）；**本地 TXT 全新导入未重复造书验证**（旧行自愈与 `toc.json` 已真机核对，导入路径复用同一 `splitTitleAuthor()` 且主机断言通过）；书架行内角标（留待下一轮）；**收尾小迭代的进度文案**已真机验证两种形态（⑤），仍未覆盖的只剩最长形态 `检查中 20/20 · 19 本未检查` 的真机渲染（架上书数不够，只有以外推）。
  - 关联：换源会重置该书基线（`SourceSwitch` 写 `lastChapterTitle`）⇒ 换源后的书不会被误报，见 T-SWITCH-1。

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
  - 顺带观察（与本次改动无关）：同一台设备上《大唐：李世民求我造反》打开时目录显示「目录加载失败」——TOC 拉取失败，该路径（`loadToc`/`engine.toc`）**不经过** `fetchContent`。
    **2026-10-11 主机侧定性（未上设备）**：该书源（`小说` / yetianlian.info）目录在 `probe toc` 下**正常返回 1449 条**（页面 30 KB / 0.7 s；设备上该书进度 `153章/1441章` 与本源同源，只是站点又更了 8 章）⇒ **无法复现**「目录加载失败」，**非引擎缺陷**；剩余可能=当时瞬时网络失败/超时，最终定性需设备侧日志。
    主机侧直接不可用的内置源只有 `🎉 蚂蚁阅读`（`network_error`，站点不可达）与 `掌阅小说💯`（`no_results`）；若该书是从这两源加入的，目录必然失败（无设备日志无法排除此分支）。
  - 未覆盖：release 包（不涉混淆面）；TTS 侧 `BookContent.loadChapterParagraphs` 有同型「未命中即打引擎」写法，
    但与阅读页是两条独立调用链、无共享单飞表，本次**不合并**（要合并需引入共享模块，另立任务）。
  - 证据：`pages/Reader.ets`（`inflight` 字段 / `fetchContent` / `fetchRemote`、`prefetch` 已删）、[`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §15

- [x] **T-READ-4（P1）Legado `text.` 前缀未实现 → 目录/正文只取第一页（缺章）**：引擎规则 DSL 只认 `class.` / `id.` / `tag.`，`text.下一页@href` 落到无效 CSS 选择器 → **0 结果 + 无诊断**（静默失败）→ 翻页循环第一页后 `break`。
  - 发现（2026-10-11 · 纯主机侧 `make probe`，未上设备）：内置 13 源里 **9 条规则 / 8 个源**用了 `text.` 前缀 ——
    `ruleToc.nextTocUrl`：爱下书 / bbiquge8 / 笔趣阁8；`ruleContent.nextContentUrl`：小说 / 🔖天堂向左 深圳往右 / 爱下书 / bbiquge8 / 笔趣阁8；`ruleBookInfo.tocUrl`：💯 连尚读书。
  - 决定性证据（《剑来》@ bbiquge8，`info` 报最新章节「第83章 今日无事」）：
    ① 修复前 `toc` = **50 条**（末条「第一卷 笼中雀 第五十章 天行健」），`probe parse text/html 'text.下一页@href'` = **0 个结果 + 无诊断**；
    ② 站点侧目录实为 **≥4 页**（`curl '?page=4'` 已到「第200章」）→ 整本 **1308 章**；
    ③ 修复后同一条命令 = **1308 条**，末条正是「第83章 今日无事」⇒ 翻页一直走到最后一页（`runtime.rs` 的 `MAX_TOC_PAGES=50` / `seen` 去重逻辑本身没错）。
  - 对照实验（证明唯一变量是该前缀）：把爱下书 `ruleToc.nextTocUrl` 置空 → `toc` = **20 条**；规则原样 → **58 条**。正文同理：bbiquge8 首章「(第1/3页)」修复后拼到**第 3/3 页**结尾（`ps3:好久不见，剑来！`）⇒ `nextContentUrl` 生效（修复前只返回第 1 页）。
  - 语义依据（Legado 官方规则说明）：「第一段是类型，如 `class,id,tag,text`…`text` 可以根据文本内容获取」⇒ `text.关键字` = 选取**自身文本包含关键字**的元素（对应 jsoup `:containsOwn`），是真实书源里的常用写法，**不是**坏规则。
  - 修法（Rust，`rust/legado-engine/src/rule_dsl/`）：`parser.rs` 新增 `RuleToken::TextContains` 并**在裸 CSS 兜底之前**判断（否则 `text.下一页` 仍会静默退化成 CSS 选择器）；
    `html_extractor.rs` 新增 `apply_text_filter`（按**直接文本子节点**匹配、ASCII 大小写不敏感、按文档序返回外层 HTML、**排除 fragment 包装节点 `<html>`**，否则关键字命中包装节点会返回整页）。
    JSON 与诊断路径不动：`json_extractor` / `diagnose` 的兜底分支都不会误报。
  - 验证（2026-10-11 · 主机侧，无设备）：`make test` **56 → 58 项全通过**（新增 parser + html_extractor 用例，含「关键字只在子孙里不命中」「命中多个可用 `.n` 取第 n 个」「未命中返回空而不是整页兜底」）；
    `probe search 剑来` 回归 **588 条 / 成功 11-13 与修复前逐源一致**（纯增补，零回归）；`make rust` 交叉编译 `.so` 成功（设备侧可直接用）。
  - **设备侧复验（2026-10-12，真机 `33Z0224424136564`）**：验证换源功能时顺带落地 —— bbiquge8 的《剑来》旧目录缓存（50 条，修复前产物）被换源清理后**重新爬取得 1308 章**（`files/tocs/5b4fad87.json` = 194384 B），书架随之由 `105章/1309章` 变为 `104章/1308章`；渲染的正文也是多页拼接后的完整章。⇒ 该修复已在设备上确认生效（原文“设备侧复跑待设备上线”已了结）。
  - 附带影响：真机书架《剑来》显示的 **`3章/50章`**（T-SHELF-3 三态取证时记下的）就是本源目录只取到第一页所致 —— 目录修好后总章数变为 **1308**。
  - 未覆盖：**设备侧复跑**（`make run` 后打开《剑来》：目录应 >1000 章、正文应一次拉全 3 页）——本轮设备离线（`hdc list targets` = `[Empty]`）；release 包未复跑（纯 Rust 改动，不涉混淆面）。
  - 未修（另一件事，已定性）：💯 连尚读书 `ruleBookInfo.tocUrl = text.目录@href` 在**现行站点**上本就无命中（目录页 HTML 里「目录」二字出现 **0 次**）⇒ 属源规则过期，与本次前缀修复无关（该源目录仍回退 `bookUrl`，可另立源规则更新任务）。
  - 证据：`rust/legado-engine/src/rule_dsl/parser.rs`、`rust/legado-engine/src/rule_dsl/html_extractor.rs`、[`RELEASE-NOTES.md`](./RELEASE-NOTES.md) §17
- [x] **T-SWITCH-1（P1）换源：候选被静默丢掉 + 每轮白等 13 源（2026-10-13，真机已验证）**：真机《剑来》换源只有 1 个候选，且每次打开都要等 13 源全跑完（进度行停在 `已检索 N/13`）。
  主机侧 `probe search 剑来 --json`（13 个内置源 / 560 条）把症状拆成三个独立原因：
  - **① 候选漏判（根因）**：`isSameBook` 用 `normalizeKey` 比作者，而 `normalizeKey` 只删空白、**不认页面标签** ——
    同名 8 条里 `小说` / `黑炎小说` 的 `author` 是 `作者：烽火戏诸侯`，与书架的 `烽火戏诸侯` 不相等 → 被当「另一本书」**静默丢掉**。
    修法：`作者：` / `作家：` / `最新章节：` 前缀清洗收敛到 `common/Format.ets` 的 `stripLabel` / `cleanAuthor` / `cleanChapter` **单点**
    （`SearchResult` 里那份私有副本删除、改 import，避免两处分头漂移），`SourceSwitch.isSameBook` 比作者前先削。
  - **② 同域重复**：`m.bbiquge8.net` 有两条书源（`bbiquge8` / `笔趣阁8`，`bookSourceUrl` 一字不差）——
    `SourceRepository.dedupeByUrl` 只能吃完全同 URL 的；本轮补 `dedupeBySite`（域名 + 搜索模板）兜「同站两个入口」
    （http/https、镜像首页等），候选项也按域名去重（同名 8 条 → 7 行）。
  - **③ 等待时长**：单源超时 **10s → 6s**（13 源实测最慢 2.0s）；新增**全局派发预算 10s** 与**候选够 3 条即收尾**
    （进度行写明原因，并给「继续检索」回头路 —— 提前收尾只是「不再等」，不是「不再要」）；候选结果**会话缓存 30 分钟**
    （同一批书源 + 同一本书重开抽屉直接上屏，右侧给「重新检索」）。
  - **④ 预热（新文件 `model/SourcePrefetch.ets`）**：行一上屏就预热最靠前 2 个候选的 `bookInfo` + `toc`，点「切换」时宿主直接命中
    （原换源链路：`bookInfo` 1.1s + 目录爬取 5.9s = 7s）；其余候选只串行补一次 `bookInfo`，用来把行内文案从
    「该源未提供最新章节」换成「最新：xxx」（原实现恒显占位，因为换源面板不像搜索结果页有详情缓存可回退）。
    只放内存（**不写 `TocCache`**：没被选中的候选不留垃圾），`busy` 变 true（用户点了切换）即停派发 + 清预热队列。
  - **⑤ 设备侧又逮到两个（主机侧静态看代码看不出来的）**：
    - **异步回填的文案不刷新**：`ForEach` 按 key 复用子树，而候选行的 key 只含 `bookSourceUrl + 序号`；`fetchInfo` 回填时只换行内文案 → key 不变 →
      **子树不重建**，行内恒显占位（黑炎小说 / 悠久小说 明明已拿到 `最新：第83章` 却不上屏）。修法：列表 `ForEach` 的 key 追加 chapter
      （`row.key + '|' + row.chapter`），而 `SwitchRow.key` 字段本身保持稳定（预热回填要按它认行）——两者分工写进了 `SourceSwitchPanel` 的注释。
    - **「重新检索」点了没反应**：`startSearch()` 无条件先试 `restoreCache()`，而用户刚打开面板时那份缓存还新鲜 → 重搜被缓存原样命中，
      看起来像按钮失灵（行数 / 文案 / 「重新检索」全都没变）。修法：`startSearch(forceFresh = false)`，按钮走 `startSearch(true)` 绕过缓存。
    - 顺手收口：「继续检索」在 `nextIndex >= sources.length`（12/12 已全部派发）时不再显示 —— 此时无可续，避免死按钮。
  - 文件：`common/Format.ets`、`model/SourcePrefetch.ets`（新）、`model/SourceSwitch.ets`、`components/SourceSwitchPanel.ets`、`pages/SearchResult.ets`。
  - 验证（2026-10-13 · 主机侧，已完成）：`probe search 剑来 --json` 同名 8 条 → 削前缀后**命中 8/8**（修复前 6/8，其中
    `m.bbiquge8.net` 两条源被 `dedupeByUrl` 合成 1 ⇒ **修复前 5 行 / 修复后 7 行**）；`make hap` 通过。
  - **验证（2026-10-13 · 真机，已完成）**：
    - 候选从 **2 行 → 7 行**（13 个内置源 − 同域 1 = 12 源参与检索）；开抽屉 3s 时已上屏 6 行，进度行 `已检索 11-12/12 个书源 · 候选已够用`。
    - 行内回填真的上屏了：`黑炎小说` / `悠久小说` / `玄幻阁` 从「该源未提供最新章节」→「最新：第83章 今日无事」；
      `溜达小说` / `云中书库` 留占位**是对的**（`probe info` 复核：该源详情页本就没有最新章节节点）。
    - 缓存：关抽屉再开 =「上次检索到的 7 个候选」秒上屏（含回填文案），当前源行仍正确标记；点「重新检索」确实重跑（行清空 → 重新累积）。
    - 切换耗时：预热命中 **≤1s**（原链路 `bookInfo` 1.1s + 目录 5.9s = 7s）；`bbiquge8 ↔ 小说` 往返切换后书架进度 `104章/1308章` 未丢。
    - 留一条未解释的观测（不阻塞收尾）：曾有一次从 `bbiquge8` 切到 `小说` 后重开抽屉，7 行**全无「当前」标记**（`currentSourceUrl` 不匹配任何行 URL）；
      随后三次复现（含再切 `悠久小说` / 切回 `bbiquge8`）都正常、日志逐行 `eq=Y`，故本轮按一次性现象记录，复现时再看 `SourceSwitchPanel` 的 `@Monitor('runToken')` 与 `@Param currentSourceUrl` 的时序。
  - **后续可选（2026-10-19 已实现，主机侧待真机）**：当前源若本轮检索未命中（例：一次真机运行里 `bbiquge8` 单源瞬时超时，而主机 `probe` 同刻正常），
    抽屉会在检索结束后固定补一行「当前源名 + 本轮检索未返回当前源 + 当前」（不可点）。该行只在没有 `current` 候选时出现，
    **不计入候选数、不显示「切换」**；`currentSourceName` 为空或仍在检索时不占位。
  - **加载优化（2026-10-19 已实现，主机侧待真机）**：书架刷新与「更新」原先逐书源串行 `getSource()`；现按去重后的
    书源 id 一次调用 `sourcesForEngine(ids)`，并把 `getBooks()` / `getAllProgress()` 的列下标解析移出逐行循环。
    同 URL 孪生源继续优先取启用行，书架条目与返回顺序不变。

- [x] **T-READ-5（P1）长章节首屏冻结（真机实证，已修）**：打开《剑来》第 25 章要 **5s 才出字**，系统日志同时刻出现
  `WMSMain OnVsyncTimeOut` + `Vsync PrintRequestTs: recv vsync timeout ... timeInterval:2630443928ns`（= **单帧 2.63s**）。
  - **根因（两支）**：
    ① **书源规则**：内置 `小说`（yetianlian.info）的 `ruleContent.nextContentUrl = text.下一章@href` —— `nextContentUrl` 的语义是
    「**本章**正文分页的下一页」，而 `text.下一章` 匹配的是**下一章**的链接。引擎 `content_inner` 会顺着它追到 `MAX_PAGES = 30`
    并**全部拼进同一章**，于是每章 = 30 章正文（设备侧章节缓存 `4b445f13_25.json` = **394KB / 133,983 字 / 2405 段**，内嵌
    `649743..649772` 共 30 个链接；相邻章**重复 29 章**，ch26 首句出现在 ch25 第 71 行），换一章还要顺序发 30 个 HTTP 请求。
    站点每页正文实测 ~4.3k 字，`div#content.showtxt` 已是完整一章，**该站根本没有分页** ⇒ 该规则纯属多余。
    ② **分页算法**：长章节下 `rebuildWindow` 要同时排 上/本/下 三章全部页流（413 页 / 6674 次 `measureTextSize` / 604ms），
    且暖载邻章回来后 `warmNeighbors` 再整体重建一次（1244 页 / 19,978 次 measure / **1942ms**，其中约 600ms 是把本章重排一遍的纯重复劳动）。
    ⇒ 这是「规则错得更狠时也不会冻」的兜底缺口，与 ① 分开修。
  - 修法：① 删掉该源 `ruleContent.nextContentUrl`（主机 `probe` 复核：`正文：4305 字，nextUrl=（无）`）；
    ② `Reader.paginateChapter` 结果按章缓存（`pageCache` / `chapterPages` / `layoutKey`，排版参数 = 宽 × 高 @ 字号 / 行距，任一变化整体失效；
    `resetContentState` 与 `applyChapter` 同步清理）—— 只这一处就把「本章排两遍」降成排一遍；
    ③ Swiper 内 `ForEach` → `LazyForEach`（新 `common/PageDataSource.ets`，`PageSeg` 抽到 `common/PageSeg.ets`），其余页不实例化。
  - **真机验证（2026-10-30 · 设备 `33Z0224424136564` · debug · `make run`）**：修复前 `rebuildWindow pages=413 measures=6674
    measureMs=604` + `(from warmNeighbors) 1942ms`、**vsync timeout 1 次 / 2630ms**；修复后首屏 `pages=14 measures=209 measureMs=27`、
    暖载后 `pages=52 measures=548 measureMs=209`、**vsync timeout 0 次**。缓存生效的直接证据：同一章因邻章 warm 而重排时，
    短章从 `pages=7 measures=94 → pages=21 measures=210` 变为 `pages=15 measures=0 → pages=23 measures=134`（**0 次重测**）；
    字号 18→20 连按两次只测 362 / 425 次（无缓存时单章约 2000 次）。章内时间线：toc 4ms / refreshDownloadState 32ms /
    fetchContent 657ms / sanitize 2ms / 首次排版 27ms，全部就绪 **0.77s**。
  - 未覆盖：剩余 ~4s 在转场与「迁移列表」判定（该源目录已被站点重排，`index 25` 现是「第十四章 五月初五」，迁移在解析**旧**快照），
    属另一条链路，本轮不动；release 包未复跑（不涉混淆面，无新增 JSON 字段 ⇒ 未动 keep 列表）。
  - 顺带记录（未修）：该源目录后半段是 `第84章 / 第83章 / 第82章 …` 倒序，疑似站点目录分页本身倒排（`tocs/4b445f13.json` 1321
    条目首尾可见），与本次冻结无关。
  - 证据：`entry/src/main/resources/rawfile/bundled-sources.json`（`小说` 源 `ruleContent`）、`rust/legado-engine/src/runtime.rs`
    `content_inner`（`MAX_PAGES` 追链循环）、`entry/src/main/ets/pages/Reader.ets`（`pageCache` / `chapterPages` / `layoutKey` /
    `contentPager`）、`entry/src/main/ets/common/PageDataSource.ets`、`entry/src/main/ets/common/PageSeg.ets`

- [x] **T-READ-6（P2）目录正/倒序切换把抽屉整个重挂载（重播开启动画）**：阅读页打开目录后点「正序/倒序」，抽屉会消失再从底部上滑一次（**用户 2026-11-02 反馈**：「点正序/倒序会触发重新打开抽屉」）。
  - 根因（两层）：① `Reader.build()` 用 `if (this.tocDescending) { BottomDrawer(...) } else { BottomDrawer(...) }` **两个分支**挂载同一个目录抽屉（`bd2a343` → `0eb1e1c`，为绕过 V2 下 `@BuilderParam` 内容不随父组件普通 `@Local` 重跑）；② ArkUI 的 `if/else` 是**结构性**节点 —— 条件翻转 = 旧分支销毁 + 新分支新建，新实例的 `@Local`（`overlayShown` / `panelShown` / `panelHeight` / `panelMeasured`）全部复位，而 `visible: this.panel === PANEL_TOC` **仍为 `true`** ⇒ `aboutToAppear()` 直接 `openOverlay()`，从 `panelSlideOut()` 重播 `OVERLAY_OPEN_MS = 260ms` 上滑动画；旧实例的 `visible` 从未变成 `false` ⇒ 连关闭动画都没有（观感 = 面板闪一下再滑上来）。
  - 修法（一处状态源）：`pages/Reader.ets` 恢复**单处常驻挂载** + 新增 `@Local tocContentRevision`，`toggleTocOrder()` 改序后自增；`ui/common/BottomDrawer.ets` 新增 `@Param contentRevision`，并在内容区读取它（`contentArea()` 的 `padding.top`，恒为 `contentRevision * 0`）登记依赖 ⇒ revision 变化时抽屉**原地**重渲染，`content()` 重跑（表头「正序/倒序」+ LazyForEach 重键），`overlayShown` / `panelHeight` 保留、无动画重播。列表顺序仍由 `buildTocItems()` 的 `setItems()`（`onDataReloaded`）负责，与该参数无关。
  - 验证（主机侧 2026-11-02）：`make hap` **BUILD SUCCESSFUL in 19s**（`.hvigor/outputs/build-logs/build.log`），`Reader.ets` / `BottomDrawer.ets` 无新增 ArkTS 告警。转译产物直证机制 —— `…/esmodule/debug/…/pages/Reader.ts` 目录抽屉只剩**一处** `BottomDrawer(this, {… contentRevision: this.tocContentRevision …})`，父侧更新走 `updateStateVarsOfChildByElmtId`；`…/ui/common/BottomDrawer.ts` 的 `contentArea()` 里 `this.content.bind(this)()` 在 `observeComponentCreation2` **之外**无条件执行 ⇒ 组件重渲染必然重跑内容 builder。`scripts/check-keep-props` / `check-hilog-format` / `check-source-consumers` / `check-t16-bench` 全 ✓（`make check` 仍因**既有** `docs/research/BOOKSOURCE-REVAMP-TODO.md` 指向已过期的 `/tmp` 证据文件而失败，与本改动无关）；调用点计数 8 → 7（UI-SPEC §2 同步）。
  - **真机验证（2026-11-02 · 设备 `33Z0224424136564` · debug · `make run` 强制重编后安装）**：打开《剑来》→ 目录抽屉打开（`正序`）→ 点「正序」：
    ① **标签原地翻转**：`正序` → `倒序`，且两次切换（正→倒→正）该 Text 的 `accessibilityId` **恒为 136**（未重建）；
    ② **抽屉宿主未重建**：抽屉根链 `Stack 114 → Column 116/118/119/123/124 → Row 131 / List 137` 在切换前后 elmtId **完全一致**；
    ③ **列表顺序确实翻转**：`第84章…第73章 → 第一章/第二章` ⇄ `第二章/第一章 → 第73章…`（切回后复原）；
    ④ **切换瞬间无可视重开动画**：点击前后连拍 16 帧（`uitest screenCap`，约 0.5s/帧，点击落在第 2–3 帧之间）逐帧 OCR —— `f01/f02` = `正序`、`f03–f16` = `倒序`，**每一帧都能读到抽屉表头的「定位」**，且没有任何一帧读到只属于正文的段落文字（如「幽冥剑」「陈非凡」）⇒ 面板从未消失或上滑；
    ⑤ 收尾：点遮罩可关闭（`定位` 消失、正文回归）、关闭后页面仍可点击（再点中央顶栏章节名 `第80章 一一风荷举` + 进度条出现）；`make log` 无 JSCRASH/应用级 error（仅一条既有 `AceTheme … slider_pixels_per_inch` 警告）。
  - 未覆盖：release 包未复跑（不涉混淆面，无新增 JSON 字段 ⇒ 未动 keep）；下拉拖拽关闭未在切换后单独复验（该手势路径未改）。
  - 证据：`entry/src/main/ets/pages/Reader.ets`（`tocDescending` / `tocContentRevision` / `toggleTocOrder` / `buildTocItems` / `build()` 目录抽屉调用点）、`entry/src/main/ets/ui/common/BottomDrawer.ets`（`contentRevision` / `contentArea` / `aboutToAppear` / `openOverlay` / `OVERLAY_OPEN_MS`）、`docs/specs/UI-SPEC.md` §1.1「内容刷新」/ §2 / §3。

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
    同期发现**即使换成表里有名字的原神 sid，CER 也反而更差**（见 [`../research/TTS-VOICE-SOURCES.md`](../research/TTS-VOICE-SOURCES.md) §3；原任务 T-TTS-6 已于 2026-10-11 按要求移除，见文首第十八次同步）。音色名目前只是**标签**，不代表真实角色。
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
  - **进度（2026-10-11）**：
    - ② **已改**：`RemoteTtsClient.ets` `readTimeout=120000`（`connectTimeout` 仍 5000）；实测最坏单请求 wall ≈46s，余量充足。
    - ③ **已改**：`TTS_REMOTE_VOICE_OPTIONS=['刻晴','甘雨','胡桃','钟离','雷电将军']`、`TTS_REMOTE_VOICE_DEFAULT='钟离'`（用户选定）；
      新增 `REMOTE_VOICE_RENAMES` + `normalizeRemoteVoice()`：老设备上的 `流萤/花火/卡芙卡` 在 `loadPrefs` / 设置页读取时归一（**不写回 pref**，避免多余写盘）。
      ⚠️ 音色名只是**标签**（见上文 sid 空洞号更正），用户是按 F0 选默认值的，不是按角色名。
    - 语速（④的前提）**改为客户端下发**：`remoteSynthesize(..., speed)` → 服务端 `speed = clamp(client,0.5,2.0) × SPEED_SCALE`。
      客户端 `setSpeed()` 新增远端分支：起播中改档 → `clearInflight()` + `ensureSynthesized()` 让新档位立刻生效（远端没有 `engine`，旧分支原本空转）。
    - ④ **起点值 0.75**（已部署到 VPS 并写入 `server/tts.service` 默认值）：实测有效语速下 **5.2 字/秒**，与客户端 `CHARS_PER_SECOND=5` 的时长估算碰巧吻合。
      **终值待用户听感**（试听包 `~/Desktop/tts-abtest-tts5/`：同一段文字在 App 1.0x 档位下分别对应 SPEED_SCALE 0.75 / 0.85 / 1.00 三个 wav）。
    - **已决（2026-10-11，用户拍板）· 远端语速上限**：本机（4C）每字合成成本 ≈ 0.13–0.16s，有效语速 1.5 时播放仅需 0.136 s/字 →
      **RTF≈1.2**，即 App 1.5x / 2.0x 档会断续。现新增 `TTS_REMOTE_SPEED_MAX = 1.2`（× 0.75 = 有效 0.9，留 1.4× 余量）：
      `Const.ets::effectiveSpeed()` 在下发前夹取，听书页 1.5x/2.0x 菜单项 `enabled=false`、设置页档位置灰；
      系统 TTS 不受影响（仍 5 档全开）。详见 [`../remote-tts-deploy.md`](../remote-tts-deploy.md) §0。
    - **已决（2026-10-11，用户拍板）· 回退不落盘**：`fallbackToSystem()` 不再 `putNumber(KEY_TTS_ENGINE)`，
      只在**本次会话**内改用系统 TTS（Toast 文案同步为「远端合成失败，本次已切换回系统 TTS」），
      pref 保留「远端」⇒ 下次听书自动重试。
  - **验证（2026-10-11 真机 `33Z0224424136564` · debug HAP · `make run`）**：
    - 修复前复现：App 2.0x 播《剑来》第四章时服务端 `ZeroDivisionError`（curl 直连复现：`：`/`“`/`”`/`——` 全部 500、`…` 正常）→ App 日志 `remote synth failed para=3` → `falling back to system TTS` → 重建 16k 系统引擎 → 之后一直 `remoteVoice` 失效。
    - 修复后：`_synth_vits` 跳过 `sample_rate<=0` 的分段（日志 `drop unspeakable segment`），整段无字时回 320ms 静音（HTTP 200）；`_resample_fft` 对 `sr_in<=0` 加硬护栏。
    - 修复后端到端复跑（同一章）：`start para=7` → `play 8/9/10/11` 连续推进 67s，**0 次回退**、0 error；服务端 `speed=1.500`（App 2.0x）与 `speed=0.750`（App 1.0x 改档后立刻生效）都对得上 ⇒ **语速下发 + 改档即时生效 + 标点修复**三项同时成立。
    - 音色改名与归一：设备 pref 里残留 `tts_remote_voice=流萤` → 界面显示「远端音色 · 甘雨」，播放请求 `voice=甘雨`（服务端日志确认）。
    - 服务端 5 音色逐个 `POST /tts` 均 200 / 24kHz mono 16bit（样本 378–449 KB）；`/health` 返回 `speed_scale=0.75` + 5 个新名。
    - **未覆盖**：真机上 5 音色的**逐个切换**（走到一半设备掉线，`uitest` 命令只回 `need connect-key`）；听感结论本身需要用户耳朵。
- [x] **T-TTS-7（P1）TTS 预生成：服务端内容寻址缓存 + job worker（阶段一）** —— **2026-10-13 阶段一已实现并 7/7 验收通过**；**阶段二（客户端接入）同日实现；2026-10-14 真机贯通**（缓存章 24 kHz 命中 / 跨章 16k↔24k 双向重建 / 未算完退实时 / 听完即删 + 自动续章 均已拍到；剩拖动·变速逐项拍照、锁屏、`expired` 分支、Wi-Fi 门禁取证）。**2026-10-15 键↔章对齐已真机验证通过**（job `6ad0e8ad36e7fb`：服务端回显 title 与设备 sidecar 逐条对上，worker 合成文本 = 该章正文）。**2026-10-14 又修两个真 bug**：① 缓存章拖动 seek 折字节未**帧对齐**（16 bit mono 落奇数字节 = 采样高低字节互换 ⇒ 整章白噪）→ `model/PregAudioSource.ets::pregSeekBytes`；② `storePregKeys` 曾按**下标**对齐服务端响应，而服务端 `create_job` 把已 ready 的条目排前面 ⇒ 键张冠李戴（缓存章读出别章正文）→ 改 `matchPregKeys` **按 title 配对**（仿真 104/104）。**2026-10-16 听感验收通过**：缓存章内 1.5x ↔ 1.0x 来回拖动**无白噪 / 无爆音**、「听到的正文 == 屏上章」✓（bug ① 主观闭环；bug ② 主观 + 客观闭环）⇒ 剩 `expired` 分支、锁屏、Wi-Fi 门禁 `ip route` 取证、拖动逐项拍照；**新增打磨项（P2）**：拖动体感「重复 + 顿挫」= 段落粒度滑杆（`step: 1`）落点即段首 + 重启整段 flush 掉旧字节，详见顶部第三十三次同步。
  - 目标（用户原话）：VPS 空闲时批量预生成 50–100（或更多）章的音频，**听书优先读缓存音频、读不到才用默认 TTS**。
  - **决策（同日用户拍板）**：① 默认引擎 **GPT-SoVITS v2ProPlus（流萤微调）** —— 试听后判定「`cut5` + `fragment_interval=0.3` 这个听着效果比较好」；
    ② 缓存 **WAV 直出（24 kHz mono S16LE）+ 严格淘汰**（已播放优先删、**未播放项受保护**）；③ 素材**先手动喂**（curl），客户端入口后置（阶段二）。
  - **实测前提**（VPS 4C Xeon / 3.9 G + 6 G swap）：整章 8741 字 = 6 块 / 音频 **1802.5 s（30.0 min）** / 合成 **9992.4 s（2.78 h）** / **RTF 5.57** / 常驻 **3.29 GB**（HWM 3.65）
    ⇒ 一章 3000 字 ≈ **57 min 算力 / 9.8 min 音频 / 31 MB**，100 章 ≈ **95 h + 3.1 GB**；`v4`（钟离_ZH）RTF **115.3** ⇒ CPU 不可用；零样本底座 5.86–7.17（花火/卡芙卡）。
  - **硬约束**：**磁盘**（`/` 只剩 **1.2 G**，需先回收 ~1.5 G 无风险项，100 章装不下 ⇒ 靠「听完即删」+ 窗口）与**内存**（worker 3.3 GB 与线上 VITS 抢；
    跑批时 `Mem available` 100–190 MB / swap 4.9 GB，线上 `/health` 仍 0.5 s 但**首个 `/tts` 要等引擎页换入**）。
  - **施工图**：**`../research/TTS-PREGEN-IMPL.md`**（§1 数据契约 / §2 服务端 / §2.5 磁盘 / §3 App 侧「填写方式」/ §4 验收 / §6 下个 session 的 prompt）；
    判据改写与实测明细 `../research/TTS-PREGEN-PLAN.md`；决策 `../decisions.md` **D15**。
  - **阶段一实现（2026-10-13）**：`server/tts_cache.py`（键/布局/状态机/淘汰，纯 stdlib）+ `server/job_worker.py`（**独立进程**，`import gsv_batch.synth_native` 作唯一口径；单 worker 单音色，音色不匹配的条目**判失败不串音色**；超长段句末切开的安全阀）+ `app.py` 6 个新端点 + `tts-job.service`（**disabled**）+ `pregen_test.py` + `deploy.sh`。
    队列=文件系统（`new→run→done|fail` 靠 `rename(2)`），`run/` 靠 mtime 心跳做 stale 重排（attempts ≥3 判失败）；未播放项受保护、全被保护时 `409 cache_full_wait_playback`。
  - **阶段一验收（主机侧 curl，不上设备）**：7/7 已执行，结果与偏差见 [`../research/TTS-PREGEN-IMPL.md`](../research/TTS-PREGEN-IMPL.md) **§4.1.1**（含整章 7 块而非 6 块的解释、RTF 6.76 实测）。
  - **阶段二实现（2026-10-13，同日）**：听书设置新增「预生成」分组（音色 `流萤/花火/卡芙卡`、章数 `5/10/20/30`、仅 Wi-Fi、**缓存优先播放**）+
    听书页「预生成」行（开始 / 停止查看 / 重试失败 + `done/total` 进度 + 失败章清单）+ `TtsController` **章级原子切换**（进章取 `pregKey` → `GET /audio/{key}` 整章落盘 → 渲染器直接喂文件、`setSpeed` 变速、
    块锚点（`chunks[].p0/p1`）重建时间轴、**出声那一刻锁路线**、听完 `DELETE /cache/{key}` + 删本地 + 抹 `pregKey`、下一章后台预取）。
    - 文件：新 `model/TtsPregen.ets`（契约 + 纯函数 + HTTP）、`model/TtsPregenRunner.ets`（进程级单例跟踪器，5 s 轮询）、`model/PregAudioSource.ets`（WAV → 24 kHz S16LE 读盘 + seek）；
      改 `model/TtsController.ets`、`model/ChapterCache.ets`（`pregKey`）、`pages/Listening.ets`、`pages/ListeningSettings.ets`、`entry/obfuscation-rules.txt`（+27 keep 名）。
    - **已验证（静态）**：`make hap` 成功；`scripts/check-keep-props.sh` ✓ 172 keep 名覆盖全部 JSON 字段（`pregKey` 与 30 个预生成字段全在）；
      **主机仿真 `make test-pregen` 87/87 通过**（`scripts/tts-pregen-sim.py`：真源码机械切片 + `tsc` + `node`，含路由真值表 / 时间轴边界 / 倍速夹取 / 文案形态；条数从 88 降 87 = D17 把路由真值表由 5 条收到 4 条、另加一条 Python 侧回归门）。
    - **真机（2026-10-13 夜，首轮）**：① 系统 TTS 实时（16 kHz）✓；② 听书页/设置页 UI ✓；③ 缓存章 24 kHz / 跨章 16k↔24k / 拖动变速 / 听完即删 **未跑**（提交被「仅 Wi-Fi」门禁拦下，且真缓存与设备章节的 key 对不上）—— 详情与卡点判断见顶部**第二十八次同步**。
    - [ ] **打磨项（P2，2026-10-16 登记）**：缓存章**拖动体感「重复 + 顿挫」** —— 段落粒度滑杆（`step: 1`）落点即段首（来回拖必重听整段，设计使然）+ 重启 `pause → flush → start` 丢掉渲染器里排队的旧字节（一小段静音）。**不是 bug①（白噪已修）**；要更丝滑需「滑杆改连续（段内精确 seek）」或「压缩 flush 静默窗口」。详见顶部第三十三次同步。
      仿真还抓出一处真 bug 并已修：`pregSummary` 原来只把 `state=failed` 计入失败清单，`expired` 只进计数 ⇒ 服务端只有过期项时界面显示「重试失败」但点下去 `failures` 为空、直接 `return`（按钮死掉）。
      修法：`expired` 一并进清单（给默认原因「已过期（服务器已清理）」），进度行「失败 n」改为 `failed + expired`（与按钮判据一致）。
    - **未验证（真机，设备未连）**：IMPL §4.2 六项 —— 缓存章整章播放 / 拖动进度与段落高亮对齐 / 变速 / 未就绪章退实时且**不半章换声线** / 听完 `audio/` 与 `pregKey` 被清 / 锁屏与后台。
    - 已知取舍（接受）：实时链路是 VITS 的 5 个标签音色 vs 预生成是 GSV 的 3 个 ⇒ **跨章换声线**（同章内不换），默认建议实时 `甘雨`/预生成 `流萤`；「听完即删」⇒ **重听同一章要重新生成或退回实时**。

## 书源管理（BookSourceManage）

- [x] **T-SRC-4（2026-11-02）书源管理改版：单一主体（书源列表）+ 检测任务态**：撤掉搜索框、筛选 chips
  （全部/启用/停用/未测/失败）、分组选择器、`书源/检测` 分段、底部作业条与检测结果面；页面级动作
  （导入·文件/链接、导出、检测·增量/全部、规则调试器、恢复内置）全部收进页内头行单一 `⋯`，范围与
  计数写进菜单项（`检测书源（增量 N）` / `全部重测（M）`）。检测改为任务态：进行中整页只剩进度卡，
  结束后原地变摘要 +「返回书源列表」，失败源靠三档排序浮到列表最前；关闭/删除不可用搬到摘要卡
  （仍走 `setEnabledMany` / `removeMany` 批量事务 + 二次确认）；空态给「导入书源」主按钮。
  - 文件：改 `pages/BookSourceManage.ets`、`components/SourceRows.ets`（删 `sourceRowMatchesQuery`）；
    新 `components/DetectProgressCard.ets`；删 `components/DetectPanel.ets`。`BottomDrawer` 仍 8 处、无新路由。
  - 规范：[`../specs/SPEC-BOOKSOURCE-LAYOUT.md`](../specs/SPEC-BOOKSOURCE-LAYOUT.md) §3 / §7（改版理由与
    已知代价：3000 条下无搜索、无筛选，只能滚动查找；恢复的最小形态是头行加搜索图标）。
  - 状态（2026-11-02）：**主机侧 + 真机均通过**。`make hap` 通过；`check-keep-props` /
    `check-hilog-format` / `check-source-consumers` / `check-t16-bench` 通过；编译产物已确认含新代码、
    旧符号归零。真机（debug `33Z0224424136564`）：常态 = 头行 + 列表（反例扫描 0 命中）；`⋯` 菜单 7 项
    （debug 8 项）且 `检测书源（增量 2）`/`全部重测（13）` 计数正确；检测后整页只剩进度卡
    （运行 / 完成 / 取消三态均取证）；「返回书源列表」回到列表；hilog 无 JS/ArkTS 异常。
    顺带修真机暴露的一处布局抖动：取消后 `canResume` 约 1s 才转真，原按它切换「单按钮 ↔ 双按钮」会让
    按钮位置跳动；改为 `cancelled` / `failed` 固定双按钮 + 置灰「继续本轮」。
  - 证据：`pages/BookSourceManage.ets`（`moreMenuItems` / `startDetect` / `detectBody`）、
    `components/DetectProgressCard.ets`；改版记载见 [`../progress.md`](../progress.md) §「2026-11-02 布局改版」。

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
- [x] **T-SRC-3（P2）规则调试器：未支持的前缀 / 后缀没有任何诊断（静默失败）**：`diagnose` 曾只校验 CSS 语法 / 正则编译 / JS 规则，对**已确认未实现的 Legado 前缀与尾缀**（`xpath.`、`children.`、`ownText`、`all`）不发提示 —— T-READ-4（`text.` 前缀静态下降 = 8/13 源目录缺章）就藏在这里。
  - 状态（2026-10-19）：**已实现，主机侧验证通过**。`children.` 与 `xpath.` 作为显式未支持 locator namespace；`@ownText`、`@all` 作为显式未支持 annotation，均产生 `kind: "unsupported"` 诊断。
  - 边界：**不把任意 `tag.class` 一律当未知 namespace**（`span.last`、`div#content.showtxt`、`.item` 等都是合法 CSS）；未知写法若 CSS 本身非法，仍由 CSS 诊断兜底。合法但 0 结果仍不报错。
  - 回归：`make test` **73 passed, 0 failed**；新增 `test_diagnose_known_legado_gaps` 与 `test_diagnose_keeps_valid_dotted_css_selectors`，另保留 `valid-zero-results` 用例。
  - 本轮（2026-10-11）`probe parse` 实测矩阵（text/html，同一份 bbiquge8 目录页 HTML）：`class.ptm-list-view-cell@tag.a@text` = 50 结果/无诊断（正常）；`@css:div.nope@text` = 0 结果/无诊断（合法选择器未命中，**不应报错**）；`class.not-exist-xyz@text` = 0 结果/无诊断（同上）；`css.#no-such-id@text` = **有**诊断 `CSS 选择器解析失败`（因为合法写法是 `@css:`，`css.` 是未知前缀，恰好因 CSS 解析失败才被抓到）；修复前的 `text.下一页@href` = **0 结果 + 无诊断**（静默）。
  - 修法（已实施）：已知 Legacy namespace / annotation 在 parser 层标成 `RuleToken::Unsupported`，由 `diagnose` 统一输出；**不**对「0 结果」告警（选择器合法但未命中是正常情况）。
  - 数据面已核对（主机侧）：`pages/RuleDebugger.ets:46` 调 `bookEngine.parseWithDiagnostics` → Rust `parse_with_diagnostics` ⇒ 与 `make probe ARGS='… parse <ct> <rule>'` **同一条链路**；仅 UI 渲染未验（设备离线）。
  - 证据：`rust/legado-engine/src/rule_dsl/mod.rs`（`diagnose`）、`pages/RuleDebugger.ets:46`
- [x] **T-SRC-2 检测并发/超时**：确认 `detect`（并发 4）无源级串扰，`busy` 态防重入。
  - 证据：`pages/BookSourceManage.ets:200-222`
- [x] **书源管理批量操作不再逐行提交（2026-10-19，主机侧）**：关闭不可用源、删除不可用源原先在循环里
  逐条 `await setEnabled()` / `remove()`；现在先收集稳定 id，再分别走 `setEnabledMany()` / `removeMany()`。
  两个函数内部去重非法 id、每 400 个一组 `IN (...)`，整批共用一个事务；行内单条开关仍走单行接口。
  - 证据：`pages/BookSourceManage.ets`（`disableUnavailable` / `deleteUnavailable`）、`model/SourceStore.ets`
  - 检测作业：`DetectJobRunner.runBatch()` 每批 JSONL append 后一次 `patchDetects()`；`recoverRunning()`
    每个重放批次一次事务回写，批次间仍检查取消状态。

## 数据管理（缓存 / 备份，M6）

- [x] **T-DATA-1（R4/R5）封面缓存读穿**：`BookCover.load` 先查 `ctx.cacheDir/cover_{hash}` 是否已存在（或加内存 PixelMap 缓存），避免重复下载。
  - 证据：`components/BookCover.ets:22-39`、`rust/legado-engine/src/runtime.rs:653-658`
  - 2026-10-19 补强：模块级 `inflightLoads` 按 `cacheDir + coverUrl` 单飞**整段下载 + 解码**，同一封面同时出现在书架 / 搜索 / 详情时只执行一次；
    成功结果进入既有 PixelMap LRU，失败仍进入 `failedCache` 且任务落定即出表。主机侧编译通过，真机并发渲染待验。
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
  - **2026-10-19 事务收尾**：`replaceShelf()` 的清表与全量重建现共用一个事务，任何一行写入失败都回滚；
    进度行仍直接插入以保持 RESTORE 语义。`removeBooks()` 同样改为单事务分块删除 `books` / `progress`，
    提交后才清 `lastWriteAt` / `ProgressOwner`。设备连接后需抽查导入失败回滚与批量删书耗时。
    主机侧 `make test` 73 passed、`make test-pregen` 114 条、`make test-detect` 135 条、
    `scripts/shelf-updater-sim.py` ALL PASS，`make native-fresh` / `make check` / `make hap` 通过。
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
