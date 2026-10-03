# HANDOFF-S10 — 阅读页横向分页翻页 + 跨章连续滑动（含全部踩坑记录）

日期：2026-10-04
范围：**仅阅读页翻页逻辑** —— 竖向滚动改横向分页、跨章连续滑动、末页闪烁修复。
基线：未提交（见 §7）。

> 本文件是「阅读页翻页改造」这一长线任务的完整交接：起因、需求拍板、架构演进、
> 每一步踩到的坑、当前代码精确状态、以及一个可直接喂给新 Session 的 prompt（§8）。

---

## 0. 需求结论（用户多次拍板，勿改）

1. 阅读页由「竖向滚动」改为「横向分页翻页」，像华为阅读/微信读书。
2. 翻页模式（与手势无关）：
   - **单手模式**：左右点击都是「下一页」，中间窄条呼出菜单。
   - **非单手模式**：左侧 1/3 上一页，中间 1/3 呼菜单，右侧 1/3 下一页。
3. 手势（两组模式通用）：**左滑=下一页，右滑=上一页**（标准方向；否定了字面写的「左滑=上一页」）。
4. 页的定义：**简化分块翻页**（按字号+屏高估算，横向 Swiper，不保证每页恰好铺满）。
5. 跨章：要求**连续滑动**（滑过本章最后一页自然进入下一章第一页，反之亦然），
   而非「突然跳转」；用户明确选了「完整连续滑动（推荐）」方案，接受改动较大、风险中等。
6. 「单手翻页」开关保留在阅读页底部「阅读设置」抽屉里，与「设置 Tab → 阅读设置」的 Switch 共享
   `KEY_READER_ONE_HAND_PAGE`（`reader_one_hand_page`）持久化 key，两处联动。

---

## 1. 核心架构决策与演进

### 1.1 从竖向滚动到横向分页
原 `Reader.ets` 是竖向 `List`（段落列表），点击只是翻章，无「页」概念。改为 `Swiper` + 分页。

### 1.2 分页 = 测字精确测量（不是估算）
- 用 `@ohos.measure` 的 `measureTextSize` 精确测量每段文本在「可用宽度」约束下的换行高度。
- 推荐非弃用路径：`this.getUIContext().getMeasureUtils().measureTextSize(options): SizeOptions`。
- 返回 `{ width, height }`，单位 **px**；带 `constraintWidth` 时自动换行、返回换行后高度。

### 1.3 跨章连续滑动 = 「上一章+本章+下一章」扁平页流
- `pages` 从「单章页数组」改为「三章扁平页流」：`[上一章末页..] + [本章全部页] + [下一章首页..]`。
- 每段 `PageSeg` 携带 `chapterIndex`（所属章下标）以回取对应章段落文本、判标题、判高亮。

---

## 2. 踩坑记录（重点，全部真实踩过）

### 坑1：测字单位混用 → 分页错乱（fp / vp / px）
- **Text `.fontSize(number)` 单位是 fp**，`Text .lineHeight(number)` 单位也是 **fp**。
- **`Area.width/height`（onAreaChange 回调）单位是 vp**；**margin number 单位 vp**。
- **`measureTextSize` 返回的 height 单位是 px**。
- 结论：measure 的 `fontSize`/`lineHeight` 必须传显式 **fp 字符串**（如 `` `${fontSize}fp` ``）；
  `constraintWidth`/margin 用 vp 数字；容量要 `getUIContext().vp2px(availHeightVp)` 换算成 px。

### 坑2：Swiper ForEach key 不变 → 「首章排不满，直到下一章才满」
- 首次进入第一章时分页发生太早，屏幕尺寸还没测出（用默认 360×640），排出的页偏矮；
  `onAreaChange` 实测真实尺寸（373×777）后虽重排了（日志见 11页→9页），但 **Swiper 内 ForEach
  的 key 只用 `chapterIndex + '_p' + pageIdx`**，同章重排后 pageIdx 字符串不变、key 不变，
  ArkUI **复用旧条目视图**，不重渲染 → 首章仍显示旧的默认尺寸排版；翻到下一章 chapterIndex 变了
  才重渲染，所以「下一章才满」。
- 修法（历史）：加 `pageGen` 计数打进 key，每次 `rebuildPages` 自增，强制重建。
  （后因跨章连续滑动改用内容身份 key，见 §2.3 现状。）

### 坑3：进入书籍「先闪未铺满帧，再刷新成铺满」
- `applyChapter` 在首次进入时同步调 `rebuildPages`，但此刻 `contentWidth/Height` 还是默认值
  （360×640），先渲染一帧「未铺满」，`onAreaChange` 再重排成铺满 → 视觉闪烁。
