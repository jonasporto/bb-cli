# Changelog

Notable changes to bb-cli. Format follows [Keep a Changelog][kac]; versions
follow [semver][semver], with the caveat that everything below 1.0 may break.

[kac]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html

## [0.2.0] - 2026-09-05

Everything a repository needs before strangers can read it, plus the onboarding
and portability defects that preparing for them uncovered.

### Fixed

- The `test-minimal` CI job asserted on the literal string `needs jq`, but that
  container has neither curl nor jq, so the tool correctly says `needs curl jq`.
  The job failed on the very first public push while the product was behaving
  exactly as designed. Both assertions there are patterns now, and the block was
  replayed under `sh -e` in the same image before pushing.
- **`bb-cli login` was still teaching the app-password flow Atlassian removed.**
  It pointed at `bitbucket.org/account/settings/app-passwords/` and asked for
  three *read* permissions, while the README, `docs/setup.md`, `docs/scopes.md`
  and the skill all describe an Atlassian API token from `id.atlassian.com` with
  five scopes, two of them writes. App passwords were permanently removed on
  2026-07-28 (Atlassian CHANGE-3222), so the very first command a new user runs
  sent them to a dead page, and anyone who found the token page anyway came
  back with a read-only credential that cannot edit a pull request, comment, or
  trigger a pipeline. The instructions now match the docs, name the five scopes,
  and lead with the two traps: `write` does not imply `read`, and scopes are
  fixed at creation. The failure tips no longer point at app passwords either.

### Added

- **`bb-cli login --with-token`**, reading the token from stdin the way
  `gh auth login --with-token` does. Onboarding was interactive-only, so a
  script, a CI job or an agent could not finish it: `read -p` hit EOF and the
  run died at an invisible prompt. A bare `login` without a terminal now exits 1
  naming this form and the `BITBUCKET_USERNAME`/`BITBUCKET_API_TOKEN`
  environment alternative, instead of consuming a prompt nobody could see.
- **`tests/login_test.sh`**: `login` had no tests at all, which is how the
  instructions drifted from the documentation unnoticed. 25 assertions covering
  the instructions, both non-interactive paths, the `600`/`700` permissions, and
  that a token containing `$()` is stored quoted rather than executed when the
  credentials file is sourced.
- **Install without cloning first.** `install.sh` already bootstrapped its own
  checkout when it found no repository around it; nothing said so. The
  `curl … | bash` one-liner is now the first thing in the README, in
  `bb-cli docs setup`, in the skill and in the `upgrade` error, with
  `BB_CLI_HOME` documented for choosing the directory. Still a clone rather
  than a tarball, because `bb-cli upgrade` is a `git pull`.
- **A single-file install is now a supported way to run bb-cli.** Copy
  `bin/bb-cli` onto your PATH and every command works, `bb-cli upgrade`
  included: with no repository to pull it replaces the script from the
  published URL, after checking the download parses as bash and is actually
  bb-cli. A symlinked install updates the file the link points at, not the
  link. `upgrade` previously exited 1 with "not a git checkout", which left the
  commonest way to install one bash script with no way forward at all.
- `docs`, `man` and `skill` now name that situation instead of calling it a
  "partial install": they say every command still works, that these three carry
  files a single script cannot, and give the one line that installs the full
  set.
- **A missing `jq` now produces a sentence, not a shell error.** `jq` parses
  every response and is the one dependency a fresh machine usually lacks;
  reaching the API without it died inside a pipeline with
  `bb-cli: line 1701: jq: command not found`. Commands that touch the API check
  first and name the package with the right install command for the platform.
  `version`, `--help`, `docs`, `man` and `skill` keep working without it, since
  that is where a reader goes to find out what to install.
- **`bb-cli status` reports a missing dependency**, which `docs/setup.md` had
  been promising it did. It now lists what is absent, gives the install line,
  and exits 1 rather than reporting "Not authenticated" and blaming the token
  for a missing package.
- **Two test suites passed only on the author's machine.** Running them in a
  `debian:12-slim` container, on both linux/amd64 and linux/arm64, found it:
  - `upgrade --check` and `_refresh-update-cache` were pointed at the developer's
    own bb-cli checkout, so they did a real `git fetch` against GitHub. They
    passed where the network and an SSH key happened to be, and failed
    everywhere else, CI included. They now build a bare repository and a clone
    of it in the temp dir, so the fetch is real but local.
  - the credentials-permission assertions used `stat -f '%Lp' || stat -c '%a'`.
    On GNU, `-f` means *file system status*, so it succeeds while printing
    filesystem details, and the fallback never runs: the assertion compared
    block counts to "600" and failed with an unreadable message. GNU's `-c` is
    rejected outright by BSD stat, so trying that first works on both.
  - the replacement fixture then failed on Linux for a second reason: it let git
    pick the branch name. Without `init.defaultBranch` that is `master`, so a
    fixture built on a machine configured for `main` fetched a branch the bare
    repository did not have. It is pinned with `symbolic-ref` now.
