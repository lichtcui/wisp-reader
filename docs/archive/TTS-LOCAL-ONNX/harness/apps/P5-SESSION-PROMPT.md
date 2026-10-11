# P5 交接提示词（2026-09-29 晚，展开自 TTS-PLAN/P5 调研结论）

> 工作目标：继续 P5「CosyVoice 2 端侧路线」调研，**先核实鸿蒙侧端侧运行时现状，再决定是否值得上鸿蒙 SDK POC**。
> 本提示词由前一 session 收尾时生成；前一轮已完成的调研与结论见下方「已核实/关键事实」。

## 环境与工作目录
- 交付仓库：`/Users/lichtcui/Documents/playground/source-reader-tts`（分支 `tts/mac-p0`，含未提交改动：TTS-PLAN.md §7/§9 P4、docs/tts-p0-report.md §14.19，都是已拍板结论，勿改）
- P4 历史工作区：`/Users/lichtcui/Documents/playground/tts/p4`（archive/ 有长稳原始数据）
- 引擎/模型仓库：`/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs`（P4 增量，默认行为不变；lib.rs/onnx_builder.rs/seg.rs 有未提交改动）
- 不要碰 `/Users/lichtcui/Documents/playground/source-reader`（阅读 App，已复原）
- 不要 commit，除非明确要求

## 上一轮已核实的关键事实（P5 起点）
1. **`NativeNui` 不是现成可用的官方鸿蒙 SDK**：CosyVoice 官方仓库（`QwenAudio/CosyVoice`，原名 `FunAudioLLM/CosyVoice`，活跃、23.8k★）的 `git/trees` 里没有任何 harmony/ohos/napi/native/hap 相关内容；ModelScope 官方 demo 是 gradio 在线服务；华为/OpenHarmony/Gitee/GitHub 全站检索 `NativeNui` = 0 命中；P4 文档与 git 历史也没有该说法出处。§7 拍板时把它当作既定事实是未经验证的假设。
2. CosyVoice 官方发布的三套推理：Python（PyTorch，`inference_zero_shot` 等，`stream=True` 流式）、`cosyvoice/bin/export_onnx.py`（导出 flow decoder/encoder、speech tokenizer、CosyVoice-BlankEN，opset 18）、Triton-TRT-LLM（GPU 服务）。
3. `CosyVoice2-0.5B` 模型文件（ModelScope `iic/CosyVoice2-0.5B`）：`llm.pt` 2.02 GB、`flow.pt`/`flow.cache.pt` 各 ~450 MB、`hift.pt` 83 MB、`speech_tokenizer_v2.onnx` 496 MB、`campplus.onnx` 28 MB 等；另有 `CosyVoice-ttsfrd`（可选，中文分字，不做也可用 WeTextProcessing）。
4. **P4 的 GPT-SoVITS 模型不能复用**：类型/结构完全不同（老的是 v2ProPlus 定制 ONNX + 角色克隆；CosyVoice2 是 `llm.pt/flow.pt/hift.pt` + SpeechTokenizer）。
   可复用的是 5 个 GPT-SoVITS 角色的 `ref.wav`（音色对比素材）与 P4 的 ORT for OHOS / Rust NAPI / M5 PCM 骨架经验。
5. **网络/环境（已实测）**：GitHub 直连超时；`gh-proxy.com`/`ghfast.top` 可达；ModelScope、PyPI、镜像站（daocloud、docker.1ms.run 等）可用；Docker Hub 直连不可用，第三方 CosyVoice 镜像（如 neosun100/cosyvoice-docker）在 daocloud 白名单外 403；本机 Mac load1 2.27、16 GB 物理、Docker Desktop 29.4.1 已跑（8 CPU/11.68GiB 限额，长期容器已占 ~1GB）。

## 我（上一轮）已给出的 P5 调整后的步骤
- 鸿蒙可行性核查（已完成大半）→ 产出「鸿蒙侧验证清单」初稿 + §7 修正草案
- Docker 验证 CosyVoice 2：流式/RTF/分段/音质，并重点验证「官方 ONNX + onnxruntime CPU 走通」
- 结论回填 `TTS-PLAN.md` §9 P5 + 更新 §7（把「官方鸿蒙 SDK NativeNui」改为待验证候选）

## 本轮具体任务（按顺序）
1. **核实鸿蒙侧端侧运行时现状**：CosyVoice 目前**没有**现成端侧运行时（官方无、sherpa 无）。需要评估：官方 ONNX 产物 + ORT for OHOS（P4 已打通交叉编译）+ NAPI + 流式推理 是否可行；LLM 部分能否导出 ONNX 是最大不确定性。同时调研是否存在别的端侧候选（如 onnxruntime-mobile、MindSpore Lite、NNRt 等）以及各候选对 CosyVoice 的支持状态。
2. 基于 1 的结论，**决定是否值得上鸿蒙 SDK POC**，并给出「鸿蒙侧验证清单」（HBN-AL80 / 麒麟 9010 / 16GB / API 24：模型分发、内存/RTF/首包延迟、流式、分段、回退、长稳等）。
3. 若值得，给出鸿蒙 POC 的技术路径（含自建运行时的工程量分级、风险）；若不值得（或需要先做 Docker 验证），给出替代路径（云端/预生成 + 端侧播放，或保持系统 TTS）。
4. **回填文档**：`TTS-PLAN.md` §9 新增「P5 结果」（按既有 P4 风格：✅/❌/⚠️、表格、结论）；同步修正 §7 路线 C 中「官方鸿蒙 SDK NativeNui」的表述（改为「候选运行时待验证，首选自研 = 官方 ONNX + ORT」及 C 兜底）。不要另开新文件。

## 约束与坑
- 先查 load1<4 窗口再跑测试；长跑边跑边落盘（hdc 掉线会丢现场）。
- 设备侧不能 exec 二进制，测量走 NAPI+ArkTS；hdc 掉线会连现场一起丢。
- crates.io 不可达，项目内 `.cargo/config.toml` 指向 rsproxy.cn 镜像（勿删）。
- Docker 里 CosyVoice 2 是虚拟化层，CPU 性能参考有限，重点验证接口/音质/分段（正确性），RTF 只作参考。
- `NativeNui`/官方鸿蒙 SDK **未证实存在**，不要把它当既定事实写进结论。
- 文档落位：`TTS-PLAN.md` 是活文档，实测结果回填 §8/§9，不要另开新文件；根目录只允许 AGENTS.md 与 README.md。
