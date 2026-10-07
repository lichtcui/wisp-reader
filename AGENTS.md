# AGENTS.md

本仓库是 **HarmonyOS NEXT 原生阅读 App**（ArkTS + ArkUI），兼容 Legado 书源格式。
书源引擎复用本地 Rust 项目，经 `ohos-rs` 编译为 `.so`，由 ArkTS 通过 NAPI 调用。

> **项目状态**：M0–M5 已完成并真机验证；M6（规则调试器 / 缓存清理 / 备份恢复）未开始。当前以单点修复与小迭代为主。

## 按需查阅（**不要**开场通读）

| 需要什么 | 去哪 |
|---|---|
| 完整设计方案（权威） | [`docs/plan.md`](./docs/plan.md) |
| 进度 / 未决风险 | [`docs/progress.md`](./docs/progress.md) |
| 环境 / 构建 / 安装 / 调试 / 签名 | [`docs/development.md`](./docs/development.md) |
| 引擎与 NAPI 接口 | [`docs/engine.md`](./docs/engine.md)、`entry/src/main/cpp/types/liblegado_core/index.d.ts` |
| UI 规范（**改底部抽屉前必读**） | [`docs/specs/UI-SPEC.md`](./docs/specs/UI-SPEC.md) |
| 已踩过的坑（**按症状查**） | [`docs/PITFALLS.md`](./docs/PITFALLS.md) |
| 技术决策与理由 | [`docs/decisions.md`](./docs/decisions.md) |
| 架构 / 目录结构 | [`docs/architecture.md`](./docs/architecture.md) |
| bug 修复生命周期 | [`docs/bugfix/TASKS.md`](./docs/bugfix/TASKS.md) |
| 调研 / 方案（如端侧自建 TTS） | [`docs/research/`](./docs/research/) |

## 项目禁令（已定，勿擅改）

- **引擎不降级**：必须走 `rust/legado-engine` + `ohos-rs`，不要改回 ArkTS 直连 HTTP。
- **网络只在 Rust**：ArkTS 侧不发起书源请求（封面也由 Rust 代下，带 header/Cookie）。
- **禁用证书放行**：Rust 侧 `reqwest` + `rustls`，不得加 `danger_accept_invalid_certs` 之类的绕过。
- **状态管理固定 V2**：新代码用 `@ComponentV2` / `@Local` / `@Param`，**不要**用 `@State` / `@Prop`。
- **阅读排版固定横向分页**（Swiper + `measureTextSize`，跨章连续滑动），不要改回纵向滚动。
- **视觉沿用白 + 红**（`#DA3838`，红系轻渐变），见 `docs/plan.md` §2 Design Token。
- **v1 不做**：JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS。
  **例外**：`@js:` 的 **L1 字符串模式**仍解析（非 L1 才排除）。

> 需要改动上述任一决策前，先读 [`docs/decisions.md`](./docs/decisions.md) 确认理由。

## 约定 / 坑

- **文档落位（硬性）**：根目录**只允许** `AGENTS.md` 与 `README.md` 两个 `.md`。
  任何新产出的文档——bug 修复记录、审计、根因分析、任务清单、UI 规范、发布说明、
  交接记录（handoff）、调研/方案等——**一律写入 `docs/` 对应子目录**：
  UI/交互规范 → `docs/specs/`；调研/方案 → `docs/research/`；bug 审计与修复生命周期 →
  `docs/bugfix/`；阶段性交接 → `docs/handoff/`（命名 `HANDOFF-S<N>.md`）；核心常读文档留在 `docs/` 根。
  **禁止**再在根目录新建 `.md`。移动或新增文档后，务必同步更新引用它的相对链接。
- **底部抽屉（硬性）**：任何抽屉的样式/动效改动，**先读 [`docs/specs/UI-SPEC.md`](./docs/specs/UI-SPEC.md)**；
  全项目抽屉**必须一起改**（共 7 处调用点，见该文档 §2 清单），并逐项过 §3 检查清单。
  **底部 tab 页（`TabContent`）内的抽屉一律用 `mode: 'cover'`**（窗口模态层，面板可从屏幕最底部上滑并盖住 tab 栏，
  tab 栏全程不动）；`NavDestination` 页用 `overlay`。
  唯一实现是 `ui/common/BottomDrawer.ets`（`mode: 'overlay'`，常驻挂载）；**禁止**裸 `bindSheet`
  与 `if (flag) { BottomDrawer(...) }` 式条件挂载。
- **改完必走闭环**：**编译 → 安装 → `aa force-stop` → 启动 → 观察**。
  只编译不安装，设备上跑的是旧版；不 `force-stop` 则 `aboutToAppear` 不重跑。
  命令见 [`docs/development.md`](./docs/development.md)（流程清单见 skill `harmony-device-run`）。
- **ArkTS 严格模式**：不用 `any`；JSON 解析字段名等点语法属性要在 `entry/obfuscation-rules.txt` 的
  `-keep-property-name` 保留（release 已开混淆）。
- **签名凭据**：`build-profile.json5` 含明文/加密凭据，**不要提交**。
  `git update-index --skip-worktree build-profile.json5`（仓库保存 `signingConfigs: []` 的干净版）。
- 设备 UDID：`33Z0224424136564`。调试日志 tag：`SourceReaderPoC`（后续按页面各自定义）。
- 参考项目：`~/Documents/playground/legado-source-filter`（引擎来源，Rust）、
  `~/Documents/playground/harmony-pokerouge`（视觉参考，白+红）。
