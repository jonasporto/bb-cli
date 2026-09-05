# `bb-cli api`: the escape hatch

`gh` is not sufficient because it has a command for everything. It is
sufficient because it has `gh api`. Everything else is convenience layered on
that.

`bb-cli api` is the same thing for Bitbucket: an authenticated passthrough with
`--method`, `--field`, `--input`, `--include`, `--jq` and `--paginate`. When a
porcelain command is missing, this is the fallback, which means a missing
command is an inconvenience rather than a blocker.

The rule of thumb: **reaching for `curl` means a bug report.** Either a command
is missing, or `api` is missing a flag.

## The endpoint argument

```bash
bb-cli api repositories/:repo/pullrequests/10   # under https://api.bitbucket.org/2.0/
bb-cli api 2.0/user                             # an explicit 2.0/ is kept
bb-cli api internal/repositories/:repo/...      # the undocumented internal API
bb-cli api https://api.bitbucket.org/2.0/...    # a full URL, Bitbucket only
```

A full URL is accepted **only for `api.bitbucket.org` or `bitbucket.org`, and
only over https**. This command attaches your Bitbucket credential to whatever
it is handed, so an arbitrary host would make it an exfiltration primitive:
one `bb-cli api https://somewhere-else/` would send your token there. That is
not paranoia about typos. An agent following this tool's skill reads pull
request bodies and pipeline logs that other people wrote. If you genuinely need
another host, use `curl`, where you decide what credential goes with it.

Placeholders expand from the git remote, so a command pasted into a document
works in anyone's checkout:

| Placeholder | Becomes |
|---|---|
| `:repo` or `{repo}` | `workspace/repo-slug` |
| `:workspace` or `{workspace}` | the workspace |
| `:slug` or `{slug}` | the repository slug |

`--repo myworkspace/myrepo` overrides the remote, and works outside a checkout.

## Flags

| Flag | Does |
|---|---|
| `-X, --method` | HTTP method. Default `GET`, or `POST` when `--input` is given |
| `-f, --raw-field K=V` | string field: a query parameter on `GET`, a JSON field on a write |
| `-F, --field K=V` | typed field: `true`/`false`/`null` and numbers stay unquoted; `@file` reads the value from a file |
| `--input FILE` | request body read verbatim (`-` for stdin) |
| `-q, --jq EXPR` | filter the response through jq |
| `-i, --include` | print response headers |
| `-H, --header "K: V"` | extra request header, repeatable |
| `--paginate` | follow `next` and merge every page's `.values` |
| `-R, --repo REF` | workspace/repo instead of the git remote |

Exit code is 1 on any HTTP status >= 400. The response body is still printed,
the way `gh` does it, because Bitbucket's error bodies are the most useful part
of a failure.

Three more things it will refuse, each because a real one was found and fixed:
a `next` link during `--paginate` that points at another host or at anything
other than https; a plaintext `http://` endpoint, which would put basic auth on
the wire in the clear; and a redirect that downgrades to http.

### One deliberate difference from `gh`

In `gh`, `-f`/`-F` on their own imply `POST`. **Here they do not.**

On Bitbucket, `POST /repositories/{ws}/{repo}/pullrequests` *creates a pull
request*. A documented read like

```bash
bb-cli api repositories/:repo/pullrequests -f 'q=state="OPEN"'
```

would then silently be a write. Fields never change the method here, so say
`-X POST` when you mean it. `--input` does imply `POST`, because a request body
only makes sense on a write.

### `--input`, not `-d "$(cat file)"`

Use `--input` for anything multi-line. This is not style. Getting three Jira
issue links to stack as cards in a pull request body requires two trailing
spaces at the end of each line, preserved byte for byte, because markdown's hard
break. Command substitution strips trailing whitespace, so `-d "$(cat body.md)"`
silently produces a different document from the one on disk.

### `--paginate` merges, it does not concatenate

`gh api --paginate` concatenates page objects. Bitbucket paginates as
`{"values": [...], "next": "<url>"}`, so this merges instead and hands back one
`{"values": [...]}` with every page's items. That is what you almost always
want, and it means `-q '.values[]'` works the same paginated or not.

It stops after 100 pages with a warning rather than looping forever.

## Cookbook

Every one of these replaced a raw `curl` that a real session actually ran.

```bash
# read a pull request's description
bb-cli api repositories/:repo/pullrequests/10 -q .description

# rewrite title and body, byte-exact
bb-cli api repositories/:repo/pullrequests/10 -X PUT --input body.json

# what can this token do?
bb-cli api repositories/:repo -i | grep -i oauth

# every pull request into a branch, across pages
bb-cli api repositories/:repo/pullrequests --paginate \
  -f 'q=destination.branch.name="master"' -q '.values[].title'

# build statuses on a commit
bb-cli api repositories/:repo/commit/$(git rev-parse HEAD)/statuses -q '.values[].key'

# comment on a pull request
bb-cli api repositories/:repo/pullrequests/10/comments -X POST --input comment.json

# pipeline caches: list, then delete one BY UUID
bb-cli api repositories/:repo/pipelines-config/caches -q '.values[] | "\(.uuid) \(.name)"'
bb-cli api repositories/:repo/pipelines-config/caches/<uuid> -X DELETE
# NOT by name: ?name=gems deletes every cache sharing that name, on every
# branch, because caches are distinguished by path as well as by name.

# cancel a running pipeline
bb-cli api repositories/:repo/pipelines/<uuid>/stopPipeline -X POST

# the configured runners
bb-cli api repositories/:repo/pipelines-config/runners -q '.values[].name'
```

`comment.json` for that third-from-last one:

```json
{"content": {"raw": "Looks good.\n\nOne question about the cache key."}}
```

## Two Bitbucket mechanics that cost time

**Pipeline and step UUIDs need their braces percent-encoded**, and `bb-cli
api` now does it for you. A raw `{2a2f5c49-...}` in a path returns `400
Unexpected response body`, which reads like a malformed request or a missing
scope and is neither. Paste a uuid straight out of `bb-cli pipeline <n> steps`
and it works; an already-encoded `%7B...%7D` is left alone.

Only `curl` still needs it by hand, which is one more reason not to reach for
it.

**A `POST` with an empty body is a safe way to make the API state its own
contract**, because field validation runs after authorization on most
endpoints. Posting `{}` to the build-status endpoint is what produced the
required-field list in `bb-cli docs signoff`. It is safe *because* it fails,
but see `bb-cli docs scopes` for why a 400 there is suggestive rather than
conclusive about permissions.
