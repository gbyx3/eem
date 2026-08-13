# SECURITY_ADDRESSED.md

Response to: `SECURITY_CONCERNS.md`

Security-fix commit: `258511d` (`Harden environment and terminal handling`)

Review targets:

- `env-manager.sh`
- `tests/env-manager-test.sh`
- `README.md`

This is a validation brief, not proof that the implementation is correct and
not a request to accept the fixes without inspection.

## Instructions for the reviewing LLM

1. Read `SECURITY_CONCERNS.md`, `env-manager.sh`, and
   `tests/env-manager-test.sh` in full.
2. Independently verify every claim below against the current code. Cite the
   relevant function and exact check when confirming or refuting a claim.
3. Run the listed tests and adversarial checks. Do not rely only on the existing
   test assertions.
4. Look for bypasses, regressions, Bash dynamic-scope issues, quoting errors,
   trap leakage, and behavior that violates the original program contract.
5. Report findings before proposing changes. Do not edit files unless the user
   explicitly asks for fixes after reviewing your findings.
6. Distinguish findings introduced by commit `258511d` from unrelated current
   worktree changes. Use `git show 258511d` and `git diff 258511d --` as needed.

Expected program contract remains:

- The script is source-only and direct execution refuses.
- It requires Bash 4+.
- Managed variables are exported into the current shell only.
- Deleting managed variables restores their original value and export state.
- Secret values are hidden during input and masked in listings.
- No values or secrets are persisted to disk.
- Re-sourcing preserves the in-memory management maps.

## Summary of implemented response

F1 through F4 were treated as confirmed. F7 was addressed by extending the
existing test file. F5 and F6 were intentionally not changed because they were
outside the requested F1-F4 implementation scope.

One additional defect was found while validating F1: Bash functions use dynamic
scope, so the old `printf -v "$key"` could target a local variable in `em_set`
when a requested key matched a local name such as `value`. The fix includes
explicit global assignment and a regression test for this case.

## F1 - Dangerous variable names

Status claimed: addressed.

### Implementation

- `_em_safe_key` contains a case-sensitive denylist for shell-critical,
  loader-critical, Bash special-state, and script-owned names.
- It rejects exact critical names including `PATH`, `LD_PRELOAD`,
  `PROMPT_COMMAND`, and families matching `_EM_*`, `_em_*`, and `em_*`.
- `em_set` first retains `_em_valid_key` identifier validation and then calls
  `_em_safe_key` on the final exported name.
- Prefixing remains usable: `PATH` is rejected, while a non-special final name
  such as `EM_OPENCODE_PATH` is allowed.
- Assignment now uses `declare -gx -- "$2=$3"`. This explicitly targets the
  global scope and avoids assignment to a dynamically scoped local variable.
- Restoration uses `declare -gx` for originally exported values and
  `declare -g +x` for originally non-exported values.
- `_em_screen` no longer executes `tput` or `tr`. It uses validated `COLUMNS`
  and `LINES` values and a Bash loop for vertical spacing.
- Terminal echo restoration uses `/usr/bin/stty` or `/bin/stty`, not a
  PATH-resolved executable.

### Existing regression coverage

`tests/env-manager-test.sh` checks:

- `PATH` is rejected and its original value remains unchanged.
- `LD_PRELOAD`, `PROMPT_COMMAND`, and `_EM_UI_ACTIVE` are rejected.
- `OPENAI_API_KEY` remains allowed.
- A key named `value` becomes a global managed variable and can be deleted.

### Reviewer checks

Confirm at minimum:

```bash
bash -c 'source ./env-manager.sh <<< E; old=$PATH; ! em_set app PATH /tmp 0; [[ $PATH == "$old" ]]'
bash -c 'source ./env-manager.sh <<< E; em_set app EM_APP_PATH safe 0; [[ $EM_APP_PATH == safe ]]; em_delete_all'
bash -c 'source ./env-manager.sh <<< E; unset value; em_set app value global 0; [[ $value == global ]]; em_delete_key value; [[ ! -v value ]]'
```

