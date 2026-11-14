#!/usr/bin/env bash
# Regression test for `wt <pr#>`: the worktree it opens must hold that PR's head commit
# (or its own commits on top of it), or wt must stop with a non-zero exit. Fork PRs often
# share a head branch name ("main", "patch-1"), and the local branch of that name can hold
# another PR's commits, the main checkout, or a PR's pre-force-push commits.
# gh is stubbed; "origin" is a local bare repo with refs/pull/N/head.
# Usage: tests/pr_head_test.sh [path/to/wt]     (exit 0 = all pass)
set -uo pipefail

WT=${1:-"$(dirname "$0")/../wt"}
WT=$(cd "$(dirname "$WT")" && pwd)/$(basename "$WT")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 WT_NO_OPEN=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME/worktrees" "$tmp/bin"

# gh stub: `pr view N` answers from $tmp/prs ("N branch cross owner" per line); any other
# gh call fails, which wt treats as "no answer".
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "pr view" ] || exit 1
read -r _ b c o < <(grep "^\$3 " "$tmp/prs") || exit 1
printf '%s\t%s\t%s\tno-such-repo\n' "\$b" "\$c" "\$o"
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

o="$tmp/origin.git"; src="$tmp/src"; repo="$HOME/repo"
commit() { # dir, message -> sha
  git -C "$1" commit -q --allow-empty -m "$2"; git -C "$1" rev-parse HEAD
}
setpr() { # number sha
  git -C "$src" push -q -f "$o" "$2:refs/pull/$1/head"
}

git init -q -b main "$src"
base=$(commit "$src" base)
git clone -q --bare "$src" "$o"
git -C "$src" checkout -q -b feat; feat=$(commit "$src" "same-repo feat")
git -C "$src" push -q "$o" feat
git -C "$src" checkout -q --detach "$base"; p1=$(commit "$src" "PR1 by alice")
git -C "$src" checkout -q --detach "$base"; p2=$(commit "$src" "PR2 by bob")
git -C "$src" checkout -q --detach "$base"; p3=$(commit "$src" "PR3 by carol")
setpr 1 "$p1"; setpr 2 "$p2"; setpr 3 "$p3"; setpr 4 "$feat"
cat >"$tmp/prs" <<EOF
1 patch-1 true wt-test-alice
2 patch-1 true wt-test-bob
3 main true wt-test-carol
4 feat false -
EOF
git clone -q "$o" "$repo"

fails=0
check() { # label, condition-exit-status
  if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
wt() { # pr#: runs wt inside the repo, sets $rc and $out
  out=$(cd "$repo" && ${WT_BASH:-bash} "$WT" "$@" 2>&1); rc=$?
}
head_of() { git -C "$1" rev-parse HEAD 2>/dev/null; }
w1="$HOME/worktrees/repo-1-patch-1"; w2="$HOME/worktrees/repo-2-patch-1"

wt 1
check "A wt 1 succeeds" "$rc"
[ "$(head_of "$w1")" = "$p1" ]; check "A wt 1 holds PR 1's head" $?

wt 1
[ "$rc" -eq 0 ] && [ "$(head_of "$w1")" = "$p1" ]; check "B wt 1 again reuses the worktree" $?

wt 2
[ "$rc" -ne 0 ]; check "C wt 2 stops while PR 1 holds branch patch-1 (rc=$rc)" $?
echo "$out" | grep -q 'reusing existing worktree'; [ $? -ne 0 ]; check "C wt 2 does not offer PR 1's worktree" $?

git -C "$repo" worktree remove "$w1"
wt 2
[ "$rc" -ne 0 ]; check "D wt 2 stops when the kept branch patch-1 holds PR 1 (rc=$rc)" $?
[ ! -e "$w2" ] || [ "$(head_of "$w2")" = "$p2" ]; check "D no repo-2 worktree with PR 1's code" $?

main0=$(git -C "$repo" rev-parse main)
wt 3
[ "$rc" -ne 0 ]; check "E wt 3 (fork head 'main') stops (rc=$rc)" $?
[ "$(git -C "$repo" rev-parse main)" = "$main0" ]; check "E local main untouched" $?

# PR 1 gains a commit (contributor pushed): reopening fast-forwards, kept worktree or not.
git -C "$src" checkout -q --detach "$p1"; p1b=$(commit "$src" "PR1 follow-up"); setpr 1 "$p1b"
wt 1
[ "$rc" -eq 0 ] && [ "$(head_of "$w1")" = "$p1b" ]; check "F wt 1 after a push holds the new head (kept branch)" $?
git -C "$src" checkout -q --detach "$p1b"; p1c=$(commit "$src" "PR1 second follow-up"); setpr 1 "$p1c"
wt 1
[ "$rc" -eq 0 ] && [ "$(head_of "$w1")" = "$p1c" ]; check "G wt 1 after a push holds the new head (live worktree)" $?

# Local rework on top of the PR is kept.
mine=$(commit "$w1" "my rework")
wt 1
[ -n "$mine" ] && [ "$rc" -eq 0 ] && [ "$(head_of "$w1")" = "$mine" ]; check "H wt 1 keeps local commits on top of the PR" $?

# Force-push: PR 1's head no longer contains the local branch. In PR 1's own worktree that
# is the user's work: open it, keep the commits, warn. A kept branch with no worktree stops.
git -C "$src" checkout -q --detach "$base"; p1f=$(commit "$src" "PR1 rewritten"); setpr 1 "$p1f"
wt 1
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'diverged'; check "I wt 1 after a force-push opens its own worktree with a warning" $?
[ -n "$mine" ] && [ "$(head_of "$w1")" = "$mine" ]; check "I local commits survive" $?
git -C "$repo" worktree remove "$w1"
wt 1
[ "$rc" -ne 0 ] && [ ! -e "$w1" ]; check "I2 a kept, diverged branch with no worktree stops (rc=$rc)" $?
[ "$(git -C "$repo" rev-parse patch-1)" = "$mine" ]; check "I2 local commits survive" $?

# Same-repo PR still works.
wt 4
[ "$rc" -eq 0 ] && [ "$(head_of "$HOME/worktrees/repo-4-feat")" = "$feat" ]; check "J same-repo PR 4 works" $?

# Origin without refs/pull (e.g. origin is your fork): the check is skipped, as before.
git -C "$src" checkout -q -b feat2 "$base"; feat2=$(commit "$src" "same-repo feat2"); git -C "$src" push -q "$o" feat2
echo "5 feat2 false -" >>"$tmp/prs"
wt 5
[ "$rc" -eq 0 ] && [ "$(head_of "$HOME/worktrees/repo-5-feat2")" = "$feat2" ]; check "K PR with no pull/5/head on origin works" $?

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" -eq 0 ]
