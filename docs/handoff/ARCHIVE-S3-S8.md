# HANDOFF 归档（S3–S8）

> 本文件由 `HANDOFF-S3.md` … `HANDOFF-S8.md` 合并归档，正文未作改动，原文件已删除。
> S9 起仍保留独立文件（见 `HANDOFF-S9.md`）。

---

# HANDOFF-S3 — 地基改动（公共组件 + 缓存层）

日期：2026-09-25
范围：UI-SPEC.md §1–3 公共组件落地 + ROOT-CAUSE.md §1/§2-B 缓存层最小修复。
约束：**未改动任何业务页面逻辑**（三组件均未接入页面）。

## 决策记录（开工前已确认）

1. 按**任务命名 + `ui/common/`**落地，不采用 UI-SPEC 的 `AppNavBack / AppMoreButton / AppBottomSheet` + `components/` 命名；入参、动画严格照 UI-SPEC。
2. 缓存层「架构级」修复 = **§2-B + §1 两者都做**。
3. §2-B 的 in-flight 请求合并放在**引擎适配层 `BookEngineNapi`**（不触业务页面）。
4. `MoreMenuButton` 配色：`normal=text_2` / `onReader=reader_dim` / `onBrand=on_brand`。
5. `BottomDrawer.visible` 用 `@Param visible + @Event onClose`（V2 单向 + 事件，组件不自写 visible；关闭路径统一调 `onClose()`）。
6. overlay 模式 = **自包含底部抽屉**（全屏遮罩 + 贴底圆角面板；不含 topBar/bottomBar）。

## 1. 变更文件

| 文件 | 类型 | 说明 |
|---|---|---|
| `entry/src/main/ets/ui/common/AppBackButton.ets` | 新增 | 返回键组件 |
| `entry/src/main/ets/ui/common/MoreMenuButton.ets` | 新增 | 省略号功能键组件 |
| `entry/src/main/ets/ui/common/BottomDrawer.ets` | 新增 | 底部抽屉，system / overlay 两模式 |
| `entry/src/main/resources/base/element/color.json` | 改 | 新增 `mask = #52000000` |
| `entry/src/main/resources/dark/element/color.json` | 改 | 新增 `mask = #80000000` |
| `entry/src/main/ets/model/ChapterCache.ets` | 改 | 内存层改存 `{url,content,fetchedAt}` 并命中前比对 `url` |
| `entry/src/main/ets/components/BookCover.ets` | 改 | 模块级 PixelMap / 路径缓存 + 磁盘存在性短路 |
| `entry/src/main/ets/engine/BookEngineNapi.ets` | 改 | `content` 增加 in-flight 请求合并 |
| `rust/legado-engine/src/runtime.rs` | 改 | `download_cover` 先算文件名，命中磁盘即短路返回 |
| `entry/libs/arm64-v8a/liblegado_core.so` | 改 | `ohrs build --arch arm64 --release` 重编产物 |

> NAPI 导出未变，`entry/src/main/cpp/types/liblegado_core/index.d.ts` 无需更新。
> 未新增 JSON 点语法字段，`obfuscation-rules.txt` 无需更新。

## 2. 新组件接口签名

```ts
// ui/common/AppBackButton.ets
type AppBackTone = 'normal' | 'onBrand';
@ComponentV2
export struct AppBackButton {
  @Param label: string = '返回';
  @Param tone: AppBackTone = 'normal';
  @Event onTap: () => void = () => {};
}
```

```ts
// ui/common/MoreMenuButton.ets
type AppMoreTone = 'normal' | 'onReader' | 'onBrand';
@ComponentV2
export struct MoreMenuButton {
  @Param items: MenuElement[] = [];
  @Param tone: AppMoreTone = 'normal';
  @Param label: string = '更多';
}
```

```ts
// ui/common/BottomDrawer.ets
type AppSheetSize = 'medium' | 'large' | 'fit';
type AppSheetMode = 'system' | 'overlay';
@ComponentV2
export struct BottomDrawer {
  @Param visible: boolean = false;
  @Param title: string = '';
  @Param size: AppSheetSize = 'medium';
  @Param mode: AppSheetMode = 'system';
  @Event onClose: () => void = () => {};
  @BuilderParam content: () => void = this.emptyContent;
}
```

尺寸/动画实现对照 UI-SPEC：
- 热区 44×44；glyph 24fp；字号 17fp；标题栏 48vp；顶部圆角 20；遮罩 `app.color.mask`。
- `bindMenu` / `bindSheet` 走系统默认动画，未包 `animateTo`。
- overlay 打开 260ms `FastOutSlowIn`、关闭 200ms；遮罩淡入 200ms / 淡出 160ms `Linear`；图标按压 100ms scale 0.92 `EaseInOut`。
- 拖拽条自绘 36×4 radius 2，`divider` 色，上边距 8；下拉 > 面板高 30% 或速度 > 1000 关闭，否则回弹。

## 3. 缓存层方法签名

```ts
// model/ChapterCache.ets（签名未变，语义修正）
getCachedChapter(ctx: common.UIAbilityContext, bookId: string, index: number, url: string): string | undefined
putCachedChapter(ctx: common.UIAbilityContext, bookId: string, index: number, url: string, content: string): void
hasCachedChapter(bookId: string, index: number): boolean
// 内存：Map<string, CachedChapter>{url,content,fetchedAt}；命中内存时 mem.url !== url 则 delete 并继续查磁盘。
```

```ts
// engine/BookEngineNapi.ets
async content(source: BookSource, chapterUrl: string): Promise<ContentResult>
// in-flight key = `${source.bookSourceUrl}|${chapterUrl}`；并发同键复用同一 Promise；
// .finally 清理，失败/异常也清理，避免永久 pending。
```

```ts
// components/BookCover.ets（无导出签名变化）
// 模块级：pixmapCache: Map<coverUrl, image.PixelMap>
//         pathCache:   Map<coverUrl, string>
// load(): pixmap 命中→直用；否则 path 命中且 fileIo.accessSync(path)→仅解码；
//         否则 downloadCover（Rust 已对磁盘文件短路）。解码结果写回 pixmapCache。
```

```rust
// rust/legado-engine/src/runtime.rs
pub async fn download_cover(source: &BookSource, cover_url: &str, dest_dir: &str) -> Result<String, String>
// 先算 cover_<hash>.img，Path::exists 命中即 Ok(path)，不发生网络请求。
```

## 4. 构建 / 验证结果

- 每完成一个文件均跑 `hvigorw assembleHap ...`：全部 **BUILD SUCCESSFUL**（AppBackButton / MoreMenuButton / BottomDrawer / ChapterCache / BookCover / BookEngineNapi 各一次，Rust 产物落地后一次）。
- `cargo test`（legado-engine）：**54 passed; 0 failed**。
- `ohrs build --arch arm64 --release`：成功，`.so` 已拷贝至 `entry/libs/arm64-v8a/`。
- 未做真机安装/重启/观察（本轮仅编译闭环）。

## 5. 遗留问题 / 待办

