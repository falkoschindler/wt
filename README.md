# wt

> Git worktrees, one per task — each opened in its own editor window.

`wt` is a tiny Bash helper that makes [git worktrees](https://git-scm.com/docs/git-worktree) practical for everyday work: one command creates (or reuses) a worktree for a pull request or branch, names it predictably, and opens it as its own VS Code window. If the worktree root contains exactly one `.code-workspace` file, that workspace is opened instead of the bare folder.

It's built for **running several tasks in parallel** — e.g. multiple AI coding sessions or review sessions on different PRs at once — without them clashing on files in a single checkout. One window = one task = one worktree = one branch.

```console
$ wt 6127            # review PR #6127 in its own worktree + window
$ wt new my-feature  # start fresh work on a new branch
$ wt list            # see every worktree, with PR, state, milestone and assignee
$ wt board           # maintainer queue: open issues + PRs grouped by assignee
$ wt prune           # clean up worktrees whose PR is merged or closed
```

## Why

A single checkout is single-threaded: switch branches or edit files in two sessions at once and they trip over each other. A git *worktree* is the same repository checked out into a second directory on its own branch — same history, separate files — so parallel work never collides. `wt` removes the friction of creating, labelling, and cleaning them up.

## Install

```sh
# put the script anywhere on your PATH
curl -fsSL https://raw.githubusercontent.com/falkoschindler/wt/main/wt -o ~/.local/bin/wt
chmod +x ~/.local/bin/wt
```

Or clone and symlink:

```sh
git clone https://github.com/falkoschindler/wt.git
ln -s "$PWD/wt/wt" ~/.local/bin/wt
```

### Requirements

- **git** ≥ 2.31 (for `--path-format`)
- **[gh](https://cli.github.com/)** — authenticated; used to resolve PR numbers and states (the tool degrades gracefully without it)
- **code** — the VS Code CLI on your PATH (to open worktrees as windows)

## Usage

| Command | What it does | Run from |
|---|---|---|
| `wt <number>` | Inside a repo: worktree a PR's head branch for review/rework (number in the name; works with fork PRs) — or, if `<number>` is an open issue, start new work on a fresh local branch named after its title. Outside a repo: open the existing worktree with that number, if exactly one matches. | in / outside repo |
| `wt new <branch> [num]` | Fresh branch off the default branch; optional issue/ticket number. | inside the repo |
| `wt <branch>` | Worktree an existing branch by name (local or on origin). | inside the repo |
| `wt num [<number>]` | Add a number to the *current* worktree afterwards (renames + reopens, moving any Claude Code session history along). Without a number, it uses the current branch's PR. | inside a worktree |
| `wt list` | Table of every worktree under `~/worktrees`, with repo, linked issue, PR number, state, milestone and assignee. | anywhere |
| `wt board` | Maintainer queue: open issues + PRs in the repo, grouped by assignee and ordered by milestone, with a ✓ where you already have a worktree. | inside the repo |
| `wt prune` | Remove worktrees whose PR is merged or closed (asks first). | anywhere |
| `wt rm` | Remove the *current* worktree and optionally delete its branch. | inside a worktree |
| `wt help` | Show usage. | anywhere |

Worktrees are created under `~/worktrees/<repo>-[<number>-]<branch>`.

`wt list` colours PR state GitHub-style (open green, merged purple, closed red, draft grey) and makes most cells clickable: the repo, issue, PR number, milestone and assignee link to their GitHub pages, and a trailing ↗ opens the worktree in VS Code (as its workspace, if it has one). Colour and links are emitted only when writing to a terminal, so piping the output stays clean (the ↗ falls back to the plain path). The ISSUE column shows only what GitHub actually links (the PR's closing reference) — a `-` next to an open PR means the PR is missing its "Fixes #…".

Any create/reuse form accepts `--take`: it copies the newest Claude Code session of the current directory into the new worktree's session store, so the conversation that led to the work shows up there under `/resume` (the original stays where it is). Useful when a discussion in the main checkout turns into real work that belongs in its own worktree.

Starting from an issue works without a detour through `wt num`: `wt 123` on an open issue derives a branch name from the issue title and creates the worktree with the issue number in its name, so the window is identifiable from the start. Once a PR exists, `wt num` (no argument needed — it looks up the branch's PR) renames the worktree to the PR number and moves any Claude Code session history (`~/.claude/projects/…`) along, so past conversations stay attached to the renamed worktree.

`wt board` answers "who's working on what" straight from GitHub's native fields — no project board to hand-maintain. It lists every open issue and PR in the current repo that has an assignee, grouped by assignee (your own group first) and ordered by milestone, with each row linking to its issue/PR. A ✓ marks the ones you already have checked out as a worktree. It only reads, so it's safe to run any time, and the output pipes cleanly like `wt list`.

## Recommended VS Code setup

Lead the window title with the worktree name so many windows stay distinguishable:

```jsonc
// settings.json
"window.title": "${folderName}${separator}${activeEditorShort}"
```

`${folderName}` (rather than `${rootName}`) keeps the worktree directory name — and thus the PR/issue number — in the title even when a worktree is opened via its `.code-workspace` file, where `${rootName}` would degrade to the workspace file's name plus a "(Workspace)" suffix. Caveat: `${folderName}` derives from the active editor, so the title stays empty until a file is opened.

Trust the worktree parent folder once so new worktrees don't prompt: Command Palette → **Manage Workspace Trust** → **Add Folder** → `~/worktrees`.

## License

[MIT](LICENSE) © Falko Schindler