- **`bb-cli status` exits non-zero when there is no credential.** It printed
  "Not authenticated" and exited 0, so `bb-cli status || bb-cli login` never
  ran the second half and a CI job could not gate on it. `gh auth status`
  exits 1 here; now so does this.
- **`bb-cli man` no longer prints roff source when there is no `man`.** A slim
  Linux container has no man(1), and the fallback was `cat`, which put
  `.TH BB\-CLI 1 "August 2026" ...` on the reader's screen. It now renders
  through groff or nroff when either exists, and otherwise says it cannot
  render the page and points at `bb-cli docs`, which is the same material in a
  form needing no renderer. Found by running the installer in a
  `debian:12-slim` container on linux/amd64.
- **`install.sh` checks dependencies before the bootstrap clone**, not after. A
  machine without `jq` used to download the whole repository and only then
  report that it could not be used. The hint now also covers `dnf` and
  `pacman`.
- **The installer says so when it is run under `sh`.** `curl … | sh` is a common
  habit, and on Debian and Ubuntu `/bin/sh` is dash, where the script died on
  `set -o pipefail` with a line number that named neither the cause nor the fix.
  It now names both, before that line.
- **`CONTRIBUTING.md`**: issue first, the offline test harness, which bash to
  run it under, the shellcheck gate, and the rule that a new command ships with
  its `--help`, README row, changelog entry, tests and skill update.
- **`SECURITY.md`**: private reporting, everything the tool reads and writes,
  and an explicit scope: `bb-cli api` sending your token wherever you point it
  is the feature, a token reaching a log or a process listing is a bug.
- **CI** (`.github/workflows/test.yml`): the suite on Linux, on macOS with
  bash 5 and on macOS with the system bash 3.2 that `docs/setup.md` promises;
  a jq-less Debian job proving the tool still starts and documents itself, and
  that `install.sh` refuses rather than half-installing; `shellcheck -S error`
  as a blocking gate (baseline: zero).
- **`.github/workflows/require-issue.yml`**: external pull requests must
  reference an issue, and pull requests from bot accounts are closed before
  that check runs. An automated account has no issue to reference, so it would
  otherwise be closed with the wrong explanation, and a merged bot PR puts the
  bot in the contributor list permanently. There is deliberately no
  `dependabot.yml`: nothing here has a dependency manifest, and the action
  versions are bumped by hand.
- `test.yml` declares `permissions: contents: read`, rather than inheriting
  whatever the repository default happens to be.
- **`CLAUDE.md` and `GEMINI.md`** as symlinks to `AGENTS.md`, so agents that
  look for their own filename find the same guidance.

### Changed

- The README now says that `npx skills add` needs `git` present and prompts for
  which agents to install into, with the flags that make it non-interactive.
  Verified against the published repository in a `node:22-slim` container:
  without `git` it fails with a raw Node stack trace, and with no terminal it
  stops at the agent picker.
- **The checkout now lands in `~/.bb-cli`**, not `~/llm-tools/bb-cli`. It is the
  convention for a directory the tool manages rather than one you work in
  (`~/.nvm`, `~/.rbenv`). An existing checkout still wins over the default,
  the old path included, so re-running the installer never leaves a second copy
  behind. `BB_CLI_HOME` overrides both.
- The skill's onboarding section now hands the user the token URL, the five
  scopes and both traps in one message, then stores the token with
  `--with-token`. It previously said only "point them at `bb-cli docs setup`",
  which took four round trips and ended at an interactive prompt the agent
  could not answer.

## [0.1.0] - 2026-08-23

First numbered release. The tool existed for seven months before this and was
used heavily (1,343 invocations across 53 sessions) but had no version, no
tags and no release notes. The entries below the horizontal rule reconstruct
that history from the commits; they were never released under a number, so they
carry dates instead of versions.

### Added

- **`bb-cli api`**: authenticated passthrough to the Bitbucket REST API, the
  `gh api` of this tool. `-X`, `-f`/`-F`, `--input`, `-q`, `-i`, `-H`,
  `--paginate`, and `:repo` / `:workspace` / `:slug` placeholders resolved from
  the git remote. Anything the named commands do not cover goes through here,
  which is what keeps `curl` out of a session.
