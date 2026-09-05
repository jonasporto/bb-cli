# Setup: install bb-cli and give it a credential

Read this first on a new machine. Ten minutes, three steps, and one thing that
trips everybody up (`write` does not imply `read`).

## What it needs

| Tool | Why | Almost certainly already there |
|---|---|---|
| `bash` 3.2+ | the CLI is one bash script | macOS ships 3.2, Linux ships 5.x |
| `curl` | every API call | yes |
| `jq` | parses every response | `brew install jq` / `apt install jq` |
| `git` | resolves workspace/repo from the remote | yes |

`bb-cli status` tells you if any of them is missing.

## Install

One line, nothing to clone first:

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/install.sh | bash
```

The script notices it is running with no repository around it and clones one
into `~/.bb-cli` before installing from there, or reuses a checkout you
already have, so re-running it never leaves a second copy behind.
`BB_CLI_HOME` picks a different directory:

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/install.sh \
  | BB_CLI_HOME=~/src/bb-cli bash
```

The same thing by hand, if you would rather see each step:

```bash
git clone https://github.com/jonasporto/bb-cli.git ~/.bb-cli
~/.bb-cli/install.sh
```

### Just the script

bb-cli is one bash file, so dropping it on your PATH is a valid install:

```bash
curl -fsSL https://raw.githubusercontent.com/jonasporto/bb-cli/main/bin/bb-cli \
  -o ~/.local/bin/bb-cli && chmod +x ~/.local/bin/bb-cli
```

Every command works, `bb-cli upgrade` included: with no repository to pull, it
replaces the script from that same URL, verifying the download parses as bash
and is actually bb-cli before overwriting anything. A symlinked install updates
the file the link points at, not the link.

What a single file cannot carry is the material that ships beside it: the five
`bb-cli docs` topics, the man page, and the agent skill. Those three commands
report the situation and give the one line that installs the full set. Nothing
else changes.

Pick the checkout if you want documentation offline or an agent that knows the
tool; pick the single file if you want one binary and nothing else.

`install.sh` symlinks `bb-cli` into `~/.local/bin` and the man page into
`~/.local/share/man/man1`, then tells you if either is outside your `PATH` or
`MANPATH`. Nothing is copied, so `git pull` upgrades the installed tool.

To put it somewhere else:

```bash
./install.sh --prefix /usr/local     # bin/ and share/man/man1/ under a prefix
./install.sh --bin-dir ~/bin         # just the executable
./install.sh --uninstall
```

Or skip it entirely. The script has no build step, so a symlink of your own
works as well:

```bash
ln -s ~/.bb-cli/bin/bb-cli ~/.local/bin/bb-cli
```

## Create the token

`id.atlassian.com` → Security → API tokens → **Create API token with scopes**.

**Pick the Bitbucket app.** The creation screen scopes a token to exactly one
product, and each entry says so: "API token can only access Bitbucket APIs". A
Bitbucket token cannot reach Jira, and the reverse holds too.

Check exactly these five:

```
read:repository:bitbucket     write:pipeline:bitbucket
read:pullrequest:bitbucket    write:pullrequest:bitbucket
read:pipeline:bitbucket
```

Two traps before you click:

- **`write` does not imply `read`.** Bitbucket scopes are isolated, so both
  halves of each pair have to be checked.
- **Scopes are fixed at creation.** A token cannot gain one later. Getting it
  wrong means creating a new token, not editing this one.

Why those five and not the other forty, including which ones look necessary and
are not: `bb-cli docs scopes`.

## Store it

```bash
bb-cli login     # interactive; writes the file for you
```

In a script, a CI job, or anywhere an agent is driving, there is no terminal to
prompt at. Pass the token on stdin instead:

```bash
printf %s "$TOKEN" | bb-cli login --with-token --email you@example.com
bb-cli login --with-token --email you@example.com < token.txt
```

Either form verifies the credential against the API before writing anything. A
bare `bb-cli login` with no terminal exits 1 and points at these, rather than
consuming an invisible prompt.

Or write it by hand. The file is `~/.config/bb-cli/credentials`, a shell file
the script sources:

```
BITBUCKET_USERNAME=<your atlassian email>
BITBUCKET_API_TOKEN=<the token>
```

`bb-cli login` sets `600` on the file and `700` on the directory. Keep it that
way, and keep the path outside any git repository so the token cannot be
committed by accident.

Three loading details worth knowing:

- **The environment wins over the file.** With `BITBUCKET_USERNAME` and
  `BITBUCKET_API_TOKEN` exported, the file is never read. That is how to try a
  new token without touching the file, and how CI supplies one:

  ```bash
  BITBUCKET_API_TOKEN=xxx bb-cli pr 10
  ```

- `BITBUCKET_APP_PASSWORD` is still accepted as a fallback name, from before
  Atlassian removed app passwords. That removal was real and is finished:
  brownouts began 2026-06-09 and removal was permanent from **2026-07-28**
  (Atlassian CHANGE-3222). If something still holds an app password, it is
  already broken; create an API token with scopes instead.
- **Do not leave a commented-out old token in the file.** One sat in a file for
  months and cost a round of debugging: it 401s on everything, so it is not a
  backup, it is a trap for whoever uncomments it.

## Confirm it works

```bash
bb-cli status
```

It exits non-zero when there is no usable credential, so it works in a script:

```bash
bb-cli status > /dev/null 2>&1 || bb-cli login
```

Then, from inside a Bitbucket checkout:

```bash
bb-cli pr --limit 2
bb-cli pipeline --limit 2
```

Outside a checkout, name the repository instead:

```bash
bb-cli pipeline --repo myworkspace/myrepo --limit 1
```

The definitive check on what the token can do is the response headers, not a
list of things you tried:

```bash
bb-cli api repositories/:repo -i | grep -i oauth
```

```
x-oauth-scopes: read:pullrequest:bitbucket, write:pullrequest:bitbucket, read:pipeline:bitbucket, write:pipeline:bitbucket, read:repository:bitbucket
x-accepted-oauth-scopes: repository
```

`x-oauth-scopes` is what your token has. `x-accepted-oauth-scopes` is what that
endpoint demands. See `bb-cli docs scopes` for how to read the older vocabulary
it answers in.

## Rotating

1. Create the new token with the same five scopes.
2. Replace `BITBUCKET_API_TOKEN=` in the credentials file.
3. `bb-cli api repositories/:repo -i | grep -i 'x-token-id\|x-oauth-scopes'`:
   `x-token-id` must have changed, which proves the file took the new value.
4. Read paths: `status`, `repo`, `pr --limit 2`, `pr <n>`, `pipeline --limit 2`.
5. One real write, the cheapest being a pull request title:
   `bb-cli api repositories/:repo/pullrequests/<n> -X PUT --input body.json`.
   A 403 here means `write:pullrequest` is missing.
6. **Revoke the old token only after both the read and the write check pass.**
   Revoking first turns one failed verification into two problems at once.

## When something fails

| Symptom | Cause |
|---|---|
| `401` on everything | wrong token, or the wrong email as username |
| `403 lack one or more required privilege scopes` | a missing scope, see `bb-cli docs scopes` |
| `Not in a git repository or no origin remote` | run inside a checkout, or pass `--repo ws/slug` |
| `jq: command not found` | install jq |
| `400 Unexpected response body` on a pipeline step | the UUID needs its braces percent-encoded; `bb-cli` does this for you, raw curl does not |
