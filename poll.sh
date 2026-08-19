#!/usr/bin/env bash
# poll.sh — poll the repos in config.json for PRs needing review and auto-launch
# a headless review session per new PR (git-worktree based). The agent harness is
# config-driven: "dsh" (DeepSeek Harness) or "claude" (Claude Code, headless -p).
# Top-level config.json is the global config; each "repos[]" entry may override
# harness / reviewer / model / custom_prompt. Also the single source of bot logic
# shared by run-now.sh and status.sh.
set -uo pipefail

# --- self-locating bot dir (safe to move the whole folder anywhere) ---------
BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$BOT_DIR/config.json}"
STATE_DIR="$BOT_DIR/state"
LOG_DIR="$BOT_DIR/logs"
STATE_FILE="$STATE_DIR/state.json"
LOCK_FILE="$STATE_DIR/poll.lock"
STATE_LOCK="$STATE_DIR/state.lock"
LAST_POLL_FILE="$STATE_DIR/last_poll"
EFFECTIVE_FILE="$STATE_DIR/effective.json"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"

# --- portable tool resolution (override each via env, else auto-discover) ----
GH="${GH:-$(command -v gh 2>/dev/null || echo "$HOME/.nix-profile/bin/gh")}"
NODE="${NODE:-$(command -v node 2>/dev/null || echo "$HOME/.nix-profile/bin/node")}"
if [ -z "${DSH_BIN:-}" ]; then
  for c in "$HOME/.local/share/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" \
           /usr/local/share/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js; do
    [ -f "$c" ] && DSH_BIN="$c" && break
  done
  [ -n "${DSH_BIN:-}" ] || DSH_BIN="$(command -v dsh 2>/dev/null || true)"
fi
# claude's binary and profile are resolved after load_config (env > config > PATH).
CLAUDE_BIN_ENV="${CLAUDE_BIN:-}"
CLAUDE_CONFIG_DIR_ENV="${CLAUDE_CONFIG_DIR:-}"
expand_home() { case "$1" in "~") echo "$HOME";; "~/"*) echo "$HOME/${1#\~/}";; *) echo "$1";; esac; }
export PATH="$(dirname "$GH"):/usr/bin:/bin:$PATH"

log() { echo "[$(date -Is)] $*"; }