- **`bb-cli signoff`**: publish a build status on a commit from a local test
  run, the Bitbucket counterpart of `gh signoff`. Refuses on a dirty working
  tree or an unpushed commit unless forced. `bb-cli signoff status` reads them
  back, including statuses published by pipelines and third-party integrations.
- **Pull request writes**: `pr edit`, `pr ready` (with `--undo`) and
  `pr comment`, matching `gh pr edit|ready|comment`. Bodies come from a file, or
  stdin, never an inline string: markdown hard breaks are trailing spaces and
  command substitution strips them. `pr edit` reads the pull request first and
  sends both fields, so changing the title cannot blank the description.
- **`bb-cli pr checks <n>`**: `gh pr checks`. On Bitbucket the checks on a pull
  request are the build statuses on its head commit, the same objects `signoff`
  writes.
- **`bb-cli pipeline cancel <n>`**: `gh run cancel`, the one verb of `gh run`
  that had no counterpart. A finished build answers 400 rather than 403, so the
  message says the build finished instead of implying a missing scope.
- **`bb-cli cache list|delete`**: `gh cache`. Deletion is by uuid only:
  Bitbucket also accepts `?name=`, which removes every cache sharing that name
  on every branch, because caches are distinguished by path as well.
- **`gh`'s nouns as aliases**: `run`/`runs` for `pipeline`, `view` on `pr` and
  `pipeline`, `stop` for `cancel`, and `auth login|logout|status` alongside the
  existing top-level forms. Bitbucket's own noun stays primary: a *pipeline* is
  what its UI, docs and API call it.
- **`bb-cli upgrade`**: pull the checkout bb-cli was installed from. Because
  the executable, man page and skill are all symlinks into it, one pull updates
  all four.
- **Update notice** on `bb-cli status`: at most once a day, on stderr, only for
  a human at a terminal, never in piped output. `BB_CLI_NO_UPDATE_CHECK=1`
  disables it.
- **`bb-cli version`** / `--version`. Sessions had tried this three times and
  got "Unknown command".
- **`bb-cli docs`**: the documentation set now ships with the tool: `setup`,
  `scopes`, `api` and `signoff`, readable offline.
- **`man bb-cli`**, and `bb-cli man` for reading it before `install.sh` runs.
- **`install.sh`**: dependency check, symlinks for binary and man page, and a
  plain warning when either lands outside `PATH` or `MANPATH`. Also works piped
  from `curl`, cloning first when there is no checkout to work from.
- **A skill for AI agents** (`skills/bb-cli/SKILL.md`), installable with
  `npx skills add jonasporto/bb-cli` or `bb-cli skill install`, plus `AGENTS.md`
  at the repository root.
- **Offline test suites**: 201 assertions across five suites, run by
  `tests/run.sh`. A fake `curl` on `PATH` records the argv and answers from a
  fixture, so nothing touches the network or needs a token.
- `LICENSE` (MIT) and this file.

### Fixed

- **`bb-cli api` did not percent-encode `{uuid}` braces in a path.** The
  porcelain commands always did, so a uuid copied out of
  `bb-cli pipeline <n> steps` and pasted into `bb-cli api` returned
  `400 Unexpected response body`, a message that reads like a malformed request
  or a missing scope and is neither. Reported from a session that lost time to
  it and fell back to `curl`. An already-encoded `%7B...%7D` is left alone, and
  a trailing slash (which `POST /pipelines/` needs) survives.
- **`pr <n> -j` silently ignored the flag.** It was parsed, then dropped on the
  way to `cmd_pr_show`, so the formatted view printed instead of JSON. Reading a
  pull request body was the single commonest reason a session fell back to
  `curl`.
- **`pr <n>` never printed the description.** It does now, in its own section.
- **`bb-cli status` reported "Invalid credentials" for a perfectly good token.**
  It probed an account endpoint and treated anything but 200 as failure;
  `GET /user` answers 403 without `read:account`, which this tool deliberately
  tells you to leave off, and the account-wide listings answer 410 Gone for API
  tokens entirely. It now judges by the `x-oauth-scopes` header, which every
  authenticated response carries, and reports the granted scopes plus any of the
  five that are missing.
- **`docs`, `man` and `skill` broke for anyone who installed properly.**
  `SCRIPT_DIR` was taken from the symlink rather than its target, so the three
  commands looked for files beside `~/.local/bin`.

