#!/bin/bash
# ============================================================
# vangrr 后台控制循环：登录节点常驻，纯 bash（jq / qstat / qselect / qsub / git / flock），不跑 Python，不起任何 AI 会话。
# 用 setsid -f 起，和 Claude 会话无关；会话关掉照常运行。每 CTL_SLEEP 秒（默认 120）一轮：
#   [jobs]      台账里登记的作业：被挤（271/265）600 s 后原样重投；到时限（-29 或用满）60 s 后重投；坏节点（20）300 s 后重投（≤6 次）；
#               exit 0 → done + job_done 事件；其他退出码 → failed + job_failed 事件，不自动重投。
#               重投前先按作业名 qselect，已有就认领，不重复投
#   [downloads] 4 个模型没下完且没有下载进程 → 续传（fetch_models.sh 幂等）
#   [git]       每 CTL_GIT_EVERY 秒（默认 900）：fetch；Van 有新提交 → van_push 事件；工作区干净 → pull --rebase；
#               本地领先 → 扫描新增行无别的项目信息 / 密钥后 push
# 事件只记录在 logs/monitor/events.jsonl，由下一次打开的会话先读、处理、再清空；循环自己不做判断，也不改实验代码。
# 状态都在 logs/monitor/（不入库）：ledger.json 台账、events.jsonl 待处理事件、ctl.log。
#
#   setsid -f bash abci/monitor/grr_ctl.sh run >> logs/monitor/ctl.log 2>&1 < /dev/null    常驻（同一时刻只会有一个）
#   bash abci/monitor/grr_ctl.sh status                                                     看状态
#   bash abci/monitor/grr_ctl.sh track <run> <jobid> <script> [qsub -v 串]                  登记一个已投的作业（之后被挤自动重排）
#   bash abci/monitor/grr_ctl.sh event <type> ['<json>']                                     手工补一个事件
#   开关（放在 logs/monitor/）：PAUSE = 不重投作业；STOP = 下一轮退出
# 自测：CTL_DRY=1 CTL_ROUNDS=1 bash abci/monitor/grr_ctl.sh run   （只打印将要做的事）
# ============================================================
set -uo pipefail

ROOT=${GRR_ROOT:-/groups/gcg51557/experiments/0314_clip-modality-gap/vangrr}
M=${CTL_DIR:-$ROOT/logs/monitor}
LEDGER=$M/ledger.json
EVENTS=$M/events.jsonl
export PATH=${CTL_MOCK_BIN:+$CTL_MOCK_BIN:}/opt/pbs/bin:/usr/local/bin:/usr/bin:/bin:$PATH   # CTL_MOCK_BIN：模拟测试用的假 qstat/qsub
DRY=${CTL_DRY:-}
SKIP=${CTL_SKIP:-}             # 模拟测试用：如 "downloads git"
SLEEP=${CTL_SLEEP:-120}
GIT_EVERY=${CTL_GIT_EVERY:-900}
PREEMPT_DELAY=${CTL_PREEMPT_DELAY:-600}; SEGMENT_DELAY=60; BAD_NODE_DELAY=300; MAX_PREEMPT=40; MAX_BAD_NODE=6
OUR_AUTHOR=chuang-ma-ku
MODELS="EvoCUA-8B-20260105 EvoCUA-32B-20260105 UI-Mate-9B UI-Mate-27B"
# 推送前扫描新增行：形似密钥的串，加上本地文件 logs/monitor/deny_patterns.ere 里的别的项目 / 合作者名字（名单不入库）
DENY_SECRETS='hf_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}'
DENY_FILE=${CTL_DENY_FILE:-$M/deny_patterns.ere}
deny_re() { local extra=""; [ -s "$DENY_FILE" ] && extra=$(grep -v '^#' "$DENY_FILE" | paste -sd'|'); echo "$DENY_SECRETS${extra:+|$extra}"; }

