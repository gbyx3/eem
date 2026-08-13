#!/usr/bin/env bash

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
failures=0

assert_eq() {
  if [[ $1 != "$2" ]]; then
    printf 'FAIL: %s (expected %q, got %q)\n' "$3" "$2" "$1" >&2
    ((failures++))
  fi
}

# Exit the automatic menu immediately, then exercise the public functions.
source "$ROOT/env-manager.sh" <<< 'E'

assert_eq "$(_em_app_prefix 'Open Code')" 'EM_OPEN_CODE_' 'application prefix is normalized'
assert_eq "$(_em_app_prefix 'my---app')" 'EM_MY_APP_' 'repeated separators are collapsed'
assert_eq "$(_em_app_prefix '!!!')" 'EM_APP_' 'empty normalized application uses fallback'

empty_app_output=$(_em_add_menu <<< '')
[[ $empty_app_output == *'Application name cannot be empty.'* ]] || {
  printf 'FAIL: empty application returns from add menu\n' >&2
  ((failures++))
}

unset EM_TEST_NEW
em_set opencode EM_TEST_NEW 'new value' 0
assert_eq "$EM_TEST_NEW" 'new value' 'new variable is assigned'
export -p | command grep -q 'EM_TEST_NEW' || { printf 'FAIL: new variable is exported\n' >&2; ((failures++)); }
em_delete_key EM_TEST_NEW
[[ ! -v EM_TEST_NEW ]] || { printf 'FAIL: new variable is unset on deletion\n' >&2; ((failures++)); }

EM_TEST_LOCAL='original local'
export -n EM_TEST_LOCAL
em_set opencode EM_TEST_LOCAL 'temporary' 0
em_delete_key EM_TEST_LOCAL
assert_eq "$EM_TEST_LOCAL" 'original local' 'non-exported value is restored'
export -p | command grep -q 'EM_TEST_LOCAL' && { printf 'FAIL: non-exported state is restored\n' >&2; ((failures++)); }

export EM_TEST_EXPORTED='original exported'
em_set github EM_TEST_EXPORTED 'temporary secret' 1
em_set github EM_TEST_SECOND 'second' 0
listing=$(_em_list)
[[ $listing == *'[github]'* && $listing == *'EM_TEST_EXPORTED=********'* ]] || {
  printf 'FAIL: listing groups and masks secrets\n' >&2
  ((failures++))
}
[[ $listing != *'temporary secret'* ]] || { printf 'FAIL: listing leaks secret\n' >&2; ((failures++)); }

em_delete_all
assert_eq "$?" '0' 'delete all succeeds with historical ordering entries'
assert_eq "$EM_TEST_EXPORTED" 'original exported' 'exported value is restored by delete all'
export -p | command grep -q 'EM_TEST_EXPORTED' || { printf 'FAIL: exported state is restored\n' >&2; ((failures++)); }
[[ ! -v EM_TEST_SECOND ]] || { printf 'FAIL: delete all unsets new variable\n' >&2; ((failures++)); }
assert_eq "$(_em_list)" 'No variables are currently managed.' 'metadata is cleared'

unset EM_TEST_LOCAL EM_TEST_EXPORTED

if ((failures)); then
  printf '%d test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf 'All tests passed.\n'
