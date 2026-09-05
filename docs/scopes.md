# Scopes: what bb-cli needs, what it does not, and how to prove it

Everything below was measured against the live API, not read off a
documentation page. Where a claim rests on inference rather than a request that
actually returned, it says so.

## The five

```
read:repository:bitbucket
read:pullrequest:bitbucket
write:pullrequest:bitbucket
read:pipeline:bitbucket
write:pipeline:bitbucket
```

That covers every endpoint bb-cli calls, plus editing a pull request, plus
publishing a build status. Verified by rotating a token to exactly these five
and re-running the whole command surface.

| Command | Needs |
|---|---|
| `status`, `repo`, `branch` | `read:repository` |
| `pr`, `pr <n>` | `read:pullrequest` |
| `api ... -X PUT` on a pull request | `write:pullrequest` |
| `pipeline`, `pipeline <n>`, `steps`, `failures`, step logs | `read:pipeline` |
| `pipeline trigger`, `pipeline rerun` | `write:pipeline` |
| `signoff`, `signoff status` | `read:repository`, yes, the read one |

## Six things that catch people

1. **`write` does not imply `read`.** The scopes are isolated. A token holding
   only `write:pipeline:bitbucket` can start a pipeline and then cannot check
   whether it passed. Check both halves of every pair.
2. **Scopes are fixed at creation.** A token cannot gain one afterwards. The fix
   is always a new token, then updating the credentials file, never editing the
   existing token.
3. **A scope is not a repository permission.** They are two separate systems and
   you need both. Triggering a pipeline on a branch takes
   `write:pipeline:bitbucket` *and* the token owner's account having write access
   to that branch. A 403 can mean either, so check the account before assuming
   the token is wrong.
4. **The same isolation applies to `admin:*`.** `admin:pipeline:bitbucket`
   grants pipeline variables and configuration, and implies neither read nor
   write of pipelines. Admin is a third thing, not a superset.
5. **`write:pullrequest` is broader than it sounds.** It covers creating,
   commenting, approving, merging and declining, not just `PUT` on a title and
   description. Grant it deliberately.
6. **A draft pull request is not a separate permission.** Same endpoint, same
   scope: `POST .../pullrequests` with `"draft": true`.

## What to leave unchecked, and why

Each of these looks necessary. None is.

| Scope | Verdict |
|---|---|
| `read:project:bitbucket` | **Not needed. Proven by removal**: a rotated token dropped it and every bb-cli command still passed. That is stronger evidence than grepping the source for project endpoints, which was the earlier basis |
| `read:account`, `read:me` | Not needed. `bb-cli status` tries `GET 2.0/user`, takes the 403 and falls back to the repository endpoint. Nothing breaks |
| `read:test:bitbucket` | Not needed. `read:pipeline` already covers the test-report endpoints, which answer 404 when a step has no report, not 403 |
| `write:repository:bitbucket` | Not needed. `origin` is SSH, so git never authenticates with the token. And publishing a build status does not need it either (below) |
| `admin:repository:bitbucket` | **Deliberately excluded.** It is what branch restrictions require, for READ as well as write, and that policy is not a developer's to edit. See `bb-cli docs signoff` |

## The full catalogue

The creation screen lists around forty-five Bitbucket scopes. bb-cli needs the
five above; the rest exist and are worth recognising when you see one named in
a 403 body. They follow one shape: `read:` / `write:` / `admin:` crossed with
`repository`, `pullrequest`, `pipeline`, `project`, `workspace`, `webhook`,
`issue`, `wiki`, `snippet`, `runner`, `package` and `test`, each suffixed
`:bitbucket`.

Two notes on that list. `admin:*` is a third axis rather than a superset, per
gotcha 4 above. And a handful appear in the API vocabulary without being
obvious in the creation UI, `manage:org` among them.

## The counterintuitive one

**Publishing a build status needs only `read:repository:bitbucket`.**

Measured: a real status published with `201 Created` from a token whose
`x-oauth-scopes` were `write:pullrequest, read:pipeline, write:pipeline,
read:repository, read:pullrequest`. No `write:repository`, no admin. The
endpoint declares `x-accepted-oauth-scopes: repository`, which in Bitbucket's
older vocabulary is the read scope.

So `bb-cli signoff` has no permission barrier at all. The most basic developer
token can publish. This would have been guessed wrong: writing a build status
is cheaper than reading the merge checks that consume it.

## How to prove what a token has

Never guess, and do not probe endpoint by endpoint. Every response carries it:

```bash
bb-cli api repositories/:repo -i | grep -i oauth
```

```
x-oauth-scopes: read:pullrequest:bitbucket, write:pullrequest:bitbucket, read:pipeline:bitbucket, write:pipeline:bitbucket, read:repository:bitbucket
x-accepted-oauth-scopes: repository
```

- `x-oauth-scopes`: the token's own list, in the modern vocabulary.
- `x-accepted-oauth-scopes`: what *that endpoint* demands, in the legacy
  vocabulary (`repository`, `pullrequest:write`, `repository:admin`).
- `x-token-id`: changes on rotation, which is how you confirm the credentials
  file really took the new value.

A 403 is even more explicit, naming both sides in the modern vocabulary:

```json
{"error": {"detail": {"required": ["admin:repository:bitbucket"],
                      "granted":  ["read:pipeline:bitbucket", "..."]}}}
```

### The fallback, and why it is only a fallback

Before the headers were known, scopes were inferred from status codes: a
missing scope gives **403 "lack one or more required privilege scopes"**, while
an allowed call with no data gives 404 or 400. That still works when you have
no other signal, but it is inference and it was nearly wrong once.

Posting an empty body to the build-status endpoint returned **400 field
validation**, not 403, which suggested the token could already write. It was
suggestive, not conclusive: `PUT .../pullrequests/{id}` on the same token
returns 403 *before* validating the body, which proves the two checks can run in
either order. Only a real `201` settled it.

**Use the headers. Use status codes only when there are no headers to read.**

## The vocabularies do not match

Three different names for the same thing show up in three places, which is why
this trips people up:

| Where | Looks like |
|---|---|
| The token creation screen | `Read repositories`, `Write pull requests` |
| `x-oauth-scopes` | `read:repository:bitbucket`, `write:pullrequest:bitbucket` |
| `x-accepted-oauth-scopes` | `repository`, `pullrequest:write`, `repository:admin` |

The legacy `repository` (no suffix) is the **read** scope, which is the whole
reason the signoff finding above is surprising.
