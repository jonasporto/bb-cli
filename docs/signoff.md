# `bb-cli signoff`: local CI, Bitbucket edition

Run the suite on your own machine, publish a green build status on the commit,
and the pull request shows a check, without renting a pipeline for it.

This is the Bitbucket counterpart of [`basecamp/gh-signoff`][gh-signoff], which
is itself DHH's argument that [continuous integration belongs back on developer
machines][dhh]: a 55k-line codebase with ~5,300 tests went from 5m30 on a
hosted runner to under 2m45 on a laptop, and the second number is the one you
wait for.

[gh-signoff]: https://github.com/basecamp/gh-signoff
[dhh]: https://world.hey.com/dhh/we-re-moving-continuous-integration-back-to-developer-machines-3ac6c611

## Use it

```bash
npm test && bb-cli signoff --name "vitest 461 passed, 23 skipped, 8s"
```

```
  ✓ local-signoff  SUCCESSFUL  a1b2c3d4e5

    vitest 461 passed, 23 skipped, 8s
    https://bitbucket.org/myworkspace/myrepo/commits/a1b2c3d4e5f...
```

Read them back, yours and everyone else's:

```bash
bb-cli signoff status
```

```
  local-signoff          SUCCESSFUL   vitest 461 passed, 23 skipped, 8s    2026-08-21
  default                SUCCESSFUL   Pipeline - default                   2026-08-21
  security/snyk          SUCCESSFUL   security/snyk                        2026-08-21
```

## What it costs in permissions: nothing extra

**`read:repository:bitbucket` is enough to publish.** Measured, not inferred:
a real status returned `201 Created` from a token with no `write:repository` and
no admin. The endpoint declares `x-accepted-oauth-scopes: repository`, and in
Bitbucket's legacy vocabulary that is the read scope.

So the most basic developer token can sign off. See `bb-cli docs scopes` for why
that is counterintuitive and how it was confirmed.

## The guards, and why they are there

A signoff is a claim: *this suite ran green against exactly this commit*. Two
things would make that false, so both refuse by default:

- **A dirty working tree.** What you tested is not what the commit contains.
- **A commit that is not on any remote.** Bitbucket has no such object to attach
  a status to, and you would get a confusing 404 instead of a clear refusal.

`--force` overrides either. Use it when you know why.

## Fields, and the one place Bitbucket beats GitHub

| GitHub (`gh signoff`) | Bitbucket (`bb-cli signoff`) |
|---|---|
| `POST repos/:o/:r/statuses/{sha}` | `POST .../commit/{sha}/statuses/build` |
| `state=success` | `state=SUCCESSFUL` |
| `context=signoff`, identity *and* label | `key` is the identity, `name` is a free label |
| `description="<user> signed off"` | `description`, same idea |
| no url needed | `url` **required** |

GitHub's `context` has to be both the identity and what a human reads, so it
ends up a bare word. Bitbucket separates them, which means the check can read

```
vitest 461 passed, 23 skipped, 8s, macOS arm64
```

instead of just `signoff`. That is the entire point of a record you consult
three weeks later, and it is the one place this API is better than GitHub's.

Field notes:

- **`key` is the identity.** A later run with the same key *overwrites* the
  status. Keep it stable and predictable, never generated. Repositories mix
  both styles in practice: Bitbucket's own pipeline writes a readable `default`,
  Snyk writes a hash.
- **The build panel truncates `name` around 32–35 characters**, so front-load
  what matters. `461 passed, 23 skipped - local` survives; `local signoff -
  vitest 461 passed, 23 skipped` shows you the word "local" and little else.
  For the same reason `description` is the wrong place for an email address:
  `gh-signoff`'s `<user> signed off` reads well only because GitHub usernames
  are short.
- **`url` is required and there is no build page to point at.** The commit page
  is the honest default. Point it at a CI artifact if you publish one.
- **`state`** is `SUCCESSFUL`, `FAILED`, `INPROGRESS` or `STOPPED`, confirmed
  by the API's own validation error, not by documentation. `INPROGRESS` makes
  "tests running locally right now" expressible.
- **Partial signoffs** are just several keys: `--key test`, `--key lint`,
  `--key types`. The same trick as `gh signoff`'s `signoff/<context>`.

## What is deliberately missing: `signoff install`

`gh signoff install` adds `signoff` to a branch's required status checks, so a
pull request cannot merge without one. The Bitbucket equivalent is a branch
restriction, and it is **not implementable from a developer credential**:

```
GET/POST /2.0/repositories/{ws}/{repo}/branch-restrictions
→ 403 {"required": ["admin:repository:bitbucket"], "granted": [...]}
```

Note that admin is required to **read** it, not only to write it. Measured
against a live repository, not read off a documentation page.

