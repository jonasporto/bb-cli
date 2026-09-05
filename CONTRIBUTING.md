# Contributing to bb-cli

Thanks for your interest in contributing.

## How to contribute

### 1. Open an issue first

Before writing any code, please
[open an issue](https://github.com/jonasporto/bb-cli/issues/new) describing:

- **Bug reports**: what happened, what you expected, and how to reproduce it.
  Include `bb-cli version` and the command you ran, with the token redacted.
- **Feature requests**: what you would like, and the Bitbucket endpoint it would
  need. If `bb-cli api` already does it, say why porcelain would be better.
- **Questions**: if you are unsure about something.

### 2. Wait for feedback

Maintainers will review the issue. This avoids duplicate work and settles the
approach before code is written.

### 3. Open a pull request

1. Fork the repository
2. Create a branch
3. Make your changes
4. Run the tests: `tests/run.sh`
5. Open a PR referencing the issue (e.g. `Fixes #123`)

**PRs without a linked issue are closed automatically.**

### Automated accounts

Pull requests from bot accounts are closed automatically, without the issue
check. bb-cli is one bash script with no dependency manifest, so there is
nothing for a dependency bot to update; the action versions in
`.github/workflows/` are pinned and bumped by hand. There is deliberately no
`.github/dependabot.yml`.

Contributions written with an AI assistant are welcome, from your own account,
under the same rules as any other: open the issue first, and be able to explain
and defend the change in review. A patch you cannot explain is one nobody can
maintain.

## Development setup

There is no build step. The tool is one bash script.

```bash
git clone https://github.com/YOUR_USERNAME/bb-cli.git
cd bb-cli
./bin/bb-cli --help
```

`curl`, `jq` and `git` are the only dependencies.

## Running tests

```bash
tests/run.sh              # every suite
tests/run.sh api          # only suites whose name matches "api"
```

The suite is **offline by design**: a fake `curl` on `PATH` records the argv and
answers from a fixture, so it needs no token, no network and no Bitbucket
account. It runs in about the time one real request would take.

The suites assert on **what would go over the wire** (verb, URL, request body)
rather than on formatted output. A test that only checks that a string appears
in the terminal will pass while the request is wrong, so please assert on
`CURL_LOG`.

### Which bash runs it matters

`bin/bb-cli` hard-codes `#!/bin/bash`, and on macOS that is 3.2.57, the version
`docs/setup.md` promises. Run the suite under both:

```bash
tests/run.sh              # whatever bash is first on your PATH
/bin/bash tests/run.sh    # macOS system bash 3.2
```

CI runs Linux, macOS with Homebrew bash 5, and macOS with system bash 3.2. No
bash 4+ constructs: no `declare -A`, no `${var,,}`, no `mapfile`. No GNU-only
flags either (`sed -i ''` and BSD `stat` differ from GNU). Those never show up
on macOS, which is why Linux CI is the final word.

Two traps that have already cost time here:

- **`stat -f` means different things.** On BSD it is the format string; on GNU
  it is *file system status*, which succeeds while printing block counts. So
  `stat -f '%Lp' f || stat -c '%a' f` never reaches the GNU branch and compares
  garbage. Try `stat -c` first: BSD rejects it outright.
- **A test must not depend on your machine reaching the network.** Two suites
  did a real `git fetch` against GitHub, so they were green here and red
  everywhere else. Build a bare repository in `$TMP` and clone it when a test
  needs a real remote.
- **Nor on your git config.** That replacement fixture still failed on Linux,
  because it let git choose the branch name: without `init.defaultBranch` that
  is `master`, and a fixture built where it is `main` fetches a branch the bare
  repository does not have. Pin it with
  `git symbolic-ref HEAD refs/heads/main`.

The quickest way to catch both before pushing:

```bash
docker run --rm -v "$PWD:/src:ro" debian:12-slim \
  bash -c 'apt-get -qq update && apt-get -qq install -y --no-install-recommends \
    git jq curl ca-certificates && cp -a /src /work && cd /work && tests/run.sh'
```

Lint before opening a PR; `shellcheck -S error` is a blocking gate:

```bash
shellcheck -S error bin/bb-cli install.sh
```

## Ground rules for changes

**Verify against the API, not against the documentation.** Atlassian's developer
pages render as JavaScript and repeatedly came back empty when fetched; a field
list read from them is a claim, not a measurement. Every non-obvious statement in
`docs/` was established by making a request and reading the response. If you
write something down, say how you know it, and mark inference as inference.

**Response headers beat probing.** `x-oauth-scopes` lists what a token holds and
`x-accepted-oauth-scopes` what an endpoint demands. `bb-cli api <path> -i` prints
both. Inferring permissions from status codes is a fallback that has produced a
wrong conclusion before. See the note in `docs/scopes.md`.

**Reaching for `curl` is a bug.** The ladder is porcelain → `bb-cli api <path>`.
`api` attaches the credential, expands `:repo`, percent-encodes step UUIDs and
follows the redirects that a hand-rolled `curl` silently drops.

**A new command needs, in the same PR:** `--help` text, a row in the README
table, an entry in `CHANGELOG.md`, tests that assert on the request, and, if it
changes what an agent should do, an update to `skills/bb-cli/SKILL.md` and
`man/bb-cli.1`. The documentation travels with the tool; that is the point of it.

## Code style

- Functions: `snake_case`, prefixed `cmd_` for subcommands and `bb_` for helpers
- Locals are `local`, always. An unlocalized variable in a 3,800-line script is
  a bug waiting for the right caller.
- Quote every expansion. `set -e` is on, so an unquoted empty variable is a
  silent behaviour change rather than an error.
- Comments explain *why*, not *what*, and where a value was measured rather
  than assumed, say so.
