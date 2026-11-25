#!/usr/bin/env bash
# Regression test for stale worktrees: when a worktree's directory is deleted (e.g. a
# cleaned-up temp dir), git keeps it registered, and `wt <branch>` used to reuse that dead
# path instead of creating a fresh worktree. Only entries under ~/worktrees are dropped;
# a locked one or one elsewhere makes wt stop. Runs against a local bare "origin", no gh.
# Usage: tests/stale_worktree_test.sh [path/to/wt]     (exit 0 = all pass)
set -uo pipefail

WT=${1:-"$(dirname "$0")/../wt"}
WT=$(cd "$(dirname "$WT")" && pwd)/$(basename "$WT")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WT_NO_OPEN=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME/worktrees"

# repo "repo" with a bare origin; branch feat exists locally and on origin.
git init -q --bare -b main "$tmp/origin.git"
repo="$tmp/src/repo"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
git -C "$repo" commit -q --allow-empty -m c0
git -C "$repo" push -q origin main
git -C "$repo" branch feat
git -C "$repo" push -q origin feat
target="$HOME/worktrees/repo-feat"

fails=0
check() { # label, condition-exit-status
  if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
wt() { out=$(cd "$repo" && bash "$WT" "$@" 2>&1); rc=$?; echo "  $(echo "$out" | tr '\n' ' ')"; }

# A: the dead worktree sat exactly at the target path. Must create it afresh, not report
# "reusing existing worktree" for a directory that does not exist.
git -C "$repo" worktree add -q "$target" feat
rm -rf "$target"
wt feat
[ "$rc" -eq 0 ] && [ -d "$target" ] && [ "$(git -C "$target" symbolic-ref --short HEAD)" = feat ]
check "A recreates the worktree at the target path (rc=$rc)" $?

# B: the dead worktree sat at another path. Must not open that path, but create the
# worktree at the target path.
rm -rf "$target"; git -C "$repo" worktree prune
git -C "$repo" worktree add -q "$HOME/worktrees/other" feat
rm -rf "$HOME/worktrees/other"
wt feat
[ "$rc" -eq 0 ] && [ -d "$target" ] && ! grep -q 'worktrees/other .*reusing' <<<"$out" \
  && grep -q 'dropped stale worktree .*/worktrees/other' <<<"$out"
check "B drops the dead worktree at another path and says so (rc=$rc)" $?

# C: a live worktree of the branch at another path is still reused (no regression).
rm -rf "$target"; git -C "$repo" worktree prune
git -C "$repo" worktree add -q "$HOME/worktrees/other" feat
wt feat
[ "$rc" -eq 0 ] && grep -q 'worktrees/other .*reusing existing worktree' <<<"$out" && [ ! -d "$target" ]
check "C still reuses a live worktree at another path (rc=$rc)" $?

# D: a dead worktree of ANOTHER branch is not touched (it may just be on an unmounted volume);
# only the entry in the way of this branch is dropped.
rm -rf "$target" "$HOME/worktrees/other"; git -C "$repo" worktree prune
git -C "$repo" branch other
git -C "$repo" worktree add -q "$HOME/worktrees/repo-other" other
rm -rf "$HOME/worktrees/repo-other"
wt feat
[ "$rc" -eq 0 ] && [ -d "$target" ] && git -C "$repo" worktree list --porcelain | grep -q "^worktree .*/worktrees/repo-other$"
check "D leaves a dead worktree of another branch registered (rc=$rc)" $?

# E: a LOCKED dead worktree of the branch is never `prunable`, so it is not dropped either;
# wt must stop with a hint instead of "reusing" a directory that is not there.
rm -rf "$target"; git -C "$repo" worktree remove --force "$HOME/worktrees/repo-other"; git -C "$repo" worktree prune
git -C "$repo" worktree add -q "$target" feat
git -C "$repo" worktree lock "$target"; rm -rf "$target"
wt feat
[ "$rc" -ne 0 ] && grep -q 'registered but its directory is missing' <<<"$out" && [ ! -d "$target" ] \
  && git -C "$repo" worktree list --porcelain | grep -q "^worktree .*/worktrees/repo-feat$"
check "E stops on a locked dead worktree and leaves it registered (rc=$rc)" $?

# F: a dead worktree OUTSIDE ~/worktrees (may be on an unmounted volume) is not dropped, even
# though it holds the branch: wt stops with the same hint.
git -C "$repo" worktree unlock "$target"; git -C "$repo" worktree remove --force "$target"
mkdir -p "$tmp/elsewhere"; git -C "$repo" worktree add -q "$tmp/elsewhere/feat" feat
rm -rf "$tmp/elsewhere/feat"
wt feat
[ "$rc" -ne 0 ] && grep -q 'registered but its directory is missing' <<<"$out" && [ ! -d "$target" ] \
  && git -C "$repo" worktree list --porcelain | grep -q "^worktree .*/elsewhere/feat$"
check "F leaves a dead worktree outside ~/worktrees alone and stops (rc=$rc)" $?

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" -eq 0 ]
