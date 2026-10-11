# P4 续跑说明（2026-09-29 08:2x 交接）

## 现在的状态
- **P4 已全部收尾**：60 min 长稳终值已拿到并回填（TTS-PLAN §9 ⑧⑨、报告 §14.19），唯一未闭环项已闭环。
- **设备不在线**（`hdc list targets` → `[Empty]`）；阅读 App 复原待设备重连后：`hdc install -r`。
- **设备在线**：`33Z0224424136564`（HBN-AL80 / OHOS 6.1.1.120 / API 24）。屏保已覆盖 2 h、性能模式 **602**。
- **设备上装的是测试 HAP**（`p4/ohos-tts-test`，占用 `com.lichtcui.sourcereader`，按钮 A–H）；
  **阅读 App 尚未复原**（收尾要从 `~/Documents/playground/source-reader` 重装）。
- 沙箱数据完好：`data/storage/el2/base/tts-p4/`（bundle 1.2 GB + libs 55 MB）。
- 文档已回填：`source-reader-tts/TTS-PLAN.md` §9 P4 ④–⑨、`docs/tts-p0-report.md` §14.7–§14.18。**未 commit。**

## 已完成（结论已定，不要重做）
| 项 | 结果 |
|---|---|
| 端侧 RTF 单流（`cap=30`） | 1.570 / 1.745 / 1.926 / 1.884，ALL **1.881**（>1.0，验收未达标） |
| 归因 | 固定开销与 Mac **1.00×**；每语义 token **1.82×**（`ms = 884 + 73.81·sem`）⇒ 全在 T2S 自回归环 |
| 线程内并行 | 1→8 线程 **1.32×**（调优无效，7 档扫描） |
| 分片级并行（多副本） | 2 副本 1.889 / 4 副本 **1.483** ⇒ 上限 1.68×，端侧 RTF 下限 **1.483** |
| 内存 | Pss 1.95→1.99 GiB 平稳，`VmHWM` 2.13 GiB 封顶（31 min 采样） |
| 守门阶梯 | 强制触发链路可用；自然命中 1.9%（1/54）；**重试成功率 0/3** |

## ✅ 60 min 长稳终值（已闭环，2026-09-29 10:50）
```
STAB DONE n=483 wall=3609s audio=1874.8s rtf=1.924 fails=0 guard=0 fb=8 shortEos=0 maxChunkMs=15517
```
- 跑满 60.15 min 未中断；0 失败 / 0 panic / 0 异常 EOS；Pss 1.93→2.13 GB 平稳、VmHWM 2.30 GB 封顶。
- 数据与坑（切后台冻结 JS 线程）已回填：TTS-PLAN §9 ⑧⑨、报告 §14.19；原始日志/内存序列归档在 `archive/`。

~~首轮（09-28 23:20）跑到 31 min 时 USB 掉线，终值丢失（进程已不在、hilog 已滚）。重跑成功，无需再跑。~~

重跑步骤（留档备查，按钮 E = 1 h）：
```bash
export PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
hdc install -r ~/Documents/playground/tts/p4/ohos-tts-test/entry/build/default/outputs/default/entry-default-signed.hap
hdc shell "power-shell timeout -o 7200000"; hdc shell "power-shell setmode 600"
hdc shell "aa force-stop com.lichtcui.sourcereader"; hdc shell "hilog -r"
hdc shell "aa start -a EntryAbility -b com.lichtcui.sourcereader"   # 需先人工解锁屏幕！
# 点 E（坐标 630 940，若多改了按钮要重新 dumpLayout 定位）
cd ~/Documents/playground/tts/p4 && OUT=$PWD/stability-mem.tsv INTERVAL=240 COUNT=16 ./sample_mem.sh &
# 每 15 min 把 hilog 导出到主机（掉线会丢现场）：
hdc shell "hilog -x -T TTSP4" > p4/logs/stab-$(date +%H%M).log
```
终值看 `STAB DONE n=… wall=… audio=… rtf=… fails=… guard=… fb=… shortEos=…`，
回填 TTS-PLAN §9 P4 ⑧ 与 ⑨。

## 收尾（长稳跑完再做）
1. 复原阅读 App：`cd ~/Documents/playground/source-reader`（`master`）→ 按其 `AGENTS.md` §4
   构建 + `hdc install -r`（等设备重连）。
2. ~~回填 §9 P4 ⑧ 终值~~ ✅ 已完成；方向决策待拍板后写进 §9 ⑨ 与 §7。

## 环境坑（本轮踩过，别再踩）
- 锁屏时 `aa start` 报 `10106102 screen is locked`；**滑动解锁会触发"防误触模式"**，只能人工解锁。
- 改完 `.so` 必须拷进 `ohos-tts-test/entry/libs/arm64-v8a/` 再打 HAP（见报告 §14.15）。
- 别手写 affinity（`4;6;8;10` 不是大核，见 §14.17）。
- 设备侧**不能 exec** 二进制（SELinux），一切测量走 NAPI + ArkTS；bundle 只能 `hdc file send -b`。
- Mac（4 核共享机）只采信 `load1 < 4` 的窗口；跑完 `pkill -f tts-bench`。
