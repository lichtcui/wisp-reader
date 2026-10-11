# ─────────────────────────────────────────────────────────────────────────────
# 常用命令统一入口。用法：`make`（= make help）看全部命令。
#
# 环境/签名/踩坑细节见 docs/development.md；真机验证闭环见 skill `harmony-device-run`。
# 约定：**改完 ArkTS 一律用 `make run`**（只 `aa start` 不会重跑 aboutToAppear）。
# ─────────────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

# 注意：用 `:=` 而不是 `?=`——本机环境里可能已存在 `NDK_HOME`/`SDK` 等同名变量（会被 `?=` 误当成“已定义”
# 而跳过赋值，导致拿错 hdc/NDK）。必须改用 `:=`（命令行 `make HDC=…` 仍可覆盖）。
DEVECO   := /Applications/DevEco-Studio.app
SDK      := $(DEVECO)/Contents/sdk
NDK_HOME := $(SDK)/default/openharmony
HDC      := $(NDK_HOME)/toolchains/hdc
HVIGORW  := $(DEVECO)/Contents/tools/hvigor/bin/hvigorw

BUNDLE   := com.lichtcui.sourcereader
ABILITY  := EntryAbility
HAP      := entry/build/default/outputs/default/entry-default-signed.hap
SO       := entry/libs/arm64-v8a/liblegado_core.so
DTS      := entry/src/main/cpp/types/liblegado_core/index.d.ts
LOG_TAG  := SourceReaderPoC

# hvigorw 依赖 DevEco 自带的 node/ohpm，必须在 PATH 里（否则报找不到 node）。
export DEVECO_SDK_HOME := $(SDK)
export OHOS_NDK_HOME   := $(NDK_HOME)
export PATH := $(DEVECO)/Contents/tools/node/bin:$(DEVECO)/Contents/tools/ohpm/bin:$(PATH)

# hvigor 一律走**常驻 daemon**（默认行为）：编译进程复用，改 1 个 .ets 后重编 **13.1s → 3.5s**
# （2026-10-11 实测；`--no-daemon` 时 ArkTS 编译进程每次冷启多花 ~4.3s）。
# 需要「一次性、干净复现」（如 T-VER-1 那种 clean 构建复验）时：`make hap NO_DAEMON=1`。
DAEMON_FLAG := $(if $(NO_DAEMON),--no-daemon,)

.DEFAULT_GOAL := help
.PHONY: help rust test probe hap hap-release daemon-status daemon-stop install restart run run-release log devices doctor check docs-toc

help: ## 显示所有可用命令
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## ── Rust 引擎 ────────────────────────────────────────────────────────────────

rust: ## 交叉编译 .so 并拷进 entry/libs（首次约 10–15 分钟）
	cd rust/legado-core && ohrs build --arch arm64 --release
	cp rust/legado-core/dist/arm64-v8a/liblegado_core.so $(SO)
	cp rust/legado-core/dist/index.d.ts $(DTS)
	@ls -la $(SO) $(DTS)

test: ## 主机上跑引擎单测（cargo test，不碰真机）
	cd rust/legado-engine && cargo test

probe: ## 主机上直接跑引擎，不上设备（例：make probe ARGS='源.json search 剑来'）
	cd rust/legado-engine && cargo run --release --example probe -- $(ARGS)

## ── HAP ─────────────────────────────────────────────────────────────────────

hap: ## 编译 debug HAP（NO_DAEMON=1 可关 daemon）
	$(HVIGORW) assembleHap --mode module -p product=default -p buildMode=debug $(DAEMON_FLAG)

hap-release: ## 编译 release HAP（含混淆 + 签名）
	$(HVIGORW) assembleHap --mode module -p product=default -p buildMode=release $(DAEMON_FLAG)

daemon-status: ## 查看本项目 hvigor 常驻进程状态
	$(HVIGORW) --status-daemon

daemon-stop: ## 停掉本项目 hvigor daemon（换 SDK / 构建行为诡异时用）
	-$(HVIGORW) --stop-daemon

## ── 真机 ────────────────────────────────────────────────────────────────────

devices: ## 列出已连接设备（UDID）
	$(HDC) list targets

install: ## 安装最新 HAP 到设备
	$(HDC) install -r $(HAP)

restart: ## 只 force-stop + 启动（不重装）；改 ArkTS 后必须走这步
	-$(HDC) shell aa force-stop $(BUNDLE)
	$(HDC) shell aa start -a $(ABILITY) -b $(BUNDLE)

run: hap install restart ## 编译 → 安装 → force-stop → 启动（真机验证闭环）
	@echo "已启动。抓日志： make log"

run-release: hap-release install restart ## 同上但用 release 包（验证混淆 / 备份等只在 release 现形的问题）
	@echo "已启动（release）。抓日志： make log"

log: ## 清日志后实时过滤本应用日志（Ctrl-C 退出；可再用 Q=关键词 筛，如 make log Q=Backup）
	$(HDC) shell hilog -r
	$(HDC) shell hilog -x -T $(LOG_TAG) $(if $(Q),| grep --line-buffered "$(Q)")

## ── 自检 ────────────────────────────────────────────────────────────────────

doctor: ## 自检：.so / index.d.ts / HAP 是否落后于源码 + 设备是否连着
	@scripts/doctor.sh

check: ## 自检文档与契约（行号目录是否过期 / md 失效链接 / JSON 字段是否都进 keep 列表）
	@scripts/docs-toc.sh --check
	@scripts/check-docs-links.sh
	@scripts/check-keep-props.sh

## ── 文档 ────────────────────────────────────────────────────────────────────

docs-toc: ## 重建大文档顶部的行号目录
	scripts/docs-toc.sh
