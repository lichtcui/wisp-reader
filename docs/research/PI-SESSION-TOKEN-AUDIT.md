# pi 会话 token 审计（S10 会话，2026-10-11）

> 素材：原始会话记录 `~/.pi/agent/sessions/--Users-lichtcui-Documents-playground-source-reader--/2026-10-11T03-03-20-358Z_01a128ea-3626-766a-b1ff-69ac6712024b.jsonl`
> （274 行，每行一条 entry；同内容的 HTML 导出件分析后已删除，需要时 `pi --export <session.jsonl>` 重新生成）。
> **一句话结论**：这次会话 **8.85M tokens 里 97% 是「同一份越滚越大的上下文被重发了 118 次」**；
> 要治的是「会话长度 × 轮次数」，不是单个工具的输出大小（output 连 1% 都不到）。
> 项目侧约定已回写 [`../../AGENTS.md`](../../AGENTS.md) §上下文卫生；pi 自身的压缩参数**未改**（见 §6）。

## 1. 取数方法（可复现）

```bash
S=~/.pi/agent/sessions/--Users-lichtcui-Documents-playground-source-reader--/2026-10-11T03-03-20-358Z_01a128ea-3626-766a-b1ff-69ac6712024b.jsonl
python3 - "$S" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    e = json.loads(line)
    u = (e.get('message') or {}).get('usage')
    if u: print(e['timestamp'], u)      # provider 真报数
PY
```

（导出 HTML 的等价取法：`<script id="session-data">` 里是 base64 的同一份 JSON。）

- **token 一律用 `message.usage`（provider 真报）**，不猜。
- 内容体积用「JSON 序列化字符数」只做**相对**比较：中文 markdown ≈ 1.4 字符/token，ASCII/代码 ≈ 3.8。
- 分类方法：按 `role` / `toolName` 聚合 `content` 字符数；增量校验用相邻两次调用的 `input+cacheRead` 差。

## 2. 实测账本

| 项 | tokens | 占比 | 说明 |
|---|---:|---:|---|
| **cacheRead** | **8,578,304** | **97.0%** | 每轮重发的前缀上下文 |
| input（未命中缓存） | 192,798 | 2.2% | 145,962 + 压缩调用 46,836 |
| output | 75,806 | 0.9% | 72,496 + 压缩 3,310；其中 **reasoning 41,445（57%）** |
| **合计** | **8,846,908** | 100% | 119 次 LLM 调用（118 轮 + 1 次压缩） |

会话概况：模型 `apigoto/deepseek-flash`（窗口 128k），03:03:20–03:20:59，**3 条用户消息**，
145 次工具调用（bash 100 / read 27 / edit 13 / fetch 2 / web_search 1 / ask 2）。

**上下文轨迹**（每次调用的 `input+cacheRead`）：

```
call 1  8,402 ──► 峰值 114,746（03:16:41 自动压缩，阈值 128k−16,384=111,616）
        ──► 压缩后 39,229 ──► 会话结束 111,502        平均 72.7k ≈ 窗口 57%
```

**按用户请求分解**（关键表）：

| 用户请求 | 调用数 | cacheRead | 平均上下文 | 占全会话 |
|---|---:|---:|---:|---:|
| ① 检查未完成任务 | 6 | 159,744 | 31,928 | 1.8% |
| ② T-TTS-6 去掉 | 19 | 1,034,240 | 55,166 | 11.7% |
| ③ 剩余任务有不连手机能做的么 | **93** | **7,384,320** | **80,478** | **84.6%** |

## 3. 根因（按可省额度排序）

### 3.1 会话长度没管：③ 背了 ① ② 的 63k 上下文（≈ −57%）

③ 开跑时上下文已经是 **63,276**（① ② 的积累），此后 93 次调用平均 **80,478**。
若 ③ 开新会话（静态前缀 8.4k），在产出内容相同的前提下平均上下文 ≈ `80,478 − (63,276 − 8,402) ≈ 25.6k`
→ 93 × 25.6k ≈ **2.4M**，**省约 5.1M ≈ 全会话 57%**。
→ [`../../AGENTS.md`](../../AGENTS.md) 的「换任务即 `/new`」这次没执行，**这是唯一的大头**。

### 3.2 轮次粒度太粗：1.23 个工具/轮（≈ −30% 调用数）

145 工具 / 118 轮；分布：0 个 3 轮、**1 个 86 轮**、2 个 28 轮、3 个 1 轮。
每次 bash 的边际成本不是它 466 字符（中位）的输出，而是**那一整轮 ~73k 的 cacheRead**；
100 次 bash 里有 8 次输出不足 100 字符，6 次超过 2,000 字符——输出大小与成本几乎无关。