# --- load config.json + compute effective (global-overridden) config ----------
load_config() {
  [ -f "$CONFIG_FILE" ] || { log "FATAL: $CONFIG_FILE missing"; exit 1; }
  REVIEWER="$(jq -r '.reviewer // ""' "$CONFIG_FILE")"
  POLL_INTERVAL_MINUTES="$(jq -r '.poll_interval_minutes // 5' "$CONFIG_FILE")"
  MAX_SESSIONS_PER_POLL="$(jq -r '.max_sessions_per_poll // 2' "$CONFIG_FILE")"
  MAX_CONCURRENT_SESSIONS="$(jq -r '.max_concurrent_sessions // 4' "$CONFIG_FILE")"
  MENTION_WINDOW_HOURS="$(jq -r '.mention_window_hours // 24' "$CONFIG_FILE")"
  HARNESS="$(jq -r '.harness // "dsh"' "$CONFIG_FILE")"
  MODEL_PROVIDER="$(jq -r '.model.provider // ""' "$CONFIG_FILE")"
  MODEL_NAME="$(jq -r '.model.model // ""' "$CONFIG_FILE")"
  MODEL_EFFORT="$(jq -r '.model.reasoningEffort // ""' "$CONFIG_FILE")"
  CUSTOM_PROMPT="$(jq -r '.custom_prompt // ""' "$CONFIG_FILE")"
  SESSION_ENV_COUNT="$(jq -r '(.session_env // {}) | length' "$CONFIG_FILE")"
  CLAUDE_CFG_BIN="$(jq -r '.claude.bin // ""' "$CONFIG_FILE")"
  CLAUDE_CFG_DIR="$(jq -r '.claude.config_dir // ""' "$CONFIG_FILE")"
  TOKEN_ENV="$(jq -r '.gh.token_env // ""' "$CONFIG_FILE")"
  TOKEN_LITERAL="$(jq -r '.gh.token // ""' "$CONFIG_FILE")"
  GITHUB_BASE_URL="$(jq -r '.gh.base_url // "https://github.com"' "$CONFIG_FILE")"
  local git_dir worktree_base
  git_dir="$(jq -r '.git_dir // "git"' "$CONFIG_FILE")"
  worktree_base="$(jq -r '.worktree_base // "worktrees"' "$CONFIG_FILE")"
  case "$git_dir" in /*) GIT_DIR="$git_dir";; *) GIT_DIR="$BOT_DIR/$git_dir";; esac
  case "$worktree_base" in /*) WORKTREE_BASE="$worktree_base";; *) WORKTREE_BASE="$BOT_DIR/$worktree_base";; esac

  # merge: per-repo fields fall back to global fields
  jq '{ repos: [ .repos[] | . as $r |
    {
      repo: ($r.repo // ""),
      reviewer: ($r.reviewer // $root.reviewer // ""),
      harness: ($r.harness // $root.harness // "dsh"),
      model: {
        provider: ($r.model.provider // $root.model.provider // ""),
        model: ($r.model.model // $root.model.model // ""),
        reasoningEffort: ($r.model.reasoningEffort // $root.model.reasoningEffort // "")
      },
      custom_prompt: ($r.custom_prompt // $root.custom_prompt // "")
    } ] }' --argjson root "$(cat "$CONFIG_FILE")" "$CONFIG_FILE" > "$EFFECTIVE_FILE.tmp" \
    && mv "$EFFECTIVE_FILE.tmp" "$EFFECTIVE_FILE" \
    || { log "FATAL: cannot compute effective config"; exit 1; }
}

# state/ and logs/ must exist before load_config writes effective.json into them;
# GIT_DIR / WORKTREE_BASE are only known after the config is read.
mkdir -p "$STATE_DIR" "$LOG_DIR"
load_config
mkdir -p "$GIT_DIR" "$WORKTREE_BASE"

# --- resolve the claude binary + profile (env > config.json > PATH) ------------
# Wrappers like `claude-sk` are usually shell ALIASES of the form
#   alias claude-sk='CLAUDE_CONFIG_DIR="$HOME/.claude-sk" claude'
# An alias cannot be exec'd from a script and systemd exports no shell aliases, so
# the profile has to travel explicitly as CLAUDE_CONFIG_DIR. Point claude.config_dir
# at the profile that is actually logged in — the default ~/.claude often is not.
resolve_claude() {
  if   [ -n "$CLAUDE_BIN_ENV" ]; then CLAUDE_BIN="$CLAUDE_BIN_ENV"
  elif [ -n "$CLAUDE_CFG_BIN" ]; then CLAUDE_BIN="$(expand_home "$CLAUDE_CFG_BIN")"
  else CLAUDE_BIN="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"
  fi
  # A bare name (no slash) may be an alias or a PATH entry: resolve it to a real path.
  case "$CLAUDE_BIN" in
    */*) ;;
    *)   CLAUDE_BIN="$(command -v "$CLAUDE_BIN" 2>/dev/null || echo "$CLAUDE_BIN")";;
  esac
  if   [ -n "$CLAUDE_CONFIG_DIR_ENV" ]; then CLAUDE_CONFIG_DIR_EFF="$CLAUDE_CONFIG_DIR_ENV"
  elif [ -n "$CLAUDE_CFG_DIR" ];        then CLAUDE_CONFIG_DIR_EFF="$(expand_home "$CLAUDE_CFG_DIR")"
  else CLAUDE_CONFIG_DIR_EFF=""   # leave claude to its own default
  fi
}
resolve_claude
# claude.bin / claude.config_dir are machine-level, not per-repo: a repo entry
# carrying them would be silently ignored, so say so instead.
if jq -e '[.repos[]? | select(has("claude"))] | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
  log "WARNING: a repos[] entry sets \"claude\" — that block is global only and is being ignored (move it to the top level)"
fi

# --- GitHub credentials for BOTH gh and git -----------------------------------
GITHUB_TOKEN=""; TOKEN_SRC=""
if [ -n "$TOKEN_ENV" ]; then
  GITHUB_TOKEN="${!TOKEN_ENV:-}"
  if [ -n "$GITHUB_TOKEN" ]; then TOKEN_SRC="env $TOKEN_ENV"
  else log "WARNING: $TOKEN_ENV (config gh.token_env) is unset; falling back"; fi
fi
if [ -z "$GITHUB_TOKEN" ] && [ -n "$TOKEN_LITERAL" ]; then
  GITHUB_TOKEN="$TOKEN_LITERAL"; TOKEN_SRC="config gh.token"
fi
if [ -z "$GITHUB_TOKEN" ]; then
  GITHUB_TOKEN="$("$GH" auth token 2>/dev/null || true)"; TOKEN_SRC="gh keyring"
fi
if [ -n "$GITHUB_TOKEN" ]; then
  export GITHUB_TOKEN
  TOKEN_B64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.${GITHUB_BASE_URL%/}/.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $TOKEN_B64"
  log "token injected for gh + git (source: $TOKEN_SRC)"
else
  log "WARNING: no GitHub token — private repos will fail"
fi

# --- single-instance lock (skipped when sourced by status.sh) ------------------
if [ "${SKIP_LOCK:-0}" != "1" ]; then
  exec 9>"$LOCK_FILE"
  if [ -n "${LOCK_WAIT:-}" ]; then
    flock -w "$LOCK_WAIT" 9 || { log "poll lock still busy after ${LOCK_WAIT}s, skip"; exit 0; }
  else
    flock -n 9 || { log "another poll is running, skip"; exit 0; }
  fi
fi

