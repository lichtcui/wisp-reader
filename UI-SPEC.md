# UI-SPEC — 返回键 / 省略号功能键 / 底部抽屉

范围：仅统一这三项。不含排版、字体、业务逻辑。
状态：规范定稿（三项决策已确认，见 §5）。本文档只定义规范，不含代码改动。

## 1. 设计令牌

### 1.1 尺寸与圆角（vp）

| Token | 值 | 用途 |
|---|---|---|
| `hitTarget` | 44×44 | 所有图标按钮热区 |
| `barHeight` | 52 | 顶栏高度 |
| `glyphSize` | 24 | 返回 / 关闭 SymbolGlyph |
| `sheetTopRadius` | 20（topLeft / topRight） | 所有底部抽屉顶部圆角 |
| `sheetCardRadius` | 12 | 抽屉内卡片 |
| `dragBar` | 36×4，radius 2 | 自定义拖拽指示条 |
| `ellipsisDot` | 4×4，gap 3，radius 2 | 省略号 |

### 1.2 颜色

| Token | Light | Dark | 来源 |
|---|---|---|---|
| `mask`（新增） | `#52000000` | `#80000000` | 抽屉 / 浮层遮罩 |
| `bg_page` | `#FFFFFF` | `#121212` | 抽屉底、内容 |
| `text_1` / `text_2` / `text_3` | 现有 | 现有 | 标题 / 图标 / 次级 |
| `divider` | `#EDEDED` | `#2A2A2A` | 分隔线、指示条 |
| `brand` | `#DA3838` | 同 | 选中态 |

> 需在 `entry/src/main/resources/base/element/color.json` 与 `dark/element/color.json` 各加一项 `mask`。

### 1.3 动画（ms）

| 场景 | 时长 | 曲线 | 是否可控 |
|---|---|---|---|
| 系统 `bindSheet` 出入场 | 框架默认（约 350） | 弹簧 | ❌ `SheetOptions` 无该参数 |
| `bindMenu` 下拉 | 框架默认（约 250） | 默认 | ❌ |
| overlay 抽屉打开 | 260 | `Curve.FastOutSlowIn` | ✅ `animateTo` |
| overlay 抽屉关闭 | 200 | `Curve.FastOutSlowIn` | ✅ |
| 遮罩淡入 / 淡出 | 200 / 160 | `Curve.Linear` | ✅ |
| 图标按压反馈 | 100，scale 0.92 | `Curve.EaseInOut` | ✅ |

约定：凡能走系统 `bindSheet` 的抽屉，动画一律用系统默认，**不额外包 `animateTo`**；只有 Reader 页内浮层走自定义时长。

## 2. 组件

### 2.1 `AppNavBack`（返回键）

文件：`entry/src/main/ets/components/AppNavBack.ets`

| 入参 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `label` | string | `'返回'` | 无障碍文案 |
| `tone` | `'normal' \| 'onBrand'` | `'normal'` | `text_1` / `on_brand`（详情页渐变头） |
| `onTap` | `() => void` | — | 返回动作 |

- 结构：`Row` 44×44 居中 + `SymbolGlyph($r('sys.symbol.arrow_left'))` 24fp；纯透明底，无圆角。
- 契约：页面级"先关浮层再返回"的逻辑留在页面（如 `Reader.ets:304`），组件不自知。
- 圆形填充变体（可选）：40vp 圆、`bg_pill` 底、radius 20。

### 2.2 `AppMoreButton`（省略号功能键）

文件：`entry/src/main/ets/components/AppMoreButton.ets`

| 入参 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `items` | `MenuElement[]` | — | 菜单项 |
| `tone` | `'normal' \| 'onReader' \| 'onBrand'` | `'normal'` | 三点颜色 |
| `label` | string | `'更多'` | 无障碍文案 |

- 结构：3 个 4×4 圆点（gap 3、radius 2），外包 44×44 热区，`.bindMenu(items)`。
- 统一热区：书架现无固定 44×44，必须补齐。
- 菜单动画、圆角、遮罩沿用系统默认（`bindMenu` 不可配）。

