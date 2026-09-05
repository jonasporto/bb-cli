#!/usr/bin/env bash
#
# Tests for `bb-cli upgrade` and the update notice.
#
# The load-bearing test here is the quiet one: the notice must never appear in
# output that something else is parsing. `bb-cli api ... -q .description` gets
# piped into scripts and jq, and `pr <n> -j` gets parsed as JSON. One unasked-for
# line corrupts both. It is on stderr, gated on a terminal, capped at once a day,
# and switchable off.
#
# The cache is driven directly rather than by letting a real fetch run, so these
# tests touch neither the network nor the real ~/.config/bb-cli.
#
# Run: tests/update_test.sh
set -u

# shellcheck source=tests/lib/fake_curl.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init

# Redirect the config dir so the real credentials and caches are never touched.
export HOME="$TMP/home"
mkdir -p "$HOME/.config/bb-cli"
CACHE="$HOME/.config/bb-cli/update-check"

REPO_DIR="$TMP/checkout"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin git@bitbucket.org:myworkspace/myrepo.git
cd "$REPO_DIR"

echo "update tests"

# --- the notice must never reach machine-readable output -------------------
# Pretend an update is waiting. Every command below runs with stdout and stderr
# captured, which is exactly the non-terminal case.

printf '%s\n%s\n%s\n' "$(date +%s)" "42" "main" > "$CACHE"

echo '{"description":"the body text","id":10}' > "$CURL_BODY"
run_bb api "repositories/:repo/pullrequests/10" -q .description
assert_eq "the body text" "$BB_OUT" \
    "api -q output is exactly the field, with no update notice attached"

run_bb pr 10 -j
if printf '%s' "$BB_OUT" | jq -e . > /dev/null 2>&1; then
    echo "  ok   - pr -j output still parses as JSON with an update pending"
    pass=$((pass + 1))
else
    echo "  FAIL - an update notice broke the JSON output"
    fail=$((fail + 1))
fi

run_bb status
assert_not_contains "bb-cli upgrade" "$BB_OUT" \
    "no notice when stderr is not a terminal (an agent capturing output)"

# --- the opt-out -----------------------------------------------------------

BB_CLI_NO_UPDATE_CHECK=1 run_bb status
assert_not_contains "commits behind" "$BB_OUT" "BB_CLI_NO_UPDATE_CHECK=1 silences it"

# --- the notice text itself ------------------------------------------------
# Exercised directly, since the terminal gate makes it unreachable from a test.

notice_text() {
    printf '%s\n%s\n%s\n' "$(date +%s)" "$1" "${2:-main}" > "$CACHE"
    HOME="$HOME" bash -c '
        CONFIG_DIR="$HOME/.config/bb-cli"
        UPDATE_CACHE="$CONFIG_DIR/update-check"
        '"$(sed -n '/^bb_update_notice_text()/,/^}/p' "$BBCLI")"'
        bb_update_notice_text
    '
}

assert_eq "bb-cli is 42 commits behind origin/main. Run: bb-cli upgrade" \
    "$(notice_text 42 main)" "the notice names the count, the branch and the fix"

assert_eq "bb-cli is 1 commit behind origin/main. Run: bb-cli upgrade" \
    "$(notice_text 1 main)" "one commit is singular, not '1 commits'"

assert_eq "" "$(notice_text 0 main)" "zero commits behind produces no notice at all"

assert_contains "origin/develop" "$(notice_text 3 develop)" \
    "the notice names the branch actually tracked, not a hardcoded main"

# A corrupt cache must be silent, not noisy or fatal.
printf 'garbage\nnot-a-number\n' > "$CACHE"
run_bb status
assert_eq "0" "$BB_RC" "a corrupt update cache does not break status"
assert_not_contains "commits behind" "$BB_OUT" "a corrupt cache produces no notice"

# --- upgrade ---------------------------------------------------------------
# A real checkout with a local bare origin, so the fetch inside `upgrade` and
# `_refresh-update-cache` actually runs without a network or a credential.
# Pointing these at the developer's own bb-cli checkout made them pass only on
# a machine that could reach GitHub, which is neither CI nor a contributor.