# --- state helpers ------------------------------------------------------------
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
KEY() { echo "$1#$2"; }
handled_pr() { jq -e --arg k "$(KEY "$1" "$2")" '.handled_prs[$k] != null' "$STATE_FILE" >/dev/null 2>&1; }
handled_comment() { jq -e --arg c "$1" '.handled_comments[$c] != null' "$STATE_FILE" >/dev/null 2>&1; }

# Every state write is a read-modify-write, and a poll, a manual run-now and a
# status.sh can overlap; an unsynchronised `jq > tmp && mv` silently drops one
# side's entry. This lock is separate from the poll lock so a manual single-PR
# review still serialises its writes without blocking on discovery.
state_update() {  # jq-filter [jq-args...]
  local filter="$1"; shift
  ( flock 7
    jq "$@" "$filter" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  ) 7>"$STATE_LOCK"
}
mark_handled_pr() {
  local key="$(KEY "$1" "$2")"
  state_update '.handled_prs[$k] = {pr: $p, triggered_at: $t, reason: $r, session_log: $l, head_sha: $h, status_comment: $sc}' \
    --arg k "$key" --arg p "$2" --arg r "$3" --arg l "$4" --arg t "$NOW_ISO" --arg h "${5:-}" --arg sc "${6:-}"
}
clear_status_comment() {
  state_update 'del(.handled_prs[$k].status_comment)' --arg k "$1"
}
mark_handled_comment() {
  state_update '.handled_comments[$c] = {repo: $r, pr: $p, seen_at: $t}' \
    --arg c "$1" --arg p "$2" --arg r "$3" --arg t "$NOW_ISO"
}
# Mentions older than twice the window can never come back from the `since`
# filter, so their dedup entries are dead weight.
prune_handled_comments() {
  local cutoff
  cutoff="$(date -u -d "-$((MENTION_WINDOW_HOURS * 2)) hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-$((MENTION_WINDOW_HOURS * 2))H +%Y-%m-%dT%H:%M:%SZ)"
  state_update 'if .handled_comments then .handled_comments |= with_entries(select(.value.seen_at >= $c)) else . end' \
    --arg c "$cutoff"
}

# --- session pid helpers ------------------------------------------------------
pidfile_for() { echo "$STATE_DIR/session-pr-$(echo "$1" | tr '/' '-')-$2.pid"; }
read_pid() {  # prints the pid recorded in $1; drops the file if it is malformed
  local pid
  [ -f "$1" ] || return 1
  pid="$(cat "$1" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) rm -f "$1"; return 1;; esac
  [ "$pid" -gt 1 ] || { rm -f "$1"; return 1; }
  echo "$pid"
}
pid_alive() { kill -0 "$1" 2>/dev/null; }
# Only ever drop the pid file of a session that is really gone — deleting a live
# session's file makes it invisible to status.sh and the interrupted-run report.
prune_pidfile() {
  local pid
  pid="$(read_pid "$1")" || { rm -f "$1"; return 0; }
  pid_alive "$pid" || rm -f "$1"
}
# Kill a session and everything it spawned. Sessions are started with setsid so
# they own their process group; group-killing is what reaches the git/gh children
# that would otherwise keep writing the worktree the replacement session reuses.
kill_session() {  # pid
  local pid="$1" pgid own i
  own="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  # Never group-kill our own group: that would take out the poller itself.
  case "$pgid" in
    ''|*[!0-9]*) pgid="";;
    "$own")      pgid="";;
    1)           pgid="";;
  esac
  if [ -n "$pgid" ]; then kill -TERM "-$pgid" 2>/dev/null || true
  else kill -TERM "$pid" 2>/dev/null || true; fi
  for i in $(seq 1 25); do
    pid_alive "$pid" || return 0
    sleep 0.2
  done
  log "session pid $pid ignored SIGTERM, sending SIGKILL"
  if [ -n "$pgid" ]; then kill -KILL "-$pgid" 2>/dev/null || true
  else kill -KILL "$pid" 2>/dev/null || true; fi
}
count_running_sessions() {
  local n=0 pf pid
  for pf in "$STATE_DIR"/session-pr-*.pid; do
    [ -f "$pf" ] || continue
    pid="$(read_pid "$pf")" || continue
    pid_alive "$pid" && n=$((n+1))
  done
  echo "$n"
}

# max_sessions_per_poll bounds how many we START per poll; without this, N polls
# could stack N x that many concurrent agents on one machine.
at_session_cap() {  # repo pr -> true (0) when we must not launch now
  local running
  running="$(count_running_sessions)"
  if [ "$running" -ge "$MAX_CONCURRENT_SESSIONS" ]; then
    log "PR #$1/$2: $running session(s) already running (max_concurrent_sessions=$MAX_CONCURRENT_SESSIONS) — deferring to a later poll"
    return 0
  fi
  return 1
}

