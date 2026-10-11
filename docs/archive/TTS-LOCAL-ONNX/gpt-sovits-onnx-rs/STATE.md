# gpt-sovits-onnx-rs 状态快照（清理前冻结）

clone: https://github.com/bailu-obj/gpt-sovits-onnx-rs.git

分支: main
origin/main: `a04d89b8da6f7aa847eb481e0642aee2638044eb`
本地 HEAD（**未推送**）: `12bfc9ecb7be0a48cd66f965b59ff38198d6943e`

## 未推送提交（补丁见 000*.patch）
- `12bfc9e` feat(p3): add chunked-synthesis example and env-gated semantic dump
- `ca90059` fix(ort): support Intel macOS by pinning ort api-23
- `859c33a` feat(export): support PyTorch < 2.6 hosts in the ONNX export path

## 未提交改动（diff 见 worktree-uncommitted.diff，原文件见 worktree-files/）
```
 Cargo.toml              | 13 ++++++++
 src/lib.rs              | 71 ++++++++++++++++++++++++++++++++++++++++--
 src/onnx_builder.rs     | 83 ++++++++++++++++++++++++++++++++++++++++++++++---
 src/preprocessor/seg.rs | 63 +++++++++++++++++++++++++++++++++++++
 4 files changed, 224 insertions(+), 6 deletions(-)
```

## 未跟踪
- src/preprocessor/testdata/