log() { echo "[$(date '+%F %T')] $*"; }
mkdir -p "$M/submissions"
[ -f "$LEDGER" ] || echo '{"runs":{},"git":{"last_remote":"","last_sync":0},"downloads":{"starts":0,"last_start":0}}' > "$LEDGER"

lset() {  # lset <jq 表达式> [jq 参数...]：加锁 + 临时文件 + mv，循环和命令行子命令不会互相覆盖，台账不会写坏
  local expr=$1; shift
  (
    flock 8
    jq --arg now "$(date -Is)" "$@" "$expr" "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  ) 8> "$M/ledger.lock"
}
rget() { jq -r --arg r "$1" ".runs[\$r] | $2" "$LEDGER"; }
emit() {  # emit <type> [detail json]
  local d=${2:-}; [ -n "$d" ] || d='{}'
  jq -nc --arg at "$(date -Is)" --arg t "$1" --argjson d "$d" '{at:$at, type:$t, detail:$d}' >> "$EVENTS"
  log "event $1 $d"
}
to_sec() { local h m s; IFS=: read -r h m s <<<"$1"; echo $((10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0})); }
script_name() { sed -n 's/^#PBS -N[[:space:]]*//p' "$ROOT/$1" | head -1; }
qjob() { timeout 60 qstat -xf -F json "$1" 2>/dev/null | jq -c --arg j "$1" '.Jobs[$j] // empty' 2>/dev/null; }
walltime_hit() {  # ABCI 用满时限记 -29；另外"已用 ≥ 申请 - 2 分钟"也算
  local q=$1 used req
  [ "$(jq -r '.Exit_status // empty' <<<"$q")" = -29 ] && return 0
  used=$(jq -r '.resources_used.walltime // empty' <<<"$q"); req=$(jq -r '.Resource_List.walltime // empty' <<<"$q")
  [ -n "$used" ] && [ -n "$req" ] && [ "$(to_sec "$used")" -ge $(( $(to_sec "$req") - 120 )) ]
}
need_review() {  # need_review <run> <原因>
  lset '.runs[$r] |= (.status="failed" | .needs_review=true | .reason=$why)' --arg r "$1" --arg why "$2"
  emit job_failed "$(jq -nc --arg r "$1" --arg why "$2" '{run:$r, reason:$why}')"
}

# ---------- 作业：只重投台账里登记过（即用户放行过）的作业 ----------
submit_run() {
  local run=$1 script vars name active new n intent how fails
  script=$(rget "$run" '.script'); vars=$(rget "$run" '.vars // ""')
  name=$(script_name "$script")
  [[ $name == 0314_grr_* ]] || { need_review "$run" "job name '$name' lacks the 0314_grr_ prefix"; return; }
  [[ ,$vars, == *,RTYPE=rt_HF,* ]] || vars="RTYPE=rt_HF${vars:+,$vars}"
  active=$(timeout 60 qselect -u "$USER" -N "$name" -s QRHW 2>/dev/null) || { log "$run: qselect failed; next round"; return; }
  if [ "$(wc -w <<<"$active")" -gt 1 ]; then need_review "$run" "more than one active job named $name: $(echo $active)"; return; fi
  if [ -n "$active" ]; then
    new=$active how=adopted
  else
    n=$(rget "$run" '.history | length'); intent=$M/submissions/$run.$((n + 1)).json
    [ -e "$intent" ] && { need_review "$run" "unresolved submission ($intent exists, no job in the queue)"; return; }
    if [ -n "$DRY" ]; then log "DRY: would qsub -v $vars $script ($run)"; return; fi
    jq -n --arg at "$(date -Is)" '{at:$at, state:"submitting"}' > "$intent"
    new=$(cd "$ROOT" && timeout 120 qsub -v "$vars" "$script" 2>&1)
    if [[ ! $new =~ ^[0-9]+\.pbs1$ ]]; then
      rm -f "$intent"
      fails=$(( $(rget "$run" '.submit_fail // 0') + 1 ))
      lset '.runs[$r].submit_fail=($f|tonumber)' --arg r "$run" --arg f "$fails"
      log "$run: qsub failed ($fails): $new"
      [ "$fails" -ge 3 ] && need_review "$run" "qsub failed 3 times: $new"
      return
    fi
    jq -n --arg at "$(date -Is)" --arg j "$new" '{at:$at, state:"submitted", job_id:$j}' > "$intent"
    how=resubmitted
  fi
  lset '.runs[$r] |= (.history += [$j] | .job_id=$j | .status="queued" | .submitted_at=$now | .submit_fail=0 | del(.retry_after))' \
    --arg r "$run" --arg j "$new"
  log "$run $how $new"
}

