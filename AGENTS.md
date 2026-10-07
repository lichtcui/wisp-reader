# AGENTS.md

本仓库是 **HarmonyOS NEXT 原生阅读 App**（ArkTS + ArkUI），兼容 Legado 书源格式；书源引擎复用本地 Rust
项目经 `ohos-rs` 编译的 `.so`，由 ArkTS 通过 NAPI 调用。
**状态**：M0–M5 已真机验证；M6（规则调试器 / 缓存清理 / 备份恢复）未开始，当前以单点修复与小迭代为主。

## 按需查阅（**不要**开场通读）

| 需要什么 | 去哪 |
|---|---|
| **构建 / 安装 / 跑测 / 看日志** | **先 `make help`**（根目录 `Makefile`）；改完代码直接 `make run` |
| 完整设计方案（权威） | [`docs/plan.md`](./docs/plan.md)（顶部有行号目录，只读需要的 §） |
| 进度 / 未决风险 / 交接 | [`docs/progress.md`](./docs/progress.md)（只记当前状态，很短） |
| 环境 / 构建 / 安装 / 调试 / 签名 | [`docs/development.md`](./docs/development.md) |
| 引擎与 NAPI 接口 | [`docs/engine.md`](./docs/engine.md)（语义）、`entry/src/main/cpp/types/liblegado_core/index.d.ts`（**签名**） |
| UI 规范（**改底部抽屉前必读**） | [`docs/specs/UI-SPEC.md`](./docs/specs/UI-SPEC.md) |
| 已踩过的坑（**按症状查**） | [`docs/PITFALLS.md`](./docs/PITFALLS.md) |
| 技术决策与理由 / 参考项目 | [`docs/decisions.md`](./docs/decisions.md) |
| 架构 / 目录结构 / **改什么动哪些文件** | [`docs/architecture.md`](./docs/architecture.md)（末尾有「改动定位」表） |
| bug / 发布 / 调研 / 交接 | [`docs/bugfix/`](./docs/bugfix/)、[`docs/research/`](./docs/research/)、[`docs/handoff/`](./docs/handoff/) |
| 已完结的历史（**默认不读**） | `docs/archive/`（含 105KB `SHELF-EDIT-PLAN.md`、61KB `ARCHIVE-S3-S8.md`） |

## 上下文卫生（省 token：本文件 + 全部历史每轮都要重发）

- **大文件只读片段**：`docs/plan.md` 与 `docs/archive/*`（50–105KB）顶部有行号目录（由 `make docs-toc` 维护），
  用 `read` 的 `offset`/`limit` 取段；改同一文件先 `grep -n "^## "` 定位再读，**不要**整文件反复重读。
- **`docs/archive/` 默认不读**：那是已完结的历史（含 105KB `SHELF-EDIT-PLAN.md`）；只在查旧账时进，且先看它的目录。
- **大 `.ets` 先看文件索引**：`pages/Reader.ets`(1.4k 行)、`model/TtsController.ets`(1.3k 行)、`pages/SearchResult.ets`(1k 行)
  顶部有成员名索引，按名字 `grep` 取段，别整文件读。
- **用内置工具而非 bash 同名牌**：`read`/`grep`/`find`/`ls` 尊重 `.gitignore`（本仓库有 3.3GB `rust/**/target`）且输出更紧凑。
- **外部命令先落盘**：`cmd > /tmp/x.log 2>&1` 后只 `rg -n "ERROR|error\[|FAILED" /tmp/x.log`，只带结论回对话。
- **不要 `read` 图片**：当前默认模型不支持图片，只会回占位提示；UI 验证用 `uitest dumpLayout` + `rg`（见 skill `harmony-device-run` §4）。
- **换任务即 `/new`**：单会话峰值上下文曾达 340k，续用旧会话会让每轮重发全部历史。

## 项目禁令（已定，勿擅改；理由见 [`docs/decisions.md`](./docs/decisions.md)）

- **引擎不降级**：走 `rust/legado-engine`（纯核心）+ `rust/legado-core`（NAPI 壳）+ `ohos-rs`，不要改回 ArkTS 直连 HTTP。
- **网络只在 Rust**：ArkTS 侧不发起书源请求（封面也由 Rust 代下，带 header/Cookie）。
- **禁用证书放行**：Rust 侧 `reqwest` + `rustls`，不得加 `danger_accept_invalid_certs` 之类的绕过。
- **状态管理固定 V2**：新代码用 `@ComponentV2` / `@Local` / `@Param`，**不要**用 `@State` / `@Prop`。
- **阅读排版固定横向分页**（Swiper + `measureTextSize`），不要改回纵向滚动。
- **视觉沿用白 + 红**（`#DA3838`，红系轻渐变），见 [`docs/plan.md`](./docs/plan.md) §2 Design Token。
- **v1 不做**：JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS（**例外**：`@js:` 的 L1 字符串模式仍解析）。

## 硬性约定（其余约定与坑见 [`docs/PITFALLS.md`](./docs/PITFALLS.md)、[`docs/development.md`](./docs/development.md)）

- **文档落位**：根目录**只允许** `AGENTS.md` / `README.md`（文档）与 `Makefile`（命令入口）；新文档一律进 `docs/` 对应子目录
  （UI 规范 → `specs/`、方案 → `research/`、bug → `bugfix/`、交接 → `handoff/HANDOFF-S<N>.md`、
  **已完结/纯历史 → `archive/`**），并同步更新引用它的链接。
- **文档目录自动生成**：大文档顶部的「行号目录」写在 `<!-- TOC:BEGIN/END -->` 之间，改完跑 `make docs-toc`，**勿手改行号**。
- **NAPI 契约单点**：签名与接口说明只写在 `rust/legado-core/src/lib.rs` 的 `///`（`make rust` 生成并拷 `index.d.ts`，勿手改）；
  `docs/engine.md` / `architecture.md` 只写语义，**不要**再粘贴签名列表。
- **动抽屉前先读 [`docs/specs/UI-SPEC.md`](./docs/specs/UI-SPEC.md)**：7 处调用点必须一起改；唯一实现
  `ui/common/BottomDrawer.ets`，禁止裸 `bindSheet` 与 `if (flag) { BottomDrawer(...) }` 条件挂载；
  `TabContent` 内 `mode: 'cover'`，`NavDestination` 页 `overlay`。
- **改完必走闭环**：`make run`（= 编译 → 安装 → `aa force-stop` → 启动）→ 观察（细节见 skill `harmony-device-run`）；
  动 Rust 先 `make test`（主机 `cargo test`，不占真机）。
- **通用 harmony skill 按需声明**：`.pi/settings.json` 只常驻 `harmonyos-build-doctor`（`harmony-device-run` 随仓库自动发现）；
  `harmony-next` / `harmonyos-project-audit` / `harmonyos-release-*` 需要时再临时加进该数组——每个 skill 的 description 每轮都付 token。
- 其余（ArkTS 严格模式与混淆、签名凭据、UDID、日志 tag、构建命令）见 [`docs/development.md`](./docs/development.md)。
