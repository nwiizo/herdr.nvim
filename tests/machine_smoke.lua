-- Opt-in integration test for watched saved machines; requires the disposable fake-SSH setup
-- in docs/testing.md. It creates and closes its own workspaces on both servers.
local root = assert(vim.env.HERDR_NVIM_MACHINE_TEST_ROOT, "set HERDR_NVIM_MACHINE_TEST_ROOT")
assert(root:match("/hnm%.[%w]+$"), "use a fresh hnm.XXXXXX test directory")
assert(vim.env.HERDR_SOCKET_PATH == root .. "/local.sock", "refusing to use a shared Herdr socket")
assert(vim.env.HOME == root .. "/home", "refusing to read real saved machine profiles")
local machine = "fake"
local created = {}

local herdr = require("herdr")
local board = require("herdr.board")
local state = require("herdr.state")

local function cli(target, args)
  local argv = { "herdr" }
  if target then
    vim.list_extend(argv, { "--machine", target })
  end
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(20000)
  assert(result.code == 0, table.concat(argv, " ") .. ": " .. (result.stderr or ""))
  local ok, decoded = pcall(vim.json.decode, result.stdout or "")
  return ok and type(decoded) == "table" and decoded.result or result.stdout
end

local function create_workspace(target, cwd, label)
  local result = cli(target, { "workspace", "create", "--cwd", cwd, "--label", label, "--no-focus" })
  table.insert(created, { machine = target, workspace = result.workspace.workspace_id })
  return result.root_pane.pane_id
end

local function report(target, pane, status, seq)
  cli(target, {
    "pane",
    "report-agent",
    pane,
    "--source",
    "nvim-machine-smoke",
    "--agent",
    "claude",
    "--state",
    status,
    "--seq",
    tostring(seq),
  })
end

local function refresh(opts)
  local done, ok
  state.refresh(vim.tbl_extend("force", { explicit = true }, opts or {}), function(value)
    ok, done = value, true
  end)
  assert(
    vim.wait(30000, function()
      return done
    end, 20),
    "refresh timed out"
  )
  return ok
end

local function find_agent(predicate)
  for _, agent in ipairs(state.agents()) do
    if predicate(agent) then
      return agent
    end
  end
end

