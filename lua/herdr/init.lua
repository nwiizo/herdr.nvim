local M = {}

local initialized = false
local cleanup_group
local lifecycle_generation = 0
local pending_instructions = {}
local maintenance_running = false

local function message(err)
  if type(err) == "table" then
    local text = err.message or err.kind or vim.inspect(err)
    -- Herdr names the machine in transport errors but not in API errors such as agent_blocked.
    if err.machine and not text:find(err.machine, 1, true) then
      text = err.machine .. ": " .. text
    end
    return text
  end
  return tostring(err)
end

local function agent_label(agent)
  return require("herdr.client").agent_label(agent)
end

local function notify_error(err)
  vim.notify(message(err), vim.log.levels.ERROR, { title = "Herdr" })
end

local function has_api_code(err, code)
  return type(err) == "table" and (err.code == code or err.api_code == code)
end

local function notify_prompt_stalled(agent)
  vim.notify(
    string.format(
      "Herdr did not observe %s start the instruction; clear any provider setup screen, "
        .. "return to Herdr, and press p to retry the saved draft",
      agent_label(agent)
    ),
    vim.log.levels.WARN,
    { title = "Herdr" }
  )
end

local function valid_instruction(text)
  if type(text) ~= "string" then
    notify_error("instruction must be a string")
    return false
  end
  if #text > require("herdr.config").get().context.max_bytes then
    notify_error("instruction exceeds context.max_bytes")
    return false
  end
  return true
end

local function ensure_setup()
  if not initialized then
    M.setup()
  end
end

local function configured_agent_kinds()
  local agents = require("herdr.config").get().agents
  local result = {}
  for _, preferred in ipairs({ "codex", "claude" }) do
    if agents[preferred] then
      table.insert(result, preferred)
    end
  end
  local rest = {}
  for kind in pairs(agents) do
    if kind ~= "codex" and kind ~= "claude" then
      table.insert(rest, kind)
    end
  end
  table.sort(rest)
  vim.list_extend(result, rest)
  return result
end

local function with_agent_kind(kind, prompt, callback)
  if kind and kind ~= "" then
    callback(kind)
    return
  end
  local kinds = configured_agent_kinds()
  vim.ui.select(kinds, { prompt = prompt }, callback)
end

-- Targets are an agent key, or a terminal ID, pane ID, or name with an optional @machine.
-- Unqualified targets prefer Local, matching the Herdr CLI without --machine.
local function find_agent(target)
  local agents = require("herdr.state").agents()
  for _, agent in ipairs(agents) do
    if target == agent.key then
      return agent
    end
  end
  local base, machine = target:match("^(.+)@([^@]+)$")
  base = base or target
  local local_matches, remote_matches = {}, {}
  for _, agent in ipairs(agents) do
    local same_machine = machine == nil or agent.machine == machine
    local identifies = base == agent.terminal_id or base == agent.pane_id or base == agent.name
    if same_machine and identifies then
      table.insert(agent.machine and remote_matches or local_matches, agent)
    end
  end
  local matches = #local_matches > 0 and local_matches or remote_matches
  if #matches == 1 then
    return matches[1]
  end
  if #matches > 1 then
    local ids = vim.tbl_map(function(agent)
      return agent.key
    end, matches)
    return nil, string.format("agent name %q is ambiguous; use a terminal ID: %s", target, table.concat(ids, ", "))
  end
  return nil, string.format("unknown Herdr agent %q; run :HerdrRefresh", target)
end

local function with_target(target, callback)
  local state = require("herdr.state")
  state.ensure_snapshot(function(ok, snapshot_err)
    if not ok then
      notify_error(snapshot_err)
      return
    end
    if target and target ~= "" then
      local agent, err = find_agent(target)
      if not agent then
        notify_error(err)
        return
      end
      callback(agent)
      return
    end
    local agents = state.agents()
    if #agents == 0 then
      notify_error("no Herdr agents; run :HerdrStart codex or :HerdrStart claude")
    elseif #agents == 1 then
      callback(agents[1])
    else
      vim.ui.select(agents, {
        prompt = "Herdr agent:",
        format_item = function(agent)
          return string.format("%-12s %-8s %s  [%s]", agent_label(agent), agent.status, agent.cwd or "", agent.key)
        end,
      }, function(agent)
        if agent then
          callback(agent)
        end
      end)
    end
  end)