### 2.3 `AppBottomSheet`（底部抽屉，单一 API 两模式）

文件：`entry/src/main/ets/components/AppBottomSheet.ets`

| 入参 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `visible` | boolean（`$$` 双向） | false | 显隐 |
| `title` | string | `''` | 标题栏 |
| `size` | `'medium' \| 'large' \| 'fit'` | `'medium'` | → `SheetSize` |
| `mode` | `'system' \| 'overlay'` | `'system'` | sheet / 页内浮层 |
| `onClose` | `() => void` | — | 关闭回调 |
| `content` | `CustomBuilder` | — | 内容 |

**system 模式固定选项**（保证 API 12 兼容）：

```
height: SheetSize.*
dragBar: true
showClose: false          // 自绘关闭，避免系统关闭键遮挡表头（见 docs/progress.md §BUG）
blurStyle: BlurStyle.NONE
maskColor: $r('app.color.mask')
backgroundColor: $r('app.color.bg_page')   // 默认 Color.White，深色模式必须覆盖
preferType: SheetType.BOTTOM
enableOutsideInteractive: false
onWillDismiss: onClose
```

- `radius` 选项 **API 15 才有**，本项目 `compatibleSdkVersion 5.0.0(12)` 不可用 → 用内容根 `.borderRadius({topLeft:20,topRight:20}).clip(true)` 实现顶部圆角（方案 A，见 §5）。
- 内容根**禁止**再写 `height('100%')` / 固定 `70%`（现有 `SearchResult.ets:493`、`Listening.ets:348` 与 `SheetSize` 冲突），统一交 `size` 控制。

**overlay 模式**（Reader 专用）：

- 根 `Stack` 内全屏浮层，面板位于 topBar(52) 与 bottomBar 之间；
- 打开 `animateTo(260, FastOutSlowIn)` + `translateY 24→0` + `opacity 0→1`；关闭 200ms；
- 全屏遮罩 `app.color.mask`，点击即 `onClose`；
- 自定义拖拽指示条 36×4；关闭手势：下拉 > 面板高 30% 或速度 > 1000 → 关闭，否则回弹；另支持点遮罩 / 返回键 / 关闭按钮。

## 3. 抽屉通用结构（自上而下）

1. **拖拽指示条**：system 模式用系统 `dragBar`；overlay 模式自绘 36×4、radius 2、`divider` 色，上边距 8。
2. **标题栏**：48vp；标题 17fp Medium `text_1`，左 padding 20；右侧可选关闭 `SymbolGlyph(xmark)` 20fp `text_3`，40vp 热区。
3. **分隔线**：1px `divider`（可选）。
4. **内容区**：`List/Scroll`，`layoutWeight(1)`，左右 padding 16，底部安全区 padding 24。
5. **顶部圆角** 20vp；**遮罩** `app.color.mask`；**关闭途径**：拖拽下拉、点遮罩、关闭按钮、系统返回键。

## 4. 旧实现替换清单