local function lines_of(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end

-- Runs :checkhealth herdr's checks and returns the reported lines with their advice.
local function health_report()
  local lines = {}
  local original = vim.health
  local function record(level)
    return function(message, advice)
      table.insert(lines, level .. ": " .. message .. " " .. table.concat(advice or {}, " | "))
    end
  end
  vim.health = {
    start = record("start"),
    ok = record("ok"),
    warn = record("warn"),
    error = record("error"),
    info = record("info"),
  }
  package.loaded["herdr.health"] = nil
  local ok, err = pcall(function()
    require("herdr.health").check()
  end)
  vim.health = original
  package.loaded["herdr.health"] = nil
  assert(ok, err)
  return table.concat(lines, "\n")
end

local function run()
  local notices = {}
  vim.notify = function(message)
    table.insert(notices, tostring(message))
  end
  local function noticed(text)
    return vim.iter(notices):any(function(notice)
      return notice:find(text, 1, true) ~= nil
    end)
  end
  herdr.setup({
    machines = { machine },
    auto_start_server = false,
    agents = { codex = { args = {} }, smoke = { args = {} } },
    refresh = { board_ms = 60000, background_ms = 60000 },
  })
  vim.cmd("runtime plugin/herdr.lua")

  local remote_project = root .. "/rhome/project"
  local local_pane = create_workspace(nil, root .. "/home", "local-smoke")
  local remote_pane = create_workspace(machine, remote_project, "project")
  cli(machine, { "pane", "run", remote_pane, "printf 'REMOTE_PREVIEW_MARK\\n'" })
  cli(machine, { "pane", "wait-output", remote_pane, "--match", "REMOTE_PREVIEW_MARK", "--timeout", "5000" })
  report(nil, local_pane, "working", 1)
  report(machine, remote_pane, "working", 1)
  assert(refresh(), "first refresh")

  local local_agent = find_agent(function(agent)
    return not agent.machine and agent.pane_id == local_pane
  end)
  local remote_agent = find_agent(function(agent)
    return agent.machine == machine and agent.pane_id == remote_pane
  end)
  assert(local_agent and remote_agent, "agents from Local and the saved machine are listed")
  assert(remote_agent.key == remote_agent.terminal_id .. "@" .. machine, "remote identity is qualified")
  assert(herdr._find_agent(remote_pane .. "@" .. machine).key == remote_agent.key, "pane@machine target")
  if local_pane == remote_pane then
    assert(herdr._find_agent(local_pane).key == local_agent.key, "an unqualified pane ID prefers Local")
  end
  local reachable = health_report()
  assert(reachable:find("ok: " .. machine .. " (fake-mac) is reachable", 1, true), "health: reachable\n" .. reachable)

  -- A blocked remote agent notifies with its machine and rises above Local work.
  report(machine, remote_pane, "blocked", 2)
  assert(refresh(), "blocked refresh")
  assert(noticed("@" .. machine .. " is blocked"), "remote blocked notification")
  assert(state.grouped_agents({ all = true })[1].machine == machine, "blocked remote Space rises first")
  herdr.prompt(remote_agent.key)
  assert(noticed(":HerdrAttach " .. remote_agent.key), "blocked remote agent points to its qualified attach")

  -- The board labels the remote Space and reads its output through forwarding.
  board.open({ key = remote_agent.key })
  assert(lines_of(board._buffer()):find(machine .. " › project", 1, true), "remote Space heading")
  board.refresh_preview({ force = true })
  assert(
    vim.wait(15000, function()
      return lines_of(board._preview_buffer()):find("REMOTE_PREVIEW_MARK", 1, true) ~= nil
    end, 50),
    "remote preview"
  )
  board.close()

  -- Rename and prompt revalidate on the agent's machine; failures keep a draft.
  report(machine, remote_pane, "idle", 3)
  assert(refresh(), "idle refresh")
  local original_input, original_select = vim.ui.input, vim.ui.select
  vim.ui.input = function(_, callback)
    callback("remote-reviewer")
  end
  herdr.rename(remote_agent.key)
  assert(
    vim.wait(15000, function()
      local current = state.agent(remote_agent.key)
      return current and current.name == "remote-reviewer"
    end, 50),
    "remote rename"
  )
  herdr.prompt("remote-reviewer@" .. machine, "printf 'NOT_DELIVERED\\n'")
  assert(
    vim.wait(15000, function()
      return noticed("delivery was not confirmed") or noticed("prompted remote-reviewer@" .. machine)
    end, 50),
    "remote prompt result"
  )
  assert(noticed(machine .. ": ") or noticed("prompted remote-reviewer@" .. machine), "remote errors name the machine")

  -- Starting offers the matching remote Space and creates the tab there with its absolute cwd.
  local offered
  vim.ui.select = function(items, opts, callback)
    offered = vim.tbl_map(opts.format_item, items)
    for _, item in ipairs(items) do
      if item.machine == machine then
        callback(item)
        return
      end
    end
  end
  herdr.start("smoke", { cwd = root .. "/home/project", instruction = "" })
  assert(
    vim.wait(20000, function()
      return noticed("Herdr kept the new tab")
    end, 50),
    "remote start reached agent start"
  )
  vim.ui.input, vim.ui.select = original_input, original_select
  assert(offered[2]:find(machine .. " › project", 1, true), "matching remote Space offered after Local")
  local remote_snapshot = cli(machine, { "api", "snapshot" }).snapshot
  local tab_in_project = vim.iter(remote_snapshot.panes):any(function(pane)
    return pane.pane_id ~= remote_pane and (pane.cwd or ""):find("/rhome/project$") ~= nil
  end)
  assert(tab_in_project, "the new remote tab uses the machine's absolute project path")

  -- An unreachable machine keeps its last view while Local continues; an explicit retry recovers.
  vim.fn.writefile({}, root .. "/offline")
  report(nil, local_pane, "blocked", 2)
  refresh()
  assert(state.agent(local_agent.key).status == "blocked", "Local updates while the machine is offline")
  local remote_endpoint = state.endpoints()[2]
  assert(remote_endpoint.error and remote_endpoint.stale, "offline machine keeps a stale view")
  local client = require("herdr.client")
  local original_read, reads = client.read, 0
  client.read = function(...)
    reads = reads + 1
    return original_read(...)
  end
  board.open({ key = remote_agent.key })
  assert(lines_of(board._buffer()):find(machine .. " showing last view", 1, true), "board reports the machine")
  board.refresh_preview({ force = true })
  client.read = original_read
  assert(reads == 0, "the preview does not read from an offline machine")
  assert(lines_of(board._preview_buffer()):find("REMOTE_PREVIEW_MARK", 1, true), "the last output stays visible")
  board.close()
  local unreachable = health_report()
  assert(
    unreachable:find("warn: " .. machine .. " is not reachable", 1, true)
      and unreachable:find("machine reconnect " .. machine, 1, true),
    "health: unreachable\n" .. unreachable
  )
  vim.fn.delete(root .. "/offline")
  refresh({ retry = true })
  assert(state.endpoints()[2].error == nil, "explicit retry reconnects")

  -- Attach opens the machine's Herdr session; the return key selects the same agent.
  herdr.attach(remote_agent.key)
  local session_buffer
  assert(
    vim.wait(15000, function()
      for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[buffer].herdr_machine == machine then
          session_buffer = buffer
          return lines_of(buffer):find("project", 1, true) ~= nil
        end
      end
      return false
    end, 100),
    "remote Herdr session rendered"
  )
  assert(noticed("select remote-reviewer"), "attach explains where to select the agent")
  vim.api.nvim_set_current_buf(session_buffer)
  vim.fn.maparg(require("herdr.config").get().terminal.return_key, "t", false, true).callback()
  assert(
    vim.wait(5000, function()
      return board.is_open()
    end, 20),
    "return key reopens the board"
  )
  local line = vim.api.nvim_win_get_cursor(vim.fn.bufwinid(board._buffer()))[1]
  assert(board._line_agents()[line].key == remote_agent.key, "return selects the remote agent")
  board.close()
  print(
    "MACHINE_SMOKE_OK: merged attention, qualified targets, remote preview/rename/prompt/start, "
      .. "offline isolation, session attach"
  )
end

local ok, err = xpcall(run, debug.traceback)
state.stop()
board._reset()
require("herdr.terminal").cleanup()
herdr._reset()
vim.fn.delete(root .. "/offline")
for _, item in ipairs(created) do
  local cleaned, cleanup_err = pcall(cli, item.machine, { "workspace", "close", item.workspace })
  if not cleaned then
    ok, err = false, tostring(err or "") .. "\ncleanup: " .. tostring(cleanup_err)
  end
end
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
