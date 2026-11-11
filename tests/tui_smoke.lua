-- Opt-in integration test; requires a disposable Herdr TUI server. See docs/testing.md.
local test_root = assert(vim.env.HERDR_NVIM_TEST_ROOT, "set HERDR_NVIM_TEST_ROOT")
assert(test_root:match("^/tmp/herdr%-nvim%-tui%.[%w]+$"), "use a fresh /tmp/herdr-nvim-tui.XXXXXX directory")
assert(vim.env.HERDR_SOCKET_PATH == test_root .. "/herdr.sock", "refusing to use a shared Herdr socket")
local workspace
local client = require("herdr.client")
local board = require("herdr.board")
local state = require("herdr.state")

local function cli(args)
  local argv = { "herdr" }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(10000)
  assert(result.code == 0, result.stderr)
  if args[1] == "workspace" and args[2] == "create" then
    return vim.json.decode(result.stdout).result
  end
end

local function await(action)
  local done, value, failure
  action(function(result, err)
    value, failure, done = result, err, true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 20),
    "callback timed out"
  )
  assert(not failure, vim.inspect(failure))
  return value
end

local function refresh()
  await(function(callback)
    state.refresh({ explicit = true }, function(ok, result)
      callback(ok and result, not ok and result or nil)
    end)
  end)
end

local function run()
  require("herdr").setup({ auto_start_server = false, refresh = { board_ms = 60000, background_ms = 60000 } })
  vim.cmd("runtime plugin/herdr.lua")
  local created = cli({ "workspace", "create", "--cwd", test_root, "--label", "nvim-smoke", "--no-focus" })
  workspace = created.workspace.workspace_id
  local pane = created.root_pane.pane_id
  cli({ "pane", "run", pane, "printf 'HERDR_PREVIEW_FIRST\\n'" })
  cli({ "pane", "wait-output", pane, "--match", "HERDR_PREVIEW_FIRST", "--timeout", "3000" })
  cli({
    "pane",
    "report-agent",
    pane,
    "--source",
    "nvim-smoke",
    "--agent",
    "claude",
    "--state",
    "working",
    "--seq",
    "1",
  })
  refresh()
  local selected
  for _, agent in ipairs(state.agents()) do
    if agent.pane_id == pane then
      selected = agent
    end
  end
  assert(selected, "reported test agent missing")
  local origin = vim.api.nvim_get_current_win()
  board.open({ terminal_id = selected.terminal_id })
  local list_window = vim.fn.bufwinid(board._buffer())
  local preview_window = vim.fn.bufwinid(board._preview_buffer())
  board.refresh_preview({ force = true })
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(board._preview_buffer(), 0, -1, false), "\n")
  end
  assert(vim.wait(5000, function()
    return text():find("HERDR_PREVIEW_FIRST", 1, true)
  end, 20))
  vim.api.nvim_set_current_win(preview_window)
  vim.fn.maparg("P", "n", false, true).callback()
  local frozen = text()
  vim.cmd('normal! "zyy')
  local copied = vim.fn.getreg("z")
  assert(#copied > 0, "native yank failed")
  local cursor = vim.api.nvim_win_get_cursor(preview_window)
  cli({ "pane", "run", pane, "printf 'HERDR_PREVIEW_SECOND\\n'" })
  cli({ "pane", "wait-output", pane, "--match", "HERDR_PREVIEW_SECOND", "--timeout", "3000" })
  cli({
    "pane",
    "report-agent",
    pane,
    "--source",
    "nvim-smoke",
    "--agent",
    "claude",
    "--state",
    "blocked",
    "--seq",
    "2",
  })
  refresh()
  board.refresh_preview({ force = true })
  assert(text() == frozen and vim.fn.getreg("z") == copied, "paused text changed")
  assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(preview_window)), "paused cursor moved")
  assert(state.agent(selected.terminal_id).status == "blocked", "state polling stopped with preview")
  local before = vim.api.nvim_win_get_config(preview_window)
  vim.o.columns = vim.o.columns + 10
  vim.api.nvim_exec_autocmds("VimResized", {})
  assert(vim.fn.bufwinid(board._buffer()) == list_window)
  assert(vim.fn.bufwinid(board._preview_buffer()) == preview_window)
  assert(vim.api.nvim_get_current_win() == preview_window)
  assert(vim.api.nvim_win_get_config(preview_window).zindex == before.zindex)
  vim.fn.maparg("P", "n", false, true).callback()
  assert(vim.wait(5000, function()
    return text():find("HERDR_PREVIEW_SECOND", 1, true)
  end, 20))
  board.close()
  assert(vim.api.nvim_get_current_win() == origin, "board close lost editor focus")
  local snapshot = await(client.snapshot)
  assert(vim.iter(snapshot.agents):any(function(agent)
    return agent.terminal_id == selected.terminal_id
  end))
  print("TUI_SMOKE_OK: live preview, pause, yank, state updates, resume, resize, editor return; agent retained")
end

local ok, err = xpcall(run, debug.traceback)
state.stop()
board._reset()
require("herdr")._reset()
if workspace then
  local cleaned, cleanup_err = pcall(cli, { "workspace", "close", workspace })
  if not cleaned then
    ok, err = false, tostring(err or "") .. "\ncleanup: " .. tostring(cleanup_err)
  end
end
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
