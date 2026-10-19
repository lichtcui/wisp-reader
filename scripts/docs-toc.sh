#!/usr/bin/env bash
# 重建大文档顶部的「行号目录」。
#
# 用法：
#   scripts/docs-toc.sh                  # 重建下面 FILES 里列出的全部文档（= make docs-toc）
#   scripts/docs-toc.sh docs/plan.md     # 只重建指定文档
#   scripts/docs-toc.sh --check          # 只检查目录是否过期（不改任何文件，过期则退出码 1）
#
# 约定：
#   - 目录内容必须夹在 `<!-- TOC:BEGIN -->` 与 `<!-- TOC:END -->` 两行之间（这两行本身不动）。
#   - 条目来自 `## ` 标题；若该文件的 `## ` 条目 ≤ 30 条，同时收录 `### `（缩进为二级）。
#     归档类大文件（`## ` 很多）只列 `## `，免得目录本身变成噪音。
#   - `docs/archive/ARCHIVE-S3-S8.md` 不在本列表里：它的分节标题是 H1且文件内还有代码块
#     注释（`# cargo test …`）会污染自动索引，改用文件头部的手写固定索引（已冻结）。
#   - 行号是「生成时的快照」。改完文档跑一次 `make docs-toc` 即可，**不要再手改目录行号**。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
  shift
fi
BAD=0
TOC_TMP=""
OUT_TMP=""

cleanup_temps() {
  if [ -n "$TOC_TMP" ]; then rm -f "$TOC_TMP"; fi
  if [ -n "$OUT_TMP" ]; then rm -f "$OUT_TMP"; fi
}
trap cleanup_temps EXIT

# 需要重建目录的文档。ARCHIVE-S3-S8.md 不在内（用手写固定索引，见下）。
FILES=(
  docs/plan.md
  docs/progress.md
  docs/archive/PROGRESS-HISTORY.md
  docs/archive/SHELF-EDIT-PLAN.md
  docs/research/TTS-ENGINE-COMPARISON.md
  docs/research/TTS-VOICE-SOURCES.md
  docs/research/TTS-PREGEN-PLAN.md
  docs/research/TTS-PREGEN-IMPL.md
)
if [ "$#" -gt 0 ]; then
  FILES=("$@")
fi

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "跳过（文件不存在）: $f" >&2
    continue
  fi
  if ! grep -q '<!-- TOC:BEGIN -->' "$f"; then
    echo "跳过（没有 <!-- TOC:BEGIN --> 标记）: $f" >&2
    continue
  fi

  h2="$(grep -c '^## ' "$f" || true)"
  toc="$(mktemp "${f}.toc.XXXXXX")"
  TOC_TMP="$toc"
  out="$(mktemp "${f}.toc-out.XXXXXX")"
  OUT_TMP="$out"

  # 「## 目录…」这一节自身不进目录。
  if [ "$h2" -le 30 ]; then
    awk '/^## 目录/ {next}
         /^## /   {printf "- %s — L%d\n", substr($0, 4), NR; next}
         /^### /  {printf "  - %s — L%d\n", substr($0, 5), NR; next}' "$f" > "$toc"
  else
    awk '/^## 目录/ {next}
         /^## /   {printf "- %s — L%d\n", substr($0, 4), NR}' "$f" > "$toc"
  fi
  n="$(wc -l < "$toc" | tr -d ' ')"

  awk -v toc="$toc" '
    /<!-- TOC:BEGIN -->/ { print; while ((getline line < toc) > 0) print line; skip = 1; next }
    /<!-- TOC:END -->/   { skip = 0; print; next }
    skip { next }
    { print }
  ' "$f" > "$out"

  # Never replace a document with a truncated result, even if a future edit
  # to the extraction logic (or an interrupted run) silently loses its body.
  begin_count="$(grep -cF '<!-- TOC:BEGIN -->' "$out" || true)"
  end_count="$(grep -cF '<!-- TOC:END -->' "$out" || true)"
  h2_after="$(grep -c '^## ' "$out" || true)"
  if [ "$begin_count" != "1" ] || [ "$end_count" != "1" ] || [ "$h2_after" != "$h2" ]; then
    echo "拒绝替换（目录生成结果不完整）: $f" >&2
    exit 1
  fi

  if [ "$CHECK" = "1" ]; then
    if diff -u "$f" "$out" > /tmp/docs-toc-diff.txt 2>&1; then
      echo "✓ ${f}（目录最新）"
    else
      echo "✗ ${f} 目录已过期（跑 make docs-toc 重建）：" >&2
      sed -n '3,14p' /tmp/docs-toc-diff.txt >&2
      BAD=1
    fi
  else
    mv "$out" "$f"
    echo "✓ ${f}（${n} 条）"
  fi
  rm -f "$toc" "$out"
  TOC_TMP=""
  OUT_TMP=""
done

if [ "$CHECK" = "1" ] && [ "$BAD" = "0" ]; then
  echo "全部目录都是最新的"
fi
exit "$BAD"
