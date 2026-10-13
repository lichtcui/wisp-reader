# UI-SPEC — 底部抽屉（统一规范）

状态：**生效（normative）** · 更新：2026-10-06 · 基线：`6054929`
适用范围：全项目所有**从底部上滑的抽屉 / 面板**（含阅读页目录、阅读设置）。

> **本文件是抽屉样式与动效的唯一权威来源。** 改动抽屉前必读 §2 调用点清单与 §3 检查清单。
>
> **取代（superseded）**：本文件取代以下已失效记载 ——
> - 旧 `UI-SPEC.md`（`596f16a` 引入、`c044735` 随文档整理被删除）中「凡能走系统 `bindSheet` 的抽屉，动画一律用系统默认，不额外包 `animateTo`；只有 Reader 页内浮层走自定义时长」；
> - `docs/bugfix/RELEASE-NOTES.md` §1.2「听书目录抽屉由 `overlay` 改为 `system` 模式」、§1.3「听书目录用 overlay 模式 → `system` + `large`」。
>
> **现行规则与上述相反：全部抽屉统一走页内浮层（overlay），不使用系统 `bindSheet`。** 若再次看到「目录走系统 sheet」之类的整改建议，以本文件为准，**不要回改**。

---

## 1. 统一规范（normative）

### 1.1 实现与模式

| 项 | 规定 |
|---|---|
| 唯一实现 | `entry/src/main/ets/ui/common/BottomDrawer.ets`（`@ComponentV2`） |
| `mode` | **固定 `'overlay'`**。`'system'`（`bindSheet`）分支保留仅为兼容，**新代码禁止使用** |
| 直接 `bindSheet` | **禁止**（裸 `bindSheet` 视为缺陷）；`bindMenu` 不算抽屉，不在此范围 |
| 挂载方式 | **常驻挂载**：`BottomDrawer({ visible: this.flag })`，`@Monitor('visible')` 驱动动画。**禁止** `if (this.flag) { BottomDrawer({ visible: true }) }`（首帧即最终态 → 无上滑动画） |
| 显隐动画 | 打开 `260ms` / 关闭 `200ms`，`Curve.FastOutSlowIn`。**禁止按页面自定义时长**（常量 `OVERLAY_OPEN_MS` / `OVERLAY_CLOSE_MS`） |

### 1.2 打开/关闭行为（「从屏幕最底部上滑」）

1. 面板关闭时**仍留在组件树内**，靠 `translate({ y: panelHeight })` 停在视口下方 → 页面加载即完成测高。
2. 打开：从「面板顶边正好贴着屏幕底边」起滑，行程 = 面板实测高度 `panelHeight`（`onAreaChange` 测量）。
   - 兜底值 `PANEL_UNMEASURED = 3000` **仅**用于「尚未测到高度」的极短窗口；若它成了实际动画起点，可见上滑会被压缩成"弹出"——**这是本规范要消除的缺陷**。
3. 关闭：`overlayShown=false` → `translate` 回到 `panelHeight`；**不卸载**面板。
4. 拖拽关闭：下拉位移 > 面板高 `30%` 或 `velocityY > 1000` → 关闭，否则回弹；`dragOffset` 在下次打开时复位。
5. 关闭途径：点遮罩、拖拽下拉、标题栏 X（`showHeader` 时）。

#### 1.2.1 必须锚定到**屏幕物理底边**（真机踩坑）

抽屉宿主的高度 = **所在页面布局区**，而页面布局区通常**不等于**屏幕底边：

| 页面类型 | 布局区底边 | 后果（未处理时） |
|---|---|---|
| `NavDestination` 页（书源管理） | 屏幕底 − 底部安全区（本机 127px / 63.5vp） | 面板从**安全区上方**弹出 |
| `TabContent` 内的页（搜索页 `SearchResult`） | 底部 tab 栏顶边（本机 2597px） | 面板从**底部 menu 上方**弹出，且面板底部被 tab 栏遮挡 |
| 阅读页 `Reader` | 已是全屏（无 tab 栏、无安全区内缩） | 正常，是基准 |

