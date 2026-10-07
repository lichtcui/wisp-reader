# AGENTS.md

本仓库是 **HarmonyOS NEXT 原生阅读 App**（ArkTS + ArkUI），兼容 Legado 书源格式；书源引擎复用本地 Rust
项目经 `ohos-rs` 编译的 `.so`，由 ArkTS 通过 NAPI 调用。
**状态**：M0–M5 已真机验证；M6（规则调试器 / 缓存清理 / 备份恢复）未开始，当前以单点修复与小迭代为主。

## 按需查阅（**不要**开场通读）

| 需要什么 | 去哪 |
|---|---|
| 完整设计方案（权威） | [`docs/plan.md`](./docs/plan.md) |
| 进度 / 未决风险 | [`docs/progress.md`](./docs/progress.md) |
| 环境 / 构建 / 安装 / 调试 / 签名 | [`docs/development.md`](./docs/development.md) |
| 引擎与 NAPI 接口 | [`docs/engine.md`](./docs/engine.md)、`entry/src/main/cpp/types/liblegado_core/index.d.ts` |
| UI 规范（**改底部抽屉前必读**） | [`docs/specs/UI-SPEC.md`](./docs/specs/UI-SPEC.md) |
| 已踩过的坑（**按症状查**） | [`docs/PITFALLS.md`](./docs/PITFALLS.md) |
| 技术决策与理由 / 参考项目 | [`docs/decisions.md`](./docs/decisions.md) |
| 架构 / 目录结构 | [`docs/architecture.md`](./docs/architecture.md) |
| bug / 发布 / 调研 / 交接 | [`docs/bugfix/`](./docs/bugfix/)、[`docs/research/`](./docs/research/)、[`docs/handoff/`](./docs/handoff/) |

## 项目禁令（已定，勿擅改；理由见 [`docs/decisions.md`](./docs/decisions.md)）

- **引擎不降级**：走 `rust/legado-engine`（纯核心）+ `rust/legado-core`（NAPI 壳）+ `ohos-rs`，不要改回 ArkTS 直连 HTTP。
- **网络只在 Rust**：ArkTS 侧不发起书源请求（封面也由 Rust 代下，带 header/Cookie）。
- **禁用证书放行**：Rust 侧 `reqwest` + `rustls`，不得加 `danger_accept_invalid_certs` 之类的绕过。
- **状态管理固定 V2**：新代码用 `@ComponentV2` / `@Local` / `@Param`，**不要**用 `@State` / `@Prop`。
- **阅读排版固定横向分页**（Swiper + `measureTextSize`），不要改回纵向滚动。
- **视觉沿用白 + 红**（`#DA3838`，红系轻渐变），见 [`docs/plan.md`](./docs/plan.md) §2 Design Token。
- **v1 不做**：JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS（**例外**：`@js:` 的 L1 字符串模式仍解析）。

## 硬性约定（其余约定与坑见 [`docs/PITFALLS.md`](./docs/PITFALLS.md)、[`docs/development.md`](./docs/development.md)）

- **文档落位**：根目录**只允许** `AGENTS.md` 与 `README.md`；新文档一律进 `docs/` 对应子目录
  （UI 规范 → `specs/`、方案 → `research/`、bug → `bugfix/`、交接 → `handoff/HANDOFF-S<N>.md`），并同步更新引用它的链接。
- **动抽屉前先读 [`docs/specs/UI-SPEC.md`](./docs/specs/UI-SPEC.md)**：7 处调用点必须一起改；唯一实现
  `ui/common/BottomDrawer.ets`，禁止裸 `bindSheet` 与 `if (flag) { BottomDrawer(...) }` 条件挂载；
  `TabContent` 内 `mode: 'cover'`，`NavDestination` 页 `overlay`。
- **改完必走闭环**：**编译 → 安装 → `aa force-stop` → 启动 → 观察**（见 skill `harmony-device-run`）。
- 其余（ArkTS 严格模式与混淆、签名凭据、UDID、日志 tag、构建命令）见 [`docs/development.md`](./docs/development.md)。
