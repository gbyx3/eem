# Ephemeral Environment Manager

Interactively export environment variables for the current Bash shell without
storing them on disk. Variables are grouped by application/system for listing
and deletion. Values marked as secrets are hidden in listings.

## Usage

The script must be sourced so it can modify the current shell:

```bash
source ./env-manager.sh
```

In an interactive terminal, the manager uses the terminal's alternate screen
and centers each view. Menus redraw in place without adding to normal shell
scrollback, and the original terminal screen is restored when the menu exits.
Every view uses a fixed-width ASCII frame; long names and values wrap within
the frame instead of resizing it.

OpenCode or Grok can be launched directly from the main menu after configuring
the environment. The manager returns when the application exits. Alternatively,
choose **Exit menu** and start an application from the same shell:

```bash
opencode
```

Managed variables remain active until they are deleted through the menu or the
shell closes. Source the script again to reopen the menu.

When adding variables, choose whether to export the original variable name or
prefix it with the normalized application name. For example, application
`Open Code` and variable `TOKEN` produce either `TOKEN` or
`EM_OPEN_CODE_TOKEN`. Original names are recommended when an application
expects a specific environment variable such as `OPENAI_API_KEY`.

Shell-critical names such as `PATH`, `LD_PRELOAD`, and `PROMPT_COMMAND` cannot
be managed directly. A prefixed final name such as `EM_OPENCODE_PATH` remains
allowed because it does not alter Bash or child-process startup behavior.

Use **Add or update variables** with the same application name to append more
variables. Entering an existing variable name offers to replace its current
managed value while preserving the original shell value for later restoration.

Deleting a variable restores the value and export state it had before the
script first managed it. **Delete All** only restores variables managed by this
script; it does not affect unrelated environment variables.

Secret input is hidden from the terminal and masked when listed. Environment
variables are still visible to the current user and inherited child processes;
the secret option is not encryption.

## Tests

```bash
bash tests/env-manager-test.sh
```
