# wt

> Git worktrees, one per task — each opened in its own editor window.

`wt` is a tiny Bash helper that makes [git worktrees](https://git-scm.com/docs/git-worktree) practical for everyday work: one command creates (or reuses) a worktree for a pull request or branch, names it predictably, and opens it as its own VS Code window.

It's built for **running several tasks in parallel** — e.g. multiple AI coding sessions or review sessions on different PRs at once — without them clashing on files in a single checkout. One window = one task = one worktree = one branch.

```console
$ wt 6127            # review PR #6127 in its own worktree + window
$ wt new my-feature  # start fresh work on a new branch
$ wt list            # see every worktree, with PR number, state and milestone
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
| `wt <pr#>` | Inside a repo: worktree a PR's head branch for review/rework (number in the name; works with fork PRs). Outside a repo: open the existing worktree with that number, if exactly one matches. | in / outside repo |
| `wt new <branch> [num]` | Fresh branch off the default branch; optional issue/ticket number. | inside the repo |
| `wt <branch>` | Worktree an existing branch by name (local or on origin). | inside the repo |
| `wt num <number>` | Add a number to the *current* worktree afterwards (renames + reopens). | inside a worktree |
| `wt list` | Table of every worktree under `~/worktrees`, with repo, PR number, state and milestone. | anywhere |
| `wt prune` | Remove worktrees whose PR is merged or closed (asks first). | anywhere |
| `wt rm` | Remove the *current* worktree and optionally delete its branch. | inside a worktree |
| `wt help` | Show usage. | anywhere |

Worktrees are created under `~/worktrees/<repo>-[<number>-]<branch>`.

`wt list` colours PR state GitHub-style (open green, merged purple, closed red, draft grey) and makes most cells clickable: the repo, PR number and milestone link to their GitHub pages, and the path opens the worktree in VS Code. Colour and links are emitted only when writing to a terminal, so piping the output stays clean.

## Recommended VS Code setup

Lead the window title with the worktree name so many windows stay distinguishable:

```jsonc
// settings.json
"window.title": "${rootName}${separator}${activeEditorShort}"
```

Trust the worktree parent folder once so new worktrees don't prompt: Command Palette → **Manage Workspace Trust** → **Add Folder** → `~/worktrees`.

## License

[MIT](LICENSE) © Falko Schindler
