# SPEC — `detect-job`

状态：**待批准（draft）** · 归属：[`SPEC-BOOKSOURCE-REVAMP.md`](./SPEC-BOOKSOURCE-REVAMP.md) 模块 `detect-job`
Commands / Project Structure / Code Style / Testing Strategy / Boundaries 见 map 文件 §4–§8，本文只写本模块特有内容。

## Objective

把检测从「一次 `await` 全量、丢了就重跑」变成**可续跑的后台作业**：分批推进、进度可见、可取消、
结果增量落盘、进程重启后接着跑；息屏期间靠系统长时任务继续。

用户可见的成功：可以点「开始检测」然后离开去做别的事；回来看到进度或已经完成的结果；中途杀掉应用
不会白跑。

## Non-goals

- 不做进度 UI（那是 `detect-ui`）；本模块只通过 `@Trace` 暴露状态。
- 不取消 Rust 侧的单次调用（见下「取消」——分批路线让它不必要）。
- 不做网络重试退避策略的重新设计（沿用引擎既有行为）。

## 关键设计决策

**1. 分工：ArkTS 编排 + 引擎无状态。** 本模块**不**要求引擎提供常驻任务或取消接口。

```
ArkTS: 取一批 32 源（source-store 投影 → 完整 JSON）
      → bookEngine.detect(batch, { mode })      // 引擎：一次调用一个集合，无状态
      → 结果 append 到 results.jsonl            // 追加写，不重写
      → patchDetect(逐条单行 UPDATE)            // source-store 单行写
      → 更新 job.json + 刷一次 @Trace 进度
      → 下一批
```

**2. 取消。** 取消 = 置状态为 `cancelled` 并停止派发下一批。**当前批在途的最多 32 源会在 ≤ 单批超时
（L1 约 8 s 量级）内自然收尾**，不需要 Rust 侧取消原语。这是分批路线换来的最大简化——值得写下来，
以免以后有人为了「更快的取消」去动 NAPI 契约。

**3. 落盘格式。** 用追加写 + 一个小的状态文件，避免每批重写大 JSON：

```
filesDir/detect/job.json      // 作业状态（小，可整写）
  { status, mode, keyword, total, done, cursor, batchSize,
    startedAt, updatedAt, fingerprint }
filesDir/detect/results-<轮次戳>.jsonl // 每轮一个文件，每批 append 一行（永不重写）
```

**保留策略：只保留最近 2 轮**（够做「上一轮 vs 本轮」对比），更早轮次的文件删除。
（原设计为单个 `results.jsonl` 追加写，因会无限增长而改为此形式——见
[`../research/BOOKSOURCE-REVAMP-PLAN.md`](../research/BOOKSOURCE-REVAMP-PLAN.md) A7。）

`fingerprint` = 源集合摘要（参与检测的 `id` 列表 + `mode` + `keyword` 的确定性摘要）。
**只有 fingerprint 匹配才允许续跑**——书源集合变了（导入/删除/改关键词）就作废，避免用旧结果拼出新结论。

**4. 状态机**（纯函数部分放 `model/DetectJob.ets`，不依赖 `@kit.*`，以便主机仿真覆盖）：

```
idle ──start──> running ──批循环耗尽──> done
                   ├──cancel──> cancelled ──resume──> running
                   └──连续失败/不可恢复──> failed ──resume──> running
   （进程重启：running → 读 job.json，fingerprint 匹配则续跑，否则 idle）
```

**T4.1 冻结的状态语义（2026-10-18）：** `start` 在 running 时拒绝；`failed` / `cancelled` 仅在
fingerprint 相同时从原 `cursor` 继续；`done` 或 fingerprint 变化时建立新一轮并从 0 开始。
`cursor` 按去空、去重、字典序排序后的源 ID 顺序推进，避免同 fingerprint 因集合顺序变化导致续跑漏源或重测。

**T4.1 冻结的 `@Trace` 字段：**

| 字段 | 语义 |
|---|---|
| `status` | `idle` / `running` / `done` / `cancelled` / `failed` |
| `mode` | `probe` / `full` |
| `keyword` | 本轮检测关键词 |
| `total` | 本轮源总数 |
| `done` | 已处理源数 |
| `cursor` | 下一个待处理源在规范化 ID 顺序中的位置 |
| `batchSize` | 每批源数，默认 32 |
| `startedAt` | 本轮开始时间（epoch ms） |
| `updatedAt` | 最近一次状态更新时间（epoch ms） |
| `fingerprint` | 源 ID 集合 + mode + keyword 的确定性摘要 |
| `message` | 失败详情；非 failed 状态为空 |

`sourceIds` 是 runner 的运行时字段，不进入上述 `@Trace` 契约，也不写入 `job.json`。

**5. 进度节流。** 每批（32 源）刷一次 `@Trace`，**不是每源**。3000 源 = 约 94 次状态更新，
而不是 3000 次重渲染。

**6. 长时任务。** 实测事实与 SDK 原文规则见
[`../research/T0.1-LONG-TASK-EVIDENCE.md`](../research/T0.1-LONG-TASK-EVIDENCE.md)（`T0.1` 真机，2026-10-15 已定）：

- `DATA_TRANSFER` **可用**：真机申请成功、通知栏出现常驻通知、**息屏 606 秒 tick 零丢**；
- **一个 UIAbility 同时只能有一个长时任务**（第二次 `startBackgroundRunning` 报 `9800005`）⇒ 需要与听书并存时，
  **不要**再申请一个任务，而用**一个任务带多种类型**：
  `startBackgroundRunning(ctx, bgModes: string[], wantAgent)` / `updateBackgroundRunning(ctx, bgModes)`（均 @since 12）；
