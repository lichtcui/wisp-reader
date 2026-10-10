# 中文原神／星铁音色到底有没有公开模型（T-TTS-6 调研）

> 起因：`v2.0.0` 换成 VITS 后仍被反馈「听着还是像外国人说话」。上一轮（[`TTS-ENGINE-COMPARISON.md`](./TTS-ENGINE-COMPARISON.md) §10）的结论是
> 「可用的纯中文模型只有 `melo` / `fanchen-C`」，用户追问 **①「是不是真的找不到中文的原神角色模型？」②「有没有办法在这台 Mac 上自己训练？」**
> 本文回答这两问，并给出上一轮结论需要修正的地方。引擎/管线的其余细节见 [`TTS-ENGINE-COMPARISON.md`](./TTS-ENGINE-COMPARISON.md)，部署见 [`../remote-tts-deploy.md`](../remote-tts-deploy.md)。

<!-- TOC:BEGIN -->
- 0. 结论先行 — L20
- 1. 上一轮为什么得出「找不到」——那是「sherpa 能跑的」口径 — L29
- 2. 现用 804 模型**本来就是原神模型**（新证据） — L35
- 3. 但它仍然出不了母语普通话（三次评测证据） — L67
- 4. 公开的中文原神／星铁模型清单 — L85
  - 4.1 ModelScope `aihobbyist/GPT-SoVITS_Model_Collection` —— **最全，可直接下载** — L87
  - 4.2 其余来源（多为「模型已下架」或非 TTS） — L113
- 5. GPT-SoVITS 在 CPU 上有多慢（RTF≈4.5 的证据链） — L124
- 6. 这台 Mac 能不能自己训练 — L136
- 7. 可选路线与推荐顺序 — L154
- 8. 复现入口 — L167
- 9. 参考 — L179
<!-- TOC:END -->

## 0. 结论先行

1. **找得到** —— 中文原神 / 星铁语音模型有**很多**，上一轮说「没有」是口径错误：那是「sherpa-onnx 直接能跑的」口径。见 §4。
2. **但都不能进现有 CPU 管线**：公开的中文原神模型全是 **GPT-SoVITS** 格式，sherpa-onnx 不支持；而 GPT-SoVITS 在这台 4C VPS 上 **RTF ≈ 4.5**（§5），**与「RTF < 1」硬约束直接冲突**。唯一的纯 VITS 原神模型（`TimeRainStarSky/GenshinVoice`，51 角色）**已停止发布**，只留数据集。
3. **新证据：现用的 804 模型本身就是原神模型**（训练集名 `uma_genshin_genshinjp_bh3`，sid 92–230 = 原神中文 144 角色，含钟离/甘雨/胡桃/刻晴/雷电将军/魈/派蒙/可莉…）。见 §2。
4. **但换了正确 sid 也没救**：用 §2 的表重测，CER 从 12.62% 变成 **14.36%（更差）**，且 F0 与角色对不上 → **口音来自「中/日混训」的模型基座 + `zh_ja_mixture_cleaners`，与 sid、词典、导出都无关**。§10 of [`TTS-ENGINE-COMPARISON.md`](./TTS-ENGINE-COMPARISON.md) 的这个结论**站得住**。
5. **这台 Mac 不能自训**（§6）：`MacBookPro16,2` = Intel i5-1038NG7 + Iris Plus，**无 CUDA、也无 Apple Silicon 的 MPS**；GPT-SoVITS 与 VFFT 都要求这类 Mac 只能 CPU **推理**。替代是租 GPU。
6. 建议的下一步见 §7：**先做声纹匹配验证 `fanchen-C` 的 187 个声线**（零成本，若命中则直接得到「中文原神 + RTF 0.462」）。

## 1. 上一轮为什么得出「找不到」——那是「sherpa 能跑的」口径

`TTS-ENGINE-COMPARISON.md` §10 筛的是「能导成 sherpa-onnx ONNX 且 RTF < 1」的模型，于是在 HF 上只捞到
`fanchen-C`(187 说话人) / `melo`(1) / `theresa`·`eula`(804) / `vits-zh-ll`(5) / `aishell3`(174) / `kokoro`。
本文把口径放宽到「只要存在」，结论立刻不同 —— 见 §4。教训：**筛选口径必须写进结论**，否则「找不到」会被误读成「不存在」。

