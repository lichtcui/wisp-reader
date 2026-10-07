---
name: harmony-device-run
description: 改完本仓库代码后在真机验证的完整闭环流程（判定改动范围 → 编译 → 安装 → force-stop → 启动 → 抓日志），含 ArkTS/Rust 改动范围判定、hdc/uitest 无 GUI 验证、构建与日志的输出卫生。用于本项目任何代码改动后的验证，或用户反馈"改了没生效 / 设备上跑的是旧版"时。
---

# 真机验证闭环

**两条铁律**
1. **只编译不安装 = 设备上跑的是旧版。**
2. **不 `aa force-stop` = `aboutToAppear` 不重跑。**

**拿不准先跑 `make doctor`**：它比对 `.so` / `index.d.ts` / HAP 与源码的 mtime 并报设备连通（回答“改了没生效”的第三类成因）。

## 1. 判定改动范围

| 改了什么 | 要重建 native（步骤①）吗 | 后续 |
|---|---|---|
| 只有 `entry/src/main/ets/**`（ArkTS / ArkUI） | 否 | 直接 ②③ |
| `rust/**` 或 `entry/src/main/cpp/types/**` | **是** | ① → ②③ |
| 只改 `entry/src/main/resources/**`、`module.json5` | 否 | 直接 ②③ |

改 Rust 后额外两件事：
1. 先在主机跑测试：`make test`（= `cd rust/legado-engine && cargo test`，含 mock 端到端）——过了再上设备；
   只改规则 DSL / URL 模板 / 门禁时优先 `make probe ARGS='源.json search 关键词'`（主机直跑，秒级，不用装 HAP）；
2. 重新生成 `.so` 与 `index.d.ts`：`make rust`（会一次性拷进 `entry/libs/...` 与 `entry/src/main/cpp/types/liblegado_core/`）。

## 2. 执行

**优先用 `make`（根目录 `Makefile`，环境变量/路径已固定）**：

| 场景 | 命令 |
|---|---|
| 只改 ArkTS | `make run` |
| 改了 Rust / NAPI 类型 | `make test && make rust && make run` |
| 只调引擎规则（不上设备） | `make probe ARGS='entry/src/main/resources/rawfile/bundled-sources.json detect 关键词'` |
| 怀疑设备上是旧版 | `make doctor` |
| 混淆相关 / 备份往返 | `make run-release`（release 包才现形的 bug 只在它上面能看到） |
| 看日志 | `make log`（已带 `hilog -r` + `-T SourceReaderPoC`；可加 `Q=关键词`） |
| 看设备 | `make devices` |

需要手工分步时，`make -n <target>` 可打印它到底执行了什么；原始命令与环境变量
（`OHOS_NDK_HOME` / `DEVECO_SDK_HOME` / `PATH` / hdc 路径）以 [`Makefile`](../../../Makefile) 与
[`docs/development.md`](../../../docs/development.md) 为准，**不要自创路径**。

- `OHOS_NDK_HOME` **不要**指到 `.../openharmony/native`（`ohrs` 会自己再拼 `native/`）。
- 本机 `crates.io` 不可达：项目根 `.cargo/config.toml` 指向 `rsproxy.cn`，**勿删**。

## 3. 输出卫生（避免刷爆上下文）

- 构建：`make hap > /tmp/build.log 2>&1`，然后 `rg -n "ERROR|error\[|error:|FAILED" /tmp/build.log`。
  **不要**把完整构建日志贴回来。
- 日志：先 `hdc shell hilog -r` 清，再 `hdc shell hilog -x -T SourceReaderPoC | tail -n 200`。
  不要裸 `hilog -x | grep`（会刷屏）。
- 中间产物留在 `/tmp`，只把**结论**带回对话。

## 4. 无 DevEco GUI 时的 UI 验证

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC shell uitest dumpLayout -p /data/local/tmp/l.json -a
$HDC file recv /data/local/tmp/l.json /tmp/l.json      # 再用 rg 提取需要的 node，别整份贴回
$HDC shell "uitest uiInput click <x> <y>"              # bounds 是物理像素（本机宽 1260）
$HDC shell "uitest uiInput inputText <x> <y> <text>"
```

## 5. 汇报格式

`改动文件 → 真机现象（截图 / 关键日志 ≤3 行）→ 结论 → 未验证项`。
不复述命令、不贴完整日志、不贴整份 dumpLayout。

## 相关

- 通用 harmony skill（API/离线文档查询 `harmony-next`、构建诊断 `harmonyos-build-doctor`、
  项目基线审计 `harmonyos-project-audit`、发布签名与门禁 `harmonyos-release-*`）：
  真源在 `~/Documents/skills.harmony/`；**默认只声明 `harmonyos-build-doctor`**（省 token），
  其余三个用到时临时加进本仓库 `.pi/settings.json` 的 `skills` 数组（详见 `docs/development.md` § Skill 来源）。
  若未加载，先查该文件与「项目信任」（详见 `docs/development.md` § Skill 来源）。
- 症状对不上先查：[`docs/PITFALLS.md`](../../../docs/PITFALLS.md)
- 环境 / 构建 / 签名细节：[`docs/development.md`](../../../docs/development.md)
