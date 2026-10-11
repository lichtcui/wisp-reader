#!/usr/bin/env python3
"""Reimplementation of gpt-sovits-onnx-rs src/preprocessor/seg.rs (pre_seg_text).

Validated against the engine's own DEBUG 'Processing chunk:' log lines.
"""
import re

SPLITS = "，。？！, . ? ! ~ : ：—…".replace(" ", "")
SENT_END = "。！？.!?"
PURE_SYMBOL_RE = re.compile(r"^\W+$", re.UNICODE)


def _norm_punct(text):
    text = text.replace("，", ",").replace("。", ".").replace("？", "?").replace("！", "!")
    text = text.replace("：", ":")
    text = re.sub(r"([!?…,.\-])\1+", r"\1", text)
    return text


def has_content(t):
    return any(c.isalnum() or '\u4e00' <= c <= '\u9fff' or '\u3400' <= c <= '\u4dbf' for c in t)


def split_sentence_chunks(line):
    out, cur = [], ""
    n = len(line)
    for i, c in enumerate(line):
        cur += c
        if c not in SENT_END:
            continue
        if c == "." and 0 < i < n - 1 and line[i-1].isdigit() and line[i+1].isdigit():
            continue
        if not has_content(cur):
            continue
        t = cur.strip()
        if t and not PURE_SYMBOL_RE.match(t):
            out.append(t)
        cur = ""
    tail = cur.strip()
    if tail and not PURE_SYMBOL_RE.match(tail):
        out.append(tail)
    if not out:
        w = line.strip()
        if w and not PURE_SYMBOL_RE.match(w):
            out.append(w)
    return out


def _merge_short(texts, threshold):
    if len(texts) < 2:
        return list(texts)
    res, buf = [], ""
    for e in texts:
        buf += e
        if len(buf) >= threshold:
            res.append(buf); buf = ""
    if buf:
        if not res:
            res.append(buf)
        else:
            res[-1] += buf
    return res


def split_big_text(text, max_len=510):
    segs = re.split("([" + re.escape(SPLITS) + "])", text)
    segs = [s for s in segs if s != ""]
    res, cur = [], ""
    for s in segs:
        if len(cur) + len(s) > max_len:
            if cur:
                res.append(cur)
            cur = s
        else:
            cur += s
    if cur:
        res.append(cur)
    return res


def pre_seg_text(text, max_len=510, lang_en=False):
    """Engine default max_len=510. P3 uses a smaller max_len to force finer chunks."""
    text = text.strip()
    if not text:
        return []
    text = _norm_punct(text)
    if text[0] not in SPLITS:
        first = re.split("[" + re.escape(SPLITS) + "]", text)[0].strip()
        if len(first) < 4:
            text = ("." if lang_en else "。") + text
    while "\n\n" in text:
        text = text.replace("\n\n", "\n")
    lines = _merge_short([l for l in text.split("\n") if l.strip()], 5)
    texts = []
    for line in lines:
        if not line.strip() or PURE_SYMBOL_RE.match(line):
            continue
        for chunk in split_sentence_chunks(line):
            if len(chunk) > max_len:
                texts.extend(split_big_text(chunk, max_len))
            else:
                texts.append(chunk)
    return texts


def enforce_max(tokens, max_len):
    """Split any chunk longer than max_len at the last punctuation <= max_len."""
    out = []
    for t in tokens:
        while len(t) > max_len:
            window = t[:max_len]
            cut = max((window.rfind(p) for p in SPLITS), default=-1)
            if cut <= 0:
                out.append(t[:max_len]); t = t[max_len:]
            else:
                out.append(t[:cut+1]); t = t[cut+1:]
        if t:
            out.append(t)
    return out


def chunk_for_limit(text, max_len):
    """Smart splitting at the last punctuation <= max_len (P3 chunking policy)."""
    return enforce_max(pre_seg_text(text, max_len=max_len), max_len)


if __name__ == "__main__":
    import json, sys
    case = json.load(open("/Users/lichtcui/Documents/playground/tts/p2/harness/cases.json"))
    page = [c for c in case["cases"] if c["id"] == "page_long"][0]["text"]
    for lim in (510, 60, 45, 30):
        ch = chunk_for_limit(page, lim)
        print(f"max={lim}: n={len(ch)} lens={[len(c) for c in ch]}")
