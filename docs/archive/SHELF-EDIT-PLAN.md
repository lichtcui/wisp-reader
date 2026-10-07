# 书架编辑模式（多选删除）· 设计与实施计划

- **状态**：**已实施并真机验证（2026-10-07）** —— §8 S1–S4 代码全部落地；debug 与 release（含 SignHap）均 `BUILD SUCCESSFUL`；release 混淆产物已刷新并通过 §5.5 静态自查；**真机 DoD D1–D21 已跑（设备 `33Z0224424136564`）：D1–D9/D11/D13/D15–D17/D19/D21 ✅，D10/D12/D14/D18 按用户决定跳过，D20 部分通过（书架书量不足，见 §12.3）。** 真机轮另外发现并修复一处真机专属缺陷（长按手势被编译成空手势，见 §1.6/§5.2/K16）。
  本文件同时是「设计+实施计划（含完整代码）」与「实施记录」（§1.5 实施轮发现 / §1.6 真机轮发现 / §12 逐阶段与真机结果）。
- **关联任务**：`docs/bugfix/TASKS.md` → `T-SHELF-1（R5）删除书籍清理关联缓存`（本方案一并落实）。
- **修订**：
  - 第二修订 —— 对照代码 / SDK / 离线文档复核后补全（见 §1.1；§4.2 更正了首版一处不准确表述，§7 文件清单新增 3 项、删除 1 项，新增顺带修复 T-DATA-5/T-DATA-6）。
  - **第三修订** —— 对照真实源码逐行 + 官方 `@Builder` 参数刷新规则再次审计（见 §1.2）：
    1. **修一个真 bug**：`entryKey` 必须编码「编辑态」三态，否则进入编辑态后未选中的书不重建、看不到空角标（§5.1）。
    2. **消除一类隐危**：`editAction(icon,label,action)` 是多参数 builder（官方规则：**不会动态刷新**）→ 改为 **0 参数的 `deleteAction()`**（§5.3 K10）。
    3. 补充：`isChapterFile` 改名而非新增重复函数；S4 文案要把「目录」写上（原计划那句等于没改）；toc 强证据挪到 S4 后；新增 R13/E2E 项。
  - **第四修订（本轮）** —— 拉官方 V2 状态管理文档**正文**（`arkts-new-param.md` / `arkts-new-observedV2-and-trace.md`）与手写代码逐条对齐（见 §1.3）：
    1. **关闭 R2**：官方 `@Param` 文档的类对象刷新规则与示例和本方案**同形**（父 `@Local` 持 `@ObservedV2` 实例 → 子 `@Param` → `@Trace` 属性写入刷新父+子）——不再是待验行为，不再阻塞 S1→S2（§9 R2 / §11）。
    2. 新增 §5.4「V2 观测规则速查」：`@Trace` 只通知「读到它」的组件、UI 要读的字段必须 `@Trace`、`@ObservedV2` 必须 `new`（勿 `JSON.parse`）、子组件可改 `@Param` 对象的属性但不可整体赋值。
    3. 加固 `ShelfEditState.allSelected()`（不再依赖「selected 无重复 + 已剪枝」两个隐含前提）；S1-3c 注释笔误「三段 Text」改「两个 Text」。
  - **第五修订（本轮）** —— 攻前四轮未碰的三块空白（§1.4）：
    1. **release 混淆面（读本机 release 混淆产物取证）**：ArkUI **struct 成员被 ArkGuard 整列自动保留**（`fileWhiteLists.json` 实证），`@ObservedV2` **类成员不会**（`TtsController.structProperties: []`，`active`/`playing` 0 命中）→ 新增 **K15/§5.5 禁令**（禁 `@Monitor('edit.x')` / `this.edit['x']` / JSON 往返）；`obfuscation-rules.txt` 确认**不必改**（依据升级为产物实证）。
    2. **修一处计划缺口**：`ShelfRepository.ets:79-86` 有过时 TODO，S2-1 必须连 doc comment 一起替换（§7 行 5 / §8 S2-1）。
    3. **S1/S2 逐行对账**：`onBackPress`/`.scrollable`/a11y/弹窗/`rmdirSync` 递归性/各缓存模块签名 → **代码零修改**；`lastWriteAt.delete()` 理由升级为「必要」；R3 补三级兜底。
  - **实施轮（本轮，2026-10-07）** —— 按 §8 逐步落地 S1–S4，发现并修正 2 处计划细节（§1.5）；编译与混淆面验证见 §12。
  - **真机轮（本轮，2026-10-07）** —— 设备接回后跑完 DoD D1–D21（§12.3）；发现并修复 1 处**真机专属缺陷**（长按 helper 返回 gesture → 被编译成空手势 → 永不触发，见 §1.6 #42/#43、K16、§5.2）；三个真机疑点 R6/R10/R12 全部关闭；临时诊断日志已清理复验。
- **不涉及**：抽屉（`docs/specs/UI-SPEC.md` §1.2.1 只约束抽屉，本方案「编辑态替换底栏内容」不隐藏 tab 栏，无冲突，UI-SPEC 无需改动）。

---

## 目录（行号定位，只读需要的段）

> 本目录由 `make docs-toc` 自动生成，**勿手改**（行号是生成时快照）。
> **勿通读**：§7 是改动清单，§8 是逐行代码计划（S1–S4 各约 400/240/40/70 行）。

**[常查]** §7 改动清单 / §8 S1–S4 / §10 DoD / §12 实施结果

<!-- TOC:BEGIN -->
- 0. 摘要（4 步可交付） — L77
- 1. 复核结论（本次修订相对首版的差异） — L90
  - 1.1 首版 → 第二轮复核（已回写首版） — L94
  - 1.2 第三轮审计（对源码逐行对账 + SDK 符号表/官方 @Builder 规则） — L112
  - 1.3 第四轮审计（拉官方 V2 在线文档正文，关闭 R2；并逐条校对代码） — L124
  - 1.4 第五轮审计（release 混淆面 + S1/S2 逐行对账 + 数据层一致性扫描） — L145
  - 1.5 实施轮（照 §8 落代码时发现，2026-10-07） — L166
  - 1.6 真机轮（DoD 验证时发现，2026-10-07） — L175
- 2. 目标 / 非目标 — L184
  - 2.1 目标 — L186
  - 2.2 非目标 — L196
- 3. 交互规格 — L205
  - 3.1 线框 — L207
  - 3.2 状态机 — L230
- 4. 状态设计 — L260
  - 4.1 单实例共享（V2） — L262
  - 4.2 写状态一律整体换引用 — L277
  - 4.3 新文件：`entry/src/main/ets/model/ShelfEditState.ets` — L285
- 5. 关键技术点 — L397
  - 5.1 K5 展开：`ForEach` 复用导致角标不显示（含三态 key 修正） — L418
  - 5.2 K13 展开：长按与点击互斥 — L445
  - 5.3 `@Builder` 状态刷新规则（K10/K12 的依据） — L486
  - 5.4 V2 观测规则速查（第四轮官方取证，R2 关闭依据） — L501
  - 5.5 混淆（release）与状态管理：字符串访问禁令（第五轮产物实证） — L520
- 6. 决策（已确认） — L543
- 7. 改动清单（11 个文件，2 新增） — L558
- 8. 分步实施计划 — L579
  - S1 —— 可进可退的编辑模式（不删书） — L583
  - S2 —— 真删（DB + 三类缓存） — L984
  - S3 —— 边界收尾 — L1226
  - S4 —— 目录缓存统计收尾（T-DATA-5 / T-DATA-6）+ 文档 — L1268
- 9. 风险 — L1340
- 10. DoD（真机逐项） — L1360
- 11. 工作量与顺序 — L1388
- 12. 实施结果（2026-10-07） — L1404
  - 12.1 逐阶段落地情况 — L1406
  - 12.2 构建 / 混淆证据 — L1425
  - 12.3 真机验证结果（2026-10-07，设备 `33Z0224424136564`） — L1437
  - 12.4 收尾 — L1473
<!-- TOC:END -->

---

## 0. 摘要（4 步可交付）

| 步骤 | 交付物 | 真机可验证状态 |
|---|---|---|
| **S1** | `ShelfEditState` + `Index` 顶栏/底栏骨架 + `Shelf` 长按/多选 + `BookCover.dimmed` | 长按进入编辑态、计数、全选、完成/返回键退出（删除按钮暂为 stub） |
| **S2** | `BookRemoval` + `ShelfRepository.removeBooks` + `ChapterCache/TocCache/LocalBook` 清理 + 确认弹窗 | 真删：DB 行 + 章节缓存 + 目录缓存 + 本地 TXT 全部清除，TTS 互斥 |
| **S3** | 边界收尾（防重入、空选禁用、听书中被删、刷新竞态、空书架） | 逐项过 §9 DoD |
| **S4** | `CacheRepository` 目录缓存分类（T-DATA-5）+ `clearCache` 清 `tocs`（T-DATA-6）+ 文档同步 | 清理缓存页数值正确 |

工作量估计：11 个文件（2 新增）、净增 ~430 行；S1/S2 各一轮真机闭环，S3/S4 一轮合并。

---

## 1. 复核结论（本次修订相对首版的差异）

复核方式：读源码 + DevEco SDK `ets/component/*.d.ts` + 离线 `harmony-next` 参考资料 + 在 SDK 符号表内检索 symbol 名。

### 1.1 首版 → 第二轮复核（已回写首版）

| # | 首版说法 | 复核结论 | 影响 |
|---|---|---|---|
| 1 | 风险 R1：`sys.symbol.checkmark` / `trash` 未校验 | **R1 消除**。SDK 符号索引 `ets/build-tools/ets-loader/sysResource.js` 的 `symbol:` 段确认存在：`checkmark`(125831490)、`trash`(125831542)、`trash_fill`(125831543)、`checkmark_circle_fill`、`folder_badge_plus`(125831904，留给「移动到分组」)。`xmark`/`bookshelf` 等同文件既有用例 | 对勾直接用 `SymbolGlyph($r('sys.symbol.checkmark'))`；顶栏/底栏无需文字降级方案 |
| 2 | 清除范围 = `chapters` + `local` | **漏了目录缓存**：`model/TocCache.ets` 还写 `filesDir/tocs/{bookId}.json`。若不清，删除书籍后目录缓存永久残留 | S2 增加 `TocCache.deleteBookToc`；并新增顺带修复 T-DATA-5 / T-DATA-6 |
| 3 | 删除编排写在 `Index.ets` | 编排放**新模块** `model/BookRemoval.ets`：`Index` 只做「弹窗 + 调用 + 刷新 + Toast」，模型层可复用、可单测，避免 `Index` 同时依赖 4 个 model | 文件清单 +1（`BookRemoval.ets`），`Index` 依赖收敛为 2 个 import |
| 4 | `CacheRepository.deleteBookCache(ctx, bookId)` | 该函数要同时知道「chapters 文件名规则」和「local 目录布局」，等于把两个模块的私有知识搬到第三个模块。改为**各自归属**：`ChapterCache.deleteBookChapters`、`TocCache.deleteBookToc`、`LocalBook.deleteLocalBookData`，由 `BookRemoval` 编排 | 文件清单：删 `CacheRepository` 改动（改为 S4 只做统计），`CacheRepository` 不再需要按书删除 |
| 5 | 「`@Trace` 数组的 push 可能不触发刷新」 | 表述不准确。V2 对 `@Trace` 的 Array/Set/Map/Date 有 API 级观察能力（官方文档），本地参考资料仅未收录该细节。**本方案仍然统一整体重新赋值**——理由是让刷新行为不依赖该细节，并与项目现有 V2 风格一致，而非「push 一定不行」 | §4.2 措辞更正；实现不变 |
| 6 | `tocCache`/`textCache` 需要 evict | 确认：两 Map 均为 `LocalBook.ets` 模块私有，必须新增导出的 evict 函数 | S2 代码按此写 |
| 7 | 封面文件是否删 | 不删。文件名由 Rust `DefaultHasher::finish()` over `coverUrl` 生成（`runtime.rs` `format!("cover_{:x}.img", …)`），ArkTS 侧无法在不复刻 SipHash 的前提下定位文件 | 维持首版结论：封面留给「清理缓存」页；写入文档说明 |
| 8 | `LocalBook` 删除后能否重导 | 确认可以：`importLocalTxt` 会 `mkdirSync(dir, true)` 并重写 `book.txt`/`toc.json`，且 `bookId = computeBookId(LOCAL_SOURCE_URL, name|len)` 是确定值 | 删除本地书无后患；S2 验证项之一 |
| 9 | `Index` 顶栏是否在 `Tabs` 内 | 确认：`shelfHeader()` 渲染在 `Tabs` **之上**（`activeTab === TAB_SHELF` 分支），`Tabs.barHeight(0)` | 顶栏替换不影响 Tabs 布局 |
| 10 | 返回键 | `onBackPress?(): void \| boolean` 在 `component/common.d.ts:24694`（`@Entry` 可用）；`LongPressGesture({repeat, duration})`、`Tabs.scrollable(boolean)`、`GestureType`（`gesture.d.ts:733` 全局 `declare type`，含 `LongPressGestureInterface`）均在 SDK 声明中确认。**但**：`Navigation` 在本 SDK 无 `onBackPressed` 钩子，返回键是否会被 `Navigation` 先消费需真机确认 → 回退方案见 R10 | 可直接用；回退路径已备（`UIAbility.onBackPressed`） |
| 11 | `Margin` 类型 | `declare type Margin = Padding`（`component/units.d.ts:651`）是全局类型，可作 `@Builder` 形参 | 角标 margin 用形参传对象字面量，避开「三元表达式两支对象字面量类型不一致」的推断风险 |
| 12 | `UIContext.showAlertDialog` | 确认：`showAlertDialog(options: AlertDialogParamWithConfirm \| AlertDialogParamWithButtons \| AlertDialogParamWithOptions): void`（`api/@ohos.arkui.UIContext.d.ts:4715`） | 二次确认弹窗写法可用 |
| 13 | 按书状态清单是否完整 | 全仓 `Map<string, …>` 只有 7 处：`BookCover.pixmapCache/pathCache`（按 **coverUrl**，非 bookId；取用前有 `accessSync` 检查，废条目不会指向已删文件）、`LocalBook.tocCache/textCache`、`TocCache.memory`、`ChapterCache.memory`、`ShelfRepository.lastWriteAt`；别无按 bookId 的持久化（`Prefs` 也无按书键） | 清理清单完整：S2 覆盖后 4 处，`lastWriteAt` 由 `removeBooks` 清，`BookCover` 两 Map 无需处理（`pixmapCache` 有 64 条 LRU 上限） |