## 2. 现用 804 模型**本来就是原神模型**（新证据）

线上模型 `vits-hf-zh-jp-zomehwh.onnx` 的来源是 HF Space `lkz99/tts_model` 的 `zh_japanese/G_CJ`，
其 `G_CJ.json` 里写着（**关键**）：

```
n_speakers : 804          sampling_rate : 22050
text_cleaners : ["zh_ja_mixture_cleaners"]
training_files : "filelists/uma_genshin_genshinjp_bh3_train.txt.cleaned"
```

即 **804 = 马娘(Uma) + 原神中文 + 原神日文 + 崩坏3**，且用的是**中日混合 cleaner**。

同仓库另有 `zh/G_C.json`（= `fanchen-C`）：`n_speakers 187`、`sampling_rate 16000`、`chinese_cleaners`、`filelists/train.txt.cleaned`
—— 命名 `C` / `CJ` / `CJE` 是同族（`C`=中、`CJ`=中+日、`CJE`=中+日+英）。

**sid → 角色名对照表**（社区公开发布，用于 `G_trilingual.pth` / `configs/uma_trilingual.json`，同一 804 说话人谱系）：

| sid 段 | 内容 |
|---|---|
| 0–91（有空洞） | 赛马娘 Uma |
| **92–230** | **原神中文 144 角色**：九条裟罗92 / 芭芭拉93 / **派蒙94** / 荒泷一斗96 / 早柚97 / 香菱98 / 神里绫华99 / 重云100 / 流浪者102 / 优菈103 / 凝光105 / **钟离106** / **雷电将军107** / 枫原万叶108 / 赛诺109 / 诺艾尔112 / 八重神子113 / 凯亚114 / **魈115** / 托马116 / 可莉117 / 迪卢克120 / 夜兰121 / 鹿野院平藏123 / 辛焱124 / 丽莎125 / 云堇126 / 坎蒂丝127 / 罗莎莉亚128 / 北斗129 / 珊瑚宫心海132 / 烟绯133 / 久岐忍136 / 宵宫139 / 安柏143 / 迪奥娜144 / 班尼特146 / 雷泽147 / 阿贝多151 / 温迪152 / 空153 / 神里绫人154 / 琴155 / 艾尔海森156 / 莫娜157 / 妮露159 / **胡桃160** / **甘雨161** / 纳西妲162 / **刻晴165** / 荧169 / 埃洛伊179 / 柯莱182 / 多莉184 / 提纳里186 / 砂糖188 / 行秋190 / 奥兹193 / 五郎198 / 达达利亚202 / 七七207 / 申鹤217 / 莱依拉228 / 菲谢尔230 |
| 231–803 | 崩坏3 |

> 顺带修正：上一轮做 F0 对比时用的 sid `{104,101,94,111,115,119,125}` 里，**104 / 101 / 111 / 119 在新表里根本没有名字**（是空洞号），
> 所以 `TTS-ENGINE-COMPARISON.md` §6 的那组「钟离 121.4 Hz / 甘雨 271.8 Hz」标签**是错的**（`94` 实为派蒙、`115` 实为魈、`125` 实为丽莎）。
> 那组 F0 数值本身仍是实测，只是**名字对不上**，不要再引用。

**另一个旁证**：线上模型的 `tokens.txt` 只有 **52 个 token**（`_ , . ! ? - ~ …` + 拉丁字母 + `ʃ ʧ ʦ ɯ ɹ ə ɥ ⁼ ʰ \` → ↓ ↑`），
**没有 `[ZH]` / `[JA]` 语言 token**；而社区推理代码是先按语言把文本包成 `[ZH]…[ZH]` 或 `[JA]…[JA]` 再喂给 `uma_trilingual` 模型。
sherpa 导出把这个语言开关丢掉了 → 中/日两条音素路径**无法区分**。

## 3. 但它仍然出不了母语普通话（三次评测证据）

裁判 = 中文 ASR（paraformer-zh）回译算 CER，20 句、`speed=0.85`、同一批文本（方法学与局限见 `TTS-ENGINE-COMPARISON.md` §10）。

