local h = require("tests.harness")
local config = require("herdr.config")
local client = require("herdr.client")
local state = require("herdr.state")

local function reset()
  require("herdr")._reset()
  require("herdr.board")._reset()
  require("herdr.terminal")._reset()
  require("herdr.notifier")._reset()
  state._reset()
  client._reset()
  config._reset()
end

local function raw_agent(overrides)
  return vim.tbl_extend("force", {
    terminal_id = "term_1",
    agent_status = "working",
    workspace_id = "w1",
    tab_id = "w1:t1",
    pane_id = "w1:p1",
    revision = 1,
    name = "api",
    agent = "codex",
    cwd = "/repo",
  }, overrides or {})
end

local function raw_snapshot(agents, workspaces, panes)
  return {
    type = "session_snapshot",
    snapshot = {
      version = "0.9.5",
      protocol = 22,
      agents = agents,
      workspaces = workspaces or { { workspace_id = "w1", label = "repo" } },
      panes = panes or { { pane_id = "w1:p1", workspace_id = "w1", cwd = "/repo" } },
    },
  }
end

local function normalized(agents, machine, workspaces, panes)
  return assert(client._normalize_snapshot(raw_snapshot(agents, workspaces, panes), machine))
end

-- Routes fake Herdr processes by their --machine selector ("local" when absent).
local function route_runner(routes, calls)
  client._set_runner(function(argv, _, callback)
    table.insert(calls, vim.deepcopy(argv))
    local machine = argv[2] == "--machine" and argv[3] or "local"
    local args = vim.list_slice(argv, machine == "local" and 2 or 4)
    local handler = routes[machine]
    local result = handler and handler(args) or nil
    if type(result) == "table" and result.code then
      callback(result)
    else
      callback({ code = 0, stdout = vim.json.encode(result or { id = "1", result = { type = "ok" } }), stderr = "" })
    end
  end)
end

h.test("config accepts saved machine selectors and rejects ambiguous ones", function()
  reset()
  h.eq({}, config.setup().machines)
  h.eq({ "hdymac", "Build machine" }, config.setup({ machines = { "hdymac", "Build machine" } }).machines)
  h.raises("machines", function()
    config.setup({ machines = "hdymac" })
  end)
  h.raises("machines[1]", function()
    config.setup({ machines = { "" } })
  end)
  h.raises("without '@'", function()
    config.setup({ machines = { "me@host" } })
  end)
  h.raises("unique", function()
    config.setup({ machines = { "hdymac", "hdymac" } })
  end)
end)

h.test("client routes machine commands through --machine and qualifies identity", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  local calls = {}
  route_runner({
    hdymac = function(args)
      if args[1] == "api" then
        return { id = "1", result = raw_snapshot({ raw_agent() }) }
      end
      if args[2] == "read" or args[2] == "explain" then
        return { code = 0, stdout = "remote output\n", stderr = "" }
      end
    end,
  }, calls)

  local snapshot
  client.snapshot(function(result)
    snapshot = result
  end, "hdymac")
  client.prompt("w1:p1", "review", function() end, "hdymac")
  client.rename("w1:p1", "reviewer", function() end, "hdymac")
  client.read("w1:p1", 40, function() end, "hdymac")
  client.explain("w1:p1", function() end, "hdymac")

  h.eq("term_1@hdymac", snapshot.agents[1].key)
  h.eq("hdymac", snapshot.agents[1].machine)
  h.eq("hdymac", snapshot.workspaces[1].machine)
  h.eq({ "herdr", "--machine", "hdymac", "api", "snapshot" }, calls[1])
  h.eq({ "herdr", "--machine", "hdymac", "agent", "prompt", "w1:p1", "review" }, calls[2])
  h.eq({ "herdr", "--machine", "hdymac", "agent", "rename", "w1:p1", "reviewer" }, calls[3])
  h.eq("--machine", calls[4][2])
  h.eq("read", calls[4][5])
  h.eq({ "herdr", "--machine", "hdymac", "agent", "explain", "w1:p1", "--format", "text" }, calls[5])
end)