### 1.2 第三轮审计（对源码逐行对账 + SDK 符号表/官方 @Builder 规则）

| # | 发现 | 依据 | 处置 |
|---|---|---|---|
| 14 | **`@Builder` 超过 1 个参数就不会动态刷新** | 官方规则原文（`JsEtsAPIReference/guides/@Builder装饰器：自定义构建函数.md:69-80`）：「**如果@Builder传入的参数是两个或两个以上，且未使用按回调传递参数，不会触发动态渲染UI**」「按引用传递只在传入一个参数且该参数直接传入对象字面量时生效」 | 首版 `editAction(icon,label,action,enabled)` 既传多了参数、又把动态值当参数传 → **改为 0 参数的 `deleteAction()`**（与已验证可用的 `bottomBar()` 完全同形）。见 §5.3 K10、§8 S1-4 c |
| 15 | **三态 key 缺陷（真 bug）** | `entryKey` 只编码「选中位」时，长按 A 进入编辑态：A 的 key 变（0→1）✓，而其余未选中的书 selected 仍为 `'0'`、`editing` 却已翻转 → **key 不变 → 那一行不重建 → 空角标不出现**（与 §3.1 设计不符：编辑态所有书都应有角标） | `entryKey` 第三段改成「编辑态 × 选中」**三态**：`0`=普通态 / `1`=编辑态未选中 / `2`=编辑态已选中（§5.1）。S1 验证项 1 专门覆盖 |
| 16 | `selectBadge`/`deleteAction` 的刷新机理要说清 | 官方规则（同上）：多参数 builder 不动态刷新；能刷新的只有 **0 参数 builder 内的状态读取**（如 `bottomTab` 读 `this.activeTab`、`bottomBar` 读 `this.edit.editing`） | 角标靠 **K12 行重建**保证（与三态 key 配合）；`deleteAction` 靠 **0 参数 + 状态直读**保证。两者均不再依赖任何未验证行为 |
| 17 | `CacheRepository` 的 `isChapterFile` 去留 | 真实代码 `CacheRepository.ets:75-77` 有 `isChapterFile`（`getCacheStats` 用它）；S4 又新增一个 `isJsonFile` → 两个同义函数共存 | S4 改成 **改名**：`isChapterFile` → `isJsonFile`（chapters 与 tocs 共用），勿新增重复函数 |
| 18 | `getCacheStats` 的另一个消费者 | `pages/Settings.ets:41` 也在用 `formatBytes(getCacheStats(ctx).totalBytes)`；`CacheStats` 加字段后**不会**编译报错（它只取 `totalBytes`） | 无需改动，但要在 §7 表下明写“这是刻意不动的文件”，避免无意义的顺手改 |
| 19 | S4 文案那条是空操作 | 真实文案（`CacheManage.ets:104`）已经是「封面与章节在再次打开时会按需重新下载；TTS 音频当前仅内存缓存」——S4 原计划“改为”同一句 = 无变化 | 改为把**目录**写进文案：见 §8 S4-2 |
| 20 | 真机上怎么验证 toc 文件被删 | 设备 shell 访问 App 沙箱不一定可行；而「目录缓存」行要 S4 才存在 | 把 toc 文件的强证据挪到 **S4 之后**（有数字可比）；S2 阶段无 toc 行时用 `ls` 或“重新加入书架后目录重新拉取”旁证（已写入 S2 验证项 6 与 D9） |

### 1.3 第四轮审计（拉官方 V2 在线文档正文，关闭 R2；并逐条校对代码）

取证方式：`raw.githubusercontent.com/openharmony/docs/master/zh-cn/application-dev/ui/state-management/` 下 `arkts-new-param.md` 与 `arkts-new-observedV2-and-trace.md` 两份官方文档**正文**（离线参考资料只有指路摘要页，故本轮拉正文）。

| # | 发现 | 依据（官方原文） | 处置 |
|---|---|---|---|
| 21 | **R2 关闭**：`@ObservedV2` + `@Param` 的跨组件刷新是官方**主推用法**，不是待验行为 | `arkts-new-param.md` §「观察变化」：「当装饰的变量类型为类对象时，仅可以观察到对类对象**整体赋值**的变化，无法直接观察到对类成员属性赋值的变化，**对类成员属性的观察依赖 `@ObservedV2` 和 `@Trace` 装饰器**」；§「使用场景 · 从父组件到子组件变量传递与同步」的示例与本方案**同形**：父 `@Local infoList: Info[]`（`Info` 为 `@ObservedV2`）→ `MiddleComponent({info})` → `@Require @Param info: Info`，注释明写「修改数组元素及对象属性，触发 MiddleComponent 和 SubComponent 更新」 | R2 由「低概率待验」改为**文档已确认**；S1 保留冒烟项但**不再作为进 S2 的阻塞门**（§9 / §11 同步） |
| 22 | 子组件调用 `edit.setBooks()` 是**合法且有官方依据**的 | 同文档：「使用 `@Param` 装饰的变量在子组件中无法被直接修改。但是，如果装饰的变量是对象类型，**在子组件中可以修改对象的属性**」「该修改会同步到父组件数据源上，当属性被 `@Trace` 装饰时，可观测到对应 UI 刷新」 | `Shelf.ets` 调方法改其自身 `@Trace` 字段 → 合法。但**不能**写 `this.edit = …`（编译报错）；约束写入 §4.3 注释与 §5.4 |
| 23 | `@ObservedV2` 实例**必须 `new`**；`JSON.parse` 得到的对象**没有观察能力** | `arkts-new-observedV2-and-trace.md`：「需通过 `new` 操作符实例化后，才具备被观测变化的能力」「`JSON.parse` 获得的对象实际并不是 `Info` 的实例，所以无属性观察能力」 | `@Local edit = new ShelfEditState()` 写法正确；在 §4.3 注明“勿从 JSON/持久化恢复此对象” |
| 24 | Array/Map/Set/Date 的 **API 级观察**现在有确切清单（§4.2 原来只写“官方文档”） | 同文档：Array = `push/pop/shift/unshift/splice/copyWithin/fill/reverse/sort`；Map = `set/clear/delete`；Set = `add/clear/delete`；Date = 各 `setXxx` | §4.2 补清单与出处；**决策不变**（仍整体换引用：刷新时机确定、不依赖子组件对数据源的观察范围） |
| 25 | **`@Trace` 属性变化只通知「读到该属性」的组件** | 同文档：「被 `@Trace` 装饰的属性 property 变化时，**仅会通知 property 关联的组件进行刷新**」「未被 `@Trace` 装饰的属性用在 UI 中无法感知到变化」 | 写入 §5.4 作为扩展规则：将来给 `ShelfEditState` 加字段（如分组）时，**UI 要读的字段必须同时 `@Trace`** |
| 26 | 宫格项注释数量写错 | 真实 `Shelf.ets:111-127`：封面之下只有**两个** `Text`（书名 / 进度） | §8 S1-3 c 的「以下**三段** Text 原样不动」→「两个」 |
| 27 | 删除正在听的书后，**TTS 延迟写入会不会把 `progress` 行“复活”**（本轮主动排查的最大隐危） | 读 `TtsController.ets`：`stop()` 依次调 `clearTimer()` / `stopFlushTimer()` / `stopProgressTimer()`（`setInterval` 定时器全部清掉）；且 `loadChapter()` 在 `await loadChapterParagraphs(...)` **之后**有 `if (!this.active) { return; }` 守卫（`TtsController.ets:503` 附近，`beginFrom`/`next` 同类守卫见 :864/:890） | **安全**：`stop()` → `removeBooks()` 的次序下，不会有晚到的 `persistProgress()` 重建已删书的进度行。K7 不用改；写入 §5.4 旁证 |
| 28 | 调用点影响面核实 | `grep` 全仓：`BookCover(` 共 7 处（本方案只改 `Shelf.ets` 2 处，其余 5 处不传 `dimmed` → 默认 `false`，行为不变）；`MoreMenuButton(` 共 3 处（`Index.ets:132` 属本方案，`Reader.ets:972/996` 不受影响）；`ShelfPage(` 仅 `Index.ets:293` 一处 | S1-2「非破坏性」结论成立；改动面锁死在 11 文件内 |
| 29 | 代码里用的 API 先例核实 | `getUIContext().getPromptAction().showToast({message})`：`Index.ets:97/101`、`BackupManage.ets:34`、`Settings.ets:56` 等 6 处；`getUIContext().showAlertDialog({primaryButton,secondaryButton})`：`BackupManage.ets:161`；`getHostContext() as common.UIAbilityContext \| undefined`：6 处 | S1/S2 代码片段的 API 写法与项目一致，无需新引入（Plan 已注先例；此处补齐 Toast 先例） |

**复核新增任务（顺带修复，S4）**

- `T-DATA-5`：「清理缓存」页**统计漏了 `filesDir/tocs`**（`CacheRepository.CacheStats` 无该分类），数字偏小。
- `T-DATA-6`：`clearCache()` **不删 `filesDir/tocs`**，导致「清理全部缓存」后目录缓存仍占空间且无 UI 入口可清（是真实泄漏点）。

### 1.4 第五轮审计（release 混淆面 + S1/S2 逐行对账 + 数据层一致性扫描）

前四轮都没碰过的三块空白：**① release 混淆（`-enable-property-obfuscation`）会不会让 V2 状态静默失效；② §8 S1/S2 代码与真实文件的逐行对账；③ 全仓「按书落盘/入内存」的完整性扫描**。

取证方式：**直接读本机 release 编译产物**（比文档更硬）——`entry/build/default/cache/default/default@CompileArkTS/esmodule/release/obfuscation/{fileWhiteLists,projectWhiteList,nameCache}.json`（2026-10-02 生成，已含 `RuleDebugger.ets`）；辅以 SDK `@ohos.file.fs.d.ts` / `tabs.d.ts` 原文与全仓 `grep`。

| # | 发现 | 依据（取证原文/实证） | 处置 |
|---|---|---|---|
| 30 | **release 混淆面：现有 5 处 `@Monitor('字符串路径')` 全部安全，`obfuscation-rules.txt` 确认无需改动** | `fileWhiteLists.json` 中 `Shelf.ets` 的 `fileKeepInfo.structProperties` = `[refreshToken, viewMode, entries, tts, onGoSearch, onOpenBook, onOpenListening, aboutToAppear, onRefresh, reload, build, gridView, listView, entryKey, progressText]` → **ArkUI struct 的成员被整列自动保留**（ArkGuard 内建规则，不是靠我们的白名单）；`projectWhiteList.json` 另实证含 `refreshToken`/`searchToken`/`visible`/`paragraphIndex`/`chapterIndex`；且规则文件只开了 `-enable-property-obfuscation`，**未开** `-enable-string-property-obfuscation`（官方混淆配置文档：「字符串字面量属性名不会被混淆，并且与其同名的属性名也不会被混淆」） | §7「不动 `obfuscation-rules.txt`」**维持**，但依据从「无新增 JSON 字段」升级为**产物实证**；`@Param refreshToken` / `@Param edit` / `@Param dimmed` 全部落在 struct 成员里 → 混淆无关 |
| 31 | **新约束：`@ObservedV2` 类（非 struct）的成员不在自动保留白名单** → 对 `ShelfEditState` 一切**字符串式属性访问都是 release-only 静默失效面** | 同一 `fileWhiteLists.json` 里 `TtsController.ets`（`@ObservedV2` 类）的 `structProperties: []`；`active`/`playing` 在 `projectWhiteList.json` 中 **0 命中**（确实会被改名）。反例 `Reader.ets:101` 的 `@Monitor('tts.paragraphIndex','tts.chapterIndex')` 之所以安全，纯属 `paragraphIndex`/`chapterIndex` 恰好也是 `Reader` 自己的 struct 成员（ArkGuard 白名单**按名字全局生效**） | 新增 **K15**（§5.5）：编辑态实现里禁止 ① `@Monitor('edit.xxx')` 字符串路径；② `this.edit['selected']` 式下标访问；③ 把 `ShelfEditState` 做 `JSON.stringify`/`parse` 往返当状态。要走这三种写法，必须把字段名加进 `-keep-property-name`（或把字段挪回 struct 的 `@Local`） |
| 32 | **计划缺口**：`ShelfRepository.ets:79-86` 有一段**过时 TODO**，S2-1 只写「替换函数」不够，必须**连 doc comment 一起替换** | 原文：「Remove a book and its progress. Reserved for the shelf "delete book" action (T-SHELF-1), **which is not wired yet; when it is, also purge `filesDir/chapters/{bookId}_*` and local-book dirs**.」→ S2 落地后这两句都变假（已接线，且清理搬去了 `BookRemoval`）。**交叉验证收益**：该 TODO 预期的清理范围（chapters + local dirs）是我们 `BookRemoval` 的**子集**（我们还多清 `tocs`）→ 删除范围完整性得到仓内独立佐证 | S2-1 明确「替换 `removeBook` 及其 doc comment」，并注明这是**兑现仓内既存 TODO**；§7 行 5 同步 |
| 33 | `removeBook` **零调用点** → 改名替换无回归面 | `grep -rn "removeBook" entry/src/main/ets` 只命中定义行 `ShelfRepository.ets:87` | S2-1 维持「直接替换、不留死代码」，本节留证 |
| 34 | `lastWriteAt.delete(bookId)` 从「卫生」升级为**必要** | `ShelfRepository.ets:124-131` `saveProgress()` 守卫是 `if (last !== undefined && last > incoming) return;`（单边 `>`）→ 保留旧时间戳时，时钟回拨/未来时间戳会**吞掉**重新加入后的合法进度写入 | S2-1 注释补这句理由 |
| 35 | `fileIo.rmdirSync` **是递归删除**，S2-4 可一次删净 `filesDir/local/{bookId}`（内含 `book.txt` + `toc.json`） | SDK `js/api/@ohos.file.fs.d.ts:3159` 原文注释：「Removes a directory and all its subdirectories and files synchronously.」；同处 `@throws 13900002 - No such file or directory` → 故仍需 `accessSync` 守卫 + try/catch（计划已有）。`CacheRepository.removeDir` 是同一用法 | S2-4 代码无需改，依据补齐 |
| 36 | **S2 逐行对账通过**：`memory` / `memoryKey` / `filePath` / `cacheDir` / `tocCache` / `textCache` / `bookDir` 签名一致；`Map.forEach` 内 `delete` 合法；`_` 前缀防误删成立；弹窗写法与项目先例**逐字同形** | `ChapterCache.ets:18/22/39/43`、`TocCache.ets:18/22/38/42`、`LocalBook.ets:29/30/49`（`bookDir = filesDir + '/local/' + bookId`）；`Map.prototype.forEach` 规范允许回调中删除键；`confirmDelete()` 与 `BackupManage.ets:160-179` 完全同形（含 `action: () => { this.doImport(); }` 直接调用 async 方法、`fontColor: $r('app.color.text_2'/'brand')`）→ 编译零风险 | **S2 代码零修改**；结论见 §8 S2 验证前置注 |
| 37 | **S1 逐行对账通过**：`onBackPress` 可用、`.scrollable` 未废弃且已有先例、a11y 写法有先例、计数器能动态刷新 | `Index.ets:40-42` = `@Entry @ComponentV2 struct Index` → `onBackPress(): boolean` 合法（R10 仍是「`Navigation` 会不会先消费」的真机问题，不是 API 问题）；`Index.ets:323` **已有** `.scrollable(true)` → 改 `scrollable(!this.edit.editing)` 是最小改动；SDK `component/tabs.d.ts` 的 `scrollable(value: boolean)` **无 deprecated 标记**；`AppBackButton.ets:30-40` = 「容器 `Row` + 内部 `Text` + `.accessibilityText()` + `.accessibilityLevel('yes')`」先例 → 顶栏「全选/完成」写法成立；`count()`/`allSelected()`/`isSelected()` 在渲染期直读 `@Trace` 字段 → 依赖被记录，顶栏计数与底栏置灰都会刷新 | **S1 代码零修改** |
| 38 | 角标刷新**兜底顺序升级**（R3 的补救路径原来只有“改手势”） | K12 已承认 2 参数 builder 静态，主防线是 K5 三态 key；但官方唯一「按引用传递」（= 会动态刷新）的路径是**单参数 + 直接传对象字面量** | R3 缓解改为三级：① K5 三态 key（已实现）；② **首选加固** = `selectBadge` 改**单参数对象字面量**（如 `selectBadge({ selected, margin })`）；③ 次选 = 角标 UI 内联进宫格/列表两处 |
| 39 | **数据层一致性扫描收尾**：全仓「按书」落盘点只有 4 处，3 处已清、第 4 处（封面）不可定位属**刻意**；封面内存缓存不按书清也是**刻意且有益** | `grep` 全仓 `filesDir`/`cacheDir` 写入点 + 模块级 `Map`：`chapters/{bookId}_{i}.json`、`tocs/{bookId}.json`、`local/{bookId}/`（三处均由 S2 清理）+ `cacheDir/cover_<Rust hash>.img`（理由见 §8 S2-5 注释）；`BookCover.pixmapCache`/`pathCache` 按 `coverUrl` 且 `PIXMAP_LIMIT = 64` → 删书后保留是**好处**（重新加入秒显封面），不是遗漏 | 无需改动；本节留证（回答「为什么删书不清封面缓存」直接引此条） |

