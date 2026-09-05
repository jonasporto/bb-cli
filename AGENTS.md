# bb-cli, for agents

This file is for AI coding agents working in a repository that uses `bb-cli`,
and for agents working on `bb-cli` itself.

## If you are here to *use* bb-cli

`bb-cli` is to Bitbucket Cloud what `gh` is to GitHub. When a repository's
remote is `bitbucket.org`, `gh` will not work on it and this tool will.

```bash
bb-cli status                    # is it installed and authenticated?
bb-cli --help                    # the command surface
bb-cli docs                      # setup, scopes, api, signoff
```

**Never `curl https://api.bitbucket.org` directly.** Use `bb-cli api`, which is
the same call with the credential loaded and `:repo` resolved from the git
remote:

```bash
bb-cli api repositories/:repo/pullrequests/10 -q .description
bb-cli api repositories/:repo/pullrequests/10 -X PUT --input body.json
bb-cli api repositories/:repo -i | grep -i oauth
```

If `bb-cli` itself is missing, `curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/install.sh | bash` installs it. Ask the user first, it writes to their home directory.

The full agent-facing guide is `skills/bb-cli/SKILL.md`. Install it with
`npx skills add jonasporto/bb-cli` (any agent), or `bb-cli skill install` if the
tool is already present and you would rather not involve node. `bb-cli skill
print` writes it to stdout without installing anything.

## If you are here to *change* bb-cli

### Ground rules

**Verify against the API, not against the documentation.** Atlassian's developer
pages render as JavaScript and repeatedly came back empty; every non-obvious
claim in `docs/` was established by making a request and reading the response.
Keep that standard: if you write something down, say how you know it, and mark
inference as inference.

**Response headers beat probing.** `x-oauth-scopes` lists what a token holds and
`x-accepted-oauth-scopes` what an endpoint demands. Inferring permissions from
status codes is a fallback, and it nearly produced a wrong conclusion once. See
the note in `docs/scopes.md`.

**A POST with an empty body makes the API state its own contract**, because
field validation usually runs after authorization. That is how the build-status
field list was established.

### Layout

```
bin/bb-cli              the whole tool, one bash script
docs/                   setup, scopes, api, signoff, surfaced by `bb-cli docs`
man/bb-cli.1            the man page, installed by install.sh
skills/bb-cli/SKILL.md  the Claude Code skill
tests/                  offline suites; tests/run.sh runs them all
install.sh              symlinks the binary and the man page
```

### Tests

```bash
tests/run.sh            # everything, in about a second
tests/run.sh api        # one suite
```

Every suite is offline: a fake `curl` on `PATH` records the argv and answers
from a fixture (`tests/lib/fake_curl.sh`). No network, no token, no rate limit.
Assert on **what would go over the wire** (the HTTP verb, the URL, the request
body) rather than on formatted output, which changes for cosmetic reasons.

Two bash traps the harness exists to avoid, both of which have already caused
bugs here:

- `x="$(some_function)"` runs the function in a **subshell**, so any variable it
  sets is lost. That silently swallowed the HTTP status code, making every error
  look like a success. `api_request` writes to files for this reason.
- `cmd | while read` and `echo x | run_bb` have the same problem: the right-hand
  side is a subshell.

### When you add a command

1. A `cmd_<name>` function and a `cmd_<name>_help`, wired into `main` and into
   the `help <topic>` case.
2. A test suite, or new cases in an existing one, asserting the request shape.
3. `--help` text that is accurate, because agents read it before the docs.
4. If it changes setup or permissions, update `docs/` and `man/bb-cli.1`.
5. If it changes what an agent should reach for, update
   `skills/bb-cli/SKILL.md`.

### Deliberate design choices, so you do not "fix" them

- **`-f`/`-F` on `bb-cli api` do not imply POST**, unlike `gh api`. On Bitbucket
  a POST to `/pullrequests` creates a pull request, so an accidental write is
  expensive. Only `--input` implies POST.
- **`--paginate` merges `.values` into one array** rather than concatenating page
  objects the way `gh` does, because that is Bitbucket's pagination shape.
- **`signoff` refuses on a dirty tree or an unpushed commit.** A signoff is a
  claim that a suite ran green against that exact commit.
- **There is no `signoff install`.** Requiring a status for merge is a branch
  restriction needing `admin:repository:bitbucket` to read as well as write, and
  it edits a policy every contributor lives under.
- **`pipeline rerun --failed` prints a limitation instead of doing something
  else.** Bitbucket's public API has no such endpoint, though the web UI does.
