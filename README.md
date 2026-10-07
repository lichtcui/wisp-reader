# 源阅读（Source Reader）

HarmonyOS NEXT 原生阅读 App，兼容 [Legado](https://github.com/gedoor/legado) 书源格式。

- **引擎**：复用本地 Rust 书源引擎（`rust/legado-core`），经 [ohos-rs](https://github.com/ohos-rs/ohos-rs) 编译为
  `.so`，ArkTS 通过 NAPI 调用。网络请求（`reqwest` + rustls）也在 Rust 侧完成。
- **UI**：ArkTS + ArkUI 声明式，V2 状态管理，白 + 红视觉。
- **v1 范围**：搜索 → 详情 → 加入书架 → 阅读（横向分页翻页）→ 听书。
- **v1 不做**：JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS。

> 完整设计见 [`docs/plan.md`](./docs/plan.md)；开发/构建说明见 [`docs/development.md`](./docs/development.md)；
> 文档路由见 [`AGENTS.md`](./AGENTS.md)。

## 当前进度

M0–M5 已完成并真机验证；M6（规则调试器 + 缓存/备份）未开始。

| 里程碑 | 状态 |
|---|---|
| M0 引擎 PoC（编译 / parse / HTTPS / HTTP / 体积 / 冷启动） | ✅ |
| M1 骨架 + 设计规范 + 三 Tab | ✅ |
| M2 引擎接口（search/bookInfo/toc/content）+ 书源导入 | ✅ |
| M3 搜索聚合 + 详情 + 加入书架 | ✅ |
| M4 阅读页 + 目录 + 进度 | ✅ |
| M5 听书 + TTS + 后台播放 | ✅ |
| M6 规则调试器 + 缓存/备份 | ⏳ |

详见 [`docs/progress.md`](./docs/progress.md)。

## 快速开始

命令都收在根目录 `Makefile` 里（`make help` 看全部）：

```bash
make rust        # 交叉编译 .so 并拷进 entry/libs（首次约 10–15 分钟；非首次可跳过）
make run         # 编译 HAP → 安装 → force-stop → 启动（改完代码走这个）
make log         # 清日志 + 实时过滤本应用日志
make test        # 主机上跑引擎单测（cargo test，不碰真机）
```

底层原始命令与环境变量说明见 [`docs/development.md`](./docs/development.md)
（签名需 DevEco 自动签名）。

## 免责声明

本 App 不内置任何书籍正文内容；书源由用户自行导入，内容版权归各站点所有。仅供学习交流。