handle_run() {
  local run=$1 status jid q st ex host detail ns
  status=$(rget "$run" '.status // ""')
  case $status in done|failed|paused) return ;; esac
  if [[ $status == preempted || $status == segment_end || $status == bad_node ]]; then
    [ "$(date +%s)" -ge "$(rget "$run" '.retry_after // 0')" ] && submit_run "$run"
    return
  fi
  jid=$(rget "$run" '.job_id // ""')
  [ -n "$jid" ] || return
  q=$(qjob "$jid"); [ -n "$q" ] || return   # qstat 偶尔什么都不返回：这一轮不知道，什么都不改
  st=$(jq -r '.job_state' <<<"$q"); ex=$(jq -r '.Exit_status // empty' <<<"$q"); host=$(jq -r '.exec_host // ""' <<<"$q" | sed 's|/.*||')
  if [ "$st" != F ]; then
    ns=queued; [ "$st" = R ] && ns=running
    if [ "$ns" != "$status" ]; then
      lset '.runs[$r] |= (.status=$s | (if $h != "" then .exec_host=$h else . end))' --arg r "$run" --arg s "$ns" --arg h "$host"
      log "$run $jid $ns${host:+ on $host}"
    fi
    return
  fi
  detail=$(jq -nc --arg r "$run" --arg j "$jid" --arg e "${ex:-none}" --arg h "$host" \
    --arg w "$(jq -r '.resources_used.walltime // ""' <<<"$q")" '{run:$r, job_id:$j, exit:$e, host:$h, walltime_used:$w}')
  if [ "$ex" = 0 ]; then
    lset '.runs[$r] |= (.status="done" | .exit_status=0 | .done_at=$now)' --arg r "$run"
    emit job_done "$detail"
  elif [ "$ex" = 271 ] || [ "$ex" = 265 ]; then
    if [ "$(rget "$run" '.preempt_count // 0')" -ge "$MAX_PREEMPT" ]; then need_review "$run" "preempted $MAX_PREEMPT times"; return; fi
    lset '.runs[$r] |= (.status="preempted" | .preempt_count+=1 | .retry_after=(now + ($d|tonumber) | floor))' --arg r "$run" --arg d "$PREEMPT_DELAY"
    log "$run $jid preempted or deleted (exit $ex); resubmits in ${PREEMPT_DELAY}s"
  elif walltime_hit "$q"; then
    lset '.runs[$r] |= (.status="segment_end" | .walltime_count+=1 | .retry_after=(now + ($d|tonumber) | floor))' --arg r "$run" --arg d "$SEGMENT_DELAY"
    log "$run $jid hit its walltime (exit $ex); resubmits in ${SEGMENT_DELAY}s"
  elif [ "$ex" = 20 ] && [ "$(rget "$run" '.bad_node_count // 0')" -lt "$MAX_BAD_NODE" ]; then
    lset '.runs[$r] |= (.status="bad_node" | .bad_node_count+=1 | .bad_node=$h | .retry_after=(now + ($d|tonumber) | floor))' \
      --arg r "$run" --arg h "$host" --arg d "$BAD_NODE_DELAY"
    log "$run $jid bad node $host (exit 20); resubmits in ${BAD_NODE_DELAY}s"
  else
    lset '.runs[$r] |= (.status="failed" | .needs_review=true | .exit_status=$e | .reason="exit \($e)")' --arg r "$run" --arg e "${ex:-none}"
    emit job_failed "$detail"
  fi
}