UPSTREAM="$TMP/upstream.git"
INSTALL="$TMP/install"
git init -q --bare "$UPSTREAM"
git init -q "$INSTALL"
# The branch name has to be pinned, not inherited: git defaults to `master`
# without init.defaultBranch, so a checkout created on a machine configured for
# `main` fetched a branch the bare repo did not have, and `upgrade` failed. That
# is a machine-dependent test, which is the thing this fixture exists to avoid.
git -C "$INSTALL" symbolic-ref HEAD refs/heads/main
mkdir -p "$INSTALL/bin"
cp "$BBCLI" "$INSTALL/bin/bb-cli"
chmod +x "$INSTALL/bin/bb-cli"
git -C "$INSTALL" -c user.email=t@t -c user.name=t add -A
git -C "$INSTALL" -c user.email=t@t -c user.name=t commit -qm "bb-cli"
git -C "$INSTALL" remote add origin "$UPSTREAM"
git -C "$INSTALL" push -q -u origin main
BBCLI_GIT="$INSTALL/bin/bb-cli"

run_bb_git() {
    set +e
    BB_OUT="$(HOME="$HOME" "$BBCLI_GIT" "$@" 2>&1)"
    BB_RC=$?
    set -e
}

run_bb_git upgrade --check
assert_eq "0" "$BB_RC" "upgrade --check exits 0"
assert_contains "Checkout:" "$BB_OUT" "it names the checkout it would pull"

run_bb upgrade --help
assert_eq "0" "$BB_RC" "upgrade --help exits 0"
assert_contains "BB_CLI_NO_UPDATE_CHECK" "$BB_OUT" "the help documents the opt-out"
assert_contains "no releases API" "$BB_OUT" \
    "the help records why a release feed was not used"

run_bb upgrade --nonsense
assert_eq "1" "$BB_RC" "an unknown flag on upgrade is rejected"

# Not a git checkout: this is a single-file install, not a broken one, so
# upgrade re-downloads the script instead of refusing. It used to exit 1 with
# "not a git checkout", which left that install with no way forward at all.
NOTGIT="$TMP/notgit"
mkdir -p "$NOTGIT/bin" "$NOTGIT/docs"
cp "$BBCLI" "$NOTGIT/bin/bb-cli"
set +e
NG_OUT="$(CURL_BODY="$BBCLI" "$NOTGIT/bin/bb-cli" upgrade 2>&1)"
NG_RC=$?
set -e
assert_eq "0" "$NG_RC" "upgrade in a non-git install takes the single-file path"
assert_contains "single file, no checkout" "$NG_OUT" "it names the kind of install"
assert_contains "Already on" "$NG_OUT" "and compares versions rather than refusing"

# A download it cannot verify must leave the working script alone.
set +e
NG_OUT="$("$NOTGIT/bin/bb-cli" upgrade 2>&1)"
NG_RC=$?
set -e
assert_eq "1" "$NG_RC" "an unverifiable download exits 1"
assert_contains "Nothing was changed" "$NG_OUT" "and changes nothing"

# --- the background refresh is a real subcommand ---------------------------

rm -f "$CACHE"
set +e
REFRESH_OUT="$("$BBCLI_GIT" _refresh-update-cache 2>&1)"
REFRESH_RC=$?
set -e
assert_eq "0" "$REFRESH_RC" "the refresh subcommand exits 0"
assert_eq "" "$REFRESH_OUT" "the refresh subcommand is silent (it runs detached)"


# --- a single-file install upgrades by re-downloading itself ---------------
# `git pull` has nothing to pull when bb-cli was copied onto PATH without a
# repository beside it, which is the commonest way to install one bash script.
# Refusing there would leave that install with no way forward.

SINGLE="$TMP/single"
mkdir -p "$SINGLE/bin"
sed 's/^BB_CLI_VERSION="[^"]*"/BB_CLI_VERSION="0.0.9"/' "$BBCLI" > "$SINGLE/bin/bb-cli"
chmod +x "$SINGLE/bin/bb-cli"