因此**必须**满足以下两条之一，缺一即为缺陷：

1. **页内模式（`mode: 'overlay'`）**：宿主外扩安全区——`overlayHost` 的 Stack 加
   `.ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])`
   **再加** `.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])`（在 `.alignContent(Alignment.Bottom)` 之前）。
   仅适用于**页面本身已能到屏幕底边**的场景（`NavDestination` 页、阅读页）。
2. **窗口层模式（`mode: 'cover'`）**：抽屉用 `bindContentCover` 画在**窗口模态层**（`ModalTransition.NONE` +
   `backgroundColor: Color.Transparent`），面板天然锚定窗口底边，且**在底部 tab 栏之上**。
   **凡是位于 `TabContent`（底部 tab 页）内的抽屉，一律用 `mode: 'cover'`。**
   `coverBody` 同样要加 `.ignoreLayoutSafeArea(...)` + `.expandSafeArea(...)`（见下）。

> **`ignoreLayoutSafeArea`（布局外扩，API 20）与 `expandSafeArea`（绘制外扩）缺一不可**：
> `expandSafeArea` 只外扩**背景绘制区域**，不改变子组件的布局——单用它面板仍停在安全区上沿，
> 面板底边阴影（`offsetY:-4` 下沿约 20px）会漏成安全区上方的**一条灰影带**。
> `ignoreLayoutSafeArea` 才真正外扩**布局范围**，使 `alignContent(Bottom)` 把面板锚到屏幕物理底边、
> 盖住安全区，底边阴影也被推到屏幕外。二者同时设置时 `ignoreLayoutSafeArea` 先生效，`expandSafeArea` 在其基础上再生效。

> **禁止**再让底部 tab 栏「让位/隐藏/条件渲染」来给抽屉腾空间（2026-10-06 已废弃 `model/DrawerOverlay.ets` 计数单例 +
> `Index.ets` 的 `if (openCount === 0)` 条件渲染）：那样 tab 栏会先消失再出现（真机反馈缺陷），
> 且抽屉打开/关闭时整页会重新布局（背后内容跳动）。`cover` 模式下 tab 栏**原位不动**，只被抽屉遮罩盖住——
> 这正是阅读页目录抽屉的行为。

#### 1.2.2 关闭后必须**完全不可见**（无残影阴影）

面板常驻后，`translate` 只是移出视口；其 `shadow`（`radius 24, offsetY -4`）仍会在**面板顶边上方约 24–28px** 处绘制，而该处仍在宿主内 → 关闭时屏幕底部出现**一条两端缺角的阴影带**（缺角来自面板圆角）。

**规定**：用 `@Local panelShown` 控制 `visibility`——

- 打开：`panelShown = true` → `visibility(Visible)`；
- 关闭动画结束（`OVERLAY_CLOSE_MS + 40ms`）且仍为关闭态：`panelShown = false` → `visibility(Hidden)`。

必须用 `Visibility.Hidden`（**不要用 `None`**）：`Hidden` 保留布局与 `onAreaChange`，面板高度测量不丢；`None` 会退出布局导致下次打开退化成 3000 兜底 → 回到"弹出"缺陷。

> 宿主的 `clip(true)` **不能**裁掉阴影，不要依赖它。
>
> **打开态底部阴影带**（本节 1.2.1 所述）：面板未锚定到屏幕物理底边（未外扩布局）时，面板**底边**阴影会漏
> 在底部安全区上沿，表现为一条水平灰影；需用 §1.2.1 的 `ignoreLayoutSafeArea`（而非仅 `expandSafeArea`）修复。

### 1.3 视觉

