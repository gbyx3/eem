# SECURITY_CONCERNS.md

Living review brief for `env-manager.sh`. This file is written for an
implementing LLM (OpenCode). It is not a patch.

Audited commit: `258511d` (`Harden environment and terminal handling`).
Claimed response: `SECURITY_ADDRESSED.md`.
Tests: `tests/env-manager-test.sh`.

Do not re-implement closed items. Confirm each open item against the current
code, then fix only those. Unrelated worktree changes (logo, `grok_was_here/`)
are out of scope.

## Instructions

1. Read `env-manager.sh` and `tests/env-manager-test.sh` in full first.
2. Treat the **Open follow-ups** section as the work queue. Closed items are
   context, not a request to rewrite them.
3. Keep the sourced-script contract. No disk-backed secret store, encryption,
   or daemon.
4. Add or extend tests in `tests/env-manager-test.sh` for every behavioral
   fix. Do not add a second test framework. Keep
   `source "$ROOT/env-manager.sh" <<< 'E'`.
5. `bash tests/env-manager-test.sh` must pass. Direct execution of
   `env-manager.sh` must still fail with the source hint.
6. Do not rewrite the TUI unless a finding requires it.
7. Do not expand the README unless you add user-visible behavior.

Scope:

- Trusted interactive user shell. Do not defend a compromised account.
- Do defend: shell-critical / loader names, nameref write-through, terminal
  control injection, interrupt leaving the tty unusable, UI helpers hijacked
  via `PATH`.
- "Secret" means masked listing + `read -s`. Do not claim encryption. Do not
  try to hide `/proc/<pid>/environ`.

## Program contract (do not break)

- Source-only. Direct execution refuses and exits.
- Bash 4+.
- Public API used by tests: `em_set`, `em_delete_key`, `em_delete_app`,
  `em_delete_all`, `_em_app_prefix`, `_em_list`, `_em_add_menu`.
- `em_set APP KEY VALUE SECRET` exports `KEY=VALUE` and records metadata so
  delete restores the pre-management value and export flag.
- `SECRET` is `0` or `1`. Listings must mask `1`. Stored values must not be
  altered by display sanitization.
- Re-sourcing must not wipe `_EM_APP`, `_EM_SECRET`, `_EM_ORIGINAL_*`, or the
  order arrays.
- Names remain `^[A-Za-z_][A-Za-z0-9_]*$`.
- No `eval`. Assign with `declare -g` / `export` / `unset` on a validated
  name only.
- No persistence to disk.

## Audit of 258511d

Independent review of `258511d` plus live checks on Bash 5.3. Official suite
printed `All tests passed.` Direct execution exited 1 with the source hint.
Restore-on-delete, secret masking, and no-disk still hold.

| ID | Status | Notes |
|---|---|---|
| F1 | CLOSED | Denylist + identifier regex. `tput`/`tr` removed. `declare -gx` avoids dynamic-scope locals. Required names rejected. |
| F2 | CLOSED | `declare -p` flag group + `*[aArn]*`. `-n` and `-nx` rejected. Target unchanged. |
| F3 | PARTIAL | Default path restores alt-screen and echo, clears owned traps, does not `exit`. Parent-trap fallback still leaves `read -s` unprotected. |
| F4 | CLOSED | Display sanitizer strips C0/DEL/C1. App names with controls rejected. Stored values unchanged. |
| F5 | UNCHANGED | Session-wide export is the product. Leave it. |
| F6 | UNCHANGED | Re-source reloads functions. Leave it. |
| F7 | PARTIAL | Tests cover the original F1/F2/F4 cases and trap cleanup. They do not cover the open follow-ups. |

Do not reopen F1/F2/F4 from scratch. Residual holes under those IDs are listed
as new follow-ups below.

Verified live (not only the existing assertions):