**本轮结论**：S1/S2 代码**零修改**；新增 1 条硬约束（K15/§5.5）；修正 1 处计划缺口（S2-1 注释替换）；R3 补救路径升级。仍未定论的仍是老三样：**R10**（返回键是否被 `Navigation` 吞）、**R12**（长按是否双触发/是否影响滚动）、**R6**（500ms 手感）——都只能真机定论。

### 1.5 实施轮（照 §8 落代码时发现，2026-10-07）

| # | 计划写法 | 实际落地 | 原因 |
|---|---|---|---|
| 40 | §8 S1-3e `selectBadge` 用 `.justifyContent(FlexAlign.Center)` + `.alignItems(HorizontalAlign.Center)` 居中小勾 | 改为 `Stack({ alignContent: Alignment.Center })`（代码里留注释指向本节） | 编译报错 `Property 'justifyContent' does not exist on type 'StackAttribute'`：`Stack` 的居中只能由构造参数 `alignContent` 控制，本 SDK 无该二属性（`alignItems` 仅 `Flex`/`Column`/`Row`/`Stack` 的 `alignContent` 语义） |
| 41 | §8 S1-4 `confirmDelete()` 先写 Toast 占位（S1 阶段） | S1 照写占位，S2 按计划替换为真实 `showAlertDialog` | 非偏差，仅记录两者是同一函数，勿误认为 S1 遗留死代码 |

其余 §8 代码**逐字照抄、零改动**。§5.5/K15 静态自查通过与混淆产物实证（`PropertyCache`: `editing→c12`、`bookIds→d12`）见 §12。

### 1.6 真机轮（DoD 验证时发现，2026-10-07）

| # | 计划写法 | 实际落地 | 原因 / 证据 |
|---|---|---|---|
| 42 | §8 S1-3e 把长按写成 helper：`private longPressToEdit(entry): GestureType { return LongPressGesture(...).onAction(...) }`，模板里 `.gesture(this.longPressToEdit(entry))` | 内联手势字面量：`.parallelGesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => this.onLongPress(entry)))`；helper 改名 `onLongPress(entry): void`（只留业务） | **真机长按从不触发**。转译产物实证：`entry/build/.../esmodule/debug/entry/src/main/ets/pages/Shelf.ts` 里该参数位编译成 `globalThis.Gesture.create(GesturePriority.Parallel); globalThis.Gesture.pop();` = **空手势**——helper 返回的手势对象被 ETS 编译器丢弃。改内联字面量后生成真正的 `LongPressGesture.create({repeat:false,duration:500})`，+498ms 触发。见 §5.2 |
| 43 | 同上用 `.gesture(...)` | 改用 `.parallelGesture(...)` | `.gesture()` = `GesturePriority.Low`，在本页 `Navigation` 的识别器面前输掉竞争（内联字面量也仍不触发）；`.parallelGesture()` 并行挂载、不受优先级影响。两者都**只接受内联手势字面量** |

---

## 2. 目标 / 非目标

### 2.1 目标

0. （顺带修复）把 `filesDir/tocs` 纳入缓存统计与「清理全部缓存」范围（`T-DATA-5` / `T-DATA-6`，见 S4）。
1. 书架长按书籍 → 进入**编辑态**（多选），可继续点按加/减选。
2. 底栏由「书架/搜索/设置」切换为动作区（本期只有「删除」）。
3. 顶栏：左「全选/取消全选」、中「已选择 X 本书」、右「完成」。
4. 删除：二次确认 → 清 DB（`books` + `progress`）→ 清缓存（章节/目录/本地文件 + 内存层）→ 退出编辑态并刷新书架。
5. 落实 `T-SHELF-1`（删除书籍清理关联缓存）。
6. 为「移动到分组」预留位置与调用点（本期不实现、不渲染）。

### 2.2 非目标

- 移动/新建分组、分组数据模型；置顶、拖拽排序、删除撤销、表格/多列切换、批量导出。
- 删除书源、删除本地文件选择器中的原始 TXT。
- 封面文件按书删除（见 §1 #7）。
- 抽屉相关任何改动。

---

## 3. 交互规格

### 3.1 线框

```
普通态                                   编辑态
┌──────────────────────────────┐        ┌──────────────────────────────┐
│ 书架                     ⋯   │ 52vp   │ 全选   已选择 2 本书     完成 │ 52vp
├──────────────────────────────┤        ├──────────────────────────────┤
│ ┌────┐ ┌────┐ ┌────┐         │        │ ┌────┐ ┌────┐ ┌────┐         │
│ │封面│ │封面│ │封面│         │        │ │✓◯ │ │封面│ │ ✓◯│         │
│ └────┘ └────┘ └────┘         │        │ └────┘ └────┘ └────┘         │
│ 书名    书名    书名          │        │ 书名    书名    书名          │
│ …                            │        │ …                            │
├──────────────────────────────┤        ├──────────────────────────────┤
│  ▤书架   🔍搜索   ⚙设置      │ 60vp   │            🗑 删除            │ 60vp
└──────────────────────────────┘        └──────────────────────────────┘
   （听书 FAB 可见）                       （听书 FAB 隐藏）
```

- 未选中角标：22vp 圆 + 半透黑底（`app.color.mask`，base `#52000000` ≈32% / dark `#80000000` 50%）+ 1.5vp 白环（`app.color.on_brand`），压在封面右上角内缩 4vp。
- 选中角标：同尺寸实心 `app.color.brand` 圆 + 白色 `sys.symbol.checkmark`（12fp）；封面 `opacity 0.72`。
- 列表模式：角标改到行尾，垂直居中，左边距 12vp。
- **编辑态下所有书都有角标**（选中=实心红+白勾，未选中=空环）——这一条正是 §5.1 要求 `entryKey` 含「编辑态」的原因：只编码选中位的话，未选中的那些行不会重建、看不到空环。

### 3.2 状态机

```
        长按书籍 (editing=false)
  idle ─────────────────────────► editing(selected=[bookId])
   ▲                                     │
   │ 完成 / 系统返回 / 书架变空            │ 点按其他书 → toggle(bookId)
   └─────────────────────────────────────┘
       删除成功 → exit() → 刷新书架
```

规则：

| 事件 | 行为 |
|---|---|
| 长按任意书籍 | 进入编辑态并选中该书；已在编辑态则忽略（不反选、不切换） |
| 编辑态点按书籍 | 切换选中；**不打开阅读页** |
| 非编辑态点按书籍 | 现状行为（打开阅读页） |
| 顶栏左 | 全选 / 取消全选（依据 `allSelected()`） |
| 顶栏中 | `已选择 X 本书`（X = `selected.length`，允许 0） |
| 顶栏右「完成」 | 退出编辑态并清空选择（不删任何东西） |
| 底栏「删除」 | `selected.length > 0` 且非删除中才可点；点击弹二次确认 |
| 二次确认「删除」 | 执行删除 → 退出编辑态 → 刷新书架 → Toast |
| 二次确认「取消」 | 关闭弹窗，保留编辑态与选择 |
| 系统返回键 | 编辑态内 → 退出编辑态并消费事件（`return true`）；否则走默认返回 |
| 切 Tab（正常路径下不可达） | `onChange` 兜底 `exit()` |
| 书架变空 | `setBooks([])` 自动退出编辑态，显示 `EmptyView` |

---

## 4. 状态设计

### 4.1 单实例共享（V2）

```
Index  @Local edit: ShelfEditState  ──@Param edit──►  ShelfPage
   │                                                      │
   ├── shelfEditHeader()  读 editing / bookIds / selected
   ├── bottomBar()        读 editing / selected
   └── confirmDelete()    读 selected，调 exit()
```

- `@ObservedV2` 类实例 + `@Trace` 字段；V2 的 `@Param` 是**引用传递**（对照 V1 `@Prop` 的深拷贝语义，见离线文档《状态管理V1-V2迁移指导》）。
- 三处消费方（顶栏 / 底栏 / 宫格行）读同一实例，写一次自动三处刷新，无需 `@Event` 回传列表。
- 同族先例：`TtsController.instance()`（`@ObservedV2` + `@Trace`，M5 真机已验证跨页面刷新）。
- **回退方案（若 S1 真机发现父组件不刷新）**：把 `ShelfEditState` 改成与 `TtsController` 完全一致的进程内单例（`static instance()`），`Index` 与 `ShelfPage` 各自 `TtsController` 式取实例 —— 两文件各改 2 行，其余代码零改动。

### 4.2 写状态一律整体换引用

`selected` / `bookIds` 的更新统一 `this.selected = <新数组>`，而不是 `push/splice`。

依据（官方 `arkts-new-observedV2-and-trace.md` / `arkts-new-param.md`，第四轮已取证）：V2 对 `@Trace` 变量的 API 级观察清单是 —— Array：`push/pop/shift/unshift/splice/copyWithin/fill/reverse/sort`；Map：`set/clear/delete`；Set：`add/clear/delete`；Date：各 `setXxx`。也就是说 `push` 其实**能**触发刷新。

那为什么仍整体换引用？—— 不是因为 `push` 不行，而是：① 整体赋值是“无条件通知”，刷新时机确定，不依赖“是否踩中清单里的方法”；② 与项目已有 V2 风格一致；③ 不用去记某个方法在不在清单里（以后改代码不会踩坑）。 **代价**：每次多一次小数组分配（≤ 书架本数，忽略不计）。

### 4.3 新文件：`entry/src/main/ets/model/ShelfEditState.ets`

```ts
/**
 * Shelf edit mode (multi-select → delete) shared state.
 *
 * One instance is owned by `Index` and passed to `ShelfPage` through `@Param`
 * (V2 passes objects by reference), so a single `@Trace` write refreshes the
 * top bar, the bottom action bar and the grid/list rows together. All writes go
 * through the methods below — components never mutate `selected` directly.
 *
 * Official V2 rules this class relies on (第四轮已取证):
 * - `@Param` only observes a *whole-object* reassignment; member changes rely on
 *   `@ObservedV2` + `@Trace` (`arkts-new-param.md` §观察变化).
 * - A child component **may** modify the object's properties (our `ShelfPage`
 *   calls `setBooks`), but must **not** reassign the `@Param` variable itself
 *   (`this.edit = …` is a compile error) — never do that.
 * - Every field the UI reads must be `@Trace`, and a `@Trace` write only
 *   refreshes the components that *read* that property.
 * - The instance must be created with `new`; a `JSON.parse` result is not an
 *   instance and loses observability — so never restore this from storage.
 */
@ObservedV2
export class ShelfEditState {
  @Trace editing: boolean = false;
  @Trace selected: string[] = [];
  /** Every book id currently on the shelf; reported by ShelfPage after a reload. */
  @Trace bookIds: string[] = [];

  /** Long press: enter edit mode with that book selected. */
  enter(bookId: string): void {
    this.editing = true;
    this.selected = bookId.length > 0 ? [bookId] : [];
  }

  /** Leave edit mode and drop the selection (no side effects on data). */
  exit(): void {
    this.editing = false;
    this.selected = [];
  }

  isSelected(bookId: string): boolean {
    return this.selected.indexOf(bookId) >= 0;
  }

  count(): number {
    return this.selected.length;
  }

  /** True when every book on the shelf is selected (empty shelf → false). */
  allSelected(): boolean {
    if (this.bookIds.length === 0) {
      return false;
    }
    // Iterate the shelf list instead of comparing lengths: that way a stale or
    // duplicated id in `selected` can never make this report a wrong "all".
    for (let i = 0; i < this.bookIds.length; i++) {
      if (!this.isSelected(this.bookIds[i])) {
        return false;
      }
    }
    return true;
  }

  /** Tap in edit mode. */
  toggle(bookId: string): void {
    const next: string[] = this.selected.filter((id: string) => id !== bookId);
    if (next.length === this.selected.length) {
      next.push(bookId);
    }
    this.selected = next;
  }

  /** 全选 / 取消全选. */
  toggleAll(): void {
    this.selected = this.allSelected() ? [] : this.bookIds.slice();
  }

  /**
   * Shelf reload: refresh the selectable set, drop ids that disappeared, and
   * leave edit mode when the shelf became empty. Ids are compared before the
   * write so an unchanged reload does not wake the UI up again.
   */
  setBooks(ids: string[]): void {
    if (!sameIds(this.bookIds, ids)) {
      this.bookIds = ids;
    }
    const kept: string[] = this.selected.filter((id: string) => ids.indexOf(id) >= 0);
    if (kept.length !== this.selected.length) {
      this.selected = kept;
    }
    if (this.editing && ids.length === 0) {
      this.editing = false;
    }
  }
}

function sameIds(a: string[], b: string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}
```

