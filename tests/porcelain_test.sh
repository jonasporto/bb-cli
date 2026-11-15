#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/fake_curl.sh"
harness_init
mkdir "$TMP/checkout"
git -C "$TMP/checkout" init -q -b feature
git -C "$TMP/checkout" remote add origin git@bitbucket.org:example/project.git
cd "$TMP/checkout"
cat > "$CURL_BODY" <<'JSON'
{"id":42,"title":"Example","state":"OPEN","draft":true,"description":"Body","author":{"display_name":"Author"},"source":{"branch":{"name":"feature"}},"destination":{"branch":{"name":"main"}},"created_on":"2026-01-01T00:00:00Z","updated_on":"2026-01-01T00:00:00Z","links":{"html":{"href":"https://bitbucket.org/example/project/pull-requests/42"}},"values":[],"participants":[]}
JSON
printf 'First line with "quotes"  \nSecond line\n' > "$TMP/body.md"
run_bb pr create --title 'New "title"' --base main --body-file "$TMP/body.md" --draft
assert_eq 0 "$BB_RC" 'create succeeds'
assert_contains '-X POST' "$CURL_CALLS" 'create sends POST'
assert_contains '/repositories/example/project/pullrequests' "$CURL_CALLS" 'create targets selected repository'
assert_eq true "$(printf '%s' "$CURL_BODIES" | jq -r .draft)" 'draft is a boolean'
assert_eq feature "$(printf '%s' "$CURL_BODIES" | jq -r .source.branch.name)" 'head defaults to current branch'
assert_eq main "$(printf '%s' "$CURL_BODIES" | jq -r .destination.branch.name)" 'base is explicit'
assert_eq 'New "title"' "$(printf '%s' "$CURL_BODIES" | jq -r .title)" 'title escaping survives JSON'
assert_eq "$(cat "$TMP/body.md")" "$(printf '%s' "$CURL_BODIES" | jq -r .description)" 'multiline description and spaces survive JSON'
run_bb pr create --title Test --base main --head another --body-file - <<< 'stdin body'
assert_eq another "$(printf '%s' "$CURL_BODIES" | jq -r .source.branch.name)" 'explicit head used'
assert_eq 'stdin body' "$(printf '%s' "$CURL_BODIES" | jq -r .description)" 'stdin body supported'
assert_eq false "$(printf '%s' "$CURL_BODIES" | jq -r .draft)" 'default is ready'
run_bb pr create --title Test
assert_eq 1 "$BB_RC" 'missing base refused'
assert_eq '' "$CURL_CALLS" 'missing base sends nothing'
run_bb pr create --title Test --base main --body-file "$TMP/no-file"
assert_eq 1 "$BB_RC" 'unreadable body refused'
assert_eq '' "$CURL_CALLS" 'unreadable body sends nothing'
run_bb pr create --title Test --base
assert_eq 1 "$BB_RC" 'missing flag value refused'
run_bb pr create --title Test --base main --dry-run
assert_eq 0 "$BB_RC" 'dry run succeeds'
assert_eq '' "$CURL_CALLS" 'dry run writes nothing'
CURL_STATUS=403
run_bb pr create --title Test --base main
assert_eq 1 "$BB_RC" 'create HTTP denial propagates'
CURL_STATUS=200
run_bb pr 42
assert_contains DRAFT "$BB_OUT" 'draft visible in detail'
jq '{values:[.]}' "$CURL_BODY" > "$TMP/list.json"
cp "$TMP/list.json" "$CURL_BODY"
run_bb pr list
assert_contains '[DRAFT]' "$BB_OUT" 'draft visible in list'
cat > "$CURL_BODY" <<'JSON'
{"values":[{"status":"removed","old":{"path":"old.txt"},"new":null,"lines_added":0,"lines_removed":7},{"status":"added","old":null,"new":{"path":"new.txt"},"lines_added":4,"lines_removed":0}]}
JSON
run_bb pr diffstat 42
assert_eq 0 "$BB_RC" 'diffstat succeeds'
assert_contains '/pullrequests/42/diffstat' "$CURL_CALLS" 'diffstat uses correct endpoint'
assert_contains 'old.txt' "$BB_OUT" 'removed path is visible'
assert_contains 'new.txt' "$BB_OUT" 'new path is visible'
assert_not_contains '-X POST' "$CURL_CALLS" 'diffstat is read only'
run_bb pr diffstat 42 --json
assert_eq 2 "$(printf '%s' "$BB_OUT" | jq '.values | length')" 'diffstat JSON keeps values'
cat > "$CURL_BODY" <<'JSON'
{"values":[{"build_number":1,"target":{"ref_name":"main","selector":{"type":"custom","pattern":"Unit specs"}}},{"build_number":2,"target":{"ref_name":"main","selector":{"type":"custom","pattern":"Deploy"}}},{"build_number":3,"target":{"ref_name":"main","selector":{"type":"branches","pattern":"Unit specs"}}}]}
JSON
run_bb pipeline list --custom 'Unit specs' --json
assert_eq 0 "$BB_RC" 'custom list succeeds'
assert_eq '[1]' "$(printf '%s' "$BB_OUT" | jq -c '[.values[].build_number]')" 'custom filter requires type and exact selector name'
run_bb pipeline list --custom 'Unit specs'
assert_contains 'custom / Unit specs' "$BB_OUT" 'selector name appears in list'
run_bb frobnicate
assert_eq 1 "$BB_RC" 'unknown command fails'
assert_contains 'bb-cli api --help' "$BB_OUT" 'unknown command advertises API hatch'
summary