1. **组件未接入页面**：受「不改业务页面逻辑」约束，UI-SPEC §4 替换清单（SearchResult 返回、BookDetail 返回、Reader 顶栏/目录/设置、Listening 目录、Index 省略号等）**全部未做**，需下一轮单独实施并逐项真机验证。
2. **UI-SPEC 路径需更新**：UI-SPEC §2/§4 中的文件名与目录（`components/AppNavBack.ets` 等）与本次落地（`ui/common/AppBackButton.ets` 等）不一致，建议同步修订文档。
3. **BottomDrawer system 模式 `onWillDismiss` 语义偏差**：UI-SPEC 写 `onWillDismiss: onClose`，但该回调需显式 `action.dismiss()` 才会关闭，故实现为 `(action) => { action.dismiss(); this.onClose(); }`。
4. **overlay 系统返回键关闭未实现**：组件级无稳定 back 拦截点；需页面在返回逻辑里调 `onClose()`（Reader 已有 `onTopBack` 可挂）。UI-SPEC §3 的「系统返回键」关闭途径待页面接入时补齐。
5. **system 模式内容区高度待真机确认**：按 UI-SPEC 去掉了内容根 `height('100%')`，内部用 `layoutWeight(this.size==='fit'?0:1)`。若在 `SheetSize.MEDIUM/LARGE` 下内容不填充/目录不滚动（尤其 Listening 大目录），需回退加高度或改用其他方案——属真机才能暴露。
6. **`onReader` 不随阅读页 nightMode 切换**：按决策用单一 `reader_dim`（#8A8A92）。阅读页日间模式原本用 `reader_dim_day`（#999999），接入后会有轻微色差。
7. **封面缓存无上限**：`pixmapCache` / `pathCache` 均按 coverUrl 永久驻留（会话级），未做 LRU；封面量大时内存增长。可按需加容量上限。
8. **Rust 文件哈希稳定性**：`DefaultHasher` 结果不保证跨 Rust 版本稳定，升级工具链可能导致旧封面文件名失配而重下（仅多一次网络，语义无害）。
9. **in-flight 合并范围**：仅 `content`，keyed by `sourceUrl|chapterUrl`；跨源同 URL 不合并（有意）。prefetch 与 loadChapter 的同章并发已被合并。
10. **`hasCachedChapter` 仍仅查内存**（未改），如需磁盘存在性应另行扩展。

---

# HANDOFF-S4 — 阅读模块逐项修复（A–G）

日期：2026-09-26
范围：**仅阅读模块**（`pages/Reader.ets` 为主线，含阅读设置与封面缓存层复用）。
基线：`b02e223`（M5）。HEAD：`0eb1e1c`。
约束履行：C 项使用 `HANDOFF-S3.md` 的 `ui/common/BottomDrawer.ets`（未自绘）；E 项按“同源只改一处”处理并注明。

> 真机验证已完成（设备 `33Z0224424136564`，中途多次掉线已重连）。逐项结果见 §5。
> 验证期间发现 A/C/E 的三处实现问题，已各自追加 commit 修正（`0ce201d` / `0eb1e1c`），见对应小节。

---

## 1. 变更清单（按项）

### A. 全屏展示（上下安全区全屏，保留状态栏）

**根因（验证期修正）**：最初用沉浸式 `setWindowLayoutFullScreen(true)`，但 **ArkUI 在该模式下会去掉页面内容的安全区**，
正文首行贴到状态栏被时间遮挡（dump 首行由 y=195 变 y=132）。且状态栏条由**阅读路由 `NavDestination` 的固定背景**
`reader_bg`（#181820）绘制，与阅读页内部昼夜状态无关，日间模式出现“夜条带 + 日正文”。

**最终实现**：
- 保持**非沉浸**布局（安全区恢复），窗口背景 `setWindowBackgroundColor()` 取 `bgColor()` 的真实资源色（`resolveColorHex`）。
- 新增 `common/ReaderTheme.ets`（`@ObservedV2`，`@Trace bgHex`）：阅读页写入当前背景色，`Index.pageMap` 的阅读路由
  `.backgroundColor(ReaderTheme.instance().bgHex)` 绑定，使状态栏条随昼夜同步。
- 退出阅读页复原窗口背景为 `bg_page`、状态栏图标按系统深浅色。

**commit**：`508471e`（初版沉浸方案）→ **`0ce201d`（修正为非沉浸 + ReaderTheme）**、`6e3423b`（退出复原状态栏图标）

**验证**：screenCap 采样——日间 条带/正文/底部均 `#F4F2EC`；夜间均 `#181820`；正文首行 y=195（安全区保留），状态栏时间可见。

### B. 加载动画与缓存（已有缓存不再走加载动画）

**根因**：`loadChapter` 无条件 `loading=true` 后才 `await fetchContent`，命中缓存仍闪一帧 `LoadingProgress`。

- `pages/Reader.ets`：新增同步探测 `cachedContent()`；命中即 `applyChapter()` 立即上屏、不置 loading；抽出 `applyChapter()`。
- 落地 S3 缓存层：`model/ChapterCache.ets`（内存 `{url,content,fetchedAt}` + url 校验）、`engine/BookEngineNapi.ets`（in-flight 合并）。

**commit**：`45bb1d5`

**验证**：逻辑修复；未逐帧抓 spinner（见 §6 遗留）。

### C. 目录 & 设置改 BottomDrawer

**根因（验证期修正）**：`@BuilderParam content` 以**值**方式传入（`content: this.tocDrawerContent`）在 V2 下运行期变为
`undefined`，`update func: undefined is not callable` → 点“目录”**进程被杀**退出（此前阅读页被顶掉的真相）。S3 组件参数名
`size` 与 `CustomComponent` 基类冲突，编译失败。

- `ui/common/BottomDrawer.ets`：`@Param size` → `@Param sheetSize`。
- `pages/Reader.ets`：目录/设置改为 `BottomDrawer({ mode:'overlay' })`，内容用**尾随 builder** 传参：
  `BottomDrawer({...}) { this.tocDrawerContent() }`；目录 `'large'`、设置 `'fit'`。
- 落地 S3 组件与 `mask` 颜色 token。

**commit**：`328b893` → **`0eb1e1c`（尾随 builder 修正崩溃）**

**验证**：点「目录」正常弹出（标题栏/书卡/定位/正序/列表），点「设置」弹出字号/行距；hilog 无 `undefined is not callable`。

### D. 目录重复渲染（二次 set）

**根因**（ROOT-CAUSE §2-A）：目录 `List` 无 `initialIndex`，首帧渲染顶部后再定位，LazyForEach 在目标位置重建一批 item。

- `pages/Reader.ets`：`List(... initialIndex: this.tocPosition())`；定位收敛为 `tocPosition()`；打开目录的 80ms 延时代码随 C 删除。

**commit**：`19364a0`

**验证**：打开目录首帧即当前章（如 `3、破碎的世界（修）`），无“先顶部后跳”。

### E. 正倒序只生效一次 + 进度条左右逻辑

**根因（验证期确认，含两层）**：
1. **渲染层**：`@BuilderParam` 内容在 V2 细粒度更新下**不会因普通 `@Local` 变化重跑**；`LazyForEach` 仍指向旧
   `dataSource`，故第 2 次切序不重建；`slice().reverse()` 亦有 V2 代理数组干扰。
2. **数据源层（观测）**：测试书《夜的命名术》的源目录本身**畸形**（开头是“新书+1004、1003…”最新块，
   结尾又重复该块），导致切序后**列表顶部看起来相同**，加剧“没生效”的错觉。

**修复（一处状态源）**：
- `buildTocItems()`：改为**显式循环**构造有序数组（不用 `slice/reverse`），并用新的 `ChapterDataSource` 实例替换 `@Local dataSource`。
- `build()`：用 `if (this.tocDescending) { … } else { … }` **分支持序重挂载** TOC 抽屉，强制 LazyForEach 以新序重建。
- **进度条/上一章下一章未改**：真机实测左右箭头与滑块恒为源顺序（右=+1、左=−1），与 `tocDescending` 无关，即“只改一处”。

**commit**：`bd2a343` → **`0eb1e1c`（显式循环 + 分支重挂载）**

**验证**：对同一目录 `定位` 后对比——正序中部显示 `995/996/997/998/999`，倒序中部显示相邻不同序列；每次切序渲染序列确实变化。