- 修法：加 `@Local sized` 标记。`applyChapter` 里 `!sized` 时**不立即分页**，只 `pages=[]`，
  交给 `onAreaChange`（首次布局必触发）用真实尺寸完成首次分页；`sized` 为真才直接 `rebuildWindow`。

### 坑4：长段落跨页 → 回滑定位到错误页（倒数第二页而非最后一页）
- 用「末段 `para >= 目标`」定位页面时，某章**最后一段很长、被拆到两页**（倒数第二页与最后一页
  的段首 `para` 相同），定位到的是倒数第二页（那段文字开头），用户实际在最后一页。
- 修法：引入「页身份」`pageIdFor(seg) = \`${chapterIndex}@${para}@${start}\``（`start` 区分长段
  拆分页），`rebuildWindow` 优先按 `currentPageId` 用 `indexOfPageId` 精确回找，找不到才退回
  `flatIndexOf(chapterIndex, paragraphIndex)`。

### 坑5（已解决）：末页/首页闪烁一帧「满页」
- 现象：滑动多了，停在「内容短、未占满」的**章末页**会闪一下满页（相邻页）；后续复测发现
  **章首页**也会闪。中间页都是满页所以看不出，只有不满页（章首页/章末页）才明显。
- 根因：跨章重锚或暖载邻居章会 prepend/append 前一章/后一章，使扁平页流里当前页的**下标位移**。
  `rebuildWindow()` 里 `this.pages = flat`（响应式，下一帧 ForEach 才重建生效）与紧接的
  `swiperController.changeIndex(pageIndex, false)`（命令式，立即作用在**旧子组件树**）是两步，
  中间必有一帧「新 children + 旧下标」→ 显示错页（邻居满页）。向前翻章 drop 旧上一章、向后翻章
  prepend 上一章、暖载 prepend 上一章，都会让当前页下标位移，故首页/末页都会闪。
- 第一次尝试（**失败**）：把 changeIndex 用 `getUIContext().postFrameCallback()` 延后。但
  `FrameCallback.onFrame` 在**下一帧渲染开始前**执行，`@Local pages` 响应式更新也在同帧才生
  效，时序仍未对齐，仍闪。
- 最终修法（**已真机验证**）：删除命令式 changeIndex，改用**声明式 `.index(this.pageIndex)`** 绑
  定到 Swiper；`pageIndex` 与 `pages` 同为 `@Local`，在 `rebuildWindow` 同一同步块里更新，ArkUI
  批量合并在**同一渲染帧原子生效**，从根上消除「新树/旧下标」中间帧。点击翻页的**动画跳页仍走
  `changeIndex(±1, true)`**（不重建 pages、不与声明式绑定竞态）。
  - SDK 印证：`SwiperAttribute.index(value)` 自 API 10 起支持 `$$` 双向绑定，证明是**活 setter**
    （非仅初始值）；单写方（声明式 index for 重建 + 命令式 changeIndex 仅用于带动画的点击翻页）
    即可避免坑8 的双写竞态。

### 坑6：分页性能（翻章卡一下）
- 早期 `paginate` 对**每个段落**都走 `maxCharsFit` 二分（每段十几次 `measureTextSize` 主线程同步），
  整章几十上百段导致翻章卡顿。
- 修法：每段先 `measureHeight(整段剩余)` 测整段高度（大多数段落 1 次测量即可整段放下），
  仅当 `fullH > budget` 才退化二分 `maxCharsFit`。测量次数从「每段 O(log n)」降到「每段 1 次」。

### 坑7：目录（toc）无本地缓存 → 每次进书都慢
- `load()` 里每次进书都 `bookEngine.toc` 整本目录（Rust 侧 `MAX_TOC_PAGES=50` 逐页顺序抓），
  长书目录分多页很慢。正文有 ChapterCache（二次秒开），目录没有。
- 修法：新增 `model/TocCache.ets`，仿 ChapterCache：内存 LRU（`MEMORY_LIMIT=6`，
  键=bookId，按 tocUrl 校验命中）+ 落盘 `filesDir/tocs/{bookId}.json`，`getCachedToc`/`putCachedToc`。

### 坑8（注意勿再次引入）：声明式 `.index()` 与命令式 `changeIndex` 双轨竞态
- 之前同时存在 `.index(this.pageIndex)` 绑定 + `rebuildWindow` 末尾 `changeIndex`，两机制竞态
  导致反向回滑/闪烁。后已删除 `.index()` 绑定、统一走命令式 `changeIndex`。
- 关键 Semantics（`swiper.d.ts` 已查）：`changeIndex(index, useAnimation?: boolean)` since 12
  （默认 false）；`changeIndex(index, animationMode)` since 15（默认 `SwiperAnimationMode.NO_ANIMATION`）；
  `index(value)` since 7（越界取 0）；`onChange` 在动画结束触发。
