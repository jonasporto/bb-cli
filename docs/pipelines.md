# Pipelines: reading them, running them, and not stepping on anyone

`bb-cli pipeline` was modelled on `gh run`, so the muscle memory carries over.
Two things do not, and both cost real time the first time you meet them.

## The mapping

| bb-cli | gh |
|---|---|
| `bb-cli pipeline` | `gh run list` |
| `bb-cli pipeline <n>` / `<n> steps` | `gh run view <n>` |
| `bb-cli pipeline <n> step <uuid> --log` | `gh run view <n> --log` |
| `bb-cli pipeline <n> failures` | `gh run view <n> --log-failed` |
| `bb-cli pipeline trigger --custom "<name>"` | `gh workflow run` |
| `bb-cli pipeline rerun <n>` | `gh run rerun <n>` |
| `bb-cli pipeline watch <n> --exit-status` | `gh run watch <n> --exit-status` |
| `bb-cli pipeline cancel <n>` | `gh run cancel <n>` |

`bb-cli run` is accepted everywhere `pipeline` is, since that is `gh`'s noun for
the same object.

Both honour `--exit-status`, so the chaining idiom works either way:

```bash
bb-cli pipeline watch 1241 --exit-status && echo green || echo red
```

Flags `gh` has and this does not: `gh run watch --compact` (only relevant and
failed steps), `-i/--interval` (default 3s), and `gh run watch` with no run id,
which prompts you to pick from the in-progress runs. `bb-cli pipeline watch`
takes `--exit-status` and `-j/--json`, and needs the build number.

## The two gaps

**There is no failed-only rerun.** `gh run rerun --failed` re-runs just the
failed jobs; Bitbucket's public REST API has no equivalent, so
`bb-cli pipeline rerun` posts a *new* build of the same target: branch head
plus custom selector. On a suite sharded eighteen ways that is the difference
between re-running three shards and re-running eighteen, roughly half an hour.
Prefer fixing locally and triggering once.

The web UI does offer "rerun failed steps"; it calls an undocumented internal
API. The public feature request is [BCLOUD-21591][bcloud]. `bb-cli pipeline
rerun <n> --failed` prints this rather than quietly doing something else.

[bcloud]: https://jira.atlassian.com/browse/BCLOUD-21591

**`failures` is metadata, not logs.** `bb-cli pipeline <n> failures` lists the
failed steps and any JUnit test report. When a step emits no report it says
"No test report available", which is common, and **does not mean there were no
failures**. There is no `--log-failed`. Get the log yourself:

```bash
bb-cli pipeline <n> step '{<uuid>}' --log > log.txt
sed -n '/^Failures:/,$p' log.txt | head -120
```

**Redirect to a file first.** A shard log can run to 44,000 lines. Never pipe a
raw `--log` straight into a terminal, and never into an agent's context.

## Statuses lie, a little

The status in the web UI and the API's `state` are related but not identical.
Normalise from `state.result.name`, then `state.name`, then `state.stage.name`
which is what `bb-cli` prints for you. UI "Failed", "Error" and "System
error" all map to completed/failed.

Source: [Atlassian, differences between pipeline status in UI and API][uiapi].

[uiapi]: https://support.atlassian.com/bitbucket-cloud/kb/differences-between-bitbucket-pipelines-status-from-ui-and-api-results/

## Addressing a build

`bb-cli pipeline <n>` takes a build number and resolves it in one request:
Bitbucket accepts a build number in the `{pipeline_uuid}` path slot, even though
only a uuid is documented there.

**Do not try `?q=build_number=N` instead.** That filter is accepted and silently
ignored, and you get the first page, unfiltered. A wrong pipeline, not an error.

`--repo` takes `workspace/slug` **or a full Bitbucket URL**, so a link pasted
from a browser works:

```bash
bb-cli pipeline --repo https://bitbucket.org/myworkspace/myrepo/src/master/ --limit 5
```

Step UUIDs appear in three forms: `%7Buuid%7D` in a URL, `{uuid}` in the API,
and bare `uuid`. `bb-cli` normalises all three, in the porcelain commands *and*
in `bb-cli api`, so a uuid copied out of one command works in the other. A
hand-built `curl` URL with unencoded braces returns `400 Unexpected response
body`, which reads like a malformed request or a missing scope and is neither.

When filtering by a branch name containing `/`, `--branch` matches exactly, so
`feature/my-feature` does not also pull in `feature/my-feature-2`.

## Before you trigger: check, then own it

Two failure modes on a shared repository, both avoidable:

**Duplicate concurrent builds on the same branch**, wasted minutes and a
"which run is the real one?" question at triage time.

**Stopping someone else's build.** Don't. Ever.

The protocol before every `trigger` or `rerun`:

1. **Look for a build already running on the branch.**

   ```bash
   bb-cli pipeline --branch <branch> --limit 5
   ```

   Look for `IN_PROGRESS` or `PENDING`.

2. **If one is running, decide by ownership.**
   - **Yours and obsolete** (an older commit, superseded by your push): stop it
     with `bb-cli pipeline cancel <n>`, then trigger. A build that already
     finished answers 400, not 403: the state refused, not your permissions.
   - **Yours and current** (the same commit you were about to run): just
     `watch` it. Don't duplicate.
   - **Not yours**: never stop it. Wait, or run on your own branch.

3. **Keep a note of the builds you start.** `bb-cli pipeline --branch X` shows
   everyone's builds for that branch, not only yours, and there is no "mine"
   filter that survives across sessions and checkouts. A one-line-per-build note
   is the only reliable record of which ones you may stop.

## When a build "does not exist"

If `bb-cli pipeline <n>` says the build was not found but a URL or an earlier
command says otherwise, check access before concluding it is gone:

```bash
bb-cli status
bb-cli pipeline --limit 5
```

The usual causes are a missing or expired credential, the wrong repository
parsed out of a URL, or a build number that belongs to a different repository.
Do not start reading local code until the remote metadata is confirmed.

## Caches and runners

```bash
bb-cli cache list                 # uuid, name, size, age
bb-cli cache delete <uuid>
```

**Deleting a cache by name deletes every cache that shares that name.** Caches
are distinguished by path, not only by name, so `?name=gems` removes all of
them, including other branches'. `bb-cli cache delete` therefore takes a uuid
and refuses a name; if you really want the sweep, it is one `bb-cli api` call
and you have to write it out.

Runners have no porcelain command yet:

```bash
bb-cli api repositories/:repo/pipelines-config/runners -q '.values[].name'
```

## One thing to know about raw logs and `bb-cli api`

The raw log endpoint returns text, not JSON, and answers `406 Not Acceptable`
to a request carrying `Accept: application/json`. `bb-cli api` omits that header
for `/log` paths, and an explicit `-H 'Accept: ...'` of your own always wins,
so both of these work:

```bash
bb-cli pipeline <n> step '{<uuid>}' --log
bb-cli api "repositories/:repo/pipelines/<n>/steps/{<uuid>}/log"
```

The braces are encoded for you in both, so a uuid pasted from
`bb-cli pipeline <n> steps` works as-is.
