local client = require("herdr.client")
local config = require("herdr.config")

local M = {}

-- Endpoint key for the Herdr session inherited by Neovim. Saved machines use their selector.
-- Each endpoint refreshes independently: { machine, snapshot, stale, error, in_flight,
-- stopped (Local terminal failure), retry_at/backoff_ms (machine failures), waiters }.
local LOCAL = ""
local endpoints = {}
local endpoint_order = {}
local current
local by_key = {}
local acknowledged = {}
local board_visible = false
local polling = false
local timer
local timer_running = false
local generation = 0
local failure_notifications = {}
local snapshot_waiters = {}
local now = function()
  return vim.uv.now()
end
local timer_factory = function()
  return vim.uv.new_timer()
end
local emit_user = function(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data })
end
local transition_handler = function(event)
  require("herdr.notifier").on_transition(event)
end

-- A failing machine is retried less often so SSH failures do not slow Local updates.
local machine_backoff_ms = { initial = 5000, maximum = 30000 }

local rank = {
  blocked = 1,
  done = 2,
  working = 3,
  idle = 4,
  unknown = 5,
}

local attention_status = {
  blocked = true,
  done = true,
}

local function emit_transition(agent, previous_status)
  local event = {
    key = agent.key,
    machine = agent.machine,
    terminal_id = agent.terminal_id,
    previous_status = previous_status,
    status = agent.status,
    revision = agent.revision,
    completion_seq = agent.completion_seq,
    name = agent.name,
    title = agent.title,
    workspace_id = agent.workspace_id,
  }
  transition_handler(event)
  emit_user("HerdrAgentStatusChanged", event)
end

local function interval()
  return board_visible and config.get().refresh.board_ms or config.get().refresh.background_ms
end

local function stop_timer()
  if timer and not timer:is_closing() then
    timer:stop()
  end
  timer_running = false
end

local function restart_timer()
  stop_timer()
  if not polling then
    return
  end
  if not timer or timer:is_closing() then
    timer = timer_factory()
  end
  local delay = interval()
  timer:start(
    delay,
    delay,
    vim.schedule_wrap(function()
      M.refresh()
    end)
  )
  timer_running = true
end

-- The timer ticks on a fixed cadence; each tick refreshes only endpoints that are idle and due.
local function ensure_timer()
  if polling and not timer_running then
    restart_timer()
  end
end

local function counts(agents)
  local result = { blocked = 0, working = 0, done = 0, idle = 0, unknown = 0 }
  for _, agent in ipairs(agents or {}) do
    if agent.status ~= "done" or not acknowledged[agent.key] then
      result[agent.status] = (result[agent.status] or 0) + 1
    end
  end
  return result
end

local function finish_snapshot_waiters(ok, result)
  local waiters = snapshot_waiters
  snapshot_waiters = {}
  for _, callback in ipairs(waiters) do
    callback(ok, result)
  end
end

local function rebuild_current()
  local agents, workspaces, panes = {}, {}, {}
  local loaded = false
  for _, key in ipairs(endpoint_order) do
    local snapshot = endpoints[key].snapshot
    if snapshot then
      loaded = true
      vim.list_extend(agents, snapshot.agents)
      vim.list_extend(workspaces, snapshot.workspaces)
      vim.list_extend(panes, snapshot.panes or {})
    end
  end
  by_key = {}
  for _, agent in ipairs(agents) do
    by_key[agent.key] = agent
  end
  if not loaded then
    current = nil
    return
  end
  local local_snapshot = endpoints[LOCAL].snapshot or {}
  current = {
    agents = agents,
    workspaces = workspaces,
    panes = panes,
    version = local_snapshot.version,
    protocol = local_snapshot.protocol,
    focused_workspace_id = local_snapshot.focused_workspace_id,
  }
end

local function sync_endpoints()
  local wanted = { LOCAL }
  vim.list_extend(wanted, config.get().machines)
  if vim.deep_equal(wanted, endpoint_order) then
    return
  end
  local next_endpoints = {}
  for _, key in ipairs(wanted) do
    next_endpoints[key] = endpoints[key]
      or { machine = key ~= LOCAL and key or nil, retry_at = 0, backoff_ms = 0, waiters = {} }
  end
  endpoints = next_endpoints
  endpoint_order = wanted
  rebuild_current()
end

local function any_endpoint(predicate)
  for _, key in ipairs(endpoint_order) do
    if predicate(endpoints[key]) then
      return true
    end
  end
  return false