h.test("client keeps Local argv unchanged and tags errors with their machine", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  local calls = {}
  route_runner({
    ["local"] = function()
      return { id = "1", result = raw_snapshot({ raw_agent() }) }
    end,
    hdymac = function()
      return {
        code = 1,
        stdout = "",
        stderr = vim.json.encode({ error = { code = "agent_blocked", message = "agent is blocked" } }),
      }
    end,
  }, calls)
  local local_snapshot, remote_err
  client.snapshot(function(result)
    local_snapshot = result
  end)
  client.prompt("w1:p1", "go", function(_, err)
    remote_err = err
  end, "hdymac")
  h.eq({ "herdr", "api", "snapshot" }, calls[1])
  h.eq("term_1", local_snapshot.agents[1].key)
  h.eq(nil, local_snapshot.agents[1].machine)
  h.eq("agent_blocked", remote_err.api_code)
  h.eq("hdymac", remote_err.machine)
end)

h.test("client starts a remote agent in the chosen Space with that machine's cwd", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  local calls = {}
  route_runner({
    hdymac = function(args)
      if args[1] == "api" then
        return {
          id = "1",
          result = raw_snapshot({}, { { workspace_id = "w7", label = "api" } }, {
            { pane_id = "w7:p1", workspace_id = "w7", cwd = "/home/me/api" },
          }),
        }
      end
      if args[1] == "tab" then
        return { id = "1", result = { type = "tab_created", root_pane = { pane_id = "w7:p2" } } }
      end
      return {
        id = "1",
        result = { type = "agent_started", agent = raw_agent({ terminal_id = "term_9", pane_id = "w7:p2" }) },
      }
    end,
  }, calls)
  local started
  client.start_agent(
    "codex",
    "worker",
    { machine = "hdymac", workspace_id = "w7", cwd = "/home/me/api" },
    function(_, err, _, agent)
      h.eq(nil, err)
      started = agent
    end
  )
  h.eq({
    "herdr",
    "--machine",
    "hdymac",
    "tab",
    "create",
    "--workspace",
    "w7",
    "--cwd",
    "/home/me/api",
    "--label",
    "worker",
    "--no-focus",
  }, calls[2])
  h.eq("--machine", calls[3][2])
  h.eq("start", calls[3][5])
  h.eq("term_9@hdymac", started.key)
end)