### F. 单手翻页模式

- `common/Const.ets`：`KEY_READER_ONE_HAND_PAGE` / `READER_ONE_HAND_PAGE_DEFAULT(false)`。
- `pages/ReadingSettings.ets`：新增「单手翻页」`SwitchCell`（持久化）。
- `pages/Reader.ets`：开启后 `onContentTap` 分区改为 **45% / 10% / 45%**（左右翻页、中间窄条仍开菜单）；关闭为 1/3 三分区。

**commit**：`d321d43`

**验证**：开启后右点→下一章（`新书…`→`1004、后记（完）`）、左点→上一章、中点→菜单；验证后已恢复开关为关闭。

### G. 目录封面延迟

**结论**：与 ROOT-CAUSE §1 书架封面**同一根因**（`BookCover` 每次挂载都走网络、Rust `download_cover` 只写不读）。
按“复用缓存层修复”落地 S3 缓存层单点：

- `components/BookCover.ets`：模块级 `pixmapCache`/`pathCache` + 磁盘存在性短路（命中 PixelMap 同步赋值，重挂载无闪）。
- `rust/legado-engine/src/runtime.rs`：`download_cover` 先算 hash 文件名，`Path::exists` 命中直接返回。
- `entry/libs/arm64-v8a/liblegado_core.so`：S3 重编产物（`cargo test` 54 passed）。

**commit**：`d82a467`

**验证**：静态修复确认；未做网络抓包级验证（见 §6）。

> S3 地基改动分散并入相关项：ChapterCache/BookEngineNapi → B；ui/common + mask → C；BookCover/Rust/.so → G。

---

## 2. 每项 commit 对照

| 项 | commit | 说明 |
|---|---|---|
| A | `508471e` + `6e3423b` + **`0ce201d`** | 全屏；退出复原图标；**修正：非沉浸 + ReaderTheme 条带同色** |
| B | `45bb1d5` | 同步缓存探测跳过 loading；并入 S3 缓存层 |
| C | `328b893` + **`0eb1e1c`** | BottomDrawer overlay；`size`→`sheetSize`；**修正：尾随 builder 防崩溃** |
| D | `19364a0` | 目录 `initialIndex` + `tocPosition` |
| E | `bd2a343` + **`0eb1e1c`** | 方向 key；**修正：显式循环 + if/else 重挂载（与 C 同 commit）** |
| F | `d321d43` | 单手翻页开关 |
| G | `d82a467` | 封面读穿缓存（S3 缓存层） |

## 3. 关键文件

- `entry/src/main/ets/pages/Reader.ets`（A/B/C/D/E/F）
- `entry/src/main/ets/common/Window.ets`、`common/ReaderTheme.ets`、`pages/Index.ets`（A）
- `entry/src/main/ets/pages/ReadingSettings.ets` + `common/Const.ets`（F）
- `entry/src/main/ets/components/BookCover.ets` + `rust/legado-engine/src/runtime.rs` + `.so`（G）
- `entry/src/main/ets/ui/common/BottomDrawer.ets`（C，S3 原版 + `sheetSize` 重命名）

## 4. 构建 / 验证命令

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# cargo test（legado-engine）：54 passed; 0 failed
# 真机截图（可信）：hdc shell uitest screenCap -p /data/local/tmp/c.png（snapshot_display 会返回陈旧帧，勿用）
# UI 驱动：hdc shell "uitest uiInput click <x> <y>"；dumpLayout 坐标为物理像素（本机 1260×2844）
```

## 5. 真机验证结果

| 项 | 结果 | 依据 |
|---|---|---|
| A | ✅ | 日/夜条带与正文同色（`#F4F2EC` / `#181820`），首行 y=195、状态栏时间可见 |
| B | ✅（逻辑） | 缓存命中路径不再置 loading；未逐帧抓 spinner |
| C | ✅ | 目录/设置抽屉正常，无 `undefined is not callable` 崩溃 |
| D | ✅ | 打开目录首帧即当前章 |
| E | ✅ | 切序后渲染序列变化（定位后中部对比不同） |
| F | ✅ | 单手：右=下章、左=上章、中=菜单 |
| G | ⚪ | 缓存层修复已落地，未做网络级验证 |

## 6. 遗留问题 / 已知风险

1. **系统返回键不关抽屉**：BottomDrawer overlay 无组件级 back 拦截；系统返回直接 pop 阅读页。需在 `Index.ets` reader 路由用
   `onBackPressed`/`onShown/onHidden` 接入（S3 已记）。
2. **窗口/路由状态在“阅读页之上再压页”期间保持**：Reader → 详情/听书 时 Reader 未销毁，路由背景/窗口色保持阅读页色，叠加页状态栏条为阅读页色。范围受限，暂接受。
3. **V2 `@BuilderParam` 限制**：内容不随普通状态重跑；已用 if/else 重挂载绕过。后续给 BottomDrawer 传入依赖频繁变化的内容时需注意同一坑。
4. **源目录畸形**：测试书《夜的命名术》目录首尾重复“最新章”块（`新书…/1004…`），属**引擎/书源规则**问题（详情规则未剔除“最新章节”块），非阅读页缺陷；建议单独立项。
5. **单手翻页分区为设计假设**（45/10/45），如需全屏二分区需再拍板。
6. **封面首次加载仍走网络**（缓存只覆盖二次）；Rust `DefaultHasher` 跨工具链稳定性 S3 已记。
7. **`tocDescending` 未持久化**：重进阅读页恢复默认正序。
8. **S3/审计文档未提交**：`AUDIT.md` / `ROOT-CAUSE.md` / `TASKS.md` / `UI-SPEC.md` / `HANDOFF-S3.md` 及本文件仍 untracked。
   `AGENTS.md` / `docs/progress.md` 的改动来自并行 TTS 调研工作流，本轮未纳入。
9. **`ui/common/AppBackButton.ets`、`MoreMenuButton.ets` 已并入 C 但页面尚未接入**（S3 遗留）。

---

# HANDOFF-S5 — 听书模块逐项修复（A–E）

日期：2026-09-26
范围：**仅听书模块**（`model/TtsController.ets` 为主线，含 `pages/Listening.ets`、书架 / 阅读页浮动入口）。
基线：`0eb1e1c`（S4 收尾）。HEAD：`1131008`。
约束履行：A、B 各自单独 commit；D 吸附动画复用 `UI-SPEC.md` 的 `260ms / Curve.FastOutSlowIn`；E 只改听书传输控制，未联动阅读模块 E 项。

> 构建：`assembleHap` 通过（7 个 commit 均编译绿灯）。
> **真机验证已完成**（设备 `33Z0224424136564`，先遇锁屏 `10106102`，解锁后跑通），逐项结果见 §5。
> 验证期发现浮动按钮「容器未挂载」缺陷，已追加 commit `ad136e7` 修正。

---

## 0. 调查来源

- A 项根因来自 `ROOT-CAUSE.md` §3-A（只读调查，未改码）。
- B 项由 `@general` 只读复核报告独立给出（复核确认 ROOT-CAUSE §3-B 成立，并补全三处可执行细节）。
  其关键 API 结论：`person` 只能在 `createEngine` 时确定（无法运行时切音色，重建不可避免）；
  `speed` 是每次 `speak()` 的 `extraParams`（改速**不需要**重建/重合成）；`flush()` 会重置播放位置。

---

## 1. 变更清单（按项）

### A. 进度条跳跃（commit `1fa17cd`）

