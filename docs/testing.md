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
