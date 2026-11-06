#!/usr/bin/env bash
# Regression test for wt's PR lookup. `gh pr list --head <branch>` matches the head
# branch name across every fork, so the list can hold PRs that are not this worktree's
# (a branch named "main" matches every fork PR from main). gh is stubbed with canned
# PR lists; the test checks what `wt list` and `wt prune` report for one worktree.
# Usage: tests/lookup_pr_test.sh [path/to/wt]     (exit 0 = all pass)
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "needs jq (the gh stub filters with it)"; exit 2; }

WT=${1:-"$(dirname "$0")/../wt"}
WT=$(cd "$(dirname "$WT")" && pwd)/$(basename "$WT")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME/worktrees" "$tmp/bin"

# gh stub: `pr list -q FILTER` applies FILTER to the canned list in $STUB_PRS; any other
# gh call fails, which wt already treats as "no answer".
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pr list" ]; then
  f=""; while [ $# -gt 0 ]; do [ "$1" = "-q" ] && f=$2; shift; done
  exec jq -r "$f" <"$STUB_PRS"
fi
exit 1
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# repo "repo": trunk holds c0; feature-x holds c1 and is checked out in a worktree.
src="$tmp/src/repo"; mkdir -p "$src"
git -C "$src" init -q -b trunk
git -C "$src" commit -q --allow-empty -m c0
c0=$(git -C "$src" rev-parse HEAD)
git -C "$src" remote add origin https://github.com/example/repo.git
git -C "$src" checkout -q -b feature-x
git -C "$src" commit -q --allow-empty -m c1
c1=$(git -C "$src" rev-parse HEAD)
git -C "$src" checkout -q trunk
git -C "$src" worktree add -q "$HOME/worktrees/repo-feature-x" feature-x

pr() { # number state head-sha [head-owner]
  printf '{"number":%s,"state":"%s","isDraft":false,"url":"https://github.com/example/repo/pull/%s","milestone":null,"assignees":[],"headRefOid":"%s","headRepositoryOwner":{"login":"%s"}}' "$1" "$2" "$1" "$3" "${4:-example}"
}

fails=0
check() { # label, condition-exit-status
  if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

run_case() { # label, canned PR list (JSON array)
  printf '%s' "$2" >"$tmp/prs.json"
  export STUB_PRS="$tmp/prs.json"
  row=$(bash "$WT" list 2>&1 | grep -F 'feature-x')
  prune=$(echo n | bash "$WT" prune 2>&1)
  echo "  row:   $row"
  echo "  prune: $(echo "$prune" | tr '\n' ' ')"
  echo "$row" >"$tmp/row.txt"; echo "$prune" >"$tmp/prune.txt"
}

# A: the first PR listed for the branch is an old CLOSED one; the worktree's own PR is the
# OPEN one (its head is not HEAD, the branch has unpushed commits). Must show the OPEN PR
# and prune must not offer anything.
run_case A "[$(pr 7 CLOSED "$c0"),$(pr 9 OPEN "$c0")]"
grep -Eq ' 9 +OPEN ' "$tmp/row.txt"; check "A shows the open PR 9, not the closed PR 7" $?
grep -q 'CLOSED' "$tmp/row.txt"; [ $? -ne 0 ]; check "A row has no CLOSED" $?
grep -q 'nothing to prune' "$tmp/prune.txt"; check "A prune offers nothing" $?

# B: branch name reused. Only an old CLOSED PR exists, with a head that is not this
# worktree's HEAD. Must not claim CLOSED, and prune must not offer to remove the worktree.
run_case B "[$(pr 7 CLOSED "$c0")]"
grep -q 'CLOSED' "$tmp/row.txt"; [ $? -ne 0 ]; check "B row has no CLOSED" $?
grep -q 'nothing to prune' "$tmp/prune.txt"; check "B prune offers nothing" $?

# C: the worktree's own PR is MERGED and its head is HEAD. Must still show it and offer
# to prune it (no regression on the normal case).
run_case C "[$(pr 7 MERGED "$c1")]"
grep -Eq ' 7 +MERGED ' "$tmp/row.txt"; check "C shows merged PR 7" $?
grep -q 'Removable:' "$tmp/prune.txt"; check "C prune offers the merged worktree" $?

# old is a head that was never pulled ("Update branch" or a suggestion applied on GitHub).
old=0123456789abcdef0123456789abcdef01234567

# D: the worktree is named for its PR (repo-7-…). That PR is MERGED on a head that was never
# pulled, and an older closed PR with the same branch name is listed first. Must show PR 7 MERGED.
git -C "$src" worktree add -q -b feature-z "$HOME/worktrees/repo-7-feature-z" trunk
git -C "$HOME/worktrees/repo-7-feature-z" commit -q --allow-empty -m c2
printf '%s' "[$(pr 3 CLOSED "$c0"),$(pr 7 MERGED "$old")]" >"$tmp/prs.json"
export STUB_PRS="$tmp/prs.json"
row_z=$(bash "$WT" list 2>&1 | grep -F 'feature-z')
echo "  row:   $row_z"
grep -Eq ' 7 +MERGED ' <<<"$row_z"; check "D shows PR 7 named in the worktree, not older PR 3" $?

# D2: same worktree, but PR 7's head is c1: local, and HEAD (c2) is not contained in it, so
# the branch holds new work past the merged PR. The number alone must not make it MERGED,
# and prune must not offer the worktree.
printf '%s' "[$(pr 3 CLOSED "$c0"),$(pr 7 MERGED "$c1")]" >"$tmp/prs.json"
row_z=$(bash "$WT" list 2>&1 | grep -F 'feature-z')
echo "  row:   $row_z"
[ -n "$row_z" ] && ! grep -q 'MERGED' <<<"$row_z"; check "D2 numbered worktree with commits past its merged PR shows no MERGED" $?
prune_z=$(echo n | bash "$WT" prune 2>&1)
! grep -q 'feature-z' <<<"$prune_z"; check "D2 prune does not offer it" $?

# E: same worktree (HEAD = c2). PR 7 (named in the worktree) is MERGED on an old head, but
# PR 8 is OPEN on HEAD itself. The head-commit match must win over the number in the name.
printf '%s' "[$(pr 7 MERGED "$c1"),$(pr 8 OPEN "$(git -C "$HOME/worktrees/repo-7-feature-z" rev-parse HEAD)")]" >"$tmp/prs.json"
row_e=$(bash "$WT" list 2>&1 | grep -F 'feature-z')
echo "  row:   $row_e"
grep -Eq ' 8 +OPEN ' <<<"$row_e"; check "E head-commit match (PR 8) beats the number in the name (PR 7)" $?

# The cases below have a branch that pushes to a known remote, so the PR's head owner decides.
row_of() { bash "$WT" list 2>&1 | grep -F "$1"; }

# F: HEAD is behind the merged PR's head, the worktree has no number, and another fork has
# an open PR from a branch of the same name. Must show the own merged PR and offer to prune.
git -C "$src" worktree add -q -b feature-f "$HOME/worktrees/repo-feature-f" trunk
git -C "$src" config branch.feature-f.remote origin
printf '%s' "[$(pr 11 OPEN "$old" someone),$(pr 10 MERGED "$old")]" >"$tmp/prs.json"
row_f=$(row_of feature-f); echo "  row:   $row_f"
grep -Eq ' 10 +MERGED ' <<<"$row_f"; check "F shows the own merged PR 10, not the other fork's open PR 11" $?
prune_f=$(echo n | bash "$WT" prune 2>&1)
grep -q 'feature-f' <<<"$prune_f"; check "F prune offers the merged worktree" $?
git -C "$src" worktree remove "$HOME/worktrees/repo-feature-f"

# G: started with `wt <issue>`, so the name holds issue 42, not the PR number. Another fork's
# closed PR is listed first. Must show the own merged PR 50.
git -C "$src" worktree add -q -b fix-thing "$HOME/worktrees/repo-42-fix-thing" trunk
git -C "$src" config branch.fix-thing.remote origin
printf '%s' "[$(pr 49 CLOSED "$old" someone),$(pr 50 MERGED "$old")]" >"$tmp/prs.json"
row_g=$(row_of fix-thing); echo "  row:   $row_g"
grep -Eq ' 50 +MERGED ' <<<"$row_g"; check "G shows the own merged PR 50 for an issue-numbered worktree" $?

# H: the branch pushes to origin (owner example) and only other forks have PRs from a branch
# of that name. Must show no PR, and owners compare case-insensitively.
printf '%s' "[$(pr 12 OPEN "$old" someone),$(pr 13 MERGED "$old" other)]" >"$tmp/prs.json"
row_h=$(row_of fix-thing); echo "  row:   $row_h"
[ -n "$row_h" ] && ! grep -Eq ' (12|13) ' <<<"$row_h"; check "H shows no PR from other forks" $?
printf '%s' "[$(pr 50 MERGED "$old" Example)]" >"$tmp/prs.json"
grep -Eq ' 50 +MERGED ' <<<"$(row_of fix-thing)"; check "H owner match ignores case" $?

# I: as `gh pr checkout` sets it, the branch pushes to a bare fork URL. Must show that fork's PR.
git -C "$src" config branch.fix-thing.remote https://github.com/someone/repo.git
printf '%s' "[$(pr 50 MERGED "$old"),$(pr 49 CLOSED "$old" someone)]" >"$tmp/prs.json"
grep -Eq ' 49 +CLOSED ' <<<"$(row_of fix-thing)"; check "I a bare-URL push remote selects its owner's PR 49" $?

# J: a reused branch name in the same repo. The own closed PR's head (c1) is local and HEAD has
# a commit beyond it, so the worktree holds new work. Must not claim CLOSED or offer a prune.
git -C "$src" worktree add -q -b feature-j "$HOME/worktrees/repo-feature-j" "$c1"
git -C "$HOME/worktrees/repo-feature-j" commit -q --allow-empty -m c3
git -C "$src" config branch.feature-j.remote origin
printf '%s' "[$(pr 14 CLOSED "$c1")]" >"$tmp/prs.json"
row_j=$(row_of feature-j); echo "  row:   $row_j"
[ -n "$row_j" ] && ! grep -q 'CLOSED' <<<"$row_j"; check "J row has no CLOSED when HEAD is ahead of the closed PR" $?
prune_j=$(echo n | bash "$WT" prune 2>&1)
grep -Eq 'nothing to prune|aborted' <<<"$prune_j" && ! grep -q 'feature-j' <<<"$prune_j"; check "J prune does not offer it" $?

# K: the merged PR's head (c1) was fetched and HEAD (c0) is behind it. Must show MERGED.
git -C "$src" worktree add -q -b feature-k "$HOME/worktrees/repo-feature-k" "$c0"
git -C "$src" config branch.feature-k.remote origin
printf '%s' "[$(pr 15 MERGED "$c1")]" >"$tmp/prs.json"
grep -Eq ' 15 +MERGED ' <<<"$(row_of feature-k)"; check "K shows the merged PR 15 when HEAD is behind its fetched head" $?

# L: the remote's name has a slash and it fetches from example but pushes to someone (the
# push URL decides). Among the owner's PRs an open one beats a closed one listed first.
git -C "$src" remote add fork/alice https://github.com/example/repo.git
git -C "$src" remote set-url --push fork/alice git@github.com:someone/repo.git
git -C "$src" config branch.feature-k.remote fork/alice
printf '%s' "[$(pr 15 MERGED "$old"),$(pr 16 CLOSED "$old" someone),$(pr 17 OPEN "$old" someone)]" >"$tmp/prs.json"
grep -Eq ' 17 +OPEN ' <<<"$(row_of feature-k)"; check "L the push URL's owner decides, and its open PR 17 wins" $?

# M: two PRs have HEAD itself as head and the newer one, listed first, is CLOSED (closed and
# reopened as a new PR from the same commit). Among head matches the open one must win.
printf '%s' "[$(pr 19 CLOSED "$c1"),$(pr 18 OPEN "$c1")]" >"$tmp/prs.json"
grep -Eq ' 18 +OPEN ' <<<"$(row_of feature-x)"; check "M among head-commit matches the open PR 18 beats the newer closed PR 19" $?

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit "$fails"
