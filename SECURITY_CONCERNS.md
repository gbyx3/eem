# SECURITY_CONCERNS.md

Review target: `env-manager.sh` (sourced Bash TUI; ephemeral env-var manager).
Tests: `tests/env-manager-test.sh`.
Do not treat this file as a patch. It is a review brief.

## Reviewer instructions

You are reviewing an existing implementation, not writing a new one from scratch.

1. Read `env-manager.sh` and `tests/env-manager-test.sh` in full before changing anything.
2. Confirm or refute each finding below against the current code. Cite the function and the exact check or missing check.
3. Fix confirmed findings. Do not "fix" items you can show are already handled.
4. Keep the sourced-script contract: the file must remain `source`-only, must still restore prior value/export state, and must not persist secrets to disk.
5. Do not add a disk-backed secret store, encryption, or a daemon. That is out of scope.
6. Add or extend tests in `tests/env-manager-test.sh` for every behavioral fix. The current suite does not cover the cases in this document.
7. After edits, `bash tests/env-manager-test.sh` must pass.
8. Do not rewrite the TUI unless a finding requires it.

Scope limits:

- This tool runs in an already-trusted interactive user shell. Do not try to defend against a fully compromised user account.
- Do defend against: accidental overwrite of shell-critical names, nameref write-through, terminal escape injection from user-supplied strings, interrupt leaving the tty unusable, and UI commands being hijacked via `PATH`.
- "Secret" in this program means "mask in the list view + `read -s`". Do not claim encryption. You may document residual exposure; you do not need to eliminate `/proc/<pid>/environ` visibility.

## Program contract (do not break)

- Must be sourced. Direct execution must refuse and exit.
- Requires Bash 4+.
- Public API used by tests: `em_set`, `em_delete_key`, `em_delete_app`, `em_delete_all`, `_em_app_prefix`, `_em_list`, `_em_add_menu`.
- `em_set APP KEY VALUE SECRET` exports `KEY=VALUE` and records metadata so delete can restore the pre-management state.
- `SECRET` is `0` or `1`. Listings must mask `1`.
- Re-sourcing must not wipe in-memory session maps (`_EM_APP`, `_EM_SECRET`, `_EM_ORIGINAL_*`, order arrays).
- Variable names must remain valid shell identifiers: `^[A-Za-z_][A-Za-z0-9_]*$`.
- No `eval`. Assign with `printf -v` / `export` / `unset` on a validated name only.
- No persistence to disk.

## Findings

Each item is independently actionable. Severity is for triage, not a request to inflate the design.

### F1 — Dangerous variable names are accepted

Severity: high
Where: `em_set` (validation is only `_em_valid_key`)
Problem: Any valid identifier can be managed, including names that change shell or child-process security:

- `PATH`, `CDPATH`
- `IFS`
- `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`
- `BASH_ENV`, `ENV`
- `PROMPT_COMMAND`, `PS0`, `PS1`, `PS2`, `PS4`
- `HISTFILE`, `HISTCONTROL`
- `HOME`, `SHELL`, `USER`
- `SHELLOPTS`, `BASHOPTS`, `BASH_XTRACEFD`
- the script's own `_EM_*` scalars (`_EM_UI_ACTIVE`, `_EM_UI_LEFT`, `_EM_FRAME_WIDTH`, `_EM_FRAME_PADDING`)

`PATH` is additionally a live UI hazard: `_em_screen` calls `tput` and `tr` without `command` or an absolute path. If the user sets `PATH` from the menu, later draws can execute attacker-controlled binaries.

Required change:

- Reject a denylist of shell-critical and loader-critical names in `em_set` (case-sensitive exact match).
- Also reject any name that is already used as this script's metadata (`_EM_*` and public `em_*` / `env_manager` identifiers you do not want overwritten).
- Keep the identifier regex. The denylist is in addition to it, not a replacement.
- Call `tput` and `tr` via `command tput` / `command tr` so a later `PATH` change cannot retarget UI helpers even if a denylist hole remains.

Tests to add:

- `em_set app PATH /tmp 0` fails and does not change `PATH`.
- `em_set app LD_PRELOAD /tmp/x.so 0` fails.
- `em_set app PROMPT_COMMAND 'id' 0` fails.
- `em_set app _EM_UI_ACTIVE 1 0` fails.
- A normal name such as `OPENAI_API_KEY` still succeeds.

### F2 — Namerefs (`declare -n`) are not rejected

Severity: high
Where: `em_set`, the `declare -p` flag check:

```bash
if [[ $declaration =~ ^declare\ -[^\ ]*[arA] ]]; then
```

Problem: That regex rejects arrays (`a`), read-only (`r`), and associative arrays (`A`). It does not reject namerefs (`n`). `printf -v "$key"` on a nameref writes through to the referenced variable (for example a name `foo` that points at `PATH`).

Required change:

- Treat nameref the same as array/read-only: refuse to manage it.
- Prefer parsing `declare -p` flags in a way that cannot miss `n` if flags are reordered (do not assume `-n` is the only flag or that `n` appears in a fixed position).

Tests to add:

- Create `declare -n EM_TEST_REF=PATH` (or another throwaway target), call `em_set`, assert failure, assert the target variable is unchanged, then unset the nameref.

### F3 — No trap to restore the terminal

Severity: medium
Where: `_em_ui_start`, `_em_ui_stop`, `_em_read` (`read -s`), `env_manager`
Problem:

- Alternate screen is enabled with `\033[?1049h` and only disabled on a clean `_em_ui_stop`.
- Secret input uses `read -s`, which disables terminal echo.
- There is no `EXIT` / `INT` / `TERM` trap. Ctrl-C during the menu can leave the user in the alternate screen. Ctrl-C during `read -s` can leave echo off (`stty -echo`).

Required change:

- Install traps when the UI starts; always restore alternate screen and echo on exit, interrupt, or return from `env_manager`.
- Do not leave traps that affect the parent shell after a normal menu exit. Restore prior trap state or use a scoped pattern appropriate for a sourced script.
- A sourced script must not `exit` the user's shell from a trap on a clean return. Use `return` from `env_manager` / `_em_ui_stop` as you do today.

Tests:

- Automated tests cannot easily assert tty state. Add a comment in code near the trap documenting the restore obligations, and manually reason about: UI start → trap set → `_em_ui_stop` → trap cleared; and UI start → simulated INT path → screen/echo restore functions still run.
- If you can unit-test the restore helpers without a tty, do so. Do not skip the trap because tests are hard.

### F4 — User-controlled strings are printed raw to the terminal

Severity: medium
Where: `_em_screen`, `_em_list`, any path that prints application names or non-secret values
Problem: Application names and values are not stripped of `ESC` (0x1b), `CR`, or other C0/C1 control characters. A value or app name can inject CSI/OSC sequences, move the cursor, spoof the frame, or (on some terminals) trigger OSC handlers. Newlines in an application name also break the one-app-per-section listing.

Required change:

- Sanitize strings before they are drawn or listed. Strip or replace ASCII control characters (at least `ESC`, `CR`, `NEL`, and C1). Decide whether a newline in an application name is rejected at input time or flattened for display; do not let it break grouping.
- Do not alter the stored value of a secret or non-secret variable — sanitize for display only, unless you also reject controls at `em_set` / app-name input. Prefer reject-at-input for application names; display-sanitize for values.
- Keep wrapping based on visible/printable width after sanitizing, not on raw byte length that includes escapes.

Tests to add:

- Application name containing `$'\e[31m'` does not appear with a raw ESC in `_em_list` / screen output (or is rejected).
- Non-secret value containing CSI does not leak ESC into `_em_list` output (or is rejected by `em_set`).
- A legitimate value with spaces and punctuation still lists correctly.

### F5 — Session-wide export is easy to over-share

Severity: low (design; document + optional guard, do not redesign)
Where: `em_set` always `export`s
Problem: There is no `KEY=value command` scope. After the menu exits, every subsequent process in that shell inherits every managed secret.

Required change:

- Do not add a wrapper-exec mode unless it is a small, obvious extra menu option. Default behavior stays "export into this shell".
- If you add anything, add a one-line warning on the main menu or on secret save: secrets are inherited by all child processes of this shell.
- README already states this. Do not expand the README unless you add new user-visible behavior.

### F6 — Re-source replaces functions from whatever is on disk

Severity: low
Where: top-level re-source; maps are preserved, functions are redefined
Problem: A second `source ./env-manager.sh` keeps `_EM_*` maps but reloads function bodies from the current file. A replaced file can redefine `em_set` / `_em_restore_key` while secrets are still in memory.

Required change:

- Optional only. Acceptable mitigations: refuse to redefine functions if maps are already populated, or warn on re-source that the file will be re-read.
- Do not add signature checking or a package manager.

### F7 — Tests do not cover hostile cases

Severity: medium (process)
Where: `tests/env-manager-test.sh`
Problem: Current tests cover prefix normalization, assign/restore/export flags, and secret masking. They do not cover F1–F4.

Required change:

- Extend the existing test file. Do not add a second framework.
- Keep the `source "$ROOT/env-manager.sh" <<< 'E'` pattern so the auto-started menu exits.
- Clean up every test variable you create.

## Out of scope (do not implement)

- Encrypting values in memory or on disk.
- Wiping Bash heap/swap after `unset`.
- Preventing a local user from reading their own `/proc/self/environ`.
- Multi-user access control.
- Prompting for a master password.
- Rewriting the program in another language.

## Suggested implementation order

1. F2 nameref reject (small, high confidence).
2. F1 denylist + `command tput` / `command tr`.
3. F4 display/input sanitization.
4. F3 trap + tty restore.
5. Tests for F1, F2, F4 (and F3 helpers if testable).
6. F5 warning only if you touch the main menu anyway.
7. F6 only if it is a few lines and does not break re-open-the-menu.

## Acceptance

- `bash tests/env-manager-test.sh` passes.
- Confirmed findings have a code change or an explicit written reason they are invalid.
- Sourced usage, restore-on-delete, secret masking, and no-disk persistence still hold.
- Direct execution of `env-manager.sh` still fails with the source hint.
