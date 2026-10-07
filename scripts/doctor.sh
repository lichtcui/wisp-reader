#!/usr/bin/env bash
# 自检：回答「设备上跑的到底是不是我刚改的东西？」（= make doctor）
#
# 覆盖三类常被误判的「改了没生效」：
#   1) Rust 改了但没重编 .so（或没把 index.d.ts 拷到 entry/）
#   2) ArkTS/资源改了但没重编 HAP（`make run` 会自动做）
#   3) 设备没连（`make run` 其实什么也没装）
#
# 退出码：有 ✗ 则 1（⚠ 只是提醒，不影响退出码）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVECO="${DEVECO:-/Applications/DevEco-Studio.app}"
HDC="${HDC:-$DEVECO/Contents/sdk/default/openharmony/toolchains/hdc}"
BUNDLE="${BUNDLE:-com.lichtcui.sourcereader}"
SO=entry/libs/arm64-v8a/liblegado_core.so
DTS=entry/src/main/cpp/types/liblegado_core/index.d.ts
DIST_DTS=rust/legado-core/dist/index.d.ts
HAP=entry/build/default/outputs/default/entry-default-signed.hap
LIB_RS=rust/legado-core/src/lib.rs

FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$1"; }

newer_than() { # newer_than <参考文件> <找什么…>
  local ref="$1"; shift
  find "$@" -newer "$ref" -print -quit 2>/dev/null
}

echo "── Rust 引擎产物 ────────────────────────────────"

if [ ! -f "$SO" ]; then
  bad "$SO 不存在 → make rust"
else
  # 只看会影响 .so 的源码（src/**），examples/、tests/、benches/ 不影响引擎产物。
  stale="$(newer_than "$SO" rust -name '*.rs' -path '*/src/*' -not -path '*/target/*' -not -path '*/dist/*')"
  if [ -n "$stale" ]; then
    bad "$SO 落后于源码（如 ${stale}）→ make rust（否则真机跑的是旧引擎）"
  else
    ok "$SO 比全部 rust/*/src/**/*.rs 新（$(stat -f '%Sm' -t '%m-%d %H:%M' "$SO")）"
  fi
fi

if [ ! -f "$DTS" ]; then
  bad "$DTS 不存在 → make rust"
elif [ -f "$LIB_RS" ] && [ "$LIB_RS" -nt "$DTS" ]; then
  bad "$DTS 落后于 ${LIB_RS}（NAPI 契约真源）→ make rust"
elif [ -f "$DIST_DTS" ] && ! cmp -s "$DIST_DTS" "$DTS"; then
  bad "$DTS 与 $DIST_DTS 内容不一致 → make rust（勿手改 entry 侧）"
else
  ok "$DTS 与 Rust 契约同步"
fi

echo "── ArkTS 产物 ──────────────────────────────────"
if [ ! -f "$HAP" ]; then
  bad "$HAP 不存在 → make hap"
else
  stale="$(newer_than "$HAP" entry/src/main/ets entry/src/main/resources entry/src/main/module.json5)"
  if [ -n "$stale" ]; then
    warn "HAP 落后于 $stale → make run（改了没编译）"
  else
    ok "$HAP 比 ets/资源新（$(stat -f '%Sm' -t '%m-%d %H:%M' "$HAP")）"
  fi
fi

echo "── 设备 ────────────────────────────────────────"
if [ ! -x "$HDC" ]; then
  warn "找不到 hdc（${HDC}）；设 HDC=… 或用 DevEco 自带 env"
else
  targets="$("$HDC" list targets 2>/dev/null | grep -v '\[Empty\]' | grep -v '^[[:space:]]*$' || true)"
  if [ -z "$targets" ]; then
    warn "没有已连接设备 → make run 不会真的安装/启动（插线后重跑）"
  else
    ok "设备：$(echo "$targets" | tr '\n' ' ')"
    ver="$("$HDC" shell bm dump -n "$BUNDLE" 2>/dev/null | grep -m1 -o '"versionName"[: ]*"[^"]*"' || true)"
    if [ -n "$ver" ]; then
      ok "设备上已装：$ver"
    else
      warn "设备上查不到 ${BUNDLE}（没装过？）"
    fi
  fi
fi

echo "── 文档 / 契约（详细输出见 make check）──────────"
scripts/docs-toc.sh --check > /dev/null 2>&1 && ok "大文档行号目录最新" || warn "行号目录过期 → make docs-toc"
scripts/check-keep-props.sh > /dev/null 2>&1 && ok "JSON 字段名都进了混淆 keep 列表" || warn "keep 列表缺字段 → make check 看详情"

echo
if [ "$FAIL" = "1" ]; then
  echo "结论：有阻断项（✗），先修上面标 ✗ 的再上真机。"
  exit 1
fi
echo "结论：没有阻断项。"