end

local function with_server(callback)
  require("herdr.client").ensure_server(function(ok, err)
    if not ok then
      notify_error(err)
      return
    end
    callback()
  end)
end

-- Forwarded commands need no Local server; only Local agents wait for ensure_server.
local function with_agent_server(agent, callback)
  if agent.machine then
    callback()
    return
  end
  with_server(callback)
end

-- Re-reads the agent from its own machine just before a mutation. The snapshot comes from
-- that machine, so its terminal ID identifies the same agent.
local function fresh_agent(agent, callback)
  local client = require("herdr.client")
  local function read_snapshot()
    client.snapshot(function(snapshot, err)
      if err then
        callback(nil, err)
        return
      end
      for _, candidate in ipairs(snapshot.agents) do
        if candidate.terminal_id == agent.terminal_id then
          callback(candidate)
          return
        end
      end
      callback(nil)
    end, agent.machine)
  end
  if agent.machine then
    read_snapshot()
    return
  end
  client.ensure_server(function(ok, server_err)
    if not ok then
      callback(nil, server_err)
      return
    end
    read_snapshot()
  end)
end

local function close_board()
  local board = require("herdr.board")
  if board.is_open() then
    board.close()
  end
end

-- Herdr does not forward `agent attach`, so a remote agent opens its machine's Herdr session.
local function attach_remote_agent(agent, callback)
  require("herdr.client").machine_profile(agent.machine, function(profile, err)
    if not profile then
      notify_error(err)
      return
    end
    close_board()
    local bufnr = require("herdr.terminal").attach_machine(agent, profile)
    if not bufnr then
      return
    end
    vim.notify(
      string.format(
        "Opened the Herdr session on %s; select %s (%s) there. %s returns to the board",
        agent.machine,
        agent.name,
        agent.pane_id,
        require("herdr.config").get().terminal.return_key
      ),
      vim.log.levels.INFO,
      { title = "Herdr" }
    )
    if callback then
      callback(bufnr)
    end
  end)
end

local function attach_agent(agent, opts, callback)
  if agent.machine then
    attach_remote_agent(agent, callback)
    return
  end
  local function open_terminal()
    close_board()
    local bufnr = require("herdr.terminal").attach(agent, opts)
    if bufnr and callback then
      callback(bufnr)
    end
  end

  if vim.env.HERDR_ENV ~= "1" then
    open_terminal()
    return
  end
  require("herdr.client").move_current_pane(agent.workspace_id, function(_, err)
    if err then
      notify_error("could not move Neovim to the agent's Herdr Space: " .. message(err))
      return
    end
    open_terminal()
  end)
end

-- Names are unique per Herdr server, so only the destination machine's agents are considered.
local function with_new_agent_name(kind, destination, explicit_name, callback)
  local client = require("herdr.client")
  local project = vim.fn.fnamemodify(destination.cwd, ":t")
  local default_name = client.default_agent_name(kind, project ~= "" and project or "agent")
  if explicit_name then
    local name, name_err = client.validate_agent_name(explicit_name)
    if name_err then
      notify_error(name_err)
      return
    end
    callback(name)
    return
  end
  require("herdr.state").ensure_snapshot(function(ok, snapshot)
    if not ok then
      notify_error(snapshot)
      return
    end
    local same_machine = vim.tbl_filter(function(agent)
      return agent.machine == destination.machine
    end, snapshot.agents)
    callback(client.next_agent_name(default_name, same_machine))
  end)
end

local function space_cwd(snapshot, workspace)
  for _, pane in ipairs(snapshot.panes or {}) do
    if pane.machine == workspace.machine and pane.workspace_id == workspace.workspace_id and pane.cwd then
      return pane.cwd
    end
  end
  return nil
