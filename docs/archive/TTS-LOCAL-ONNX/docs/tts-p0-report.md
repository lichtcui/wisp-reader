# TTS-P0/P1 报告 — 环境、权重与 ONNX 导出（Mac）

日期：2026-09-26（P0）/ 2026-09-27（P1）
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`，基线 `0eb1e1c`）
对应计划：[`TTS-PLAN.md`](TTS-PLAN-LOCAL-ONNX.md) §9「P0 环境与权重（Mac）」、§9「P1 导出与校验」、§10
结论：**P0 全部完成**；**P1（ONNX 导出与校验）也已完成**（见 §11）。
上游克隆、patch、环境、预训练依赖全部就绪；三套 v2ProPlus 音色权重已修复并验证可被 PyTorch 加载；
`liuying` / `huahuo` / `kafuka` 三份全精度 bundle 均已导出、校验并可通过 `onnxruntime` 加载。

> 本文件是本轮的**交付证据与偏差记录**；实测结论（P1–P4）按 §11 约定继续回填 `TTS-PLAN.md` §8/§9。

---

## 1. 结论速览

| 项 | 状态 | 说明 |
|---|---|---|
| `01_clone.sh`（上游 GPT-SoVITS） | ✅ | 克隆到 `gpt-sovits-upstream/` |
| `02_patch.sh`（KV-cache overlay） | ✅ | 10 个文件被覆盖 + `export_onnx_v2.py` 新增 |
| `03_setup_env.sh`（Python 环境） | ✅ | uv `.venv`（python 3.10.19），torch 2.2.2 / transformers 4.57.6 可导入；**有 1 处偏差，见 §3** |
| `04_download_models.sh --version v2ProPlus` | ✅ | `s1v3.ckpt`、`s2Gv2ProPlus.pth`、`sv/*.ckpt`、G2PW、g2p_en 全部到位并通过 zip 校验 |
| 重下损坏的角色权重 | ✅ | 流萤 / 花火 / 卡芙卡三套 `gpt.ckpt` + `sovits.pth` 均可用 |
| staging `models/export/v2ProPlus/` | ✅ | 已指向流萤（主用音色） |

---

## 2. 与原文的关键事实修正

计划书 §2 判定三个角色 `.pth` 属「真损坏、必须重下」。**重下后证实：损坏源自上一轮的下载过程，而非源文件**。

证据链：

| 环节 | 观察 |
|---|---|
| 旧本地 zip | `流萤.zip` sha256 `67547bad…`，条目 `流萤_e10_s250.pth` 解压报 `invalid literal/length/distance code` |
| ModelScope 仓库记录 | `流萤.zip` 声明 sha256 `536c1c69…`（**与旧本地不一致**） |
| 重新下载（`resolve/master` 直链） | 得到 sha256 `536c1c69…`，**与仓库记录完全一致**；下载耗时 26s、11.7 MB/s |
| 重新解压 | `流萤_e10_s250.pth` 解出 172,765,299 B（= 声明大小），CRC 通过 |

花火、卡芙卡同样：重下 sha256 与仓库记录逐字节一致，解压 100%。

**已回写 Downloads**：校验通过后，4 个损坏包已用 `os.replace` 原子覆盖（保留原文件名，下游路径不变）：
`流萤.zip` / `花火.zip` / `卡芙卡.zip` / `芙宁娜_ZH.zip`（`芙宁娜` 的 `ckpt` 此前也是坏的）；
`胡桃_ZH.zip` 本来就完好，未改动。覆盖后对全部 5 个包重跑「sha256 + 逐条目解压 + 尺寸比对」→ 全部通过。
注意：Downloads 里的 zip 解出的 `.pth` **仍带 2 字节幻数问题**，直接 `torch.load` 仍会失败；
可直接使用的版本在 `models/v2ProPlus/<角色>/`（已修幻数）。

**由此新增一个 P0 未记录的步骤**：新下载的 `.pth` 内层存在 **2 字节幻数被改写**（与 §2 记录的 `胡桃` 同一模式）：
首字节为 `30 36`（`"06"`）而非 `50 4B`（`PK`）。把前 2 字节改回 `PK` 后，684 个条目全部 `testzip=None`。
若不修这一步，后续 `torch.load()` 会失败。**这是 P1 导出的前置条件。**

---

## 3. 已知偏差 / 与本机现实的差异（需要知情）

| # | 偏差 | 影响与处置 |
|---|---|---|
| 1 | 上游 `requirements.txt` 的 `onnxruntime-gpu; platform_machine == "x86_64"` 在 macOS 无 wheel | 本机为 Intel（x86_64）macOS 26.6.2，故改为 `onnxruntime`（CPU）后安装 |
| 2 | `numba` 最新版依赖的 `llvmlite` 无 cp310/osx-x86_64 wheel，源码编译失败 | pin `numba==0.62.0` + `llvmlite==0.45.0`（均有官方 wheel） |
| 3 | `onnxsim` 全版本**只有 arm64 的 macOS wheel**，源码编译在本机失败 | 用最小 stub 占位（见 §4）。`optimize_aio.py` **只 import、从不调用** `simplify()`，实际简化走 `onnxslim` |
| 4 | `04_download_models.sh` 的 `ModelScope` 分支仍用 `huggingface.co` 作为 `HF_BASE`，本机直连超时 | 改用 `--source HF-Mirror`（脚本内置、可正常解析全部条目） |
| 5 | `nltk_data` / OpenJTalk 词典按脚本逻辑只对 uv 环境补齐 | 已自动补；`04` 第二次运行输出 “Downloading OpenJTalk dictionary for uv env” |
| 6 | 旧「解压失败百分比」（97.09% / 99.90% / 88.23%） | 属**下载损坏**的表象，重下后不再复现，已非真实约束 |

---

## 4. `onnxsim` stub 说明（可审计）

安装位置：`gpt-sovits-upstream/.venv/lib/python3.10/site-packages/onnxsim.py`

```python
__version__ = "0.0.0-stub"

def simplify(model, *args, **kwargs):
    raise NotImplementedError(
        "onnxsim is stubbed on this host; optimize_aio.py does not use it. "
        "Use onnxslim.slim() instead."
    )
```

设计取舍：宁可**显式抛错**也不静默返回未简化的模型。审计依据：`scripts/optimize_aio.py` 中 `simplify(` 的调用次数 = **0**（`grep -c` 为 0），文件内实际简化全部经 `onnxslim.slim()`。
若后续需要真正的 `onnxsim`：装 arm64 Mac（或等 x86_64 wheel），或按 §10 的手动 cmake 路线补 `Python_FIND_STRATEGY=LOCATION`。

---

## 5. 环境快照

- Python 3.10.19（uv 托管），venv：`gpt-sovits-upstream/.venv`（2.1 GB）
- torch 2.2.2 / torchaudio 2.2.2 / transformers 4.57.6 / peft 0.17.1
- onnxruntime 1.23.2 / onnx 1.22.0 / onnxslim 0.1.96 / onnxoptimizer 0.4.2 / onnxconverter-common 1.16.0
- numba 0.62.0 / llvmlite 0.45.0 / numpy 1.26.4 / librosa 0.10.2 / gradio 3.36.1
- 磁盘占用：`gpt-sovits-onnx-rs/` 7.3 GB；`models/` 945 MB

---

## 6. 权重清单与校验值

持久目录：`~/Documents/playground/tts/models/v2ProPlus/<角色>/{gpt.ckpt,sovits.pth}`

| 角色 | 文件 | 大小 (B) | sha256（2 字节修复后） |
|---|---|---|---|
| 流萤 | `gpt.ckpt` | 155,313,312 | `6bd258178790eceb244fc27a8a60a530012f309c45525609c8343ca6597da358` |
| 流萤 | `sovits.pth` | 172,765,299 | `56767d6c7aa5bce96fdebeb634d713558305515f0135d5046b9db1f56b54d073` |
| 花火 | `gpt.ckpt` | 155,313,312 | `924e8ade8a82332543d959f120eeccf2f8112c84826331fd14bbc2687aea26da` |
| 花火 | `sovits.pth` | 172,765,299 | `885cc4f568fd9914d09e041f5f252f8a433719d2839d60b0ab40970413563d51` |
| 卡芙卡 | `gpt.ckpt` | 155,313,312 | `75a9ac0806a8692bc2f6bfbf4ab5990173e1afeb4c4daf287edaed1b882d7ad2` |
| 卡芙卡 | `sovits.pth` | 172,765,299 | `9a8bc382ae86acc98f0193e4d602e329021d7b8d06dde311a97093113616002d` |

Downloads 侧复核（2026-09-26，全部通过）：

| 包 | sha256 | 状态 |
|---|---|---|
| `流萤.zip` | `536c1c69…` | ✅ 已替换 |
| `花火.zip` | `562fee3a…` | ✅ 已替换 |
| `卡芙卡.zip` | `ab501b22…` | ✅ 已替换 |
| `芙宁娜_ZH.zip` | `7a5c00fc…` | ✅ 已替换（v4，保留） |
| `胡桃_ZH.zip` | `b46dec72…` | ✅ 原本完好（v4，保留） |

预训练依赖（`GPT_SoVITS/pretrained_models/`）：

| 文件 | 大小 (B) | 校验 |
|---|---|---|
| `s1v3.ckpt` | 155,284,856 | `testzip=None`（297 条目） |
| `v2Pro/s2Gv2ProPlus.pth` | 200,125,741 | `testzip=None`（785 条目） |
| `v2Pro/s2Gv2Pro.pth` | 162,303,657 | `testzip=None` |
| `sv/pretrained_eres2netv2w24s4ep4.ckpt` | 107,528,697 | `testzip=None`（1003 条目） |
| `text/G2PWModel/g2pW.onnx` | 635,212,732 | 存在 |
| `models/g2p_en/{encoder,decoder}_model.onnx` | 6,634,844 / 9,999,491 | 存在 |

权重可加载性（`torch.load` + `sys.path` 加 `GPT_SoVITS/`）——三套一致：

```
gpt_tensors=295   sovits_tensors=678   ref_enc=True   quantizer=True
gpt config n_layer=24   sovits n_speakers=300   enc_p.text_embedding=(732,192)
```

后两项与 TTS-PLAN §3 的记载一致（`n_speakers: 300` 沿用、v2ProPlus 全量权重而非 LoRA）。

---

## 7. 参考音色

主用：**流萤【难过】抱歉，我不得不这么做……** — 44100Hz / 单声道 / 16bit
对照：**流萤【中立】…我应该会选择请求猎犬家系停止追捕。** — 44100Hz / 单声道 / 16bit
参考文本 = 文件名去掉 `【情绪】` 前缀。

三套角色共 14 条参考音频固化在 `models/v2ProPlus/<角色>/中文/emotions/`，
时长/采样率与 TTS-PLAN §1 明细逐条吻合（全部 44.1kHz 单声道 16bit）。

### 7.1 已就绪的 ref.wav（P2 直接用）

| 路径 | 用途 | 内容 |
|---|---|---|
| `models/v2ProPlus/流萤/ref.wav` | **主用** | 【难过】**已裁静音**，2.68s |
| `models/v2ProPlus/流萤/中文/emotions/【难过】….wav` | 原始 | 4.41s（含 1.75s 前导静音） |
| `models/v2ProPlus/流萤/ref_zhongli.wav` | 对照 | 【中立】3.38s（原样，无长静音） |
| `models/export/v2ProPlus/ref.wav` | P2 staging | 同主用裁剪版 |

`gpt_sovits_demo` 从 `{model_path}/ref.wav` 读取参考音频（硬编码），故 staging 目录已放好。

### 7.2 ⚠ 参考音频质量发现（P2 需知情）

对**全部 6 条流萤参考音频**做静音分析（50ms 窗、阈值 0.02）后发现：

| 参考音频 | 总长 | 前导静音 | 尾部静音 | **实际语音** |
|---|---|---|---|---|
| 【生气】 | 3.24s | 0.05s | 0.10s | 3.09s |
| 【中立】 | 3.38s | 0.00s | 0.15s | 3.23s |
| 【恐惧】 | 3.82s | 0.10s | 0.30s | 3.42s |
| 【开心】 | 4.55s | 0.05s | 0.10s | 4.40s |
| 【吃惊】 | 4.70s | 0.10s | 1.00s | 3.60s |
| **【难过】** | **4.41s** | **1.75s** | 0.05s | **2.61s** |

- **【难过】实际语音只有 2.61s**，前 1.75s 几乎全静音 —— 低于上游建议的 3–10s 区间下限。
  原因是「抱歉，我不得不这么做……」之前的剧情停顿被录进了素材。
- 已生成裁静音版 `ref.wav`（2.68s，含 30ms 前导 / 100ms 尾巴），**原始文件未改动**。
- 运行时（Rust `TtsController` 侧）**不做静音裁剪**，故这 1.75s 静音会直接进 SSL 特征、污染参考语义。
  裁剪是必要的，不是可选优化。
- **因此 TTS-PLAN §9 把【难过】定为「主用」的假设需要 P2 复验**：2.61s 有效语音可能不足以稳定克隆音色。
  若 P2 听感不佳，退回【中立】（3.38s，无长静音）或【开心】（4.40s）更稳妥。

## 8. 目录布局（仓库外，未污染 App 仓库）

```
~/Documents/playground/tts/
  gpt-sovits-onnx-rs/                 # bailu 工具链（git clone）
    gpt-sovits-upstream/              # 上游 GPT-SoVITS + patch + .venv
    scripts/export/                   # 01–05 脚本
  models/v2ProPlus/<角色>/            # 修复后的权重 + 参考音频
```

Downloads 中的 `{流萤,花火,卡芙卡,芙宁娜_ZH}.zip` 已替换为校验通过的完整版；
`胡桃_ZH.zip` / `芙宁娜_ZH.zip` 为 v4，**保留备用**（本期不投入）。临时目录 `redownload/` 已清理。

**注意**：P0 未改动 App 仓库任何 `entry/`、`rust/`、`.so`；本分支只新增本报告并回填 `TTS-PLAN.md`。

---

## 9. 复现命令

```bash
cd ~/Documents/playground/tts/gpt-sovits-onnx-rs
./scripts/export/01_clone.sh
./scripts/export/02_patch.sh
# 03：uv 路线，另需按 §3 偏差 1–3 调整依赖
./scripts/export/03_setup_env.sh --source HF-Mirror
./scripts/export/04_download_models.sh --version v2ProPlus --source HF-Mirror

# 角色权重：重下 + 修 2 字节幻数（可脚本化）
curl -fL -o 流萤.zip "https://www.modelscope.cn/models/aihobbyist/GPT-SoVITS_Model_Collection/resolve/master/星穹铁道/中文/流萤.zip"
shasum -a 256 流萤.zip   # 期望 536c1c69742f169b14f18f46ce0a407248b7075f0f39a85032952ea5aaf45cdc
```

---

## 10. P1 导出方案（已于 2026-09-27 执行完毕，实测见 §11）

P1 = 导出与校验。**导出粒度 = 每个音色一份 ONNX bundle**（不是每个参考音频一份）：

- 导出脚本 `export_onnx_v2.py` 用的是 `torch.randn` 假音频做 dummy input，**完全不读参考音频**；
  参考音频与参考文本是 **P2 推理时**的运行时输入（`--ref-audio` / `--ref-text`）。
- 因此**流萤【难过】与【中立】共用同一份 bundle**，参考音频在 P2 阶段换着喂即可。
- 已核实三套角色的 `gpt.ckpt` 权重确有差异（295 张量中 294 个不同）→ **每个音色必须各导一份**。

```bash
# 流萤（主用；参考音色【难过】/【中立】都走这一份）
ln -sfn ~/Documents/playground/tts/models/v2ProPlus/流萤/gpt.ckpt    \
        gpt-sovits-upstream/models/export/v2ProPlus/gpt.ckpt
ln -sfn ~/Documents/playground/tts/models/v2ProPlus/流萤/sovits.pth \
        gpt-sovits-upstream/models/export/v2ProPlus/sovits.pth
./scripts/export/05_export.sh --version v2ProPlus --export-name liuying --no-quant
./scripts/export/validate_bundle.sh --bundle-dir gpt-sovits-upstream/onnx-patched/liuying --expect-v2pro
```

可选：把 staging 的 `gpt.ckpt`/`sovits.pth` 换成 `花火` / `卡芙卡` 再各跑一次 05，
得到 `huahuo` / `kafuka` 两份 bundle（P2 若要做音色 A/B 会用到）。

**P1 前置**：`models/export/v2ProPlus/` 当前 staging 的已是**流萤**；
三套角色的权重与参考音频固化在 `~/Documents/playground/tts/models/v2ProPlus/<角色>/`
（sha256 见本报告 §6）。参考文本 = 参考音频文件名去掉 `【情绪】` 前缀。

> **P1 执行结果见 §11**（2026-09-27）。

---

## 11. P1 实测（ONNX 导出与校验，2026-09-27）

P1 = 导出与校验。**全部完成**，结论与命令已回填 `TTS-PLAN.md` §9「P1 结果」。

### 11.1 产物 sha256（三份 bundle）

`gpt-sovits-upstream/onnx-patched/<name>/`，全部 **opset 21**、`onnx.checker` 通过、`onnxruntime` 加载通过。

| 文件 | liuying | huahuo | kafuka |
|---|---|---|---|
| `ssl.onnx` | `093edf9b95bc604e` | `093edf9b95bc604e` | `093edf9b95bc604e` |
| `sv.onnx` | `c841c0387fa3a6df` | `c841c0387fa3a6df` | `c841c0387fa3a6df` |
| `bert.onnx` | `35a7ea4dab0efe8c` | `5b3b4d26a0d814b7` | `5b3b4d26a0d814b7` |
| `g2pW.onnx` | `e44d7bbaa07b8456` | `4892800773acd22f` | `cd062583ddfbe6ba` |
| `*_t2s_encoder.onnx` | `24c681334bcdac36` | `24c681334bcdac36` | `24c681334bcdac36` |
| `*_t2s_fs_decoder.onnx` | `2ff5713e12807f4f` | `c2f7e5eedfb87899` | `11a561f00f40e283` |
| `*_t2s_s_decoder.onnx` | `2404d917ec868d04` | `21e5c71c8d7c2328` | `7194fae21f7e2c6e` |
| `*_vits.onnx` | `aff04cdadb42f2fd` | `3eb80612b8f549a9` | `cdfadccc3f70f155` |

（sha256 截前 16 位；每份 bundle 约 3.2 GB。）

### 11.2 关于 `bert.onnx` / `g2pW.onnx` 的 sha256 不一致

- `ssl.onnx` / `sv.onnx` 三份**逐字节相同**（音色无关）。
- `bert.onnx` / `g2pW.onnx` sha256 不同，但**张量逐元素相等、算子多重集与 initializer 集合相同**；
  差异仅在 1–2 个 value_info 的**符号维度标签**（`input_ids_dynamic_axes_*` / `token_type_ids_len` 等），
  来自 onnxslim 的非确定性命名。**非语义差异，无需处理。**
- `*_t2s_encoder.onnx` 三份相同（编码器共享），音色差异集中在 `*_t2s_{fs,s}_decoder.onnx` 与 `*_vits.onnx`。
- 复核命令：`onnx.load(...)` 后逐 initializer `numpy_helper.to_array` 比较（`equal_nan=True`），差异数 = 0。

### 11.3 关键新发现：上游工具链假设 torch ≥ 2.6

上游 patch 的 `export_onnx_v2.py` 用 `_LEGACY_ONNX_KWARGS = {"dynamo": False}` + `opset_version=20`，
**明确假设 torch ≥ 2.6**（2.6 起 `torch.onnx.export` 才有 `dynamo`、默认 dynamo 导出器）。
本机 Intel macOS 的 torch 上限是 **2.2.2**（无 2.6+ x86_64 wheel），因此 4 个偏差全部在本机暴露。
详见 `TTS-PLAN.md` §9「P1 结果 → 新增平台偏差」；处置脚本见 §11.4。

### 11.4 P1 处置脚本（仓库外，纯增量、幂等、可回滚）

新增/改动都在工具链仓库 `gpt-sovits-onnx-rs`：

| 文件 | 作用 |
|---|---|
| `scripts/export/lib/ensure_safetensors.py` | 为 `.bin` 检查点生成 `model.safetensors`（**新增**） |
| `scripts/export/lib/patch_torch_legacy_export.py` | 在克隆副本上做 3 处 legacy 适配（**新增**） |
| `scripts/export/lib/common.sh` | 新增 `patch_legacy_onnx_export()` / `ensure_pretrained_safetensors()`，**仅当 torch < 2.6 触发**（+25 行） |
| `scripts/export/05_export.sh` | 导出前调用上述两个钩子（+3 行） |

- **未改 `patch/GPT_SoVITS/`** 的 patch 语义（该目录是 overlay 源，`02_patch.sh` 会用它还原上游副本）。
- 三个适配点：① 干掉 `dynamo` kwarg；② `opset_version` 20 → 17；③ `attn_implementation="eager"`。
- 幂等：重复运行输出 `[INFO] up to date`；`torch ≥ 2.6` 的主机不触发，行为与原先完全一致。
- `legacy opset` 说明：torch 2.2.2 名义上支持 19，但它发出的 `ReduceMean(axes=...)` 属性直到 opset 18
  才改为输入，故 opset > 17 会被 exporter 自己的 checker 拒绝。下游 `optimize_aio.py` 必跑
  `version_converter.convert_version(model, 21)`，最终 bundle 仍为 opset 21。

### 11.5 P2 前置状态

| 项 | 状态 |
|---|---|
| `onnx-patched/liuying/ref.wav` | ✅ 已放（流萤【难过】裁剪版 2.683s，sha `b287aefa07ef7e91`） |
| `models/export/v2ProPlus/` staging | ✅ 已还原为**流萤** |
| `huahuo` / `kafuka` 的 ref.wav | ⬜ 未放（参考音频选择留到 P2，按需从 `models/v2ProPlus/<角色>/中文/emotions/` 拷入） |
| `bert.onnx` / `g2pW.onnx` 去重 | ⬜ 三份 bundle 各存一份（多占约 3.7 GB）；P2 如需省盘可改指向同一文件 |

---

## 12. P2 安装/运行层面的新偏差（2026-09-27）

P2（Mac 推理与指标）首次真正**运行** Rust 引擎时，暴露了 P0/P1（只做导出/加载）覆盖不到的两类问题。
**结论**：这两条都是**本机（Intel macOS）平台限制**，与 §3 的 6 条同源（都是「上游假设较新平台」）；处置均**仓库外、纯增量、可回滚**。

### 12.1 `ort` rc.12 在 Intel macOS 无可用 ORT（**必须知情**）

| 项 | 内容 |
|---|---|
| 现象 | `cargo build --release` 在 **link 阶段（ort-sys build script）** 报 `ort does not provide prebuilt binaries for the target x86_64-apple-darwin with feature set (no features)`；原 `dist.txt` 里 x86_64-macOS 记录为 **0 条**（仅 `aarch64-apple-darwin`）。 |
| 根因（两层） | ① 微软**从 ORT 1.24 起不再发布 x86_64-macOS 预编译**，Intel 最后一版是 **1.23.2**（GitHub releases 实测：1.20.x–1.23.x 有 `onnxruntime-osx-x86_64-*.tgz`，≥1.24 只有 `osx-arm64`）。② `ort` **2.0.0-rc.12 默认 `api-24`**（`default = [..., "api-24"]`），与 1.23.2 的 **API 23** 不兼容——即便强行链接，`GetApi(24)` 也会返回 null，运行时 panic（本机实测：`The requested API version [24] is not available, only API versions [1, 23] are supported`）。 |
| 处置（改动落在工具链仓库 `gpt-sovits-onnx-rs`） | `Cargo.toml` 里把 `ort` 改为 `default-features = false` + 显式 `["std","ndarray","tracing","copy-dylibs","half","api-23"]`，使 `ort-sys::ORT_API_VERSION = 23`；并把 **`ORT_LIB_LOCATION`** 指向 venv 自带的 `libonnxruntime.1.23.2.dylib` 做**动态链接**（`ORT_PREFER_DYNAMIC_LINK=1`）。 |
| 可回滚 | 仅 1 处 `Cargo.toml` 改动（`git diff` 可见，见下）；回滚即恢复 `download-binaries` + 默认 feature。**未改 `src/`、未改任何 ONNX、未改 Android/OHOS 路径。** |
| 与计划的关系 | 印证 §4.5 / §8 第 3–4 条：**ORT 的版本与 API 等级是路线 A 的硬约束**。P4 若要配 `ort` rc.12，自建的 OHOS ORT **必须 ≥ 1.24**（1.16.3 冒烟版必然不兼容）。 |

```diff
# rust 工具链仓库 Cargo.toml（可回滚）
-ort = { version = "=2.0.0-rc.12", features = ["ndarray","download-binaries","copy-dylibs","half"] }
+# ort rc.12 默认 api-24；Intel macOS 无 ORT ≥1.24 预编译，降到 api-23 并动态链接 1.23.2
+ort = { version = "=2.0.0-rc.12", default-features = false,
+        features = ["std","ndarray","tracing","copy-dylibs","half","api-23"] }
```

```bash
# 构建/运行（P2 实际用法）
export ORT_LIB_LOCATION=~/Documents/playground/tts/p2/ort-lib      # 内含 libonnxruntime.1.23.2.dylib 符号链接
export ORT_PREFER_DYNAMIC_LINK=1
cargo build --release --example gpt_sovits_demo
# 产物用 install_name_tool -add_rpath 指向该目录后，即可脱离 DYLD_LIBRARY_PATH 运行
```

> 附带坑：`/usr/bin/time -l` 在 macOS 受 SIP 保护，会**剥离 `DYLD_*`**；改用 `install_name_tool -add_rpath` 固化 rpath，或直接用 Python `resource.getrusage(RUSAGE_CHILDREN)` 取峰值。

### 12.2 测量脚手架与「共享机器噪声」（影响指标可信度）

- **本机是共享机器**：P2 头两小时遇到外部进程（`duetexpertd` 49% / `BiomeAgent` 21% / `MTLAssetUpgraderD` 16% / `swcd` 15% …，合计 ≈186% CPU）**把 4 核打满**，
  同一段文本的合成耗时从 **4.6 s 飘到 34 s**（≈7×）。**任何单次测量都可能被污染。**
- 处置：每格取 **K 次独立进程**并记录 `loadavg_start`，只采信 **load1 ≤ ~12** 的窗口；`TTS-PLAN.md` §9 的 P2 主表已标注此协议。
- 工具链侧**无可调项**：`src/cpu_info.rs` 在非 Linux 平台无法识别大小核，`get_hw_big_cores()` 失败 → 回退 **8 intra-op 线程**（=逻辑核数），
  故外部负载会同时抢 8 个 ONNX 线程。若要在本机做**可复现**基准，建议临时 `taskset`/`cpuset` 或改小 `with_intra_threads`（P3 可议）。
- 脚手架自身：Python **3.14.5** 在本机与 `subprocess`+回读 stdout 的写法组合下**偶发段错误**（`_PyUnicode_JoinArray`）；
  实际测量改用 venv 的 **python3.10** 并以「子进程 stdout 重定向到文件 + 纯轮询采样」的方式运行，稳定。

> P2 的**全部实测表格**见 [`TTS-PLAN.md`](TTS-PLAN-LOCAL-ONNX.md) §9「P2 结果」；本条只记平台偏差与测量方法。

---

## 13. P3 追加（2026-09-27）：新偏差、新坑与口径

> 本节为 P3（分段与长稳）运行层面新增内容，**不改动 §1–§12 任何旧节**。
> P3 的结论表在 [`TTS-PLAN.md`](TTS-PLAN-LOCAL-ONNX.md) §9「P3 结果」；这里只记「怎么跑、哪里会踩坑」。

### 13.1 「复读」的真实机制（**推翻 §9 P2 §⑤ 的推断**）

- P2 依据「VITS 确定性 ⇒ 逐采样相同 ⇒ 同 semantic token」推断为**语义绕回**。P3 证明该推断链**不成立**：
  - **与文本无关**：6 段完全不同文本、每段都 >6.5 s，**每片都在同一偏移 ≈6.5 s 起被逐采样完全相同（maxdiff=0.0）的尾块覆盖**。
  - **token 层反证**：该区间的 `pred_semantic` token 与片头 token **无一相同**（`identical=0/120`）。
  - **不可懂**：尾块 `rms≈0.030`（语音 0.136）、`peak≈0.088`、谱平坦度 0.224、中心频率 2166 Hz；ASR 给出**幻觉文本**（不同片不同）。
- **定性**：`{prefix}_vits.onnx` 的**恒定尾部伪影**，固定偏移框 ≈ **6.5 s**，触发条件 ≈ **分片音频时长 > 6.5 s**，与文本/语义/采样参数**均无关**。
- §9 P2 §⑤ 报的「2.32 s / 1 处」是**漏检**：同一文件实测 6 处、最长 8.0 s（都在同偏移框架内）。

### 13.2 新坑（工具链/测量）

1. **固定 seed 在本引擎无位级可复现性**：`--seed 42` 连续两次合成，**长度相同（2920320 样本）但波形 maxdiff ≈ 1.2**；
   与 P2 那一次也逐采样不同。原因：KV cache **按任意增量重分配**（`CACHE_REALLOC_INCREMENT` 路径），
   `iy` 用**原始 `Vec<i64>` 指针**喂入；重分配点随执行路径变化 ⇒ 采样流不可位级复现。
   **结论**：P2/P3 里「固定 seed」的运行不可互相比对，「复读率」必须用**多次独立运行**统计（P3 每格 K=5）。
2. **P2 的 `measure.py` 无法关 seed**：它硬编码 `--seed <int>`，因此 **P2 从未跑过非固定 seed**——这正是 P2 只给 1 例的原因。
   P3 改用 `--no-seed`（若引擎侧未暴露，可用 `{"seed": null}` 的 `--params` JSON）。
3. **`/tmp` 临时文件与 `asm/_audio_tmp.npy`**：`harness/runlib.load_audio` 把音频写成 `.npy` 再由宿主 venv 读取；
   该 `.npy` 会累积到 12 MB 级，注意及时清理，别当成产物提交。
4. **`chunk_for_limit` 必须与 `seg.rs` 同源**：P3 的 `harness/chunker.py` 复刻了 `pre_seg_text`（含 `_merge_short(texts,5)`、
   标点归一，**但仍以「。！？」为切句界**）。已用引擎 `Processing chunk:` 日志与「0.3 s 静音 gap」双重校验一致；
   若上游改 `seg.rs`，此复刻需同步。
5. **`.venv` 里的 faster-whisper（ASR 抽检）**：`small` int8 在本机 **CPU 约 30× 实时**（7.8 s 音频 ≈ 232 s），
   且**时间戳不可靠**（大量 0.3 s 停顿会把段边界推到离谱位置）。故 ASR **只作定性抽检**，复读率一律用音频级检测。

### 13.3 复读检测口径（P3 定稿）

- `harness/loopdetect.py`：**FFT 归一化自相关**找候选 lag → 分块（0.3 s）判 **exact（`max|a-b| ≤ 1e-4`）/ near（cos ≥ 0.90）** → 最长连续 run 作为事件。
- 口径要点：① 两块都需高于能量门（默认 15 % 语音中位 RMS），**0.3 s `fragment_interval` 静音不计**；
  ② 两块间隔 ≥ 0.5 s；③ **跨分片**才计入（同片内不计）。
- 局限：`exact` 对 int8 输出仍适用（int8 的伪影与 fp32 同类型）；`near` 阈值 0.90 会漏掉更弱的伪影 ⇒ 报告的复读率是**下界**。
- 另一条独立口径：**「分片音频时长 > 6.5 s」的占比**（不需要跨片比对，直接给伪影规模上界）：

  | 阈值 | 超阈（去重 24 片） | 被覆盖时长 | 占构造音频 |
  |---|---|---|---|
  | 6.0 s | 12/24（50 %） | 22 s | 15.5 % |
  | 6.5 s | 10/24（42 %） | 16 s | 11.6 % |
  | 7.0 s | 8/24（33 %） | 12 s | 8.2 % |

  （长稳里分片 ×40 重复出现，故按**去重分片集合**口径统计；±0.3 s 内的小差异来自每轮无固定 seed 的时长抖动。）

### 13.4 长稳测量口径（1 h）

- 单进程、`960` 分片（`page_long`+`mixed` 各切 `cap=45` 后 ×40），`--no-seed`，全程 `RUST_LOG=debug`。
- 内存：`libproc proc_pid_rusage(RUSAGE_INFO_V2)` 取 `resident_size` **与** `phys_footprint`，每 5 s 一次（见 `harness/proc_sampler.py`）。
- **判泄漏的经验规则**：RSS 会随 harness **累积输出的 PCM** 线性抬升（本机 32000 Hz × f32 ⇒ 0.12 MiB/s 音频）；
  末值漂移须先扣掉这一项再看，否则会把「累积缓冲」误判成「引擎泄漏」。P3 观测 +0.54 GiB ≈ 预期 0.43 GiB ⇒ **无泄漏**；
  `phys_footprint` 更稳（+0.24 GiB），**建议端侧以 footprint 为准**。
- 异常 EOS 口径：直接解析 `stop_idx`；`stop_idx ≥ 1500` 记「跑满上限」，否则记「提前 EOS」。

---

## 14. P4 追加（2026-09-28）：ORT for OHOS 交叉编译、NAPI、主机侧坑

> 本节为 P4（真机路线）**主机侧**新增内容，**不改 §1–§13 任何旧节**。
> P4 的结论表在 [`TTS-PLAN.md`](TTS-PLAN-LOCAL-ONNX.md) §9「P4 结果」；这里只记「怎么编、哪里会踩坑」。
> **真机现状**：P4 期间 `hdc list targets` 全程 `[Empty]`（设备 33Z0224424136564 未接线），
> 故 §14 只含主机侧；端侧 RTF/内存/长稳待设备回来后补。

### 14.1 ORT 版本硬约束：必须 1.24.x（**修正 §4.5 的「1.22.0」**）

- **原因**：`ort = 2.0.0-rc.12` 默认 `api-24`，且 `ort-sys` 的 `api-1x` feature **最高只到 `api-24`**；
  `ORT_API_VERSION`（= 最高启用的 api）**必须等于**所链 ORT 的内部 `ORT_API_VERSION`。
  - 1.24.x → API 24 ✅（与 rc.12 默认一致）
  - 1.23.2 → API 23（需降 feature，Mac 侧妥协）
  - 1.22.0 → API 22（TTS-PLAN 原定，**与 rc.12 默认不符**）
  - 1.16.3 → API 16（社区唯一 OHOS 预构建，仅冒烟）
- 另注：`ort` 的 `default-features = false` 时 **api 也不是默认开**的，必须显式列 `api-24`（或对应等级），
  否则 `ORT_API_VERSION` 回落到最小 17。
- **实证**：手搓的 ORT **1.24.4** 编出后，二进制导出版本串 `1.24.4`、`OrtGetApiBase@@VERS_1.24.4`。

### 14.2 OHOS 交叉编译的两个「cfg 反直觉」点

1. `rustc --print cfg --target aarch64-unknown-linux-ohos` → `target_os="linux"`、`target_env="ohos"`、`target_family="unix"`。
   - 后果 A：任何 `#[cfg(target_os = "linux")]` 分支在 **OHOS 上也会生效**（写 OHOS 特判要小心别把 Linux 分支覆盖掉）。
   - 后果 B：`ort` 的 `load-dynamic` 走 Linux 分支 dlopen `libonnxruntime.so` —— **OHOS HAP 原生库目录天然支持**，
     不需要为 OHOS 特判，也不需要 `ORT_DYLIB_PATH` 指向绝对路径（可用 `$ORIGIN`）。
2. `ohos.toolchain.cmake` 里 `CMAKE_SYSTEM_PROCESSOR = aarch64`，故 ORT 的 `onnxruntime_target_platform = aarch64`，
   其「Linux aarch64」分支全部生效 —— 于是**上游对 Linux 的假设**（下面几条）才会在 OHOS 上崩。

### 14.3 ORT 上游需 4 处 OHOS 补丁（musl / 平台识别差异）

| # | 文件 | 现象 | 补丁 |
|---|---|---|---|
| 1 | `tools/ci_build/build.py` | Android 分支硬编码 `android.toolchain.cmake`；不带 `+bf16` 时 MLAS 的 `bfloat16_t` 缺失 | 用 `OHOS_TOOLCHAIN_FILE` 环境变量切换到 `ohos.toolchain.cmake` + `OHOS_ARCH`，并在 `CMAKE_CXX_FLAGS` 加 `-march=armv8.2-a+bf16` |
| 2 | `onnxruntime/core/mlas/lib/mlasi.h` | OHOS clang **没有 `arm_bf16.h`**，`bfloat16_t` 仅在 TU 带 `+bf16` 时存在；而 `sqnbitgemm_kernel_neon_int8.cpp` 只带 `+dotprod` 却引用该 typedef | 在 `__ARM_FEATURE_BF16` 未定义时补 `typedef unsigned short bfloat16_t;`（ABI 兼容占位） |
| 3 | `onnxruntime/core/platform/posix/env.cc` | musl(OHOS) **无 `pthread_setaffinity_np`** | 在 `#if !defined(__APPLE__) && !defined(__ANDROID__) && ...` 里加 `!defined(__OHOS__)`（与 Android 同处理） |
| 4 | `cpuinfo` 的 `CMakeLists.txt`（`pytorch_cpuinfo`） | `CMAKE_SYSTEM_NAME="OHOS"` 不在白名单 → `CPUINFO_SUPPORTED_PLATFORM=FALSE` → arm64 linux 源不编译 → 链接 `undefined symbol: cpuinfo_isa` / `cpuinfo_arm_linux_init` | 白名单加 `OHOS`，并把所有 `CMAKE_SYSTEM_NAME STREQUAL "Linux"` 分支放宽为 `Linux OR OHOS` |

> 补丁脚本（幂等）：`~/Documents/playground/tts/p4/patches_ort_ohos.sh`；
> 其中 #4 作用于 `build/…/_deps/pytorch_cpuinfo-src/`（FetchContent 拷贝），**在首次 `cmake` 配置后重跑一次**。

### 14.4 网络：GitHub 限速与镜像（**再现 §12.2 的「本机网络脆弱」**）

| 通道 | 实测速度 |
|---|---|
| `github.com` git clone | 握手/HTTP2 层失败（`Error in the HTTP2 framing layer` / `Couldn't connect … after 75 s`） |
| `codeload.github.com` 直连 | ≈ 31 KB/s，且中途断流（`unexpected end of file`） |
| 系统代理 `127.0.0.1:7897` | ≈ 1.6 MB/s，但**长连接会被掐**（164 MB 后 `curl` exit 18） |
| **`gh-proxy.com` 镜像** | **≈ 14 MB/s**，完整 271 MB tarball 20 s 下完 |

- 处置：ORT 源码走 **`gh-proxy.com` 的 codeload tarball**（非 `git clone`）；41 个 `FetchContent` 依赖预下到本地
  `mirror/`，再让 `build.py --cmake_deps_mirror_dir=<mirror>` 走本地。
- 坑：**tarball 无 `.git`** ⇒ `build.py` 的 `git submodule sync` 会 `fatal: not a git repository`（exit 128）
  ⇒ 必须 `--skip_submodule_sync`。
- 坑：`mirror/` 目录结构须严格等于 `<mirror>/<github-host-path>`（`onnxruntime_CMAKE_DEPS_MIRROR_DIR` 的
  正则只替换 `https://` 前缀）；判「本地命中」是 `EXISTS`，所以**半截文件要清掉**否则 cmake 拿坏 zip 报 hash 错。

### 14.5 Rust 侧交叉编译（引擎 + NAPI 壳）

- **C 依赖需要 `--sysroot`**：`onig_sys`（oniguruma）、`knf-rs-sys` 等经 `cc` crate 编译，
  默认 `cc --target=aarch64-unknown-linux-ohos` **找不到 `stdlib.h`**。修法（见 `p4/ohos-env.sh`）：
  ```bash
  NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
  export CC_aarch64_unknown_linux_ohos=$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang
  export CXX_aarch64_unknown_linux_ohos=$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++
  export CFLAGS_aarch64_unknown_linux_ohos="--sysroot=$NATIVE/sysroot -fPIC"
  export CXXFLAGS_aarch64_unknown_linux_ohos="--sysroot=$NATIVE/sysroot -fPIC"
  ```
- **引擎仓库的 `ort` 是按目标拆分的**：`[target.'cfg(target_env = "ohos")'.dependencies]` 里配
  `ort = { default-features = false, features = ["std","ndarray","tracing","half","api-24","load-dynamic"] }`；
  用 `load-dynamic`（而非 `ORT_LIB_PATH`）是因为 ORT 的 `.so` **不参与构建期链接**，运行时 dlopen。
- **主机 `cargo test --lib` 需要** `DYLD_LIBRARY_PATH=…/p2/ort-lib`（否则 dlopen `libonnxruntime.1.23.2.dylib` 失败，
  test 进程直接 SIGABRT）—— 与 §12.1 的 `/usr/bin/time -l` 剥 `DYLD_*` 是同源的 macOS SIP 行为。
- **NAPI 壳依赖 `napi-ohos` 1.2 + `napi-derive-ohos` 1.2 + `napi-build-ohos` 1.2**，`crate-type=["cdylib"]`，
  `build.rs` 调 `napi_build_ohos::setup()`（同 `legado-core`）。

### 14.6 产物形状（可直接比对）

| 产物 | size | NEEDED | 备注 |
|---|---|---|---|
| `libonnxruntime.so.1.24.4` | 27 MB | `libc++_shared.so`, `libc.so` | SONAME `libonnxruntime.so.1`，RUNPATH `$ORIGIN` |
| `libgpt_sovits_tts_ohos.so` | 27 MB | `libace_napi.z.so`, `libc++_shared.so`, `libc.so` | 导出 `napi_register_module_v1`；**无 `libonnxruntime` 直接依赖** |
| `tts-bench`（P4 专用） | 37 MB | 同上 | `rtf` / `stability` / `mem` 三模式，端侧 RTF·内存·长稳 |
| `ort_smoke`（加载冒烟） | 14 KB | `libdl` | dlopen + 版本串 + `GetApi(24)`，**不依赖 ort crate** |

- **设备侧运行**：`LD_LIBRARY_PATH=<dir with libonnxruntime.so> ./ort_smoke <so> 24`。
- **注意 `libc++_shared.so`**：ORT 与 NAPI 壳都是 C++，OHOS 上需一并带上（NDK 自带，
  `native/llvm/lib/aarch64-linux-ohos/c++/libc++_shared.so`），否则 `dlopen` 会因 `NEEDED` 缺失失败。

### 14.7 真机部署通道：只有 `hdc file send -b <bundle>` 一条路（三处硬限制）

P4 的 bundle 是 **1.2 GB**，且 App 要读它、`.so` 要被 `dlopen`，于是踩到三处互相冲突的限制：

| 位置 | shell 可读 | App 可读 | 可 exec |
|---|---|---|---|
| `/data/local/tmp` | ✅ | ❌（SELinux `Permission denied`） | ❌ |
| `data/storage/el2/base/…`（App 沙箱） | ✅ 仅 via `-b` | ✅ | ❌ |
| `/data/storage/el1/bundle/libs/arm64`（HAP 内代码目录） | — | ✅ | ✅ 仅 `dlopen` |

- **结论（P4 实测）**：`hdc shell -b com.lichtcui.sourcereader "cat data/storage/el2/base/tts-p4/probe.txt"` 可读；
  但 `hdc shell "cd /data/local/tmp/tts-p4 && ./ort_smoke"` → **`Permission denied`**。
  `/data` 的挂载是 `nosuid,nodev`（**没有** `noexec`），所以拒绝来自 **SELinux**（`u:r:sh:s0` 不能 exec 这些数据文件）
  ⇒ **设备侧不能命令行驱动** `tts-bench` / `ort_smoke`，一切测量必须经 NAPI + ArkTS（这也解释了 P4 为何没有
  `p3/harness/proc_sampler.py` 那种外部采样：只能 `hidumper` 轮询）。
- **`.so` 的 dlopen 路径只有一处**：`context.bundleCodeDir + "/libs/arm64"`
  （= `/data/storage/el1/bundle/libs/arm64`），所以 ORT 与 NAPI 壳必须**打进 HAP**；
  1.2 GB bundle 则走沙箱普通文件 IO。
- **`-b` 语义**：`hdc file send -b <bundle> <local> <path>` 的 `<path>` 相对 **EL2 base**
  （`/data/app/el2/100/base/<bundle>/`）。`hdc shell -b <bundle>` 的 `id` 仍是 `uid=2000(shell)`,
  `context=u:r:sh:s0`，只是 **cwd 被重映射**到 `/mnt/debug/100/debug_hap/<bundle>` —— 能读沙箱，但仍不能 exec。
- **坑：路径里不要出现 `..`**。`${filesDir}/../../../tts-p4` 这类写法会让 `dlopen` 报 `ENOENT`，
  而 `accessSync` 却返回 `true`（两条路径的规范化不同）。正解：
  `filesDir.replace('/haps/entry/files','') + '/tts-p4'`。

### 14.8 bundleName 与签名 profile 绑定

临时测试 HAP **占用 `com.lichtcui.sourcereader`**（唯一可用的签名 profile 只对该 bundleName 有效），
所以设备上会短暂没有阅读 App。**收尾必须从 App 主仓库重新构建并安装正式 HAP 复原**
（`~/Documents/playground/source-reader`，`master`）。

### 14.9 ArkTS 主线程阻塞 = appfreeze

NAPI 侧合成是**同步阻塞调用线程**的（引擎 `run_async_in_context` → `block_in_place` + `handle.block_on`），
所以 `#[napi]` 函数必须声明 `async`、ArkTS 侧用 `await`；一旦在 UI 线程里同步跑几秒，直接被 appfreeze 杀掉。
本次验收的驱动器（`Index.ets`）全部走 `await`，60 min 长稳期间 UI 未冻结。

### 14.10 `hdc shell` 拿不到的设备信息，以及内存/落核口径

- `/proc/cpuinfo`、`/sys/devices/system/cpu/*/cpufreq/*` 在 shell 域**不可读**（`Permission denied`）
  ⇒ 引擎的 `cpu_info::get_hw_big_cores()` 在端侧**静默 fallback 到硬编码 8 核**，
  这就是「端侧默认 8 个 intra-op 线程 / 6 个小核」的由来（§9 P4 ④ 的线程扫描基于此）。
- **内存口径**：以 `hidumper --mem <pid>` 的 **Total Pss** 为准（本机 `phys_footprint` 的对位）；
  `/proc/<pid>/status` 的 `VmRSS` 会被输出缓冲抬升（同 §13.4），只作辅证。`VmHWM` 可作峰值上界。
- **落核**：`/proc/self/task/<tid>/stat` 第 39 字段（`threadCpus()`）。实测 ORT worker 落 **CPU 4–11**，
  没有被甩到小核簇；`threadUtil ≈ 3.9` 说明 4 线程确实在跑（自旋也算忙）。

### 14.11 电源/屏幕：hdc 驱动的两个硬前提

- **锁屏时 `aa start` 直接失败**：`Error Code:10106102 … The device screen is locked during the application launch`
  （提示"开发者模式下不会自动解锁"）。必须先人工解锁。
- 长跑前：`power-shell timeout -o 7200000`（覆盖息屏时间，单位 ms）+ `power-shell wakeup`。
- `power-shell setmode <600|601|602|603>` = 普通 / 省电 / **性能** / 超级省电。
  本次 **RTF 表用 602，长稳用 600**（贴近日常）。实测两种模式 RTF 差异在噪声内。
- **别用滑动模拟解锁**：从屏幕上部起滑会触发「防误触模式」（proximity），只能在下方滑动两次退出。

### 14.12 `uitest` 驱动要点（复用自 App 仓库 AGENTS.md §4）

`uitest dumpLayout -p /data/local/tmp/l.json -a` → `hdc file recv` 解析 bounds（**物理像素**，本机 1260×2844）
→ `uitest uiInput click x y`。**每次改完 HAP 必须 `aa force-stop` 再 `aa start`**，
否则旧进程继续跑旧 .so（本轮 `-O3` 重建时就靠这条确认切换生效）。

### 14.13 新坑：NAPI 壳的 `opt-level` 会**连带把引擎一起**体积优化（影响端侧 RTF）

`p4/gpt-sovits-tts-ohos/Cargo.toml` 原为 `[profile.release] opt-level = "z"`（照抄 ohos-rs 模板的体积优先）。
**cargo profile 作用于整张依赖图** ⇒ 引擎（分词、G2P、重采样、后处理等 Rust 侧代码）也被 `-Oz` 编译进 `.so`，
而 Mac 侧一直是默认 `-O3`。改为 `opt-level = 3` 后，**固定开销型用例**明显改善
（同口径 perf 模式：`short_zh` 1.658 → 1.570、`baseline_doc` 2.032 → 1.745）。
⇒ 端侧 NAPI 壳**不要**用 `opt-level = "z"`；P4 已改为 `3`。

### 14.14 网络通道：USB 反向共享会抢走 hdc

手机用 **USB 给电脑共享网络**时会占用 USB 数据通道，`hdc list targets` 掉成 `[Empty]`；
改成 **手机 Wi-Fi 热点**（Mac 经 `en0` 连热点）后 hdc 稳定，网络也通。设备掉线后 `hdc kill; hdc start`
**不足以恢复**，需拔插/重新授权。

### 14.15 新坑：改完 NAPI `.so` **必须显式拷进 HAP 的 libs 目录**

`ohos-tts-test/entry/libs/arm64-v8a/libgpt_sovits_tts_ohos.so` 与 `cargo build` 的输出**没有任何自动同步**。
本轮漏拷一次，真机上直接抛：
`SyntaxError: the requested module '@normalized:Y&&&libgpt_sovits_tts_ohos.so&' does not provide an export name 'ttsInitMulti'`
（ArkTS 侧报"没有这个导出"，看起来像 Rust 没编译，实际是 HAP 里还是旧 `.so`）。

- 固定动作：`cp gpt-sovits-tts-ohos/target/aarch64-unknown-linux-ohos/release/libgpt_sovits_tts_ohos.so \
  ohos-tts-test/entry/libs/arm64-v8a/` → 再 `hvigorw assembleHap` → 安装。
- 自查（不用装到设备）：`strings -a <so> | grep "ttsInitMulti first"`，或
  `llvm-nm -D --defined-only`（注意 napi 导出名与 Rust 符号名不同，`strings` 更稳）。

### 14.16 hdc 掉线会**连带丢掉现场**：长跑必须边跑边落盘

09-28 23:5x USB 掉线 → 09-29 07:57 重连，结果：
- App 进程已不在（**原因不可考**：`/data/log/faultlog/{faultlogger,temp}` 对 shell 域 `Permission denied`）；
- `hilog -x -T TTSP4` 环形缓冲已滚掉 ⇒ **23:20 那次 60 min 长稳的终值永久丢失**（只剩掉线前采到的 31 min）。

对策（已落成脚本）：
- 内存/进度**外部轮询并写盘**（`p4/sample_mem.sh` → `stability-mem.tsv`），不要依赖事后读 hilog；
- 长跑前先确认设备不会掉线；一旦出现 `hdc list targets` → `[Empty]`，**当场把 `hilog` 导出到主机**。

### 14.17 新坑：`4;6;8;10` **不是**大核集，绑核比自由调度更慢

单模型扫描里 `global-aff-big`（`4;6;8;10`）曾是"看起来合理"的大核绑定；本轮用多副本并行直接证伪：

| 配置 | 聚合 RTF |
|---|---|
| 2 副本自由调度 | 1.889 |
| 2 副本绑 `4,6` | 2.490（更差） |
| 4 副本自由调度 | 1.483 |
| 4 副本绑 `4,6,8,10` | 2.183（更差） |

同一副本在不同 CPU 上耗时差 ~2×（4.9 s 音频：6.9 s vs 20.4 s）。**结论：不要手写 affinity**，
让内核调度即可；端侧 `/sys/.../cpufreq` 不可读，靠猜 CPU id 一定会猜错。

### 14.18 端侧并行天花板：两条路都 ~1.3–1.7×（**不是**假瓶颈）

- 线程内：`intra1 → intra8` 只 **1.32×**（`threadUtil` 从 1.00 涨到 7.58，8 线程在空转）。
- 分片级：1 → 4 条独立链（每链 1 线程、非自旋、独立池）只 **1.68×**。
  2 副本 free 的 6 片逐片耗时之和 69.4 s、墙钟 37.7 s ⇒ 重叠 1.84×，但每条链自己慢 ~1.4×。
- **排除假瓶颈**：引擎推理路径无全局锁（`grep lazy_static|Mutex` 只剩只读字典/正则 + 建会话期的 `RwLock`），
  `run_async_in_context` 走多线程 `tokio::runtime::Runtime::new()`，
  NAPI 多副本路径各链在独立 OS 线程上 ⇒ 并行是真的，瓶颈是**共享资源争用**。
- 于是端侧 RTF 的**实测下限 = 1.483**（4 副本自由调度），`< 1.0` 不可达 ⇒ 见 TTS-PLAN §9 P4 ⑨ 的结论。

### 14.19 长稳终值与新坑：切后台会被 OHOS 冻结 JS 线程（2026-09-29）

**60 min 长稳终值（重跑闭环，按钮 E = 1 h）**：

```
STAB DONE n=483 wall=3609s audio=1874.8s rtf=1.924 fails=0 guard=0 fb=8 shortEos=0 maxChunkMs=15517
```

- **跑满 60.15 min 未中断**；0 失败 / 0 panic / 0 异常 EOS（`shortEos` 代理指标全程 0）。
- RTF **1.924** 与首轮 31 min 的 1.952 同带 ⇒ **无热降频劣化**；`maxChunkMs=15517`（最坏单片 15.5 s，护栏内）。
- `回退 8/483 = 1.66 %`（`cap=30`、bench 路径 `retry=0`，记 `overLimit`）；metrics 全 0 正常（bench 路径不走守门计数）。
- 内存（`stability-mem.tsv`，10 个采样点）：Total Pss **1.93 → 2.13 GB 平稳**、`VmRSS` ≈2.07–2.29 GB、
  `VmHWM` **2.30 GB 封顶** ⇒ **无 OOM、无增长性泄漏**，「≥1 h 不崩不 OOM」**完整验收通过**。
- 数据链路：终值来自 App 内部 hilog（`TTSP4`），内存来自外部轮询落盘（`sample_mem.sh`，见 §14.16）。

**⚠️ 新坑：切后台会冻结 JS 线程，长稳直接中断**

- **现象**：重跑周期内**把手机拿起/切后台**会触发 `minimizeAllScene`，OHOS 冻结 JS 线程，`STAB` 采样停止，
  长稳中断；9x 分钟空拍浪费一轮。
- **仅唤醒屏幕无害**（`power-shell timeout -o` 保持亮屏即可）；`aa start` 在锁屏时仍报 `10106102`，
  需人工解锁（滑动解锁会触发"防误触模式"，只能人工解锁）——参见 §14.11。
- **对策**：长跑期间**设备静置、切勿拿起或最小化**；进程置前台 + 亮屏 + 性能模式 600，采样边跑边落盘。
