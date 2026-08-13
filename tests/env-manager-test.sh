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

for blocked_key in \
  LD_PRELOAD PROMPT_COMMAND _EM_UI_ACTIVE \
  GCONV_PATH GLIBC_TUNABLES LOCPATH NLSPATH BASH_LOADABLES_PATH \
  LANG LC_ALL LC_CTYPE LC_MESSAGES COLUMNS LINES; do
  if em_set app "$blocked_key" blocked 0 >/dev/null 2>&1; then
    printf 'FAIL: %s is rejected\n' "$blocked_key" >&2
    ((failures++))
  fi
done

unset OPENAI_API_KEY
em_set app OPENAI_API_KEY normal 0
assert_eq "$OPENAI_API_KEY" normal 'normal variable name remains allowed'
em_delete_key OPENAI_API_KEY

unset email EM_APP_PATH
em_set app email allowed 0
em_set app EM_APP_PATH allowed 0
assert_eq "$email" allowed 'email remains allowed'
assert_eq "$EM_APP_PATH" allowed 'prefixed critical name remains allowed'
em_delete_key email
em_delete_key EM_APP_PATH

unset value
em_set app value global 0
assert_eq "${value-}" global 'variable matching former function local is global'
em_delete_key value

unset app
_em_add_menu >/dev/null <<'EOF'
scope-test
1
app
n
interactive
n
EOF
assert_eq "${app-}" interactive 'interactive menu does not shadow key named app'
em_delete_key app
[[ ! -v app ]] || {
  printf 'FAIL: interactive key named app restores to unset\n' >&2
  ((failures++))
}

EM_TEST_REF_TARGET=unchanged
declare -n EM_TEST_REF=EM_TEST_REF_TARGET
if em_set app EM_TEST_REF changed 0 >/dev/null 2>&1; then
  printf 'FAIL: nameref is rejected\n' >&2
  ((failures++))
fi
assert_eq "$EM_TEST_REF_TARGET" unchanged 'nameref target remains unchanged'
unset -n EM_TEST_REF
unset EM_TEST_REF EM_TEST_REF_TARGET

unset EM_TEST_RECHECK
em_set app EM_TEST_RECHECK scalar 0
unset EM_TEST_RECHECK
EM_TEST_RECHECK_TARGET=unchanged
declare -n EM_TEST_RECHECK=EM_TEST_RECHECK_TARGET
if em_set app EM_TEST_RECHECK changed 0 >/dev/null 2>&1; then
  printf 'FAIL: nameref is rechecked on update\n' >&2
  ((failures++))
fi
assert_eq "$EM_TEST_RECHECK_TARGET" unchanged 'update does not write through a nameref'
if em_delete_key EM_TEST_RECHECK >/dev/null 2>&1; then
  printf 'FAIL: restore refuses a replacement nameref\n' >&2
  ((failures++))
fi
assert_eq "$EM_TEST_RECHECK_TARGET" unchanged 'restore does not write through a nameref'
unset -n EM_TEST_RECHECK
unset EM_TEST_RECHECK
em_delete_key EM_TEST_RECHECK
[[ ! -v EM_TEST_RECHECK ]] || {
  printf 'FAIL: managed variable can be restored after removing nameref\n' >&2
  ((failures++))
}
unset EM_TEST_RECHECK_TARGET

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
_EM_UI_INTERRUPTED=1
_EM_TTY_STATE='test-state'
original_em_stty=$(declare -f _em_stty)
EM_TEST_STTY_ARG=''
_em_stty() { EM_TEST_STTY_ARG=${1-}; }
trap '_em_ui_interrupt' INT TERM
_em_ui_stop
eval "$original_em_stty"
assert_eq "$(trap -p INT)" '' 'UI stop removes its INT trap'
assert_eq "$(trap -p TERM)" '' 'UI stop removes its TERM trap'
assert_eq "$_EM_UI_TRAPS" 0 'UI stop clears trap ownership'
assert_eq "$_EM_UI_INTERRUPTED" 0 'UI stop clears interrupted state'
assert_eq "$_EM_TTY_STATE" '' 'UI stop clears saved terminal state'
assert_eq "$EM_TEST_STTY_ARG" 'test-state' 'UI stop attempts exact terminal-state restore'
unset original_em_stty EM_TEST_STTY_ARG

trap ':' INT
parent_int_trap=$(trap -p INT)
_EM_UI_INTERRUPTED=1
_em_ui_start
assert_eq "$_EM_UI_INTERRUPTED" 0 'UI start clears interrupted state before fallback'
assert_eq "$(trap -p INT)" "$parent_int_trap" 'UI start preserves parent INT trap'
_em_ui_stop
assert_eq "$(trap -p INT)" "$parent_int_trap" 'UI stop preserves parent INT trap'
trap - INT

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