- **硬约束（SDK 原文）**：`DATA_TRANSFER`「进度超过 **10 分钟**不更新，该类型任务即被取消」，且进度通知必须是
  **实况窗（live view）**。实测停表恰在 **10 分 03 秒** ⇒ 作业**必须按 ≤10 分钟节奏更新进度**；
  3000 源单轮（c=16 ≈4.4 min）落在窗口内，**多轮 / 超长作业必须分片**。
- ⚠️ **前置 P0**：TTS 侧的 `AUDIO_PLAYBACK` 任务当前**不成立**（`AVSessionNotifyUpdateNotification failed
  ret=980000502` → 系统拿不到任务通知 → **约 24 秒后任务被停**，见 `docs/bugfix/TASKS.md`）⇒
  「靠听书的长时任务保命」不可依赖；「一任务多类型」也须待其修复后复验。

实现形状（正式实现归 `T4.4`）：

```ts
// 作业独立持 dataTransfer；若听书已持「有效」任务，改成 union 类型（绝不二次 start）
await backgroundTaskManager.startBackgroundRunning(ctx, ['dataTransfer'], wantAgent)
// 每批顺手更新进度通知（≤10 分钟一次，须实况窗 live view）
```

`ohos.permission.KEEP_BACKGROUND_RUNNING` **已在 `entry/src/main/module.json5:44` 声明**；
`"backgroundModes"` 已含 `dataTransfer`（`T0.1` 期间加入，正式实现沿用）。作业结束/取消/失败时
`stopBackgroundRunning`（仅当任务由本模块创建）。

**降级路径（已批准，2026-10-14，本次未触发）：** 若某机型/版本上 `DATA_TRANSFER` 不可用，或实况窗进度
不可实现 ⇒ **降级为「仅应用在前台时推进作业」+ UI 明示「离开应用会暂停」**；
map 文件 §9-6 的判据相应改为「应用在前台时持续推进」。（本次实测**可用**，故 Phase 4 范围不变。）

**7. 单例。** `@ObservedV2` + `@Trace` 的进程级单例，仿 `model/TtsPregenRunner.ets:34-56`：
页面被收起再打开时作业还在跑，状态与位置都还在。
（与 `TtsPregenRunner` 的差异：本模块**不需要轮询**——进度由本地批次驱动，无远端作业要查。）

## Success Criteria

1. 3000 源作业在中途强杀进程 → 重启后从 `cursor` 续跑；**已完成的结果不丢、不重复检测**。
2. 取消后 ≤ 1 批（≤ 单批超时）完全停止，无后续网络请求。
3. 息屏 10 分钟期间进度继续推进（真机验证：`DATA_TRANSFER` 已实测**息屏 606 秒零丢 tick**；注意
   SDK 规则「进度 >10 分钟不更新即取消」⇒ 每批顺手更新进度）；与 TTS 播放**共存时不互相终止**
   （并存只能靠「一个任务多类型」，且需先修 TTS 侧长时任务不成立的 P0）。
4. 主机仿真覆盖状态机：正常完成 / 取消 / 中断续跑 / fingerprint 不匹配作废 / 结果文件半行损坏
   （追加写被打断）的读回行为。
5. `job.json` + `results.jsonl` 的大小与批次线性，且**从不出现整文件重写**。
6. `@Trace` 更新次数 ≈ 批次数，而非源数。

## Boundaries

- **Ask first**：续跑是否要用户确认；
  批大小与并发的关系。
- **Never**：每源写盘或每源刷 UI；一次性 `JSON.parse` 3000 条结果；在 fingerprint 不匹配时续跑；
  为了让取消更快而给引擎加取消原语。

## Open Questions

1. ~~**`BackgroundMode.DATA_TRANSFER` 是否存在且适用**~~ —— **已定（`T0.1` 真机，2026-10-15）**：
   存在且可用；**不能**同时持两个任务（`9800005`），并存须用「一个任务多类型」；受「>10 分钟不更新进度
   即取消」约束。证据 → [`../research/T0.1-LONG-TASK-EVIDENCE.md`](../research/T0.1-LONG-TASK-EVIDENCE.md)。
   **遗留**：TTS 侧长时任务当前不成立（P0，`docs/bugfix/TASKS.md`），「与 TTS 共存」待其修复后复验。
2. 续跑时机：进程启动即自动续跑，还是进书源页/由用户点「继续」？（自动续跑可能让用户困惑：
   刚打开应用就在跑网络请求，且耗流量。）
3. 批大小 32 与引擎并发的匹配：**并发已定 16**（T0.2 实测，`SPEC-DETECT-ENGINE.md` §3.5）；
   批 32 + 并发 16 = 2 个串行波次，取消的「最坏收尾时间」≈2×8 s（L1 cap）。是否改成
   「批大小 = 并发数 = 16」以让取消更利落（代价：单批 NAPI JSON 开销翻倍）？
4. 结果保留几轮、每轮多少条、`results.jsonl` 的压缩/淘汰规则（map 文件开放问题 8）。
5. 是否需要一个「仅 Wi-Fi」门禁（仓库在 TTS 预生成上已有此模式：
   `TTS_PREGEN_WIFI_ONLY`）。2970 源预检会消耗可观流量，这可能是必需的而不是可选的。
