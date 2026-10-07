# 踩坑速查（按症状查）

> 用法：**先在这里搜症状**，命中就按结论做，别重新试错。
> 本表只给「症状 → 一句话结论 + 指针」，细节留在指针文档里，避免双份维护。
> 新增坑请追加，并写清复现条件。

| 症状 | 结论 | 详情 |
|---|---|---|
| 听书启动即失败，报 **9800005** | `module.json5` 缺 `backgroundModes: ["audioPlayback"]` | `docs/progress.md` §M5 |
| 锁屏无媒体卡 / 媒体键无反应 / AVSession 不是 top session | **系统 TTS「直连播报」路线不可行**（系统 TTS 自持音频焦点）。必须让 App 自己播 PCM（`STREAM_USAGE_AUDIOBOOK`）才能成为 top session | `docs/progress.md` §M5 |
| 抽屉错乱：tab 栏被盖住 / 面板从中间冒出 / 关不干净 | tab 页（`TabContent`）用 `mode: 'cover'`，`NavDestination` 用 `overlay`；唯一实现 `ui/common/BottomDrawer.ets`，**禁止**裸 `bindSheet` 与条件挂载 | `docs/specs/UI-SPEC.md` |
| 改了 ArkTS，设备上行为没变 | ① 只编译没安装 ② 没 `aa force-stop`（`aboutToAppear` 不重跑）→ 统一用 `make run` | `docs/development.md` |
| `make devices` / `hdc list targets` 返回 `[Empty]` | 未连上（插线、开 USB 调试、信任本机）；**跑测试中突然变空**则是掉线/U 口抖动 → `hdc kill -r` 后自动重连（重连前所有 `uitest` 命令只会报 `need connect-key`）。无设备时改完 ArkTS 至少跑 `make hap` 确认能编译 | skill `harmony-device-run` |
| Makefile 里拿到的 hdc/NDK 路径不对 | **变量不要用 `?=`**：本机环境已有 `NDK_HOME`/`SDK` 等同名变量，`?=` 会当成“已定义”而不赋值；用 `:=` | 根目录 `Makefile` 顶部注释 |
| `index.d.ts` 的接口说明/参数与引擎实际行为不一致 | 那份是**产物**：真源是 `rust/legado-core/src/lib.rs` 的 `///` doc comment，改完 `make rust` 会拷过来；**勿手改** `entry/.../index.d.ts` | `docs/engine.md` |
| 大文档顶部目录的行号指到了错地方 | 目录由 `make docs-toc` 生成，**勿手改行号**（只改 `<!-- TOC:BEGIN/END -->` 之间的东西会丢） | `AGENTS.md` §硬性约定 |
| release 包 JSON 字段读出来是 `undefined`（debug 正常） | `entry/obfuscation-rules.txt` 漏了对应的 `-keep-property-name`；不要靠眼睛看列表，跑 `make check` 会列出漏掉的字段名 | `docs/engine.md` §JSON 契约 |
| 不确定设备上跑的是不是刚改的代码 | 先 `make doctor`：比对 `.so` / `index.d.ts` / HAP 与源码的 mtime + 设备是否连着 | `scripts/doctor.sh` |
| 改引擎规则想秒级验证，不想上真机 | `make probe ARGS='源.json search 关键词'`（主机直跑引擎，秒级）；`detect` 走完搜索→详情→目录→正文 | `docs/engine.md` §主机侧调试 |
| 签名报 `unable to obtain user group` | DevEco 的 GRS 请求失败（非账号问题）：重试 → `File > Invalidate Caches / Restart` → 查 HTTP Proxy（本机 `127.0.0.1:7897`） | `docs/development.md` |
| `ohrs build` 找不到 NDK / 报路径错 | `OHOS_NDK_HOME` **不要**指到 `.../openharmony/native`（`ohrs` 会自己再拼 `native/`） | `docs/development.md` |
| `cargo` 拉不到 crates.io | 项目根 `.cargo/config.toml` 指向 `rsproxy.cn`，**勿删** | `docs/development.md` |
| Rust 侧规则改动后不确定有没有回归 | 先在主机跑 `make test`（`cargo test`，54 项含 mock 端到端），再上真机 | `docs/engine.md` |
| `hilog -x` 刷屏找不到自己的日志 | 用 `hdc shell hilog -x -T <tag>` + 行数上限；tag 约定 `SourceReaderPoC`（先 `hilog -r` 清） | `docs/development.md` |
| **release 包里死活看不到应用自己的 hilog**（`hilog -T SourceReaderTts` 恒为空） | 第三方应用在 release 包下日志被系统过滤（domain `0x0000` 不落 buffer）——**不是没跑/没生效**。看日志用 `make run`（debug）；release 冒烟改用系统侧证据：`hidumper -s AVSessionService -a '-show_session_info'`、`AudioLogUtils` 音频帧日志、`uitest dumpLayout` | `docs/bugfix/RELEASE-NOTES.md` §9 |
| 导入备份后书架/进度计数**只增不减**，与「全量覆盖」文案不符 | 导入必须**整体替换**：`books` / `progress` 先清表再写（`replaceShelf`），且必须 `lastWriteAt.clear()`——那个单调守卫是**会话级**的，不清会静默丢弃备份里 `updatedAt` 更旧的进度（表现为「导入了但进度没变」） | `docs/bugfix/TASKS.md` §T-DATA-7 |
| 想给 `progress` 表做「孤儿行」GC（`book_id` 不在 `books` 里） | **不要做**：详情页「立即阅读」不要求已上架也能写进度（`BookDetail.ets:233`），孤儿行有合法来源，全局 GC 会删掉用户真实阅读位置 | `docs/bugfix/TASKS.md` §T-DATA-7 |
| 无 GUI 下点不动 UI：`TextInput` 提交不了 / 长按不进编辑态 | ① `uitest uiInput inputText <x> <y> <text>` 可注入文本，但 `onSubmit` 不会自己触发 → 再发 `uitest uiInput keyEvent 2054`（Enter）；② 长按命令是 **`longClick`**（不是 `longPress`）；③ 文件选择器（保存/打开）用 `uitest uiInput click` 点右上/右下确认钮 + 目录行逐层进入 | skill `harmony-device-run` §4 |
| 编辑器/构建报 ArkTS 严格模式错误 | 不用 `any`；`getHostContext()` 返回 `Context \| undefined` 需判空 | `docs/development.md` |
| 页面跳转用了 `@ohos.router` 报废弃 | 统一 `Navigation` + `NavPathStack`，路由常量见 `common/Const.ets` 的 `ROUTE_*` | `docs/architecture.md` |
