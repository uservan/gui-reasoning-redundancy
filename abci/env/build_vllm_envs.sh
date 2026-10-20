#!/usr/bin/env bash
# ============================================================
# 建两套 vLLM 服务环境（登录节点：只下载、解包预编译 wheel，不编译源码、不跑 Python 计算）
#   conda/envs/vllm-evocua : vllm 0.11.0 + transformers 4.57.3（EvoCUA 官方推荐版本）+ backoff（EvoCUA agent 依赖）
#   conda/envs/vllm-uimate : vllm 0.28.0（UI-Mate 发布期附近的稳定版，支持 qwen3_5 架构；UI-Mate 未钉版本）
# 用 uv 建 venv 并安装；uv 缓存、uv 下载的 Python 本体、临时文件都放项目目录（家目录配额已满）。
# 幂等：装好的环境写 ENV-COMPLETE（含 requirements.lock.txt），再跑就跳过。
# 环境能否 import / 起服务要在计算节点上验证（smoke 作业，须用户放行）。
#
# usage: bash abci/env/build_vllm_envs.sh [evocua|uimate ...]     （默认两个都建）
# ============================================================
set -uo pipefail
ROOT=${GRR_ROOT:-/groups/gcg51557/experiments/0314_clip-modality-gap/vangrr}
UV=${UV:-/home/ach18422gb/miniconda3/bin/uv}
export UV_CACHE_DIR=$ROOT/conda/uvcache
export UV_PYTHON_INSTALL_DIR=$ROOT/conda/uvpython
export TMPDIR=$ROOT/conda/tmp
mkdir -p "$UV_CACHE_DIR" "$UV_PYTHON_INSTALL_DIR" "$TMPDIR" "$ROOT/conda/envs"
declare -A PKGS=(
  [evocua]="vllm==0.11.0 transformers==4.57.3 backoff"   # backoff：EvoCUA agent 的依赖
  [uimate]="vllm==0.28.0"
)
say() { echo "[$(date '+%F %T')] $*"; }

targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(evocua uimate)
rc=0
for t in "${targets[@]}"; do
  [ -n "${PKGS[$t]:-}" ] || { say "unknown env: $t"; rc=1; continue; }
  env=$ROOT/conda/envs/vllm-$t
  [ -f "$env/ENV-COMPLETE" ] && { say "$t: already complete"; continue; }
  t0=$(date +%s)
  [ -x "$env/bin/python" ] || "$UV" venv --python 3.12 "$env" || { say "$t: venv failed"; rc=1; continue; }
  # shellcheck disable=SC2086
  if "$UV" pip install --python "$env/bin/python" ${PKGS[$t]}; then
    "$UV" pip freeze --python "$env/bin/python" > "$env/requirements.lock.txt"
    printf 'packages=%s\ncompleted=%s\n' "${PKGS[$t]}" "$(date -Is)" > "$env/ENV-COMPLETE"
    say "$t: COMPLETE in $(( $(date +%s) - t0 ))s, $(du -sh "$env" | cut -f1); $(grep -E '^(vllm|torch|transformers)==' "$env/requirements.lock.txt" | tr '\n' ' ')"
  else
    say "$t: install FAILED (rerun to retry)"; rc=1
  fi
done
exit $rc
