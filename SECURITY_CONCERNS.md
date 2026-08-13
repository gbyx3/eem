# SECURITY_CONCERNS.md

Living review brief for `env-manager.sh`. Written for an implementing LLM
(OpenCode). It is not a patch.

## Verdict

Accept `748aefd` (`Complete security hardening follow-ups`) as closing the
O1–O5 work queue from `eeb33a5`. Do not re-implement closed items. Do not
open a new hardening pass unless the user asks.

| ID | Status |
|---|---|
| F1 | CLOSED |
| F2 | CLOSED |
| F3 | CLOSED (O1/O2 closed the remaining holes) |
| F4 | CLOSED |
| F5 | UNCHANGED (leave it) |
| F6 | UNCHANGED (leave it) |
| F7 / O5 | CLOSED for the requested cases |
| O1 | CLOSED |
| O2 | CLOSED |
| O3 | CLOSED |
| O4 | CLOSED |

Audited commits:

- `258511d` Harden environment and terminal handling
- `748aefd` Complete security hardening follow-ups

Live checks (Bash 5.3): `bash tests/env-manager-test.sh` passed. Direct
execution exits 1 with the source hint. Restore-on-delete, secret masking,
and no-disk still hold.

## Instructions

If you are asked to continue security work, treat **Residuals** as optional
and only implement items the user names. Do not reopen F1–F4 or O1–O4 from
scratch.

Keep the sourced-script contract. No disk-backed secret store, encryption,
or daemon. Do not add a second test framework.

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
- `email` remains a legal variable name. Do not block it.

## What landed

### F1 / O3 — name denylist

`_em_safe_key` rejects the original shell/loader set plus `GCONV_PATH`,
`GLIBC_TUNABLES`, `LOCPATH`, `NLSPATH`, `BASH_LOADABLES_PATH`, `LANG`,
`LC_*`, `COLUMNS`, and `LINES`. Identifier regex is still required first.
`tput`/`tr` are gone. Assignment is `declare -gx`. TUI locals were renamed
into `_em_*` so they cannot shadow a managed key.

Still allowed by design: `email`, `EM_APP_PATH`, `OPENAI_API_KEY`, bare `LC`.

### F2 / O4 — nameref and attributes

`_em_safe_attributes` parses the whole `declare -p` flag group (`*[aArn]*`)
on every `em_set` and on `_em_restore_key`. First insert, update, and
restore all refuse arrays, read-only variables, and namerefs without
writing through. After the caller removes the incompatible declaration,
delete can restore the original state.

### F3 / O1 / O2 — terminal restore

- `_em_ui_start` clears `_EM_UI_INTERRUPTED` before any early return.
- On a tty it snapshots `stty -g` into `_EM_TTY_STATE` before the
  parent-trap check.
- Parent `INT`/`TERM` traps are not replaced. That path stays on the
  plain UI.
- Silent `read` restores `_EM_TTY_STATE` immediately afterward.
- `_em_ui_restore_terminal` applies the snapshot whenever it is set; it
  is not gated on `_EM_UI_ACTIVE` / `_EM_UI_TRAPS`.
- `_em_ui_stop` restores, removes only script-owned traps, and clears
  `_EM_UI_INTERRUPTED` and `_EM_TTY_STATE`.
- Traps do not `exit` the parent shell.

Verified: parent INT trap left unchanged; echo on; saved TTY mode matched
after menu exit. Official tests mock `_em_stty` and assert the restore
gate plus parent-trap preservation.

### F4 — display sanitization

`_em_sanitize_display` strips C0, DEL, and C1. `_em_valid_app` rejects
names that change under sanitizing. `_em_list` / `_em_screen` sanitize
before wrap/print. Environment values are not rewritten.

### Tests

`tests/env-manager-test.sh` covers original F1/F2/F4 cases, O3 names,
`email` / `EM_APP_PATH` positives, first-insert and update namerefs,
restore refusal through a nameref, `_em_ui_stop` restore/trap/flag
cleanup, and `_em_ui_start` clearing the interrupt flag without
replacing a parent INT trap.

## Residuals (do not implement unless asked)

- No `EXIT` trap. A hard `exit` mid-menu can skip `_em_ui_stop`.
- If the parent owns `INT` or `TERM`, this script owns neither. Default
  `TERM` can still kill the shell on that path.
- A managed name later made read-only cannot be restored until the
  caller drops `-r`. Refuse-to-corrupt is intentional.
- `_em_list` can *display* through a replacement nameref (read, not
  write).
- Printable leftovers after ESC is stripped (`[31m`). U+202E bidi
  override is kept.
- Session-wide export (F5) and re-source function reload (F6) are
  product behavior.

## Out of scope

- Encrypting values in memory or on disk.
- Wiping the Bash heap after `unset`.
- Hiding `/proc/self/environ`.
- Multi-user access control.
- Master password.
- Rewriting in another language.

## Acceptance (met)

- `bash -n env-manager.sh` and `bash tests/env-manager-test.sh` pass.
- Direct execution fails with the source hint.
- Closed F1–F4 and O1–O4 behavior above holds.
- Parent INT/TERM traps are not replaced.
- `email` remains a legal variable name.