**根因**（ROOT-CAUSE §3-A）：进度取「写入渲染器」位置而非「实际播放帧」。`fill()`（`writeData` 回调）
一写入就设 `paragraphIndex`，而 AudioRenderer 预缓冲使写入领先可听播放一个缓冲区 → 进度/高亮跳到还没听到的段；
时间估算纯按字数（`chars / (5.0 * speed)`），段内不推进、跨段突跳；AVSession 位置同源且只在段边界刷新。

**实现**：
- `TtsController.ets`：新增 `ParagraphTiming` 时间轴。每段在 `enqueueParagraph` 时按**合成 PCM 字节长度**
  （`bytes / 32000 = ms`，与 M5 实测「段落字节/32000 ≈ 实测时长」一致）登记 `[startMs, endMs)`。
- 新增 200ms `tickProgress()`：用 `renderer.getAudioTimestampInfoSync().framePos`（失败回退墙钟）换算已播毫秒，
  再由时间轴解析**当前真正在播的段落**，写回 `paragraphIndex` / `currentIndex` 与新增 `@Trace elapsedMs`。
- `fill()` 回调**只搬 PCM 字节**，删除了写进度的代码（回调不再碰 DB / AVSession）。
- AVSession `elapsedTime` 改用 `elapsedMs`，并在 tick 内节流到 **1s** 刷新一次；`persistProgress` 同样节流。
- `pages/Listening.ets`：时间读数改用 `tts.elapsedMs`（播放时钟，200ms 插值）。

**验证**：静态 + 编译；真机未完成（见 §5）。段落滑块仍为整段粒度（离散推进），
时间读数连续推进；总时长仍是字数估算（见 §6 遗留）。

### B. 暂停恢复 / 改语速 / 换音色卡顿（commit `54a37d2`，加固 `1131008`）

**根因**（`@general` 复核）：
1. `pause()` 用 `resetQueues()` 清掉已合成 PCM（真正的卡顿主因）；`resume()` 走 `beginFrom` →
   停引擎 + 重清队列 + 整段重合成 + `startRenderer` 的 `pause→flush→start`（制造 underrun）。
2. `setSpeed()` 调 `beginFrom(currentIndex)` 整段重合成——但 `speed` 只是 `speak()` 参数，毫无必要。
3. `setVoice()` 先 `pause()` → `shutdown()` → **固定 120ms 死等** → 串行 `createEngine` → `resume()` 重合成；
   且 `async` 未 await + `creating` 守卫导致连点静默失败。

**实现**（均在 `TtsController.ets`）：
- 新增 `clearInflight()`：只丢弃未 flush 的在途请求，**保留** `queue` / `timeline` / `queueOffset`。
- `pause()`：`clearInflight()` 取代 `resetQueues()`；保留已缓冲音频与时间轴。
- `resume()`：快路径——`playing=true` + 续发合成 + `renderer.start()`（**不** pause/flush），
  从停顿处续播；渲染器缺失才回退 `beginFrom`。`1131008` 再补 `start()` 失败重试（防与未完成的 pause 竞争）。
- `setSpeed()`：删除 `beginFrom`；只 `engine.stop()` + `clearInflight()` + `ensureSynthesized()`，
  新语速作用于后续段，已缓冲音频不中断。
- `setVoice()`：去掉固定 120ms；**先建新引擎、后关旧引擎**，全程不停播；新增 `voiceSwitching` 串行化。

**验证**：静态 + 编译；真机未完成（见 §5）。

### C. 听书目录改 `BottomDrawer`（commit `acd3947`）

**实现**：`pages/Listening.ets` 删除一次性 `bindSheet` 目录，改用与阅读模块同一组件
`ui/common/BottomDrawer.ets`（`mode:'overlay'`、`sheetSize:'large'`、`title:'目录'`），
内容用**尾随 builder** `BottomDrawer({...}) { this.tocContent() }`（沿用 S4 的 V2 `@BuilderParam` 防崩溃写法）；
页面根由 `Column` 改为 `Stack` 以承载 overlay。章节点击 → 关闭抽屉 + `jumpChapter`。

### D. 浮动按钮（commit `c6fb27d`）

**实现**：新增 `ui/common/FloatingListenButton.ets`（`@ComponentV2`）：
- 悬浮右侧，`PanGesture` 跟随手指拖动，位置钳制在父容器内；
- 拖动结束后**空闲 2500ms** 用 `animateTo({ duration: 260, curve: Curve.FastOutSlowIn })` 向右吸附
  （时长/曲线复用 `UI-SPEC.md` §1.3「overlay 抽屉打开」参数）；
- 根 `Stack` 满尺寸但 `hitTestBehavior(HitTestMode.None)`，空白区不拦截下层触控，仅气泡消费触摸；
- 首帧位置 = 右缘、纵向约 55%。

接入：
- `pages/Shelf.ets`：替换原静态 `listenFab()`，`tts.active` 时显示；可拖动 + 吸附。
- `pages/Reader.ets`：`tts.active` 时显示（位于抽屉之下，抽屉遮罩可覆盖）；点击经新增
  `@Event onOpenListening` → `Index.openListening()`（**无参** push，保留当前 TTS 会话与书目，避免跨书误重启）。

### E. 上一章 / 下一章改真正章节跳转（commit `af1cf49`）

**现状**：传输按钮与 AVSession `playNext/playPrevious` 调 `next()/prev()`，原实现只 `beginFrom(currentIndex±1)`
（约 5 秒一个段落），仅到章末才换章。

**实现**：`TtsController.next()/prev()` 改为 `nextReadable/prevReadable(chapters, chapterIndex)` 直接
`loadChapter(..., false, this.playing)`（保留播放/暂停态，跳到相邻可读章开首）。UI 与锁屏媒体键同步生效；
`prev` 不再落到上一章末尾。与阅读模块 E 项（正倒序）无关。

---

## 2. 每项 commit 对照

| 项 | commit | 说明 |
|---|---|---|
| A | `1fa17cd` | 音频时钟驱动进度；回调只搬 PCM；AVSession/DB 节流 |
| B | `54a37d2` + **`1131008`** | 暂停续播、改速不重合成、换音色先建后关；**加固 resume 重试** |
| C | `acd3947` | 听书目录 → `BottomDrawer` overlay |
| D | `c6fb27d` + **`ad136e7`** | 浮动听书按钮（拖动/吸附/书架+阅读页）；**修正：先挂载容器再测量** |
| E | `af1cf49` | 上一章/下一章真章节跳转 |

## 3. 关键文件

- `entry/src/main/ets/model/TtsController.ets`（A/B/E）
- `entry/src/main/ets/pages/Listening.ets`（A/C，prev/next 绑定复用 E）
- `entry/src/main/ets/ui/common/FloatingListenButton.ets`（D，新增）
- `entry/src/main/ets/pages/Shelf.ets`、`pages/Reader.ets`、`pages/Index.ets`（D）

## 4. 构建命令

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# 结果：BUILD SUCCESSFUL（仅既有 ArkTS 警告：音频 API 的 syscap 提示、函数可能抛异常提示）
```

## 5. 真机验证结果

测试书《测试书》（本地 3 章，章节时长 ≈3s），`hilog` tag `SourceReaderTts`。

| 项 | 结果 | 依据 |
|---|---|---|
| A 进度 | ✅ | `begin para=0` → `play para=1`（+2.2s）→ `play para=2`（+5.2s），与 PCM 时长一致，**无写入侧提前跳段**；时间读数 `00:05`→`00:06` 连续递增 |
| B 卡顿 | ✅ | 暂停/恢复只在日志出现 `pause` / `resume`，**无 `begin para=`**（未重合成/未从段首重播）；语速 1.2x→2.0x 无 pause/begin；音色 13→21→13 仅 `engine ready voice=21/13`，全程不停播 |
| C 抽屉 | ✅ | 点列表图标：全屏遮罩 `#52000000` + 标题 `目录` + 章节 `第一章/第二章/第三章`，与阅读页同一 `BottomDrawer` overlay |
| D 浮动按钮 | ✅ | 阅读页气泡 `[1031,1570]`→拖动到 `[366,1570]`→空闲约 2.5s 吸附回 `[1030,1570]`；点击回到听书页。书架气泡 `[1031,1650]`→拖动 `[216,1649]`→吸附 `[1030,1649]` |
| E 章节跳转 | ✅ | 听书页「上一章」`第三章 归途`→`第二章 相遇`，「下一章」→`第三章 归途` |