| 项 | 规定 |
|---|---|
| 顶部圆角 | `20`（仅 topLeft / topRight） |
| 阴影 | `radius: 24, color: '#33000000', offsetX: 0, offsetY: -4` |
| 属性顺序 | `borderRadius` → `shadow` → `clip(true)`（**`shadow` 必须在 `clip` 之前**，否则阴影被裁掉） |
| 遮罩 | `Color.Transparent`（**不压暗**，番茄式）。`app.color.mask` 仅 system 模式使用 |
| 点遮罩关闭 | 遮罩层 `onClick → onClose` |
| 面板背景 | 默认 `$r('app.color.bg_page')`；阅读页传 `panelBackground: this.bgColor()` 以跟随日夜模式 |
| 拖拽指示条 | 自绘 `36×4`、radius 2、`divider` 色，上边距 8；system 模式的系统 `dragBar` 不再使用 |

> **为什么必须有阴影**：overlay 面板底色是纯白 `bg_page`，遮罩又是透明的，背后的页面同样纯白 → 白叠白时 `borderRadius` 圆角边界**完全不可见**。阴影用于勾勒顶部边缘与圆角。
>
> **关闭态例外**：阴影只在打开时存在；关闭后必须整块不可见，见 §1.2.2。

### 1.4 命中测试（**改了必须一起改**，真机踩坑）

面板常驻挂载后，宿主与面板在**关闭状态**仍占据全屏布局区，若不处理会吞掉页面手势（表现为**页面无法滚动/无法点击**）：

| 位置 | 规定 |
|---|---|
| 宿主 `Stack`（`overlayHost` 根） | `.hitTestBehavior(HitTestMode.None)`（**必需**，缺它整页不可滚动） |
| 遮罩 `Column` | `.hitTestBehavior(this.overlayShown ? HitTestMode.Default : HitTestMode.None)` |
| 面板外层 `Column` | `.enabled(this.overlayShown)` + `.hitTestBehavior(this.overlayShown ? HitTestMode.Default : HitTestMode.None)` |

### 1.5 结构（自上而下）

1. 拖拽指示条（§1.3）
2. `showHeader === true` 时：标题栏 48vp（标题 17fp Medium，左 padding 20；右侧 X `SymbolGlyph(xmark)` 20fp，40×40 热区）+ 1px `divider`
   - 标题色 / 图标色默认 `text_1` / `text_3`；面板底色**不跟全局主题**的抽屉（阅读页换源：底色为 `reader_bg`，`reader_bg` 在浅色系统下也是深色）必须传 `titleColor` / `iconColor`（传阅读页的 `textColor()` / `dimColor()`）。
3. 内容区：左右 padding 16、底部 padding 24，`layoutWeight(1)`（`fit` 时为 0）
   - 内容区**没有顶部内边距**：首屏元素自带顶部留白（阅读页目录/设置为卡片自带 12vp；
     「源状态」的统计区为 `padding({ top: 16, bottom: 24 })`）。
   - 区段之间要通栏分割线时，在内容里用
     `Divider().color($r('app.color.divider')).strokeWidth(1).margin({ left: -16, right: -16 })`：
     负外边距抵消内容区左右 padding 后与标题栏分割线同宽。

`showHeader` 约定：阅读页目录 / 阅读设置为 `false`（内容自带头部），**其余一律 `true`**（含阅读页**换源**：面板底色虽跟阅读主题，但用 `titleColor` / `iconColor` 传色即可用标准标题栏）。

> 新增抽屉（第 9 处起）必须同时登记到本表。

### 1.6 尺寸语义

| `sheetSize` | 高度 | 用例 |
|---|---|---|
| `large` | 宿主高的 `90%` | 阅读页目录、「源状态」、搜索结果「选择来源」、书源状态、听书目录 |
| `medium` | 宿主高的 `70%` | （暂无调用点，保留语义） |
| `fit` | 内容高度，`constraintSize({ maxHeight: '90%' })` | 阅读页设置 |

> 宿主 = 抽屉所在页面的根 `Stack`（通常已排除页面顶部 title bar），故 `90%` 的**底边仍在屏幕最底部**。

### 1.7 设计令牌（沿用）