# Classify a session that is no longer running, from its log: failed|finished|empty.
# claude writes one JSON object (is_error); dsh writes free-form text.
session_outcome() {  # logfile
  local slog="$1"
  [ -n "$slog" ] && [ -s "$slog" ] || { echo empty; return 0; }
  if jq -e 'type == "object"' "$slog" >/dev/null 2>&1; then
    [ "$(jq -r '.is_error // false' "$slog" 2>/dev/null)" = "true" ] && echo failed || echo finished
  elif grep -qE 'Error:|at file://|FATAL|MISSING_CREDENTIAL' "$slog" 2>/dev/null; then
    echo failed
  else
    echo finished
  fi
}

# --- per-repo effective config lookup ------------------------------------------
eff_repo() { jq -c --arg r "$1" '.repos[] | select(.repo == $r)' "$EFFECTIVE_FILE" 2>/dev/null; }

# --- github helpers -------------------------------------------------------------
head_of() { "$GH" api "repos/$1/pulls/$2" -q .head.sha 2>/dev/null || echo ""; }
reviewed_by() {  # $3's latest live (non-dismissed) review commit_id on repo $1 pr $2; empty = no live review
  "$GH" api "repos/$1/pulls/$2/reviews" --paginate \
    -q '.[] | select(.user.login == "'"$3"'") | select(.state != "DISMISSED") | .commit_id' 2>/dev/null | tail -1
}

# Open PRs in $1 with a review requested from $2. Paginated: a bare `first: 100`
# silently capped discovery on busy repos.
requested_prs() {
  "$GH" api graphql --paginate \
    -f query='query($q: String!, $endCursor: String) {
      search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        edges { node { ... on PullRequest { number } } }
      } }' \
    -f q="repo:$1 is:pr is:open review-requested:$2" \
    -q '.data.search.edges[].node.number' 2>/dev/null
}

# Human-readable name of a harness id, for PR comments and status output.
harness_label() { case "$1" in claude) echo "Claude Code";; dsh|"") echo "DeepSeek Harness";; *) echo "$1";; esac; }

# Post a "review in progress" comment on the PR; prints the new comment id.
post_status_comment() {  # repo pr reviewer harness provider model effort head_sha
  local repo="$1" pr="$2" reviewer="$3" harness="$4" mprovider="$5" mname="$6" meffort="$7" sha="$8"
  local body
  body="@$reviewer is now reviewing this PR using $(harness_label "$harness") — ${mprovider:+$mprovider/}$mname${meffort:+ (reasoning effort $meffort)}. Target HEAD commit: ${GITHUB_BASE_URL%/}/$repo/commit/$sha (\`${sha:0:7}\`)."
  "$GH" api --method POST "repos/$repo/issues/$pr/comments" -f "body=$body" -q .id 2>/dev/null || echo ""
}

# --- clean up stale "review in progress" comments ------------------------------
# Once a live review exists for the current head, any lingering status comment is
# removed (the agent deletes it too; this is the poller's safety net).
cleanup_status_comments() {
  local key repo pr cid reviewer reviewed cur
  while IFS=# read -r repo pr; do
    [ -n "$repo" ] && [ -n "$pr" ] || continue
    key="$(KEY "$repo" "$pr")"
    cid="$(jq -r --arg k "$key" '.handled_prs[$k].status_comment // ""' "$STATE_FILE" 2>/dev/null)"
    [ -n "$cid" ] || continue
    reviewer="$(eff_repo "$repo" | jq -r '.reviewer')"
    reviewed="$(reviewed_by "$repo" "$pr" "$reviewer")"
    cur="$(head_of "$repo" "$pr")"
    if [ -n "$reviewed" ] && [ "$cur" = "$reviewed" ]; then
      "$GH" api --method DELETE "repos/$repo/issues/comments/$cid" >/dev/null 2>&1 || true
      clear_status_comment "$key"
      log "PR #$repo/$pr: removed 'reviewing in progress' comment (id $cid, review done)"
    fi
  done < <(jq -r '.handled_prs | keys[]' "$STATE_FILE" 2>/dev/null)
}