| 测试 | sid | 平均 CER | 结论 |
|---|---|---|---|
| 上一轮（错 sid） | 104 / 111 / 119 | **12.62%** | 疑为抽到未命名空洞号 |
| **本轮（正确原神 sid）** | **106 钟离 / 161 甘雨 / 160 胡桃 / 165 刻晴 / 107 雷电将军 / 115 魈** | **14.36%** | **更差；换 sid 无效** |

逐 sid：钟离 14.12% / 甘雨 13.28% / 胡桃 10.17% / 刻晴 15.25% / 雷电将军 15.54% / 魈 17.80%（RTF 0.492–0.522，全部 < 1）。

同时 **F0 与角色对不上**（粗略自相关估计）：钟离 259 Hz、甘雨 155 Hz、刻晴 113 Hz、魈 251 Hz
—— 钟离（低沉男声）比甘雨（女声）还高一个八度，说明**这张 sid 表对不上我们的权重**，或者该权重的说话人顺序本就与 `G_trilingual` 不同。

**两条结论**：
1. **`804 家族（zomehwh / theresa / eula / G_CJ）不要继续投入** —— 中/日混训的基座决定了它出不了干净的普通话，与 sid、词典（已修）、导出姿势都无关。
2. **`fanchen-C`（`G_C`，纯中文 187 说话人，CER 4.80%、RTF 0.462）仍是 sherpa 侧唯一有戏的候选**；它的 187 个声线**是否是原神角色尚未验证**（见 §7 路线 A）。

## 4. 公开的中文原神／星铁模型清单

### 4.1 ModelScope `aihobbyist/GPT-SoVITS_Model_Collection` —— **最全，可直接下载**

| 目录 | 角色数 | 体积 |
|---|---|---|
| `原神/中文` | **263** | **56.1 GB** |
| `星穹铁道/中文` | **118** | 36.0 GB |
| `原神/{日语,英语,韩语}` + 其余游戏（妮姬/崩坏三/明日方舟/绝区零/蔚蓝档案/鸣潮） | — | 原神共 877 文件 |

- **重点角色 40/40 全部在库**：钟离、甘雨、胡桃、刻晴、雷电将军、魈、迪卢克、派蒙、可莉、纳西妲、八重神子、温迪、神里绫华、宵宫、夜兰、芙宁娜、那维莱特、枫原万叶、流浪者、艾尔海森、妮露、珐露珊、闲云、千织、希诺宁……
- **星铁侧含 `流萤` / `花火` / `卡芙卡`** —— 正是 App 最初选定的三个音色。
- 作者：**红血球AE3803** 与 **白菜工厂1145号员工**（后者另有 CPU 推理专版 `baicai-1145/GPT-SoVITS-CPUFast`）；License **CC-BY-NC**。
- **VPS 可直连 ModelScope**（实测 HTTP 200 / 0.54 s），下载很快：`钟离_ZH.zip`（213,263,292 B）18.8 s，`流萤.zip`（305,018,327 B）25.9 s。

**包内结构**（已实测解包）：

```
v4/钟离_ZH/                       # 流萤 是 v2ProPlus/流萤/
  ├── 钟离_ZH-e10.ckpt         155,312,893 B   # GPT (s1)
  ├── 钟离_ZH_e10_s990_l32.pth  75,549,998 B   # SoVITS (s2)
  ├── train.log
  └── reference_audios/中文/emotions/           # 6 段带情绪标签的中文参考音频
        【默认】不用担心，我刚刚看过周围，没有其他危险。.wav   369,068 B