end

local function any_stale()
  return any_endpoint(function(endpoint)
    return endpoint.stale
  end)
end

local function any_in_flight()
  return any_endpoint(function(endpoint)
    return endpoint.in_flight
  end)
end

-- Polling continues while any endpoint can still retry on its own.
local function update_polling()
  if not any_endpoint(function(endpoint)
    return not endpoint.stopped
  end) then
    polling = false
    stop_timer()
  end
end

-- Snapshots from tests or older callers may omit machine identity; stamp it once here.
local function stamp_identity(snapshot, machine)
  for _, agent in ipairs(snapshot.agents) do
    agent.machine = machine
    agent.key = client.agent_key(agent.terminal_id, machine)
  end
  for _, workspace in ipairs(snapshot.workspaces) do
    workspace.machine = machine
  end
end

function M._accept(snapshot, machine)
  sync_endpoints()
  local endpoint = endpoints[machine or LOCAL]
  if not endpoint then
    return
  end
  stamp_identity(snapshot, machine)
  local previous = {}
  for _, agent in ipairs(endpoint.snapshot and endpoint.snapshot.agents or {}) do
    previous[agent.key] = agent
  end

  endpoint.snapshot = snapshot
  endpoint.stale = false
  endpoint.error = nil
  endpoint.backoff_ms = 0
  endpoint.retry_at = 0
  rebuild_current()

  for key, completion in pairs(acknowledged) do
    local agent = by_key[key]
    if not agent or agent.status ~= "done" or completion ~= (agent.completion_seq or true) then
      acknowledged[key] = nil
    end
  end

  if endpoint.initialized then
    for _, agent in ipairs(snapshot.agents) do
      local old = previous[agent.key]
      local new_completion = old
        and agent.status == "done"
        and agent.completion_seq ~= nil
        and old.completion_seq ~= nil
        and agent.completion_seq ~= old.completion_seq
      if old and (old.status ~= agent.status or new_completion) then
        emit_transition(agent, old.status)
      elseif not old and attention_status[agent.status] then
        emit_transition(agent, nil)
      end
    end
  end
  endpoint.initialized = true
  emit_user("HerdrUpdated", { stale = any_stale(), counts = counts(current.agents) })
  if not any_in_flight() then
    finish_snapshot_waiters(true, current)
  end
end

function M._fail(err, opts, machine)
  sync_endpoints()
  opts = opts or {}
  local endpoint = endpoints[machine or LOCAL]
  if not endpoint then
    return
  end
  endpoint.stale = endpoint.snapshot ~= nil
  endpoint.error = err
  if machine then
    endpoint.backoff_ms =
      math.min(machine_backoff_ms.maximum, math.max(machine_backoff_ms.initial, endpoint.backoff_ms * 2))
    endpoint.retry_at = now() + endpoint.backoff_ms
  elseif opts.stop then
    -- Missing executables and incompatible protocols wait for an explicit refresh; machines keep polling.
    endpoint.stopped = true
    update_polling()
  end
  if not machine and err and err.kind == "executable" and not failure_notifications.executable then
    failure_notifications.executable = true
    vim.notify(
      "Herdr executable was not found. Install Herdr TUI from https://herdr.dev/tui/ and run :checkhealth herdr",
      vim.log.levels.ERROR,
      { title = "Herdr" }
    )
  end
  emit_user("HerdrUpdated", { stale = any_stale(), error = err, machine = machine })
  if not any_in_flight() then
    finish_snapshot_waiters(false, err)
  end
end

-- Waiters run after the endpoint leaves flight, so they observe its settled state.
local function settle_endpoint(endpoint, ok, err)
  endpoint.in_flight = false
  local waiters = endpoint.waiters
  endpoint.waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter(ok, err)
  end
end

local function fetch_local(endpoint, request_generation)
  client.ensure_server(function(ok, server_err)
    if request_generation ~= generation then
      return
    end
    if not ok then
      local terminal = server_err and (server_err.kind == "executable" or server_err.kind == "protocol")
      M._fail(server_err, { stop = terminal })
      settle_endpoint(endpoint, false, server_err)
      return
    end
    client.snapshot(function(snapshot, err)
      if request_generation ~= generation then
        return
      end
      if err then
        if err.kind == "process" or err.kind == "executable" then
          client.mark_server_unavailable()
        end
        local terminal = err.kind == "executable" or err.kind == "protocol"
        M._fail(err, { stop = terminal })
        settle_endpoint(endpoint, false, err)
        return
      end
      M._accept(snapshot)
      settle_endpoint(endpoint, true)
    end)
  end)