### Changed

- **Pipeline lookup by build number is one request instead of a paged scan.**
  Bitbucket accepts a build number in the `{pipeline_uuid}` path slot, though
  only a uuid is documented there. Measured on a build roughly two thousand
  behind the newest, where the scan had to walk 21 pages: **59.4s** before,
  **0.6s** after. The scan remains as a fallback, since the direct form is
  undocumented.
  Do not substitute `?q=build_number=N`: that filter is accepted and silently
  ignored, returning the first page unfiltered: a wrong pipeline, not an error.
- **`pr <n>` dropped a wasted HTTP round trip.** It fetched
  `?fields=participants` into a variable nothing ever read; the reviewers
  section reads `.participants` out of the response it already had.
- **Independent requests now run concurrently** in `pr <n>` (comments and
  activity), `pipeline <n>` (pipeline and steps) and `pipeline <n> failures`
  (test report and cases per step).
- **`bb-cli skill install` links rather than copies**, so `git pull` updates the
  skill too. It has no `update` subcommand, so a copy would have gone stale in
  silence. `--copy` still takes a detached copy, and says that it will.

### Notes on deliberate omissions

- **No `signoff install`.** Requiring a status for merge is a Bitbucket branch
  restriction, which needs `admin:repository:bitbucket` to read as well as
  write, and it edits a merge policy every other contributor lives under.
- **`-f`/`-F` on `bb-cli api` do not imply POST**, unlike `gh api`. On Bitbucket
  a POST to `/pullrequests` creates a pull request, so a read that silently
  became a write would be expensive.
- **`pipeline rerun --failed` prints a limitation** rather than doing something
  else. Bitbucket's public API has no endpoint for it, although the web UI does.

---

# Before versioning

Reconstructed from the six commits that preceded 0.1.0. None of these was
tagged or released; they are here so the history is legible rather than
starting at a cliff.

## 2026-07-16 - repo-agnostic

`Make bb-cli repo-agnostic: drop hardcoded workspace/repo from docs, examples,
tests`

Replaced the workspace and repository used throughout the documentation, the
`--help` examples and the test fixtures with the placeholder
`myworkspace/myrepo`. The first change made with someone else's machine in
mind, and the point at which the tool stopped assuming one particular repo.

## 2026-07-16 - pipeline write verbs, fixed and tested

`pipeline: fix trigger/rerun/watch arg-routing; add --failed, tests, docs`

Fixed an argument-parsing bug that made the write verbs silently do nothing: a
flag placed *before* the subcommand (`pipeline --repo=X rerun 1240`) set the
action to `list`, and the parse loop then had no `trigger` case and did not
consume `rerun`'s argument, so `trigger` was re-read as `show trigger` and
`rerun 1240` as `show 1240`. Neither ever issued its POST.

Added `tests/pipeline_routing_test.sh`, the repository's first tests, which
stub `curl` on `PATH` and assert the right HTTP verb reaches the network layer
for each command shape. Every suite since follows that pattern.

Also added `rerun --failed`, which prints Bitbucket's limitation rather than
quietly running everything: the web UI offers "rerun failed steps", the public
REST API has no endpoint for it, and the UI calls an undocumented internal one.

## 2026-07-03 - pipeline trigger, rerun, watch

`Add pipeline trigger/rerun/watch (gh-style)`

The first write capability, modelled on `gh workflow run`, `gh run rerun` and
`gh run watch`. `rerun` re-posts the same target (branch head plus custom
selector) because Bitbucket has no "run this exact pipeline again" endpoint.

## 2026-05-30 - better failure lookup

`Improve pipeline failure lookup commands`

Step log retrieval, and the UUID encoding that makes it work: pipeline and step
UUIDs need percent-encoded braces (`%7B...%7D`) in a path, or the API answers
`400 Unexpected response body`, which reads like a malformed request and is not.

## 2026-05-30 - pipelines

`Add Bitbucket pipeline inspection commands`

Roughly doubled the tool: `pipeline` list and show, `steps`, `step --log`, and
`failures` with its test-report summary. Pipelines went on to be the most-used
part of bb-cli by a wide margin.

## 2026-01-21 - initial commit

`Initial commit: bb-cli - Bitbucket CLI`

848 lines of bash: `login`, `logout`, `status`, `pr`, `branch`, `repo`. Credentials
in `~/.config/bb-cli/credentials`, HTTP Basic against `api.bitbucket.org`, and
workspace and repository resolved from the git remote. All four still true.
