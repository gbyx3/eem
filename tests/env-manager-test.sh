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

original_path=$PATH
em_set app PATH /tmp 0 >/dev/null 2>&1 && {
  printf 'FAIL: PATH is rejected\n' >&2
  ((failures++))
}
assert_eq "$PATH" "$original_path" 'rejected PATH remains unchanged'

for blocked_key in LD_PRELOAD PROMPT_COMMAND _EM_UI_ACTIVE; do
  if em_set app "$blocked_key" blocked 0 >/dev/null 2>&1; then
    printf 'FAIL: %s is rejected\n' "$blocked_key" >&2
    ((failures++))
  fi
done

unset OPENAI_API_KEY
em_set app OPENAI_API_KEY normal 0
assert_eq "$OPENAI_API_KEY" normal 'normal variable name remains allowed'
em_delete_key OPENAI_API_KEY

unset value
em_set app value global 0
assert_eq "${value-}" global 'variable matching former function local is global'
em_delete_key value

EM_TEST_REF_TARGET=unchanged
declare -n EM_TEST_REF=EM_TEST_REF_TARGET
if em_set app EM_TEST_REF changed 0 >/dev/null 2>&1; then
  printf 'FAIL: nameref is rejected\n' >&2
  ((failures++))
fi
assert_eq "$EM_TEST_REF_TARGET" unchanged 'nameref target remains unchanged'
unset -n EM_TEST_REF
unset EM_TEST_REF EM_TEST_REF_TARGET

control_app=$'unsafe\e[31m'
if em_set "$control_app" EM_TEST_CONTROL value 0 >/dev/null 2>&1; then
  printf 'FAIL: control characters in application name are rejected\n' >&2
  ((failures++))
fi

unset EM_TEST_DISPLAY
display_value=$'safe punctuation !@#$%^&*() \e[31mhidden\rtext'
em_set display EM_TEST_DISPLAY "$display_value" 0
display_listing=$(_em_list)
[[ $display_listing != *$'\e'* && $display_listing != *$'\r'* ]] || {
  printf 'FAIL: display output strips terminal controls\n' >&2
  ((failures++))
}
[[ $display_listing == *'safe punctuation !@#$%^&*() [31mhiddentext'* ]] || {
  printf 'FAIL: printable display characters are preserved\n' >&2
  ((failures++))
}
assert_eq "$EM_TEST_DISPLAY" "$display_value" 'display sanitization does not alter stored value'
em_delete_key EM_TEST_DISPLAY

_EM_UI_ACTIVE=0
_EM_UI_TRAPS=1
trap '_em_ui_interrupt' INT TERM
_em_ui_stop
assert_eq "$(trap -p INT)" '' 'UI stop removes its INT trap'
assert_eq "$(trap -p TERM)" '' 'UI stop removes its TERM trap'
assert_eq "$_EM_UI_TRAPS" 0 'UI stop clears trap ownership'

empty_app_output=$(_em_add_menu <<< '')
[[ $empty_app_output == *'Application name is required'* ]] || {
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