end

-- Remote destinations are existing Spaces on watched machines: their absolute cwd comes from
-- that machine's snapshot, and Spaces for the same project name are listed first.
local function start_destinations(snapshot, cwd)
  local project = vim.fs.basename(cwd)
  local remote = {}
  for index, workspace in ipairs(snapshot and snapshot.workspaces or {}) do
    local remote_cwd = workspace.machine and space_cwd(snapshot, workspace)
    if remote_cwd then
      table.insert(remote, {
        machine = workspace.machine,
        workspace_id = workspace.workspace_id,
        label = workspace.label,
        cwd = remote_cwd,
        order = index,
        matches_project = vim.fs.basename(remote_cwd) == project,
      })
    end
  end
  table.sort(remote, function(left, right)
    if left.matches_project ~= right.matches_project then
      return left.matches_project
    end
    return left.order < right.order
  end)
  local result = { { cwd = cwd, label = project } }
  vim.list_extend(result, remote)
  return result
end

local function format_destination(destination)
  if not destination.machine then
    return string.format("Local · %s  %s", destination.label, vim.fn.fnamemodify(destination.cwd, ":~"))
  end
  return string.format("%s › %s  %s", destination.machine, destination.label, destination.cwd)
end

local function with_destination(opts, prompt, callback)
  local cwd = opts.cwd or require("herdr.context").project_root(0)
  if opts.machine then
    if not opts.cwd then
      notify_error("starting on a saved machine needs an absolute cwd on that machine")
      return
    end
    callback({ machine = opts.machine, cwd = opts.cwd, workspace_id = opts.workspace_id })
    return
  end
  if #require("herdr.config").get().machines == 0 then
    callback({ cwd = cwd })
    return
  end
  require("herdr.state").ensure_snapshot(function(ok, snapshot)
    local destinations = start_destinations(ok and snapshot or nil, cwd)
    if #destinations == 1 then
      callback(destinations[1])
      return
    end
    vim.ui.select(destinations, { prompt = prompt, format_item = format_destination }, function(destination)
      if destination then
        callback(destination)
      end
    end)
  end)
end

function M.setup(opts)
  require("herdr.config").setup(opts)
  if initialized then
    require("herdr.state").stop()
  end
  lifecycle_generation = lifecycle_generation + 1
  local setup_generation = lifecycle_generation
  require("herdr.client").mark_server_unavailable()
  require("herdr.board").setup()
  require("herdr.notifier")._reset()
  pending_instructions = {}
  initialized = true

  cleanup_group = vim.api.nvim_create_augroup("HerdrCleanup", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = cleanup_group,
    callback = function()
      require("herdr.state").stop()
      require("herdr.terminal").cleanup()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = cleanup_group,
    pattern = "HerdrUpdated",
    callback = function()
      for _, agent in ipairs(require("herdr.state").agents()) do
        if agent.status == "working" then
          pending_instructions[agent.key] = nil
        end
      end
    end,
  })
  vim.schedule(function()
    if initialized and lifecycle_generation == setup_generation then
      require("herdr.state").start()
    end
  end)
  return M
end

function M.toggle()
  ensure_setup()
  require("herdr.board").toggle()
end

function M.refresh()
  ensure_setup()
  -- An explicit refresh also retries machines that are waiting out a failure backoff.
  require("herdr.state").refresh({ explicit = true, retry = true }, function(ok, result)
    if not ok then
      notify_error(result)
    end
  end)
end

