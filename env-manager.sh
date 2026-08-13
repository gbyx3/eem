#!/usr/bin/env bash

# Ephemeral environment manager. Source this file so exported variables remain
# available in the current shell after the menu closes.

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]} -lt 4 ]]; then
  printf 'env-manager requires Bash 4 or newer.\n' >&2
  return 1 2>/dev/null || exit 1
fi

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  printf 'This script must be sourced:\n  source %q\n' "$0" >&2
  exit 1
fi

# Do not discard active session metadata if this file is sourced again.
if ! declare -p _EM_APP >/dev/null 2>&1; then
  declare -gA _EM_APP=()
  declare -gA _EM_SECRET=()
  declare -gA _EM_ORIGINAL_STATE=()
  declare -gA _EM_ORIGINAL_VALUE=()
  declare -gA _EM_ORIGINAL_EXPORTED=()
  declare -ga _EM_KEY_ORDER=()
  declare -ga _EM_APP_ORDER=()
fi

_EM_UI_ACTIVE=0
_EM_UI_LEFT=0
_EM_UI_INTERRUPTED=0
_EM_UI_TRAPS=0
_EM_TTY_STATE=''
_EM_FRAME_WIDTH=76
_EM_FRAME_PADDING=3

_EM_LOGO=(
  '███████╗███████╗███╗   ███╗'
  '██╔════╝██╔════╝████╗ ████║'
  '█████╗  █████╗  ██╔████╔██║'
  '██╔══╝  ██╔══╝  ██║╚██╔╝██║'
  '███████╗███████╗██║ ╚═╝ ██║'
  '╚══════╝╚══════╝╚═╝     ╚═╝'
  ''
  'ephemeral environment manager'
)

_em_ui_start() {
  _EM_UI_INTERRUPTED=0
  _EM_TTY_STATE=''
  [[ -t 0 && -t 1 ]] || return
  _EM_TTY_STATE=$(_em_stty -g 2>/dev/null) || _EM_TTY_STATE=''
  # Do not replace traps owned by the parent shell. In that uncommon case the
  # plain UI avoids creating terminal state that this script cannot own safely.
  if [[ -n $(trap -p INT) || -n $(trap -p TERM) ]]; then
    return
  fi
  _EM_UI_TRAPS=1
  trap '_em_ui_interrupt' INT TERM
  _EM_UI_ACTIVE=1
  printf '\033[?1049h'
}

_em_stty() {
  if [[ -x /usr/bin/stty ]]; then
    /usr/bin/stty "$@"
  elif [[ -x /bin/stty ]]; then
    /bin/stty "$@"
  else
    return 127
  fi
}

_em_ui_restore_terminal() {
  [[ -n $_EM_TTY_STATE ]] && _em_stty "$_EM_TTY_STATE" 2>/dev/null || :
  (( _EM_UI_ACTIVE )) && printf '\033[?1049l'
  _EM_UI_ACTIVE=0
}

_em_ui_interrupt() {
  _EM_UI_INTERRUPTED=1
  _em_ui_restore_terminal
}

_em_ui_stop() {
  _em_ui_restore_terminal
  if (( _EM_UI_TRAPS )); then
    trap - INT TERM
    _EM_UI_TRAPS=0
  fi
  _EM_UI_INTERRUPTED=0
  _EM_TTY_STATE=''
}

