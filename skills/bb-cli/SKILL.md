---
name: bb-cli
description: "Use bb-cli for anything on Bitbucket Cloud: pull requests, pipelines, branches, build statuses, and any REST endpoint. Trigger when the user mentions Bitbucket, a bitbucket.org URL, a PR/pipeline/build number in a Bitbucket repository, asks to read or edit a pull request, check why a pipeline failed, rerun or trigger a pipeline, publish a build status or sign off on a local test run, or when the git remote points at bitbucket.org. Also use when tempted to curl api.bitbucket.org, since bb-cli api does that with credentials already loaded."
---

# bb-cli

`bb-cli` is to Bitbucket Cloud what `gh` is to GitHub. If a repository's remote
is `bitbucket.org`, this is the tool. `gh` will not work on it.

## Before anything else

```bash
command -v bb-cli || echo "not installed"
bb-cli status
```

This skill can arrive on a machine without the tool, because `npx skills add` installs
the skill, not the binary. If `bb-cli` is missing, install it rather than
falling back to `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/install.sh | bash
```

That clones into `~/.bb-cli` and installs from there. Ask the user
before running it, since it writes to their home directory.

If they would rather not have a checkout, the script alone is a valid install:

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/bin/bb-cli \
  -o ~/.local/bin/bb-cli && chmod +x ~/.local/bin/bb-cli
```

Every command works that way, `upgrade` included. Only `bb-cli docs`,
`man bb-cli` and `bb-cli skill install` need the checkout, so prefer the first
form when the user wants the documentation available offline.

It is one bash script needing `curl`, `jq` and `git`; `install.sh` symlinks it
into `~/.local/bin` and checks those dependencies.

### If there are no credentials

Only the user can create the token. It is a browser flow behind their
Atlassian login. **Do not run `bb-cli login` bare**: it prompts, and you have no
terminal, so it exits 1 telling you this. Ask them for the token instead, then
finish the job yourself.

Give them all of this at once, so it is one trip and not four:

> 1. https://id.atlassian.com/manage-profile/security/api-tokens
> 2. **Create API token with scopes** → pick the **Bitbucket** app
> 3. Check these five:
>    `read:repository:bitbucket`, `read:pullrequest:bitbucket`,
>    `read:pipeline:bitbucket`, `write:pullrequest:bitbucket`,
>    `write:pipeline:bitbucket`
> 4. Copy it. It is shown once.

Two things to say while they are in there, because both cost a second token:
**`write` does not imply `read`** (check both halves of each pair), and
**scopes are fixed at creation**, so a missing one cannot be added later.

When they hand you the token, store it without prompting:

```bash
printf %s "$TOKEN" | bb-cli login --with-token --email them@example.com
```

The email is their **Atlassian account email**, not a Bitbucket username. The
token is verified against the API before anything is written.

Prefer having them paste it into a file or an environment variable over pasting
it into the chat. The environment wins over the stored file, so this works with
nothing written to disk at all:

```bash
export BITBUCKET_USERNAME=them@example.com BITBUCKET_API_TOKEN=...
```

If `status` reports a scope gap rather than a missing credential, it names which
scope. Quote it and have them create a new token. Do not guess, and do not
probe endpoints to find out.

## The one rule

**Never `curl https://api.bitbucket.org`.** `bb-cli api` is that call with the
credential already loaded, `:repo` resolved from the git remote, and `-q` for
jq. If you find yourself building a curl command, you want:

```bash
bb-cli api <path> [-X METHOD] [-f k=v] [--input file] [-q '.jq.expr'] [-i] [--paginate]
```

Reaching for curl means either a command is missing or `api` is missing a flag.
Both are worth reporting to the user rather than working around silently.

## Reading

```bash
bb-cli pr                          # open pull requests
bb-cli pr 42                    # one PR: state, reviewers, description, activity
bb-cli pr 42 -j                 # the same as JSON, for parsing
bb-cli pr 42 -c                 # with comments
bb-cli pr --branch feature/x       # by source branch
bb-cli pr --target master          # by destination branch
bb-cli pr merged --limit 5

bb-cli pipeline                    # recent pipelines
bb-cli pipeline 1234              # one build with its steps
bb-cli pipeline 1234 failures     # failed steps + test report summary  <- start here
bb-cli pipeline 1234 steps
bb-cli pipeline 1234 step '{uuid}' --log

bb-cli branch feature              # branches matching a string
bb-cli repo

bb-cli pr checks 42                # build statuses on a PR (gh pr checks)
bb-cli cache list                  # pipeline caches (gh cache list)
```

Coming from `gh`? The surface tracks it: `run` is an alias for `pipeline`,
`view` works on `pr` and `pipeline`, `cancel` is `gh run cancel`, and
`bb-cli auth login|logout|status` works as well as the top-level forms.

For "why did the build fail", go straight to `pipeline <n> failures`. It
summarises the failed steps and their test reports, which is almost always the
answer without reading a full log.

## Writing