function M.update_all()
  ensure_setup()
  if maintenance_running then
    vim.notify("Herdr updates are already running", vim.log.levels.WARN, { title = "Herdr" })
    return
  end
  maintenance_running = true
  vim.notify("Updating Herdr server, integrations, and manifests...", vim.log.levels.INFO, { title = "Herdr" })
  local integrations = {}
  local agents = require("herdr.config").get().agents
  for _, name in ipairs({ "codex", "claude" }) do
    if agents[name] then
      table.insert(integrations, name)
    end
  end
  require("herdr.client").update_all(integrations, function(result, err)
    maintenance_running = false
    if err then
      notify_error(err)
      return
    end
    local updated = {}
    for _, name in ipairs(result.integrations) do
      updated[name] = true
    end
    local integration_statuses = {}
    for _, name in ipairs(integrations) do
      table.insert(integration_statuses, string.format("%s %s", name, updated[name] and "updated" or "current"))
    end
    local integration_summary = #integration_statuses > 0 and table.concat(integration_statuses, ", ")
      or "none configured"
    vim.notify(
      string.format(
        "Herdr updates complete: server %s; integrations %s; manifests updated",
        result.server == "handed_off" and "handed off" or "current",
        integration_summary
      ),
      vim.log.levels.INFO,
      { title = "Herdr" }
    )
    require("herdr.state").refresh({ explicit = true }, function(ok, refresh_err)
      if not ok then
        notify_error(refresh_err)
      end
    end)
  end)
end

function M.start(kind, opts)
  ensure_setup()
  opts = opts or {}
  with_agent_kind(kind, "Start agent:", function(selected_kind)
    if not selected_kind then
      return
    end
    if not require("herdr.config").get().agents[selected_kind] then
      notify_error("unknown agent kind: " .. selected_kind)
      return
    end
    local client = require("herdr.client")
    with_destination(opts, "Start agent where:", function(destination)
      with_new_agent_name(selected_kind, destination, opts.name, function(name)
        local function launch(instruction)
          if instruction == nil then
            return
          end
          if not valid_instruction(instruction) then
            return
          end
          with_agent_server(destination, function()
            client.start_agent(selected_kind, name, destination, function(_, err, allocation, started_agent)
              if err then
                notify_error(err)
                return
              end

              local function attach_started_agent()
                if not started_agent then
                  vim.notify(
                    "agent started, but Herdr did not return its terminal identity; refresh Herdr to attach",
                    vim.log.levels.WARN,
                    { title = "Herdr" }
                  )
                  require("herdr.state").refresh({ explicit = true })
                  return
                end
                attach_agent(started_agent, nil, function()
                  vim.notify(
                    string.format("started %s agent %s", selected_kind, agent_label(started_agent)),
                    vim.log.levels.INFO,
                    { title = "Herdr" }
                  )
                  require("herdr.state").refresh({ explicit = true })
                end)
              end

              if instruction == "" then
                attach_started_agent()
                return
              end
              client.prompt_until_working(
                started_agent and started_agent.target or allocation.pane_id,
                instruction,
                function(_, prompt_err)
                  if prompt_err then
                    if has_api_code(prompt_err, "agent_prompt_stalled") and started_agent then
                      pending_instructions[started_agent.key] = instruction
                      notify_prompt_stalled(started_agent)
                    else
                      notify_error(prompt_err)
                    end
                  elseif started_agent then
                    pending_instructions[started_agent.key] = nil
                  end
                  attach_started_agent()
                end,
                destination.machine
              )
            end)
          end)
        end

        if opts.instruction ~= nil then
          launch(opts.instruction)
        else
          vim.ui.input({ prompt = "Initial instruction (empty to skip, cancel to abort): " }, launch)
        end
      end)
    end)
  end)
end