Audit the denylist for important omissions and overbroad patterns. In
particular, verify that rejecting script function-name patterns does not block
ordinary application variables unexpectedly.

## F2 - Nameref write-through

Status claimed: addressed.

### Implementation

- `em_set` obtains the declaration using `declare -p`.
- It extracts the complete declaration flag group rather than relying on a
  fixed flag position.
- `[[ $_em_flags == *[aArn]* ]]` rejects indexed arrays (`a`), associative
  arrays (`A`), read-only variables (`r`), and namerefs (`n`).
- Rejection occurs before original-state metadata or assignment is performed.

### Existing regression coverage

The test suite creates `EM_TEST_REF` as a nameref to a throwaway target,
asserts that `em_set` fails, and verifies that the target remains unchanged.

### Reviewer checks

```bash
bash -c '
  source ./env-manager.sh <<< E
  target=unchanged
  declare -n EM_TEST_REF=target
  ! em_set app EM_TEST_REF changed 0
  [[ $target == unchanged ]]
'
```

Also test namerefs carrying additional declaration flags if the local Bash
version permits such combinations. Confirm that flag parsing is independent of
flag order.

## F3 - Terminal restoration after interrupt

Status claimed: addressed, with an explicit parent-trap compatibility choice.

### Implementation

- `_em_ui_start` installs `INT` and `TERM` traps before entering the alternate
  screen.
- If the parent shell already has an `INT` or `TERM` trap, `_em_ui_start` does
  not overwrite it and does not enter the alternate screen. The menu falls back
  to plain output for that invocation.
- `_em_ui_interrupt` marks the UI interrupted and calls
  `_em_ui_restore_terminal`.
- `_em_ui_restore_terminal` restores terminal echo through an absolute `stty`
  path, exits the alternate screen when active, and clears `_EM_UI_ACTIVE`.
- `_em_read` returns status 130 after an interrupt; enclosing loops observe
  `_EM_UI_INTERRUPTED` and unwind.
- `env_manager` always reaches `_em_ui_stop` after the loop unwinds.
- `_em_ui_stop` performs defensive restoration and removes only traps installed
  by this script, tracked by `_EM_UI_TRAPS`.
- No interrupt trap calls `exit`, so sourcing does not terminate the parent
  shell.

### Existing regression coverage

The test suite installs the same script-owned traps, invokes `_em_ui_stop`, and
asserts that both traps and the ownership flag are cleared.

This test does not fully prove real TTY behavior.

### Manual pseudo-terminal check used during implementation

The following pattern was used to deliver `SIGINT` while the menu was waiting:

```bash
TERM=xterm script -qec 'bash -c '\''
  (sleep 0.2; kill -INT $$) &
  source ./env-manager.sh
  printf "SURVIVED:%s:%s\n" "$_EM_UI_ACTIVE" "$(trap -p INT)"
'\''' /dev/null
```

Observed result at implementation time:

- The alternate screen exit sequence was emitted.
- The shell continued and printed `SURVIVED:0:`.
- No `INT` trap remained.

### Reviewer checks

Repeat real pseudo-terminal tests for:

- `SIGINT` at the main menu.
- `SIGTERM` at the main menu.
- `SIGINT` specifically during secret `read -s` input.
- Normal `E` exit.
- A parent shell with a pre-existing `INT` or `TERM` trap.

Verify after every path that echo is enabled, the normal screen is restored,
the shell remains alive where appropriate, and no script-owned trap remains.
Pay particular attention to race windows between trap installation and
alternate-screen activation.

## F4 - Terminal escape and control-character injection

Status claimed: addressed for application names and all strings rendered
through `_em_screen` or `_em_list`.

### Implementation

- `_em_sanitize_display` removes C0 controls, DEL, and C1 controls from display
  strings while preserving printable characters.
- `_em_valid_app` requires a non-empty application name whose sanitized form is
  byte-for-byte equal to the input. Application names containing controls,
  including newline, carriage return, or ESC, are rejected.
- `em_set` enforces `_em_valid_app`, so the public API cannot bypass the
  interactive validation.