```bash
bb-cli pipeline trigger --branch my-branch --custom "Unit specs"
bb-cli pipeline rerun 1240                 # posts a NEW build on the branch head
bb-cli pipeline watch 1241 --exit-status
bb-cli pipeline cancel 1240                # only ever cancel builds that are yours
bb-cli cache delete <uuid>                 # by uuid: by name deletes every match

# edit a pull request: write the body to a file first, never inline
cat > /tmp/body.md <<'EOF'
line one  
line two  
EOF
bb-cli pr edit 42 --body-file /tmp/body.md
bb-cli pr edit 42 --title "New title"       # description is preserved
bb-cli pr ready 42                           # draft -> ready for review
bb-cli pr comment 42 --body-file /tmp/note.md
```

**Always use `--body-file` (or `--input` on `api`) for a pull request body.**
Descriptions are multi-line markdown, and trailing spaces are markdown's hard
line break, and command substitution strips them, so `--body "$(cat body.md)"`
silently produces a different document. This is what makes stacked issue links
render one per line instead of running together.

`pr edit` reads the pull request first and sends both title and description, so
changing one cannot blank the other.

## Signing off on a local run

`bb-cli signoff` publishes a build status on a commit, so a pull request shows a
check from a suite that ran locally. It needs no extra permission.

```bash
npm test && bb-cli signoff --name "vitest 461 passed, 23 skipped, 8s"
bb-cli signoff --fail --name "3 failures in checkout_spec"
bb-cli signoff --key lint --name "eslint clean"
bb-cli signoff status
```

Put the measured numbers in `--name`, front-loaded: the build panel truncates
it around 32–35 characters, so `461 passed, 23 skipped - local` survives where
`local signoff - vitest 461 passed` does not. That field is the whole point:
it is what a reviewer reads weeks later, and it is where Bitbucket beats GitHub,
whose equivalent field has to double as the status's identity.

Before using `--fail`, know that a build status counts toward the pull request's
build tally. On a repository whose merge check requires passing builds, a
`FAILED` signoff blocks the merge until a later run with the same `key`
overwrites it. Usually intended; not intended if you were only recording a local
experiment.

It refuses on a dirty working tree or an unpushed commit. Those refusals are
correct, because a signoff is a claim that the suite ran against *that* commit. Do not
reflexively add `--force`; fix the state, or ask the user.

## Escape hatch cookbook

```bash
# a PR's description, nothing else
bb-cli api repositories/:repo/pullrequests/42 -q .description

# what the token can do (the definitive answer, not a guess)
bb-cli api repositories/:repo -i | grep -i oauth

# every PR into a branch, across pages
bb-cli api repositories/:repo/pullrequests --paginate \
  -f 'q=destination.branch.name="master"' -q '.values[].title'

# comment on a PR
bb-cli api repositories/:repo/pullrequests/42/comments -X POST --input c.json

# pipeline caches
bb-cli api repositories/:repo/pipelines-config/caches -q '.values[].name'
bb-cli api repositories/:repo/pipelines-config/caches/<uuid> -X DELETE

# cancel a running pipeline
bb-cli api repositories/:repo/pipelines/<uuid>/stopPipeline -X POST
```

`:repo` expands to `workspace/repo-slug` from the git remote, so these work in
any checkout. Outside one, pass `--repo workspace/slug`.

## Things that will otherwise cost you time

- **`-i` is how you learn permissions.** `x-oauth-scopes` is what the token has,
  `x-accepted-oauth-scopes` is what the endpoint wants. Do not probe endpoints
  to infer scopes, and do not read the Atlassian docs pages, which render as
  JavaScript and come back empty.
- **A 403 body names both sides**: `{"required": [...], "granted": [...]}`. Quote
  it to the user rather than guessing which scope is missing.
- **Pipeline and step UUIDs need percent-encoded braces** (`%7B...%7D`) in a raw
  URL. `bb-cli` handles this everywhere, including `bb-cli api`, so paste a uuid
  from one command straight into another. Only hand-built `curl` still needs it,
  and a raw `{uuid}` there returns `400 Unexpected response body`, which looks
  like a scope problem and is not.
- **Fields do not imply POST here**, unlike `gh api`. That is deliberate:
  `POST /pullrequests` creates a pull request. Pass `-X POST` explicitly.
- **`pipeline rerun --failed` is not supported by Bitbucket's public API.** The
  web UI has it; there is no endpoint. `bb-cli` says so rather than doing
  something else. A full `rerun` runs everything, on the branch head.
- **A Bitbucket token cannot reach Jira.** Tokens are scoped to one Atlassian
  product at creation.
- **Requiring a signoff for merge needs `admin:repository:bitbucket`** and is
  not implementable from a developer token. It is a branch restriction, and it
  changes a policy everyone lives under. Tell the user to ask an admin once.

## Deeper documentation

Ships with the tool, no network needed:

```bash
bb-cli docs            # list topics
bb-cli docs setup      # install, token creation, credential file
bb-cli docs scopes     # the five scopes, what to leave off, how to prove it
bb-cli docs api        # the full api reference and cookbook
bb-cli docs pipelines  # reading/running pipelines, log slicing, trigger etiquette
bb-cli docs signoff    # local CI, field mapping against gh-signoff
man bb-cli
```

Every command also takes `--help`, and those are kept accurate.