| Token | 值 | 用途 |
|---|---|---|
| `hitTarget` | 44×44 | 图标按钮热区 |
| `barHeight` | 52 | 顶栏高度 |
| `glyphSize` | 24 | 返回 / 关闭 SymbolGlyph |
| `sheetTopRadius` | 20 | 抽屉顶部圆角 |
| `sheetCardRadius` | 12 | 抽屉内卡片 |
| `dragBar` | 36×4 / radius 2 | 拖拽指示条 |

颜色：`mask` L `#52000000` / D `#80000000`；`bg_page` L `#FFFFFF` / D `#121212`；
`divider` L `#EDEDED` / D `#2A2A2A`；`brand` `#DA3838`；`text_1` `#333333`。

> 底色跟随**阅读日夜主题**（非系统主题）的面板（换源抽屉）慎用带透明度的自定义令牌：
> 它无法按系统主题在 base/dark 间分值。换源面板的当前源标注**只用行首 3vp 品牌色竖条 +
> 品牌色源名**，不加行底色（真机试过 12% 品牌底，观感偏脏，已撤）。

---

## 2. 调用点清单（**共 8 处，样式改动必须全部同步**）

| # | 位置（快照 `6054929`） | 场景 | `sheetSize` | `showHeader` | 背景 |
|---|---|---|---|---|---|
| 1 | `pages/Reader.ets:1383` | 阅读页 · 目录（倒序） | `large` | `false` | `this.bgColor()` |
| 2 | `pages/Reader.ets:1396` | 阅读页 · 目录（正序） | `large` | `false` | `this.bgColor()` |
| 3 | `pages/Reader.ets:1410` | 阅读页 · 阅读设置 | `fit` | `false` | `this.bgColor()` |
| 4 | `pages/SearchResult.ets:633` | 搜索结果 · 源状态 | `large` | 默认 `true` | 默认 |
| 5 | `pages/SearchResult.ets:645` | 搜索结果 · 选择来源 | `large` | 默认 `true` | 默认 |
| 6 | `pages/BookSourceManage.ets:706` | 书源管理 · 书源状态 | `large` | 默认 `true` | 默认 |
| 7 | `pages/Listening.ets:382` | 听书页 · 目录 | `large` | 默认 `true` | 默认 |
| 8 | `pages/Reader.ets`（`grep -n "PANEL_SOURCE"`） | 阅读页 · 换源（v1.1） | `large` | `true`（传 `titleColor` / `iconColor`） | `this.bgColor()` |

> 行号会漂移；**以命令为准**：`grep -rn "BottomDrawer({" entry/src/main/ets/pages/`
> 新增抽屉（第 8 处）必须同时登记到本表。

---

## 3. 改动检查清单（DoD）

改抽屉（含动效/尺寸/命中测试）时逐项确认：

- [ ] `mode` 仍为 `'overlay'`；没有新增裸 `bindSheet`
- [ ] 调用点仍为**常驻挂载**（`visible: this.flag`），没有被改成 `if (flag) { ... }`
- [ ] §1.4 三处命中测试齐全（改完必须真机确认**页面可滚动、可点击**）
- [ ] §1.2.1 屏内抽屉（`overlay`）宿主有 `ignoreLayoutSafeArea(...BOTTOM)` **且** `expandSafeArea(...BOTTOM)`；tab 页内抽屉（`cover`）面板底边 = 屏幕物理底边，且**打开/关闭全程底部 tab 栏位置不变**
- [ ] §1.2.2 关闭后抽屉**不参与绘制**（`overlay`：`panelShown = false` / `visibility(Hidden)`；`cover`：整个模态层卸载），屏幕底部**无阴影残影**
- [ ] 阴影在 `clip(true)` 之前；圆角 20 可见
- [ ] 打开/关闭时长未被单独覆盖
- [ ] §2 的 8 处调用点**全部同步**（样式改动不分页面，一处改即全改）
- [ ] `showHeader` 约定未被破坏
- [ ] 新增/改名的 JSON 字段（若有）已加进 `entry/obfuscation-rules.txt`
- [ ] 真机闭环：编译 → 安装 → `aa force-stop` → `aa start` → 观察（见 `docs/development.md`）

