#!/usr/bin/env bash
# poll.sh — poll the repos in config.json for PRs needing review and auto-launch
# a DSH headless review session per new PR (git-worktree based).
# Top-level config.json is the global config; each "repos[]" entry may override
# reviewer / model / custom_prompt. Also the single source of bot logic shared
# by run-now.sh and status.sh.
set -uo pipefail

# --- self-locating bot dir (safe to move the whole folder anywhere) ---------
BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$BOT_DIR/config.json}"
STATE_DIR="$BOT_DIR/state"
LOG_DIR="$BOT_DIR/logs"
STATE_FILE="$STATE_DIR/state.json"
LOCK_FILE="$STATE_DIR/poll.lock"
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
export PATH="$(dirname "$GH"):/usr/bin:/bin:$PATH"

log() { echo "[$(date -Is)] $*"; }

# --- load config.json + compute effective (global-overridden) config ----------
load_config() {
  [ -f "$CONFIG_FILE" ] || { log "FATAL: $CONFIG_FILE missing"; exit 1; }
  REVIEWER="$(jq -r '.reviewer // ""' "$CONFIG_FILE")"
  POLL_INTERVAL_MINUTES="$(jq -r '.poll_interval_minutes // 5' "$CONFIG_FILE")"
  MAX_SESSIONS_PER_POLL="$(jq -r '.max_sessions_per_poll // 2' "$CONFIG_FILE")"
  MENTION_WINDOW_HOURS="$(jq -r '.mention_window_hours // 24' "$CONFIG_FILE")"
  MODEL_PROVIDER="$(jq -r '.model.provider // ""' "$CONFIG_FILE")"
  MODEL_NAME="$(jq -r '.model.model // ""' "$CONFIG_FILE")"
  MODEL_EFFORT="$(jq -r '.model.reasoningEffort // ""' "$CONFIG_FILE")"
  CUSTOM_PROMPT="$(jq -r '.custom_prompt // ""' "$CONFIG_FILE")"
  TOKEN_ENV="$(jq -r '.gh.token_env // ""' "$CONFIG_FILE")"
  GITHUB_BASE_URL="$(jq -r '.gh.base_url // "https://github.com"' "$CONFIG_FILE")"
  local git_dir worktree_base
  git_dir="$(jq -r '.git_dir // "git"' "$CONFIG_FILE")"
  worktree_base="$(jq -r '.worktree_base // "worktrees"' "$CONFIG_FILE")"
  case "$git_dir" in /*) GIT_DIR="$git_dir";; *) GIT_DIR="$BOT_DIR/$git_dir";; esac
  case "$worktree_base" in /*) WORKTREE_BASE="$worktree_base";; *) WORKTREE_BASE="$BOT_DIR/$worktree_base";; esac

  # merge: per-repo fields fall back to global fields
  jq '{ repos: [ .repos[] | . as $r |
    {
      repo: $r.repo,
      reviewer: ($r.reviewer // $root.reviewer // ""),
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

load_config
mkdir -p "$STATE_DIR" "$LOG_DIR" "$GIT_DIR" "$WORKTREE_BASE"

# --- GitHub credentials for BOTH gh and git -----------------------------------
GITHUB_TOKEN=""
if [ -n "$TOKEN_ENV" ]; then
  GITHUB_TOKEN="${!TOKEN_ENV:-}"
  [ -n "$GITHUB_TOKEN" ] || log "WARNING: $TOKEN_ENV (config gh.token_env) is unset; falling back to gh auth token"
fi
[ -n "$GITHUB_TOKEN" ] || GITHUB_TOKEN="$("$GH" auth token 2>/dev/null || true)"
if [ -n "$GITHUB_TOKEN" ]; then
  export GITHUB_TOKEN
  TOKEN_B64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.${GITHUB_BASE_URL%/}/.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $TOKEN_B64"
  log "token injected for gh + git (source: ${TOKEN_ENV:-keyring})"
else
  log "WARNING: no GitHub token — private repos will fail"
fi

# --- single-instance lock (skipped when sourced by status.sh) ------------------
if [ "${SKIP_LOCK:-0}" != "1" ]; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || { log "another poll is running, skip"; exit 0; }
fi

# --- state helpers ------------------------------------------------------------
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
KEY() { echo "$1#$2"; }
handled_pr() { jq -e --arg k "$(KEY "$1" "$2")" '.handled_prs[$k] != null' "$STATE_FILE" >/dev/null 2>&1; }
handled_comment() { jq -e --arg c "$1" '.handled_comments[$c] != null' "$STATE_FILE" >/dev/null 2>&1; }
save_state() { mv "$STATE_FILE.tmp" "$STATE_FILE"; }
mark_handled_pr() {
  local key pr reason log
  key="$(KEY "$1" "$2")"; pr="$2"; reason="$3"; log="$4"
  jq --arg k "$key" --arg p "$pr" --arg r "$reason" --arg l "$log" --arg t "$NOW_ISO" \
    '.handled_prs[$k] = {pr: $p, triggered_at: $t, reason: $r, session_log: $l}' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && save_state
}
mark_handled_comment() {
  local cid="$1" pr="$2" repo="$3"
  jq --arg c "$cid" --arg p "$pr" --arg r "$repo" --arg t "$NOW_ISO" \
    '.handled_comments[$c] = {repo: $r, pr: $p, seen_at: $t}' \
    "$STATE_FILE" > "$STATE_FILE.tmp" && save_state
}

# --- per-repo effective config lookup ------------------------------------------
eff_repo() { jq -c --arg r "$1" '.repos[] | select(.repo == $r)' "$EFFECTIVE_FILE" 2>/dev/null; }

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
  local repo="$1" reviewer
  local owner="${repo%%/*}" name="${repo##*/}"
  reviewer="$(eff_repo "$repo" | jq -r '.reviewer')"
  ensure_mirror "$owner" "$name" >/dev/null

  # 1) requested as reviewer (GitHub search)
  mapfile -t REQ < <(
    "$GH" api graphql \
      -f query="query { search(query: \"repo:$repo is:pr is:open review-requested:$reviewer\", type: ISSUE, first: 100) { edges { node { ... on PullRequest { number } } } } }" \
      -q '.data.search.edges[].node.number' 2>/dev/null
  ) || true
  for p in "${REQ[@]+"${REQ[@]}"}"; do
    [ -n "$p" ] || continue
    CANDIDATES["$(KEY "$repo" "$p")"]="review_requested"
  done

  # 2) @mention in an issue/PR comment within the window
  SINCE="$(date -u -d "-$MENTION_WINDOW_HOURS hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-${MENTION_WINDOW_HOURS}H +%Y-%m-%dT%H:%M:%SZ)"
  mapfile -t MENT < <(
    "$GH" api "repos/$repo/issues/comments?since=$SINCE&per_page=100" --paginate \
      -q '.[] | select(.user.login != "'"$reviewer"'") | select(.body | test("@'"$reviewer"'"; "i")) | [.id, (.issue.number // 0)] | @tsv' 2>/dev/null
  ) || true
  for row in "${MENT[@]+"${MENT[@]}"}"; do
    [ -n "$row" ] || continue
    cid="${row%%$'\t'*}"; pr="${row##*$'\t'}"
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
  local SESSION_LOG="$LOG_DIR/session-pr-$pr-$(date +%Y%m%d-%H%M%S).log"
  local PROMPT_FILE="$LOG_DIR/prompt-$SAFE_REPO-$pr.txt"
  local MODEL_PATCH="$STATE_DIR/model-patch-$SAFE_REPO.yml"
  local base_ref reviewer custom_prompt
  local mprovider mname meffort
  local entry

  entry="$(eff_repo "$repo")"
  [ -n "$entry" ] || { log "FATAL: repo $repo not found in effective config"; return 1; }
  reviewer="$(jq -r '.reviewer' <<<"$entry")"
  custom_prompt="$(jq -r '.custom_prompt' <<<"$entry")"
  mprovider="$(jq -r '.model.provider' <<<"$entry")"
  mname="$(jq -r '.model.model' <<<"$entry")"
  meffort="$(jq -r '.model.reasoningEffort' <<<"$entry")"

  # per-repo model patch
  {
    echo "# generated from config.json (effective model for $repo)"
    echo "- id: agent-default-model"
    echo "  config:"
    printf '    provider: %s\n' "$mprovider"
    printf '    model: %s\n' "$mname"
    [ -n "$meffort" ] && printf '    reasoningEffort: %s\n' "$meffort"
  } > "$MODEL_PATCH"

  base_ref="$("$GH" api "repos/$repo/pulls/$pr" -q .base.ref 2>/dev/null || echo main)"

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

