#!/usr/bin/env bash
#
# Tests for the parts of the CLI a newcomer (or an agent) hits first: version,
# help, the bundled docs, the skill, and the -j flag on `pr <n>` that used to be
# parsed and then silently dropped.
#
# Run: tests/cli_surface_test.sh
set -u

# shellcheck source=tests/lib/fake_curl.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_DIR="$TMP/checkout"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin git@bitbucket.org:myworkspace/myrepo.git
cd "$REPO_DIR"

echo "cli surface tests"

# --- version ---------------------------------------------------------------
# Sessions typed `bb-cli --version` and got "Unknown command". A tool nobody can
# ask the version of does not look installed.

run_bb --version
assert_eq "0" "$BB_RC" "--version exits 0"
assert_contains "bb-cli" "$BB_OUT" "--version names the tool"

run_bb version
assert_eq "0" "$BB_RC" "the 'version' subcommand works too"

run_bb -v
assert_eq "0" "$BB_RC" "-v is accepted"

# The version string lives in two files that cannot read each other: the script
# and the man page's .TH line. Nothing keeps them in step, so this does.
DECLARED_VERSION="$(grep -m1 '^BB_CLI_VERSION=' "$BBCLI" | cut -d'"' -f2)"
MAN_VERSION="$(head -1 "${REPO_ROOT}/man/bb-cli.1" | grep -oE 'bb-cli [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')"
assert_eq "$DECLARED_VERSION" "$MAN_VERSION" \
    "man/bb-cli.1 declares the same version as bin/bb-cli"
assert_contains "$DECLARED_VERSION" "$BB_OUT" "the reported version is the declared one"

# --- status judges by the scopes header, not the status code ----------------
# The old check called an account endpoint and reported "Invalid credentials"
# on anything but 200. GET /user answers 403 for a token without read:account -
# which the docs tell you to leave off on purpose - and the account-wide
# listings answer 410 Gone for API tokens entirely. So a perfectly good token
# was told it was invalid, on the very first command a new user runs.
# Every authenticated response carries x-oauth-scopes; that is the real signal.

CURL_STATUS=403 ; export CURL_STATUS
echo '{"type":"error","error":{"message":"forbidden"}}' > "$CURL_BODY"
run_bb status
assert_eq "0" "$BB_RC" "a 403 on the probe endpoint is not a credential failure"
assert_contains "Authenticated" "$BB_OUT" "the token is reported as valid"
assert_contains "read:repository:bitbucket" "$BB_OUT" "the granted scopes are listed"

CURL_STATUS=401 ; export CURL_STATUS
run_bb status
assert_eq "1" "$BB_RC" "a 401 IS a credential failure"
assert_contains "Invalid credentials" "$BB_OUT" "a 401 says the credentials are wrong"
assert_contains "bb-cli login" "$BB_OUT" "and says how to fix it"

CURL_STATUS=200 ; export CURL_STATUS
echo '{"full_name":"myworkspace/myrepo"}' > "$CURL_BODY"
run_bb status
assert_eq "0" "$BB_RC" "a 200 is authenticated"
assert_contains "myworkspace/myrepo" "$BB_OUT" "it names what it verified against"

# The fake curl grants only two of the five scopes, so the gap must be named.
assert_contains "Missing" "$BB_OUT" "missing scopes are called out"
assert_contains "write:pullrequest:bitbucket" "$BB_OUT" "the missing scope is named"

echo '{"ok":true}' > "$CURL_BODY"

# --- help lists everything -------------------------------------------------

run_bb help
for cmd in pr pipeline branch repo signoff api docs man skill; do
    assert_contains "$cmd" "$BB_OUT" "help lists '${cmd}'"
done

run_bb help api
assert_contains "Usage: bb-cli api" "$BB_OUT" "help api reaches the api help"

run_bb help signoff
assert_contains "Usage: bb-cli signoff" "$BB_OUT" "help signoff reaches the signoff help"

# --- pr -j is honoured on the show path ------------------------------------
# The bug: cmd_pr parsed -j, then called cmd_pr_show without it, so `pr <n> -j`
# printed the formatted view. Reading a PR body was the commonest reason a
# session dropped to curl.

cat > "$CURL_BODY" <<'JSON'
{"id":10,"title":"A pull request","description":"the body text","state":"OPEN",
 "author":{"display_name":"Someone"},
 "source":{"branch":{"name":"feature"}},"destination":{"branch":{"name":"master"}},
 "created_on":"2026-08-01T10:00:00.000Z","updated_on":"2026-08-02T10:00:00.000Z",
 "links":{"html":{"href":"https://bitbucket.org/x/y/pull-requests/10"}},
 "participants":[],"values":[]}
JSON