---

## 5. 关键技术点

| # | 点 | 做法 |
|---|---|---|
| K1 | 顶栏真居中 | 左右两侧容器**等宽 76vp × 44vp**（`全选/取消全选` 最长 4 字 = 64vp@16fp，留 12vp 余量），中间 `layoutWeight(1) + TextAlign.Center` |
| K2 | 不隐藏 tab 栏 | 底栏沿用**同一根外层 `Column`**（`height(60)` + `border` + `expandSafeArea(BOTTOM)`），只替换内部 `Row` 内容 |
| K3 | 编辑态锁滑动 | `Tabs.scrollable(!this.edit.editing)`（SDK：`TabsAttribute.scrollable(value: boolean)`） |
| K4 | 长按手势 | `LongPressGesture({ repeat: false, duration: 500 }).onAction(...)`，**必须内联写在 `.parallelGesture(...)` 的参数位**，与同节点 `.onClick` 并存。⚠️ helper 方法返回 `GestureType` 的写法在真机上被编译成空手势 → 永不触发（见 K16 / §1.6 #42） |
| K5 | **`entryKey` 必须含「编辑态 × 选中」三态** | 见 §5.1（最容易漏的一处：只加选中位仍会让未选中的书不重建） |
| K6 | 刷新书架 | 现有 `shelfRefresh: number` 计数器 + `@Monitor('refreshToken')`，删除后 `+1`；`ShelfPage.reload()` 内调 `edit.setBooks(ids)` |
| K7 | TTS 互斥 | 删除前若 `tts.isActiveFor(bookId)` 则 `tts.stop()`（避免后台任务/AVSession 指向已删书籍） |
| K8 | 删除顺序 | 先删 DB 行（真相源），再清缓存（IO 失败静默，与 `CacheRepository` 现有风格一致） |
| K9 | 弹窗按钮顺序 | 沿用项目既有用法（`pages/BackupManage.ets`）：`primaryButton` = 取消，`secondaryButton` = 删除（红色 `app.color.brand`） |
| K10 | **`@Builder` 只允许 0 参数承载动态内容** | 官方规则：多参数 builder **不动态刷新**，动态值不能当形参传。故底栏删除按钮写成 **0 参数的 `deleteAction()`**，在属性表达式里直读 `this.canDelete()`——与已验证可用的 `bottomBar()`/`shelfEditHeader()` 同形（见 §5.3） |
| K11 | 书架刷新代数守卫 | `Shelf.reload()` 加 `reloadGen`，每次进入自增并捕获，`await` 回来后比对，过期结果直接丢弃（同 `SearchResult.searchGen`） |
| K12 | 角标刷新靠 **行重建**（不靠 builder 参数） | `selectBadge(selected, margin)` 是多参数 builder → 官方规则下**不动态刷新**；因此它的正确性完全由 **K5 三态 key 触发的整行重建**保证（新 key = 新节点 = 形参重新求值）。副产物：`BookCover` 也会重建，但 `pixmapCache`（模块级、按 coverUrl）会命中且**在首个 await 之前**同步赋值（`BookCover.ets:52-57`），不会闪；只有 LRU（64 条）已被挤掉时才会重新解码，见 R13 |
| **K13** | **长按 + 点击同节点会双触发** | 用 `longPressFired` 标志互斥（见 §5.2）；回退 `GestureGroup(GestureMode.Exclusive, …)` |
| **K14** | V2 观测规则速查（R2 关闭依据） | `@ObservedV2`+`@Trace` 才能观察类成员属性；`@Trace` 写入只刷新**读到该属性**的组件；实例必须 `new`；子组件可改 `@Param` 对象的属性、不可整体赋值。见 §5.4 |
| **K15** | **`@ObservedV2` 类成员禁「字符串式访问」**（release 混淆安全边界，第五轮实证） | struct 成员被 ArkGuard **整列自动保留**，`@ObservedV2` 类成员**不会**。故对 `ShelfEditState` 禁止 `@Monitor('edit.xxx')`、`this.edit['selected']`、JSON 往返——这些在 debug 全正常、**release 才静默失效**。见 §5.5 |
| **K16** | **`.gesture()/.parallelGesture()` 只认「内联手势字面量」**（真机实证，2026-10-07） | helper 方法返回的 gesture 对象被 ETS 编译器**静默丢弃**（转译产物退化成 `Gesture.create(...); Gesture.pop();` 空手势，debug/release 均不报错、真机无任何回调）→ 手势必须字面量内联写在参数位；且要用 `.parallelGesture`（`.gesture` 是 `GesturePriority.Low`，在 `Navigation` 等祖先识别器下输掉竞争）。见 §1.6 #42/#43、§5.2 |

### 5.1 K5 展开：`ForEach` 复用导致角标不显示（含三态 key 修正）

现有 key：

```ts
return entry.book.bookId + '#' + sig;   // sig = 进度
```

进入编辑态只改 `edit.editing/selected`，`entry` 本身没变 → key 不变 → **该行不重建**，角标不会出现。与 `T-SRC-1` / `BookSourceManage`（key 含 `enabled`）同族缺陷。修正（**第三轮审计修正：第三段必须是「编辑态 × 选中」三态，不能只带选中位**）：

```ts
private entryKey(entry: ShelfBookItem): string {
  const p: ReadProgress | undefined = entry.progress;
  const sig: string = p === undefined ? 'none' : `${p.chapterIndex}_${p.percent}`;
  // 第三段三态：0 = 普通态，1 = 编辑态未选中，2 = 编辑态已选中。
  // 必须含「编辑态」这一维：长按 A 进入编辑态时，A 的选中位 0→1 ✓，
  // 但其余未选中的书选中位仍是 0；若 key 不含 editing，它们的 key 不变 →
  // 不重建 → 那一行不会出现空角标（而 §3.1 要求编辑态所有书都有角标）。
  const state: string = this.edit.editing
    ? (this.edit.isSelected(entry.book.bookId) ? '2' : '1')
    : '0';
  return entry.book.bookId + '#' + sig + '#' + state;
}
```

依赖链：`keyGenerator` 在 build 期间读取 `this.edit.editing/selected`（`@Trace`）→ 注册依赖 → `enter()/toggle()/exit()` 换数组引用或改标志 → `ShelfPage` 重建 → key 变化 → 该行重建 → 角标与封面变暗同步更新。`isSelected()` 是同步方法内读 `@Trace`，V2 按「读取时机」记录依赖，方法调用不影响。

### 5.2 K13 展开：长按与点击互斥

长按识别成功后抬手，ArkUI 仍可能补送一次 `onClick`。若真双触发，表现是：长按进入编辑态选中 A → 抬手立刻被 toggle 成未选中（顶栏显示「已选择 0 本书」，而需求是“长按的那本默认选中”）——新人第一次真机测试就会撞到。

做法：`private longPressFired: boolean = false;`（普通字段，不需响应式）

- 长按 `onAction`：先 `this.longPressFired = true;`，再 `this.edit.enter(bookId);`
- 点击 `onItemTap` **开头**：`if (this.longPressFired) { return; }`
- 新增 `onItemTouch(event: TouchEvent)` 绑 `.onTouch`：`if (event.type === TouchType.Down) { this.longPressFired = false; }`（下次按下复位，保证普通点击仍能 toggle）

不用计时窗口（“按住 1s 再松手”会超出任何阈值）。**回退方案**：`GestureGroup(GestureMode.Exclusive, LongPressGesture, TapGesture)`（`gesture.d.ts:157` 确认枚举存在），代价是去掉 `.onClick` 会损失无障碍「点击激活」，仅在 R12 真机确认为双触发且标志无效时再用。项目内**无**现有 `LongPressGesture` 用法（无先例）。

> `.onTouch` 是**被动回调**（只上报 TouchEvent，不注册手势识别器、不参与手势竞争，默认不阻断冒泡），因此不会影响 `Grid`/`List` 滚动；真机上若发现滚动异常（R12 的一部分），按上面的回退方案换 `GestureGroup`。

**真机轮追加（2026-10-07，设备 `33Z0224424136564`）**：上面这套写法里**手势注册方式错了**，真机长按从不触发（详见 §1.6 #42/#43）。最终形态：

```ts
// Shelf.ets（grid 与 list 两个分支同形）
.parallelGesture(
  LongPressGesture({ repeat: false, duration: 500 })
    .onAction(() => this.onLongPress(entry))
)
```

```ts
private onLongPress(entry: ShelfBookItem): void {
  this.longPressFired = true;
  if (!this.edit.editing) {
    this.edit.enter(entry.book.bookId);
  }
}
```

原因：`.gesture()/.parallelGesture()` **只接受内联手势字面量**；写成 `private longPressToEdit(entry): GestureType { return LongPressGesture(...)... }` 再 `.gesture(this.longPressToEdit(entry))`，转译产物是 `globalThis.Gesture.create(GesturePriority.Parallel); globalThis.Gesture.pop();`（空手势，静默无报错）。另 `.gesture()` 为 `GesturePriority.Low`，在本页 `Navigation` 下也竞争不过祖先识别器。

真机实测结果：

- **R6**：长按在 +498ms 触发（`duration: 500` 手感符合预期）。
- **R12-a（补送 click）**：长按后**未观察到补送 click**（顶栏稳定在「已选择 1 本书」，无先选后取消跳动）→ `longPressFired` 兜底保留但未被依赖，K13 的 `GestureGroup(GestureMode.Exclusive)` 回退**未启用**。
- **R12-b（滚动误触发）**：`uitest uiInput swipe 232 1000 232 400 200`（手指持续移动约 3s，位移事件 sizeable 送达）→ **不触发长按、不误进编辑态**（`LongPressGesture` 内置位移容差生效）；编辑态内同样慢滑跨书封面 → 选中数不变。`.parallelGesture` 不阻断容器滚动、`.onTouch` 不消费事件 ✅ |

### 5.3 `@Builder` 状态刷新规则（K10/K12 的依据）

官方规则（离线文档 `JsEtsAPIReference/guides/@Builder装饰器：自定义构建函数.md` §「参数传递规则 / 限制条件」原文）：

- 「按回调传递和按引用传递时，支持 @Builder 函数内 UI 组件刷新。**按引用传递只在传入一个参数且该参数直接传入对象字面量时生效，有多个参数时不支持 @Builder 函数内 UI 组件刷新。**」
- 「如果 @Builder 传入的参数是两个或两个以上，且未使用按回调传递参数，**不会触发动态渲染 UI**。」
- 「@Builder 装饰的函数参数类型不允许为 undefined、null 和返回 undefined、null 的表达式。」（本方案形参只有 `boolean` / `Resource` / `string` / `Margin`，且 `Margin` 恒传对象字面量，不命中该限制）

→ 本方案的两条落地规约：

1. **动态内容放 0 参数 builder，在属性表达式里直读状态**：`deleteAction()`、`shelfEditHeader()`、`shelfNormalHeader()`、`bottomBar()`、`gridView()`、`listView()` 均 0 参数，表达式内直读 `this.edit.*` / `this.deleting` / `this.entries`（与现有 `bottomBar` 读 `this.activeTab` 同族）。
2. **必须带参数的 builder（`selectBadge(selected, margin)`）不做动态保证**，只求「重建时取值正确」，由 K5 三态 key 的行重建驱动。

> 落笔写代码时的自查句：**「这个会变的表达式，是靠状态直读刷新的，还是靠重建刷新的？」**——两者都没有，就是隐 bug。

### 5.4 V2 观测规则速查（第四轮官方取证，R2 关闭依据）

出处：`zh-cn/application-dev/ui/state-management/arkts-new-observedV2-and-trace.md` 与 `arkts-new-param.md`（第四轮拉正文核对）。

| 官方规则（原文摘要） | 对本方案的含义 |
|---|---|
| 「`@ObservedV2` 与 `@Trace` 需配合使用，单独使用没有任何作用」；「未被 `@Trace` 装饰的属性用在 UI 中无法感知到变化」 | `editing` / `selected` / `bookIds` 三个字段的 `@Trace` **不能删**；将来加字段（如分组）时，UI 要读的字段必须同步 `@Trace`（扩展自查项） |
| 「被 `@Trace` 装饰的属性变化时，**仅会通知 property 关联的组件进行刷新**」 | 顶栏/底栏/行三处都真的**读**了 `editing/selected/bookIds`（`count()`/`allSelected()`/`isSelected()` 内部也是直读 `@Trace`）→ 才会刷新；若把值先存到普通字段再渲染，就不会刷新 |
| 「`@Param` 只观察到类对象**整体赋值**的变化，成员属性赋值的变化依赖 `@ObservedV2` 与 `@Trace`」（官方示例：父 `@Local infoList: Info[]` → 子 `@Require @Param info: Info` → 改 `info.name` 触发父子刷新） | **R2 关闭**：本方案的 `@Local edit` → `@Param edit` → 写 `@Trace` 与官方示例**同形** |
| 「`@Param` 变量在子组件中无法被直接修改。但如果是对象类型，**在子组件中可以修改对象的属性**」「该修改会同步到父组件数据源上」 | `ShelfPage` 调 `this.edit.setBooks(...)` 合法且会同步回 `Index`；但**绝不能**写 `this.edit = …`（编译报错） |
| 「需通过 `new` 操作符实例化后，才具备被观测变化的能力」；`JSON.parse` 得到的对象「并不是 `Info` 的实例，所以无属性观察能力」 | `@Local edit: ShelfEditState = new ShelfEditState()` 正确；**不要**从 `preferences`/JSON 恢复这个对象（它不是持久化数据） |
| Array/Map/Set/Date API 级观察清单（见 §4.2） | 整体换引用是**风格/确定性**选择，不是绕开能力缺失 |

扩展检查清单（将来给编辑态加能力时逐条过）：

1. 新字段加 `@Trace` 了吗？UI 真的直接读了它吗？
2. 新 UI 动态内容是否放进了 **0 参数 builder**（§5.3）？
3. 靠重建刷新的部分，`entryKey` 需要多一段状态位吗（K5）？

### 5.5 混淆（release）与状态管理：字符串访问禁令（第五轮产物实证）

