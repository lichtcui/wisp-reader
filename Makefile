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

.DEFAULT_GOAL := help
.PHONY: help rust test hap hap-release install restart run log devices docs-toc

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

## ── HAP ─────────────────────────────────────────────────────────────────────

hap: ## 编译 debug HAP
	$(HVIGORW) assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

hap-release: ## 编译 release HAP（含混淆 + 签名）
	$(HVIGORW) assembleHap --mode module -p product=default -p buildMode=release --no-daemon

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

log: ## 清空日志后实时过滤本应用日志（Ctrl-C 退出）
	$(HDC) shell hilog -r
	$(HDC) shell hilog -x -T $(LOG_TAG)

## ── 文档 ────────────────────────────────────────────────────────────────────

docs-toc: ## 重建大文档顶部的行号目录
	scripts/docs-toc.sh