| 项 | 文件:行 | 现状 | 处置 |
|---|---|---|---|
| 返回 | `entry/src/main/ets/pages/SearchResult.ets:355-362` | `Text('‹')` | → `AppNavBack` |
| 返回 | `entry/src/main/ets/pages/BookDetail.ets:91-98` | `Text('‹')` light | → `AppNavBack(tone:'onBrand')` |
| 返回 | `entry/src/main/ets/pages/Reader.ets:485` | `iconButton(arrow_left)` | → `AppNavBack` |
| 返回 | `entry/src/main/ets/pages/Reader.ets:454-466` | `iconButton` 通用 builder | 保留（供前后章 / 关闭用），返回不再复用 |
| 返回 | `entry/src/main/ets/pages/Listening.ets:155` | `chevron_down` 收起 | 仅统一热区 44×44 / 24fp（语义保留） |
| 返回 | `entry/src/main/ets/pages/Index.ets:163-186` | 系统 title bar 箭头 ×4 | 保留系统箭头（见 §5） |
| 省略号 | `entry/src/main/ets/pages/Index.ets:131-140` | 手搓 3 点，无固定热区 | → `AppMoreButton` |
| 省略号 | `entry/src/main/ets/pages/Reader.ets:468-480` | 手搓 3 点 | → `AppMoreButton` |
| 抽屉 | `entry/src/main/ets/pages/SearchResult.ets:584-588` | `bindSheet` 选项 | → `AppBottomSheet(system, medium)` |
| 抽屉 | `entry/src/main/ets/pages/SearchResult.ets:454-495` | 内容 `height('100%')` | 去高度，交 `size` |
| 抽屉 | `entry/src/main/ets/pages/Listening.ets:388-391` | `bindSheet(showClose:false)` | → `AppBottomSheet(system, large)` + 自绘关闭 |
| 抽屉 | `entry/src/main/ets/pages/Listening.ets:313-350` | 内容 `height('70%')` | 去高度，交 `size` |
| 抽屉 | `entry/src/main/ets/pages/Reader.ets:803-822` | 页内浮层容器 | → `AppBottomSheet(overlay)` |
| 抽屉 | `entry/src/main/ets/pages/Reader.ets:567-669` / `671-738` | 目录 / 设置面板 | 迁入 overlay，视觉不变 + 头部 / 指示条 |
| 抽屉 | `entry/src/main/ets/pages/SearchResult.ets:538-579` | "源状态"内联展开 | → `AppBottomSheet(system, fit)`，标题"源状态"，复用现有状态行（见 §5） |
| 相邻 | `entry/src/main/ets/pages/BookDetail.ets:204` | 圆角 16 | 统一为 `sheetTopRadius` 20（可选） |

> 说明：至本文档为止，全项目仅 2 处真 `bindSheet`（SearchResult 来源选择、Listening 目录）；Reader 目录 / 设置为页内浮层（非 sheet）；"源状态"为内联展开而非抽屉。全项目无自定义动画参数。

## 5. 已定决策 / 风险

- **抽屉顶部圆角（已定：方案 A）**：`SheetOptions.radius` 需 API 15，当前 `compatibleSdkVersion 5.0.0(12)` 不可用。采用内容根 `.borderRadius({topLeft:20,topRight:20}).clip(true)`，不改 SDK 版本；system 模式保留系统容器圆角作兜底。将来若升到 API 15+，可改用 `SheetOptions.radius` 达到完全一致。
- **系统返回键（已定：保留）**：4 个设置页（书源管理 / 阅读设置 / 通用设置 / 听书设置）继续使用系统 `NavDestination.title()` 自带箭头，与系统设计一致；仅自绘顶栏页面统一为 `AppNavBack`。
- **"书源状态"（已定：转抽屉）**：`SearchResult.ets:538-579` 由内联展开改为 `AppBottomSheet(system, fit)`，标题"源状态"，内容复用现有状态行。属新增交互，实现时需单独验证。
- **动画时长受框架限制**：`bindSheet` / `bindMenu` 的出入场动画由框架固定，无法通过参数指定毫秒；本文档标注约值仅供参考，仅要求"全 App 一致"。overlay 模式时长完全可控。
- `BookSourceManage.ets` 的"排除明细"同为内联展开，不在三项目范围内，暂不动。

## 6. 实施顺序（批准后）

1. 新增颜色 token `mask`（`resources/base/element/color.json` + `dark/element/color.json`）。
2. 新建 `components/AppNavBack.ets`、`AppMoreButton.ets`、`AppBottomSheet.ets`。
3. 按 §4 替换清单逐项改造；system 模式统一 `backgroundColor: bg_page`（修深色模式白底）。
4. 走完「编译 → 安装 → 重启 → 观察」闭环（见 `AGENTS.md` §4）。