取证对象是本机 release 编译的 ArkGuard 产物（比在线文档更硬）：
`entry/build/default/cache/default/default@CompileArkTS/esmodule/release/obfuscation/` 下的 `fileWhiteLists.json` / `projectWhiteList.json`（工程已开 `-enable-property-obfuscation`）。

| 事实（实证） | 结论 |
|---|---|
| `fileWhiteLists.json` 中 `Shelf.ets` 的 `fileKeepInfo.structProperties` **列出了这个 struct 的全部成员**（`refreshToken`/`viewMode`/`entries`/`tts` + 全部方法）；`projectWhiteList.json` 里 `refreshToken`/`searchToken`/`visible`/`paragraphIndex`/`chapterIndex` 均有命中 | ArkUI **struct**（`@ComponentV2`）的成员名**免于属性混淆** → 一切 `@Param`/`@Monitor('本 struct 字段')` 在 release 下都安全 |
| 同文件中 `TtsController.ets`（`@ObservedV2` **类**）的 `structProperties: []`，且 `active`/`playing` 在 `projectWhiteList.json` 里 **0 命中** | **`@ObservedV2` 类的成员会被改名**。ArkGuard 白名单是**按名字全局**生效的（官方：「采用全局生效的属性保留机制……无法针对特定类型精确保留」），所以现存 `@Monitor('tts.paragraphIndex')` 之所以活着，只是因为 `paragraphIndex` 恰好也是 `Reader` struct 的成员 |
| `obfuscation-rules.txt` 只开了 `-enable-property-obfuscation`，**没开** `-enable-string-property-obfuscation` | 官方混淆配置文档：「字符串字面量属性名不会被混淆，并且与其同名的属性名也不会被混淆」→ 这是上面「同名即被保留」的机制来源 |

**因此（写码时逐条自查）**：

1. `ShelfEditState`（`@ObservedV2` 类）与 UI 之间**只走属性/方法直读**；
2. **禁止** `@Monitor('edit.selected')` 这类字符串路径：debug 正常、release 静默不触发（要监听就把名字加进 `-keep-property-name`，或把字段挪回某个 struct 的 `@Local`）；
3. **禁止** `this.edit['selected']` / `this.edit[动态键]` 式访问；
4. **禁止**把 `ShelfEditState` 当可持久化的数据结构做 `JSON.stringify`/`JSON.parse` 往返（既有 K14 的观察能力问题，也有混淆后的键名问题）；
5. 本方案所有动态值都在**属性表达式里直读** `this.edit.editing` / `isSelected(...)` / `count()` / `allSelected()` → 全部落在白名单内（struct 成员）或走访问器（`@Trace`）→ **release 无静默失效面**。

> 附：`@Trace` 字段的观察走**编译期生成的访问器**（`editing` 与其 backing 字段同步改名），不依赖运行时字符串键 → 所以「类成员被改名」本身不破坏 V2 观察；真正脆弱的只有第 2/3/4 条那些**用字符串点名**的写法。

---

## 6. 决策（已确认）

| # | 决策点 | 结论 |
|---|---|---|
| A | 长按行为 | 长按即进入编辑态并选中该书；编辑态内长按忽略 |
| B | 删除确认 | 二次确认弹窗（`showAlertDialog`），红色「删除」 |
| C | 缓存清理范围 | 本次一并落实 `T-SHELF-1`：DB + 章节缓存 + 目录缓存 + 本地 TXT（+ 内存层 evict）；封面不删 |
| D | 编辑态 Tab | 锁滑动（`scrollable(false)`），底栏无 tab 可点，系统返回键退出编辑态 |
| E | 空选 | 允许「已选择 0 本书」，删除按钮置灰不可点，**不自动退出**编辑态 |
| F | 顺带修复 | 纳入 T-DATA-5（目录缓存统计）+ T-DATA-6（`clearCache` 清 `tocs`）；不纳入封面统计口径调整 |
| G | 顶栏左侧按钮文案 | 用**切换文案**：全选态显示「取消全选」，非全选态显示「全选」（非固定「全选」、非 checkbox 图标）；`.accessibilityText` 同步、以 `allSelected()` 判定（第四轮已由用户确认） |
| H | release 混淆 | **不改 `obfuscation-rules.txt`**；代价是新代码遵守 K15/§5.5 的「禁字符串式属性访问」约束（第五轮产物实证） |

---

## 7. 改动清单（11 个文件，2 新增）

| # | 文件 | 类型 | 内容 | 步骤 |
|---|---|---|---|---|
| 1 | `entry/src/main/ets/model/ShelfEditState.ets` | 新增 | 编辑态单实例（§4.3） | S1 |
| 2 | `entry/src/main/ets/pages/Index.ets` | 改 | 顶栏编辑态分支、底栏动作区、`onBackPress`、`scrollable`、删除流程、传参 | S1+S2 |
| 3 | `entry/src/main/ets/pages/Shelf.ets` | 改 | `@Param edit`、长按、点按分流、角标、`entryKey`、`setBooks`、FAB 隐藏 | S1 |
| 4 | `entry/src/main/ets/components/BookCover.ets` | 改 | 新增 `@Param dimmed: boolean = false` | S1 |
| 5 | `entry/src/main/ets/model/ShelfRepository.ets` | 改 | `removeBook` → `removeBooks(bookIds)`（批量 + 清 `lastWriteAt`）；**连 `:79-86` 的过时 TODO doc comment 一起替换**（§1.4 #32；零调用点 → 无回归面） | S2 |
| 6 | `entry/src/main/ets/model/ChapterCache.ets` | 改 | 新增 `deleteBookChapters(ctx, bookId)` | S2 |
| 7 | `entry/src/main/ets/model/TocCache.ets` | 改 | 新增 `deleteBookToc(ctx, bookId)` | S2 |
| 8 | `entry/src/main/ets/model/LocalBook.ets` | 改 | 新增 `deleteLocalBookData(ctx, bookId)`（含内存 evict） | S2 |
| 9 | `entry/src/main/ets/model/BookRemoval.ets` | 新增 | `deleteBooks(ctx, bookIds)` 编排 | S2 |
| 10 | `entry/src/main/ets/model/CacheRepository.ets` | 改 | `toc` 分类 + `clearCache` 清 `tocs` | S4 |
| 11 | `entry/src/main/ets/pages/CacheManage.ets` | 改 | 目录缓存一行 + `zero()` | S4 |
| — | `entry/obfuscation-rules.txt` | 不动 | 无新增 JSON 字段；且第五轮读 release 混淆产物实证：struct 成员自动保留、`-enable-string-property-obfuscation` 未开（§1.4 #30/#31）→ 只要遵守 K15/§5.5 的禁字符串访问约束即可 | — |
| — | `pages/Settings.ets`、`entryability/EntryAbility.ets`、`docs/specs/UI-SPEC.md` | 不动 | 见 §8 S4-4「刻意不改」清单 | — |
| — | `docs/**` | 改 | `TASKS.md`（T-SHELF-1 完成 + T-DATA-5/6）、`RELEASE-NOTES.md`、`progress.md` | S4 |

---

## 8. 分步实施计划

> 每步结束都要走完整闭环：`hvigorw assembleHap` → `hdc install -r` → `aa force-stop` → `aa start` → `hilog | grep`。（设备断开时：只编译，设备侧验证推迟到设备接回，先记录待验项。）

### S1 —— 可进可退的编辑模式（不删书）

**目标**：编辑态进出、计数、全选、选中角标全部可用；删除按钮显示但行为是临时 stub。

#### S1-1 `model/ShelfEditState.ets`（新增）

代码见 §4.3，整文件新建。

#### S1-2 `components/BookCover.ets`（改）

```ts
  @Param radius: number = 8;
  /** Shelf edit mode: dim the cover to 72% while selected. */
  @Param dimmed: boolean = false;
```

根 `Stack` 追加（放在 `.backgroundColor(...)` 之后）：

```ts
    .opacity(this.dimmed ? 0.72 : 1)
```

非破坏性：其余调用点（`BookDetail`/`SearchResult`/`Reader`）使用命名参数，未传即 `false`。

#### S1-3 `pages/Shelf.ets`（改）

**a. import + 参数**

```ts
import { ShelfEditState } from '../model/ShelfEditState';
...
export struct ShelfPage {
  @Param refreshToken: number = 0;
  @Param viewMode: number = 0;
  /** Owned by Index; shared so the top bar, the action bar and the rows stay in sync. */
  @Param edit: ShelfEditState = new ShelfEditState();
```

**b. `reload()` 末尾上报可选集合**（S3-1 在此根底上加代数守卫；S1 先按此处写）

```ts
    this.entries = entries;
    this.edit.setBooks(entries.map((entry: ShelfBookItem) => entry.book.bookId));
```

**c. 宫格项**（`gridView()`，替换 `GridItem` 内整块）

```ts
        GridItem() {
          Column() {
            Stack({ alignContent: Alignment.TopEnd }) {
              BookCover({
                source: entry.source,
                coverUrl: entry.book.coverUrl,
                name: entry.book.name,
                coverWidth: 96,
                coverHeight: 128,
                radius: 8,
                dimmed: this.edit.editing && this.edit.isSelected(entry.book.bookId)
              })
              if (this.edit.editing) {
                this.selectBadge(this.edit.isSelected(entry.book.bookId), { top: 4, right: 4 })
              }
            }
            Text(entry.book.name)
              // …（以下两个 Text：书名 / 进度，原样不动）
          }
          .width('100%')
          .accessibilityText(this.itemA11yText(entry))
          .onClick(() => this.onItemTap(entry))
          .onTouch((event: TouchEvent) => this.onItemTouch(event))
          .gesture(this.longPressToEdit(entry))
        }
```

（`.accessibilityText` 把整行合并为单一无障碍节点，编辑态下读屏能报出选中情况；普通态退回「书名，进度」。）

**d. 列表项**（`listView()`）—— `BookCover` 加同样 `dimmed`，`Row` 内追加：

```ts
            if (this.edit.editing) {
              this.selectBadge(this.edit.isSelected(entry.book.bookId), { left: 12 })
            }
```

并把 `Row` 的 `.onClick(...)` 换成 `.accessibilityText(this.itemA11yText(entry)).onClick(() => this.onItemTap(entry)).onTouch((event: TouchEvent) => this.onItemTouch(event)).gesture(this.longPressToEdit(entry))`。

**e. 新增方法 + 角标 builder**

> `selectBadge` 的 `margin` 用全局类型 `Margin` 作形参（`units.d.ts:651 declare type Margin = Padding`），避开「三元表达式两支对象字面量类型不一致」的推断风险。
> 若编译器仍不接受对象字面量实参，降级为两个固定 margin 的 builder（`badgeGrid`/`badgeRow`）——**不影响其他设计**。

```ts
  /** Long press opened edit mode for the current press; swallows the click that may follow it. */
  private longPressFired: boolean = false;

  @Builder
  selectBadge(selected: boolean, margin: Margin) {
    Stack() {
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(12)
          .fontColor([$r('app.color.on_brand')])
      }
    }
    .width(22)
    .height(22)
    .borderRadius(11)
    .backgroundColor(selected ? $r('app.color.brand') : $r('app.color.mask'))
    .border({ width: selected ? 0 : 1.5, color: $r('app.color.on_brand') })
    .margin(margin)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    // 纯装饰：真实语义由所在行/宫的 accessibilityText 承担（见下）。
    .accessibilityLevel('no')
  }

  private onItemTap(entry: ShelfBookItem): void {
    // 长按（已进入编辑态）后可能还会补送一次 click，用 onTouch(Down) 复位的标志吞掉它（见 K13）。
    if (this.longPressFired) {
      return;
    }
    if (this.edit.editing) {
      this.edit.toggle(entry.book.bookId);
      return;
    }
    if (entry.source !== undefined) {
      this.onOpenBook(entry.source, entry.book);
    }
  }

  /**
   * 无障碍文本：编辑态下把选中情况并入行语义（角标自身对读屏不可见）。
   */
  private itemA11yText(entry: ShelfBookItem): string {
    const base: string = entry.book.name + '，' + this.progressText(entry);
    if (!this.edit.editing) {
      return base;
    }
    return base + (this.edit.isSelected(entry.book.bookId) ? '，已选中' : '，未选中');
  }

  /** Long press opens edit mode; inside edit mode long press is a no-op. */
  private longPressToEdit(entry: ShelfBookItem): GestureType {
    return LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
      this.longPressFired = true;
      if (!this.edit.editing) {
        this.edit.enter(entry.book.bookId);
      }
    });
  }

  /**
   * 每次按下的 Down 都复位 `longPressFired`，保证标志不会泄漏到下一次点击：
   * 同一根手指的长按（Down → 500ms 动作 → Up → 可能的 click）里，click 会被吞掉；
   * 下一次点击先发 Down（置 false），再正常走 tap 分支。
   */
  private onItemTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.longPressFired = false;
    }
  }
```

**f. `entryKey()`** —— 按 §5.1 修正。**注意第三段是「编辑态 × 选中」三态（`0`/`1`/`2`），不是布尔位**；只写布尔位会在“长按进入编辑态后，其余未选中的书不显示空角标”。

**g. FAB 隐藏**

```ts
      if (this.tts.active && !this.edit.editing) {
        FloatingListenButton({ visible: true, onTap: () => this.onOpenListening() })
      }
```

#### S1-4 `pages/Index.ets`（改）

**a. import + 字段**

```ts
import { ShelfEditState } from '../model/ShelfEditState';
...
  @Local shelfViewMode: number = 0;
  @Local edit: ShelfEditState = new ShelfEditState();
  /** Guards the delete flow against a double tap on the dialog button. */
  @Local deleting: boolean = false;
```

**b. 顶栏拆分**（替换现有 `@Builder shelfHeader()`）

```ts
  // ── Shelf header (title + 更多 menu / edit-mode bar) ───────────

  @Builder
  shelfHeader() {
    if (this.edit.editing) {
      this.shelfEditHeader()
    } else {
      this.shelfNormalHeader()
    }
  }

  @Builder
  shelfNormalHeader() {
    Row() {
      Text('书架')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_1'))
      Blank()
      MoreMenuButton({ items: this.shelfMenuItems() })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /** 编辑态顶栏：全选 / 已选择 X 本书 / 完成（左右等宽 76，保证中间真居中）。 */
  @Builder
  shelfEditHeader() {
    Row() {
      Row() {
        Text(this.edit.allSelected() ? '取消全选' : '全选')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .maxLines(1)
      }
      .width(76)
      .height(44)
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Center)
      .accessibilityText(this.edit.allSelected() ? '取消全选' : '全选')
      .accessibilityLevel('yes')
      .onClick(() => this.edit.toggleAll())

      Text('已选择 ' + this.edit.count().toString() + ' 本书')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_1'))
        .maxLines(1)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      Row() {
        Text('完成')
          .fontSize(16)
          .fontColor($r('app.color.brand'))
          .maxLines(1)
      }
      .width(76)
      .height(44)
      .justifyContent(FlexAlign.End)
      .alignItems(VerticalAlign.Center)
      .accessibilityText('完成')
      .accessibilityLevel('yes')
      .onClick(() => this.edit.exit())
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }
```