# --- report review sessions that ended without posting a review -----------------
# A session that genuinely finished has a live review by the time the next poll
# runs, so its stale pid file is just clean-up. Anything else ended early, and the
# session log says how: a non-empty failure log means the agent itself failed,
# while an empty/absent log means the process vanished (reboot, OOM, kill).
# (Whether a later commit should be re-reviewed at all is the main loop's call.)
report_interrupted() {
  local n=0 list="" repo pr pidf pid reviewed reviewer slog outcome why
  while IFS=# read -r repo pr; do
    [ -n "$repo" ] && [ -n "$pr" ] || continue
    pidf="$(pidfile_for "$repo" "$pr")"
    [ -f "$pidf" ] || continue
    pid="$(read_pid "$pidf")" || continue
    pid_alive "$pid" && continue   # still running — not stale

    reviewer="$(eff_repo "$repo" | jq -r '.reviewer')"
    reviewed="$(reviewed_by "$repo" "$pr" "$reviewer")"
    if [ -n "$reviewed" ]; then
      rm -f "$pidf"   # A review landed — the run finished (clean-up only).
      continue
    fi
    slog="$(jq -r --arg k "$(KEY "$repo" "$pr")" '.handled_prs[$k].session_log // ""' "$STATE_FILE" 2>/dev/null)"
    outcome="$(session_outcome "$slog")"
    case "$outcome" in
      failed) why="agent failed — see ${slog##*/}";;
      empty)  why="process vanished (reboot / crash / kill)";;
      *)      why="ended without posting a review — see ${slog##*/}";;
    esac
    n=$((n+1)); list="$list
    #$repo/$pr — $why"
  done < <(jq -r '.handled_prs | keys[]' "$STATE_FILE" 2>/dev/null)
  if [ "$n" -gt 0 ]; then
    log "SESSION-RECOVERY: $n previous review session(s) ended without posting a review:$list
    Those still requested will be re-reviewed automatically."
  fi
}

# --- ensure a git mirror exists for a repo (parallel-safe via flock) ----------
ensure_mirror() {
  local owner="$1" name="$2"
  local mirror="$GIT_DIR/$owner-$name.git"
  mkdir -p "$GIT_DIR"
  if [ ! -d "$mirror" ]; then
    ( flock 8
      if [ ! -d "$mirror" ]; then
        log "cloning mirror $owner/$name -> $mirror"
        git clone --mirror "${GITHUB_BASE_URL%/}/$owner/$name.git" "$mirror" >> "$LOG_DIR/git.log" 2>&1
      fi
    ) 8>"$GIT_DIR/.clone.lock"
  fi
  echo "$mirror"
}

# --- discover candidates for one repo -----------------------------------------
discover() {
  local repo="$1" reviewer p row cid pr since
  local owner="${repo%%/*}" name="${repo##*/}"
  local -a REQ MENT
  reviewer="$(eff_repo "$repo" | jq -r '.reviewer')"
  ensure_mirror "$owner" "$name" >/dev/null

  # 1) requested as reviewer (GitHub search)
  mapfile -t REQ < <(requested_prs "$repo" "$reviewer") || true
  for p in "${REQ[@]+"${REQ[@]}"}"; do
    [ -n "$p" ] || continue
    CANDIDATES["$(KEY "$repo" "$p")"]="review_requested"
  done

  # 2) @mention in an issue/PR comment within the window
  since="$(date -u -d "-$MENTION_WINDOW_HOURS hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-${MENTION_WINDOW_HOURS}H +%Y-%m-%dT%H:%M:%SZ)"
  mapfile -t MENT < <(
    "$GH" api "repos/$repo/issues/comments?since=$since&per_page=100" --paginate \
      -q '.[] | select(.user.login != "'"$reviewer"'") | select(.body | test("@'"$reviewer"'"; "i")) | [.id, (.issue_url | split("/") | last)] | @tsv' 2>/dev/null
  ) || true
  for row in "${MENT[@]+"${MENT[@]}"}"; do
    [ -n "$row" ] || continue
    cid="${row%%$'\t'*}"; pr="${row##*$'\t'}"
    handled_comment "$cid" && continue   # already seen: don't rewrite state every poll
    mark_handled_comment "$cid" "$pr" "$repo"
    if [ "$pr" != "0" ] && [ -n "$pr" ] && ! handled_pr "$repo" "$pr"; then
      CANDIDATES["$(KEY "$repo" "$pr")"]="${CANDIDATES["$(KEY "$repo" "$pr")"]:-mentioned}"
    fi
  done
}