恢复现场：语速已还原 `1.0x`、音色已还原 `聆小珊（女声）`；验证后 `aa force-stop` 结束听书后台任务。

（过程记录：首次 `aa start` 因锁屏报 `10106102 ... cannot be unlocked automatically`，解锁后重试成功。）

## 6. 遗留问题 / 已知风险

1. **`getAudioTimestampInfoSync` 为 API 19**：`compatibleSdkVersion 5.0.0(12)`，API 12–18 设备上该方法不存在，
   已用 `try/catch` 回退到墙钟估算，不会崩溃；但**低版本设备进度精度退化为墙钟**。目标机 API 24 无此问题。
2. **总时长仍是字数估算**（`CHARS_PER_SECOND=5.0`），未随 PCM 时间轴校正；段落滑块为整段粒度。
   `elapsedMs`（音频时钟）与 `estimateDurationMs`（字数）口径不同，极端文本下滑块到头/总时长可能略有偏差。
3. **暂停续播的音频时钟**：若 pause 与 resume 之间渲染器被系统路由变化重置，`framePos` 会从 0 重新计，
   而时间轴未重置 → 段落映射可能短暂偏差；目前未做路由变化监听（`audioInterrupt` 只处理 pause/stop）。
4. **`onParagraphEnd` 仍是写入侧触发**：章末切章由 end 标记（写入领先）驱动，最多提前一个缓冲区；
   进度/高亮本身已由音频时钟驱动，两者在章末可能有亚秒级不一致。
5. **跨书串扰（T-CROSS-1）未处理**：`Reader.onTtsProgress` / `isSpeaking` 仍无 `bookId` 守卫；
   阅读页浮动按钮已用**无参** `openListening()` 规避「点一下把 TTS 切到当前书」，但监听中的跨书滚动仍是原缺陷。
6. **后台任务泄漏（T-CROSS-2）未处理**：`pause()` 仍未 `stopBackground()`；本轮未纳入。
7. **文档未提交**：`AUDIT.md` / `ROOT-CAUSE.md` / `TASKS.md` / `UI-SPEC.md` / `HANDOFF-S3.md` / `HANDOFF-S4.md`
   及本文件仍 untracked；`AGENTS.md` / `docs/progress.md` 的改动来自并行 TTS 调研工作流，本轮未纳入。

---

# HANDOFF-S6 — 搜索模块原地化 + 抽屉化（A–F）

日期：2026-09-26
范围：**仅搜索模块**（`pages/Search.ets` / `pages/SearchResult.ets`，含 `pages/Index.ets` 路由接线、`common/Const.ets` 清理）。
基线：`ad136e7`（S5 收尾）。HEAD：`f5d66a4`（本轮提交，见 §2）。
约束履行：
- E/F 均使用 `HANDOFF-S3.md` 的 `ui/common/BottomDrawer.ets`（`mode:'system'`，未自绘 sheet）。
- D 的自定义动画复用 `UI-SPEC.md` §1.3「overlay 抽屉打开」参数：`260ms / Curve.FastOutSlowIn`。
- **搜索/合并/排序逻辑零改动**：`rebuildGroups` / `bucketOf` / `weightOf` / `cleanAuthor` / `cleanChapter` /
  `enrichMerged` / `enrichOne` / `primaryOrigin` 全部原样保留。

> 构建：`assembleHap` **BUILD SUCCESSFUL**（仅既有 ArkTS 警告：`audio` syscap、函数可能抛异常、剪贴板权限）。
> **真机验证已完成**：设备 `33Z0224424136564`，A–F 全项通过（见 §5），无崩溃。

---

## 0. 调查来源

- 现有实现：`Search.ets`（居中输入框 + 「管理书源」入口，`onSearch` push 新页面）、
  `SearchResult.ets`（独立路由页，自带返回键 + 输入框 + 结果 + 内联「源状态」+ `bindSheet` 选源）。
- 参考组件：`ui/common/BottomDrawer.ets`（`@Param visible/title/sheetSize/mode` + `@Event onClose` +
  尾随 `@BuilderParam content`），接入写法沿用 S5 的 `BottomDrawer({...}) { this.xxxContent() }`。
- 动画参数来源：`UI-SPEC.md` §1.3。

---

## 1. 变更清单（按项）

### A. 原地搜索：不再跳新页面，当前页直接展示结果

- `Search.ets` 由「纯输入页」改为「**搜索 Tab 全页**」：顶部输入栏 + 下方结果区；
  `SearchResultPage` 作为**内嵌子组件**渲染在同一页（`Column().layoutWeight(1)` 包裹）。
- `Search.ets` 新增 `@Local submittedKeyword`（首次提交后非空）与 `@Local searchToken`（每次提交自增）：
  - 未提交：显示 `idleHint()`（放大镜 + "输入书名或作者开始搜索"）。
  - 已提交：渲染 `SearchResultPage({ keyword, searchToken, onOpenDetail })`。
- `SearchResult.ets`：
  - 删除独立页的 `topBar()`（返回键 + 输入框）与 `@Event onBack`；
  - 新增 `@Param searchToken` + `@Monitor('searchToken')`：同关键词再次提交也能重搜；
  - 根布局由 `Column` 改 `Stack`（承载两个抽屉），内容列 `height('100%')`。
- `Index.ets`：删除 `openSearchResult()` 与 `ROUTE_SEARCH_RESULT` 路由分支，`SearchPage` 改为直接接收
  `onOpenDetail`；`Const.ets` 删除已无用的 `ROUTE_SEARCH_RESULT` / `SearchParam`。

### B. 输入框移到页面最上方

- `Search.ets` 用 `this.searchBar()`（圆角胶囊：放大镜 + `TextInput` + 清空「✕」）置于 `Column` 第一个子节点，
  顶部 padding 8；页面不再 `justifyContent(FlexAlign.Center)`。
- 搜索栏常驻（结果页也能改词重搜），`enterKeyType(Search)` / `onSubmit` 行为不变。

### C. 暂时隐藏「管理书源」入口

- 删除 `Search.ets` 中「管理书源」`Text` 与 `@Event onOpenSource`，`Index.ets` 不再传入该回调。
  > `openSourceManage()` 仍保留（「设置 → 书源管理」在用）。

### D. 搜索中动画 / 标识

- 新增 `@Local enriching: boolean`，标记「各源已返回完毕、正在 `enrichMerged` 补简介/封面」阶段；
  `enrichMerged` 有目标时置 `true`、结束置 `false`，`startSearch()` 复位。
- 新增派生 `isSearching()` = `pending > 0 || enriching`（**进度期间覆盖「聚合后刷新排序」二次刷新**）。
- 新增 `@Builder searchBanner()`：结果列表上方常驻一条弱提示行——
  - 搜索中：`LoadingProgress`（14×14，brand 色）+「正在搜索…结果仍在更新，排序可能变化」；
  - 完成：「共 N 条结果」。
  - 整行 `.opacity(isSearching()?1:0.7)` + `.animation({ duration: 260, curve: Curve.FastOutSlowIn })`
    （复用 UI-SPEC §1.3 参数）。