**c. 底栏替换内容**（改现有 `bottomBar()`，同时删掉重复的 `@Builder` 装饰器）

```ts
  @Builder
  bottomBar() {
    Column() {
      Row() {
        if (this.edit.editing) {
          this.deleteAction()
          // TODO(S3+): 「移动到分组」再加一个**同形的 0 参数 builder**（如 groupAction()）；
          // 不要改成“带参数的通用 action builder”——多参数 builder 不会动态刷新（§5.3 K10）。
        } else {
          this.bottomTab($r('sys.symbol.bookshelf'), '书架', TAB_SHELF)
          this.bottomTab($r('sys.symbol.magnifyingglass'), '搜索', TAB_SEARCH)
          this.bottomTab($r('sys.symbol.gearshape'), '设置', TAB_SETTINGS)
        }
      }
      .width('100%')
      .height(60)
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_page'))
    .border({ width: { top: 1 }, color: $r('app.color.divider') })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  /**
   * 删除按钮是否可点。**只能在 0 参数 builder 的属性表达式里直接调用**。
   * 官方限制：`@Builder` 传两个及以上参数就不会动态刷新，把 enabled 当形参传入
   * 会在「已选择 0 本 ↔ N 本」之间不变色（见 §5.3）。
   */
  private canDelete(): boolean {
    return !this.deleting && this.edit.count() > 0;
  }

  /** 编辑态 · 删除按钮。0 参数 + 状态直读 → 与已验证可用的 `bottomBar()` 同形。 */
  @Builder
  deleteAction() {
    Column({ space: 2 }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(24)
        .fontColor([this.canDelete() ? $r('app.color.brand') : $r('app.color.text_5')])
      Text('删除')
        .fontSize(11)
        .fontColor(this.canDelete() ? $r('app.color.brand') : $r('app.color.text_5'))
    }
    .layoutWeight(1)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .accessibilityText('删除')
    .accessibilityLevel('yes')
    .onClick(() => {
      if (this.canDelete()) {
        this.confirmDelete();
      }
    })
  }
```

**d. S1 临时桩**（`confirmDelete()` 在 S2 落地，S1 先只提示）

```ts
  private confirmDelete(): void {
    // S1 临时实现，S2 替换为二次确认 + deleteBooks(...)
    this.getUIContext().getPromptAction().showToast({
      message: '已选择 ' + this.edit.count().toString() + ' 本书（删除链路 S2 接入）'
    });
  }
```

**e. 返回键 + 滑动锁 + 传参 + onChange 兜底**

```ts
  /** 编辑态内的系统返回：只退出编辑态，不退出页面。 */
  onBackPress(): boolean {
    if (this.edit.editing) {
      this.edit.exit();
      return true;
    }
    return false;
  }
```

```ts
            ShelfPage({
              refreshToken: this.shelfRefresh,
              viewMode: this.shelfViewMode,
              edit: this.edit,
              // …
            })
```

```ts
        .scrollable(!this.edit.editing)
        .onChange((index: number) => {
          if (this.edit.editing) {
            this.edit.exit();
          }
          this.activeTab = index;
          // …（原逻辑不变）
        })
```

#### S1 验证

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
```

真机项：

1. 长按任一封面 → 顶栏变「全选 / 已选择 1 本书 / 完成」、底栏只剩「删除」、**该封面右上出现红色对勾、封面变暗**；**同时其余所有书都出现空角标**（专测 K5 三态 key：不含 `editing` 的 key 会让这些行不重建、看不到空角标）。顶栏计数能变 = **R2 冒烟**（父组件 `Index` 确实随子组件的 `@Trace` 写入刷新）；不通过仍按 §4.1 改单例。**角标两种失败形态的归因**：① 只有选中过的书有角标、其余无空角标 → 三态 `entryKey` 写错了（§5.1）；② 进入编辑态后点别的书，其角标不变 → **R3 三级兜底**（§1.4 #38）：首选把 `selectBadge` 改为**单参数对象字面量**（官方“按引用传递”→ 会动态刷新），次选把角标 UI 内联。
2. 长按抬手后顶栏**不应**变成「已选择 0 本书」（K13 双触发）；若真的变 0 → 启用 §5.2 回退方案（`GestureGroup`）。
3. 点按另一本 → 计数 +1、其角标由空变实心；再点同一本 → 取消选中（计数 -1、角标变回空）。
4. 点「全选」→ X = 书架总数、按钮变「取消全选」；再点 → 0（删除按钮随之置灰）。
5. 已选择 0 本时点「删除」→ 无反应（灰色，@Builder 状态直读生效；这一项专测 K10）。
6. 已选择 N 本时点「删除」→ Toast「已选择 N 本书（删除链路 S2 接入）」（S1 临时桩，确认点击链路通）。
7. 点「完成」→ 顶栏/底栏恢复，角标消失；再长按另一本 → 正常进入（不残留选中态）。
8. 编辑态按系统返回键 → 退出编辑态（不退出应用）；再按一次 → 退出应用（确认未吞掉正常返回）。
9. 编辑态左右滑动 → 不切 Tab；底栏无 tab 可点。
10. 正常态点书 → 仍能进入阅读页；长按 → 不会误触打开阅读页。
11. 列表模式同样用例（角标在行尾、垂直居中）。
12. 深色模式 + 系统大字体下上述 1/3/4 不截断、不遮封面标题。
13. 书架多到可滚动（或列表模式）时，编辑态下**上下滑动正常**（专测 `.onTouch` 未影响 `Grid`/`List` 滚动；若异常 → 按 §5.2 回退 `GestureGroup`）；滚动中不应误进编辑态（R6）。

> `uitest` 辅助：`$HDC shell "uitest uiInput longClick <x> <y>"`（物理像素，本机 1260 宽）；布局核对用 `uitest dumpLayout`。

**回滚**：`git checkout -- entry/src/main/ets/pages/Index.ets entry/src/main/ets/pages/Shelf.ets entry/src/main/ets/components/BookCover.ets && rm entry/src/main/ets/model/ShelfEditState.ets`

---

### S2 —— 真删（DB + 三类缓存）

#### S2-1 `model/ShelfRepository.ets`：`removeBook` → `removeBooks`

替换现有 `removeBook`：

```ts
/**
 * Remove books from the shelf: their `books` row (source of truth, so the shelf
 * stops showing them even if cache cleanup fails) and their `progress` row.
 * Callers that own a context should use `BookRemoval.deleteBooks`, which also
 * purges the chapter/toc/local caches.
 */
export async function removeBooks(bookIds: string[]): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined || bookIds.length === 0) {
    return;
  }
  for (const bookId of bookIds) {
    await s.executeSql('DELETE FROM books WHERE book_id = ?', [bookId]);
    await s.executeSql('DELETE FROM progress WHERE book_id = ?', [bookId]);
    lastWriteAt.delete(bookId);
  }
}
```

（不加事务：本机实测 RDB 事务 + `await executeSql` 无既有先例，且删除失败可重试、UI 以 DB 为准，风险不值得引入。）

两点必须一起做（第五轮补齐，见 §1.4 #32/#33/#34）：

- **连旧的 doc comment 一起替换**：现有注释写着「Reserved for the shelf "delete book" action (T-SHELF-1), which is not wired yet; when it is, also purge `filesDir/chapters/{bookId}_*` and local-book dirs.」——S2 之后这两句都变假。新注释要说明「清理已由 `BookRemoval.deleteBooks` 负责（顺带也清 `tocs`）」。
- **`lastWriteAt.delete(bookId)` 不是可选项**：`saveProgress()` 的守卫是 `if (last !== undefined && last > incoming) return;`，留着旧时间戳会在时钟回拨/未来时间戳时**吞掉重新加入后的合法进度写入**（注释里写明这条理由）。
- 证据：`removeBook` 全仓**零调用点**（只命中定义行 `ShelfRepository.ets:87`）→ 改名替换不会波及别处。

#### S2-2 `model/ChapterCache.ets`：新增导出

```ts
/**
 * Drop every cached body of one book: the in-memory entries and the
 * `filesDir/chapters/{bookId}_{index}.json` files. Best-effort — a file that
 * denies deletion is skipped; the caller has already removed the DB row.
 */
export function deleteBookChapters(ctx: common.UIAbilityContext, bookId: string): void {
  const memPrefix: string = bookId + '#';
  memory.forEach((_value: CachedChapter, key: string) => {
    if (key.startsWith(memPrefix)) {
      memory.delete(key);
    }
  });
  const dir: string = cacheDir(ctx);
  const prefix: string = bookId + '_';
  let names: string[] = [];
  try {
    if (!fileIo.accessSync(dir)) {
      return;
    }
    names = fileIo.listFileSync(dir);
  } catch (err) {
    return;
  }
  for (const name of names) {
    if (!name.startsWith(prefix) || !name.endsWith('.json')) {
      continue;
    }
    try {
      fileIo.unlinkSync(dir + '/' + name);
    } catch (err) {
      continue;
    }
  }
}
```

> 前缀安全性：`bookId` 是 hex（`computeBookId`），前缀以 `_` 结尾，不会误删另一本书的文件。

#### S2-3 `model/TocCache.ets`：新增导出

```ts
/** Drop one book's cached TOC (memory + `filesDir/tocs/{bookId}.json`). */
export function deleteBookToc(ctx: common.UIAbilityContext, bookId: string): void {
  memory.delete(memoryKey(bookId));
  const path: string = filePath(ctx, bookId);
  try {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (err) {
    return;
  }
}
```

#### S2-4 `model/LocalBook.ets`：新增导出

```ts
/**
 * Delete one local book's sandbox files (`filesDir/local/{bookId}`) and drop its
 * decoded TOC/text from memory. Re-importing the same TXT recreates everything
 * (`importLocalTxt` always rewrites `book.txt` / `toc.json`).
 */
export function deleteLocalBookData(ctx: common.UIAbilityContext, bookId: string): void {
  tocCache.delete(bookId);
  textCache.delete(bookId);
  const dir: string = bookDir(ctx, bookId);
  try {
    if (fileIo.accessSync(dir)) {
      fileIo.rmdirSync(dir);
    }
  } catch (err) {
    return;
  }
}
```

#### S2-5 `model/BookRemoval.ets`（新增）

```ts
import { common } from '@kit.AbilityKit';
import { removeBooks } from './ShelfRepository';
import { deleteBookChapters } from './ChapterCache';
import { deleteBookToc } from './TocCache';
import { deleteLocalBookData } from './LocalBook';
import { TtsController } from './TtsController';

/**
 * Permanently delete shelf books and everything they own.
 *
 * Order matters: DB rows first (source of truth → the shelf reload cannot show
 * a deleted book even if the file cleanup fails), then the on-disk caches
 * (chapter bodies, TOC, local TXT) and their in-memory layers. Cache cleanup is
 * best-effort — a failure is swallowed, matching `CacheRepository`'s style, and
 * the leftover can always be swept by 清理缓存.
 *
 * Cover images are intentionally left behind: their filename is a Rust-side hash
 * of the cover URL (`runtime.rs::download_cover`), so ArkTS cannot locate the
 * file for a given book. They are handled by the 清理缓存 page.
 *
 * @returns the number of books removed from the shelf.
 */
export async function deleteBooks(ctx: common.UIAbilityContext, bookIds: string[]): Promise<number> {
  if (bookIds.length === 0) {
    return 0;
  }
  const tts: TtsController = TtsController.instance();
  for (const bookId of bookIds) {
    if (tts.isActiveFor(bookId)) {
      tts.stop();
    }
  }
  await removeBooks(bookIds);
  for (const bookId of bookIds) {
    deleteBookChapters(ctx, bookId);
    deleteBookToc(ctx, bookId);
    deleteLocalBookData(ctx, bookId);
  }
  return bookIds.length;
}
```

#### S2-6 `pages/Index.ets`：替换 S1 桩

```ts
import { deleteBooks } from '../model/BookRemoval';
```

```ts
  private confirmDelete(): void {
    const n: number = this.edit.count();
    if (n === 0 || this.deleting) {
      return;
    }
    const message: string = n === 1
      ? '删除后，该书的阅读进度与缓存将一并清除，且不可恢复。'
      : '删除后，这 ' + n.toString() + ' 本书的阅读进度与缓存将一并清除，且不可恢复。';
    this.getUIContext().showAlertDialog({
      title: '删除书籍',
      message: message,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.doDelete();
        }
      }
    });
  }

  private async doDelete(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    const ids: string[] = this.edit.selected.slice();
    if (ctx === undefined || ids.length === 0 || this.deleting) {
      return;
    }
    this.deleting = true;
    let ok: boolean = true;
    try {
      await deleteBooks(ctx, ids);
    } catch (err) {
      ok = false;
    }
    this.deleting = false;
    this.edit.exit();
    this.shelfRefresh = this.shelfRefresh + 1;
    this.getUIContext().getPromptAction().showToast({
      message: ok ? '已删除 ' + ids.length.toString() + ' 本书' : '删除失败，请重试'
    });
  }