```

> **参考音频是白送的关键资产**：6 段/角色、**中文**、带情绪标签。它同时是 ① GPT-SoVITS 的推理 prompt，② ZipVoice 零样本克隆的 prompt，③ **声纹匹配（§7 路线 A）的基准**。

### 4.2 其余来源（多为「模型已下架」或非 TTS）

| 来源 | 内容 | 状态 |
|---|---|---|
| Gitee `TimeRainStarSky/GenshinVoice`（= GitHub `DeSireFire/genshin_vits` / `w4123/vits`） | **纯 VITS** 原神 **51 角色**（派蒙/钟离/魈/甘雨/胡桃/刻晴…），曾有公开 API + 可视化合成 | **模型与 API 均已停止发布**（README：20221108 起不再提供），只留数据集 |
| GitHub `w4123/GenshinVoice` | 上一行作者整理的**中文原神数据集** | 可自训 |
| HF `jzsues/genshin-voice-zh`（7×parquet ≈ 27 GB）、`hanamizuki-ai/genshin-voice-v3.4-mandarin`、`OpenSpeechHub/Genshin-Voice`、`greensea/GenshinVoice`（78,426 条） | 中文原神数据集 | 可自训 |
| HF `NyaNyaBOSS/Genshin_MB_VITS_CJE` | VITS 权重 `G_181400.pth`(455 MB) + `D_181400.pth`，`config.json` 里 `training_files: filelists/genshin_train_01.txt.cleaned`、`n_speakers 55`、`sr 22050`、`cjke_cleaners2` | 可用，但只有 55 个说话人且**无名字**；这是「`G_` 前缀 = Genshin」的旁证 |
| HF `ArkanDash/rvc-genshin-impact`、`lazyboy450/RVCv2-Genshin`、`kaze-mio/so-vits-genshin` 等 | **变声（RVC / so-vits-svc）**，不是 TTS | 需「中文 TTS + 变声」两段式 |
| HF `BigPancake01/GPT-SoVITS_Mihoyo` | GPT-SoVITS，7 角色（Ayaka/Klee/Nahida/Firefly…），语言未标注 | 可用 |

## 5. GPT-SoVITS 在 CPU 上有多慢（RTF≈4.5 的证据链）

| 来源 | 硬件 | RTF |
|---|---|---|
| 中文技术博客实测表（v3 默认参数，10 s 语音） | **i5-8250U**（4C/8T，与 VPS 的 Xeon 8173M 同档） | 45 s → **4.5** |
| 同上 | i3-7100U 4GB / Atom N450 2GB | 8.8 / 19.2 |
| GPT-SoVITS 官方 README（v2ProPlus） | **M4 CPU** | **0.526** |
| GPT-SoVITS-CPUFast（同一训练者的 CPU 专版） | 相对上游 | −45%（端到端 `zh_pure` 15.14 s → 8.31 s） |

**判定**：M4 单核约为本机 Xeon 8173M 的 3 倍，4C 对 10 核；即使按最乐观的 CPUFast 再打 55 折，**本 VPS 上 GPT-SoVITS 的 RTF 也在 1.5–2.5 之间**，过不了硬约束。
**要上 GPT-SoVITS 就必须换 GPU 服务器**（4060Ti 级 RTF 0.028，即算力余量 >30×，成本是唯一取舍）。

## 6. 这台 Mac 能不能自己训练

**不能（就现实可行的口径而言）**。硬件事实：

| 项 | 值 |
|---|---|
| 机型 | `MacBookPro16,2` = 2020 款 13" Intel Mac |
| CPU | Intel Core i5-1038NG7 @ 2.00 GHz（Ice Lake，4P+4E） |
| GPU | **Intel Iris Plus Graphics**（Metal 3）——**无 NVIDIA CUDA、无 Apple Silicon 的 MPS** |
| 内存 / 磁盘 | 16 GB / 可用 139 GiB |
| Python | `python3.11` / `python3.12` 可用；**未装 torch** |

- MPS 后端**只支持 Apple Silicon 或 AMD GPU**，Iris Plus 不在内 → 只能纯 CPU。
- GPT-SoVITS 与 Plachtaa VFFT 的官方说明都写明：**非 Apple Silicon / AMD 的 Mac 只能用 CPU 推理，不提供 CPU 训练路径**（这也是社区要另开 `GPT-SoVITS-CPUFast` 这类「只留推理」分支的原因）。
- 估算：VFFT 单角色（~100 条、1–2 万步）在 2080Ti 上约 45 min；换 4C 低压 CPU 约 **30–60×** → **20–50 h/角色**，且 16 GB 内存在 BERT/HuBERT 特征提取阶段偏紧。

**替代**：① 租 GPU（AutoDL / 云厂商，T4~4090 约 **¥1–2/h**，单角色 ~1 h）② 直接用 §4 的现成模型 ③ 本 VPS 硬跑（几十小时/角色，不现实）。

## 7. 可选路线与推荐顺序

| 路线 | 做法 | 成本 | 风险 |
|---|---|---|---|
| **A（首选，零成本）** | **声纹匹配**：用 §4.1 的**中文参考音频**（钟离/甘雨/胡桃/刻晴/雷电将军…）做声纹，与 `fanchen-C` 的 **187 个 sid** 合成样本比对，找出「fanchen-C 的哪个 sid = 哪个角色」 | 0（要加一个中文说话人 embedding ONNX，sherpa 自带 `SpeakerEmbeddingExtractor`，3D-Speaker/Wespeaker zh 约 26–90 MB，hf-mirror 可下） | 若 `fanchen-C` 的 187 声线并非原神档（F0 分布 144 女/24 男/19 中性，更像 Plachtaa VFFT 底模「原神 + VCTK」的泛二次元集合），则匹配不到 |
| B | **ZipVoice 零样本克隆**：已装、已在线过、RTF 0.83，把 §4.1 的中文参考音频当 prompt → 口音问题自动消失（它本来就是中文 prompt） | 0 | 复现当初被否的「杂音」（few-step flow matching）；且 RTF 余量小 |
| C | **租 GPU 跑 GPT-SoVITS**，接 ModelScope 中文原神/星铁模型（含流萤/花火/卡芙卡） | ¥1–2/h（24×7 约 ¥700/月） | 音色最好、工程最重；API 契约要重写 |
| D | **租 GPU 自训 VITS**：中文原神数据集（§4.2）→ VFFT 训练 → 导 ONNX **回灌 sherpa** | 一次性 ~1 h/角色 + 下载 27 GB 数据 | 长期最优（音色可控 + RTF 0.46），但需训练工程 |
| ✗ | 继续换 804 导出（theresa/eula/其它） | — | §3 已证无效 |
| ✗ | 在本 Mac 或本 VPS 上自训 | — | §6 已证不可行 |

**推荐**：先跑 **A**（今天就能出结论，且不需要动线上服务）→ 命中即收工；不命中再按预算选 **B** 或 **C/D**。

## 8. 复现入口

| 动作 | 命令 / 位置 |
|---|---|
| 本轮的「正确 sid」重测 | VPS `/root/tts/genshin-vits/cer_gen.py`（→ `/root/tts/models/cer_gen_sids.json`，日志 `/tmp/cergen.log`） |
| 上一轮的 CER 大表 | VPS `/root/tts/genshin-vits/cer_eval.py`（→ `cer_result.json`） |
| 原神/星铁模型清单 | `curl -s "https://www.modelscope.cn/api/v1/models/aihobbyist/GPT-SoVITS_Model_Collection/repo/files?Revision=master&Recursive=true&Root=原神/中文"` |
| 下载一个角色包 | VPS `/root/tts/dlchars.sh`（已下 `钟离_ZH.zip` / `流萤.zip` 到 `/root/tts/gsv/`） |
| 说话人表原始出处 | `DeSireFire/genshin_vits` README（`configs/uma_trilingual.json` 对应的 `speakers` 字典） |

**环境依赖**：`cer_*.py` 依赖 VPS 上已装的 `sherpa-onnx 1.13.8`；FST 在 `/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/{date,number,phone}.fst`；jieba 词典在 `/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/dict/`；ASR（paraformer-zh）在 `/root/tts/models/asr/`。

## 9. 参考

1. ModelScope `aihobbyist/GPT-SoVITS_Model_Collection`（原神 263 中文角色 / 星铁 118）
2. HF Space `lkz99/tts_model`（`zh/G_C`、`zh_japanese/G_CJ`、`zh_japanese_en/G_CJE`）
3. GitHub / Gitee `TimeRainStarSky/GenshinVoice`、`DeSireFire/genshin_vits`、`w4123/vits`（纯 VITS 原神 51 角色 + 数据集）
4. GitHub `baicai-1145/GPT-SoVITS-CPUFast`（CPU 推理专版）与 GPT-SoVITS 官方 README 的 CPU RTF 数据
5. 中文技术博客的 CPU 推理实测表（i5-8250U 10 s → 45 s）
6. HF `NyaNyaBOSS/Genshin_MB_VITS_CJE`、`BigPancake01/GPT-SoVITS_Mihoyo`、`jzsues/genshin-voice-zh`
7. Plachtaa `VITS-fast-fine-tuning`（底模说明：原神数据集 + VCTK）
