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
# github.com resolves to local bare repos under $tmp/gh (a fork with no repo there fails at
# once); any other non-file protocol is refused, so the test never touches the network.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$tmp/gh/.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/ GIT_ALLOW_PROTOCOL=file
mkdir -p "$HOME/worktrees" "$tmp/bin" "$tmp/gh"

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
setpr() { # number sha [fork-owner branch]: PR head on origin, and the branch in the fork
  git -C "$src" push -q -f "$o" "$2:refs/pull/$1/head"
  if [ -n "${3:-}" ]; then
    f="$tmp/gh/$3/no-such-repo.git"
    [ -d "$f" ] || git init -q --bare "$f"
    git -C "$src" push -q -f "$f" "$2:refs/heads/$4"
  fi
}

git init -q -b main "$src"
base=$(commit "$src" base)
git clone -q --bare "$src" "$o"
git -C "$src" checkout -q -b feat; feat=$(commit "$src" "same-repo feat")
git -C "$src" push -q "$o" feat
git -C "$src" checkout -q --detach "$base"; p1=$(commit "$src" "PR1 by alice")
git -C "$src" checkout -q --detach "$base"; p2=$(commit "$src" "PR2 by bob")
git -C "$src" checkout -q --detach "$base"; p3=$(commit "$src" "PR3 by carol")
setpr 1 "$p1" wt-test-alice patch-1; setpr 2 "$p2" wt-test-bob patch-1; setpr 3 "$p3" wt-test-carol main; setpr 4 "$feat"
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
echo "$out" | grep -q 'worktree add --detach'; check "D the hint opens a detached worktree" $?
echo "$out" | grep -q 'wt pr-'; [ $? -ne 0 ]; check "D the hint does not point at a wt pr-N branch" $?
[ "$rc" -ne 0 ]; check "D wt 2 stops when the kept branch patch-1 holds PR 1 (rc=$rc)" $?
[ ! -e "$w2" ] || [ "$(head_of "$w2")" = "$p2" ]; check "D no repo-2 worktree with PR 1's code" $?

git -C "$repo" checkout -q -b other  # main is now a plain branch, not the checked-out one
main0=$(git -C "$repo" rev-parse main)
wt 3
[ "$rc" -ne 0 ]; check "E wt 3 (fork head 'main') stops (rc=$rc)" $?
[ "$(git -C "$repo" rev-parse main)" = "$main0" ]; check "E local main untouched" $?

# PR 1 gains a commit (contributor pushed): reopening fast-forwards, kept worktree or not.
git -C "$src" checkout -q --detach "$p1"; p1b=$(commit "$src" "PR1 follow-up"); setpr 1 "$p1b" wt-test-alice patch-1
wt 1
[ "$rc" -eq 0 ] && [ "$(head_of "$w1")" = "$p1b" ]; check "F wt 1 after a push holds the new head (kept branch)" $?
git -C "$src" checkout -q --detach "$p1b"; p1c=$(commit "$src" "PR1 second follow-up"); setpr 1 "$p1c" wt-test-alice patch-1
wt 1
[ "$rc" -eq 0 ] && [ "$(head_of "$w1")" = "$p1c" ]; check "G wt 1 after a push holds the new head (live worktree)" $?

# Local rework on top of the PR is kept.
mine=$(commit "$w1" "my rework")
wt 1
[ -n "$mine" ] && [ "$rc" -eq 0 ] && [ "$(head_of "$w1")" = "$mine" ]; check "H wt 1 keeps local commits on top of the PR" $?

# Force-push: PR 1's head no longer contains the local branch. The branch tracks alice's fork,
# so it is PR 1's branch with the user's work on it: open it, keep the commits, warn.
git -C "$src" checkout -q --detach "$base"; p1f=$(commit "$src" "PR1 rewritten"); setpr 1 "$p1f" wt-test-alice patch-1
wt 1
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'diverged'; check "I wt 1 after a force-push opens its own worktree with a warning" $?
[ -n "$mine" ] && [ "$(head_of "$w1")" = "$mine" ]; check "I local commits survive" $?
git -C "$repo" worktree remove "$w1"
wt 1
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'diverged' && [ "$(head_of "$w1")" = "$mine" ]; check "I2 a kept, diverged branch of PR 1 reopens with a warning (rc=$rc)" $?
[ "$(git -C "$repo" rev-parse patch-1)" = "$mine" ]; check "I2 local commits survive" $?

