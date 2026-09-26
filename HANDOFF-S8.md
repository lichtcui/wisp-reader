# HANDOFF-S8 — 书源管理模块（A–F）

日期：2026-09-26
范围：**仅书源管理模块** —— `pages/BookSourceManage.ets` + 其检测链路所需的 Rust `detect`/`verify_chain`。
基线：`0a1a4d9`（S7 收尾）。本轮改动**未提交**（见 §7）。

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

本轮改动**未提交**。预期纳入提交的文件：

```
entry/src/main/ets/pages/BookSourceManage.ets
rust/legado-engine/src/runtime.rs
rust/legado-core/src/lib.rs
entry/libs/arm64-v8a/liblegado_core.so
HANDOFF-S8.md
```

`AGENTS.md`、`docs/progress.md`（并行 TTS 工作流）与本文件外的 untracked 文档（`AUDIT.md` /
`ROOT-CAUSE.md` / `TASKS.md` / `UI-SPEC.md` / `HANDOFF-S3..7.md`）沿旧例不纳入。