# --- launch one review session ------------------------------------------------
launch_review() {
  local repo="$1" pr="$2" reason="$3"
  local owner="${repo%%/*}" name="${repo##*/}"
  local mirror="$GIT_DIR/$owner-$name.git"
  local wtbase="$WORKTREE_BASE/$owner-$name"
  local wt="$wtbase/pr-$pr"
  local SAFE_REPO="$(echo "$repo" | tr '/' '-')"
  local SESSION_LOG="$LOG_DIR/session-pr-$SAFE_REPO-$pr-$(date +%Y%m%d-%H%M%S).log"
  local PROMPT_FILE="$LOG_DIR/prompt-$SAFE_REPO-$pr.txt"
  local MODEL_PATCH="$STATE_DIR/model-patch-$SAFE_REPO.yml"
  local pair base_ref head_sha reviewer custom_prompt harness
  # Inside the per-repo worktree area: it is the agent's cwd, it is already
  # --add-dir'd, and it keeps the payload out of the bot's own state/ dir.
  local REVIEW_JSON="$wtbase/review-pr-$pr.json"
  local mprovider mname meffort
  local entry

  entry="$(eff_repo "$repo")"
  [ -n "$entry" ] || { log "FATAL: repo $repo not found in effective config"; return 1; }
  reviewer="$(jq -r '.reviewer' <<<"$entry")"
  harness="$(jq -r '.harness // "dsh"' <<<"$entry")"
  custom_prompt="$(jq -r '.custom_prompt' <<<"$entry")"
  mprovider="$(jq -r '.model.provider' <<<"$entry")"
  mname="$(jq -r '.model.model' <<<"$entry")"
  meffort="$(jq -r '.model.reasoningEffort' <<<"$entry")"

  pair="$("$GH" api "repos/$repo/pulls/$pr" -q '"\(.base.ref)\t\(.head.sha)"' 2>/dev/null || true)"
  base_ref="${pair%%$'\t'*}"; [ -n "$base_ref" ] || base_ref="main"
  head_sha="${pair##*$'\t'}"

  # --- per-harness preflight: fail before touching the PR ----------------------
  case "$harness" in
    dsh)
      [ -n "${DSH_BIN:-}" ] && [ -x "$NODE" ] || { log "FATAL: harness dsh needs NODE + DSH_BIN (node=$NODE dsh=${DSH_BIN:-unset})"; return 1; }
      # per-repo model patch (dsh selects its model through this patch layer)
      {
        echo "# generated from config.json (effective model for $repo)"
        echo "- id: agent-default-model"
        echo "  config:"
        printf '    provider: %s\n' "$mprovider"
        printf '    model: %s\n' "$mname"
        [ -n "$meffort" ] && printf '    reasoningEffort: %s\n' "$meffort"
      } > "$MODEL_PATCH"
      ;;
    claude)
      [ -x "$CLAUDE_BIN" ] || { log "FATAL: harness claude: no executable claude at $CLAUDE_BIN (set claude.bin or \$CLAUDE_BIN)"; return 1; }
      if [ -n "$CLAUDE_CONFIG_DIR_EFF" ] && [ ! -d "$CLAUDE_CONFIG_DIR_EFF" ]; then
        log "FATAL: harness claude: config_dir $CLAUDE_CONFIG_DIR_EFF does not exist"; return 1
      fi
      if [ -z "${ANTHROPIC_API_KEY:-}" ] \
         && [ ! -f "${CLAUDE_CONFIG_DIR_EFF:-$HOME/.claude}/.credentials.json" ]; then
        log "WARNING: no .credentials.json in ${CLAUDE_CONFIG_DIR_EFF:-$HOME/.claude} and ANTHROPIC_API_KEY is unset — the session will probably fail to authenticate (set claude.config_dir to a logged-in profile)"
      fi
      case "$meffort" in
        ""|low|medium|high|xhigh|max) ;;
        *) log "WARNING: reasoningEffort '$meffort' is not a claude --effort level; ignoring"; meffort="";;
      esac
      ;;
    *) log "FATAL: unknown harness '$harness' for $repo (expected dsh or claude)"; return 1;;
  esac

  # manage the "review in progress" status comment on the PR
  local status_cid old_cid
  status_cid=""
  old_cid="$(jq -r --arg k "$(KEY "$repo" "$pr")" '.handled_prs[$k].status_comment // ""' "$STATE_FILE" 2>/dev/null)"
  if [ -n "$old_cid" ]; then
    "$GH" api --method DELETE "repos/$repo/issues/comments/$old_cid" >/dev/null 2>&1 || true
  fi
  status_cid="$(post_status_comment "$repo" "$pr" "$reviewer" "$harness" "$mprovider" "$mname" "$meffort" "$head_sha")"
  [ -n "$status_cid" ] || log "WARNING: could not post status comment on $repo#$pr"

  # write the custom prompt verbatim (avoids bash re-expanding $ / backticks inside it)
  local CP_FILE="$STATE_DIR/custom-prompt-$(echo "$repo" | tr '/' '-').txt"
  printf '%s\n' "$custom_prompt" > "$CP_FILE"

  mkdir -p "$wtbase"
  cat > "$PROMPT_FILE" <<EOF
You are the automated code reviewer for PR #$pr in $repo. A teammate asked @$reviewer to review it; you are acting on their behalf.

CUSTOM REVIEW INSTRUCTIONS (follow these first):
$(cat "$CP_FILE")

SETUP — a git mirror and a per-PR worktree give you a real local checkout:

    Mirror:   $mirror
    Worktree: $wt    (base branch: $base_ref)

Do the review from the worktree:

1. Sync the worktree to the PR head:
   git --git-dir="$mirror" fetch origin pull/$pr/head
   if [ ! -d "$wt" ]; then
     mkdir -p "$wtbase"
     git --git-dir="$mirror" worktree add --detach "$wt" FETCH_HEAD
   else
     git -C "$wt" fetch origin pull/$pr/head
     git -C "$wt" reset --hard FETCH_HEAD
   fi

2. Study the change:
   - git -C "$wt" log --oneline "$base_ref"..HEAD
   - git -C "$wt" diff "$base_ref"...HEAD
   - Read the changed files in full ($wt); check build config, error handling, tests, and how it integrates with the rest of the codebase.

