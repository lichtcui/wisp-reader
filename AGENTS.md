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
| bug / 发布 / 调研 / 交接 | **待修清单先看 [`docs/bugfix/TASKS.md`](./docs/bugfix/TASKS.md)**（P0→P2，每项带证据与验证方式）；发布说明 [`RELEASE-NOTES.md`](./docs/bugfix/RELEASE-NOTES.md)、[`docs/research/`](./docs/research/)、[`docs/handoff/`](./docs/handoff/) |
| 已完结的历史（**默认不读**） | `docs/archive/`（含 105KB `SHELF-EDIT-PLAN.md`、61KB `ARCHIVE-S3-S8.md`、**已封存的端侧 TTS 路线** [`TTS-LOCAL-ONNX/`](./docs/archive/TTS-LOCAL-ONNX/README.md)） |

## 上下文卫生（省 token：本文件 + 全部历史每轮都要重发）

- **大文件只读片段**：`docs/plan.md` 与 `docs/archive/*`（50–105KB）顶部有行号目录（`make docs-toc` 维护），
  用 `read` 的 `offset`/`limit` 取段；**不要**整文件反复重读。
  `docs/bugfix/TASKS.md`(76KB)、`docs/progress.md`(21KB) 这类中文长文同理：**先 `rg -n` 定位再取段**
  （一次整读 76KB ≈ 2.3 万 tokens，且此后每轮都重发；实测吃掉一次会话的 17.6%）。
- **一轮多工具**：同一轮里并行发 2–4 个互相独立的调用（`rg` 定位 + `read` 取段 + 状态检查），别拆成多轮；
  每轮成本 ≈ 全量上下文（实测平均 73k），与那点输出大小几乎无关。**工具之间不要叙述**，过渡句并进同一轮。
- **大 `.ets` / `.rs` 先看文件索引**：`Reader.ets`(1.4k 行)、`TtsController.ets`(1.3k)、`SearchResult.ets`(1k)、
  `runtime.rs`(0.9k) 顶部有成员名索引（只有名字没有行号，不会漂）→ 按名字 `grep -n` 取段。
- **用内置工具而非 bash 同名牌**：`read`/`grep`/`find`/`ls` 尊重 `.gitignore`（本仓库有 3.3GB `rust/**/target`）且输出更紧凑。
- **外部命令先落盘**：`cmd > /tmp/x.log 2>&1` 后只 `rg -n "ERROR|error\[|FAILED" /tmp/x.log`，只带结论回对话。
  慢命令（`make probe/test/hap-release/rust`）用 `&` 后台跑再一次性取结果，别每轮探一次。
- **抓取/搜索先看状态**：404 或拿到 HTML 就别往下带；`web_search` 一家 provider 足够，取段用 `get_search_content` + `findText`，别把整页塞进上下文。
- **不要 `read` 图片**：当前默认模型不支持图片，只会回占位提示；UI 验证用 `uitest dumpLayout` + `rg`（见 skill `harmony-device-run` §4）。
- **换任务即 `/new`**：单会话峰值上下文曾达 340k，续用旧会话会让每轮重发全部历史。实测三个任务同会话时，
  第三个任务 93 次调用平均上下文 80k、独占全会话 token 的 84.6%；账本见
  [`docs/research/PI-SESSION-TOKEN-AUDIT.md`](./docs/research/PI-SESSION-TOKEN-AUDIT.md)。

## 项目禁令（已定，勿擅改；每条的理由与影响面见 [`docs/decisions.md`](./docs/decisions.md) 的 D 编号）

| 禁 | 出处 |
|---|---|
| 引擎降级（改回 ArkTS 直连 HTTP） | D1 |
| ArkTS 侧发书源请求（封面也由 Rust 代下，带 header/Cookie） | D2 / D6 |
| 证书放行（`danger_accept_invalid_certs` 之类绕过） | D2 |
| `@State` / `@Prop`（新代码一律 `@ComponentV2` + `@Local` / `@Param`） | D7 |
| 阅读排版改回纵向滚动 | D5 |
| 换配色（白 + 红 `#DA3838`，走 color.json 令牌） | D8 |
| v1 范围外（JS 运行时 / 登录源 / explore / 真分页 / 在线 TTS；`@js:` 的 L1 字符串模式除外。**换源自 v1.1 起已支持**，见 D16） | D10 / D11 / D16 |

## 硬性约定（其余约定与坑见 [`docs/PITFALLS.md`](./docs/PITFALLS.md)、[`docs/development.md`](./docs/development.md)）

- **文档落位**：根目录**只允许** `AGENTS.md` / `README.md`（文档）与 `Makefile`（命令入口）；新文档一律进 `docs/` 对应子目录
  （UI 规范 → `specs/`、方案 → `research/`、bug → `bugfix/`、交接 → `handoff/HANDOFF-S<N>.md`、
  **已完结/纯历史 → `archive/`**），并同步更新引用它的链接。大文档顶部目录写在 `<!-- TOC:BEGIN/END -->` 之间，
  改完跑 `make docs-toc`，**勿手改行号**。
- **NAPI 契约单点**：签名与接口说明只写在 `rust/legado-core/src/lib.rs` 的 `///`（`make rust` 生成并拷 `index.d.ts`，勿手改）；
  `docs/engine.md` / `architecture.md` 只写语义。
- **动抽屉前先读 [`docs/specs/UI-SPEC.md`](./docs/specs/UI-SPEC.md)**：7 处调用点必须一起改；唯一实现 `ui/common/BottomDrawer.ets`，
  禁止裸 `bindSheet` 与 `if (flag) { BottomDrawer(...) }` 条件挂载（`mode` / `overlay` 细节见 UI-SPEC）。
- **改完必走闭环**：`make run`（= 编译 → 安装 → `aa force-stop` → 启动）→ 观察（细节见 skill `harmony-device-run`）；
  动 Rust 先 `make test`（不占真机）、改引擎规则优先 `make probe`（不上设备）。
- **跨 NAPI / 落盘的 JSON 字段名必须进 `obfuscation-rules.txt`**：release 开了属性混淆，漏一个就是「debug 正常、release 读到 undefined」——
  三处同步（Rust struct / `engine/types.ets` / keep 列表），`make check` 会核对。详见 [`docs/engine.md`](./docs/engine.md) §JSON 契约。
- **skill 声明**：harmony skill 随仓库放在 `.agents/skills/`（Codex / pi 自动发现），`.pi/settings.json` 不再重复声明；
  `harmony-device-run` 由根目录 `.harmony-skill.env` 渲染，改命令后跑 `~/Documents/skills.harmony/setup-codex.sh --force .`——详见 [`docs/development.md`](./docs/development.md) §Skill 来源。
- 其余（ArkTS 严格模式、签名凭据、UDID、日志 tag、冲突处理）见 [`docs/development.md`](./docs/development.md)。
