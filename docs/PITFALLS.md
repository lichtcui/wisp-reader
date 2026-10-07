# 踩坑速查（按症状查）

> 用法：**先在这里搜症状**，命中就按结论做，别重新试错。
> 本表只给「症状 → 一句话结论 + 指针」，细节留在指针文档里，避免双份维护。
> 新增坑请追加，并写清复现条件。

| 症状 | 结论 | 详情 |
|---|---|---|
| 听书启动即失败，报 **9800005** | `module.json5` 缺 `backgroundModes: ["audioPlayback"]` | `docs/progress.md` §M5 |
| 锁屏无媒体卡 / 媒体键无反应 / AVSession 不是 top session | **系统 TTS「直连播报」路线不可行**（系统 TTS 自持音频焦点）。必须让 App 自己播 PCM（`STREAM_USAGE_AUDIOBOOK`）才能成为 top session | `docs/progress.md` §M5 |
| 抽屉错乱：tab 栏被盖住 / 面板从中间冒出 / 关不干净 | tab 页（`TabContent`）用 `mode: 'cover'`，`NavDestination` 用 `overlay`；唯一实现 `ui/common/BottomDrawer.ets`，**禁止**裸 `bindSheet` 与条件挂载 | `docs/specs/UI-SPEC.md` |
| 改了 ArkTS，设备上行为没变 | ① 只编译没安装 ② 没 `aa force-stop`（`aboutToAppear` 不重跑） | `docs/development.md` |
| release 包 JSON 字段读出来是 `undefined` | `entry/obfuscation-rules.txt` 漏了对应的 `-keep-property-name` | `docs/development.md` §调试要点 |
| 签名报 `unable to obtain user group` | DevEco 的 GRS 请求失败（非账号问题）：重试 → `File > Invalidate Caches / Restart` → 查 HTTP Proxy（本机 `127.0.0.1:7897`） | `docs/development.md` |
| `ohrs build` 找不到 NDK / 报路径错 | `OHOS_NDK_HOME` **不要**指到 `.../openharmony/native`（`ohrs` 会自己再拼 `native/`） | `docs/development.md` |
| `cargo` 拉不到 crates.io | 项目根 `.cargo/config.toml` 指向 `rsproxy.cn`，**勿删** | `docs/development.md` |
| Rust 侧规则改动后不确定有没有回归 | 先在主机跑 `cd rust/legado-engine && cargo test`（50 项，含 mock 端到端），再上真机 | `docs/engine.md` |
| `hilog -x` 刷屏找不到自己的日志 | 用 `hdc shell hilog -x -T <tag>` + 行数上限；tag 约定 `SourceReaderPoC`（先 `hilog -r` 清） | `docs/development.md` |
| 编辑器/构建报 ArkTS 严格模式错误 | 不用 `any`；`getHostContext()` 返回 `Context \| undefined` 需判空 | `docs/development.md` |
| 页面跳转用了 `@ohos.router` 报废弃 | 统一 `Navigation` + `NavPathStack`，路由常量见 `common/Const.ets` 的 `ROUTE_*` | `docs/architecture.md` |
