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