# AGENTS.md

本仓库是 **HarmonyOS NEXT 原生阅读 App**（ArkTS + ArkUI），兼容 Legado 书源格式。
书源引擎复用本地 Rust 项目，经 `ohos-rs` 编译为 `.so`，由 ArkTS 通过 NAPI 调用。

> **接手前先读**：本文件 → [`docs/progress.md`](./docs/progress.md)（进度/下一步）→ [`docs/plan.md`](./docs/plan.md)（完整设计，唯一权威方案）。
> 专题文档：[`docs/architecture.md`](./docs/architecture.md)、[`docs/engine.md`](./docs/engine.md)、[`docs/development.md`](./docs/development.md)。

---

## 1. 现状（M0–M5 完成，M6 待开始）

| 里程碑 | 状态 |
|---|---|
| M0 引擎 PoC | ✅ 真机（交叉编译/https/明文 http/体积/冷启动） |
| M1 骨架 + Token + 路由 + 三 Tab | ✅ 真机 |
| M2 引擎 NAPI + 门禁 + 书源管理 | ✅ 真机（detect 8/13 可用；URL 导入成功 1/排除 2） |
| M3 搜索聚合 + 详情 + 书架持久化 | ✅ 真机（加入书架重启仍在） |
| **M4 阅读页** | ✅ 真机验证（目录/跳转/字号/进度重启恢复；修 bindSheet 错乱 + 正文实体/脚本清洗；**收尾项已补**：目录正倒序/定位/卷、paragraphIndex、正文缓存+预取、更多→详情、返回刷新书架） |
| **M5 听书** | ✅ 真机验证（系统 TTS PCM → `AudioRenderer` → AVSession top session；锁屏媒体卡 + 媒体键可控；切后台不断；定时关闭；段落高亮/跟随 + 进度回写） |
| M6 调试器 | ⏳ 未开始 |

**M5 状态**：全部完成并在真机验证。
- 关键文件：`model/TtsController.ets`（`@ObservedV2` 单例：TTS 引擎 + PCM 队列 + `AudioRenderer` +
  `AVSession` + `backgroundTaskManager` + 定时/倍速/音色/进度）、`pages/Listening.ets`（全屏听书页）、
  `pages/ListeningSettings.ets`、`common/ChapterUtil.ets`、`model/BookContent.ets`。
- 集成：`pages/Reader.ets` 底栏「听书」入口 + 段落高亮/跟随；`pages/Shelf.ets` 听书 FAB；路由 `ROUTE_LISTENING` /
  `ROUTE_LISTENING_SETTINGS`；`module.json5` 增 `backgroundModes: ["audioPlayback"]`（**缺它会报 9800005**）。
- 关键点：**TTS「直连播报」路线不可行**（AVSession 非 top session、锁屏无控件，因系统 TTS 自持音频焦点）；
  必须让 App 自己播 PCM（`STREAM_USAGE_AUDIOBOOK`）才能成为 top session。
- 详细进度与验证结果：见 [`docs/progress.md`](./docs/progress.md) §「M5 结果」。

> **端侧自建 TTS 调研（未立项）**：想用本地 GPT-SoVITS 音色替代系统 TTS 的尽调与原型计划见
> [`docs/research/TTS-PLAN.md`](./docs/research/TTS-PLAN.md)。它与上面 M5 的**系统 TTS 是并行增量**，**未改动 M5 任何代码**；
> 当前状态为「调查完成、原型未开始」，下一步是 TTS-PLAN §9 的 P0。

## 2. 关键决策（已定，勿擅改）

