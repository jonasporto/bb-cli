# bb-cli

[![Tests](https://github.com/jonasporto/bb-cli/actions/workflows/test.yml/badge.svg)](https://github.com/jonasporto/bb-cli/actions/workflows/test.yml)

**Bitbucket Cloud from the command line.**

What `gh` is to GitHub. Pull requests, pipelines, branches and build statuses in
a terminal, plus `bb-cli api`, an authenticated passthrough for everything
else, so a missing command is an inconvenience rather than a blocker.

One bash script. No build step, no runtime, no daemon.

```bash
bb-cli pr                                    # open pull requests
bb-cli pipeline 1234 failures               # why did the build fail
npm test && bb-cli signoff                   # local CI: publish a green check
bb-cli api repositories/:repo -i             # anything else
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/install.sh | bash
bb-cli login
```

That clones into `~/.bb-cli` and installs from there, or reuses a checkout
you already have, so re-running it never leaves a second copy behind.
`BB_CLI_HOME` puts it somewhere else:

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/install.sh \
  | BB_CLI_HOME=~/src/bb-cli bash
```

Or clone it yourself and run the script in place. The same thing, one step at a
time:

```bash
git clone https://github.com/jonasporto/bb-cli.git ~/.bb-cli
~/.bb-cli/install.sh
bb-cli login
```

### Just the script

If you only want the binary on your PATH, that works too:

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/bin/bb-cli \
  -o ~/.local/bin/bb-cli && chmod +x ~/.local/bin/bb-cli
```

Every command works. `bb-cli upgrade` works too, by replacing the script from
the same URL. What you give up is the material that lives beside the script and
cannot fit inside it: `bb-cli docs`, `man bb-cli` and `bb-cli skill install`.
Those three say so plainly, and name the one line that gets them back.

`install.sh` checks for `curl`, `jq` and `git`, symlinks the executable into
`~/.local/bin` and the man page into `~/.local/share/man/man1`, and tells you if
either is outside your `PATH` or `MANPATH`. Symlinks, not copies, so `git pull`
upgrades the installed tool. `--prefix`, `--bin-dir` and `--uninstall` are
there too.

Full walkthrough, including which five token scopes to check and why:

```bash
bb-cli docs setup
```

## Documentation travels with the tool

No wiki to find, no network needed.

| | |
|---|---|
| `bb-cli --help`, `bb-cli help <cmd>` | every command has one, kept accurate |
| `man bb-cli` | the man page (or `bb-cli man`, which works before install) |
| `bb-cli docs` | list the topics |
| `bb-cli docs setup` | install, token creation, the credentials file |
| `bb-cli docs scopes` | the five scopes, what to leave unchecked, how to prove what a token holds |
| `bb-cli docs api` | `bb-cli api` reference and a curl-replacement cookbook |
| `bb-cli docs pipelines` | reading and running pipelines, log slicing, trigger etiquette |
| `bb-cli docs signoff` | local CI, field-by-field against `gh signoff` |

## Using it with an AI agent

A skill ships in this repository, so an agent that has never seen this tool
knows it exists, when to reach for it, and the traps that would otherwise cost
it a dozen turns.

```bash
npx skills add jonasporto/bb-cli
```

That is [`vercel-labs/skills`](https://github.com/vercel-labs/skills), which
installs into whichever agent you use: Claude Code, Codex, Cursor, Copilot and
around eighty others. `-g` installs globally, `-p` per project. It installs the
skill, not the tool: the skill's first instruction is to check for `bb-cli` and
install it if missing.

It needs `git` on the machine, and it asks which agents to install into. In a
script or a container, name them:

```bash
npx skills add jonasporto/bb-cli -p -y --agent claude-code
npx skills add jonasporto/bb-cli --all      # every skill, every agent
```

`bb-cli skill install` does a smaller version of the same thing, for when you
already have this checkout and would rather not involve node, or you are
offline:

```bash
bb-cli skill install              # links into ~/.claude/skills/bb-cli
bb-cli skill install --project    # ./.claude/skills, commits with the repo
bb-cli skill print                # stdout, installs nothing
```

It links rather than copies, so `git pull` updates the skill too. It is **not**
equivalent to `npx skills add`:

| | `npx skills add` | `bb-cli skill install` |
|---|---|---|
| agents | ~80 | Claude Code |
| needs this checkout | no, clones it | yes |
| needs node | yes | no |
| lockfile + content hash | yes | no |
| `update` / `list` / `remove` | yes | no |

`AGENTS.md` at the repository root covers the same ground for agents that read
that convention instead.

## Commands

### Pull requests

| Command | Does |
|---|---|
| `bb-cli pr` | list open pull requests |
| `bb-cli pr <n>` | one PR: state, reviewers, **description**, comments summary, activity |
| `bb-cli pr <n> -j` | the same as JSON |
| `bb-cli pr <n> -c` | with comment bodies |
| `bb-cli pr <string>` | filter by source branch |
| `bb-cli pr --target master` | filter by destination branch |
| `bb-cli pr --author X` | filter by author |
| `bb-cli pr merged --limit 5` | last five merged |

```bash
bb-cli pr edit 42 --body-file body.md      # title and/or description
bb-cli pr ready 42                          # draft -> ready for review
bb-cli pr comment 42 --body-file note.md
```

**Always `--body-file`, not `--body "$(cat f)"`.** Descriptions are multi-line
markdown, and two trailing spaces are markdown's hard line break, and command
substitution strips them, which is exactly what turns a list of stacked issue
links into one run-on paragraph. `--body` exists for one-liners.

`pr edit` reads the pull request first and sends both fields, so changing only
the title cannot blank the description.

Creating, merging and reviewing still go through `api`. See the cookbook in
`bb-cli docs api`.

### Pipelines

| Command | Does |
|---|---|
| `bb-cli pipeline` | recent pipelines with status, duration, actor, commit, branch, trigger |
| `bb-cli pipeline <n>` | one build with its steps |
| `bb-cli pipeline <n> failures` | failed steps and test-report summary. **Start here** |
| `bb-cli pipeline <n> steps` | every step |
| `bb-cli pipeline <n> step <uuid> --log` | a step's raw log |
| `bb-cli pipeline trigger --branch <b> [--custom "<name>"]` | new build (needs Pipelines: Write) |
| `bb-cli pipeline rerun <n>` | post a **new** build for the same target/selector |
| `bb-cli pipeline watch <n> [--exit-status]` | poll until it finishes |

Flags may appear **before or after** the subcommand: `pipeline --repo X rerun 1240`
and `pipeline rerun 1240 --repo X` are the same thing.

### Signoff: local CI

```bash
npm test && bb-cli signoff --name "vitest 461 passed, 23 skipped, 8s"
bb-cli signoff status
```

Publishes a build status on the commit, so the pull request shows a check from a
suite that ran on your machine. The Bitbucket counterpart of
[`basecamp/gh-signoff`](https://github.com/basecamp/gh-signoff).

**It needs no extra permission.** `read:repository:bitbucket` is enough to
publish, which is counterintuitive and was measured rather than assumed.

It refuses on a dirty working tree or an unpushed commit, because a signoff is a
claim that the suite ran green against *that* commit. `--force` overrides.

There is no `bb-cli signoff install`. Requiring the status for merge is a branch
restriction needing `admin:repository:bitbucket` to read as well as write, and it
edits a policy every contributor lives under. `bb-cli docs signoff` explains.

### `bb-cli api`: the escape hatch

`gh` is not sufficient because it has a command for everything; it is sufficient
because it has `gh api`.

```bash
bb-cli api repositories/:repo/pullrequests/10 -q .description
bb-cli api repositories/:repo/pullrequests/10 -X PUT --input body.json
bb-cli api repositories/:repo -i | grep -i oauth
bb-cli api repositories/:repo/pullrequests --paginate -q '.values[].title'
```

`:repo` expands to `workspace/slug` from the git remote, so a command pasted
into a document works in anyone's checkout. `-q` runs jq. `-i` prints headers,
which is how you find out what a token can actually do. `--input` is byte-exact,
which matters more than it sounds: trailing spaces are markdown's hard line
break, and command substitution eats them.

**One deliberate difference from `gh`:** `-f`/`-F` alone do **not** imply POST
here. On Bitbucket, `POST /pullrequests` creates a pull request, so a read that
silently became a write would be expensive. Say `-X POST` when you mean it.

### Caches

```bash
bb-cli cache list                 # uuid, name, size, age
bb-cli cache delete <uuid>
```

By uuid only, deliberately. Bitbucket's API also accepts `?name=`, and that
removes **every** cache sharing that name (they are distinguished by path as
well), so one call takes out other branches' caches too.

### Other

`bb-cli branch [filter]`, `bb-cli repo`, `bb-cli status`, `bb-cli login`,
`bb-cli logout`, `bb-cli version`.

## Coming from `gh`

The command surface tracks `gh` wherever Bitbucket allows it, so muscle memory
carries over. `gh`'s nouns are accepted as aliases even where Bitbucket's own
vocabulary is the primary name.

| `gh` | `bb-cli` | |
|---|---|---|
| `gh auth login` / `logout` / `status` | same, and also at the top level | ✅ |
| `gh auth login --with-token` | `bb-cli login --with-token` | ✅ |
| `gh api` | `bb-cli api` | ✅ |
| `gh pr list` | `bb-cli pr` / `bb-cli pr list` | ✅ |
| `gh pr view <n>` | `bb-cli pr <n>` / `bb-cli pr view <n>` | ✅ |
| `gh pr checks <n>` | `bb-cli pr checks <n>` | ✅ |
| `gh pr edit <n>` | `bb-cli pr edit <n>` | ✅ |
| `gh pr ready <n>` | `bb-cli pr ready <n>` (`--undo`) | ✅ |
| `gh pr comment <n>` | `bb-cli pr comment <n>` | ✅ |
| `gh run list` | `bb-cli pipeline` / `bb-cli run` | ✅ |
| `gh run view <n>` | `bb-cli pipeline <n>` / `view <n>` | ✅ |
| `gh run view --log` | `bb-cli pipeline <n> step <uuid> --log` | ✅ |
| `gh run rerun <n>` | `bb-cli pipeline rerun <n>` | ✅ |
| `gh run watch <n>` | `bb-cli pipeline watch <n>` | ✅ |
| `gh run cancel <n>` | `bb-cli pipeline cancel <n>` | ✅ |
| `gh workflow run` | `bb-cli pipeline trigger` | ✅ |
| `gh cache list` / `delete` | `bb-cli cache list` / `delete` | ✅ |
| `gh repo view` | `bb-cli repo` | ✅ |
| `gh version` | `bb-cli version` | ✅ |
| `gh run rerun --failed` | prints the limitation | ⛔ no Bitbucket endpoint |
| `gh pr create` | `bb-cli api` for now | ⏳ roadmap |
| `gh pr merge` / `close` / `review` | `bb-cli api` | ⏳ |
| `gh browse` | none yet | ⏳ |
| none | `bb-cli signoff` | Bitbucket build status, mirrors the `gh-signoff` extension |
| none | `bb-cli docs` / `man` / `skill` | no `gh` equivalent |

Where the names differ, Bitbucket's noun wins and `gh`'s is an alias: a
*pipeline* is what Bitbucket calls it everywhere else (its UI, its docs, its
API), so a tool that called it a *run* would be lying about the system it talks
to. `bb-cli run` works anyway.

Two divergences are deliberate rather than missing, and both are in
`bb-cli docs api`: `-f`/`-F` do not imply `POST`, and `--paginate` merges
`.values` instead of concatenating pages.

## Credentials

`~/.config/bb-cli/credentials`, mode `600` in a `700` directory:

```
BITBUCKET_USERNAME=<atlassian email>
BITBUCKET_API_TOKEN=<token>
```

The environment wins over the file, so `BITBUCKET_API_TOKEN=xxx bb-cli pr 10`
tries a token without touching anything, and CI can supply one directly.

`bb-cli login` is interactive. Where there is no terminal (a script, CI, an
agent), pass the token on stdin instead, the way `gh auth login --with-token`
does:

```bash
printf %s "$TOKEN" | bb-cli login --with-token --email you@example.com
```

Five scopes, and two traps: **`write` does not imply `read`**, and scopes are
**fixed at creation**. `bb-cli docs scopes` has the full table, including which
scopes look necessary and are not, and why `admin:repository` is deliberately
left off.

## Tests

```bash
tests/run.sh          # every suite
tests/run.sh api      # one suite
```

Offline by design: a fake `curl` on `PATH` records the argv and answers from a
fixture, so the whole suite runs in about the time one real request would take,
with no token and no network. The suites assert on **what would go over the
wire** (verb, URL, request body) rather than on formatted output.

## Known limits

- **`pipeline rerun --failed` is not supported by Bitbucket's public API.** The
  web UI has it; there is no endpoint (the UI calls an undocumented internal
  API). bb-cli prints the limitation rather than quietly doing something else. A
  full `rerun` runs everything, on the branch head.
- **Requiring a signoff for merge needs repo admin** and is out of scope by
  design.
- **A Bitbucket token cannot reach Jira.** Atlassian scopes a token to one
  product at creation.

## License

MIT. See [LICENSE](LICENSE).