And it should not be there even with admin rights. It edits a merge policy every
other contributor lives under, from a tool one person installed. The split this
tool makes instead:

- **`bb-cli signoff` publishes a status.** No admin, no repository policy
  touched. Useful the moment a reviewer reads the commit.
- **Requiring it for merge is configured once, by whoever administers the
  repository**, in the UI or with an admin token.

If a future version ever gains admin rights, copy `gh-signoff`'s care: it reads
the existing required contexts *before* writing, so it never drops checks it did
not create. A repository carrying third-party statuses (Snyk, a pipeline)
would lose them to a careless write.

### If you want to make it mandatory anyway

Requiring a signoff before merge is a reasonable thing to want, and this is what
is actually known about it, so nobody has to measure it twice.

**Settled.** The API path is `/2.0/repositories/{ws}/{repo}/branch-restrictions`,
and it answers `403` to both `GET` and `POST` from a developer token, naming
`admin:repository:bitbucket` in the response body. Admin is required to *read*
the current restrictions, not only to change them, so a tool cannot even show
you what is configured today without it.

**Not settled, and what would settle it.** Whether the "require passing builds"
merge check exists and is configurable on a given Bitbucket plan. On GitHub the
equivalent needs a paid plan, so it is plausible this differs by tier. Answering
it needs one look at the repository's merge-check settings in the UI by someone
with admin, or one `GET /branch-restrictions` with an admin token. Neither is a
developer-credential operation, and neither should be done casually on a shared
repository.

**If it turns out to be available**, the shape that fits this tool is several
keys rather than one gate: `--key test`, `--key lint`, `--key types`, each
required. That gives "these specific steps must have run" instead of a single
boolean, and it is the same mechanism as `gh signoff`'s `signoff/<context>`.

**Two cautions for whoever configures it.** A `FAILED` signoff counts against
the build tally, so the merge check will hold the pull request until a later run
with the same key overwrites it: intended, but surprising the first time. And
whatever writes that restriction must read the existing required checks first
and merge into them: a repository already carrying third-party statuses would
otherwise lose them, silently.

## When this does not replace cloud CI

The pattern is worth adopting, and it is not a universal replacement. Three
cases where a signoff is the wrong instrument, each from a real failure rather
than a hypothetical:

**A platform your machine cannot exercise.** The signing machine is whatever you
carry; production usually is not. Two defects surfaced on one project in a
single day that a laptop-only signoff would have caught neither of: a native
image library missing on the Linux runner, and `Coverage` plus `fork()`
segfaulting a database driver specifically on arm64 macOS. "Green locally" said
nothing about Linux in either direction. If you need that matrix, a container
target has to exist *before* you switch the remote one off, and it can publish
its own partial signoff with `--key linux`.

**Untrusted external contributions at volume.** A signoff is a claim by someone
with repository access. A fork cannot certify itself, and you must never point a
self-hosted runner at a public repository, because a fork pull request would execute
arbitrary code on your machine. Keep a minimal fork workflow if that volume is
real.

**Release and deploy pipelines.** They need secrets and a neutral, reproducible
environment, and they run rarely enough that the wait costs nothing. Leave them
where they are.

The honest framing: this replaces *the feedback loop*, which is the part you
wait on many times a day. It does not replace the parts that exist because a
neutral machine is the point.

Two things also worth knowing before adopting it. The suite has to be fast
enough to run on every merge without flinching: minutes, not tens of minutes;
if it is not, speeding it up is the prerequisite, not a detail. And the value
is partly in what you stop paying attention to: runner evictions that look like
test failures, tool-version pinning, and pipeline YAML upkeep.

## Wiring it into a real loop

The command is one call; the value is in what runs before it.

```bash
#!/usr/bin/env bash
# bin/check - run everything, then sign off with the numbers
set -euo pipefail

start=$(date +%s)
output=$(npm test 2>&1) || { bb-cli signoff --fail --name "tests failed"; exit 1; }
elapsed=$(( $(date +%s) - start ))

summary=$(printf '%s' "$output" | grep -Eo '[0-9]+ passed.*' | tail -1)
bb-cli signoff --name "${summary}, ${elapsed}s, $(uname -s) $(uname -m)"
```

Two habits worth keeping:

- **Sign off on the commit you just tested**, not on whatever HEAD became while
  the suite ran. The clean-tree guard catches the common version of this.
- **Publish failures too, but know what it costs.** `--fail` makes the status
  honest rather than an award you only hand yourself when you win. Be aware that
  a build status counts toward the pull request's build tally (the "5 of 5
  builds passed" line), so on a repository whose merge check requires passing
  builds, a `FAILED` signoff **will block the merge** until a later run with the
  same `key` overwrites it. That is usually the point. It is not, if you were
  only recording a local experiment: use a separate `--key`, or leave it off.