function M.resume(kind, opts)
  ensure_setup()
  opts = opts or {}
  with_agent_kind(kind, "Resume conversation:", function(selected_kind)
    if not selected_kind then
      return
    end
    if selected_kind ~= "codex" and selected_kind ~= "claude" then
      notify_error("resume is not supported for agent kind: " .. selected_kind)
      return
    end
    if not require("herdr.config").get().agents[selected_kind] then
      notify_error("unknown agent kind: " .. selected_kind)
      return
    end
    vim.ui.select({ "Continue", "Cancel" }, {
      prompt = string.format("Stop the existing %s client before resuming it in Herdr.", selected_kind),
    }, function(choice)
      if choice ~= "Continue" then
        return
      end
      with_destination(opts, "Resume conversation where:", function(destination)
        with_new_agent_name(selected_kind, destination, opts.name, function(name)
          with_agent_server(destination, function()
            require("herdr.client").resume_agent(selected_kind, name, destination, function(_, err, _, started_agent)
              if err then
                notify_error(err)
                return
              end
              if not started_agent then
                vim.notify(
                  "resume picker started, but Herdr did not return its terminal identity; refresh Herdr to attach",
                  vim.log.levels.WARN,
                  { title = "Herdr" }
                )
                require("herdr.state").refresh({ explicit = true })
                return
              end
              attach_agent(started_agent, nil, function()
                vim.notify(
                  string.format("%s resume picker is ready; choose the conversation to rehome", selected_kind),
                  vim.log.levels.INFO,
                  { title = "Herdr" }
                )
                require("herdr.state").refresh({ explicit = true })
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

function M.attach(target, opts)
  ensure_setup()
  opts = opts or {}
  with_target(target, function(agent)
    if not agent then
      return
    end
    with_agent_server(agent, function()
      attach_agent(agent, opts)
    end)
  end)
end

function M.rename(target)
  ensure_setup()
  with_target(target, function(agent)
    vim.ui.input({ prompt = "Agent name: ", default = agent.registered_name or agent.name }, function(name)
      if not name or name == "" or name == agent.registered_name then
        return
      end
      local client = require("herdr.client")
      local _, name_err = client.validate_agent_name(name)
      if name_err then
        notify_error(name_err)
        return
      end
      fresh_agent(agent, function(current, snapshot_err)
        if snapshot_err then
          notify_error(snapshot_err)
          return
        end
        if not current or current.kind ~= agent.kind or current.registered_name ~= agent.registered_name then
          notify_error("agent changed while the rename prompt was open; select it again and retry")
          return
        end
        client.rename(current.target, name, function(_, err)
          if err then
            notify_error(err)
            return
          end
          vim.notify(
            string.format("renamed %s to %s", agent_label(agent), name),
            vim.log.levels.INFO,
            { title = "Herdr" }
          )
          require("herdr.state").refresh({ explicit = true })
        end, agent.machine)
      end)
    end)
  end)
end

local function blocked_guidance(agent)
  return string.format(
    "%s is waiting for approval or an answer; use :HerdrAttach %s to respond in the agent terminal",
    agent_label(agent),
    agent.key
  )
end

local function prompt_agent(agent, text, recovery)
  if not agent or not text or text == "" then
    return
  end
  if not valid_instruction(text) then
    return
  end
  if recovery then
    pending_instructions[agent.key] = text
  end
  local function retain_draft(err, attempted)
    local buffer = vim.api.nvim_create_buf(true, true)
    vim.bo[buffer].bufhidden = "hide"
    vim.api.nvim_buf_set_name(buffer, "herdr://draft/" .. buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(text, "\n", { plain = true }))
    local outcome = attempted and "delivery was not confirmed; inspect the agent before retrying"
      or "instruction was not sent"
    notify_error(message(err) .. "; " .. outcome .. ". Close Herdr, then :buffer " .. buffer .. " to recover the draft")
  end
  local client = require("herdr.client")
  local request_generation = lifecycle_generation
  fresh_agent(agent, function(current, snapshot_err)
    if snapshot_err then
      retain_draft(snapshot_err)
      return
    end
    if
      request_generation ~= lifecycle_generation
      or not current
      or current.kind ~= agent.kind
      or current.registered_name ~= agent.registered_name
    then
      retain_draft("agent or Herdr changed while preparing the instruction")
      return
    end
    if current.status == "blocked" then
      retain_draft(blocked_guidance(agent))
      return
    end
    local send = recovery and client.prompt_until_working or client.prompt
    send(current.target, text, function(_, err)
      if err then
        if has_api_code(err, "agent_blocked") then
          retain_draft(blocked_guidance(agent))
        elseif recovery and has_api_code(err, "agent_prompt_stalled") then
          notify_prompt_stalled(agent)
        else
          retain_draft(err, true)
        end
        return
      end
      if recovery then
        pending_instructions[agent.key] = nil
      end
      vim.notify("prompted " .. agent_label(agent), vim.log.levels.INFO, { title = "Herdr" })
    end, agent.machine)
  end)
end

-- Context is rendered before the target is resolved, so both path styles are frozen up front.
local function text_for(agent, texts)
  if type(texts) ~= "table" then
    return texts
  end
  return agent.machine and texts.remote or texts.local_text
end

local function prompt_text(target, texts)
  if not texts or texts == "" then
    return
  end
  with_target(target, function(agent)
    prompt_agent(agent, text_for(agent, texts))
  end)
end

local function concrete_buffer(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

-- Local agents get absolute paths. An agent on another machine cannot resolve this machine's
-- absolute paths, so it gets paths relative to the buffer's project root.
local function send_frozen_context(target, builder)
  local local_text, err = builder(false)
  if not local_text then
    local level = err == "buffer has no diagnostics" and vim.log.levels.INFO or vim.log.levels.ERROR
    vim.notify(err, level, { title = "Herdr" })
    return
  end
  local remote_text = builder(nil)
  prompt_text(target, { local_text = local_text, remote = remote_text or local_text })
end

function M.prompt(target, text)
  ensure_setup()
  if text ~= nil then
    prompt_text(target, text)
    return
  end
  with_target(target, function(agent)
    if agent.status == "blocked" then
      vim.notify(blocked_guidance(agent), vim.log.levels.INFO, { title = "Herdr" })
      return
    end
    local recovery = pending_instructions[agent.key] ~= nil
    vim.ui.input({ prompt = "Instruction: ", default = pending_instructions[agent.key] }, function(input)
      prompt_agent(agent, input, recovery)
    end)
  end)
end

function M._send_range(target, bufnr, line1, line2)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function(target_cwd)
    return require("herdr.context").range(captured_buffer, line1, line2, { target_cwd = target_cwd })
  end)
end

function M._send_visual(target, bufnr, line1, line2)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function(target_cwd)
    return require("herdr.context").range_from_marks(captured_buffer, line1, line2, { target_cwd = target_cwd })
  end)
end

function M._send_file(target, bufnr)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function(target_cwd)
    return require("herdr.context").file(captured_buffer, { target_cwd = target_cwd })
  end)
end

function M._send_diagnostics(target, bufnr)
  ensure_setup()
  local captured_buffer = concrete_buffer(bufnr)
  send_frozen_context(target, function(target_cwd)
    return require("herdr.context").diagnostics(captured_buffer, { target_cwd = target_cwd })
  end)
end

function M.statusline()
  local ok, result = pcall(function()
    if not initialized then
      return ""
    end
    local configured = require("herdr.config").get()
    if vim.fn.executable(configured.herdr_cmd) ~= 1 then
      return ""
    end
    local status = require("herdr.state").get()
    if not status.snapshot then
      return ""
    end
    local counts = require("herdr.state").counts()
    local parts = {}
    for _, key in ipairs({ "blocked", "done" }) do
      if counts[key] > 0 then
        table.insert(parts, configured.board.markers[key] .. counts[key])
      end
    end
    if status.stale then
      table.insert(parts, "~")
    end
    return #parts > 0 and "Herdr " .. table.concat(parts, " ") or ""
  end)
  return ok and result or ""
end

M.send = M.prompt

function M._complete_agents()
  local result = {}
  for _, agent in ipairs(require("herdr.state").agents()) do
    table.insert(result, agent.key)
  end
  return result
end

function M._find_agent(target)
  return find_agent(target)
end

function M._complete_agent_kinds()
  ensure_setup()
  return configured_agent_kinds()
end

function M._pending_instruction(key)
  return pending_instructions[key]
end

function M._reset()
  lifecycle_generation = lifecycle_generation + 1
  initialized = false
  maintenance_running = false
  if cleanup_group then
    pcall(vim.api.nvim_del_augroup_by_id, cleanup_group)
  end
  cleanup_group = nil
  pending_instructions = {}
end

return M