3. Audit per the custom instructions above. For EVERY finding, prefer an INLINE comment: pick {path, line (a line number inside the diff hunk, right side), body}. Group findings, then post them in ONE review:

   gh api repos/$repo/pulls/$pr/reviews --input - <<'JSON'
   {"event":"COMMENT","body":"<concise summary of the audit>","comments":[{"path":"<file>","line":<n>,"body":"<finding>"}]}
   JSON

   - Use event REQUEST_CHANGES when there are blocking issues, event COMMENT for minor points, event APPROVE only if the PR is genuinely ready (be conservative — almost never approve).
   - If a comment's line is rejected as outside the hunk, drop the line and fold the finding into the summary body (or post it as a plain PR comment via gh api repos/$repo/issues/$pr/comments -f body=...).
   - Write the review in the same language as the PR.

4. After posting, remove the worktree to keep things tidy:
   git --git-dir="$mirror" worktree remove --force "$wt" 2>/dev/null || true
   git --git-dir="$mirror" worktree prune 2>/dev/null || true

5. Finish by reporting: what you reviewed, key findings, and the posted review id.
EOF

  log "PR #$repo/$pr: launching review session ($reason; model=$mprovider/$mname)"
  (
    cd "$BOT_DIR"
    nohup "$NODE" --expose-internals "$DSH_BIN" --profile headless --patch "$MODEL_PATCH" \
      "$(cat "$PROMPT_FILE")" > "$SESSION_LOG" 2>&1 &
    echo $! > "$STATE_DIR/session-pr-$SAFE_REPO-$pr.pid"
  )
  mark_handled_pr "$repo" "$pr" "$reason" "$SESSION_LOG"
  log "PR #$repo/$pr: session launched, log: $SESSION_LOG"
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
    handled_pr "$repo" "$pr" && continue

    reviewer="$(eff_repo "$repo" | jq -r '.reviewer')"
    reviewed=$("$GH" api "repos/$repo/pulls/$pr/reviews" --paginate \
      -q '.[] | select(.user.login == "'"$reviewer"'") | select(.state != "DISMISSED")' 2>/dev/null | head -c1)
    if [ -n "$reviewed" ]; then
      log "PR #$repo/$pr: already reviewed by $reviewer — marking handled, skip"
      mark_handled_pr "$repo" "$pr" "already_reviewed" ""
      continue
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
      log "PR #$repo/$pr: DRY_RUN — would launch session (reason=${CANDIDATES[$key]})"
      launched=$((launched+1))
      continue
    fi
    launch_review "$repo" "$pr" "${CANDIDATES[$key]}"
    launched=$((launched+1))
  done

  log "poll done — launched=$launched repos=$(jq '.repos|length' "$EFFECTIVE_FILE")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi