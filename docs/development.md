# 开发 / 构建 / 调试

## 环境依赖（本机已装）

| 依赖 | 说明 |
|---|---|
| Rust | `1.98.1`（ohos-rs MSRV 1.88） |
| Rust targets | `rustup target add aarch64-unknown-linux-ohos armv7-unknown-linux-ohos x86_64-unknown-linux-ohos` |
| `ohrs` CLI | `cargo install ohrs --locked`（v1.5.0） |
| DevEco Studio | `/Applications/DevEco-Studio.app` |
| `OHOS_NDK_HOME` | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony`（**不要**指到 `.../native`） |
| `DEVECO_SDK_HOME` | `/Applications/DevEco-Studio.app/Contents/sdk` |

- `ohrs doctor` 可自检环境。
- **crates.io 本机不可达**：项目根 `.cargo/config.toml` 已指向 `rsproxy.cn`（勿删）。

## 首选：`make`（命令统一入口）

先试 `make help`（根目录 `Makefile` 已把环境变量、产物路径、设备命令都固定下来了）：

| 命令 | 作用 |
|---|---|
| `make run` | **改完代码走这个**：编译 debug HAP → 安装 → force-stop → 启动 |
| `make hap` / `make hap-release` | 只编译（debug / release+混淆）；两者都会先跑 `native-fresh` |
| `make app-release` | 构建唯一 Release APP；缺少独立 Release 身份时以 `PUBLICATION_BLOCKED` 阻断 |
| `make verify-app` / `make verify-profile` | 独立校验 Release APP 签名、digest、profile 类型 / bundle / 有效期 |
| `make rust` | 交叉编译 `.so` **并拷 `index.d.ts`** 进 `entry/` |
| `make native-fresh` | 校验 `.so` 与 `index.d.ts` 没有落后于 Rust 源码 |
| `make test` | 主机跑引擎单测（`cargo test`，不碰真机） |
| `make probe` | 主机直跑引擎，不上设备：`make probe ARGS='源.json search 关键词'` |
| `make log` | 清日志 + 抓本应用日志（按 bundle 名筛，一次性 dump） |
| `make log Q=关键词` | 同上，并在主机侧再筛一遍关键词 |
| `make run-release` | 同 `make run` 但装 release 包（验证混淆 / 备份等只在 release 现形的问题） |
| `make doctor` | 自检：`.so` / `index.d.ts` / HAP 是否落后于源码 + 设备是否连着 |
| `make check` | 自检文档与契约：行号目录是否过期 / md 失效链接 / JSON 字段是否都进 keep 列表 / hilog 格式串是否用了不支持的占位符 |
| `make devices` | 列出设备 UDID |
| `make docs-toc` | 重建大文档顶部的行号目录 |

下面各节保留**底层原始命令**，供排查或手工分步时对照（`make` 干的就是这些）。

## 构建 native（= `make rust`）

```bash
export OHOS_NDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony
cd rust/legado-core
ohrs build --arch arm64 --release       # 产物 dist/arm64-v8a/liblegado_core.so
cp dist/arm64-v8a/liblegado_core.so ../../entry/libs/arm64-v8a/
```

- 首次构建依赖树大，约 10–15 分钟；之后**改 1 个 `.rs` 约 4 分钟**——`lto = true`（fat LTO）会在每次改动后全量重链，
  这是引擎侧迭代的主要开销；调规则优先用 `make probe`（主机直跑，秒级），别为了试一行规则等 4 分钟。
- `ohrs build` 会顺带生成 `dist/index.d.ts`（NAPI 类型声明，由 Rust 的 `///` doc comment 来）。
  **改接口说明改 Rust 的 `///`**，手工分步时记得一并拷贝：
  `cp rust/legado-core/dist/index.d.ts entry/src/main/cpp/types/liblegado_core/`。
- `make hap` / `make hap-release` / `make app-release` 依赖 `make native-fresh`。若它报 `.so` 或声明落后，
  先跑 `make rust`；不要用旧 native 产物验证 ArkTS 改动。