3. Audit per the custom instructions above. For EVERY finding, prefer an INLINE comment: pick {path, line (a line number inside the diff hunk, right side), body}. Group findings, then post them in ONE review.

   Write the payload to a file (NOT a shell heredoc) and post it with --input:

     payload file: $REVIEW_JSON
     shape: {"event":"APPROVE","body":"<concise summary of the audit>","comments":[{"path":"<file>","line":<n>,"body":"<finding>"}]}
     post it:      gh api "repos/$repo/pulls/$pr/reviews" --input "$REVIEW_JSON"

   Decide the event by ONE rule:
   - APPROVE whenever there are NO blocking problems. All suggestions and minor notes must be
     attached as inline comments to the approve — they never block it.
   - REQUEST_CHANGES only when at least one blocking issue must be fixed before merge.
   - COMMENT only when you are unsure or the PR is an early draft.
   If a comment's line is rejected as outside the hunk, drop the line and fold the finding
   into the summary body (or post it as a plain PR comment via gh api repos/$repo/issues/$pr/comments -f body=...).
   Write the review in the same language as the PR.

4. After posting, remove the worktree and the payload file to keep things tidy:
   git --git-dir="$mirror" worktree remove --force "$wt" 2>/dev/null || true
   git --git-dir="$mirror" worktree prune 2>/dev/null || true
   rm -f "$REVIEW_JSON"

5. After posting your review, delete the "review in progress" comment from this PR
   (id: $status_cid) so it does not linger: gh api --method DELETE repos/$repo/issues/comments/$status_cid
   (If it is already gone or the delete fails, that is fine — the poller retries the cleanup.)

6. Finish by reporting: what you reviewed, key findings, and the posted review id.
EOF

  # claude reads the prompt on stdin (no argv size limit) and needs the mirror /
  # worktree trees allow-listed because they live outside its cwd.
  local -a cargs=(-p --permission-mode bypassPermissions --output-format json
                  --add-dir "$GIT_DIR" --add-dir "$WORKTREE_BASE")
  [ -n "$mname" ] && cargs+=(--model "$mname")
  [ -n "$meffort" ] && cargs+=(--effort "$meffort")

  local hinfo="harness=$harness, session_env=${SESSION_ENV_COUNT}var"
  [ "$harness" = "claude" ] && hinfo="$hinfo, bin=$CLAUDE_BIN, profile=${CLAUDE_CONFIG_DIR_EFF:-<claude default>}"
  # 9>&- / 7>&-: the session must NOT inherit the poll lock (fd 9) or the state
  # lock (fd 7). An inherited fd 9 kept the flock held for the session's whole
  # lifetime, so every later poll logged "another poll is running, skip" and no
  # other repo or PR could be discovered until the review finished.
  log "PR #$repo/$pr: launching review session ($reason; $hinfo, model=${mprovider:+$mprovider/}$mname)"
  (
    # Machine-specific environment for the agent, from config.json's session_env
    # (values must be single-line). The poller inherits a shell env when run by
    # hand but NOT when run by systemd, and on this network the model API is only
    # reachable through a local proxy — without it the session dies at once with
    # "403 Request not allowed". Keeping this in config.json (which is gitignored)
    # leaves the vendored systemd unit machine-independent.
    while IFS= read -r kv; do
      [ -n "$kv" ] && export "$kv"
    done < <(jq -r '(.session_env // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")

    # setsid: the session leads its own process group, so a later head-moved kill
    # reaches its git/gh children instead of orphaning them on the worktree.
    case "$harness" in
      claude)
        # Keep the agent's cwd out of $BOT_DIR (config.json, logs/prompt-*.txt) and
        # narrow the git credential to the repo under review, so a prompt injection
        # in PR content cannot reach the bot's own files or other repos.
        cd "$wtbase"
        export GIT_CONFIG_KEY_0="http.${GITHUB_BASE_URL%/}/$repo.git.extraheader"
        [ -n "$CLAUDE_CONFIG_DIR_EFF" ] && export CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_EFF"
        nohup setsid "$CLAUDE_BIN" "${cargs[@]}" < "$PROMPT_FILE" > "$SESSION_LOG" 2>&1 9>&- 7>&- &
        ;;
      *)
        cd "$BOT_DIR"
        nohup setsid "$NODE" --expose-internals "$DSH_BIN" --profile headless --patch "$MODEL_PATCH" \
          "$(cat "$PROMPT_FILE")" > "$SESSION_LOG" 2>&1 9>&- 7>&- &
        ;;
    esac
    echo $! > "$(pidfile_for "$repo" "$pr")"
  )
  mark_handled_pr "$repo" "$pr" "$reason" "$SESSION_LOG" "$head_sha" "$status_cid"
  log "PR #$repo/$pr: session launched (head $head_sha, status comment $status_cid), log: $SESSION_LOG"
}

