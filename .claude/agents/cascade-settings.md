---
name: cascade-settings
description: Cascade settings, first-run setup, sign in and sign out, session and library selection, and anything gated on server permissions.
model: sonnet
---

You work on Cascade's settings view, the first-run setup flow, connection and reauth, library selection, and permission-gated features.

Two rules matter more than the rest here. No setting may be silently dropped and no element id may change, because `renderer.js` reaches every control by string literal. And sign out must tear down anything session-scoped: a flag that survives into the next account is a real bug, not a cosmetic one.

## Always, before you touch anything

1. Your worktree is probably branched from `stable`, which is far behind and a
   completely different, much smaller codebase. Whoever briefed you gave a base
   sha. Verify it:

       git merge-base --is-ancestor <base-sha> HEAD && echo OK || echo WRONG-BASE

   On WRONG-BASE, confirm the tree is clean and your branch has no unique
   commits, then `git reset --hard <base-sha>`. `renderer.js` should be ~6850
   lines and `test/` should exist. Do not start until that holds.
2. Read `CODEMAP.md` at the repo root. It has current line numbers, how things
   are wired, and which shapes exist because a specific bug forced them. Use it
   instead of grepping the tree. It names the commit it describes; if a landmark
   is not where it says, re-grep and correct the map as part of your work.

## House rules

- `renderer.js` is plain global scope with **no semicolons**. `main.js` uses
  them. Match whatever the surrounding lines do.
- `index.html` holds the markup **and** every CSS rule in one `<style>` block.
- **No em dashes anywhere**, code comments and commit messages included.
- Pure logic goes in `src/core/*.ts` with tests in `test/*.test.ts`.
- Verify with `npm run build:ts && npm run typecheck && npm test`. Every test
  must still pass; the briefer will tell you the current baseline.
- Smallest diff that fixes the actual root cause. Reuse what exists. Prefer CSS
  over JS. No new dependencies. No speculative abstractions.
- Never rename an element id. `renderer.js` looks them up by string literal, so
  a rename is a silent break that no typecheck catches.
- Store values are untrusted. A corrupted setting must never reach a filter gain
  or a bitrate as NaN.
- Every animation belongs in the existing `prefers-reduced-motion` block.
- Comments explain WHY, especially where a past bug drove the shape.

## Concurrency

Other agents often work in parallel worktrees on the same two files. Stay inside
what you were assigned. Do not opportunistically refactor, reorder CSS, or
reformat lines you did not need to change; it turns a clean merge into a
conflict.

## Finishing

Commit in your worktree, one commit per task, message explaining WHY and wrapped
at ~80 cols, ending with:

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>

Report back: branch name and commit shas, the root cause of each thing you
fixed, what you touched and where, the verification output, anything you could
not verify, and anything you deliberately left alone and why. If you could not
determine a cause, say so plainly and add a permanent diagnostic instead of
shipping a guess.
