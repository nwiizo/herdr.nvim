# Verification

Run `make check` and `git diff --check` before a commit. CI uses Neovim 0.10.4 and stable, StyLua 2.5.2, and Luacheck 1.2.0 with Lua 5.1. Unit tests use a clean Neovim and clear inherited `HERDR_ENV`; the cross-Space test supplies its own mocked context. Tests make no authenticated AI requests.

When `act` and Docker are available, also run the CI job locally as described in [AGENTS.md](../AGENTS.md). Native macOS tests do not reproduce the Linux runner.

## Disposable Herdr TUI smoke test

`tests/tui_smoke.lua` exercises real Herdr CLI reads and a controlled shell reported as an agent. It checks output pause/resume, a native Neovim yank, continuing state updates, float resize and focus, return to the editor, and agent persistence. It closes only the workspace it creates. It refuses a socket outside the supplied test directory; run it against a fresh test server, never your working session.

From the plugin checkout, prepare an isolated home and config:

```sh
tui_test_root=$(rtk proxy mktemp -d /tmp/herdr-nvim-tui.XXXXXX)
rtk proxy mkdir -p "$tui_test_root/home" "$tui_test_root/config" "$tui_test_root/state"
rtk proxy tee "$tui_test_root/config.toml" <<'TOML'
onboarding = false
[terminal]
default_shell = "/bin/sh"
shell_mode = "non_login"
[update]
version_check = false
manifest_check = false
[ui.sound]
enabled = false
[ui.toast]
delivery = "off"
[session]
resume_agents_on_restore = false
TOML

rtk proxy env -u HERDR_ENV HOME="$tui_test_root/home" \
  XDG_CONFIG_HOME="$tui_test_root/config" XDG_STATE_HOME="$tui_test_root/state" \
  HERDR_CONFIG_PATH="$tui_test_root/config.toml" \
  HERDR_SOCKET_PATH="$tui_test_root/herdr.sock" \
  herdr server >"$tui_test_root/server.log" 2>&1 &
```

After the log reports the test socket, run:

```sh
rtk proxy env HOME="$tui_test_root/home" \
  XDG_CONFIG_HOME="$tui_test_root/config" XDG_STATE_HOME="$tui_test_root/state" \
  HERDR_CONFIG_PATH="$tui_test_root/config.toml" \
  HERDR_SOCKET_PATH="$tui_test_root/herdr.sock" HERDR_NVIM_TEST_ROOT="$tui_test_root" \
  nvim --headless --clean -u tests/minimal_init.lua -l tests/tui_smoke.lua
```

Success prints `TUI_SMOKE_OK`. To verify your actual UI, copy your Neovim config into separate HOME/XDG directories and reuse installed dependencies without updating or building them. Point `HERDR_SOCKET_PATH`, `HERDR_CONFIG_PATH`, and `HERDR_NVIM_TEST_ROOT` at the same test server. Run native Neovim with `-i NONE '+lua dofile("tests/tui_smoke.lua")'` from this checkout. This exercises the configured UI provider and the same assertions without provider credentials or inference.

Stop only the disposable server after the test, including when it fails:

```sh
rtk proxy env HERDR_SOCKET_PATH="$tui_test_root/herdr.sock" herdr server stop
```

Keep failed-test logs outside Git. The test covers plugin behavior with controlled state reports; it does not validate an AI provider's screen detection.

## Disposable saved-machine smoke test

`tests/machine_smoke.lua` exercises watched saved machines through real `herdr --machine` forwarding without a second host. A test-only `ssh` runs the remote command locally under a separate remote `HOME`, as Herdr's own machine API tests do. The script checks merged attention, qualified targets, remote notification, preview, rename, prompt and start routing, offline isolation and retry, and remote session attach with return to the same agent. It closes only the workspaces it creates.

Use a short directory, because macOS limits Unix socket paths to 104 bytes. The setup uses `herdr machine add`, so the remote server starts the way a real saved machine does:

```sh
machine_test_root=$(rtk proxy mktemp -d /tmp/hnm.XXXXXX)
rtk proxy mkdir -p "$machine_test_root/home" "$machine_test_root/config" "$machine_test_root/state" \
  "$machine_test_root/bin" "$machine_test_root/remote bin" \
  "$machine_test_root/rhome/.config" "$machine_test_root/rhome/.state" "$machine_test_root/rhome/project"
rtk proxy tee "$machine_test_root/bin/ssh" <<'SH'
#!/bin/sh
# Test-only ssh: runs the requested remote command locally with a separate remote HOME.
for arg do last=$arg; done
if [ -e "$TEST_ROOT/offline" ]; then echo 'test remote connection failed' >&2; exit 255; fi
export PATH="$TEST_ROOT/remote bin:/usr/bin:/bin" HOME="$TEST_ROOT/rhome" \
  XDG_CONFIG_HOME="$TEST_ROOT/rhome/.config" XDG_STATE_HOME="$TEST_ROOT/rhome/.state"
unset HERDR_SOCKET_PATH HERDR_SESSION HERDR_PANE_ID HERDR_ENV
case "$last" in
  '/bin/sh -s') exec /bin/sh -s ;;
  *) exec /bin/sh -c "$last" ;;
esac
SH
rtk proxy chmod 700 "$machine_test_root/bin/ssh"
rtk proxy ln -s "$(command -v herdr)" "$machine_test_root/remote bin/herdr"
```

Write the same `config.toml` as the TUI smoke test into `$machine_test_root/config.toml`. Then run every command below from the plugin checkout in a clean environment, which keeps your real Herdr session, socket, and saved machines out of reach:

```sh
machine_env() {
  rtk proxy env -i PATH="$machine_test_root/bin:$(dirname "$(command -v herdr)"):/usr/bin:/bin" \
    HOME="$machine_test_root/home" XDG_CONFIG_HOME="$machine_test_root/config" \
    XDG_STATE_HOME="$machine_test_root/state" HERDR_CONFIG_PATH="$machine_test_root/config.toml" \
    HERDR_SOCKET_PATH="$machine_test_root/local.sock" TEST_ROOT="$machine_test_root" \
    HERDR_NVIM_MACHINE_TEST_ROOT="$machine_test_root" TERM=xterm-256color "$@"
}
machine_env herdr server >"$machine_test_root/server.log" 2>&1 &
machine_env herdr machine add fake-mac --label fake --remote-session fleet </dev/null
machine_env nvim --headless --clean -u tests/minimal_init.lua -l tests/machine_smoke.lua
```

Success prints `MACHINE_SMOKE_OK`. For the actual UI, follow the same isolated-config approach as the TUI smoke test, keep this environment's `HOME`, XDG state, and Herdr variables, and trigger `UIEnter` before opening pickers so a lazy-loaded UI provider replaces `vim.ui.select`. Stop both disposable servers afterward, including after a failure:

```sh
machine_env herdr --machine fake server stop
machine_env herdr server stop
```

The machine smoke test does not cover real SSH authentication, network latency, or a remote host's own Herdr installation. Check those with `:checkhealth herdr` against a real saved machine.