### 3.3 整读大文档：一次 `read TASKS.md` 吃掉 17.6%（≈ −17.6%）

第 2 次调用 `read docs/bugfix/TASKS.md`（**无 limit**）返回 31,360 字符；该文件 76,541 B、
中文 ≈1.4 字符/token → **≈ 22,900 tokens**（第 2 次调用新增的 22,900 全部是它），此后 **68 次重发 ≈ 1.56M**。
而同一请求里第 1 条 bash `rg -n '^- \[[ ~]\] \*\*' docs/bugfix/TASKS.md` 就已经给出答案；
后续又对本文件切片重读 4 次（+25k 字符重复内容）。

### 3.4 空转叙述轮

118 轮里模型写了 222,111 字符可见文本（output 正文 31,051 tokens），其中不少是 9 / 20 / 33 字符的过渡句
（"先读实现，再动手："）。**每写一句都触发一整轮 ~73k 重发**，纯亏。

### 3.5 无用大结果常驻上下文

- `fetch_content` 抓 `github.com/gedoor/legado/raw/.../AnalyzeByElements.kt` 两次 404，
  第二次把 **270KB 的 404 HTML** 截成 32,006 字符留在上下文（≈8k tokens × 剩余 ~30 次 ≈ 0.24M）。
- `web_search` 5 家 provider 返回近重复文档（7,869 字符）；一次查询 + `get_search_content`/`findText` 就够。

### 3.6 静态前缀每次全量重发（天然 11.3%）

system + `AGENTS.md` + skills + docs 路由 = **8,402 tokens/次 × 119 ≈ 1.0M**。
→ `AGENTS.md` 每瘦身 30%，直接省约 3%（但**别为了省 token 砍掉路由信息**，它是省更多 token 的手段）。

## 4. 优化清单

| 动作 | 预估收益 | 落地方式 |
|---|---|---|
| 每个任务 `/new`（或压缩后再换题） | **−57%** | 仓库约定，缺执行 |
| 大中文文档先 `rg -n` 定位再 `read offset/limit` | **−17%** | 仓库约定，缺执行 |
| 每轮并行 2–4 个独立工具调用（定位 + 取段 + 状态检查合并成一轮） | −30% 调用数 | 约定（见 AGENTS.md） |
| 工具之间不叙述，过渡句并入同轮工具调用 | −10% 调用数 | 约定（见 AGENTS.md） |
| fetch 先看状态码；404/HTML 不留上下文；搜索用 `findText` 取段 | −3% | 约定（见 AGENTS.md） |
| 长命令（`make probe/test/hap-release/rust`）后台 + 一次取结果 | 每个省 2–4 轮 | 约定（见 AGENTS.md） |
| 压缩提前（见 §6 JSON） | 上下文长期停在 40–85k 而非 90–115k，≈ −15% | 待定 |
| `defaultThinkingLevel: high` 对机械改动偏高（reasoning 占 output 57%） | <1% | 低优先级 |

## 5. 已回写的项目约定

[`../../AGENTS.md`](../../AGENTS.md) §上下文卫生 新增 4 条：一轮多工具、大文档禁整读（点名 `TASKS.md` 76KB）、
工具间不叙述 + fetch 看状态码、长命令后台化；并把本节实测数字写进「换任务即 `/new`」条目作为依据。

## 6. 待定（未应用）

1. **压缩参数**（`~/.pi/agent/settings.json`）：默认在 `128k − 16,384 = 111,616` 才压缩、压缩后保留 20k，
   导致会话长期停在窗口 65–90%。可考虑：

   ```json
   "compaction": { "reserveTokens": 24576, "keepRecentTokens": 12000 }
   ```

   取舍：压缩更频繁（每次压缩调用本身≈50k tokens，见 §2 的 46,836+3,310），但稳态上下文更小；未实测。
2. **`defaultThinkingLevel: high`** + `hideThinkingBlock: true`：reasoning 41,445 tokens（占 output 57%），
   对「改一行文档」这类任务偏高。因 output 只占总量 0.9%，收益极小，暂不动。
3. **根目录的 1.5MB 导出 HTML**：按 [`../../AGENTS.md`](../../AGENTS.md) 的文档落位约定，根目录只允许
   `AGENTS.md` / `README.md` / `Makefile`；该文件仅为审计素材，**已于 2026-10-11 删除**
   （原始 session 记录仍在 `~/.pi/agent/sessions/`，可随时重新导出）。