# Same-repo PR still works.
wt 4
[ "$rc" -eq 0 ] && [ "$(head_of "$HOME/worktrees/repo-4-feat")" = "$feat" ]; check "J same-repo PR 4 works" $?

# Origin without refs/pull (e.g. origin is your fork): the check is skipped, as before.
git -C "$src" checkout -q -b feat2 "$base"; feat2=$(commit "$src" "same-repo feat2"); git -C "$src" push -q "$o" feat2
echo "5 feat2 false -" >>"$tmp/prs"
wt 5
[ "$rc" -eq 0 ] && [ "$(head_of "$HOME/worktrees/repo-5-feat2")" = "$feat2" ]; check "K PR with no pull/5/head on origin works" $?

# Stacked fork PRs with one head name: erin's PR 7 builds on dave's PR 6. Commits alone say
# "fast-forward"; the branch tracks dave's fork, so wt 7 must not move it.
git -C "$src" checkout -q --detach "$base"; d1=$(commit "$src" "PR6 by dave"); setpr 6 "$d1" wt-test-dave fix
e1=$(commit "$src" "PR7 by erin, on top of PR6"); setpr 7 "$e1" wt-test-erin fix
printf '6 fix true wt-test-dave\n7 fix true wt-test-erin\n' >>"$tmp/prs"
w6="$HOME/worktrees/repo-6-fix"
wt 6
wt 7
[ "$rc" -ne 0 ] && [ "$(head_of "$w6")" = "$d1" ]; check "L wt 7 stacked on PR 6 stops, PR 6 untouched (rc=$rc)" $?
git -C "$repo" worktree remove "$w6"
wt 7
[ "$rc" -ne 0 ] && [ "$(git -C "$repo" rev-parse fix)" = "$d1" ]; check "L wt 7 stops on PR 6's kept branch too (rc=$rc)" $?

# A long-lived upstream branch as a fork PR's head name.
git -C "$src" checkout -q --detach "$base"; dv=$(commit "$src" "develop"); git -C "$src" push -q "$o" "$dv:refs/heads/develop"
fv=$(commit "$src" "PR8 by frank on develop"); setpr 8 "$fv" wt-test-frank develop
echo "8 develop true wt-test-frank" >>"$tmp/prs"
wt develop
wt 8
[ "$rc" -ne 0 ] && [ "$(git -C "$repo" rev-parse develop)" = "$dv" ]; check "M wt 8 (fork head 'develop') leaves local develop alone (rc=$rc)" $?
git -C "$repo" worktree remove "$HOME/worktrees/repo-develop"; git -C "$repo" branch -q -D develop
wt 8
[ "$rc" -eq 0 ] && [ "$(git -C "$HOME/worktrees/repo-8-develop" rev-parse --abbrev-ref '@{u}')" = "wt-test-frank/develop" ]
check "M wt 8 without a local develop tracks frank's fork, not origin/develop" $?

# Same-repo PR: a diverged branch in a worktree wt opened by branch name is the user's work.
git -C "$src" checkout -q --detach "$base"; s1=$(commit "$src" "samefeat"); git -C "$src" push -q "$o" "$s1:refs/heads/samefeat"; setpr 9 "$s1"
echo "9 samefeat false -" >>"$tmp/prs"
wt samefeat
ws="$HOME/worktrees/repo-samefeat"; my9=$(commit "$ws" "my samefeat work")
s2=$(commit "$src" "samefeat pushed elsewhere"); setpr 9 "$s2"
wt 9
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'diverged' && [ "$(head_of "$ws")" = "$my9" ]; check "N same-repo diverged branch opens with a warning (rc=$rc)" $?