_em_sanitize_display() {
  local _em_input=$1 _em_output='' _em_char _em_code _em_i
  for ((_em_i = 0; _em_i < ${#_em_input}; _em_i++)); do
    _em_char=${_em_input:_em_i:1}
    printf -v _em_code '%d' "'$_em_char"
    if ((_em_code >= 32 && _em_code != 127 && ! (_em_code >= 128 && _em_code <= 159))); then
      _em_output+=$_em_char
    fi
  done
  printf '%s' "$_em_output"
}

_em_screen() {
  local _em_title=$1 _em_block _em_line _em_segment _em_cols _em_rows _em_top
  local _em_frame_width _em_inner_width _em_i _em_content_height
  local _em_logo_height=0 _em_logo_left _em_border _em_padding
  local -a _em_raw_lines=() _em_lines=()
  shift

  for _em_block in "$@"; do
    while IFS= read -r _em_line; do
      _em_line=$(_em_sanitize_display "$_em_line")
      _em_raw_lines+=("$_em_line")
    done <<< "$_em_block"
  done

  if (( ! _EM_UI_ACTIVE )); then
    printf '\n%s\n' "$_em_title"
    for _em_line in "${_em_raw_lines[@]}"; do printf '%s\n' "$_em_line"; done
    return
  fi

  [[ ${COLUMNS:-} =~ ^[0-9]+$ ]] && _em_cols=$COLUMNS || _em_cols=80
  [[ ${LINES:-} =~ ^[0-9]+$ ]] && _em_rows=$LINES || _em_rows=24
  _em_frame_width=$_EM_FRAME_WIDTH
  ((_em_frame_width > _em_cols - 2)) && _em_frame_width=$((_em_cols - 2))
  ((_em_frame_width < 12)) && _em_frame_width=12
  _em_padding=$_EM_FRAME_PADDING
  ((_em_frame_width < 2 * _em_padding + 4)) && _em_padding=1
  _em_inner_width=$((_em_frame_width - 2 - 2 * _em_padding))

  for _em_line in "$_em_title" '' "${_em_raw_lines[@]}"; do
    if [[ -z $_em_line ]]; then
      _em_lines+=('')
      continue
    fi
    while ((${#_em_line} > _em_inner_width)); do
      _em_segment=${_em_line:0:_em_inner_width}
      _em_lines+=("$_em_segment")
      _em_line=${_em_line:_em_inner_width}
    done
    _em_lines+=("$_em_line")
  done

  _EM_UI_LEFT=$(((_em_cols - _em_frame_width) / 2))
  ((_EM_UI_LEFT < 0)) && _EM_UI_LEFT=0
  [[ $_em_title == 'Environment Manager' ]] && _em_logo_height=$((${#_EM_LOGO[@]} + 1))
  _em_content_height=$((${#_em_lines[@]} + 4 + _em_logo_height))
  _em_top=$(((_em_rows - _em_content_height) / 2))
  ((_em_top < 0)) && _em_top=0
  printf -v _em_border '%*s' "$((_em_frame_width - 2))" ''
  _em_border=${_em_border// /-}

  printf '\033[2J\033[H'
  for ((_em_i = 0; _em_i < _em_top; _em_i++)); do printf '\n'; done
  if ((_em_logo_height)); then
    for _em_line in "${_EM_LOGO[@]}"; do
      _em_logo_left=$(((_em_cols - ${#_em_line}) / 2))
      ((_em_logo_left < 0)) && _em_logo_left=0
      printf '%*s%s\n' "$_em_logo_left" '' "$_em_line"
    done
    printf '\n'
  fi
  printf '%*s+%s+\n' "$_EM_UI_LEFT" '' "$_em_border"
  printf '%*s|%*s|\n' "$_EM_UI_LEFT" '' "$((_em_frame_width - 2))" ''
  for _em_line in "${_em_lines[@]}"; do
    printf '%*s|%*s%-*s%*s|\n' \
      "$_EM_UI_LEFT" '' "$_em_padding" '' "$_em_inner_width" "$_em_line" "$_em_padding" ''
  done
  printf '%*s|%*s|\n' "$_EM_UI_LEFT" '' "$((_em_frame_width - 2))" ''
  printf '%*s+%s+\n' "$_EM_UI_LEFT" '' "$_em_border"
  _EM_UI_LEFT=$((_EM_UI_LEFT + 1 + _em_padding))
}

_em_read() {
  local _em_name=$1 _em_prompt=$2 _em_silent=${3:-0} _em_status
  (( _EM_UI_INTERRUPTED )) && return 130
  if (( _EM_UI_ACTIVE )); then
    printf '%*s' "$_EM_UI_LEFT" ''
  fi
  if (( _em_silent )); then
    read -r -s -p "$_em_prompt" "$_em_name"
    _em_status=$?
    [[ -n $_EM_TTY_STATE ]] && _em_stty "$_EM_TTY_STATE" 2>/dev/null || :
  else
    read -r -p "$_em_prompt" "$_em_name"
    _em_status=$?
  fi
  (( _EM_UI_INTERRUPTED )) && return 130
  return "$_em_status"
}

_em_pause() {
  local _em_ignored
  _em_read _em_ignored 'Press Enter to return to the main menu...'
}

_em_valid_key() {
  [[ $1 =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

_em_safe_key() {
  case $1 in
    PATH|CDPATH|IFS|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|BASH_ENV|ENV|\
    GCONV_PATH|GLIBC_TUNABLES|LOCPATH|NLSPATH|BASH_LOADABLES_PATH|\
    PROMPT_COMMAND|PS0|PS1|PS2|PS4|HISTFILE|HISTCONTROL|HOME|SHELL|USER|\
    SHELLOPTS|BASHOPTS|BASH_XTRACEFD|BASH_COMPAT|GLOBIGNORE|INPUTRC|TMOUT|\
    OPTIND|RANDOM|SRANDOM|SECONDS|LINENO|BASHPID|BASH_SUBSHELL|EUID|UID|\
    PPID|FUNCNAME|BASH_SOURCE|BASH_LINENO|GROUPS|DIRSTACK|PIPESTATUS|\
    LANG|LC_*|COLUMNS|LINES|\
    _EM_*|_em_*|em_*|env_manager)
      return 1
      ;;
  esac
  return 0
}

_em_safe_attributes() {
  local _em_declaration _em_flags
  if _em_declaration=$(declare -p "$1" 2>/dev/null); then
    _em_flags=${_em_declaration#declare -}
    _em_flags=${_em_flags%% *}
    if [[ $_em_flags == *[aArn]* ]]; then
      printf '%s is an array, read-only variable, or nameref and cannot be managed.\n' "$1" >&2
      return 1
    fi
  fi
  return 0
}

_em_valid_app() {
  [[ -n $1 && $(_em_sanitize_display "$1") == "$1" ]]
}

_em_app_prefix() {
  local _em_prefix=${1^^}
  _em_prefix=${_em_prefix//[^A-Z0-9_]/_}
  while [[ $_em_prefix == *__* ]]; do
    _em_prefix=${_em_prefix//__/_}
  done
  _em_prefix=${_em_prefix#_}
  _em_prefix=${_em_prefix%_}
  [[ -n $_em_prefix ]] || _em_prefix=APP
  printf 'EM_%s_' "$_em_prefix"
}

_em_has_app() {
  local _em_app_name=$1 _em_var_name
  for _em_var_name in "${!_EM_APP[@]}"; do
    [[ ${_EM_APP[$_em_var_name]} == "$_em_app_name" ]] && return 0
  done
  return 1
}

_em_remember_app() {
  local _em_app_name=$1 _em_existing
  for _em_existing in "${_EM_APP_ORDER[@]}"; do
    [[ $_em_existing == "$_em_app_name" ]] && return
  done
  _EM_APP_ORDER+=("$_em_app_name")
}

_em_remember_key() {
  local _em_var_name=$1 _em_existing
  for _em_existing in "${_EM_KEY_ORDER[@]}"; do
    [[ $_em_existing == "$_em_var_name" ]] && return
  done
  _EM_KEY_ORDER+=("$_em_var_name")
}

em_set() {
  local _em_declaration _em_flags

  if ! _em_valid_app "${1-}"; then
    printf 'Application name is required and cannot contain control characters.\n' >&2
    return 1
  fi
  if ! _em_valid_key "${2-}"; then
    printf 'Invalid variable name: %s\n' "${2-}" >&2
    return 1
  fi
  if ! _em_safe_key "$2"; then
    printf 'Refusing to manage reserved or shell-critical variable: %s\n' "$2" >&2
    return 1
  fi
  if [[ ${4:-0} != 0 && ${4:-0} != 1 ]]; then
    printf 'Secret flag must be 0 or 1.\n' >&2
    return 1
  fi
  if [[ -v _EM_APP[$2] && ${_EM_APP[$2]} != "$1" ]]; then
    printf '%s is already managed under %s.\n' "$2" "${_EM_APP[$2]}" >&2
    return 1
  fi
  _em_safe_attributes "$2" || return 1

  if [[ ! -v _EM_APP[$2] ]]; then
    if _em_declaration=$(declare -p "$2" 2>/dev/null); then
      _em_flags=${_em_declaration#declare -}
      _em_flags=${_em_flags%% *}
      _EM_ORIGINAL_STATE[$2]=set
      _EM_ORIGINAL_VALUE[$2]=${!2}
      [[ $_em_flags == *x* ]] && _EM_ORIGINAL_EXPORTED[$2]=1 || _EM_ORIGINAL_EXPORTED[$2]=0
    else
      _EM_ORIGINAL_STATE[$2]=unset
      _EM_ORIGINAL_VALUE[$2]=''
      _EM_ORIGINAL_EXPORTED[$2]=0
    fi
    _em_remember_app "$1"
    _em_remember_key "$2"
  fi

  declare -gx -- "$2=$3" || return 1
  _EM_APP[$2]=$1
  _EM_SECRET[$2]=${4:-0}
}

_em_restore_key() {
  [[ -v _EM_APP[$1] ]] || return 1
  _em_safe_attributes "$1" || return 1

  if [[ ${_EM_ORIGINAL_STATE[$1]} == set ]]; then
    if [[ ${_EM_ORIGINAL_EXPORTED[$1]} == 1 ]]; then
      declare -gx -- "$1=${_EM_ORIGINAL_VALUE[$1]}" || return 1
    else
      declare -g +x -- "$1=${_EM_ORIGINAL_VALUE[$1]}" || return 1
    fi
  else
    unset -v "$1" || return 1
  fi

  unset '_EM_APP[$1]' '_EM_SECRET[$1]' '_EM_ORIGINAL_STATE[$1]'
  unset '_EM_ORIGINAL_VALUE[$1]' '_EM_ORIGINAL_EXPORTED[$1]'
}

em_delete_key() {
  if [[ ! -v _EM_APP[${1-}] ]]; then
    printf '%s is not managed by env-manager.\n' "${1-}" >&2
    return 1
  fi
  _em_restore_key "$1"
}

em_delete_app() {
  local _em_app_name=${1-} _em_var_name _em_failed=0 _em_found=0
  for _em_var_name in "${_EM_KEY_ORDER[@]}"; do
    if [[ -v _EM_APP[$_em_var_name] && ${_EM_APP[$_em_var_name]} == "$_em_app_name" ]]; then
      _em_found=1
      _em_restore_key "$_em_var_name" || _em_failed=1
    fi
  done
  if (( ! _em_found )); then
    printf 'No managed application named %s.\n' "$_em_app_name" >&2
    return 1
  fi
  return "$_em_failed"
}

em_delete_all() {
  local _em_var_name _em_failed=0
  for _em_var_name in "${_EM_KEY_ORDER[@]}"; do
    if [[ -v _EM_APP[$_em_var_name] ]]; then
      _em_restore_key "$_em_var_name" || _em_failed=1
    fi
  done
  return "$_em_failed"
}

_em_list() {
  local _em_app_name _em_var_name _em_found=0 _em_display_value
  for _em_app_name in "${_EM_APP_ORDER[@]}"; do
    _em_has_app "$_em_app_name" || continue
    _em_found=1
    printf '\n[%s]\n' "$(_em_sanitize_display "$_em_app_name")"
    for _em_var_name in "${_EM_KEY_ORDER[@]}"; do
      [[ -v _EM_APP[$_em_var_name] && ${_EM_APP[$_em_var_name]} == "$_em_app_name" ]] || continue
      if [[ ${_EM_SECRET[$_em_var_name]} == 1 ]]; then
        _em_display_value='********'
      else
        _em_display_value=$(_em_sanitize_display "${!_em_var_name}")
      fi
      printf '  %s=%s\n' "$_em_var_name" "$_em_display_value"
    done
  done
  if (( ! _em_found )); then
    printf 'No variables are currently managed.\n'
  fi
}

_em_confirm() {
  local _em_prompt=$1 _em_answer
  _em_read _em_answer "$_em_prompt [y/N] "
  [[ $_em_answer == [yY] || $_em_answer == [yY][eE][sS] ]]
}

_em_add_menu() {
  local _em_app_name _em_var_name _em_input_key _em_value _em_secret
  local _em_answer _em_naming _em_prefix
  _em_screen 'Add or update variables' \
    'Use an existing application name to add or replace its variables.' ''
  _em_read _em_app_name 'Application/system name: ' || return
  if ! _em_valid_app "$_em_app_name"; then
    _em_screen 'Add or update variables' \
      'Application name is required and cannot contain control characters.' ''
    _em_pause
    return
  fi

  _em_prefix=$(_em_app_prefix "$_em_app_name")
  while (( !_EM_UI_INTERRUPTED )); do
    _em_screen 'Variable naming' '1. Original name (recommended)' "2. Prefix with $_em_prefix" ''
    _em_read _em_naming 'Choose an option [1]: ' || return
    case ${_em_naming:-1} in
      1) _em_naming=original; break ;;
      2) _em_naming=prefixed; break ;;
      *) ;;
    esac
  done

  while (( !_EM_UI_INTERRUPTED )); do
    _em_screen 'Add or update variables' "Application: $_em_app_name" "Naming: $_em_naming" ''
    _em_read _em_input_key 'Variable name: ' || return
    if ! _em_valid_key "$_em_input_key"; then
      _em_screen 'Invalid variable name' \
        'Use letters, numbers, and underscores.' \
        'Do not start with a number.' ''
      _em_pause
      continue
    fi
    if [[ $_em_naming == prefixed ]]; then
      _em_var_name=${_em_prefix}${_em_input_key}
    else
      _em_var_name=$_em_input_key
    fi
    if [[ -v _EM_APP[$_em_var_name] ]]; then
      if [[ ${_EM_APP[$_em_var_name]} != "$_em_app_name" ]]; then
        _em_screen 'Variable already managed' \
          "$_em_var_name belongs to ${_EM_APP[$_em_var_name]}." ''
        _em_pause
        continue
      fi
      _em_screen 'Replace variable' "Exported name: $_em_var_name" ''
      _em_confirm "$_em_var_name already exists. Replace it?" || continue
    fi

    while (( !_EM_UI_INTERRUPTED )); do
      _em_screen 'Set variable' "Application: $_em_app_name" "Exported name: $_em_var_name" ''
      _em_read _em_answer 'Is this value secret? [y/n] ' || return
      [[ $_em_answer == [yYnN] ]] && break
      _em_screen 'Invalid selection' 'Enter y or n.' ''
      _em_pause
    done
    if [[ $_em_answer == [yY] ]]; then
      _em_secret=1
      _em_read _em_value 'Value: ' 1 || return
      printf '\n'
    else
      _em_secret=0
      _em_read _em_value 'Value: ' || return
    fi

    if em_set "$_em_app_name" "$_em_var_name" "$_em_value" "$_em_secret"; then
      _em_screen 'Variable exported' "$_em_var_name is active in this shell." ''
    fi
    _em_confirm 'Add another variable to this application?' || break
  done
}

_em_choose_key() {
  local _em_app_name=${1-} _em_var_name _em_choice _em_index=1
  local -a _em_choices=() _em_lines=()
  for _em_var_name in "${_EM_KEY_ORDER[@]}"; do
    [[ -v _EM_APP[$_em_var_name] ]] || continue
    [[ -z $_em_app_name || ${_EM_APP[$_em_var_name]} == "$_em_app_name" ]] || continue
    _em_choices+=("$_em_var_name")
    _em_lines+=("$_em_index. $_em_var_name (${_EM_APP[$_em_var_name]})")
    ((_em_index++))
  done
  ((${#_em_choices[@]})) || return 1
  _em_lines+=('' 'B. Back')
  _em_screen 'Choose a variable' "${_em_lines[@]}" ''
  _em_read _em_choice 'Choose a variable: ' || return 2
  [[ $_em_choice == [bB] ]] && return 2
  [[ $_em_choice =~ ^[0-9]+$ && _em_choice -ge 1 && _em_choice -le ${#_em_choices[@]} ]] || return 1
  REPLY=${_em_choices[_em_choice-1]}
}

_em_choose_app() {
  local _em_app_name _em_choice _em_index=1
  local -a _em_choices=() _em_lines=()
  for _em_app_name in "${_EM_APP_ORDER[@]}"; do
    _em_has_app "$_em_app_name" || continue
    _em_choices+=("$_em_app_name")
    _em_lines+=("$_em_index. $_em_app_name")
    ((_em_index++))
  done
  ((${#_em_choices[@]})) || return 1
  _em_lines+=('' 'B. Back')
  _em_screen 'Choose an application' "${_em_lines[@]}" ''
  _em_read _em_choice 'Choose an application: ' || return 2
  [[ $_em_choice == [bB] ]] && return 2
  [[ $_em_choice =~ ^[0-9]+$ && _em_choice -ge 1 && _em_choice -le ${#_em_choices[@]} ]] || return 1
  REPLY=${_em_choices[_em_choice-1]}
}

_em_delete_menu() {
  local _em_choice _em_target _em_listing _em_status
  while (( !_EM_UI_INTERRUPTED )); do
    _em_listing=$(_em_list)
    _em_screen 'Delete variables' "$_em_listing" '' \
      '1. Variable' '2. Application/system' '3. All' '' 'B. Back' ''
    _em_read _em_choice 'Choose an option: ' || return
    case $_em_choice in
      1)
        _em_choose_key
        _em_status=$?
        ((_em_status == 2)) && continue
        ((_em_status == 0)) || { printf 'No selection made.\n'; continue; }
        _em_target=$REPLY
        _em_confirm "Restore and remove $_em_target?" && em_delete_key "$_em_target"
        ;;
      2)
        _em_choose_app
        _em_status=$?
        ((_em_status == 2)) && continue
        ((_em_status == 0)) || { printf 'No selection made.\n'; continue; }
        _em_target=$REPLY
        _em_confirm "Restore all variables under $_em_target?" && em_delete_app "$_em_target"
        ;;
      3)
        if _em_confirm 'Restore and remove ALL managed variables?'; then
          em_delete_all
          return
        fi
        ;;
      [bB]) return ;;
      *) printf 'Invalid option.\n' ;;
    esac
  done
}

env_manager() {
  local _em_choice _em_listing
  _em_ui_start
  while (( !_EM_UI_INTERRUPTED )); do
    _em_screen 'Environment Manager' \
      '1. List variables' \
      '2. Add or update variables' \
      '3. Delete variables' \
      '' 'E. Exit menu' ''
    _em_read _em_choice 'Choose an option: ' || break
    case $_em_choice in
      1)
        _em_listing=$(_em_list)
        _em_screen 'Managed variables' "$_em_listing" ''
        _em_pause
        ;;
      2) _em_add_menu ;;
      3) _em_delete_menu ;;
      [eE]) break ;;
      *) ;;
    esac
  done
  _em_ui_stop
}

env_manager