end

-- Forwarding never starts a remote server, so a machine needs no ensure_server step.
local function fetch_machine(endpoint, request_generation)
  client.snapshot(function(snapshot, err)
    if request_generation ~= generation then
      return
    end
    if err then
      M._fail(err, nil, endpoint.machine)
      settle_endpoint(endpoint, false, err)
      return
    end
    M._accept(snapshot, endpoint.machine)
    settle_endpoint(endpoint, true)
  end, endpoint.machine)
end

-- Starts every idle, due endpoint and joins endpoints already in flight. A slow machine
-- therefore never blocks the next Local poll. The callback runs once all joined endpoints
-- settle, succeeding when any of them produced a snapshot.
function M.refresh(opts, callback)
  opts = opts or {}
  callback = callback or function() end
  sync_endpoints()
  if opts.explicit then
    polling = true
    endpoints[LOCAL].stopped = false
  end
  local request_generation = generation
  local joined, to_start = {}, {}
  for _, key in ipairs(endpoint_order) do
    local endpoint = endpoints[key]
    local due = not endpoint.stopped and (not endpoint.machine or opts.retry or now() >= endpoint.retry_at)
    if endpoint.in_flight then
      table.insert(joined, endpoint)
    elseif due then
      table.insert(joined, endpoint)
      table.insert(to_start, endpoint)
    end
  end
  if #joined == 0 then
    callback(false, endpoints[LOCAL].error or { kind = "idle", message = "no Herdr source is due for refresh" })
    return
  end
  local pending, succeeded, first_error = #joined, false, nil
  local function settle(ok, err)
    if request_generation ~= generation then
      return
    end
    succeeded = succeeded or ok
    first_error = first_error or err
    pending = pending - 1
    if pending > 0 then
      return
    end
    if succeeded then
      polling = true
    end
    update_polling()
    ensure_timer()
    callback(succeeded, succeeded and current or first_error)
  end
  for _, endpoint in ipairs(joined) do
    table.insert(endpoint.waiters, settle)
  end
  for _, endpoint in ipairs(to_start) do
    endpoint.in_flight = true
    if endpoint.machine then
      fetch_machine(endpoint, request_generation)
    else
      fetch_local(endpoint, request_generation)
    end
  end
end

function M.start()
  if polling then
    return
  end
  polling = true
  M.refresh({ explicit = true })
end

-- Target resolution needs Local's current snapshot: without it, herdr.nvim cannot tell whether
-- an unqualified name exists on Local, so a remote-only view is not enough.
function M.ensure_snapshot(callback)
  sync_endpoints()
  local local_endpoint = endpoints[LOCAL]
  if current and local_endpoint.snapshot and not local_endpoint.stale then
    callback(true, current)
    return
  end
  table.insert(snapshot_waiters, callback)
  if #snapshot_waiters == 1 then
    M.refresh({ explicit = true }, finish_snapshot_waiters)
  end
end

function M.set_board_visible(value)
  board_visible = value == true
  restart_timer()
end

function M.get()
  sync_endpoints()
  local local_endpoint = endpoints[LOCAL]
  local last_error = local_endpoint.error
  local initialized = false
  for _, key in ipairs(endpoint_order) do
    last_error = last_error or endpoints[key].error
    initialized = initialized or endpoints[key].initialized == true
  end
  return {
    snapshot = current,
    stale = any_stale(),
    error = last_error,
    initialized = initialized,
    in_flight = any_in_flight(),
    polling = polling,
  }
end

local function endpoint_view(endpoint)
  return {
    machine = endpoint.machine,
    loaded = endpoint.snapshot ~= nil,
    -- A fresh view has a snapshot and no failure since it arrived.
    fresh = endpoint.snapshot ~= nil and not endpoint.stale,
    stale = endpoint.stale == true,
    error = endpoint.error,
    in_flight = endpoint.in_flight == true,
  }
end

-- Per-endpoint health for surfaces that show watched machines; Local is always first.
function M.endpoints()
  sync_endpoints()
  local result = {}
  for _, key in ipairs(endpoint_order) do
    table.insert(result, endpoint_view(endpoints[key]))
  end
  return result
end

-- Health of one endpoint: nil for Local, or a watched machine selector.
function M.endpoint(machine)
  sync_endpoints()
  local endpoint = endpoints[machine or LOCAL]
  return endpoint and endpoint_view(endpoint) or nil