- `nextPage/prevPage` 用 `changeIndex(±1, true)` 带动画；`rebuildWindow` 的跳位用**无动画**。

---

## 3. Reader.ets 当前代码精确状态（修复后行号，供新 Session 直接定位）

字段（约 55–101 行）：`chapters: Chapter[]`、`chapterIndex`、`paragraphs: string[]`、`paragraphIndex`、
`loading`、`failed`、`menuVisible`、`panel`、`tocDescending`、`fontSize(18)`、`lineHeight(1.8)`、
`nightMode`、`oneHandMode`、`contentWidth(360)`、`contentHeight(640)`、`sized`、
`pages: PageSeg[][]`、`pageIndex`、`sliderValue`、`tts`、`dataSource`；
private：`swiperController`、`tocScroller`、`swipeStartPage`、`loadGen`、
`paraCache: Map<number, string[]> = new Map()`（各章 sanitize 段落缓存，key=章节下标）、
`currentPageId: string = ''`。

模块级 `class PageSeg { chapterIndex: number; para: number; start: number; end: number; constructor(...) }`。
import 含 `MeasureOptions` from `@ohos.measure`（`FrameCallback`/`postFrameCallback` 方案已弃用移除）。

关键方法（行号约）：
- `onTtsProgress`（@Monitor，97–113）：单章跳转用 `flatIndexOf(chapterIndex, tts.paragraphIndex)`；
  TTS 跟随时 `this.pageIndex = page` + `changeIndex(page, true)`。
- `loadChapter`（347–383）：缓存命中 or fetchContent → `applyChapter` → `persistProgress` → `warmNeighbors()`。
- `applyChapter`（387–411）：`paraCache.set(index, paragraphs)`；`sized ? rebuildWindow(restoreAtEnd) : (pages=[])`。
- `warmNeighbors`（async 413–439）：暖载 prev/next 章段落到 `paraCache`，末尾 gen 守卫 + `rebuildWindow(false)`。
- `nextPage/prevPage`（478–494）：`changeIndex(pageIndex±1, true)`，边界分别 `nextChapter/prevChapter`。
- `onPageChanged`（496–520）：读 `pages[index][0]`；跨章（`seg.chapterIndex !== chapterIndex`）→ 重锚：
  设 chapterIndex/sliderValue/paragraphs（paraCache 若有）/currentPageId/paragraphIndex →
  `rebuildWindow(false)` + `warmNeighbors()`；同章仅更新 currentPageId/paragraphIndex；末尾 `persistProgress()`。
- 度量：`availWidthPx/availHeightPx`（=max(120, content−40)，vp）、`paraMargin`、`measureOptions`
  （fp 字符串）、`measureHeight`、`maxCharsFit`（二分）。
- `paginateChapter(paras, chapterIndex)`（577–644）：容量 vp2px，先整段测高、超 budget 才二分。
- `flatIndexOf(ch, para)`（652–667）、`lastIndexOf(ch)`（670–678）、`pageIdFor(seg)`（681–683）、
  `indexOfPageId(id)`（685–693）。
- `rebuildWindow(atEnd=false)`（约 703–747）：组 `[prev(若 paraCache 有), 本章, next(若 paraCache 有)]` 扁
  平流；atEnd → lastIndexOf 末页末段；否则优先 `indexOfPageId(currentPageId)`、退回 `flatIndexOf`；
  末尾**不再命令式 changeIndex**，靠声明式 `.index(this.pageIndex)` 在同一渲染帧原子跳位（**坑5 修法**）。
- `isSpeaking(seg: PageSeg)`（764–770）：按 `seg.chapterIndex + seg.para` 判断；
  `paragraphsOf(ch)`（772–778）= `ch===chapterIndex?paragraphs:paraCache.get(ch)??[]`。
- `changeFont/changeLineHeight`（883/893）：末尾调 `rebuildWindow()`。
- `contentPager()` @Builder（1215–1277）：`Swiper` + `ForEach(pages)` + `ForEach(segments)` →
  `Text(paragraphsOf(seg.chapterIndex)[seg.para].substring(seg.start, seg.end))`；
  内层 key=`${seg.chapterIndex}_${seg.para}_${seg.start}_${seg.end}`；
  外层 key=`page.length>0 ? page[0].chapterIndex+'_'+page[0].para+'_'+page[0].start : 'empty_'+pageIdx`；
  `.index(this.pageIndex)` **声明式绑定已恢复（坑5 最终修法）**、`loop(false)`、`indicator(false)`、`onChange(onPageChanged)`、
  `onAreaChange`（首排：测 w/h，变化或 !sized 则 `sized=true; rebuildWindow()`）、`onClick(onContentTap)`、
  `parallelGesture(PanGesture Horizontal distance 20，onActionStart 记 swipeStartPage，onActionEnd 守卫后
  dx<-60 且 fromPage>=pages.length-1 → nextChapter、dx>60 且 fromPage<=0 → prevChapter)`。

