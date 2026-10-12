# 技术决策记录（ADR 摘要）

> 决策**已定**，勿擅改。改动任一决策前先在这里查有没有反对理由。
> **禁令类**（「不要做什么」）留在 [`../AGENTS.md`](../AGENTS.md) §项目禁令；本文件记「选了什么 + 为什么」。

| # | 决策 | 理由 | 影响面 |
|---|---|---|---|
| D1 | 引擎复用 Rust：`rust/legado-engine`（纯核心）+ `rust/legado-core`（NAPI 壳）+ `ohos-rs`，**不降级** | 复用 `legado-source-filter` 已有规则引擎与链路校验，避免在 ArkTS 重写一遍 | `rust/`、`engine/` |
| D2 | Rust 持有 HTTP：`reqwest` + `rustls`；每源独立 `Client`（Cookie 隔离，上限 64 后回收）+ `concurrentRate` 限速；**禁用证书放行** | 书源各自需要独立 Cookie/UA/限速；rustls 免 OpenSSL 交叉编译 | `http_client.rs` |
| D3 | 书源持久化用 `preferences` JSON（`SourceRepository`）；书籍/进度用 `relationalStore`（`ShelfRepository`，表 `books`/`progress`） | 书源是低频小数据；书架需要查询与事务 | `model/` |
| D4 | 搜索调度：ArkTS 滑动窗口（并发 8）+ **书源置信度**排序（`confidence` 字段持久化：`server_error`/`timeout`/`network_error`/`blocked` 扣分，成功回分） | 端侧无全局调度器；置信度让劣质源自动下沉 | `SearchResult.ets`、`SourceConfidence.ets` |
| D5 | 阅读排版：**横向分页翻页**（Swiper + `measureTextSize` 精确分页，跨章连续滑动） | 接近实体书体验；跨章预取已在 M4 打通 | `Reader.ets` |
| D6 | 封面由 Rust 代下（带 header/Cookie），落盘后 ArkTS 加载（二进制不过 NAPI） | 部分站点封面需 Cookie/Referer | `downloadCover` |
| D7 | 状态管理 **V2**（`@ComponentV2` / `@Local` / `@Param` / `@Monitor`）；跨页 `AppStorageV2`、跨启动 `PersistenceV2` | 与既有页面一致（V1/V2 不可混用于同一组件） | 全部 UI |
| D8 | 视觉：白 + 红（`#DA3838`，红系轻渐变 `#e35a5a → #da3838`），颜色走 `resources/{base,dark}/element/color.json` 令牌化 | 参考 `harmony-pokerouge` | 全部 UI |
| D9 | bundle `com.lichtcui.sourcereader`；`compatibleSdkVersion 5.0.0(12)` / `targetSdkVersion 6.1.1(24)` | 目标设备与 SDK 约束 | `AppScope`、`build-profile.json5` |
| D10 | JS 例外：`@js:` 的 **L1 字符串模式**仍走 `resolve_js_l1` 解析，失败才排除（非 L1 才直接排除）；v1 不做 JS 运行时 | 内置 13 个源里有 L1 用法，一律砍掉会误伤 | `search_url.rs`、`gate.rs` |
| D11 | v1 不做：JS 运行时、登录型源、发现(explore)、真分页、在线 TTS（**换源自 v1.1 起解禁，见 D16**） | 控制范围，先跑通主链路 | 全局 |
| D12 | 端侧自建 TTS（GPT-SoVITS 音色替代系统 TTS）是**并行增量**、未立项，不改动 M5 代码 | 与 M5 系统 TTS 路线不冲突，可独立推进。**→ 2026-10-12 已封存**：P4–P6 原型真机跑通（ZipVoice 端侧 RTF 0.49–0.54），但 OHOS 交叉编译的 ORT 对一切动态 shape 输出的 `GetShape()` 返回 ~4× 虚高帧数（mel 1614 vs 正确 400）⇒ 波形全 NaN / 电流声；升级 ORT、降级、换 vocoder、换模型四条路同因堵死，**重启前提 = ORT 上游修复**。证据与可恢复产物见 [`archive/TTS-LOCAL-ONNX/`](./archive/TTS-LOCAL-ONNX/README.md) | [`research/TTS-PLAN.md`](./research/TTS-PLAN.md)（原计划）、[`archive/TTS-LOCAL-ONNX/`](./archive/TTS-LOCAL-ONNX/README.md)（封存记录） |
| D13 | 门禁只在导入时做（`gate::run`）：非文字/禁用/登录/JS 源排除，可选字段含 JS 则**降级丢规则**而非排除整源 | 保源数量与可用性平衡（13 源 filter 后保留） | `gate.rs` |
| D14 | **不追原神角色音色**：远端 TTS 声线就用 804 底模自带的 5 个 sid，且它们只是**标签名**（不代表真实角色）；不再投入「贴角色标签」的调研与实现 | 现有 VPS（4C Xeon / 无 GPU）上三条路线全部撞墙：**A** 声纹匹配 = 证伪（187 声线非原神角色，已做真阳性对照排除假阴性）、**B** ZipVoice + 官方中配参考音频 = 音色 7/7 命中且 RTF<1，但 `num_steps=3` 的 few-step 毛刺属听感风险（用户不接受）、**C/D** 租 GPU 跑 GPT-SoVITS 或自训 VITS 导 ONNX = 需换硬件；收益（像不像角色）远小于成本。**注（2026-10-11）：前提已变 —— 离线批量预生成把 `RTF<1` 这条唯一的硬理由拿掉了，路线 B 在 `num_steps=12` 下已过用户听感，见 D15**；但**实时链路仍不追音色**（本节结论不变） | `server/app.py`（VITS 分支）、[`research/TTS-VOICE-SOURCES.md`](./research/TTS-VOICE-SOURCES.md)（纯参考） |
| D15 | **TTS 判据按场景分档**：**实时流式**仍守 `RTF < 1`（VITS）；**离线批量预生成**改用 `RTF ≤ 24 ÷ 每日收听小时数`（听 2 h/天 → ≤ 12）+ 峰值 RSS ≤ 机器余量。据此**部分重开 D14**：ZipVoice + 官方中配参考音频在 **`num_steps=12` 下已过用户听感（2026-10-11 试听确认）**，可作离线批量引擎（零新依赖、零新硬件、峰值 1.0 GB）；线上实时引擎与 5 个 sid 音色名不变，预生成本身**尚未实现、待立项** | 批量把「RTF<1」这个唯一硬理由拿掉，代价换成「首次缓冲的生成时间 + 批量 QC」。实测（线上同一份 `app.py`，题材=285 字真实对白）：`steps=12` RTF **3.07–4.11**（100 章 55 h ≈ 2.3 天预热）、`steps=6` 1.54–2.09（用户已否）、`steps=24` 6.30；peak RSS **0.81–1.0 GB**（文献里 ~2.2 GB 是 GPT-SoVITS 的数）；**GPT-SoVITS 已实测（2026-10-12，同机同文本）：v2ProPlus RTF 5.42 / v4 RTF 115.3 / 零样本底座 5.86–7.17，常驻 3.3–3.4 GB（v4 无 swap 直接 OOM）⇒ CPU 上比 `steps=12` 慢 1.7× 且吃满内存，不作为批量引擎**（D14 的 C 路线「租 GPU」前提不变） | [`research/TTS-PREGEN-PLAN.md`](./research/TTS-PREGEN-PLAN.md)、`server/app.py`（`ENGINE` / `NUM_STEPS` / `VOICE_REFS`） |
| D16 | **换源解禁（v1.1）**：入口 = 阅读页顶栏 `...` **左侧**的「换源」按钮 → 抽屉内**渐进**列出候选（一源一次 `search`，谁先回谁先上屏）；候选判定 = **书名 + 作者严格匹配**（`model/SourceSwitch.ets::isSameBook`，与书架 `isInShelf` 去重同语义，**不做模糊匹配**）；切换 = **换 `bookId`**（`computeBookId(sourceUrl, bookUrl)`，所以是「删旧 `books`/`progress` 行 + 清旧源章节/目录缓存 + 插新行」而不是改旧行的 `source_url`；`addedAt` 保留以维持书架排序）；进度**按章节序号迁移** = 先在新目录里按章节名对齐，落空再按 `percent` 折算（`locateChapter`，结果向用户回报「按章节对齐」/「按进度对齐」）；执行前弹确认框（不可撤销）。**零 Rust 改动** —— 不依赖 `bookUrlPattern` | 同一本书换来源是阅读类 App 的刚需（源失效 / 正文残缺 / 更新慢），而原 v2 计划的 `bookUrlPattern` 前提只有部分源支持；严格匹配 + 显式确认把误伤面压到最小（候选少但不会切错书） | `model/SourceSwitch.ets`、`components/SourceSwitchPanel.ets`、`pages/Reader.ets`、`pages/Index.ets`（`onMore` 带参）、`specs/UI-SPEC.md` §2 |

## 已知取舍（相对 Legado 官方语义）

`known_gaps`：负索引、区间选取、`&&`、`children`、`ownText/all` 未支持。见 [`engine.md`](./engine.md) §已发现 / 已修的坑。

## 参考项目

- 引擎来源：`~/Documents/playground/legado-source-filter`（Rust，含完整规则引擎 / 链路校验）
- 视觉参考：`~/Documents/playground/harmony-pokerouge`（HarmonyOS，白 + 红）