- 空结果居中态同步改为 `pending > 0 || enriching` 时显示 `LoadingProgress + 正在聚合书源…`。

### E. 书源状态抽屉 → `BottomDrawer`

- 删除原「收起 / 源状态」内联展开（`showSources` + 140vp `Scroll`）。
- 状态汇总行（`源 x/y 成功` + 「源状态」）保留在结果区底部作**触发入口**，点击置 `statusVisible = true`。
- 抽屉：`BottomDrawer({ visible:true, title:'源状态', sheetSize:'fit', mode:'system', onClose })`
  内为 `statusContent()`（沿用原状态行，去掉横向 padding 交给抽屉内容区）。

### F. 选择来源弹层 → `BottomDrawer`

- 删除原页面级 `bindSheet($$this.pickerVisible, this.pickerSheet(), { height: MEDIUM, dragBar:true, showClose:true })`
  与自带标题。
- 改为 `BottomDrawer({ visible:true, title:'选择来源', sheetSize:'medium', mode:'system', onClose })`
  内为 `pickerContent()`（原 `List` + 来源行，去掉横向 padding）。
- 为规避 S4 §6.3 的 V2 `@BuilderParam` 不随普通状态重跑，两个 system 抽屉均**按 `visible` 条件挂载**
  （`if (this.statusVisible) { BottomDrawer(...) { ... } }`），保证每次打开都按当前 `statuses` / `pickerGroup`
  重新求值。

---

## 2. 每项 commit 对照

> 本轮提交：`f5d66a4`（单 commit，含 4 个代码文件 + 本文件）。`git show --stat`：

| 项 | 文件 | 说明 |
|---|---|---|
| A / B / C | `pages/Search.ets` | 重写为搜索 Tab 全页（顶部输入 + 内嵌结果） |
| A / D / E / F | `pages/SearchResult.ets` | 去独立页外壳；searchToken；搜索中标识；状态/选源改 `BottomDrawer` |
| A | `pages/Index.ets` | 去掉 SearchResult 路由；`SearchPage` 接收 `onOpenDetail` |
| A | `common/Const.ets` | 删除 `ROUTE_SEARCH_RESULT` / `SearchParam` |

```
entry/src/main/ets/common/Const.ets       |   9 -
entry/src/main/ets/pages/Index.ets        |  20 +-
entry/src/main/ets/pages/Search.ets       | 113 +++++---
entry/src/main/ets/pages/SearchResult.ets | 365 ++++++++++++++++------------
```

> 说明：`AGENTS.md` / `docs/progress.md` 的改动来自并行 TTS 调研工作流，与本轮无关，未纳入。

---

## 3. 关键文件

- `entry/src/main/ets/pages/Search.ets`（A/B/C）
- `entry/src/main/ets/pages/SearchResult.ets`（A/D/E/F）
- `entry/src/main/ets/pages/Index.ets`、`entry/src/main/ets/common/Const.ets`（A）
- `entry/src/main/ets/ui/common/BottomDrawer.ets`（E/F，S3 原版，未改动）

---

