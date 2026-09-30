# Contributing to Cascade

Thanks for helping. This file is short on purpose; it grows as the build and
release flow settles.

## Licensing of contributions

Cascade's source code is under the GNU GPL version 3 with one additional
permission for app stores (see the top of [LICENSE](LICENSE)). By opening a
pull request you agree that:

- your contribution is licensed under those same terms, the app store
  permission included, so it can ship in every build of Cascade, the App
  Store and Google Play ones too; and
- you wrote it, or otherwise have the right to submit it under those terms.

The artwork in `assets/` is not GPL and is not open to contributions; see
[assets/LICENSE](assets/LICENSE). Please don't add images there.

## Branches

- `dev` is where work lands. Open pull requests against `dev`.
- `stable` is the release branch. Pushing to it builds a release, so only
  the maintainer merges into it.

## Before you open a pull request

```
npm install
npm test            # unit tests
npm run typecheck   # TypeScript, strict
npm run dev         # run the app with the inspector attached
```

Keep changes focused, and explain the why in the commit message, not only
the what.
