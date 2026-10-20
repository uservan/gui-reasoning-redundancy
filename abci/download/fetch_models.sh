#!/usr/bin/env bash
# ============================================================
# Download the four study models from HuggingFace into $ROOT/models/<name>/ — on the LOGIN node
# (compute nodes cannot download). Pure bash + curl + jq, no Python. Idempotent and resumable:
# every file comes from a pinned revision via `curl -C -` and is checked against the size the HF API reports;
# a model gets DOWNLOAD-COMPLETE (repo, revision, file count) only when every file matches.
# Skipped: README images and the tech-report PDF (not needed for serving).
# The HF API metadata (incl. LFS sha256 per file) is kept in <model>/.hf_meta.json for a later checksum pass on a compute node.
#
# usage: bash abci/download/fetch_models.sh [repo ...]     (default: all four, small ones first)
# ============================================================
set -uo pipefail
ROOT=${GRR_ROOT:-/groups/gcg51557/experiments/0314_clip-modality-gap/vangrr}
DEST=$ROOT/models
declare -A REV=(   # pinned 2026-10-20
  [meituan/EvoCUA-8B-20260105]=04973dbc61db6f1e56858c2bc75d30ac18bd329a
  [meituan/EvoCUA-32B-20260105]=ce0553438b5f329959b4e740791b580402bbc73e
  [tencent/UI-Mate-9B]=05dd5f2975195a5bb03d4363e8767f12158c8421
  [tencent/UI-Mate-27B]=3ade2378fc84032d5017c1a9c93c4eaa77d65e57
)
SKIP_RE='^(assets/|tech_report\.pdf$)'
repos=("$@")
[ ${#repos[@]} -gt 0 ] || repos=(meituan/EvoCUA-8B-20260105 tencent/UI-Mate-9B meituan/EvoCUA-32B-20260105 tencent/UI-Mate-27B)
say() { echo "[$(date '+%F %T')] $*"; }

all_ok=1
for repo in "${repos[@]}"; do
  rev=${REV[$repo]:-}
  [ -n "$rev" ] || { say "$repo: no pinned revision, skipped"; all_ok=0; continue; }
  dir=$DEST/${repo#*/}
  [ -f "$dir/DOWNLOAD-COMPLETE" ] && { say "$repo: already complete"; continue; }
  mkdir -p "$dir"
  meta=$(curl -sf --retry 3 --max-time 60 "https://huggingface.co/api/models/$repo/revision/$rev?blobs=true") ||
    { say "$repo: metadata fetch failed"; all_ok=0; continue; }
  jq '{id, sha, siblings: [.siblings[] | {rfilename, size, sha256: (.lfs.sha256 // null)}]}' <<<"$meta" > "$dir/.hf_meta.json"
  ok=1; n=0; t0=$(date +%s)
  while IFS=$'\t' read -r f size; do
    [[ $f =~ $SKIP_RE ]] && continue
    n=$((n + 1))
    out=$dir/$f
    mkdir -p "$(dirname "$out")"
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    (( have > size )) && { rm -f "$out"; have=0; }   # a file larger than expected cannot be resumed
    if [ "$have" != "$size" ]; then
      curl -sSL --retry 5 --retry-delay 10 -C - -o "$out" "https://huggingface.co/$repo/resolve/$rev/$f" || true
      have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    fi
    if [ "$have" = "$size" ]; then say "$repo ok  $f ($size)"; else say "$repo BAD $f (have $have, want $size)"; ok=0; fi
  done < <(jq -r '.siblings[] | [.rfilename, (.size | tostring)] | @tsv' <<<"$meta")
  if [ "$ok" = 1 ]; then
    printf 'repo=%s\nrevision=%s\nfiles=%s\ncompleted=%s\n' "$repo" "$rev" "$n" "$(date -Is)" > "$dir/DOWNLOAD-COMPLETE"
    say "$repo: COMPLETE, $n files, $(du -sh "$dir" | cut -f1), $(( $(date +%s) - t0 ))s"
  else
    all_ok=0; say "$repo: INCOMPLETE (rerun to resume)"
  fi
done
[ "$all_ok" = 1 ] && say "all requested models complete" || { say "some models incomplete"; exit 1; }
