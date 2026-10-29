#!/usr/bin/env bash
# Ticket workflow: branch + worktree -> PR to main -> CI + review-agent -> squash-merge.
# Full rules: docs/agents/workflow.md. Bash 3.2-safe (macOS default).
#
#   scripts/ticket.sh start <n> [--here]        branch ticket/<nn>-<slug> from origin/main,
#                                               in a new worktree (or the current one with --here)
#   scripts/ticket.sh pr <n> [criteria.md]      push + open the PR to main ("#<n>: <title>",
#                                               "Closes #<n>", acceptance criteria with evidence)
#   scripts/ticket.sh review <n> pass|fail <findings.md>
#                                               post findings as a PR comment and set the
#                                               review-agent commit status on the head commit
#   scripts/ticket.sh land <n>                  rebase if behind main, else gate + squash-merge
#                                               + clean branch and worktree
#   scripts/ticket.sh status <n>                show PR, CI and review-agent state
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
MAIN_CHECKOUT="$(dirname "$COMMON")"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
REVIEW_CONTEXT=review-agent

die() { echo "ticket: $*" >&2; exit 1; }
need_n() { case "${1:-}" in ''|*[!0-9]*) die "ticket number required";; esac; }
num() { echo $((10#$1)); }   # "08" -> 8 (printf %02d reads a leading 0 as octal)

issue_title() { gh issue view "$1" --repo "$REPO" --json title --jq .title; }
slug() {  # lowercase, dashes, at most 32 chars, cut at a word boundary
  local s; s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ "${#s}" -gt 32 ]; then
    local cut; cut="$(printf '%s' "$s" | cut -c1-33)"; cut="${cut%-*}"
    # no dash to cut at, or the word cut leaves almost nothing: hard cut at 32
    if [ "${#cut}" -gt 32 ] || [ "${#cut}" -lt 12 ]; then cut="$(printf '%s' "$s" | cut -c1-32)"; fi
    s="${cut%-}"
  fi
  printf '%s' "$s"
}
branch_for() {  # existing local or remote branch ticket/<nn>-*, else a new name
  local nn; nn="$(printf '%02d' "$1")"
  local b; b="$(git for-each-ref --format='%(refname:short)' "refs/heads/ticket/$nn-*" "refs/remotes/origin/ticket/$nn-*" | sed 's#^origin/##' | head -1)"
  if [ -n "$b" ]; then echo "$b"; else echo "ticket/$nn-$(slug "$(issue_title "$1")")"; fi
}
worktree_of() {  # path of the worktree that has branch $1 checked out
  git worktree list --porcelain | awk -v b="refs/heads/$1" '/^worktree /{p=substr($0,10)} $0=="branch "b{print p}'
}
pr_of() { gh pr list --repo "$REPO" --head "$1" --state open --json number --jq '.[0].number // empty'; }

cmd_start() {
  need_n "${1:-}"; local n here="${2:-}"; n="$(num "$1")"
  git fetch -q origin
  local b; b="$(branch_for "$n")"
  git show-ref -q "refs/heads/$b" && die "$b already exists (worktree: $(worktree_of "$b"))"
  local base=origin/main   # a branch that exists only on the remote resumes from there
  git show-ref -q "refs/remotes/origin/$b" && base="origin/$b"
  if [ "$here" = "--here" ]; then
    [ -z "$(git status --porcelain)" ] || die "current worktree is dirty"
    git switch -q -c "$b" "$base"
    echo "$ROOT"
  else
    local wt="$MAIN_CHECKOUT/.claude/worktrees/ticket-$(printf '%02d' "$n")"
    git worktree add -q -b "$b" "$wt" "$base"
    echo "$wt"
  fi
  echo "branch $b from $base" >&2
}

criteria_from_issue() {  # the issue's "## Acceptance criteria" section, unticked
  gh issue view "$1" --repo "$REPO" --json body --jq .body |
    awk '/^## Acceptance criteria/{on=1; next} /^## /{on=0} on' | sed '/^[[:space:]]*$/d'
}

cmd_pr() {
  need_n "${1:-}"; local n crit="${2:-}"; n="$(num "$1")"
  local b; b="$(git rev-parse --abbrev-ref HEAD)"
  case "$b" in "ticket/$(printf '%02d' "$n")-"*) ;; *) die "run from the ticket's worktree (on $b)";; esac
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes; commit first"
  [ -z "$(pr_of "$b")" ] || die "PR already open for $b: $(gh pr view "$b" --repo "$REPO" --json url --jq .url)"
  local body; body="$(mktemp)"
  {
    echo "Closes #$n"; echo
    echo "## Acceptance criteria"; echo
    if [ -n "$crit" ]; then cat "$crit"; else criteria_from_issue "$n"; fi
    echo
    echo "## Checks run locally"; echo
    echo "See the evidence on each criterion above."
  } > "$body"
  if [ -z "$crit" ]; then
    echo "ticket: no criteria file given; criteria copied unticked. Tick them with evidence (gh pr edit --body-file) before review." >&2
  fi
  git push -q -u origin "$b"
  gh pr create --repo "$REPO" --base main --head "$b" --title "#$n: $(issue_title "$n")" --body-file "$body"
  rm -f "$body"
}