| 项 | 决策 |
|---|---|
| 引擎 | 复用 Rust：`rust/legado-engine`（纯核心）+ `rust/legado-core`（NAPI 壳）+ `ohos-rs`；**不降级** |
| 网络 | **Rust 持有 HTTP**（`reqwest` + rustls）；每源独立 `Client`（Cookie 隔离）+ 限速；**禁用证书放行** |
| 书源持久化 | v1 用 `preferences` JSON（`SourceRepository`）；书籍/进度用 `relationalStore`（`ShelfRepository`，表 `books`/`progress`） |
| 搜索调度 | ArkTS 滑动窗口（并发 8）+ **书源置信度**排序（`server_error`/`timeout`/`network_error`/`blocked` 扣分、成功回分，持久化到 `confidence` 字段） |
| v1 不做 | JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS |
| JS 例外 | `@js:` 的 **L1 字符串模式**仍解析（非 L1 才排除） |
| 阅读排版 | v1 **横向分页翻页**（Swiper + `measureTextSize` 精确分页，跨章连续滑动） |
| 封面 | 由 Rust 代下（带 header/Cookie），落盘后 ArkTS 加载 |
| 状态管理 | **V2**（`@ComponentV2` / `@Local` / `@Param`） |
| 视觉 | 白 + 红（`#DA3838`，红系轻渐变）；参考 `~/Documents/playground/harmony-pokerouge` |
| bundle | `com.lichtcui.sourcereader` |
| API | `compatibleSdkVersion 5.0.0(12)` / `targetSdkVersion 6.1.1(24)` |

## 3. 环境（本机已就绪）

- Rust `1.98.1`（ohos-rs MSRV 1.88）；已装 target：`aarch64/armv7/x86_64-unknown-linux-ohos`。
- `ohrs` CLI（`cargo install ohrs --locked`，v1.5.0）。
- **`OHOS_NDK_HOME`**：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony`
  （注意：`ohrs` 会自动再拼 `native/`，**不要**指到 `.../openharmony/native`）。
- DevEco Studio：`/Applications/DevEco-Studio.app`。
- **crates.io 在本机不可达**，已在项目内加 `.cargo/config.toml` 指向 `rsproxy.cn` 镜像（勿删）。

## 4. 构建 / 安装 / 调试

```bash
# ① 构建 native（产物：rust/legado-core/dist/arm64-v8a/liblegado_core.so）
export OHOS_NDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony
cd rust/legado-core && ohrs build --arch arm64 --release
cp dist/arm64-v8a/liblegado_core.so ../../entry/libs/arm64-v8a/

# ② 构建 HAP（签名由 build-profile.json5 的 signingConfigs 提供）
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

# ③ 安装 / 启动 / 抓日志
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
$HDC shell hilog -x | grep SourceReaderPoC
```

- 改完代码必须走完「**编译 → 安装 → 重启 → 观察**」闭环；只编译不安装，设备上跑的是旧版。
- 重跑页面逻辑要先 `aa force-stop`（否则 `aboutToAppear` 不重跑）。
- **只改了 ArkTS**：跳过 ①，直接 ②③。
- **改了 Rust**：走 ①，并用生成的 `dist/index.d.ts` 更新 `entry/src/main/cpp/types/liblegado_core/index.d.ts`。
- 引擎主机自测（改 Rust 后建议先跑）：
  `cd rust/legado-engine && cargo test`（50 项，含 mock 端到端）。
- 重新生成内置书源：
  `cd rust/legado-engine && cargo run --example bundled_gen -- <filtered.json> ../../entry/src/main/resources/rawfile/bundled-sources.json`。
- **UI 自动化验证**（无 DevEco GUI 时）：
  `$HDC shell uitest dumpLayout -p /data/local/tmp/l.json -a && $HDC file recv ...`；
  点击 `$HDC shell "uitest uiInput click <x> <y>"`；输入 `inputText <x> <y> <text>`。
  dump 的 bounds 是 **物理像素**（本机 1260 宽）。

## 5. 目录结构

```
AGENTS.md / README.md        根目录只放这两个文档（其余文档一律进 docs/，见 §7）
docs/
  plan.md                   完整设计方案（权威）
  progress.md               进度/下一步
  architecture.md / engine.md / development.md
  specs/                    UI 规范：UI-SPEC.md（**底部抽屉统一规范，改动抽屉前必读**）
  research/                 TTS-PLAN.md（端侧自建 TTS 调研）
  bugfix/                   TASKS / RELEASE-NOTES（bug 修复生命周期）
  handoff/                  HANDOFF-S9.md + ARCHIVE-S3-S8.md（阶段性交接记录）
