# Security Policy

## Supported versions

A single active line: fixes land on `main`. `bb-cli upgrade` is a `git pull`,
so upgrade before reporting.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting: *Security* > *Report a vulnerability* on
https://github.com/jonasporto/bb-cli. It opens a confidential thread with the
maintainer.

Include what you can: the version (`bb-cli version`), your OS and bash version,
the command involved, and the smallest reproduction you have. **Never include a
real Atlassian API token, the contents of your credentials file, or an
unredacted response body.** You should get an acknowledgement within a week.

## What the tool touches

- Reads `BITBUCKET_USERNAME` and `BITBUCKET_API_TOKEN` from the environment, or
  from `~/.config/bb-cli/credentials` (mode `600` in a `700` directory) when the
  environment does not supply them. The token is sent only as HTTP basic auth to
  `https://api.bitbucket.org`.
- Runs `git remote get-url origin` to resolve `:repo` into `workspace/slug`, and
  `git rev-parse` / `git status` for `signoff`.
- At most every five hours, a detached `git fetch` in its own checkout, so it
  can tell you the tool is behind (the notice itself appears at most once a
  day). It talks to your git remote, never to a bb-cli server. Opt out entirely
  with `BB_CLI_NO_UPDATE_CHECK=1`.
- Writes only under `~/.config/bb-cli/`, plus the symlinks `install.sh` and
  `bb-cli skill install` create.

Things that follow from that design and are **not** vulnerabilities:

- `bb-cli api` sends any path you give it to Bitbucket with your credential
  attached. That is the feature. It is exactly as dangerous as `curl` with the
  same token, and no more.
- The credentials file is plain text, readable by your user, the same way
  `~/.netrc` and `~/.aws/credentials` are.
- `bb-cli status` prints which scopes the token holds, because a token whose
  permissions you cannot read is a token you cannot reason about. It never
  prints the token.

Things that **are** in scope: the token appearing in a command line, a log, an
error message or a process listing; command injection through a branch name, PR
title, repository slug or any other value that reaches a shell; a path that
escapes `~/.config/bb-cli` (`bb-cli docs` rejecting `../` is one such guard, and
a bypass of it is a bug); the credentials file or its directory being created
with permissions wider than `600`/`700`; and privilege issues in `install.sh`.
