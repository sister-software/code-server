# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

code-server runs VS Code on a remote server and serves it to a browser. It is **not** a fork of VS Code's UI — it uses Microsoft's open-source Code web frontend (pulled in as a submodule) and implements the server/host around it. Conceptually, code-server is an HTTP API that authenticates a user and starts/serves a remote Code process.

The two halves live in very different places:

- `src/` — the code-server-specific server (the part this repo actively develops). TypeScript, compiled to `out/`.
- `lib/vscode/` — a **git submodule** pointing at upstream `microsoft/vscode`. Empty until initialized. All changes to Code itself are applied as patches, never committed directly.

If functionality does **not** depend on Code internals, it belongs in `src/`, not in a patch.

## The iOS app (`ios/`)

`ios/` holds a separate subproject: a native iPad app (product name **Code**)
that hosts a serverless VS Code web workbench locally, edits local files, runs an
offline Linux terminal, and does native SSH remoting. It is developed on the
`feat/ios-client` branch and is **not** part of the published code-server
package, but it reuses this repo's `lib/vscode` submodule + `quilt` infra to
build its workbench (with its own `patches/ios-*.diff`, applied on vanilla Code —
not in `patches/series`). If you're working under `ios/`, read **`ios/AGENTS.md`**
(operational guide) and `ios/README.md` (architecture); the rest of this file is
about the server.

## The patch system (most important workflow concept)

Modifications to upstream Code are managed with [`quilt`](https://savannah.nongnu.org/projects/quilt/) as a stack of patches in `patches/`, ordered by `patches/series`. The submodule is checked out at an upstream release branch; patches are applied on top.

- `git submodule update --init` — fetch the Code submodule (required before anything builds).
- `quilt push -a` / `quilt pop -a` — apply / unapply the full patch stack.
- `quilt push` / `quilt pop` — step through patches one at a time.
- Creating/editing a patch: `quilt new {name}.diff` (or `quilt push` to an existing one), `quilt add [-P patch] {file}` **before** editing a file, make changes, then `quilt refresh` to capture them.
- After pulling changes that touch patches or bump the submodule: re-run `git submodule update --init` and re-apply with `quilt`.

Rules that matter when touching patches:
- Each patch must leave code-server in a working state on its own — no broken intermediate states (they must be independently testable).
- Every patch should have a comment explaining why it exists and an e2e test.
- "Forbidden access" in the browser almost always means patches didn't apply (we patch out vanilla Code's auth because we provide our own). Try `quilt pop -a && quilt push -a`.

Updating the Code version (usually automated via PR): apply what you can with `quilt push -a`, force past conflicts with `quilt push -f`, manually fix rejects, `quilt refresh`, then run `./ci/build/update.sh`.

## Build & run

Builds are **very** slow (Code's build, plus loading it in dev mode is slow too). Dev setup:

```shell
git submodule update --init
quilt push -a
npm install
npm run watch   # serves http://localhost:8080, live-reloads on change (refresh browser manually)
```

Full production release:

```shell
npm run build              # builds src/ -> out/
VERSION=0.0.0 npm run build:vscode
KEEP_MODULES=1 npm run release   # output in ./release; KEEP_MODULES bundles node + entry
npm run package            # build .deb/.rpm/standalone (needs nfpm)
```

Note: display-language support and other features only work in a **full build**, not `npm run watch`.

## Tests

There are four kinds. Tests have their **own** dependency tree under `test/` (separate `test/package.json` / `test/node_modules`) — jest and playwright are installed there, not at the root.

- **Unit** (Jest, `test/unit/`, mirrors `src/` layout): `npm run test:unit`. Single file/test: `npm run test:unit -- <pattern>` (e.g. `npm run test:unit -- util` or `-t "test name"`). Coverage threshold is 60% lines.
- **E2E** (Playwright, `test/e2e/`): `npm run test:e2e`. Requires an existing build (`npm run watch` running, or set `CODE_SERVER_TEST_ENTRY=./release`). `globalSetup` pre-authenticates so individual tests skip login. Helpers/models live in `test/e2e/models/`. Proxy variant: `npm run test:e2e:proxy`.
- **Script** (bats, `test/scripts/`): `npm run test:scripts` — covers the bash in `ci/`.
- **Integration** (`npm run test:integration`): builds and verifies packaged code-server works on its platform.

## Lint & format

- `npm run lint:ts` — ESLint over tracked `.ts`/`.js`, **excluding `lib/vscode`** (autofix on).
- `npm run lint:scripts` — shellcheck/shfmt over scripts.
- `npm run prettier` / `npm run fmt` — Prettier (`fmt` also runs doctoc to regenerate doc TOCs). Markdown TOCs are doctoc-generated — don't hand-edit the marked sections; run `npm run doctoc`.

## Server architecture (`src/`)

- `src/node/` — server entrypoint and CLI. `src/node/routes/` — Express HTTP routes.
- `src/common/` — code shared between node and browser. `src/browser/` — static pages (login/error), service worker, PWA assets.
- Process model: `entry.ts` parses CLI/config, then `wrapper.ts` spawns a **child** process running the actual server (`runCodeServer`). The parent handles `--help`, version, opening files in an existing instance, and forwards args to the child (so `PASSWORD` isn't leaked to the child env). The child does a handshake to receive args.
- `routes/index.ts` `register()` wires up all middleware/routes: a `Heart` (heartbeat at `paths.data/heartbeat`, used to know if the server is idle), `SettingsProvider` (`coder.json` in the user-data dir), `UpdateProvider` (checks GitHub releases), cookie-based session auth, and the proxy routes (`domainProxy`, `pathProxy`).
- `routes/vscode.ts` dynamically `import()`s the built Code server module from `lib/vscode/out/server-main.js` and hands off the WebSocket/HTTP connection. This is why a Code build must exist for e2e tests.
- `cli.ts` defines all flags; `toCodeArgs()` translates code-server args into the args Code's CLI/server expects.

## Build/release scripts

All in `ci/` (referenced by the npm scripts above): `ci/build/` (build, vscode build, release, packaging via `nfpm.yaml`), `ci/dev/` (watch, tests, lint, postinstall), `ci/steps/` (publish), `ci/helm-chart/` (Kubernetes chart). `ci/dev/watch.ts` is the dev server orchestrator run by `npm run watch`.

## Conventions

- Toolchain Node version is in `.node-version` (24.15.0); the published package requires Node 22 (`engines`). Use the repo's `.node-version` for development.
- Commits must be GPG-signed and verified.
- Update `CHANGELOG.md` (the unreleased section) in PRs that affect users/deployments.
- PRs are generally squashed into `main`.
