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
| `make hap` / `make hap-release` | 只编译（debug / release+混淆+签名） |
| `make rust` | 交叉编译 `.so` **并拷 `index.d.ts`** 进 `entry/` |
| `make test` | 主机跑引擎单测（`cargo test`，不碰真机） |
| `make log` | 清日志 + 实时过滤 `SourceReaderPoC` |
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

- 首次构建依赖树大，约 10–15 分钟；之后增量很快。
- `ohrs build` 会顺带生成 `dist/index.d.ts`（NAPI 类型声明，由 Rust 的 `///` doc comment 来）。
  **改接口说明改 Rust 的 `///`**，手工分步时记得一并拷贝：
  `cp rust/legado-core/dist/index.d.ts entry/src/main/cpp/types/liblegado_core/`。

## 构建 HAP（= `make hap` / `make hap-release`）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
  --mode module -p product=default -p buildMode=debug --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-signed.hap
```

## 签名

- 由 `build-profile.json5` 的 `signingConfigs` 提供；首次需在 **DevEco Studio → File → Project Structure →
  Signing Configs → 勾选 Automatically generate signature**（华为账号，为新 bundle 生成 profile，绑定设备 UDID）。
- profile 与 **bundleName + 设备 UDID** 绑定，不能用别的工程的签名。
- **报 `unable to obtain user group`**：是 DevEco 的 GRS 请求失败（账号已登录也可能发生）。处理：
  1. 重试；
  2. `File → Invalidate Caches / Restart`；
  3. 检查 `Settings → System Settings → HTTP Proxy`（本机系统代理在 `127.0.0.1:7897`）；
  4. 确认代理未拦 `*.dbankcloud.*` / `*.huawei.com`。
- **`build-profile.json5` 含凭据，勿提交**。初始化 git 后：`git update-index --skip-worktree build-profile.json5`。

## 安装 / 启动 / 日志（= `make run` / `make log` / `make devices`）

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC list targets                       # 当前设备 UDID：33Z0224424136564
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
$HDC shell hilog -r                     # 清日志
$HDC shell hilog -x -T SourceReaderPoC   # 按 tag 过滤；裸 hilog -x | grep 会刷屏（= make log）
```

**坑**：仅 `aa start` 不会重跑 `aboutToAppear`；要重跑页面逻辑必须先 `aa force-stop`。

## 调试要点

- 日志 tag：PoC 用 `SourceReaderPoC`（`hilog.info(DOMAIN, TAG, ...)`）。
- Rust 侧 `panic`/`unwrap` 会在设备上崩溃，尽量 `Result` 化。
- ArkTS 严格模式：不用 `any`；`getHostContext()` 返回 `Context | undefined` 需判空。
- release 已开混淆：新增 JSON 字段名等点语法属性名要加进 `entry/obfuscation-rules.txt` 的 `-keep-property-name`。

## Skill 来源

本仓库同时用两类 skill，来源不同：

| 类型 | 位置 | 加载方式 |
|---|---|---|
| **项目专属**（`harmony-device-run`：真机验证闭环） | 仓库内 `.pi/skills/harmony-device-run/` | `.pi/skills/` 自动发现；**随仓库 git 走**（`.gitignore` 里 `!/.pi/skills/**` 例外） |
| **通用 harmony**（`~/Documents/skills.harmony/` 里的 `harmonyos-build-doctor`、`harmony-next`、`harmonyos-project-audit`、`harmonyos-release-*`） | `~/Documents/skills.harmony/`（中央库，唯一真源） | 本仓库 `.pi/settings.json` 的 `skills` 数组按项目声明 |

为什么不全放全局 `~/.pi/agent/skills/`：那是**全局**目录，非 harmony 项目也会加载，
每个 skill 白付 name+description（约 50–100 tokens/会话）。

**只常驻 `harmonyos-build-doctor`**（高频：构建报错必查）。其余四个（`harmony-next` API/文档查询、
`harmonyos-project-audit`、`harmonyos-release-check`、`harmonyos-release-signing`）**用到时再临时加进
`.pi/settings.json` 的 `skills` 数组**，用完可以删——skill 只广告 name+description 也要每轮付 token，
而本项目实际把 6 个 skill 的 description（3.5KB/轮）当成常数成本。

常用场景的完整数组（整段拷回 `skills` 即可）：构建/发布只加 `harmonyos-build-doctor`（已是默认）、
`harmonyos-release-signing`；查 ArkTS/ArkUI/NDK 接口加 `harmony-next`；发布门禁加 `harmonyos-release-check`。

**skill 没加载时的排查顺序**：

1. `.pi/settings.json` 是否存在、路径是否写对（项目 settings 里的路径从 `.pi/` 解析，`~` 可用）；
2. **项目信任**是否已给（`.pi/` 下的配置与资源在信任后才加载，`pi -a` 可为单次放行，`/trust` 保存决定）；
3. 是否已 `/reload` 或新开会话；
4. `~/Documents/skills.harmony/` 是否存在（换机后需重新 `git clone`）。

## 目录/产物速查

| 项 | 路径 |
|---|---|
| 命令统一入口 | `Makefile`（`make help`）；文档目录生成器 `scripts/docs-toc.sh` |
| Rust 引擎核心（纯 Rust，可 `cargo test`） | `rust/legado-engine/` |
| Rust NAPI 包装（cdylib） | `rust/legado-core/` |
| 内置书源生成器 | `rust/legado-engine/examples/bundled_gen.rs` |
| native 产物 | `entry/libs/arm64-v8a/liblegado_core.so` |
| NAPI 类型声明（**生成物，勿手改**） | `entry/src/main/cpp/types/liblegado_core/index.d.ts` ← `rust/legado-core/src/lib.rs` 的 `///` |
| HAP 产物 | `entry/build/default/outputs/default/entry-default-signed.hap` |