set +e
SG_OUT="$(CURL_BODY="$BBCLI" HOME="$TMP/single-home" "$SINGLE/bin/bb-cli" upgrade --check 2>&1)"
SG_RC=$?
set -e
assert_eq "0" "$SG_RC" "upgrade --check on a single-file install exits 0, not 'not a git checkout'"
assert_contains "single file, no checkout" "$SG_OUT" "it names the kind of install it found"
assert_contains "is available" "$SG_OUT" "and reports the newer version without applying it"
assert_contains "0.0.9" "$(grep -m1 '^BB_CLI_VERSION=' "$SINGLE/bin/bb-cli")" \
    "--check changed nothing on disk"

set +e
SG_OUT="$(CURL_BODY="$BBCLI" HOME="$TMP/single-home" "$SINGLE/bin/bb-cli" upgrade 2>&1)"
SG_RC=$?
set -e
assert_eq "0" "$SG_RC" "upgrade on a single-file install exits 0"
assert_contains "Updated 0.0.9" "$SG_OUT" "it reports the version it moved from"
assert_contains "no docs, man page or skill" "$SG_OUT" "and says what this install still lacks"
assert_contains "BB_CLI_VERSION=\"$("$BBCLI" version | awk '{print $2}')\"" \
    "$(grep -m1 '^BB_CLI_VERSION=' "$SINGLE/bin/bb-cli")" \
    "the script on disk was actually replaced"

# A symlinked install must update the file the link points at, not the link.
mkdir -p "$SINGLE/real" "$SINGLE/link"
sed 's/^BB_CLI_VERSION="[^"]*"/BB_CLI_VERSION="0.0.9"/' "$BBCLI" > "$SINGLE/real/bb-cli"
chmod +x "$SINGLE/real/bb-cli"
ln -sf "$SINGLE/real/bb-cli" "$SINGLE/link/bb-cli"
CURL_BODY="$BBCLI" HOME="$TMP/single-home" "$SINGLE/link/bb-cli" upgrade > /dev/null 2>&1 || true
[[ -L "$SINGLE/link/bb-cli" ]] && { echo "  ok   - the symlink is still a symlink after an upgrade"; pass=$((pass + 1)); } \
                              || { echo "  FAIL - the upgrade replaced the symlink with a file"; fail=$((fail + 1)); }
# Read the version rather than hardcoding it: a release bump must not be a
# test failure.
assert_contains "BB_CLI_VERSION=\"$("$BBCLI" version | awk '{print $2}')\"" \
    "$(grep -m1 '^BB_CLI_VERSION=' "$SINGLE/real/bb-cli")" \
    "and the file it points at is the one that got updated"

# A truncated or wrong download must never overwrite a working tool.
sed 's/^BB_CLI_VERSION="[^"]*"/BB_CLI_VERSION="0.0.9"/' "$BBCLI" > "$SINGLE/bin/bb-cli"
chmod +x "$SINGLE/bin/bb-cli"
echo 'this is not bb-cli' > "$TMP/garbage"
set +e
SG_OUT="$(CURL_BODY="$TMP/garbage" HOME="$TMP/single-home" "$SINGLE/bin/bb-cli" upgrade 2>&1)"
SG_RC=$?
set -e
assert_eq "1" "$SG_RC" "a download that is not bb-cli exits 1"
assert_contains "Nothing was changed" "$SG_OUT" "and says so"
assert_contains "0.0.9" "$(grep -m1 '^BB_CLI_VERSION=' "$SINGLE/bin/bb-cli")" \
    "the working script is left intact"

# --- docs/man/skill name the single-file install rather than "partial" ------

set +e
SG_OUT="$(HOME="$TMP/single-home" "$SINGLE/bin/bb-cli" docs 2>&1)"
SG_RC=$?
set -e
assert_eq "1" "$SG_RC" "docs on a single-file install exits 1"
assert_contains "single-file install" "$SG_OUT" "it names the situation"
assert_contains "Every command still works" "$SG_OUT" "and does not imply the tool is broken"
assert_contains "install.sh | bash" "$SG_OUT" "and gives the one line that fixes it"

summary