- `em_set app PATH /tmp 0` fails; `PATH` unchanged.
- `EM_APP_PATH` and `OPENAI_API_KEY` still succeed.
- `em_set app value global 0` sets a global, not a function local.
- Nameref and `declare -nx` nameref rejected; target unchanged.
- `declare -- VAR=...` still sets and restores.
- `_em_list` listing of ESC/OSC/BEL/CR/LF/TAB/DEL/NEL/C1 has no raw control
  bytes in the value field. Stored value kept.
- App name with ESC or LF rejected.
- Pty `SIGINT` at the main menu: shell survived, `_EM_UI_ACTIVE=0`, no leftover
  INT trap.
- Parent INT trap: alternate screen skipped, parent trap preserved.
- `$(trap -p INT)` on Bash 5.3 still sees the parent trap (not the pre-4.2
  empty-subshell gotcha). Detection can work; the remaining bug is fallback
  policy.

`email` is allowed. `em_*` only matches names with `em_` plus more
(`em_token`). Do not "fix" `email`.

## Open follow-ups

These are independently actionable. Fix them in `env-manager.sh` and extend
`tests/env-manager-test.sh`.

### O1 — Echo not restored when a parent trap exists

Severity: medium
Status: open (remaining F3 hole)
Where: `_em_ui_start` (early return when `trap -p INT` or `TERM` is set),
`_em_ui_restore_terminal` (no-ops unless `_EM_UI_ACTIVE || _EM_UI_TRAPS`),
`_em_read` silent path (`read -s` around line 430)

If the parent shell already has an INT or TERM trap, start skips
`_EM_UI_TRAPS` and `_EM_UI_ACTIVE` but the menu still uses `read -s`. Ctrl-C
runs the parent trap. `_EM_UI_INTERRUPTED` stays 0. `_em_ui_stop` then
no-ops and never runs `stty echo`. Interactive rc files that install an INT
trap hit this.

Required change:

- Always restore echo from `_em_ui_stop` / `_em_ui_restore_terminal`, even
  when this script does not own the alternate screen.
- Keep the rule: do not overwrite a parent INT/TERM trap. Acceptable
  patterns: wrap the parent action (save, install a handler that restores
  the tty then runs the saved action), or restore echo without installing
  traps.
- Do not `exit` the parent shell from a trap.
- Remove only traps this script installed.

Tests:

- `_EM_UI_ACTIVE=0` and `_EM_UI_TRAPS=0`; call restore/stop; assert the
  restore helper still attempts echo (unit-test the gate, even without a
  tty).
- With a dummy parent `trap true INT`, sourcing still must not replace that
  trap.

### O2 — `_EM_UI_INTERRUPTED` sticks

Severity: medium
Status: open
Where: `_em_ui_interrupt` sets the flag; `_em_ui_stop` never clears it;
`_em_ui_start` only clears it after the tty and parent-trap checks succeed

After a real interrupt, a later `env_manager` whose start returns early
(parent trap, or not a tty) skips the menu: `while (( !_EM_UI_INTERRUPTED ))`.

Required change:

- Set `_EM_UI_INTERRUPTED=0` at the top of `_em_ui_start` (before any early
  return) and in `_em_ui_stop`.

Test:

- Set `_EM_UI_INTERRUPTED=1`, install a dummy INT trap, call `_em_ui_start`,
  assert the flag is 0.

### O3 — Loader / locale denylist gaps

Severity: high
Status: open (F1 residual; original required names are already blocked)
Where: `_em_safe_key`

Still allowed, same "export and every child inherits it" class as
`LD_PRELOAD`:

- `GCONV_PATH` — iconv module search path; arbitrary `.so` load
- `GLIBC_TUNABLES` — malloc/rtld hardening; exploitation primitive
- `LOCPATH` — locale object search path
- `NLSPATH` — message-catalog path
- `BASH_LOADABLES_PATH` — retargets `enable -f`

Also still allowed, lower severity, fix in the same change if cheap:

- `LANG`, `LC_ALL`, `LC_CTYPE` (and other `LC_*`) — can change character
  classes and sanitizer width