## 构建 HAP（= `make hap` / `make hap-release`）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
  --mode module -p product=default -p buildMode=debug
# 产物：entry/build/default/outputs/default/entry-default-signed.hap
```

- **不要加 `--no-daemon`**：加上后 ArkTS 编译进程每次冷启，改 1 个 `.ets` 后重编 **13.1s → 3.5s**（2026-10-11 实测，
  无 `--incremental`/`--parallel` 的额外收益）。默认（常驻 daemon）才是快的那档。
- 需要一次性干净复现时用 `make hap NO_DAEMON=1`；换 SDK / 构建行为诡异时 `make daemon-stop`（`make daemon-status` 查看）。

## 签名

- 仓库内的 `build-profile.json5` 保持 `signingConfigs: []`，不放本地路径或口令。`hvigorfile.ts` 按
  `SOURCE_READER_SIGNING_MODE=debug|release`（默认 `debug`）从仓库外读取身份：

  ```text
  ~/.ohos/source-reader/signing.json   # chmod 600
  { "debug": { "type": "HarmonyOS", "material": { ... } }, "release": null }
  ```

- 旧版 `build-profile.json5` 内已有本机身份时，运行 `scripts/migrate-signing.sh --force`：它在仓库外写入
  `debug` 身份、保留 `release: null`，并把工作区的签名配置清空。不要提交迁移前的 profile。
- 首次生成 Debug 身份仍可走 **DevEco Studio → File → Project Structure → Signing Configs → Automatically generate signature**
  或项目已有流程；迁移后日常构建不依赖 DevEco 把凭据写回仓库。正式 Release 需单独申请 release 类型证书 / Profile，
  填入外部 JSON 的 `release` 字段，且不能与 Debug 的 alias / 证书 / profile 相同。
- profile 与 **bundleName + 设备 UDID** 绑定，不能用别的工程的签名。
- **报 `unable to obtain user group`**：是 DevEco 的 GRS 请求失败（账号已登录也可能发生）。处理：
  1. 重试；
  2. `File → Invalidate Caches / Restart`；
  3. 检查 `Settings → System Settings → HTTP Proxy`（本机系统代理在 `127.0.0.1:7897`）；
  4. 确认代理未拦 `*.dbankcloud.*` / `*.huawei.com`。
- **不要把证书、Profile、keystore、路径或口令写回仓库**；`release: null` 时 `make app-release` 必须失败，这是发布门禁，
  不是构建故障。

## Release 产物（`make app-release`）

```bash
make app-release     # release-preflight → assembleApp → 确认唯一 *-signed.app
make verify-app      # hap-sign-tool verify-app + digest + release profile + bundle
make verify-profile  # 单独复核 profile 类型、bundle、有效期与 Debug 隔离
```

- 产物固定为 `build/outputs/default/source-reader-default-signed.app`；`verify-app` 最后输出 SHA-256。
- `verify-app` / `verify-profile` 与 `app-release` 都会先跑 `scripts/release-preflight.sh`，没有独立 Release 身份时统一输出
  `PUBLICATION_BLOCKED`。

## 安装 / 启动 / 日志（= `make run` / `make log` / `make devices`）

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC list targets                       # 当前设备 UDID：33Z0224424136564
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
$HDC shell hilog -r                     # 清日志
$HDC shell hilog -x | grep com.lichtcui.sourcereader   # 按 bundle 名筛（= make log）；裸 hilog -x | grep 会刷屏
```

**坑**：仅 `aa start` 不会重跑 `aboutToAppear`；要重跑页面逻辑必须先 `aa force-stop`。

## 调试要点

- 日志 tag：**每个文件自己一个**（`SourceReaderTts` / `SourceReaderReader` / `SourceReaderCache` / `SourceReaderCover` / `RuleDebugger` 用 `SourceReaderPoC`）⇒
  **不要用 `-T` 猜 tag**（会拿到空结果、看着像「没触发」），按 bundle 名筛（`make log`）。
- Rust 侧 `panic`/`unwrap` 会在设备上崩溃，尽量 `Result` 化。
- ArkTS 严格模式：不用 `any`；`getHostContext()` 返回 `Context | undefined` 需判空。
- release 已开混淆：新增 JSON 字段名等点语法属性名要加进 `entry/obfuscation-rules.txt` 的 `-keep-property-name`。
  判定范围与缺项由 `make check`（`scripts/check-keep-props.sh`）机械核对，别靠眼睛看 159 行列表。

## Skill 来源

本仓库的 skill 全部随仓库走，放在 `.agents/skills/`（Codex 与 pi 都会自动发现）：

| 类型 | 位置 | 维护方式 |
|---|---|---|
| **项目专属**（`harmony-device-run`：真机验证闭环） | `.agents/skills/harmony-device-run/`；模板在 `~/Documents/skills.harmony/harmony-device-run/`，本仓库命令在 `.harmony-skill.env` | 脚本按 `bundleName` + `.harmony-skill.env` 渲染；已存在则 `KEEP`，`--force` 才覆盖（旧文件备份到 `$TMPDIR`） |
| **通用 harmony**（`harmonyos-build-doctor`、`harmony-next`、`harmonyos-project-audit`、`harmonyos-release-*`） | `.agents/skills/<name>` → 软链到 `~/Documents/skills.harmony/<name>` | 中央库仍为唯一真源；更新后项目立即生效 |

```bash
~/Documents/skills.harmony/setup-codex.sh .          # 注入 / 校验
~/Documents/skills.harmony/setup-codex.sh --force .  # 重渲染 harmony-device-run
~/Documents/skills.harmony/setup-codex.sh --remove . # 移除
```

为什么不全放全局 `~/.codex/skills/` 或 `~/.pi/agent/skills/`：那两个是**全局**目录，非 harmony 项目也会加载，
每个 skill 白付 name+description（约 50–100 tokens/会话）。入口是脚本参数 `SKILLS="..."`，
例如只在构建排障时注入 `SKILLS=harmonyos-build-doctor setup-codex.sh .`。

`harmony-device-run` 属项目专属：bundle 名从 `AppScope/app.json5` 读取，
构建 / 安装 / 启动 / 日志命令来自根目录 `.harmony-skill.env`（随仓库提交）。
改命令后跑 `setup-codex.sh --force .` 重新渲染；`.agents/skills/` 本身也随仓库提交，
新克隆无需注入即可被 Codex / pi 发现（软链目标需本机存在中央库）。

**skill 没加载时的排查顺序**：

1. `.agents/skills/` 是否存在、软链是否断（`ls -la .agents/skills/`）；
2. 是否已 `/reload`（pi）或新开会话（Codex skill 列表是启动快照）；
3. `~/Documents/skills.harmony/` 是否存在（换机后需重新 `git clone` 中央库）。

## 目录/产物速查

| 项 | 路径 |
|---|---|
| 命令统一入口 | `Makefile`（`make help`）；`scripts/`：`docs-toc.sh`（行号目录，`--check` 只校验）· `doctor.sh`（产物/设备自检）· `check-keep-props.sh` · `check-docs-links.sh` · `check-hilog-format.sh`（拦 `%{public}f` 这类 hilog 不认的占位符） |
| Rust 引擎核心（纯 Rust，可 `cargo test`） | `rust/legado-engine/` |
| Rust NAPI 包装（cdylib） | `rust/legado-core/` |
| 内置书源生成器 | `rust/legado-engine/examples/bundled_gen.rs` |
| native 产物 | `entry/libs/arm64-v8a/liblegado_core.so` |
| NAPI 类型声明（**生成物，勿手改**） | `entry/src/main/cpp/types/liblegado_core/index.d.ts` ← `rust/legado-core/src/lib.rs` 的 `///` |
| HAP 产物 | `entry/build/default/outputs/default/entry-default-signed.hap` |