```

失败也刷新书架：即使 `removeBooks` 部分失败，UI 也必须回到与 DB 一致的状态。

#### S2 验证

> 前置注（第五轮对账结论，§1.4 #35/#36）：本节代码与真实文件**逐行对齐**（`ChapterCache`/`TocCache`/`LocalBook` 的 `memory`/`memoryKey`/`filePath`/`cacheDir`/`tocCache`/`textCache`/`bookDir` 签名全一致；`rmdirSync` 经 SDK 原文确认**递归**；`confirmDelete` 与 `BackupManage.ets:160-179` 同形）→ 照抄即可，无需改写。

前置：书架准备 ≥3 本书（至少 1 本**已读过**、1 本**本地 TXT**）。

1. 删除前：设置 → 清理缓存，记下「章节内容缓存 N 个文件」。
2. 长按选中 1 本 → 删除 → 弹窗「取消」→ 无变化，编辑态保留、选择保留。
3. 再次删除 → 弹窗「删除」→ Toast「已删除 1 本书」；书架立即少一本；顶栏/底栏恢复；系统返回键此时退出应用（不在编辑态）。
4. **DB**：`aa force-stop` + 重启 App → 该书不在书架。
5. **章节缓存**：清理缓存页「章节内容缓存」文件数下降（该书已读章节数）；重新打开该书（从搜索重新加入）→ 章节能正常下载（不出现空正文）。
6. **目录缓存**：`$HDC shell "ls files/tocs"`（App 沙箱内）确认 `{bookId}.json` 消失；若 shell 无权限，用「删除后重新加入书架 → 目录正常拉取」作旁证。**注：该行在 S4 前还没有数字可看；S4 完成后用「清理缓存 → 目录缓存」计数下降作定论（D9）。**
7. **本地 TXT**：导入一本 TXT → 长按删除 → `$HDC shell "ls files/local"` 无该 bookId 目录 → 重新导入同一 TXT 成功且目录/正文正常。
8. **TTS 互斥**：对该书开启听书 → 返回书架（底栏听书 FAB 可见，说明 `tts.active`）→ 长按该书删除 → 听书停止（FAB 消失、锁屏媒体卡消失）。
9. 多选删除 3 本 → 一次全部消失，Toast「已删除 3 本书」。
10. 全选后删除 → 书架空 → 显示「书架空空如也」，编辑态自动退出，底栏恢复。
11. 双击弹窗「删除」按钮不出现重复删除/异常 Toast（`deleting` 防重入）。
12. **端到端旁证（DB 真被删）**：搜索同名书 → 详情页显示「加入书架」而非「已在书架」（走 `isInShelf(name, author)` 查 DB）；点加入 → 重新回到书架且能读。

**回滚**：`git checkout -- <S2 涉及的 5 个文件>` + `rm model/BookRemoval.ets`（`S1` 保留）。

---

### S3 —— 边界收尾

#### S3-1 `pages/Shelf.ets`：`reload()` 并发守卫（K11）

```ts
  /** Monotonic guard: a slow earlier reload must not overwrite a newer shelf. */
  private reloadGen: number = 0;

  private async reload(): Promise<void> {
    this.reloadGen = this.reloadGen + 1;
    const gen: number = this.reloadGen;
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      return;
    }
    await initShelf(ctx);
    const books: Book[] = await getBooks();
    // …（中间三段同步代码不变）
    if (gen !== this.reloadGen) {
      return;   // 已被更新的刷新取代，丢弃本次结果
    }
    this.entries = entries;
    this.edit.setBooks(entries.map((entry: ShelfBookItem) => entry.book.bookId));
  }
```

（`searchGen` 同族做法见 `pages/SearchResult.ets:74,111-112`；不加守卫时「删除后刷新」与「返回书架刷新」叠加会偶发旧结果后到，表现为已删书短暂回跳。）

#### S3-2 逐项过 §9 DoD 中标注「S3」的条目

1. 编辑态下打开详情页/阅读页返回 → `onNavBarStateChange` 触发 `shelfRefresh` → `reload()` → `setBooks()`；确认编辑态**不被意外清除**（`setBooks` 只在书架变空时退出编辑态），且已删除的书不会残留在 `selected` 中。
2. 编辑态中另一本书被后台删除（如另开详情页移除）→ 计数与角标自动收敛。
3. 「已选择 0 本书」时删除按钮为灰、点击无反应、不自动退出编辑态。
4. 长按手感：`duration: 500` 在真机上不过敏/不迟滞（若过敏改为 600）。
5. 深色模式：角标（白环 + mask 底）、顶栏/底栏配色正确（`mask`/`on_brand`/`text_5` 双主题均有定义）。
6. 大字体（系统字体放大一档）：顶栏「取消全选」不换行、不被裁切（左右容器 76vp 已留余量；超出则加 `.maxLines(1)` 已具备）。
7. 空书架状态：无长按入口、`EmptyView` 正常。
8. `hilog` 无新增 error（重点看 `fileIo` 与 `relationalStore`）。

---

### S4 —— 目录缓存统计收尾（T-DATA-5 / T-DATA-6）+ 文档

#### S4-1 `model/CacheRepository.ets`

- 模块头注释：scope 增加「目录缓存：`filesDir/tocs/<bookId>.json` written by `TocCache`」。
- 常量 + 路径（**rename 现有 `isChapterFile` → `isJsonFile`，不要新增重复函数**：真实代码 `CacheRepository.ets:75-77` 已有 `isChapterFile`，chapters 与 tocs 两者同用即可）：

```ts
const TOC_DIR_NAME: string = 'tocs';

function tocDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + TOC_DIR_NAME;
}

/** Both chapter bodies and TOCs are stored as one JSON object per file. */
function isJsonFile(name: string): boolean {
  return name.endsWith('.json');
}
```

> `getCacheStats()` 里现有那行 `sumDir(chapterDir(ctx), isChapterFile)` 同时改名成 `isJsonFile`（chapters 那边行为不变）。

- `CacheStats` 增加 `toc: CacheCategory;`
- `getCacheStats()`：

```ts
  const toc: CacheCategory = sumDir(tocDir(ctx), isJsonFile);
  return {
    image: image,
    chapter: chapter,
    toc: toc,
    tts: tts,
    totalBytes: image.bytes + chapter.bytes + toc.bytes + tts.bytes,
    totalCount: image.count + chapter.count + toc.count + tts.count
  };
```

- `clearCache()` 增加 `removeDir(tocDir(ctx));`（对应 `T-DATA-6`）。

#### S4-2 `pages/CacheManage.ets`

- `@Local tocBytes/tocCount: number = 0;`、`reload()` 赋值、`zero()` 归零；
- 在「章节内容缓存」与「TTS 音频缓存」之间插入：

```ts
          CacheStatRow({ title: '目录缓存', bytes: this.tocBytes, count: this.tocCount })
          InsetDivider()
