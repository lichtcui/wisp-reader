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