end

function M.agents()
  return current and current.agents or {}
end

function M.agent(key)
  return by_key[key]
end

function M.counts()
  return counts(M.agents())
end

function M.acknowledge(key)
  sync_endpoints()
  local agent = by_key[key]
  local endpoint = agent and endpoints[agent.machine or LOCAL]
  if not agent or not endpoint or endpoint.stale or agent.status ~= "done" then
    return false
  end
  acknowledged[key] = agent.completion_seq or true
  emit_user("HerdrUpdated", { stale = any_stale(), counts = M.counts() })
  return true
end

local function same_project(agent_cwd, root)
  if not agent_cwd or not root then
    return false
  end
  local agent_path = vim.fn.fnamemodify(agent_cwd, ":p")
  local root_path = vim.fn.fnamemodify(root, ":p")
  agent_path = agent_path:gsub("/$", "")
  root_path = root_path:gsub("/$", "")
  agent_path = vim.fs.normalize(agent_path)
  root_path = vim.fs.normalize(root_path)
  return agent_path == root_path or agent_path:sub(1, #root_path + 1) == root_path .. "/"
end

local function group_key(machine, workspace_id)
  return (machine or LOCAL) .. "\n" .. workspace_id
end

function M.grouped_agents(opts)
  opts = opts or {}
  if not current then
    return {}
  end

  local groups_by_key = {}
  local groups = {}
  local function add_group(machine, workspace_id, label)
    local key = group_key(machine, workspace_id)
    local group = { key = key, machine = machine, workspace_id = workspace_id, label = label, agents = {} }
    groups_by_key[key] = group
    table.insert(groups, group)
    return group
  end
  for _, workspace in ipairs(current.workspaces) do
    add_group(workspace.machine, workspace.workspace_id, workspace.label)
  end
  local source_order = {}
  for index, agent in ipairs(current.agents) do
    source_order[agent.key] = index
    -- A remote cwd is a path on that machine, so it never matches the local project root.
    local in_project = not agent.machine and same_project(agent.cwd, opts.root)
    local visible = opts.all == true
      or (not acknowledged[agent.key] and (opts.root == nil or in_project or attention_status[agent.status]))
    if visible then
      local group = groups_by_key[group_key(agent.machine, agent.workspace_id)]
        or add_group(agent.machine, agent.workspace_id, agent.workspace_id)
      table.insert(group.agents, agent)
    end
  end
  local group_order = {}
  for index, group in ipairs(groups) do
    group_order[group.key] = index
    table.sort(group.agents, function(left, right)
      local left_rank = rank[left.status]
      local right_rank = rank[right.status]
      if left_rank == right_rank then
        return source_order[left.key] < source_order[right.key]
      end
      return left_rank < right_rank
    end)
  end
  groups = vim.tbl_filter(function(group)
    return #group.agents > 0
  end, groups)
  table.sort(groups, function(left, right)
    local left_rank = rank[left.agents[1].status]
    local right_rank = rank[right.agents[1].status]
    if left_rank == right_rank then
      return group_order[left.key] < group_order[right.key]
    end
    return left_rank < right_rank
  end)
  return groups
end

function M.stop()
  generation = generation + 1
  polling = false
  -- Outstanding requests belong to the old generation; their callbacks are ignored.
  for _, key in ipairs(endpoint_order) do
    endpoints[key].in_flight = false
    endpoints[key].waiters = {}
  end
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  timer = nil
  timer_running = false
  finish_snapshot_waiters(false, { kind = "lifecycle", message = "Herdr state stopped before snapshot" })
end

function M._set_timer_factory(value)
  timer_factory = value
end

function M._set_emit(value)
  emit_user = value
end

function M._set_transition_handler(value)
  transition_handler = value
end

function M._set_clock(value)
  now = value or function()
    return vim.uv.now()
  end
end

function M._reset()
  M.stop()
  endpoints = {}
  endpoint_order = {}
  current = nil
  by_key = {}
  acknowledged = {}
  board_visible = false
  polling = false
  failure_notifications = {}
  snapshot_waiters = {}
  now = function()
    return vim.uv.now()
  end
  timer_factory = function()
    return vim.uv.new_timer()
  end
  emit_user = function(pattern, data)
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data })
  end
  transition_handler = function(event)
    require("herdr.notifier").on_transition(event)
  end
end

return M