```

- 底部说明文案（现文案只提「封面与章节」，**现在要加上目录**）：「封面、章节与目录在再次打开时会按需重新下载；TTS 音频当前仅内存缓存，不计入占用。」

#### S4-3 文档同步

| 文件 | 改动 |
|---|---|
| `docs/bugfix/TASKS.md` | `T-SHELF-1` 标记完成（证据补 `TocCache.ets`）；新增 `T-DATA-5`（`tocs` 未纳入统计）、`T-DATA-6`（`clearCache` 不清 `tocs`），S4 完成后同样标完成 |
| `docs/bugfix/RELEASE-NOTES.md` | 新增一条：书架支持长按多选删除（含缓存清理） |
| `docs/progress.md` | 「书架」小节记录编辑模式；「未决 / 风险」移除本方案条目；`T-DATA-5/6` 记入已修 |
| `docs/archive/SHELF-EDIT-PLAN.md` | 本文件 → 状态改为「已实施」，附真机验证结果 |

#### S4-4 确认「刻意不改」的文件（避免顺手改出问题）

| 文件 | 为何不改 |
|---|---|
| `pages/Settings.ets` | 也调 `getCacheStats(ctx)`（:41），但只取 `totalBytes` → `CacheStats` 加字段不会破坏它，无需改 |
| `pages/BookSourceManage.ets` / `model/SourceRepository.ets` | 删书不动书源（非目标）；`T-SRC-1` 是另一条 |
| `entry/obfuscation-rules.txt` | 无新增 JSON 字段名（本方案只读 DB 列、写本地状态） |
| `entryability/EntryAbility.ets` | **仅当 R10 成立时**才加 `onBackPressed()` 回退；否则一字不动 |
| `docs/specs/UI-SPEC.md` | 不涉抽屉（底栏 tab 栏不是抽屉），无需改 |

---

## 9. 风险

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R2 | ~~`@ObservedV2` 实例经 `@Param` 传递后，父组件不随 `@Trace` 刷新~~ **已关闭（第四轮，官方文档取证）**：`arkts-new-param.md` 明确「对类成员属性的观察依赖 `@ObservedV2` 和 `@Trace` 装饰器」，且其官方示例（父 `@Local infoList` → 子 `@Require @Param info` → 改写 `@Trace` 属性）与本方案**同形**，注释明写「触发 MiddleComponent 和 SubComponent 更新」 | — | 已消除 | S1 验证项 1 降为**冒烟项**（不再是进 S2 的阻塞门，§1.3 #21）；万一真机异常，仍可按 §4.1 改单例（2 文件 × 2 行） |
| R3 | `entryKey` 未含 **编辑态** → 长按进入编辑态后，其余未选中的书不重建、不显示空角标（**只加选中位仍会漏这一半**，见 §1.2 #15） | — | 编辑态反馈不全，像“只有选中过的书才有角标” | §5.1 三态 key 已修正；S1 验证项 1 专门覆盖。**角标终极兜底（§1.4 #38 三级）**：① 三态 key（主防线）→ ② `selectBadge` 改**单参数对象字面量**（官方唯一“按引用传递”→ 会动态刷新）→ ③ 角标 UI 内联进两处 |
| R4 | 缓存删除失败（IO 占用/权限） | 低 | 残留文件 | 全部 try/catch 静默；DB 已删即视为成功；残留由「清理缓存」兜底 |
| R5 | 删除正在听的书导致 TTS 状态残留（后台任务/AVSession；或晚到的 `persistProgress` 把已删书的进度行写回） | 低（第四轮已核实机制） | 锁屏卡片不消失 / 残留 orphan `progress` 行 | K7：删除前 `isActiveFor → stop()`；S2 验证项 8。`stop()` 会清 `clearTimer/stopFlushTimer/stopProgressTimer` 三个定时器，且 `loadChapter` await 之后有 `if (!this.active) return` 守卫 → 时序安全（§1.3 #27） |
| R6 | 长按 500ms 与 Grid 滚动冲突（滚动中误触发长按） | 低 | 误进编辑态 | 真机手感验证（S3-4）；必要时 600ms |
| R7 | 「删除」按钮误触 | 低 | 数据丢失 | 二次确认（B）+ 删除中禁用（防重入）；不做撤销（非目标） |
| R8 | `removeBooks` 部分失败 | 低 | 一半删一半留 | 失败后仍刷新书架，UI 与 DB 一致；用户可重试 |
| R9 | `filesDir/tocs` 有残留但用户的「清理缓存」数字不含它 | — | 数字偏小 | S4 修复（T-DATA-5/6） |
| R10 | `Navigation` 位于 `@Entry` 页面内时，返回键可能被 `Navigation` 先消费（本 SDK 无 `Navigation.onBackPressed`），导致编辑态无法用返回键退出 | 中 | 只能点「完成」退出（功能仍可用） | S1 真机项 6 专门验证。回退方案：在 `EntryAbility` 重写 `onBackPressed(): boolean`（已确认存在：`api/@ohos.app.ability.UIAbility.d.ts:737`）→ 读 `ShelfEditState`（此时需按 §4.1 回退为单例）→ `editing` 为真则 `exit()` 并 `return true` |
| R11 | `reload()` 并发/旧结果后到 | 中 | 已删书短暂回跳、选中集被旧数据覆盖 | S3-1 `reloadGen` 守卫 |
| R12 | 长按后仍补送 `onClick` → 刚选中的书被立即取消选中 | 中（需真机定论） | 编辑态选中状态乱跳 | K13 的 `longPressFired` + `onTouch(Down)` 复位已预防；S1 真机项 2 专门验证“长按进入后该书保持选中” |
| R13 | 选中切换→行重建→`BookCover` 重建；若 `pixmapCache`（模块级 64 条 LRU）已挤掉该封面，会重新解码 → 选中时封面闪一下 | 低（书架 > 64 本且近期未浏览才会中） | 观感（非功能） | 可接受。若真机明显：把 `BookCover` 的 `PIXMAP_LIMIT` 64 → 128（一行常量），或先把封面缓存预热再进编辑态 |
| R14 | **release 混淆后静默失效**：对 `@ObservedV2` 类（`ShelfEditState`）成员做字符串式访问（`@Monitor('edit.x')`/`this.edit['x']`/JSON 往返）——debug 全对、release 不刷新 | 低（只要守住 K15） | 发布版出现“点全选/删除无反应”类诡异 bug，且本地 debug 无法复现 | **K15/§5.5 已成文禁令**；`obfuscation-rules.txt` 无需改（struct 成员自动保留，§1.4 #30 产物实证）。若日后确需字符串点名 → 把字段名加进 `-keep-property-name`；发布前可跑一次 release 模式编译确认混淆阶段无报错（D21） |

---

## 10. DoD（真机逐项）

| # | 项 | 步骤 |
|---|---|---|
| D1 | 长按进入编辑态，顶栏三区文案/位置正确（中间真居中） | S1 |
| D2 | 多选/取消/全选/取消全选计数正确，角标与封面变暗同步（**含：长按进入编辑态时，其余未选中的书也显示空角标**） | S1 |
| D3 | 编辑态不打开阅读页；非编辑态点按行为不变 | S1 |
| D4 | 「完成」与系统返回键都能退出编辑态并清空选择（**若返回键被 `Navigation` 吞掉 → 按 R10 走 `EntryAbility.onBackPressed` 回退**） | S1 |
| D5 | 编辑态锁 Tab 滑动、底栏无 tab、听书 FAB 隐藏 | S1 |
| D6 | 二次确认弹窗：取消无副作用、删除执行、防重入 | S2 |
| D7 | 删除后书架立即刷新，重启后确实不在书架（DB） | S2 |
| D8 | `filesDir/chapters/{bookId}_*.json` 被清除（含内存层） | S2 |
| D9 | `filesDir/tocs/{bookId}.json` 被清除（**强证据用 S4 后的「目录缓存」行数字比对**；S2 阶段用 `ls` 或重新拉取目录旁证） | S2/S4 |
| D10 | `filesDir/local/{bookId}` 被清除，且可重新导入 | S2 |
| D11 | 正在听的书被删 → TTS 停止、FAB 与锁屏卡片消失 | S2 |
| D12 | 多选/全选删除、删空后回到空态且退出编辑态 | S2/S3 |
| D13 | 删除后从详情页返回不残留已删书籍的选中项 | S3 |
| D14 | 深色模式与放大字体下无裁切/串色 | S3 |
| D15 | 清理缓存页含「目录缓存」且 `clearCache` 后归零 | S4 |
| D16 | `hilog` 无新增 error | S1–S4 |
| D17 | 连续快速「删除 → 返回书架」不会出现已删书回跳（K11 守卫生效） | S3 |
| D18 | 读屏（无障碍）下编辑态能报出「已选中/未选中」 | S3 |
| D19 | 长按进入编辑态后，该书**保持选中**（顶栏为「已选择 1 本书」，不出现先选中又取消的跳动） | S1 |
| D20 | 书架可滚动时：编辑态上下滑动正常（`.onTouch` 不影响滚动）、滚动中不误进编辑态 | S1/S3 |
| D21 | **release 混淆面（不必上真机）**：`hvigorw assembleHap --mode module -p product=default -p buildMode=release` 至少跑到混淆阶段完成（生成 `.../release/obfuscation/nameCache.json` + 白名单），确认新代码不引入混淆期报错；随后按 §5.5 自查清单核对「无字符串式属性访问」。**注**：本仓 `signingConfigs` 只有 debug profile，签名阶段可能失败 → 那时以「混淆产物 + 静态自查」为替代证据，并记录为已知限制 | S1–S4 |

---

## 11. 工作量与顺序

| 步骤 | 内容 | 预估 | 真机轮次 |
|---|---|---|---|
| S1 | 编辑模式骨架 + 选择链路（4 文件） | 1.5 h | 1 |
| S2 | 删除链路（6 文件） | 1.5 h | 1 |
| S3 | 边界收尾 | 0.5 h | 与 S4 合并 |
| S4 | 目录缓存统计 + 文档（2 文件 + 4 docs） | 0.5 h | 1 |
| 合计 | 11 文件（2 新增） | ~4 h | 2–3 |

边界约定：S1 结束后**暂停**，等真机验证通过（重点是 **R10** 返回键是否被 `Navigation` 吞、**R12** 长按是否双触发/是否影响 Grid 滚动；**R2 已由官方文档关闭，只作冒烟**；**R3 角标若不动 → 走 §1.4 #38 的三级兜底**）再进 S2；S2 验证通过后 S3/S4 可连续做完再统一过 DoD。

收尾约定（第五轮补）：全部代码落地后，按 **§5.5 自查清单** + **D21** 过一次 release 混淆面（这是 debug 真机验证覆盖不到的唯一盲区）；`obfuscation-rules.txt` 保持不动。

---

## 12. 实施结果（2026-10-07）

### 12.1 逐阶段落地情况

| 阶段 | 文件 | 落地 | 编译 |
|---|---|---|---|
| **S1-1** | `model/ShelfEditState.ets`（新） | `@ObservedV2 class ShelfEditState`：`@Trace editing/selected/bookIds`；`enter/exit/isSelected/count/allSelected/toggle/toggleAll/setBooks` + 模块级 `sameIds` | ✅ |
| **S1-2** | `components/BookCover.ets` | 新增 `@Param dimmed: boolean = false` + `.opacity(this.dimmed ? 0.72 : 1)` | ✅ |
| **S1-3** | `pages/Shelf.ets` | 长按/点按分流（`longPressFired` + `onItemTouch` 复位）、`selectBadge`、`itemA11yText`、`entryKey` 三态、FAB 隐藏、`@Param edit` | ✅ |
| **S1-4** | `pages/Index.ets` | `@Local edit/deleting`；`shelfNormalHeader`/`shelfEditHeader` 分支；`bottomBar()` 编辑分支 + 0 参数 `deleteAction()` + `canDelete()`；`onBackPress`；`.scrollable(!edit.editing)` | ✅ |
| **S2-1** | `model/ShelfRepository.ets` | `removeBook` → `removeBooks(bookIds)`（含 `lastWriteAt.delete`），过时 TODO doc comment 一并替换 | ✅ |
| **S2-2/3/4** | `ChapterCache` / `TocCache` / `LocalBook` | `deleteBookChapters` / `deleteBookToc` / `deleteLocalBookData` | ✅ |
| **S2-5** | `model/BookRemoval.ets`（新） | `deleteBooks(ctx, bookIds)`：TTS 互斥 → DB 删除 → 三类缓存 best-effort 清理（封面刻意不清，理由见文件注释） | ✅ |
| **S2-6** | `pages/Index.ets` | `confirmDelete()` 二次确认 + `doDelete()`（`deleting` 防重入 → 退出编辑态 → `shelfRefresh+1` → Toast） | ✅ |
| **S3-1** | `pages/Shelf.ets` | `reloadGen` 代次守卫 | ✅ |
| **S3-2…** | 边界项 | 由 S1/S2 代码天然覆盖（`deleting` 防重入、`canDelete` 空选置灰、`tts.isActiveFor` 删前停播、`setBooks` 空书架自动退出编辑态） | ✅ |
| **S4-1** | `model/CacheRepository.ets` | `CacheStats.toc`、`tocDir()`、`isChapterFile` **改名** `isJsonFile`（未新增重复函数）、`getCacheStats` 合计、`clearCache` 清 tocs | ✅ |
| **S4-2** | `pages/CacheManage.ets` | `tocBytes`/`tocCount` + 「目录缓存」行 + 文案补「目录」 | ✅ |
| **S4-3** | 文档 | 本文件 + `progress.md` + `bugfix/TASKS.md` + `bugfix/RELEASE-NOTES.md` | ✅ |
| **S4-4** | do-not-touch 清单 | `Settings.ets` / `EntryAbility.ets` / `SourceRepository.ets` / `UI-SPEC.md` / `obfuscation-rules.txt` **均未触碰** | ✅ |

### 12.2 构建 / 混淆证据

- debug：`hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon` → `BUILD SUCCESSFUL`。
  仅剩既有告警（`Function may throw exceptions`，`Index.ets:105/111` 等，全部为改动前就有）。
- release：`... -p buildMode=release ...` → `BUILD SUCCESSFUL`，**`SignHap` 也通过**（D21 只要求「跑到混淆阶段」，本轮实际更强）。
- 混淆产物已刷新：`entry/build/default/cache/default/default@CompileArkTS/esmodule/release/obfuscation/`。
- **§5.5 / K15 静态自查**：全仓 `grep` → 无 `@Monitor('edit.`、无 `this.edit[`、无 `ShelfEditState` 的 JSON 往返（唯一命中是 `ShelfEditState.ets` 自己的 doc comment 文字说明）。
- **混淆面实证**（新增证据，比第五轮更直接）：
  - `PropertyCache`：`editing → c12`、`bookIds → d12` → `@ObservedV2` **类成员确实会被改名**（K15 的立论再获实证）；`selected` 未被改名（被同名白名单项保护，不影响结论）。
  - `fileWhiteLists.json`（本轮产物字段名为 `fileKeepInfo`）的 struct 成员：`Shelf.ets` 保留全部新增成员（`edit`/`longPressFired`/`selectBadge`/`onItemTap`/`itemA11yText`/`onLongPress`/`onItemTouch`/`entryKey`/`reloadGen`；真机轮把 `longPressToEdit` 改名为 `onLongPress` 并改为内联手势，见 §1.6），`Index.ets` 保留 `edit`/`deleting`/`confirmDelete`/`doDelete`/`shelfEditHeader`/`canDelete`/`deleteAction`，`CacheManage.ets` 保留 `tocBytes`/`tocCount`（同见 `projectWhiteList.json` 的 `projectKeepInfo.propertyNames`）→ **ArkUI struct 成员仍被整列保留**；`ShelfEditState.ets` / `BookRemoval.ets` / `CacheRepository.ets` 无 struct 白名单。
  - 结论：`obfuscation-rules.txt` 保持不动是正确的（新增的 struct 成员自动保留；类成员虽被改名，但全部调用点同步改名，且我们从不做字符串访问）。

### 12.3 真机验证结果（2026-10-07，设备 `33Z0224424136564`）

设备已接回，按「编译 → 安装 → `aa force-stop` → `aa start`」闭环跑完 §10 DoD。

| 项 | 结果 | 证据 |
|---|---|---|
| D1 | ✅ | 长按 **+498ms** 进编辑态；顶栏 `全选 [54,185][162,248]` / `已选择 1 本书 [311,184][950,247]`（真居中）/ `完成 [1099,185][1207,248]`；底栏 `删除` |
| D2 | ✅ | 像素分析：选中角标 = 品牌红圆 `(218,56,56)` + 白勾（簇 `[308,318]-[380,390]`，73px ≈ 22vp）；未选中 = 半透黑方块 + 白环；选中封面变暗 `(215,162,197)` vs 基线 `(203,129,178)`。计数点击链 1→2→1→2→3（全选）→0（取消全选）；全选/取消全选标签随态互换 |
| D3 | ✅ | 编辑态点按只改计数、不打开阅读页（dump 仍在书架）；长按后无补送 click |
| D4 | ✅ | `完成` 与系统 Back 键都退出编辑态并清空选择；**R10 未出现**（`Index.onBackPress` 生效，`EntryAbility.ets` 未改） |
| D5 | ✅ | 编辑态：底栏无 Tab（整条 `Column [0,2548][1260,2751]` = 删除栏）、Tab 滑动锁定（正常态可滑切 Tab、编辑态不可）；**听书 FAB 隐藏**（TTS 播放中基线有 FAB `Row [1031,1537][1207,1713]`，编辑态消失） |
| D6 | ✅ | 弹窗 `删除书籍` + `删除后，该书的阅读进度与缓存将一并清除，且不可恢复。` + `取消 (102,102,102)` / `删除 (218,56,56)`；`取消` 无副作用（仍在编辑态、仍选中 1 本、书数未变）；`删除` 用 `uitest uiInput doubleClick` 双击复验**防重入**：只删一次、无异常日志 |
| D7 | ✅ | 删除后书架立即 4→3；重启（`force-stop`/`start`）后仍 3；DB `books` 4→3 行、`progress` 7→6 行（只删了该书行；3 条历史孤儿进度行保留 = 设计如此） |
| D8 | ✅ | `files/chapters/` 13→6（`80ddd906_8..14` 共 7 个全清）；应用内「章节内容缓存」125.2KB→28.6KB |
| D9 | ✅ | `files/tocs/` 4→3（`80ddd906.json` 165583B 清除）；应用内「目录缓存」235.5KB→**73.8KB**（= 235.5 − 161.7，逐字节对上） |
| D10 | ⏭ | **用户决定跳过**（未授权删本地书）。基线已取证：`files/local/{155886f3,36331478}` 存在；「可重新导入」在本机也无法自动化（选择器内无 `.txt`，且 shell 无共享存储写权限） |
| D11 | ✅ | 播放中（`SourceReaderTts: start book=夜的命名术 chapter=13` + `avsession ready` + `background task started`）删除该书 → 之后**无任何 `play para=` 日志**（最后一条 10:35:17，删除 ~10:35:2x，目录 mtime 佐证）→ TTS 已停；FAB 消失。锁屏卡片为间接证据（`stop()` 内 `session.deactivate()+destroy()`） |
| D12 | ⏭ | **用户决定跳过**（未授权删空书架）。空态由 `setBooks([]) → exit()` 代码路径保证 |
| D13 | ✅ | 删除后 0.6s 内把 Tab 切走再切回（抢在异步 `reload()` 之前）→ 书架仍 3 本、`夜的命名术` 残留 **0** 次（`reloadGen` 守卫生效） |
| D14 | ⏭ | **用户决定跳过**（深色模式 / 放大字体）。静态旁证：新增 UI 全部走 `app.color.*` 色令牌（base + dark 均有定义），未引入硬编码色 |
| D15 | ✅ | 「清理缓存」页有「目录缓存」行：删书前 4 文件/235.5KB → 删书后 3/73.8KB → 点「清理全部缓存」后**全部归零**（图片/章节/目录/TTS 四类均 0 文件 0 B、合计 0），文件系统 `tocs/`+`chapters/` 目录被整个移除、`local/` 保留 |
| D16 | ✅ | `hilog` 全量扫描：**0 条** JS/ArkTS 运行期错误（`JsError` / `ArkTS` / `TypeError` / `Cannot read` / `Unhandled` / `Exception`），**0 条**本应用 domain（`A00000/com.lichtcui.sourcereader`）error 级日志。仅有框架内部既有告警（`ImageSource` 解码、`Plugin`、`ResourceManager` 等，封面相关遗留噪音，与本次改动无关） |
| D17 | ✅ | 同 D13（删除后立刻切页再回）：无已删书回跳 |
| D18 | ⏭ | **用户决定跳过**（读屏）。代码级证据：`itemA11yText()` 在编辑态拼「，已选中 / ，未选中」并绑到行 `.accessibilityText()`；角标自身 `.accessibilityLevel('no')`（纯装饰）。设备装有 `com.huawei.hmos.screenreader`，但启用会拦截单击自动化 |
| D19 | ✅ | 长按进编辑态后该书**保持选中**（`已选择 1 本书`），无先选后取消跳动 |
| D20 | ⚠️ 部分 | 见下方「D20 限制」 |
| D21 | ✅ | release 构建（`buildMode=release`）`BUILD SUCCESSFUL` **含 SignHap**（强于「跑到混淆阶段」的要求）；混淆产物 + `PropertyCache(editing→c12 / bookIds→d12)` + `structProperties` 白名单 + §5.5 静态自查全过 |

**D20 限制（唯一未完整验证项）**：本机书架只有 3–4 本书（grid 2 行 / list 4 行，≤ 一屏），**内容不足以滚动**，而三条「加书」路径在该设备上都不可自动化：

1. **搜索提交**：本机 IME 处于硬件键盘态（软键盘不显示，只有候选条 + 剪贴板条）→ 无法点「搜索」键盘动作；注入 `keyEvent 2050/66`、`inputText` 均不触发 `TextInput.onSubmit`。
2. **本地导入 / 备份导入**：均走 `DocumentViewPicker`，选择器内「最近 30 天内，没有文件」（无 `.txt`）；且 shell 对共享存储（`/storage/media/100/local/files`，`drwxrws--x`）**无写权限**，无法投放测试文件。
3. **缩小窗口**：`aa start --wh/--ww` → 设备不支持（`Error 10106107 The current device does not support using window options`）。

**替代证据**：① 3s 慢滑（手指持续移动 ≥ 500ms）**不误进编辑态**（长按内置位移容差生效）；② 编辑态内跨书慢滑选中数不变；③ `.onTouch` 为纯被动回调、`.parallelGesture` 只并行不竞争 → 不阻断 `Grid`/`List` 滚动（代码层结论）。若后续书架书量 ≥ 8，建议补一次真机滚动回归。

### 12.4 收尾

- 真机诊断用的临时 `hilog('ShelfDiag')` 三条（+ import）已移除；清理后重新构建 + 安装 + 复验 D1/D2/D3/D4/D6 通过。
- R3（角标刷新）三级兜底的第 ② 级（`selectBadge` 改单参数对象字面量）**未启用** —— 真机确认第 ① 级（三态 key）已足够。
- **回滚：未触发**。§8 各阶段的 rollback 命令仍然有效（S1：`git checkout -- entry/src/main/ets/pages/Index.ets entry/src/main/ets/pages/Shelf.ets entry/src/main/ets/components/BookCover.ets && rm entry/src/main/ets/model/ShelfEditState.ets`；S2/S4 类推）。