cmd_review() {
  need_n "${1:-}"; local n verdict="${2:-}" findings="${3:-}"; n="$(num "$1")"
  case "$verdict" in pass) state=success;; fail) state=failure;; *) die "verdict must be pass or fail";; esac
  [ -f "$findings" ] || die "findings file required"
  local b pr sha; b="$(branch_for "$n")"; pr="$(pr_of "$b")"; [ -n "$pr" ] || die "no open PR for $b"
  sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
  { echo "**review-agent: $verdict** on \`${sha:0:7}\`"; echo; cat "$findings"; } | gh pr comment "$pr" --repo "$REPO" --body-file - >/dev/null
  gh api -X POST "repos/$REPO/statuses/$sha" -f state="$state" -f context="$REVIEW_CONTEXT" \
    -f description="review agent: $verdict" >/dev/null
  echo "PR #$pr ${sha:0:7}: $REVIEW_CONTEXT = $state"
}

review_state() { gh api "repos/$REPO/commits/$1/status" --jq ".statuses[] | select(.context==\"$REVIEW_CONTEXT\") | .state" | head -1; }

cmd_status() {
  need_n "${1:-}"; local b pr sha; b="$(branch_for "$(num "$1")")"; pr="$(pr_of "$b")"
  [ -n "$pr" ] || { echo "$b: no open PR"; return; }
  sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
  gh pr view "$pr" --repo "$REPO" --json number,title,url,mergeStateStatus --jq '"PR #\(.number) \(.title)\n\(.url)\nmerge state: \(.mergeStateStatus)"'
  echo "review-agent on ${sha:0:7}: $(review_state "$sha" || true)"
  gh pr checks "$pr" --repo "$REPO" || true
}

cmd_land() {
  need_n "${1:-}"; local n; n="$(num "$1")"
  local b pr sha wt; b="$(branch_for "$n")"; pr="$(pr_of "$b")"; [ -n "$pr" ] || die "no open PR for $b"
  git fetch -q origin main "$b"
  if ! git merge-base --is-ancestor origin/main "origin/$b"; then
    wt="$(worktree_of "$b")"; [ -n "$wt" ] || die "$b is behind main and has no local worktree; run start or check it out"
    [ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || die "$wt has uncommitted changes"
    git -C "$wt" rebase -q origin/main || die "rebase conflicts in $wt; resolve, push, re-review, land again"
    git -C "$wt" push -q --force-with-lease origin "$b"
    echo "ticket: rebased $b onto main and pushed. Wait for CI, review the new head, then land again." >&2
    exit 3
  fi
  sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid)"
  [ "$(review_state "$sha")" != failure ] || die "review-agent failed on head ${sha:0:7}: send the findings back to the implementer (fix loop)"
  local rc=0; gh pr checks "$pr" --repo "$REPO" --watch --fail-fast >/dev/null || rc=$?
  [ "$rc" = 0 ] || die "checks not green on PR #$pr (gh pr checks $pr)"
  [ "$(review_state "$sha")" = success ] || die "no passing $REVIEW_CONTEXT status on head ${sha:0:7}"
  [ "$(gh pr view "$pr" --repo "$REPO" --json isDraft --jq .isDraft)" = false ] || die "PR #$pr is a draft"
  gh pr merge "$pr" --repo "$REPO" --squash --match-head-commit "$sha" --subject "#$n: $(issue_title "$n") (#$pr)"
  wt="$(worktree_of "$b")"
  if [ -n "$wt" ] && [ "$wt" != "$ROOT" ]; then
    if git worktree remove "$wt" 2>/dev/null; then
      echo "removed worktree $wt"; git branch -D "$b" >/dev/null 2>&1 || true
    else
      echo "ticket: WARNING: $wt has untracked or modified files; left in place with branch $b. Inspect, then: git worktree remove --force $wt && git branch -D $b" >&2
    fi
  elif [ -z "$wt" ]; then
    git branch -D "$b" >/dev/null 2>&1 || true
  fi
  git push -q origin --delete "$b" 2>/dev/null || true
  git fetch -q --prune origin
  echo "landed #$n via PR #$pr"
}

case "${1:-}" in
  start|pr|review|land|status) c="$1"; shift; "cmd_$c" "$@";;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