## 4. 构建命令 / 结果

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# → BUILD SUCCESSFUL in 13 s 353 ms（33 tasks；仅既有 ArkTS 警告）
```

---

## 5. 真机验证结果

设备 `33Z0224424136564`；HAP 安装后 `aa force-stop` + `aa start`，搜索关键词「重生」（内置 13 源默认启用）。

| 项 | 结果 | 依据（`uitest dumpLayout` / 点击坐标，物理像素 1260×2844） |
|---|---|---|
| A 原地搜索 | ✅ | 提交后仍停留「搜索」Tab（顶栏「书架/搜索/设置」在），结果列表与输入栏同页；进详情点「‹」返回后仍保留结果与输入「重生」 |
| B 输入框置顶 | ✅ | `TextInput` bounds `[162,331][1179,480]`，紧贴顶栏（底 y≈251）之下；空态「输入书名或作者开始搜索」居中 |
| C 隐藏管理书源 | ✅ | dump 无「管理书源」节点；空态仅放大镜 + 提示 |
| D 搜索中标识 | ✅ | 提交后立即 dump 得 `正在搜索…结果仍在更新，排序可能变化`（`[128,534]`）+ 已渲染的「3个来源」结果行；约 8s 后该行变为 `共 170 条结果` |
| E 源状态抽屉 | ✅ | 点「源状态」→ 出现标题 `源状态` 的底部抽屉，列出 13 源状态（`network_error` / `✓ 50` / `no_results` 等） |
| F 选择来源抽屉 | ✅ | 点「4个来源」结果行 → 出现标题 `选择来源` 的底部抽屉，列 `小说 / bbiquge8 / 笔趣阁8 / 悠久小说`；点「小说」进入详情页，详情显示 `来源：小说` |
| 稳定性 | ✅ | 进程 PID `43801` 全程存活；`hilog` 无 `undefined is not callable` / `JSCRASH` / `CPPCRASH` |

> 结论：system 模式 `BottomDrawer`（`fit`/`medium`）与「条件挂载」方案在本机正常起落、内容正确，S3 §5.5 的 system 模式待验项关闭。
> 验证后未改动设备数据；如需可继续清理测试输入。

---

## 6. 遗留问题 / 已知风险

1. **system 模式 `BottomDrawer` 已真机通过**（源状态/选源均正常起落）；唯一未单独观察的是**关闭收场动画**：
   E/F 为「按 `visible` 条件挂载」，关闭时节点立即卸载，`bindSheet` 的退场动画可能被截断（真机观感未逐帧确认）。
   若要求退场动画完整，需改回常驻 + `visible` 切换，并另寻 V2 内容刷新方案。
2. **V2 `@BuilderParam` 陈旧内容风险**：E/F 用「条件挂载 + 每次新建组件」规避，真机已验证内容随当前 `statuses`/`pickerGroup`
   正确渲染；代价是关闭无退出动画（见上条）。
3. **搜索 Tab 无返回语义**：移除独立路由后，结果与输入栏同页，系统返回键不再有「返回搜索页」的层级；
   当前未定义「返回清空结果」行为（A 项本身要求原地展示）。若需，可后续在 Tab 返回态时清空 `submittedKeyword`。
4. **`enriching` 覆盖度**：仅合并行（`origins.length>1` 且缺简介/封面）才触发 enrich，故单源结果下
   `pending` 归零即结束；`enrichMerged` 在 `gen` 变化时提前 return 且不复位（由 `startSearch()` 复位），属有意。
5. **`searchToken` 依赖 V2 `@Monitor`**：已编译通过；`@Param` 更新与 `@Monitor` 触发同帧，使用最新 `keyword`。
6. **改动了 `Const.ets` 导出**：`ROUTE_SEARCH_RESULT` / `SearchParam` 已删；`plan.md` §「搜索 Tab」与
   `docs/architecture.md` 仍写 `SearchResultPage` 为独立页，属文档滞后（未改文档，遵「只处理搜索模块」）。
7. **`SearchResult.ets` 文件名/结构名沿用**：组件仍叫 `SearchResultPage`，但已非 `NavDestination` 路由页。
8. **其余文档未提交**：`HANDOFF-S3/4/5.md`、`AUDIT.md`、`ROOT-CAUSE.md`、`TASKS.md`、`UI-SPEC.md` 仍 untracked
   （本文件已随 `f5d66a4` 提交）。

---

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

---

# HANDOFF-S8 — 书源管理模块（A–F）

日期：2026-09-26
范围：**仅书源管理模块** —— `pages/BookSourceManage.ets` + 其检测链路所需的 Rust `detect`/`verify_chain`。
基线：`0a1a4d9`（S7 收尾）。HEAD：`a075076`（本轮提交，见 §7）。

> 构建：`cargo test` **54 passed / 0 failed**；`ohrs build --arch arm64 --release` **成功**（无警告）；
> `assembleHap` **BUILD SUCCESSFUL**（仅既有 ArkTS 警告：`audio` syscap、函数可能抛异常）。
> **真机验证已执行**：设备 `33Z0224424136564`，A–F 全部通过（含跨重启持久化，见 §5）。
> 验证中设备 `hdc` 多次掉线（同 S7 §6.3），仅「真实 timeout 样本」未取得。

约束履行：
- 仅改书源管理页与其检测链路；未触碰搜索 / 听书 / 阅读 / 书架页面，未改共享组件
  `ui/common/BottomDrawer.ets`（S3 原版直接复用）。
- C、D、E 已**联动一起改**（同一套三态语义贯穿判定、文案、字段）。
- F 的所有抽屉均使用 `HANDOFF-S3.md` 的 `BottomDrawer`（`mode:'system'`，未自绘 sheet）。
- 未新增 NAPI 导出 / JSON 字段 → `cpp/types/liblegado_core/index.d.ts` 与 `obfuscation-rules.txt` **无需更新**。

### 开工前决策（已确认）

1. **「不可用」范围**：仅**硬失败**才参与一键清理；`no_results`（该探测词未命中）与 `timeout`（可能瞬时）
   一律视为「待定」，**不自动清理**。最贴合 `ROOT-CAUSE.md` §4-B 的语义区分。
2. **一键删除无二次确认**：按用户裁定直接执行，不弹 `AlertDialog`（全项目此前亦无该组件）。
3. **D 额外修复正文分页误报**：`verify_chain` 对齐上游 `nextContentUrl` 跟读，
   修复「分页源第一章第一页 <50 字被误判 `content_short`」。

---

## 0. 调查来源（对照上游）

`@explore` 对照 `~/Documents/playground/legado-source-filter`（引擎原始实现）逐项比对，
关键结论用于 D/C：

- 上游 `tester::run` + `content_check::verify_chain` 有**逐请求 15s 超时**，但**没有链路级总超时**；
  当前 `detect()` 连 `search()` 都有的源级超时都没有（`detect_one` 直接调 `search_one`）。
- 上游 `TestStatus` 有 `Passed/Failed/DeadDomain/JsApi/Skipped/Unverified`，`no_results` 归 `Failed`
  但属**确定性**失败；`Unverified`（搜索成功但无 `bookUrl`）**不算通过**。当前把二者都压成 `no_results`。
- 上游正文跟读 `nextContentUrl`（`MAX_PAGES=30`）后再判 50 字阈值；当前只看第一页。
- `checkKeyWord` 上游仅作**关键词来源**（非校验）；`bookUrlPattern` 上游也**从未使用**。
  故本轮**未**实现二者（避免臆测），仅记录为遗留（§6）。

---

## 1. 变更清单（按项）

### A. 去掉「从剪贴板导入」入口

- 删除 `import { pasteboard } from '@kit.BasicServicesKit'`、`importFromClipboard()` 方法，
  以及「导入」行的 `剪贴板` chip。导入行现为 `从文件 / 从链接 / 恢复内置`。
- 证据：`entry/src/main/ets/pages/BookSourceManage.ets:516-523`（三个 chip）；全文件无 `pasteboard` 残留。

### B. 一键管理（检测后）

- 新增 `@Local statusVisible`（`BookSourceManage.ets:148`）与两个动作：
  - `disableUnavailable()`（`:337`）：把三态为 `unavailable` 的源 `enabled=false` 并持久化；
    文案 `已关闭 N 个不可用源` / `不可用源均已关闭`。
  - `deleteUnavailable()`（`:357`）：从 `sources` 移除 `unavailable` 源并持久化，
    同步从 `detectResults` 移除对应行；结果清空则自动收起抽屉；文案 `已删除 N 个不可用源`。
- 动作以 `sourceUrl` 集合 `unavailableUrls()`（`:326`）匹配；**仅 `unavailable` 三态可被清理**，
  `noResult` / `timeout` 不计入。
- 抽屉内两个按钮（`关闭全部不可用（N）` / `删除全部不可用（N）`）在 `N===0` 时禁用。
- 结果列表清空后抽屉自动关闭，避免空抽屉。

### C. 「no result」含义澄清（判定 + 文案）

- 新增三态派生（模块级，`BookSourceManage.ets:17-43`）：
  ```
  ok        → 可用      （完整链路通过）
  noResult  → 无结果    （stage==='no_results'：探测词未命中，源未必失效）—— 不参与一键清理
  timeout   → 超时      （stage==='timeout'：可能瞬时）—— 不参与一键清理
  其它       → 不可用    （硬失败：网络/解析/规则缺失/书名不符/正文过短等）—— 可一键清理
  ```
- 抽屉正文加一句含义说明（`:456`）：「可用=完整链路通过；无结果=探测词未命中，源未必失效；
  超时=请求超时，可能瞬时。以上两者不参与一键清理。不可用=链路失败…」。
- 检测摘要由 `可用 X / N` 改为四态计数 `可用 X / 无结果 Y / 超时 Z / 不可用 W`（`:321`）。
- **导入摘要文案**由 `成功 X / 排除 Y` 改为 `规则通过 X / 规则排除 Y`（`:211`），
  明确 gate 只做**规则层**过滤，不等于运行可用（呼应 `ROOT-CAUSE.md` §4-A 的「误认可用」）。

### D. 检测准确度（超时 / 成功判定）

Rust `rust/legado-engine/src/runtime.rs`：

1. **源级总超时**：新增 `DEFAULT_DETECT_TIMEOUT_MS = 45_000`（`:425`）；
   `detect()` 增加 `timeout_ms` 参数（`:427-434`，`clamp(10_000,120_000)`）；
   `detect_one` 用 `tokio::time::timeout` 包裹整条链路（`:448-465`），超时输出
   `stage='timeout'` / `detail='检测超时'`。此前 `detect` 无任何源级超时（最坏 4×15s）。
2. **`no_book_url` 归类**：搜索命中但 `bookUrl` 为空时不再落入 `bookinfo_fetch`，
   显式返回 `stage='no_book_url'`（`:496-500`），语义更准。
3. **正文分页跟读**：`verify_chain` 按 `nextContentUrl` 循环跟读（`MAX_PAGES=30`，
   `runtime.rs:610-660`），累计字数达标（≥50）即通过；对齐上游 `content_check`，
   修复分页源第一章第一页过短被误判 `content_short`。

`rust/legado-core/src/lib.rs`：

4. `DetectOpts` 增加 `timeoutMs`（`#[allow(non_snake_case)]`，`:113-132`），
   缺省取 `DEFAULT_DETECT_TIMEOUT_MS`；NAPI 签名不变。

### E. 书源信息展示澄清（字段重设计）

- **导入摘要**：`成功/排除` → `规则通过/规则排除`（见 C，`:211`）。
- **检测结果行**重设计（`statusRow()`，`:420`）：由原
  `可用（{contentLen} 字 / {elapsedMs}ms）` 或 `{stage}: {detail}`（含英文 reason 码）改为：
  - 左列：源名（回退 URL）+ 明细行
    - 可用：`正文 {contentLen} 字 · {elapsedMs}ms`
    - 其它：`{中文阶段名} · {elapsedMs}ms`
  - 右列：三态**徽标**（可用=brand / 无结果=text_3 / 超时=info / 不可用=warning）。
- 新增 `detectStageLabel()`（`:46`）把英文 `stage`（`no_results/network_error/...`）全部映射为中文，
  不再向用户暴露 `no_results:` 这类内部码。

### F. 书源状态抽屉 → `BottomDrawer`

- 页面根由 `Column` 改为 `Stack`；原**内联**「检测结果」区块删除，
  改为条件挂载的 `BottomDrawer`（`:694`）：
  ```ts
  BottomDrawer({ visible: true, title: '书源状态', sheetSize: 'large', mode: 'system', onClose })
  { this.statusContent() }
  ```
- `statusContent()`（`:450`）自上而下：检测摘要 + 三态含义说明 + 可滚动结果列表
  （`Scroll` + `constraintSize({ maxHeight: 320 })`）+ 两个一键按钮。
- 检测完成自动打开抽屉（`runDetect()` 置 `statusVisible=true`，`:303`）；
  关闭后结果非空时，页面显示 `检测完成… / 书源状态` 入口行（`:650` 附近）可再次打开。
- 沿用 S6 的「按 `visible` 条件挂载」规避 V2 `@BuilderParam` 陈旧内容问题。

---

## 2. 变更文件 / 统计

| 项 | 文件 | 说明 |
|---|---|---|
| A/B/C/E/F | `entry/src/main/ets/pages/BookSourceManage.ets` | 去剪贴板；三态语义；字段重设计；检测结果改 `BottomDrawer` + 一键管理 |
| D | `rust/legado-engine/src/runtime.rs` | 源级超时；`no_book_url`；正文分页跟读；`detect` 增参 |
| D | `rust/legado-core/src/lib.rs` | `DetectOpts.timeoutMs` |
| — | `entry/libs/arm64-v8a/liblegado_core.so` | `ohrs build --arch arm64 --release` 重编 |

```
 entry/libs/arm64-v8a/liblegado_core.so        | Bin 4842696 -> 4839864 bytes
 entry/src/main/ets/pages/BookSourceManage.ets | 623 ++++++++++++++++++--------
 rust/legado-core/src/lib.rs                   |   8 +-
 rust/legado-engine/src/runtime.rs             |  94 +++-
```

> `AGENTS.md` / `docs/progress.md` 的改动来自并行 TTS 工作流，与本轮无关，未纳入。

---

## 3. 关键文件

- `entry/src/main/ets/pages/BookSourceManage.ets`（A/B/C/E/F）
- `rust/legado-engine/src/runtime.rs`（D：`detect`/`detect_one`/`detect_chain`/`verify_chain`）
- `rust/legado-core/src/lib.rs`（D：`detect` opts）
- `entry/src/main/ets/ui/common/BottomDrawer.ets`（F，S3 原版，未改动）

---

## 4. 构建命令 / 结果

```bash
# Rust 主机测试
cd rust/legado-engine && cargo test
# → 54 passed; 0 failed

# 交叉编译
export OHOS_NDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony
cd rust/legado-core && ohrs build --arch arm64 --release
cp dist/arm64-v8a/liblegado_core.so ../../entry/libs/arm64-v8a/
# → 成功，无警告；.so 4,839,864 bytes

# HAP
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# → BUILD SUCCESSFUL in 18 s 974 ms（33 tasks；仅既有 ArkTS 警告）
```

---

## 5. 真机验证结果

设备 `33Z0224424136564`；HAP 安装 → `aa force-stop` → `aa start`，进入「设置 → 书源管理」。

| 项 | 结果 | 依据（`uitest dumpLayout`，物理像素 1260 宽） |
|---|---|---|
| A | ✅ | 「导入」行仅 `从文件 / 从链接 / 恢复内置`；dump 中 `剪贴板` 命中 0 |
| F | ✅ | 点「检测可用性」后自动弹出标题 `书源状态` 的底部抽屉；标题栏 ✕ 可关闭；关闭后页面出现 `书源状态` 入口行可再次打开 |
| C | ✅ | 抽屉摘要 `检测完成：可用 8 / 无结果 2 / 超时 0 / 不可用 3`；含义说明行完整；`搜索未命中` 的源徽标为 `无结果` 而非 `不可用` |
| E | ✅ | 结果行明细为中文：`正文 2540 字 · 1638ms`、`网络错误 · 44ms`、`搜索未命中 · 661ms`；无 `no_results:` 等内部码 |
| D | ✅（部分） | 失败行正确归类并本地化；本轮 `超时 0`（无超时样本），45s 源级上限已编入；第二次检测为 `可用 7 / 无结果 2 / 超时 0 / 不可用 4` |
| B 删除 | ✅ | 点「删除全部不可用（3）」→ 摘要 `已删除 3 个不可用源`、页头 `书源（10/10 启用）`，3 行从源列表与抽屉同时消失 |
| B 关闭 | ✅ | `恢复内置`（13/13）后重检、点「关闭全部不可用（4）」→ 摘要 `已关闭 4 个不可用源`、页头 `书源（9/13 启用）` |
| B 持久化 | ✅ | `aa force-stop` + `aa start` 后重进「书源管理」，页头仍为 `书源（9/13 启用）`，4 个关闭态持久生效 |
| 稳定性 | ✅ | 全程 `hilog` 无 `JSCRASH` / `CPPCRASH` / `is not callable`；无崩溃 |

未及验证：
- **真实 timeout 样本**：本轮无源触发 45s 上限（多次检测均 `超时 0`）。

> 验证结束已点「恢复内置」复位，设备书源回到 `13/13 启用`，未残留测试数据。

---

## 6. 遗留问题 / 已知风险

1. **真机验证**：A–F 全部通过（§5）；仅「真实 timeout 样本」因未触发 45s 上限而未观测到。
2. **无二次确认**：一键删除直接执行（用户裁定）。若要防误删，后续可加 `AlertDialog` 或二次点击确认。
3. **`timeout` 不参与清理**（用户裁定）：瞬时超时的好源不会被误删，但需要用户手动复查。
4. **未实现 `checkKeyWord` / `bookUrlPattern`**：上游 `checkKeyWord` 只作关键词来源、
   `bookUrlPattern` 上游亦未使用，本轮不做（避免臆测语义）。检测仍固定探测词 `重生`
   （`DEFAULT_DETECT_KEYWORD`）。
5. **无网络重试 / transient 模型**：`search_one` 仍单次请求；上游有 1 次抖动重试 + 多轮重试。
   本轮超时已兜底，未加 retry 以控制面。
6. **`detect()` 签名变更**：`runtime::detect` 增加 `timeout_ms` 参数（Rust 内部 API），
   `legado-core` 与引擎测试已同步；无 ArkTS 侧影响（NAPI 签名不变）。
7. **`statusContent` 结果列表上限 320vp**：源很多时需滚动，未做分页/虚拟列表；源数十级内可接受。
8. **`sourceUrl` 匹配一键清理**：重复 `sourceUrl` 的源会被一并处理（视为同一源），
   与 `ROOT-CAUSE.md` §4 备注的重复 URL 展示问题同源。

---

## 7. 提交状态

本轮提交：`a075076`（5 个文件 + 本文件）。纳入提交的文件：

```
entry/src/main/ets/pages/BookSourceManage.ets
rust/legado-engine/src/runtime.rs
rust/legado-core/src/lib.rs
entry/libs/arm64-v8a/liblegado_core.so
HANDOFF-S8.md
```

`AGENTS.md`、`docs/progress.md`（并行 TTS 工作流）与本文件外的 untracked 文档（`AUDIT.md` /
`ROOT-CAUSE.md` / `TASKS.md` / `UI-SPEC.md` / `HANDOFF-S3..7.md`）沿旧例不纳入。