# ---------- 模型下载 ----------
handle_downloads() {
  local m incomplete=0 last starts
  for m in $MODELS; do [ -f "$ROOT/models/$m/DOWNLOAD-COMPLETE" ] || incomplete=1; done
  if [ "$incomplete" = 0 ]; then
    [ "$(jq -r '.downloads.complete_noted // false' "$LEDGER")" = true ] && return
    lset '.downloads.complete_noted=true'; emit downloads_complete '{}'; return
  fi
  pgrep -u "$USER" -f 'abci/download/fetch_models.sh' > /dev/null && return
  last=$(jq -r '.downloads.last_start // 0' "$LEDGER"); starts=$(jq -r '.downloads.starts // 0' "$LEDGER")
  [ $(( $(date +%s) - last )) -ge 600 ] || return
  if [ "$starts" -ge 12 ]; then
    [ "$(jq -r '.downloads.review_noted // false' "$LEDGER")" = true ] && return
    lset '.downloads.review_noted=true'; emit needs_review '{"what":"model downloads restarted 12 times without completing"}'
    return
  fi
  [ -n "$DRY" ] && { log "DRY: would restart fetch_models.sh"; return; }
  mkdir -p "$ROOT/logs/download"
  (cd "$ROOT" && setsid -f bash abci/download/fetch_models.sh >> "$ROOT/logs/download/models_$(date +%F).log" 2>&1 < /dev/null 9>&-)
  lset '.downloads.last_start=(now|floor) | .downloads.starts+=1'
  log "fetch_models.sh (re)started"
}

# ---------- git ----------
handle_git() {
  local remote last others dirty behind ahead head
  [ $(( $(date +%s) - $(jq -r '.git.last_sync // 0' "$LEDGER") )) -ge "$GIT_EVERY" ] || return
  lset '.git.last_sync=(now|floor)'
  cd "$ROOT" || return
  timeout 120 git fetch -q origin 2>/dev/null || { log "git fetch failed; next sync"; return; }
  remote=$(git rev-parse origin/master); last=$(jq -r '.git.last_remote // ""' "$LEDGER")
  if [ "$remote" != "$last" ]; then
    if [ -n "$last" ]; then
      others=$(git log --format='%h%x09%an%x09%s' "$last..$remote" | awk -F'\t' -v me="$OUR_AUTHOR" '$2 != me')
      [ -n "$others" ] && emit van_push "$(jq -Rn --arg l "$others" '{commits: ($l | split("\n"))}')"
    fi
    lset '.git.last_remote=$h' --arg h "$remote"
  fi
  dirty=$(git status --porcelain --untracked-files=no)
  behind=$(git rev-list --count HEAD..origin/master)
  if [ -z "$dirty" ] && [ "$behind" -gt 0 ]; then
    if [ -n "$DRY" ]; then log "DRY: would git pull --rebase ($behind new)"
    elif ! git pull --rebase -q origin master > /dev/null 2>&1; then
      git rebase --abort > /dev/null 2>&1; emit git_conflict "$(jq -nc --arg b "$behind" '{behind:$b}')"
    else log "pulled $behind commit(s)"; fi
  fi
  ahead=$(git rev-list --count origin/master..HEAD); head=$(git rev-parse HEAD)
  [ "$ahead" -gt 0 ] || return
  if git diff origin/master..HEAD | grep -E '^\+' | grep -qiE "$(deny_re)"; then
    [ "$(jq -r '.git.push_blocked_at // ""' "$LEDGER")" = "$head" ] && return
    lset '.git.push_blocked_at=$h' --arg h "$head"
    emit push_blocked "$(jq -nc --arg h "${head:0:7}" '{head:$h, why:"added lines match the other-project / secret pattern"}')"
  elif [ -n "$DRY" ]; then log "DRY: would push $ahead commit(s)"
  elif timeout 120 git push -q origin master > /dev/null 2>&1; then log "pushed $ahead commit(s)"
  else log "git push failed; next sync"; fi
}