# A fast-forward blocked by uncommitted changes warns and still opens the worktree.
git -C "$src" checkout -q --detach "$base"; echo a >"$src/f.txt"; git -C "$src" add f.txt; g1=$(commit "$src" "PR10 adds f")
setpr 10 "$g1" wt-test-grace ffx; echo "10 ffx true wt-test-grace" >>"$tmp/prs"
w10="$HOME/worktrees/repo-10-ffx"
wt 10
echo b >"$src/f.txt"; git -C "$src" add f.txt; g2=$(commit "$src" "PR10 changes f"); setpr 10 "$g2" wt-test-grace ffx
echo dirty >"$w10/f.txt"
wt 10
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'could not fast-forward' && [ "$(head_of "$w10")" = "$g1" ]; check "O failed fast-forward warns and opens (rc=$rc)" $?
echo "$out" | grep -q 'fast-forwarded'; [ $? -ne 0 ]; check "O no 'fast-forwarded' line on failure" $?

# Reverse stack: ivy's PR 13 builds on hank's PR 12. Ivy's branch already contains PR 12's
# head, but it tracks ivy's fork, so wt 12 must not open it as PR 12.
git -C "$src" checkout -q --detach "$base"; h1=$(commit "$src" "PR12 by hank"); setpr 12 "$h1" wt-test-hank fx2
i1=$(commit "$src" "PR13 by ivy, on top of PR12"); setpr 13 "$i1" wt-test-ivy fx2
printf '12 fx2 true wt-test-hank\n13 fx2 true wt-test-ivy\n' >>"$tmp/prs"
wt 13
wt 12
[ "$rc" -ne 0 ]; check "P wt 12 stops on ivy's branch that contains PR 12 (rc=$rc)" $?
# Identity compares GitHub owner/repo, case-insensitive.
w13="$HOME/worktrees/repo-13-fx2"
git -C "$repo" config branch.fx2.remote https://github.com/WT-Test-Ivy/no-such-repo.git
i2=$(commit "$src" "PR13 follow-up"); setpr 13 "$i2" wt-test-ivy fx2
wt 13
[ "$rc" -eq 0 ] && [ "$(head_of "$w13")" = "$i2" ]; check "P owner case does not matter (rc=$rc)" $?

# Unknown ownership is not foreign. A remote that is not a GitHub URL, a removed remote, a
# fork gh no longer knows, or a same-repo branch tracking a local branch (".") cannot be
# compared; the PR's own worktree still opens and follows the PR.
git -C "$repo" config branch.fx2.remote https://elsewhere.example/wt-test-ivy/no-such-repo.git
wt 13
[ "$rc" -eq 0 ] && [ "$(head_of "$w13")" = "$i2" ]; check "Q a non-GitHub remote URL is unknown, not foreign (rc=$rc)" $?
git -C "$repo" config branch.fx2.remote gone
i3=$(commit "$src" "PR13 after the remote was removed"); setpr 13 "$i3" wt-test-ivy fx2
wt 13
[ "$rc" -eq 0 ] && [ "$(head_of "$w13")" = "$i3" ]; check "Q a removed remote is unknown, not foreign (rc=$rc)" $?
git -C "$repo" config branch.fx2.remote wt-test-ivy
grep -v '^13 ' "$tmp/prs" >"$tmp/prs.new"; mv "$tmp/prs.new" "$tmp/prs"; echo "13 fx2 true -" >>"$tmp/prs"
i4=$(commit "$src" "PR13 after the fork was deleted"); setpr 13 "$i4"
wt 13
[ "$rc" -eq 0 ] && [ "$(head_of "$w13")" = "$i4" ]; check "Q a deleted fork is unknown, not foreign (rc=$rc)" $?
git -C "$repo" config branch.samefeat.remote .
wt 9
[ "$rc" -eq 0 ] && [ "$(head_of "$ws")" = "$my9" ]; check "Q a same-repo branch tracking a local branch is ours (rc=$rc)" $?

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
[ "$fails" -eq 0 ]