- `_em_add_menu` uses the same validation.
- `_em_list` sanitizes application labels and non-secret values before output.
- `_em_screen` sanitizes every supplied content line before width calculation,
  wrapping, and terminal rendering. Wrapping therefore uses sanitized text.
- The exported value itself is not modified. Sanitization is display-only.
- Secret values remain replaced entirely with `********` in `_em_list`.

### Existing regression coverage

The test suite checks:

- An application name containing ESC is rejected.
- A non-secret value containing ESC and carriage return produces listing output
  with neither raw control character.
- Printable spaces and punctuation remain visible.
- The actual exported value remains exactly equal to the original input,
  including its control characters.

### Reviewer checks

Test at least ESC/CSI, OSC with BEL and ST terminators, CR, LF, TAB, DEL, NEL,
and C1 CSI. Inspect raw output bytes rather than relying only on terminal
appearance. Confirm both `_em_list` plain output and `_em_screen` TTY rendering.

Example starting point:

```bash
bash -c '
  source ./env-manager.sh <<< E
  value=$'\''plain\e]0;spoof\a text\rmore'\''
  em_set app EM_TEST_DISPLAY "$value" 0
  output=$(_em_list)
  [[ $output != *$'\''\e'\''* && $output != *$'\''\r'\''* && $output != *$'\''\a'\''* ]]
  [[ $EM_TEST_DISPLAY == "$value" ]]
  em_delete_all
'
```

Review locale and Unicode behavior carefully. The sanitizer intentionally
targets terminal controls; it is not a complete grapheme-width implementation.

## F7 - Hostile-case test coverage

Status claimed: partially addressed as required for F1-F4.

The existing single-file test harness was extended rather than replaced. It now
covers critical-name denial, unchanged `PATH`, normal-name acceptance, global
assignment, nameref rejection, application control rejection, display
sanitization, exact stored-value preservation, and cleanup of script-owned
traps.

Run:

```bash
bash -n env-manager.sh
bash -n tests/env-manager-test.sh
bash tests/env-manager-test.sh
bash env-manager.sh; test $? -eq 1
```

Expected results:

- Syntax checks succeed.
- The test suite prints `All tests passed.`
- Direct execution prints the source hint and returns status 1.

## Intentionally unchanged items

### F5 - Session-wide inheritance

No command-scoped execution mode was added. Exporting into the current shell is
the explicit purpose of the tool. The README continues to state that child
processes inherit these variables and that the secret option is not encryption.

### F6 - Re-source reloads function bodies

No re-source integrity mechanism was added. The in-memory maps remain preserved
as required. Protecting against a maliciously replaced file in an already
trusted user shell was judged outside the F1-F4 request and the stated scope.

## Residual risks and review focus

- The denylist is policy-based and may omit a Bash or platform-specific special
  variable. Look for concrete missing names with security or shell-integrity
  impact.
- Falling back to plain UI when parent traps exist preserves those traps but
  changes presentation for that invocation. Confirm this is acceptable and
  does not introduce another cleanup path.
- Terminal restoration depends on `/usr/bin/stty` or `/bin/stty` being present.
  The alternate-screen escape is still restored without `stty`, but echo cannot
  be explicitly repaired if neither path exists.
- Sanitization removes controls but leaves printable bytes that followed an
  escape, for example ESC is removed from `ESC [ 31 m`. This prevents terminal
  interpretation; it does not attempt to produce aesthetically clean text.
- Unicode display width can differ from Bash character count. This can affect
  border alignment but should not permit raw terminal-control injection.
- Environment variables remain visible to child processes and potentially via
  process inspection under the same user account. This is accepted by scope.

## Requested reviewer output

Return findings first, ordered by severity, with file and line references.

For each original finding F1-F4, state exactly one of:

- `CONFIRMED FIXED`
- `PARTIALLY FIXED`
- `NOT FIXED`
- `REGRESSION INTRODUCED`

Include:

- Any bypass or newly discovered issue.
- Commands used to reproduce it.
- Whether the program contract remains intact.
- Test gaps that matter materially.
- A short final recommendation: accept, revise, or reject commit `258511d`.

Do not report purely stylistic preferences as security findings.
