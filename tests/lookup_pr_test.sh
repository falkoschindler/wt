#!/usr/bin/env bash
# Regression test for wt's PR lookup. `gh pr list --head <branch>` matches the head
# branch name across every fork, so the list can hold PRs that are not this worktree's
# (a branch named "main" matches every fork PR from main). gh is stubbed with canned
# PR lists; the test checks what `wt list` and `wt prune` report for one worktree.
# Usage: tests/lookup_pr_test.sh [path/to/wt]     (exit 0 = all pass)
set -uo pipefail

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

pr() { # number state head-sha
  printf '{"number":%s,"state":"%s","isDraft":false,"url":"https://github.com/example/repo/pull/%s","milestone":null,"assignees":[],"headRefOid":"%s"}' "$1" "$2" "$1" "$3"
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

# D: the worktree is named for its PR (repo-7-…). That PR is MERGED, but its head is no
# longer the worktree's HEAD (the branch moved on), and an older closed PR with the same
# branch name is listed first. Must show PR 7 MERGED.
git -C "$src" worktree add -q -b feature-z "$HOME/worktrees/repo-7-feature-z" trunk
git -C "$HOME/worktrees/repo-7-feature-z" commit -q --allow-empty -m c2
printf '%s' "[$(pr 3 CLOSED "$c0"),$(pr 7 MERGED "$c1")]" >"$tmp/prs.json"
export STUB_PRS="$tmp/prs.json"
row_z=$(bash "$WT" list 2>&1 | grep -F 'feature-z')
echo "  row:   $row_z"
grep -Eq ' 7 +MERGED ' <<<"$row_z"; check "D shows PR 7 named in the worktree, not older PR 3" $?

# E: same worktree (HEAD = c2). PR 7 (named in the worktree) is MERGED on an old head, but
# PR 8 is OPEN on HEAD itself. The head-commit match must win over the number in the name.
printf '%s' "[$(pr 7 MERGED "$c1"),$(pr 8 OPEN "$(git -C "$HOME/worktrees/repo-7-feature-z" rev-parse HEAD)")]" >"$tmp/prs.json"
row_e=$(bash "$WT" list 2>&1 | grep -F 'feature-z')
echo "  row:   $row_e"
grep -Eq ' 8 +OPEN ' <<<"$row_e"; check "E head-commit match (PR 8) beats the number in the name (PR 7)" $?

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit "$fails"