run_bb pr 10 -j
assert_eq "0" "$BB_RC" "pr <n> -j exits 0"
assert_contains '"description": "the body text"' "$BB_OUT" \
    "pr <n> -j returns JSON including the description"
assert_not_contains "Reviewers" "$BB_OUT" "pr <n> -j does not print the formatted view"

run_bb pr 10 --json
assert_contains '"id": 10' "$BB_OUT" "--json is equivalent to -j"

run_bb pr 10
assert_contains "the body text" "$BB_OUT" \
    "the formatted view now prints the description too"
assert_contains "Description" "$BB_OUT" "the description has its own section"

# --- docs ship with the tool -----------------------------------------------

run_bb docs
assert_eq "0" "$BB_RC" "bb-cli docs lists the topics"
for topic in setup scopes api pipelines signoff; do
    assert_contains "$topic" "$BB_OUT" "docs lists the '${topic}' topic"
    [[ -f "${REPO_ROOT}/docs/${topic}.md" ]] \
        && { echo "  ok   - docs/${topic}.md exists"; pass=$((pass + 1)); } \
        || { echo "  FAIL - docs/${topic}.md is missing"; fail=$((fail + 1)); }
done

run_bb docs scopes
assert_eq "0" "$BB_RC" "bb-cli docs scopes prints the doc"
assert_contains "read:repository:bitbucket" "$BB_OUT" "the scopes doc names the scopes"

run_bb docs no-such-topic
assert_eq "1" "$BB_RC" "an unknown topic is an error"
assert_contains "no doc named" "$BB_OUT" "the error names the missing topic"

# Every error path that points a reader at a doc must point at one that exists.
run_bb docs signoff
assert_contains "admin:repository" "$BB_OUT" "the signoff doc covers the merge-check limit"

# --- the man page is real roff ---------------------------------------------

if [[ -f "${REPO_ROOT}/man/bb-cli.1" ]]; then
    echo "  ok   - man/bb-cli.1 exists"; pass=$((pass + 1))
    if head -20 "${REPO_ROOT}/man/bb-cli.1" | grep -q '^\.TH'; then
        echo "  ok   - man page has a .TH header"; pass=$((pass + 1))
    else
        echo "  FAIL - man page has no .TH header"; fail=$((fail + 1))
    fi
    if grep -q 'signoff' "${REPO_ROOT}/man/bb-cli.1"; then
        echo "  ok   - man page documents signoff"; pass=$((pass + 1))
    else
        echo "  FAIL - man page does not mention signoff"; fail=$((fail + 1))
    fi
else
    echo "  FAIL - man/bb-cli.1 is missing"; fail=$((fail + 1))
fi

# --- the skill installs where it is asked to -------------------------------

run_bb skill path
assert_contains "SKILL.md" "$BB_OUT" "skill path points at SKILL.md"

run_bb skill print
assert_contains "bb-cli" "$BB_OUT" "skill print writes the skill to stdout"
assert_contains "description:" "$BB_OUT" "the skill has the frontmatter Claude Code reads"

run_bb skill install --dir "$TMP/skills"
assert_eq "0" "$BB_RC" "skill install succeeds"
[[ -f "$TMP/skills/bb-cli/SKILL.md" ]] \
    && { echo "  ok   - the skill landed in the target directory"; pass=$((pass + 1)); } \
    || { echo "  FAIL - the skill did not land"; fail=$((fail + 1)); }

# Linked, not copied. A copy has no update path - this command has no `update`
# subcommand, unlike `npx skills` - so it would go stale silently after a git
# pull. A link cannot.
[[ -L "$TMP/skills/bb-cli" ]] \
    && { echo "  ok   - the skill is a symlink, so git pull updates it"; pass=$((pass + 1)); } \
    || { echo "  FAIL - the skill was copied, and will go stale silently"; fail=$((fail + 1)); }
assert_contains "linked at" "$BB_OUT" "the output says it linked rather than copied"
assert_contains "npx skills add" "$BB_OUT" "it points at the fuller option"

run_bb skill install --dir "$TMP/skills"
assert_eq "1" "$BB_RC" "a second install refuses rather than clobbering"
assert_contains "--force" "$BB_OUT" "the refusal says how to overwrite"

run_bb skill install --dir "$TMP/skills" --force
assert_eq "0" "$BB_RC" "--force reinstalls"

run_bb skill install --dir "$TMP/copied" --copy
assert_eq "0" "$BB_RC" "--copy succeeds"
[[ -L "$TMP/copied/bb-cli" ]] \
    && { echo "  FAIL - --copy still produced a symlink"; fail=$((fail + 1)); } \
    || { echo "  ok   - --copy produces a real directory"; pass=$((pass + 1)); }
[[ -f "$TMP/copied/bb-cli/SKILL.md" ]] \
    && { echo "  ok   - the copy contains the skill"; pass=$((pass + 1)); } \
    || { echo "  FAIL - the copy is empty"; fail=$((fail + 1)); }
