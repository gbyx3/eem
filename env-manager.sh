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
_EM_FRAME_WIDTH=76
_EM_FRAME_PADDING=3

_EM_LOGO=(
  '  ___ _  ___   __ '
  ' | __| \| \ \ / / '
  ' | _|| .` |\ V /  '
  ' |___|_|\_| \_/   '
  '   M A N A G E R  '
)

_em_ui_start() {
  [[ -t 0 && -t 1 ]] || return
  _EM_UI_ACTIVE=1
  printf '\033[?1049h'
}

_em_ui_stop() {
  (( _EM_UI_ACTIVE )) || return
  printf '\033[?1049l'
  _EM_UI_ACTIVE=0
}

_em_screen() {
  local title=$1 block line segment cols rows top frame_width inner_width
  local content_height logo_height=0 logo_left border padding
  local -a raw_lines=() lines=()
  shift

  for block in "$@"; do
    while IFS= read -r line; do
      raw_lines+=("$line")
    done <<< "$block"
  done

  if (( ! _EM_UI_ACTIVE )); then
    printf '\n%s\n' "$title"
    for line in "${raw_lines[@]}"; do printf '%s\n' "$line"; done
    return
  fi

  cols=$(tput cols 2>/dev/null || printf '80')
  rows=$(tput lines 2>/dev/null || printf '24')
  frame_width=$_EM_FRAME_WIDTH
  ((frame_width > cols - 2)) && frame_width=$((cols - 2))
  ((frame_width < 12)) && frame_width=12
  padding=$_EM_FRAME_PADDING
  ((frame_width < 2 * padding + 4)) && padding=1
  inner_width=$((frame_width - 2 - 2 * padding))

  for line in "$title" '' "${raw_lines[@]}"; do
    if [[ -z $line ]]; then
      lines+=('')
      continue
    fi
    while ((${#line} > inner_width)); do
      segment=${line:0:inner_width}
      lines+=("$segment")
      line=${line:inner_width}
    done
    lines+=("$line")
  done

  _EM_UI_LEFT=$(((cols - frame_width) / 2))
  ((_EM_UI_LEFT < 0)) && _EM_UI_LEFT=0
  [[ $title == 'Environment Manager' ]] && logo_height=$((${#_EM_LOGO[@]} + 1))
  content_height=$((${#lines[@]} + 4 + logo_height))
  top=$(((rows - content_height) / 2))
  ((top < 0)) && top=0
  printf -v border '%*s' "$((frame_width - 2))" ''
  border=${border// /-}

  printf '\033[2J\033[H'
  printf '%*s' "$top" '' | tr ' ' '\n'
  if ((logo_height)); then
    for line in "${_EM_LOGO[@]}"; do
      logo_left=$(((cols - ${#line}) / 2))
      ((logo_left < 0)) && logo_left=0
      printf '%*s%s\n' "$logo_left" '' "$line"
    done
    printf '\n'
  fi
  printf '%*s+%s+\n' "$_EM_UI_LEFT" '' "$border"
  printf '%*s|%*s|\n' "$_EM_UI_LEFT" '' "$((frame_width - 2))" ''
  for line in "${lines[@]}"; do
    printf '%*s|%*s%-*s%*s|\n' \
      "$_EM_UI_LEFT" '' "$padding" '' "$inner_width" "$line" "$padding" ''
  done
  printf '%*s|%*s|\n' "$_EM_UI_LEFT" '' "$((frame_width - 2))" ''
  printf '%*s+%s+\n' "$_EM_UI_LEFT" '' "$border"
  _EM_UI_LEFT=$((_EM_UI_LEFT + 1 + padding))
}

_em_read() {
  local __name=$1 prompt=$2 silent=${3:-0}
  if (( _EM_UI_ACTIVE )); then
    printf '%*s' "$_EM_UI_LEFT" ''
  fi
  if (( silent )); then
    read -r -s -p "$prompt" "$__name"
  else
    read -r -p "$prompt" "$__name"
  fi
}

_em_pause() {
  local ignored
  _em_read ignored 'Press Enter to return to the main menu...'
}

_em_valid_key() {
  [[ $1 =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

_em_app_prefix() {
  local prefix=${1^^}
  prefix=${prefix//[^A-Z0-9_]/_}
  while [[ $prefix == *__* ]]; do
    prefix=${prefix//__/_}
  done
  prefix=${prefix#_}
  prefix=${prefix%_}
  [[ -n $prefix ]] || prefix=APP
  printf 'EM_%s_' "$prefix"
}

_em_has_app() {
  local app=$1 key
  for key in "${!_EM_APP[@]}"; do
    [[ ${_EM_APP[$key]} == "$app" ]] && return 0
  done
  return 1
}

_em_remember_app() {
  local app=$1 existing
  for existing in "${_EM_APP_ORDER[@]}"; do
    [[ $existing == "$app" ]] && return
  done
  _EM_APP_ORDER+=("$app")
}

_em_remember_key() {
  local key=$1 existing
  for existing in "${_EM_KEY_ORDER[@]}"; do
    [[ $existing == "$key" ]] && return
  done
  _EM_KEY_ORDER+=("$key")
}

em_set() {
  local app=${1-} key=${2-} value=${3-} secret=${4:-0} declaration

  if [[ -z $app ]]; then
    printf 'Application name cannot be empty.\n' >&2
    return 1
  fi
  if ! _em_valid_key "$key"; then
    printf 'Invalid variable name: %s\n' "$key" >&2
    return 1
  fi
  if [[ $secret != 0 && $secret != 1 ]]; then
    printf 'Secret flag must be 0 or 1.\n' >&2
    return 1
  fi
  if [[ -v _EM_APP[$key] && ${_EM_APP[$key]} != "$app" ]]; then
    printf '%s is already managed under %s.\n' "$key" "${_EM_APP[$key]}" >&2
    return 1
  fi

  if [[ ! -v _EM_APP[$key] ]]; then
    if declaration=$(declare -p "$key" 2>/dev/null); then
      if [[ $declaration =~ ^declare\ -[^\ ]*[arA] ]]; then
        printf '%s is an array or read-only variable and cannot be managed.\n' "$key" >&2
        return 1
      fi
      _EM_ORIGINAL_STATE[$key]=set
      _EM_ORIGINAL_VALUE[$key]=${!key}
      [[ $declaration =~ ^declare\ -[^\ ]*x ]] && _EM_ORIGINAL_EXPORTED[$key]=1 || _EM_ORIGINAL_EXPORTED[$key]=0
    else
      _EM_ORIGINAL_STATE[$key]=unset
      _EM_ORIGINAL_VALUE[$key]=''
      _EM_ORIGINAL_EXPORTED[$key]=0
    fi
    _em_remember_app "$app"
    _em_remember_key "$key"
  fi

  printf -v "$key" '%s' "$value" || return 1
  export "$key" || return 1
  _EM_APP[$key]=$app
  _EM_SECRET[$key]=$secret
}

_em_restore_key() {
  local key=$1
  [[ -v _EM_APP[$key] ]] || return 1

  if [[ ${_EM_ORIGINAL_STATE[$key]} == set ]]; then
    printf -v "$key" '%s' "${_EM_ORIGINAL_VALUE[$key]}" || return 1
    if [[ ${_EM_ORIGINAL_EXPORTED[$key]} == 1 ]]; then
      export "$key" || return 1
    else
      export -n "$key" || return 1
    fi
  else
    unset "$key" || return 1
  fi

  unset '_EM_APP[$key]' '_EM_SECRET[$key]' '_EM_ORIGINAL_STATE[$key]'
  unset '_EM_ORIGINAL_VALUE[$key]' '_EM_ORIGINAL_EXPORTED[$key]'
}

em_delete_key() {
  local key=${1-}
  if [[ ! -v _EM_APP[$key] ]]; then
    printf '%s is not managed by env-manager.\n' "$key" >&2
    return 1
  fi
  _em_restore_key "$key"
}

em_delete_app() {
  local app=${1-} key failed=0 found=0
  for key in "${_EM_KEY_ORDER[@]}"; do
    if [[ -v _EM_APP[$key] && ${_EM_APP[$key]} == "$app" ]]; then
      found=1
      _em_restore_key "$key" || failed=1
    fi
  done
  if (( ! found )); then
    printf 'No managed application named %s.\n' "$app" >&2
    return 1
  fi
  return "$failed"
}

em_delete_all() {
  local key failed=0
  for key in "${_EM_KEY_ORDER[@]}"; do
    if [[ -v _EM_APP[$key] ]]; then
      _em_restore_key "$key" || failed=1
    fi
  done
  return "$failed"
}

_em_list() {
  local app key found=0 value
  for app in "${_EM_APP_ORDER[@]}"; do
    _em_has_app "$app" || continue
    found=1
    printf '\n[%s]\n' "$app"
    for key in "${_EM_KEY_ORDER[@]}"; do
      [[ -v _EM_APP[$key] && ${_EM_APP[$key]} == "$app" ]] || continue
      if [[ ${_EM_SECRET[$key]} == 1 ]]; then
        value='********'
      else
        value=${!key}
      fi
      printf '  %s=%s\n' "$key" "$value"
    done
  done
  if (( ! found )); then
    printf 'No variables are currently managed.\n'
  fi
}

_em_confirm() {
  local prompt=$1 answer
  _em_read answer "$prompt [y/N] "
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

_em_add_menu() {
  local app key input_key value secret answer naming prefix
  _em_screen 'Add or update variables' \
    'Use an existing application name to add or replace its variables.' ''
  _em_read app 'Application/system name: '
  if [[ -z $app ]]; then
    _em_screen 'Add or update variables' 'Application name cannot be empty.' ''
    _em_pause
    return
  fi

  prefix=$(_em_app_prefix "$app")
  while :; do
    _em_screen 'Variable naming' '1. Original name (recommended)' "2. Prefix with $prefix" ''
    _em_read naming 'Choose an option [1]: '
    case ${naming:-1} in
      1) naming=original; break ;;
      2) naming=prefixed; break ;;
      *) ;;
    esac
  done

  while :; do
    _em_screen 'Add or update variables' "Application: $app" "Naming: $naming" ''
    _em_read input_key 'Variable name: '
    if ! _em_valid_key "$input_key"; then
      _em_screen 'Invalid variable name' \
        'Use letters, numbers, and underscores.' \
        'Do not start with a number.' ''
      _em_pause
      continue
    fi
    if [[ $naming == prefixed ]]; then
      key=${prefix}${input_key}
    else
      key=$input_key
    fi
    if [[ -v _EM_APP[$key] ]]; then
      if [[ ${_EM_APP[$key]} != "$app" ]]; then
        _em_screen 'Variable already managed' \
          "$key belongs to ${_EM_APP[$key]}." ''
        _em_pause
        continue
      fi
      _em_screen 'Replace variable' "Exported name: $key" ''
      _em_confirm "$key already exists. Replace it?" || continue
    fi

    while :; do
      _em_screen 'Set variable' "Application: $app" "Exported name: $key" ''
      _em_read answer 'Is this value secret? [y/n] '
      [[ $answer == [yYnN] ]] && break
      _em_screen 'Invalid selection' 'Enter y or n.' ''
      _em_pause
    done
    if [[ $answer == [yY] ]]; then
      secret=1
      _em_read value 'Value: ' 1
      printf '\n'
    else
      secret=0
      _em_read value 'Value: '
    fi

    if em_set "$app" "$key" "$value" "$secret"; then
      _em_screen 'Variable exported' "$key is active in this shell." ''
    fi
    _em_confirm 'Add another variable to this application?' || break
  done
}

_em_choose_key() {
  local app=${1-} key choice index=1
  local -a choices=() lines=()
  for key in "${_EM_KEY_ORDER[@]}"; do
    [[ -v _EM_APP[$key] ]] || continue
    [[ -z $app || ${_EM_APP[$key]} == "$app" ]] || continue
    choices+=("$key")
    lines+=("$index. $key (${_EM_APP[$key]})")
    ((index++))
  done
  ((${#choices[@]})) || return 1
  lines+=('' 'B. Back')
  _em_screen 'Choose a variable' "${lines[@]}" ''
  _em_read choice 'Choose a variable: '
  [[ $choice == [bB] ]] && return 2
  [[ $choice =~ ^[0-9]+$ && choice -ge 1 && choice -le ${#choices[@]} ]] || return 1
  REPLY=${choices[choice-1]}
}

_em_choose_app() {
  local app choice index=1
  local -a choices=() lines=()
  for app in "${_EM_APP_ORDER[@]}"; do
    _em_has_app "$app" || continue
    choices+=("$app")
    lines+=("$index. $app")
    ((index++))
  done
  ((${#choices[@]})) || return 1
  lines+=('' 'B. Back')
  _em_screen 'Choose an application' "${lines[@]}" ''
  _em_read choice 'Choose an application: '
  [[ $choice == [bB] ]] && return 2
  [[ $choice =~ ^[0-9]+$ && choice -ge 1 && choice -le ${#choices[@]} ]] || return 1
  REPLY=${choices[choice-1]}
}

_em_delete_menu() {
  local choice target listing status
  while :; do
    listing=$(_em_list)
    _em_screen 'Delete variables' "$listing" '' \
      '1. Variable' '2. Application/system' '3. All' '' 'B. Back' ''
    _em_read choice 'Choose an option: '
    case $choice in
      1)
        _em_choose_key
        status=$?
        ((status == 2)) && continue
        ((status == 0)) || { printf 'No selection made.\n'; continue; }
        target=$REPLY
        _em_confirm "Restore and remove $target?" && em_delete_key "$target"
        ;;
      2)
        _em_choose_app
        status=$?
        ((status == 2)) && continue
        ((status == 0)) || { printf 'No selection made.\n'; continue; }
        target=$REPLY
        _em_confirm "Restore all variables under $target?" && em_delete_app "$target"
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
  local choice listing
  _em_ui_start
  while :; do
    _em_screen 'Environment Manager' \
      '1. List variables' \
      '2. Add or update variables' \
      '3. Delete variables' \
      '' 'E. Exit menu' ''
    _em_read choice 'Choose an option: ' || break
    case $choice in
      1)
        listing=$(_em_list)
        _em_screen 'Managed variables' "$listing" ''
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