---

## 4. 验证方法（真机逐帧）

动效类改动**必须实测**，不能只看代码：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
# 连拍（每帧约 0.3s）
$HDC shell "rm -f /data/local/tmp/u*.jpeg; uitest uiInput click <x> <y>; \
  for i in 1 2 3 4 5 6; do snapshot_display -f /data/local/tmp/u\$i.jpeg; done"
$HDC file recv /data/local/tmp/u1.jpeg /tmp/u1.jpeg     # 逐帧取回
sips -s format bmp /tmp/u1.jpeg --out /tmp/u1.bmp       # 纯 Python 解析 BMP，无需 PIL
```

判定标准：
- **必须在屏幕最底部起步**：首帧面板顶边贴近屏幕底边（本机 1260×2844）；
- **轨迹单调**：位置逐帧递减到最终位，带 `FastOutSlowIn` 特征（先加速后减速）；
- **不允许"弹出"**：首帧即最终位置 = 无动画，缺陷。

> **慢放诊断技巧**：把 `OVERLAY_OPEN_MS` 临时改成 `1500`，连拍即可看清完整轨迹；**测完必须改回 `260` 并重新安装**（避免把诊断值留在代码里）。

已知干扰：页面顶部 title bar（y < 约 317 物理像素）在抽屉之上，点它会**穿透到 title bar** 而不是遮罩 → 点遮罩关闭请用 y ≈ 400~450。

---

## 5. 变更历史

| 日期 | 变更 |
|---|---|
| 2026-10-13 | **书架「更新」进行中进度行显示未检查数**（T-SHELF-7 收尾小迭代）：`shelfNormalHeader()` 的进度文案由硬拼 `检查中 done/total` 改为 `ShelfUpdater.shelfProgressText(done,total,failed)`（新导出纯函数）—— 无失败 `检查中 1/2`，有失败 `检查中 1/2 · 1 本未检查`，`total = 0` 时 `检查中…`；进度回调相应由 `(done,total)` 扩为 `(done,total,failed)`（累计失败数，不含 `skipped`）。**样式与令牌未动**（13fp `text_3` / `maxLines(1)`；「更新」仍 16fp `brand` + 44 热区 + `accessibilityText` = `更新全部书籍` / `正在检查更新`），无新组件。文件：`pages/Index.ets`、`model/ShelfUpdater.ets`。**主机侧 30 断言 `ALL PASS` + `make hap` 通过；真机 2026-10-13 已拍到两种形态**（无失败 `检查中 1/2` 实测宽 211px；有失败 `检查中 1/2 · 1 本未检查` 在失败源注入下中途上屏）；最长文案 `检查中 20/20 · 19 本未检查` 按实测字宽外推 ≈550px vs 可用 ≈710px ⇒ 余量 ~80vp、不截断，但该最长形态未在真机出现（架上网络书不够） |
| 2026-10-13 | **书架顶栏新增「更新」入口**（T-SHELF-7，**2026-10-13 真机验收：入口位置/进行中「检查中 N/M」/编辑态隐藏均已验证**）：`shelfNormalHeader()` 在 `Blank()` 与 `MoreMenuButton` 之间插 `shelfUpdateAction()` —— 「更新」文字按钮（16fp、`brand` 令牌、行高 44 沿用 `hitTarget` 热区约定、`accessibilityText` = `更新全部书籍` / `正在检查更新`），进行中左侧显示 `检查中 done/total`（13fp `text_3`）且按钮转 `text_3` 并防重入，编辑态不显示。**未新造样式/令牌**（§1.1–§1.4 检查项未受影响，§2 的 8 处抽屉调用点未动），无新组件（`@Builder` 内联）。文件：`pages/Index.ets` |
| 2026-10-13 | **阅读页「换源」检索提速 + 候选漏判修复**（代码已合 + **真机已验证**：候选 2→7 行、切换 ≤1s、重开抽屉秒上屏）：① 行内占位文案「（该源无最新章节规则）」→「（该源未提供最新章节）」（它是「搜索规则没给 `lastChapter`」而非源故障；现在行上屏后会被预热详情回填成「最新：xxx」）；② 状态行右侧新增两个文字入口（12fp 品牌色、左内边距 12）——提前收尾（候选够 3 条 / 全局派发预算 10s 到点）时显示「继续检索」、会话缓存命中时显示「重新检索」；③ 进度文案补两种状态：`已检索 x/y 个书源 · 候选已够用` / `上次检索到的 N 个候选`。**样式与动效未动**（§1.1–§1.4 检查项均未受影响：行高 60vp、状态行 12fp、当前源竖条与品牌色源名均不变）。文件：`components/SourceSwitchPanel.ets` |
| 2026-10-12 | **阅读页「换源」文案与当前源标注整改**（真机验证：夜间 `reader_bg` #181820 / 日间 #FFFFFF 两套主题 + 0 源空态）：① 删内容区状态行的「当前 xxx」；② 候选数上移到标题 → `title: '换源 · N 个候选'`（`SourceSwitchPanel` 新增 `@Event onCount` 上报，与「选择来源 · N」同规格；面板删掉 `currentSourceName` 参数）；③ 当前源行去掉「当前源」文字徽标，改为**行首 3vp 品牌色竖条 + 品牌色源名**，其余行留同宽透明占位以保持源名左对齐（曾试过整行 12% 品牌底，观感偏脏 → 已撤，令牌也删了）；④ 进度行（12fp 次要色）**常驻占位、其下不画分割线**：检索中显示 x/y，检索完只剩空文本（防列表在搜索结束时上跳 ~33vp；该行下的通栏分割线试过两个版本都被真机否掉——紧贴标题栏分割线的第二条横线观感多余）；⑤ 书源行之间**取消分割线**（`List.divider` 已删）；⑥ `total === 0` 的空态文案独立成「没有启用的书源」；⑦ 「（该源未返回最新章节）」→「（该源无最新章节规则）」（该文案 = 该源搜索规则无 `lastChapter`，非源故障）。文件：`components/SourceSwitchPanel.ets`、`pages/Reader.ets` |
| 2026-10-12 | **阅读页「换源」抽屉对齐搜索结果「选择来源」**（真机验证）：① 去自绘头部 → `showHeader: true` + `title: '换源'`；`BottomDrawer` 新增 `@Param titleColor` / `iconColor`（默认 `text_1` / `text_3`，其余 7 处调用点不变），换源传 `textColor()` / `dimColor()` 解决「深色面板 + 浅色系统的固定 `text_1` 不可读」；② 当前源 + 检索进度下沉为内容区顶部状态行（12fp 次要色、上下 padding 8 + 通栏分割线，与「源状态」统计区同规格）；③ 行改为定高 60vp、`Row({ space: 8 })` + `Column({ space: 3 })`，分割线由行内 `Divider` 改为 `List.divider({ startMargin: 16 })`（与「选择来源」逐项一致）。**保留**换源特有元素：「当前源」徽标、「置信 N」、右侧「切换」按钮（未加 `›` 箭头，右侧位被「切换」占用）。文件：`ui/common/BottomDrawer.ets`、`components/SourceSwitchPanel.ets`、`pages/Reader.ets` |
| 2026-10-12 | 新增第 8 处调用点：**阅读页 · 换源**（v1.1）。`mode: 'overlay'` + `sheetSize: 'large'` + `showHeader: false`（阅读页必须自绘头部：面板跟随日夜模式，标题栏的固定 `text_1` 在夜间不可读），内容组件 `components/SourceSwitchPanel.ets`，宿主 `pages/Reader.ets`。§2 表与 §1.5 `showHeader` 约定同步；**样式与动效未动**（§1.1–§1.4 检查项均未受影响） |
| 2026-10-06 | 「源状态」抽屉内容整改（真机验证）：去「搜索源名」输入框；关闭抽屉即复位为全部收起；分组按**置信度影响**排序（成功置顶，`penaltyFor` 与扣分同表）；展开后的书源行去色点（组头保留）；修「组头 3 源只展开 2 行」（ForEach key 用 URL 撞上同 URL 重复书源 → 改组内序号 key）。另：统计区改 `padding { top:16, bottom:24 }` 并在与列表之间加通栏分割线。**同步本文件**：`sheetSize` 实际使用为 6×`large` + 1×`fit`（阅读页设置）——「源状态」「选择来源」均改为 `large`（§1.6 / §2 原记 `fit` / `medium` 系陈旧），`medium` 暂无调用点 |
| 2026-10-06 | 全部抽屉统一 overlay：`BookSourceManage` / `SearchResult` / `Listening` 去 `system` 改常驻挂载；面板改**常驻测量**（消除首开"弹出"）；补 §1.4 命中测试（修复页面不可滚动）；保留圆角阴影。基线 `6054929`，改动未提交 |
| 2026-10-06 | 真机反馈修复：① §1.2.1 面板必须锚定**屏幕物理底边**（宿主 `expandSafeArea` + `Index` 打开期间隐藏底部 tab 栏，新增 `model/DrawerOverlay.ets` 计数单例）——修复「书源状态/书源选择从底部 menu 上方弹出」「书源校验从安全区上方弹出」；② §1.2.2 关闭后 `visibility(Hidden)` ——修复「未打开时底部残留阴影带（两端缺角）」 |
| 2026-10-06 | 真机反馈二次修复：tab 页内抽屉改用新的 **`mode: 'cover'`**（`bindContentCover` 窗口模态层）——面板锚定屏幕底边并**盖住底部 tab 栏**，tab 栏**原位不动**；**废弃**「隐藏 tab 栏腾空间」方案（`model/DrawerOverlay.ets` 已删除、`Index.ets` 恢复无条件底部栏）。搜索页「源状态 / 选择来源」两个抽屉迁移到 `cover` |
| 2026-10-06 | 修复「源状态/选择来源/书源状态」打开态底部安全区上方残留灰影带：`expandSafeArea` 只外扩绘制不扩布局，面板仍停在安全区上沿、底边阴影漏成一条灰影。补 `ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.BOTTOM])`（API 20）真正外扩布局，面板锚到物理底边、盖住安全区。`BottomDrawer.ets` 的 `overlayHost` / `coverBody` 两处同步修改 |
| 2026-10-06 | 「选择来源」抽屉内容整改（去搜索 + 去分组）：删抽屉内搜索框（`pickerSearchBar` / `pickerQuery` / 过滤与「匹配 N / M」）与全部分组机制（`ListItemGroup` sticky 组头、折叠、`primaryGroup`）；“选择来源”改为**平铺 `LazyForEach` 列表**（行定高 60vp），排序仍为 章节号 ↓ → 置信度 ↓ → 源名。另修「同 URL 重复书源」：新增 `SourceRepository.dedupeByUrl()`，搜索前按 `bookSourceUrl` 去重（消除「`笔趣阁0905` 组里两个源同名站」现象）。§1.6 / §2 的 `sheetSize`/`showHeader` 不变，**样式与动效未动**（§1.1–§1.4 检查清单均未受影响） |
| （更早） | 抽屉统一白色背景 + 去遮罩变暗 + 番茄式上拉动画（`176a5d7`） |

## 6. 相关规范（仍有效，组件已更名）

| 项 | 组件 | 文件 |
|---|---|---|
| 返回键 | `AppBackButton`（原 spec 名 `AppNavBack`） | `ui/common/AppBackButton.ets` |
| 省略号功能键 | `MoreMenuButton`（原 `AppMoreButton`），44×44 热区 | `ui/common/MoreMenuButton.ets` |

返回键约定：4 个设置页保留系统 `NavDestination.title()` 自带箭头；自绘顶栏页统一 `AppBackButton`。