assert_contains "does not track" "$BB_OUT" "--copy warns that it will go stale"

run_bb skill --help
assert_contains "NOT equivalent" "$BB_OUT" "the help does not claim parity with npx skills"

# --- installed-by-symlink must still find its own files ---------------------
# install.sh symlinks bin/bb-cli onto PATH. If SCRIPT_DIR is taken from the link
# rather than its target, docs/, man/ and skills/ all resolve to the wrong
# directory and three commands break only for people who installed properly.

mkdir -p "$TMP/fakebin"
ln -sf "$BBCLI" "$TMP/fakebin/bb-cli"
set +e
LINKED_OUT="$("$TMP/fakebin/bb-cli" docs 2>&1)"
LINKED_RC=$?
set -e
assert_eq "0" "$LINKED_RC" "docs works when bb-cli is reached through a symlink"
assert_contains "signoff" "$LINKED_OUT" "the symlinked binary finds the real docs/"

set +e
LINKED_SKILL="$("$TMP/fakebin/bb-cli" skill path 2>&1)"
set -e
assert_contains "skills/bb-cli/SKILL.md" "$LINKED_SKILL" \
    "the symlinked binary finds the real skills/"

# --- unknown commands still fail loudly ------------------------------------

run_bb nonsense
assert_eq "1" "$BB_RC" "an unknown command exits 1"
assert_contains "Unknown command" "$BB_OUT" "an unknown command says so"


# --- a machine without jq gets a sentence, not a bash error ----------------
# jq is the one dependency a fresh machine usually lacks. Reaching the API
# without it used to die inside a pipeline with "jq: command not found" and a
# line number from a 3,900-line script.

NOJQ="$TMP/nojq-bin"
mkdir -p "$NOJQ"
for t in bash sh git curl sed grep awk cat ls date mktemp rm mkdir chmod stat tr cut head tail sort uname printf basename dirname readlink env; do
    p="$(command -v "$t" 2> /dev/null)" && ln -sf "$p" "$NOJQ/$t"
done

run_nojq() {
    set +e
    BB_OUT="$(PATH="$NOJQ" HOME="$TMP/nojq-home" "$BBCLI" "$@" 2>&1)"
    BB_RC=$?
    set -e
}

run_nojq pr
assert_eq "1" "$BB_RC" "an API command without jq exits 1"
assert_contains "needs jq" "$BB_OUT" "it names the missing dependency"
assert_not_contains "command not found" "$BB_OUT" "and not a raw shell error"
assert_not_contains "line " "$BB_OUT" "nor a line number from inside the script"

# docs/setup.md tells the reader that `status` reports a missing dependency.
run_nojq status
assert_contains "Missing:" "$BB_OUT" "status reports the missing dependency, as the docs promise"
assert_contains "jq" "$BB_OUT" "and names it"
assert_not_contains "Not authenticated" "$BB_OUT" \
    "and does not blame the token for a missing package"

# The documentation surface is where you go to find out what to install, so it
# has to work on the machine that has nothing installed.
for cmd in version docs; do
    run_nojq "$cmd"
    assert_eq "0" "$BB_RC" "bb-cli $cmd still works without jq"
done

# `man` needs a renderer, which a slim container does not have. `cat` on the
# page used to dump roff source (".TH BB\-CLI 1 ...") at the reader, which is
# worse than saying it cannot be rendered.
run_nojq man
assert_eq "1" "$BB_RC" "man with no man(1) and no groff exits 1"
assert_not_contains ".TH BB" "$BB_OUT" "it does not dump roff source at the reader"
assert_contains "cannot be rendered" "$BB_OUT" "it says why"
assert_contains "bb-cli docs" "$BB_OUT" "and names the same material in a readable form"
run_nojq docs setup
assert_eq "0" "$BB_RC" "bb-cli docs setup still works without jq"
assert_contains "jq" "$BB_OUT" "and it is the page that says jq is needed"


# --- status exits non-zero when there is no credential ---------------------
# `gh auth status` does, and it is what makes `bb-cli status || bb-cli login`
# and a CI gate work. It used to exit 0 while printing "Not authenticated".

set +e
BB_OUT="$(env -u BITBUCKET_USERNAME -u BITBUCKET_API_TOKEN -u BITBUCKET_APP_PASSWORD \
    HOME="$TMP/no-creds-home" "$BBCLI" status 2>&1)"
BB_RC=$?
set -e
assert_eq "1" "$BB_RC" "status with no credential exits 1, as gh auth status does"
assert_contains "Not authenticated" "$BB_OUT" "and still says so in words"
assert_contains "bb-cli login" "$BB_OUT" "and names the fix"

summary