# --- main: discover + throttle + launch ---------------------------------------
main() {
  if [ "${FORCE:-0}" != "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    LAST_POLL="$(cat "$LAST_POLL_FILE" 2>/dev/null || echo 0)"
    NOW_EPOCH="$(date +%s)"
    local elapsed=$((NOW_EPOCH - LAST_POLL))
    if [ "$elapsed" -lt $((POLL_INTERVAL_MINUTES * 60)) ]; then
      log "skip: last poll ${elapsed}s ago (< ${POLL_INTERVAL_MINUTES}m interval)"
      exit 0
    fi
    date +%s > "$LAST_POLL_FILE"
  elif [ "${DRY_RUN:-0}" = "1" ]; then
    date +%s > "$LAST_POLL_FILE"
  fi

  report_interrupted
  cleanup_status_comments
  prune_handled_comments

  declare -A CANDIDATES=()
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    discover "$repo"
  done < <(jq -r '.repos[].repo' "$EFFECTIVE_FILE")

  launched=0
  for key in $(printf '%s\n' "${!CANDIDATES[@]}" | sort); do
    [ "$launched" -ge "$MAX_SESSIONS_PER_POLL" ] && break
    repo="${key%%#*}"; pr="${key##*#}"
    [ -n "$pr" ] || continue
    reason="${CANDIDATES[$key]}"
    reviewer="$(eff_repo "$repo" | jq -r '.reviewer')"

    # --- already handled: only re-review when the PR was re-requested AND changed
    if handled_pr "$repo" "$pr"; then
      pidfile="$(pidfile_for "$repo" "$pr")"
      cur_sha="$(head_of "$repo" "$pr")"
      last_sha="$(jq -r --arg k "$(KEY "$repo" "$pr")" '.handled_prs[$k].head_sha // ""' "$STATE_FILE")"

      if [ "$reason" != "review_requested" ]; then
        log "PR #$repo/$pr: handled ($(jq -r --arg k "$(KEY "$repo" "$pr")" '.handled_prs[$k].reason' "$STATE_FILE")) — skip"
        prune_pidfile "$pidfile"
        continue
      fi

      # A failed head lookup must not be read as "the head moved": comparing an
      # empty sha would trigger a pointless full re-review.
      if [ -z "$cur_sha" ]; then
        log "PR #$repo/$pr: could not read current head from GitHub — skip this round"
        continue
      fi

      # running session: if the PR head moved since the session started, kill it
      # now and fall through to immediately re-review the new commit
      if pid="$(read_pid "$pidfile")" && pid_alive "$pid"; then
        if [ -n "$last_sha" ] && [ "$cur_sha" != "$last_sha" ]; then
          if [ "${DRY_RUN:-0}" = "1" ]; then
            log "PR #$repo/$pr: PR head changed while reviewing ($last_sha -> $cur_sha) — DRY_RUN: would kill in-flight session (pid $pid)"
            launched=$((launched+1)); continue
          fi
          log "PR #$repo/$pr: PR head changed while reviewing ($last_sha -> $cur_sha) — killing in-flight session (pid $pid)"
          kill_session "$pid"      # waits for it to actually die before we relaunch
          rm -f "$pidfile"
        else
          log "PR #$repo/$pr: review session already running (pid $pid) — skip"
          continue
        fi
      fi

      reviewed="$(reviewed_by "$repo" "$pr" "$reviewer")"   # latest live review's commit_id ("" = none)
      if [ -n "$reviewed" ] && [ "$cur_sha" = "$reviewed" ]; then
        log "PR #$repo/$pr: re-requested but no change (head $cur_sha, review still targets it) — skip"
        prune_pidfile "$pidfile"
        continue
      fi
      log "PR #$repo/$pr: re-requested with change (head $cur_sha, last review targeted ${reviewed:-none}, live review: $([ -n "$reviewed" ] && echo yes || echo no)) — re-reviewing"
      if [ "${DRY_RUN:-0}" = "1" ]; then
        launched=$((launched+1)); continue
      fi
      at_session_cap "$repo" "$pr" && continue
      launch_review "$repo" "$pr" "re-request"
      launched=$((launched+1))
      continue
    fi

    # --- new candidate
    reviewed="$(reviewed_by "$repo" "$pr" "$reviewer")"
    if [ -n "$reviewed" ]; then
      log "PR #$repo/$pr: already reviewed by $reviewer — marking handled, skip"
      mark_handled_pr "$repo" "$pr" "already_reviewed" "" "$(head_of "$repo" "$pr")"
      continue
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
      log "PR #$repo/$pr: DRY_RUN — would launch session (reason=$reason)"
      launched=$((launched+1))
      continue
    fi
    at_session_cap "$repo" "$pr" && continue
    launch_review "$repo" "$pr" "$reason"
    launched=$((launched+1))
  done

  log "poll done — launched=$launched repos=$(jq '.repos|length' "$EFFECTIVE_FILE")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi