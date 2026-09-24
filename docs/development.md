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

## 构建 native

```bash
export OHOS_NDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony
cd rust/legado-core
ohrs build --arch arm64 --release       # 产物 dist/arm64-v8a/liblegado_core.so
cp dist/arm64-v8a/liblegado_core.so ../../entry/libs/arm64-v8a/
```

- 首次构建依赖树大，约 10–15 分钟；之后增量很快。
- `ohrs build` 会顺带生成 `dist/index.d.ts`（NAPI 类型声明）。

## 构建 HAP

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

## 安装 / 启动 / 日志

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC list targets                       # 当前设备 UDID：33Z0224424136564
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
$HDC shell hilog -r                     # 清日志
$HDC shell hilog -x | grep SourceReaderPoC
```

**坑**：仅 `aa start` 不会重跑 `aboutToAppear`；要重跑页面逻辑必须先 `aa force-stop`。

## 调试要点

- 日志 tag：PoC 用 `SourceReaderPoC`（`hilog.info(DOMAIN, TAG, ...)`）。
- Rust 侧 `panic`/`unwrap` 会在设备上崩溃，尽量 `Result` 化。
- ArkTS 严格模式：不用 `any`；`getHostContext()` 返回 `Context | undefined` 需判空。
- release 已开混淆：新增 JSON 字段名等点语法属性名要加进 `entry/obfuscation-rules.txt` 的 `-keep-property-name`。

## 目录/产物速查

| 项 | 路径 |
|---|---|
| Rust 引擎核心（纯 Rust，可 `cargo test`） | `rust/legado-engine/` |
| Rust NAPI 包装（cdylib） | `rust/legado-core/` |
| 内置书源生成器 | `rust/legado-engine/examples/bundled_gen.rs` |
| native 产物 | `entry/libs/arm64-v8a/liblegado_core.so` |
| NAPI 类型声明 | `entry/src/main/cpp/types/liblegado_core/{index.d.ts, oh-package.json5}` |
| HAP 产物 | `entry/build/default/outputs/default/entry-default-signed.hap` |