build-profile.json5         含 signingConfigs（**含凭据，勿提交**，见 §7）
hvigorfile.ts / oh-package.json5 / hvigor/
.cargo/config.toml          cargo 镜像（rsproxy）
AppScope/app.json5 + resources/
entry/
  build-profile.json5 / hvigorfile.ts / oh-package.json5 / obfuscation-rules.txt
  libs/arm64-v8a/liblegado_core.so         native 产物
  src/main/module.json5                    （权限：INTERNET / KEEP_BACKGROUND_RUNNING）
  src/main/ets/entryability/EntryAbility.ets
  src/main/ets/pages/       Index / Shelf / Search / SearchResult / BookDetail / Reader / BookSourceManage / Settings
  src/main/ets/engine/      IBookEngine.ets（端口）+ BookEngineNapi.ets + types.ets
  src/main/ets/model/       SourceRepository（preferences）+ ShelfRepository（relationalStore）
  src/main/ets/components/  EmptyView / ListCells / BookCover
  src/main/ets/common/      Const / Format / Prefs / Theme / ChapterDataSource
  src/main/cpp/types/liblegado_core/{index.d.ts, oh-package.json5}   NAPI 类型声明
  src/main/resources/{base,dark,zh_CN,en_US}/...
  src/main/resources/rawfile/bundled-sources.json                    v1 兼容内置源（13 个）
rust/legado-engine/          Rust 引擎核心（纯 Rust，无 NAPI，可主机 cargo test；见 docs/engine.md）
  src/{types,status,url_fixer,search_url,http_client,gate,runtime}.rs + rule_dsl/
  examples/bundled_gen.rs    生成 bundled-sources.json
rust/legado-core/            薄 NAPI 层（cdylib，依赖 legado-engine）
  src/lib.rs                 #[napi] 导出（JSON 进出）
```

## 6. NAPI 接口（M2）

```ts
import {
  parse, parseWithDiagnostics, fetchText,
  gateSources, search, bookInfo, toc, content, detect, downloadCover
} from 'liblegado_core.so';
```

- 结构化数据以 **JSON 字符串** 进出：`gateSources(sourcesJson)`、`search(sourcesJson, keyword, optsJson)`、
  `bookInfo/toc/content/detect/downloadCover` 返回 Promise<string>（JSON）。
- 失败以 NAPI reject 返回 `reason` key（如 `network_error`），ArkTS 侧映射为中文文案。

新增导出：在 `rust/legado-core/src/lib.rs` 加 `#[napi]` 函数（业务逻辑放 `legado-engine`）→
重新 `ohrs build` → 用生成的 `dist/index.d.ts` 更新 `entry/src/main/cpp/types/liblegado_core/index.d.ts`。

> 新增 JSON 字段名（点语法访问）要同步加进 `entry/obfuscation-rules.txt` 的 `-keep-property-name`。

## 7. 约定 / 坑

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
- **ArkTS 严格模式**：不用 `any`；JSON 解析字段名等点语法属性要在 `entry/obfuscation-rules.txt` 的
  `-keep-property-name` 保留（release 已开混淆）。
- **签名凭据**：`build-profile.json5` 含明文/加密凭据，**不要提交**。初始化 git 后建议：
  `git update-index --skip-worktree build-profile.json5`（仓库保存 `signingConfigs: []` 的干净版）。
- **DevEco 签名报 `unable to obtain user group`**：是 DevEco 的 GRS 请求失败（非账号问题）。
  处理：重试 → `File > Invalidate Caches / Restart` → 检查 HTTP Proxy（系统有代理在 `127.0.0.1:7897`）。
- 设备当前 UDID：`33Z0224424136564`。
- 调试日志 tag：`SourceReaderPoC`（PoC）；后续按页面各自定义。

## 8. 参考项目

- 引擎来源：`~/Documents/playground/legado-source-filter`（Rust，含完整规则引擎/链路校验）。
- 视觉参考：`~/Documents/playground/harmony-pokerouge`（HarmonyOS，白+红）。