h.test("client refuses a remote destination whose Space disappeared", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  local calls = {}
  route_runner({
    hdymac = function()
      return { id = "1", result = raw_snapshot({}, {}, {}) }
    end,
  }, calls)
  local failure
  client.start_agent(
    "codex",
    "worker",
    { machine = "hdymac", workspace_id = "w7", cwd = "/home/me/api" },
    function(_, err)
      failure = err
    end
  )
  h.contains(failure.message, "Space was closed")
  h.eq(1, #calls, "no workspace or tab is created")
end)

h.test("client opens a saved machine's Herdr session from its profile", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  local opened = {}
  client._set_runner(function(argv, _, callback)
    h.eq({ "herdr", "machine", "list", "--json" }, argv)
    callback({
      code = 0,
      stdout = vim.json.encode({
        { id = "abc", label = "hdymac", target = "ssh://me@host:2222", session = "default", enabled = true },
        { id = "def", label = "build", target = "build-box", session = "agents", enabled = true },
        { id = "off", label = "spare", target = "spare", session = "default", enabled = false },
      }),
      stderr = "",
    })
  end)
  client._set_termopen(function(argv)
    table.insert(opened, argv)
    return 7
  end)
  local profiles = {}
  for _, selector in ipairs({ "hdymac", "def", "spare", "missing" }) do
    client.machine_profile(selector, function(profile, err)
      profiles[selector] = profile or err
    end)
  end
  h.eq("ssh://me@host:2222", profiles.hdymac.target)
  h.eq("build-box", profiles.def.target)
  h.contains(profiles.spare.message, "herdr machine enable spare")
  h.contains(profiles.missing.message, "herdr machine list")
  h.eq(7, client.attach_machine(profiles.hdymac, {}))
  h.eq(7, client.attach_machine(profiles.def, {}))
  h.eq({ "herdr", "--remote", "ssh://me@host:2222" }, opened[1])
  h.eq({ "herdr", "--remote", "build-box", "--session", "agents" }, opened[2])
end)

h.test("state merges machines, keeps colliding IDs distinct, and groups Spaces by machine", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  state._accept(normalized({ raw_agent({ agent_status = "working" }) }))
  state._accept(normalized({ raw_agent({ agent_status = "blocked" }) }, "hdymac"), "hdymac")

  h.eq(2, #state.agents())
  h.eq("working", state.agent("term_1").status)
  h.eq("blocked", state.agent("term_1@hdymac").status)
  local groups = state.grouped_agents({ all = true })
  h.eq(2, #groups)
  h.eq("hdymac", groups[1].machine, "blocked work on another machine rises first")
  h.eq(nil, groups[2].machine)
  h.eq({ blocked = 1, working = 1, done = 0, idle = 0, unknown = 0 }, state.counts())
end)

h.test("state keeps Local fresh while a failing machine backs off until an explicit retry", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  local clock = 1000
  state._set_clock(function()
    return clock
  end)
  state._set_timer_factory(function()
    return {
      is_closing = function()
        return false
      end,
      start = function() end,
      stop = function() end,
      close = function() end,
    }
  end)
  local originals = { ensure = client.ensure_server, snapshot = client.snapshot }
  local remote_calls = 0
  local remote_ok = false
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback, machine)
    if machine == "hdymac" then
      remote_calls = remote_calls + 1
      if remote_ok then
        callback(normalized({ raw_agent({ agent_status = "done" }) }, "hdymac"))
      else
        callback(nil, { kind = "process", message = "remote SSH connection failed", machine = "hdymac" })
      end
      return
    end
    callback(normalized({ raw_agent() }))
  end
  h.defer(function()
    client.ensure_server, client.snapshot = originals.ensure, originals.snapshot
  end)

  local ok
  state.refresh({ explicit = true }, function(value)
    ok = value
  end)
  h.truthy(ok, "Local success completes the round")
  h.eq(1, remote_calls)
  local endpoints = state.endpoints()
  h.eq("remote SSH connection failed", endpoints[2].error.message)
  h.eq(nil, endpoints[1].error)

  clock = clock + 1000
  state.refresh()
  h.eq(1, remote_calls, "the machine waits out its backoff")
  clock = clock + 5000
  state.refresh()
  h.eq(2, remote_calls)
  clock = clock + 1000
  remote_ok = true
  state.refresh({ explicit = true, retry = true })
  h.eq(3, remote_calls, "an explicit retry ignores the backoff")
  h.eq("done", state.agent("term_1@hdymac").status)
  h.eq(nil, state.endpoints()[2].error)
end)

h.test("state acknowledges a remote completion independently of a Local agent with the same ID", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  state._accept(normalized({ raw_agent({ agent_status = "done", completion_seq = 1 }) }))
  state._accept(normalized({ raw_agent({ agent_status = "done", completion_seq = 1 }) }, "hdymac"), "hdymac")
  h.truthy(state.acknowledge("term_1@hdymac"))
  h.eq(1, state.counts().done)
  h.eq(1, #state.grouped_agents({})[1].agents)
  h.eq(nil, state.grouped_agents({})[1].machine)
  state._fail({ kind = "process", message = "offline" }, nil, "hdymac")
  h.eq(false, state.acknowledge("term_1@hdymac"), "a stale machine cannot be acknowledged")
end)

h.test("state notifies transitions per machine with qualified identity", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  state._set_emit(function() end)
  local events = {}
  state._set_transition_handler(function(event)
    table.insert(events, event)
  end)
  state._accept(normalized({ raw_agent() }))
  state._accept(normalized({ raw_agent() }, "hdymac"), "hdymac")
  state._accept(normalized({ raw_agent({ agent_status = "blocked" }) }, "hdymac"), "hdymac")
  h.eq(1, #events)
  h.eq("term_1@hdymac", events[1].key)
  h.eq("hdymac", events[1].machine)
end)

h.test("notifier labels remote agents and deduplicates per machine", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  local notifier = require("herdr.notifier")
  local messages = {}
  notifier._set_notify(function(text)
    table.insert(messages, text)
  end)
  notifier._set_visibility_probe(function()
    return false
  end)
  local base = { terminal_id = "term_1", status = "blocked", revision = 2, name = "api", title = "approve" }
  notifier.on_transition(vim.tbl_extend("force", base, { key = "term_1" }))
  notifier.on_transition(vim.tbl_extend("force", base, { key = "term_1@hdymac", machine = "hdymac" }))
  notifier.on_transition(vim.tbl_extend("force", base, { key = "term_1@hdymac", machine = "hdymac" }))
  h.eq({ "api is blocked: approve", "api@hdymac is blocked: approve" }, messages)
end)

-- Plugin actions call ensure_setup(), so configure through herdr.setup with polling stubbed.
local function setup_plugin(opts)
  local herdr = require("herdr")
  local original_start = state.start
  state.start = function() end
  herdr.setup(opts)
  h.defer(function()
    state.start = original_start
    -- Invalidates the setup's scheduled start before the next test.
    herdr._reset()
  end)
  return herdr
end

local function seed_two_machines()
  setup_plugin({ machines = { "hdymac" }, auto_start_server = false })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  state._accept(normalized({ raw_agent({ name = "api", agent_status = "idle" }) }))
  state._accept(
    normalized(
      {
        raw_agent({ name = "api", agent_status = "idle" }),
        raw_agent({ terminal_id = "term_2", pane_id = "w1:p2", name = "reviewer", agent_status = "idle" }),
      },
      "hdymac",
      { { workspace_id = "w1", label = "remote-repo" } },
      { { pane_id = "w1:p1", workspace_id = "w1", cwd = "/home/me/repo" } }
    ),
    "hdymac"
  )
end

h.test("agent targets accept @machine and otherwise prefer Local like the Herdr CLI", function()
  reset()
  local herdr = require("herdr")
  seed_two_machines()
  h.eq("term_1", herdr._find_agent("api").key)
  h.eq("term_1@hdymac", herdr._find_agent("api@hdymac").key)
  h.eq("term_1@hdymac", herdr._find_agent("term_1@hdymac").key)
  h.eq("term_2@hdymac", herdr._find_agent("reviewer").key, "an unqualified name falls back to a unique remote agent")
  h.eq("term_1", herdr._find_agent("w1:p1").key)
  local missing, err = herdr._find_agent("api@build")
  h.eq(nil, missing)
  h.contains(err, "unknown Herdr agent")
  local keys = herdr._complete_agents()
  table.sort(keys)
  h.eq({ "term_1", "term_1@hdymac", "term_2@hdymac" }, keys)
end)

h.test("prompting a remote agent revalidates on that machine without a Local server", function()
  reset()
  local herdr = require("herdr")
  seed_two_machines()
  local ensure_calls, snapshot_machines, sent = 0, {}, nil
  local originals =
    { ensure = client.ensure_server, snapshot = client.snapshot, prompt = client.prompt, notify = vim.notify }
  h.defer(function()
    client.ensure_server, client.snapshot, client.prompt, vim.notify =
      originals.ensure, originals.snapshot, originals.prompt, originals.notify
  end)
  client.ensure_server = function(callback)
    ensure_calls = ensure_calls + 1
    callback(false, { kind = "server", message = "Local server is down" })
  end
  client.snapshot = function(callback, machine)
    table.insert(snapshot_machines, machine or "local")
    local moved = raw_agent({ name = "api", agent_status = "idle", pane_id = "w3:p1", workspace_id = "w3" })
    callback(normalized({ moved }, machine))
  end
  client.prompt = function(target, text, callback, machine)
    sent = { target = target, text = text, machine = machine }
    callback({})
  end
  vim.notify = function() end
  herdr.prompt("api@hdymac", "check the remote build")
  h.eq(0, ensure_calls)
  h.eq({ "hdymac" }, snapshot_machines)
  h.eq({ target = "w3:p1", text = "check the remote build", machine = "hdymac" }, sent)
end)

h.test("editor context sent to a remote agent uses project-relative paths", function()
  reset()
  local herdr = require("herdr")
  seed_two_machines()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.git", "p")
  vim.fn.mkdir(root .. "/lua", "p")
  local file = root .. "/lua/sample.lua"
  vim.fn.writefile({ "return 1" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()
  local sent = {}
  local originals =
    { ensure = client.ensure_server, snapshot = client.snapshot, prompt = client.prompt, notify = vim.notify }
  h.defer(function()
    client.ensure_server, client.snapshot, client.prompt, vim.notify =
      originals.ensure, originals.snapshot, originals.prompt, originals.notify
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(root, "rf")
  end)
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback, machine)
    callback(normalized({ raw_agent({ name = "api", agent_status = "idle" }) }, machine))
  end
  client.prompt = function(_, text, callback, machine)
    sent[machine or "local"] = text
    callback({})
  end
  vim.notify = function() end
  herdr._send_file("api@hdymac", bufnr)
  herdr._send_file("api", bufnr)
  h.eq("Please inspect @lua/sample.lua in the current project.", sent.hdymac)
  h.contains(sent["local"], "@/", "Local agents keep the absolute path")
  h.contains(sent["local"], "/lua/sample.lua")
end)

h.test("attaching a remote agent opens its machine session instead of moving Neovim", function()
  reset()
  local herdr = require("herdr")
  local terminal = require("herdr.terminal")
  seed_two_machines()
  vim.env.HERDR_ENV = "1"
  local moved, opened, notices = false, nil, {}
  local originals = {
    move = client.move_current_pane,
    profile = client.machine_profile,
    attach = terminal.attach,
    attach_machine = terminal.attach_machine,
    notify = vim.notify,
  }
  h.defer(function()
    vim.env.HERDR_ENV = nil
    client.move_current_pane, client.machine_profile = originals.move, originals.profile
    terminal.attach, terminal.attach_machine, vim.notify = originals.attach, originals.attach_machine, originals.notify
  end)
  client.move_current_pane = function()
    moved = true
  end
  client.machine_profile = function(machine, callback)
    callback({ id = "abc", label = machine, target = "ssh://me@host", session = "default" })
  end
  terminal.attach = function()
    error("Local attach must not run for a remote agent")
  end
  terminal.attach_machine = function(agent, profile)
    opened = { key = agent.key, target = profile.target }
    return 3
  end
  vim.notify = function(text)
    table.insert(notices, text)
  end
  herdr.attach("reviewer@hdymac")
  h.eq(false, moved)
  h.eq({ key = "term_2@hdymac", target = "ssh://me@host" }, opened)
  h.contains(table.concat(notices, "\n"), "select reviewer (w1:p2)")
end)

-- Drives start destinations through stubbed per-machine snapshots; `remote_ok = false` makes
-- the machine fail during destination discovery.
local function start_with_destinations(remote_ok)
  local herdr = setup_plugin({ machines = { "hdymac" }, auto_start_server = false })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  local picked, started = {}, nil
  local originals = {
    select = vim.ui.select,
    start = client.start_agent,
    ensure = client.ensure_server,
    snapshot = client.snapshot,
    notify = vim.notify,
  }
  h.defer(function()
    vim.ui.select, client.start_agent = originals.select, originals.start
    client.ensure_server, client.snapshot, vim.notify = originals.ensure, originals.snapshot, originals.notify
  end)
  client.ensure_server = function(callback)
    callback(true)
  end
  client.snapshot = function(callback, machine)
    if not machine then
      callback(normalized({}))
    elseif remote_ok then
      callback(
        normalized(
          {},
          machine,
          { { workspace_id = "w1", label = "other" }, { workspace_id = "w2", label = "herdr.nvim" } },
          {
            { pane_id = "w1:p1", workspace_id = "w1", cwd = "/home/me/other" },
            { pane_id = "w2:p1", workspace_id = "w2", cwd = "/home/me/herdr.nvim" },
          }
        )
      )
    else
      callback(nil, { kind = "process", message = "remote SSH connection failed", machine = machine })
    end
  end
  vim.notify = function() end
  vim.ui.select = function(items, opts, callback)
    picked = { prompt = opts.prompt, choices = vim.tbl_map(opts.format_item, items) }
    callback(items[#items > 1 and 2 or 1])
  end
  client.start_agent = function(kind, name, destination)
    started = { kind = kind, name = name, destination = destination }
  end
  herdr.start("codex", { cwd = "/tmp/work/herdr.nvim", instruction = "" })
  return picked, started
end

h.test("starting with watched machines offers Local first, then matching remote Spaces", function()
  reset()
  local picked, started = start_with_destinations(true)
  h.eq("Start agent where:", picked.prompt)
  h.contains(picked.choices[1], "Local · herdr.nvim")
  h.contains(picked.choices[2], "hdymac › herdr.nvim  /home/me/herdr.nvim")
  h.contains(picked.choices[3], "hdymac › other")
  h.eq({ machine = "hdymac", workspace_id = "w2", cwd = "/home/me/herdr.nvim" }, {
    machine = started.destination.machine,
    workspace_id = started.destination.workspace_id,
    cwd = started.destination.cwd,
  })
  h.eq("codex-herdr-nvim", started.name)
end)

h.test("starting never silently picks Local while a watched machine is unavailable", function()
  reset()
  local picked, started = start_with_destinations(false)
  h.eq(1, #picked.choices, "the picker is shown even with only Local to offer")
  h.contains(picked.prompt, "unavailable: hdymac")
  h.eq(nil, started.destination.machine)
end)

h.test("an unqualified target is not resolved remotely until Local's snapshot confirms it", function()
  reset()
  local herdr = setup_plugin({ machines = { "hdymac" }, auto_start_server = false })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  state._accept(normalized({ raw_agent({ name = "reviewer", agent_status = "idle" }) }, "hdymac"), "hdymac")
  local found, err = herdr._find_agent("reviewer")
  h.eq(nil, found, "Local has not reported yet, so it may still have a reviewer")
  h.contains(err, "reviewer@hdymac")
  h.eq("term_1@hdymac", herdr._find_agent("reviewer@hdymac").key)
  state._accept(normalized({}))
  h.eq("term_1@hdymac", herdr._find_agent("reviewer").key, "a fresh Local view without a match allows fallback")
  state._fail({ kind = "process", message = "offline" })
  h.eq(nil, (herdr._find_agent("reviewer")), "a stale Local view cannot confirm the absence")
end)

h.test("board labels remote Spaces, reports a failing machine, and keeps Git tools local", function()
  reset()
  local board = require("herdr.board")
  seed_two_machines()
  state._fail({ kind = "process", message = "remote SSH connection failed" }, nil, "hdymac")
  board.setup()
  board.open()
  local lines = vim.api.nvim_buf_get_lines(board._buffer(), 0, -1, false)
  local text = table.concat(lines, "\n")
  h.contains(text, "hdymac showing last view: remote")
  h.contains(text, "r: retry now")
  h.contains(text, "No agents match this view", "Local is fresh, so the empty view is not called stale")
  vim.api.nvim_feedkeys("A", "x", false)
  local remote_row
  for line, agent in pairs(board._line_agents()) do
    if agent.key == "term_2@hdymac" then
      remote_row = line
    end
  end
  lines = vim.api.nvim_buf_get_lines(board._buffer(), 0, -1, false)
  h.truthy(remote_row, "remote agent is listed in the all-agents view")
  h.truthy(vim.iter(lines):any(function(line)
    return line:find("hdymac › remote-repo", 1, true) ~= nil
  end))
  local notices = {}
  local original_notify = vim.notify
  vim.notify = function(value)
    table.insert(notices, value)
  end
  vim.api.nvim_win_set_cursor(0, { remote_row, 0 })
  vim.api.nvim_feedkeys("g", "x", false)
  vim.notify = original_notify
  h.truthy(board.is_open(), "Git tools do not close the board for a remote agent")
  h.contains(table.concat(notices, "\n"), "reviewer@hdymac works in a repository on hdymac")
  board.close()
end)

h.test("health matches watched machines by label or ID and lists unwatched profiles", function()
  local health = require("herdr.health")
  local list = vim.json.encode({
    { id = "abc", label = "hdymac", target = "ssh://me@host", session = "default", enabled = true },
    { id = "def", label = "build", target = "build", session = "default", enabled = true },
    { id = "off", label = "spare", target = "spare", session = "default", enabled = false },
  })
  local matched, unwatched = health._match_machine_profiles(list, { "hdymac", "def", "missing" })
  h.eq("ssh://me@host", matched.hdymac.target)
  h.eq("build", matched.def.label)
  h.eq(nil, matched.missing)
  h.eq({}, unwatched, "disabled and watched profiles are not suggested")
  local _, only_hdymac = health._match_machine_profiles(list, { "hdymac" })
  h.eq({ "build" }, only_hdymac)
  local invalid, err = health._match_machine_profiles("{}", { "hdymac" })
  h.eq(nil, invalid)
  h.contains(err, "invalid saved machine list")
end)

h.test("health parses machine reachability without trusting malformed output", function()
  local health = require("herdr.health")
  h.eq(
    { status = "reachable" },
    health._parse_machine_status(
      vim.json.encode({ { id = "abc", label = "hdymac", status = "reachable", error = vim.NIL } })
    )
  )
  h.eq(
    { status = "auth", error = "permission denied" },
    health._parse_machine_status(vim.json.encode({ { status = "auth", error = "permission denied" } }))
  )
  local status, err = health._parse_machine_status("not json")
  h.eq(nil, status)
  h.contains(err, "invalid machine status")
end)

local function fake_timer_factory()
  return function()
    return {
      is_closing = function()
        return false
      end,
      start = function() end,
      stop = function() end,
      close = function() end,
    }
  end
end

local function stub(target, fields)
  local originals = {}
  for name, value in pairs(fields) do
    originals[name] = target[name]
    target[name] = value
  end
  h.defer(function()
    for name, value in pairs(originals) do
      target[name] = value
    end
  end)
end

h.test("a multiline machine error does not stop the board from rendering", function()
  reset()
  local board = require("herdr.board")
  seed_two_machines()
  -- A full-width list keeps the newline inside the visible text instead of truncating it away.
  config.get().board.preview = false
  state._fail({ kind = "process", message = "offline\nPermission denied" }, nil, "hdymac")
  board.setup()
  board.open()
  h.contains(table.concat(vim.api.nvim_buf_get_lines(board._buffer(), 0, -1, false), "\n"), "hdymac showing last view")
  board.close()
end)

h.test("a slow machine does not hold back the next Local poll", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  state._set_timer_factory(fake_timer_factory())
  local local_calls, remote_callbacks = 0, {}
  stub(client, {
    ensure_server = function(callback)
      callback(true)
    end,
    snapshot = function(callback, machine)
      if machine then
        table.insert(remote_callbacks, callback)
        return
      end
      local_calls = local_calls + 1
      callback(normalized({ raw_agent({ agent_status = local_calls == 1 and "working" or "blocked" }) }))
    end,
  })
  state.refresh({ explicit = true })
  state.refresh()
  h.eq(2, local_calls, "Local refreshes again while the machine is still in flight")
  h.eq(1, #remote_callbacks, "the in-flight machine is not requested twice")
  h.eq("blocked", state.agent("term_1").status)
  remote_callbacks[1](normalized({}, "hdymac"))
  h.eq(nil, state.endpoint("hdymac").error)
  state.stop()
end)

h.test("a stopped Local server neither stops nor restarts machine polling", function()
  reset()
  config.setup({ machines = { "hdymac" } })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  state._set_timer_factory(fake_timer_factory())
  local clock = 1000
  state._set_clock(function()
    return clock
  end)
  local ensure_calls, remote_ok = 0, false
  stub(client, {
    ensure_server = function(callback)
      ensure_calls = ensure_calls + 1
      callback(false, { kind = "protocol", message = "unsupported" })
    end,
    snapshot = function(callback, machine)
      if remote_ok then
        callback(normalized({}, machine))
      else
        callback(nil, { kind = "process", message = "offline", machine = machine })
      end
    end,
  })
  state.start()
  h.eq(true, state.get().polling, "the machine keeps polling after Local stops")
  clock = clock + 6000
  remote_ok = true
  state.refresh()
  h.eq(1, ensure_calls, "Local waits for an explicit refresh after a protocol failure")
  h.eq(nil, state.endpoint("hdymac").error, "the machine retried after its backoff")
  state.refresh({ explicit = true })
  h.eq(2, ensure_calls, "an explicit refresh retries Local")
  state.stop()
end)

h.test("the preview does not read from a machine that is backing off", function()
  reset()
  local board = require("herdr.board")
  seed_two_machines()
  local reads = 0
  stub(client, {
    read = function(_, _, callback)
      reads = reads + 1
      callback("REMOTE OUTPUT")
    end,
  })
  board.setup()
  board.open({ key = "term_2@hdymac" })
  board.refresh_preview({ force = true })
  local before = reads
  h.truthy(before > 0)
  state._fail({ kind = "process", message = "offline" }, nil, "hdymac")
  board.refresh_preview({ force = true })
  h.eq(before, reads, "no SSH read while the machine is unavailable")
  h.contains(table.concat(vim.api.nvim_buf_get_lines(board._preview_buffer(), 0, -1, false), "\n"), "REMOTE OUTPUT")
  state._accept(normalized({ raw_agent({ terminal_id = "term_2", name = "reviewer" }) }, "hdymac"), "hdymac")
  board.refresh_preview({ force = true })
  h.eq(before + 1, reads, "reads resume after the machine recovers")
  board.close()
end)

h.test("an unconfirmed initial instruction to a remote agent is kept for an explicit retry", function()
  reset()
  local herdr = setup_plugin({ machines = { "hdymac" }, auto_start_server = false })
  state._set_emit(function() end)
  state._set_transition_handler(function() end)
  local notices = {}
  stub(vim, {
    notify = function(text)
      table.insert(notices, text)
    end,
  })
  stub(vim.ui, {
    select = function(items, _, callback)
      callback(items[2])
    end,
  })
  stub(client, {
    ensure_server = function(callback)
      callback(true)
    end,
    snapshot = function(callback, machine)
      if not machine then
        callback(normalized({}))
        return
      end
      callback(normalized({}, machine, { { workspace_id = "w2", label = "proj" } }, {
        { pane_id = "w2:p1", workspace_id = "w2", cwd = "/home/me/proj" },
      }))
    end,
    start_agent = function(_, name, destination, callback)
      local started = normalized(
        { raw_agent({ terminal_id = "term_9", pane_id = "w2:p2", name = name, agent_status = "idle" }) },
        destination.machine
      ).agents[1]
      callback({ type = "agent_started" }, nil, { pane_id = "w2:p2" }, started)
    end,
    prompt_until_working = function(_, _, callback)
      callback(nil, { kind = "process", message = "remote SSH connection failed", machine = "hdymac" })
    end,
    machine_profile = function(_, callback)
      callback(nil, { kind = "config", message = "profile lookup skipped in test" })
    end,
  })
  herdr.start("codex", { cwd = "/tmp/work/proj", instruction = "run the migration" })
  h.eq("run the migration", herdr._pending_instruction("term_9@hdymac"))
  local text = table.concat(notices, "\n")
  h.contains(text, "delivery of the initial instruction was not confirmed")
  h.contains(text, "codex-proj@hdymac and press p")
end)

h.test("a remote file reference outside the project is refused instead of sending a local path", function()
  reset()
  local herdr = require("herdr")
  seed_two_machines()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/notes.txt"
  vim.fn.writefile({ "outside" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()
  h.defer(function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(dir, "rf")
  end)
  local sent, notices = {}, {}
  stub(vim, {
    notify = function(text)
      table.insert(notices, text)
    end,
  })
  stub(client, {
    ensure_server = function(callback)
      callback(true)
    end,
    snapshot = function(callback, machine)
      callback(normalized({ raw_agent({ name = "api", agent_status = "idle" }) }, machine))
    end,
    prompt = function(_, text, callback, machine)
      sent[machine or "local"] = text
      callback({})
    end,
  })
  herdr._send_file("api@hdymac", bufnr)
  herdr._send_file("api", bufnr)
  h.eq(nil, sent.hdymac)
  h.contains(table.concat(notices, "\n"), "a remote agent cannot resolve it")
  h.contains(sent["local"], "@/", "Local agents keep the absolute path")
end)

h.test("health probes forwarding before machine status and reports aliases", function()
  local health = require("herdr.health")
  h.eq(false, health._supports_machine_status("herdr 0.9.1"))
  h.eq(true, health._supports_machine_status("herdr 0.9.2"))
  h.eq(false, health._supports_machine_status(nil))
  local list = vim.json.encode({
    { id = "abc", label = "hdymac", target = "ssh://me@host", session = "default", enabled = true },
  })
  local _, _, aliases = health._match_machine_profiles(list, { "hdymac", "abc" })
  h.eq({ { "hdymac", "abc" } }, aliases)
end)