- `COLUMNS`, `LINES` — now drive `_em_screen` geometry

Keep the identifier regex. Exact case-sensitive match, plus the existing
`_EM_*` / `_em_*` globs.

Do not broaden `em_*` further. Do not block `email`.

Tests to add (same loop style as `PATH` / `LD_PRELOAD`):

- `GCONV_PATH`, `GLIBC_TUNABLES`, `LOCPATH`, `NLSPATH`,
  `BASH_LOADABLES_PATH` rejected.
- `OPENAI_API_KEY` and `email` still allowed.
- Prefixed `EM_APP_PATH` still allowed.

### O4 — Nameref not rechecked on update

Severity: low
Status: open (F2 residual)
Where: `em_set`, the `[[ ! -v _EM_APP[$2] ]]` first-insert branch

Nameref / array / read-only rejection runs only on first manage. A later
`unset KEY; declare -n KEY=TARGET` then `em_set` replace does
`declare -gx -- "$2=$3"` and writes through the nameref.

Required change:

- Run the `declare -p` / `*[aArn]*` check on every `em_set`, not only the
  first insert.

Test:

- Manage a scalar, convert it to `declare -n` pointing at a throwaway
  target, `em_set` again, assert failure and target unchanged.

### O5 — Tests do not cover O1–O4

Severity: medium (process)
Status: open
Where: `tests/env-manager-test.sh`

Add coverage listed under O1–O4. Clean up every test variable.

## Closed (do not rework)

### F1 original list — closed

`_em_safe_key` rejects `PATH`, `CDPATH`, `IFS`, `LD_PRELOAD`,
`LD_LIBRARY_PATH`, `LD_AUDIT`, `BASH_ENV`, `ENV`, `PROMPT_COMMAND`,
`PS0`–`PS4`, `HISTFILE`, `HISTCONTROL`, `HOME`, `SHELL`, `USER`,
`SHELLOPTS`, `BASHOPTS`, `BASH_XTRACEFD`, and related specials, plus
`_EM_*` / `_em_*` / `em_*` / `env_manager`. `_em_screen` no longer calls
`tput` or `tr`. Assignment is `declare -gx -- "$2=$3"`.

### F2 first-insert nameref — closed

Flag parse is position-independent. First `em_set` on a nameref fails
before metadata or assignment.

### F3 default interrupt path — closed

No parent trap: INT/TERM installed before `\033[?1049h`; restore uses
`/usr/bin/stty` or `/bin/stty` and `\033[?1049l`; owned traps cleared;
no `exit`. Remaining work is O1 and O2.

### F4 display injection — closed

`_em_sanitize_display` strips C0, DEL, C1. `_em_valid_app` rejects names
that change under sanitizing. `_em_list` / `_em_screen` sanitize before
wrap/print. Values are not rewritten in the environment.

Residual, do not treat as a must-fix unless you are already in the
sanitizer: printable leftovers such as `[31m` after ESC is stripped;
U+202E bidi override is kept. Optional: sanitize by byte under `LC_ALL=C`.

## Intentionally unchanged

- F5: no command-scoped `KEY=value command` mode.
- F6: no re-source integrity check.

## Out of scope

- Encrypting values in memory or on disk.
- Wiping the Bash heap after `unset`.
- Hiding `/proc/self/environ`.
- Multi-user access control.
- Master password.
- Rewriting in another language.

## Suggested order

1. O3 denylist additions (small, high confidence).
2. O2 clear `_EM_UI_INTERRUPTED`.
3. O1 always restore echo; do not clobber parent traps.
4. O4 nameref check on update.
5. Tests for O1–O4.

## Acceptance

- `bash -n env-manager.sh` and `bash tests/env-manager-test.sh` pass.
- Direct execution still fails with the source hint.
- Each open item has a code change or a written reason it is invalid.
- Closed F1/F2/F4 behavior above still holds.
- Parent INT/TERM traps are not replaced.
- `email` remains a legal variable name.