# ---------- 子命令 ----------
status() {
  local hb age pid host m
  hb=$(cat "$M/ctl.heartbeat" 2>/dev/null || echo 0); age=$(( $(date +%s) - hb ))
  pid=$(cat "$M/ctl.pid" 2>/dev/null || true); host=$(cat "$M/ctl.host" 2>/dev/null || echo "?")
  if [ -n "$pid" ] && [ "$age" -le $((SLEEP * 3)) ]; then echo "grr_ctl.sh running: PID $pid on $host, last round ${age}s ago"
  else echo "grr_ctl.sh NOT running (pid ${pid:-none}, last round ${age}s ago, host $host)"; fi
  for m in PAUSE STOP; do [ -f "$M/$m" ] && echo "  switch $m is ON"; done
  echo "runs:"
  jq -r '.runs | to_entries[] | "  \(.key)\t\(.value.job_id // "-")\t\(.value.status // "-")\thost \(.value.exec_host // "-")\tpreempt \(.value.preempt_count // 0)\twalltime \(.value.walltime_count // 0)\(if .value.needs_review then "\tNEEDS REVIEW: \(.value.reason // "")" else "" end)"' "$LEDGER"
  echo "pending events: $([ -s "$EVENTS" ] && wc -l < "$EVENTS" || echo 0)  ($EVENTS)"
  echo "git: $(cd "$ROOT" && echo "ahead $(git rev-list --count origin/master..HEAD), behind $(git rev-list --count HEAD..origin/master) (as of last fetch)")"
  echo "downloads:"
  for m in $MODELS; do
    if [ -f "$ROOT/models/$m/DOWNLOAD-COMPLETE" ]; then echo "  $m complete"; else echo "  $m $(du -sh "$ROOT/models/$m" 2>/dev/null | cut -f1)"; fi
  done
}

case "${1:-}" in
  status) status; exit 0 ;;
  track)
    [ $# -ge 4 ] || { echo "usage: track <run> <jobid> <script> [vars]"; exit 2; }
    lset '.runs[$r] = {run:$r, script:$s, vars:$v, history:[$j], job_id:$j, status:"queued", preempt_count:0,
           walltime_count:0, bad_node_count:0, created_at:$now}' --arg r "$2" --arg j "$3" --arg s "$4" --arg v "${5:-RTYPE=rt_HF}"
    echo "tracking $2 = $3 ($4)"; exit 0 ;;
  event)
    [ $# -ge 2 ] || { echo "usage: event <type> [json]"; exit 2; }
    emit "$2" "${3:-}"; exit 0 ;;
  run) ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac

exec 9> "$M/ctl.lock"
flock -n 9 || { log "another grr_ctl.sh holds $M/ctl.lock; exiting"; exit 3; }
echo $$ > "$M/ctl.pid"; hostname > "$M/ctl.host"
trap 'rm -f "$M/ctl.pid"' EXIT
log "grr_ctl.sh started, PID $$ on $(hostname)${DRY:+ (DRY RUN)}"
rounds=0
while true; do
  if [ -f "$M/STOP" ]; then rm -f "$M/STOP"; log "STOP found; exiting"; exit 0; fi
  date +%s > "$M/ctl.heartbeat"
  if [ ! -f "$M/PAUSE" ]; then
    for r in $(jq -r '.runs | keys[]' "$LEDGER"); do handle_run "$r"; done
  fi
  [[ " $SKIP " == *" downloads "* ]] || handle_downloads
  [[ " $SKIP " == *" git "* ]] || handle_git
  rounds=$((rounds + 1))
  [ -n "${CTL_ROUNDS:-}" ] && [ "$rounds" -ge "$CTL_ROUNDS" ] && exit 0
  sleep "$SLEEP"
done