其余（章节导航 isReadable/firstReadable/nextReadable/prevReadable 跳过卷；fetchContent/cachedContent；
sanitize 去'当前位置'/'/'/重复标题、unshift 标题为 para 0；persistProgress；openListening 用
chapters/chapterIndex/paragraphs/paragraphIndex；topBar 标题 chapters[chapterIndex].title 等）未变。

---

## 4. 构建 / 装机 / 抓日志命令（沿用）

```bash
# 只改 ArkTS → 跳 native（未动 Rust，无需重编 .so）
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# → entry/build/default/outputs/default/entry-default-signed.hap

HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
# 日志：$HDC shell "hilog -x | grep SourceReaderPoC"
```

- 设备 UDID：`33Z0224424136564`；`list targets` 返回 `[Empty]` = 掉线，需用户重插 USB 并解锁授权。
- 设备锁屏会导致 `aa start` 报 `10106102`（开发者模式无法自动解锁，需手动解锁）。

---

## 5. 收尾已完成（2026-10-04）

- ✅ `坑5` 末页/首页闪烁已修：最终采用声明式 `.index(this.pageIndex)` 绑定（弃用 postFrameCallback
  命令式 changeIndex 方案），真机复测「末页/首页闪一下满页」消失。
- ✅ 临时 hilog 调试日志（tag `ReaderPager`）已在定位后移除，Reader.ets 无残留。
- ✅ 编译 + 装机 + force-stop + 启动闭环走完。只改 ArkTS，未动 Rust/.so。

---

## 6. 遗留问题 / 已知风险

1. `prefetch(index)` 方法已无调用（保留未删，无碍）。
2. 跨章重锚已用声明式 `.index(this.pageIndex)` 无动画跳位，与命令式 `changeIndex`（仅用于带动画的
   点击翻页）分职责、单写方，坑8 双写竞态已规避；坑5 真机验证通过。
3. 分页是「简化分块」（按字号+屏高测量，段可跨页拆字符），**不保证每页恰好铺满**——
   这是既定设计，非 bug。

---

## 7. 提交状态

已提交（2026-10-04）。本轮相关文件：
```
entry/src/main/ets/pages/Reader.ets        （核心，大幅改动）
entry/src/main/ets/model/TocCache.ets      （新增，目录缓存）
entry/src/main/ets/pages/ReadingSettings.ets （提示文案改动）
docs/handoff/HANDOFF-S10.md                （本文件，新增）
```

---

## 8. 给新 Session 的 prompt（可直接复制）

```
你在一个 HarmonyOS NEXT 原生阅读 App（bundle=com.lichtcui.sourcereader，项目根
/Users/lichtcui/Documents/playground/source-reader）上工作。先读 AGENTS.md、docs/progress.md、
docs/plan.md，然后读 docs/handoff/HANDOFF-S10.md（本文件，含全部踩坑与当前代码状态）。

当前任务：阅读页翻页改造收尾。阅读页已从竖向滚动改为横向分页（Swiper + measureTextSize 测字
精确分页），并实现了「上一章+本章+下一章」跨章连续滑动。绝大部分已完成并真机验证，
只剩最后一个 bug：滑动多了，停在「内容短、未占满」的最后一页时，偶发闪一下满页
（相邻页），无稳定复现。

我刚做完的修复（尚未装机验证）：把 rebuildWindow 末尾的 swiperController.changeIndex 用
getUIContext().postFrameCallback 延后到下一帧渲染之后执行（根因是 this.pages=flat 响应式更新
下一帧才生效、命令式 changeIndex 却立即打在旧树上）。相关代码见 HANDOFF-S10.md §2坑5、§3。

请：
1. 先确认设备连接（hdc list targets；[Empty]=掉线需用户重插 USB 授权）。
2. 构建 → 装机 → force-stop → 启动（命令见 HANDOFF-S10.md §4）。
3. 让用户复测「末页闪一下满页」是否消失。
4. 若仍闪，加 hilog 日志定位（见 §5），或降级 setTimeout(0)。
  只改 ArkTS，不动 Rust/.so。改动要符合 AGENTS.md 约定（V2 状态管理、文档落位 docs/、
  不用 any、点语法字段要加进 obfuscation-rules.txt 的 -keep-property-name）。
```