local config = require("herdr.config")
local client = require("herdr.client")

local M = {}

-- Records are keyed by agent key; a saved machine has one session record ("machine:<selector>").
local terminals = {}
local jobstop = vim.fn.jobstop

local function machine_record_key(machine)
  return "machine:" .. machine
end

local function split_width(value)
  if value < 1 then
    return math.max(20, math.floor(vim.o.columns * value))
  end
  return value
end

local function open_split()
  local terminal_config = config.get().terminal
  local modifier = terminal_config.side == "left" and "topleft" or "botright"
  local width = split_width(terminal_config.width)
  vim.cmd(string.format("%s %dvnew", modifier, width))
  local window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(window, width)
  return window, vim.api.nvim_get_current_buf()
end

local function focus_buffer(bufnr)
  local windows = vim.fn.win_findbuf(bufnr)
  if #windows > 0 and vim.api.nvim_win_is_valid(windows[1]) then
    vim.api.nvim_set_current_win(windows[1])
    return windows[1]
  end
  local window = open_split()
  vim.api.nvim_win_set_buf(window, bufnr)
  return window
end

local function wipe_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

-- Ends the session shown in `bufnr`. The buffer is wiped only after its job exits, because Neovim
-- runs a job's exit callback after the PTY streams have flushed and closed. Wiping a terminal while a
-- write to its PTY is pending (a focus report, or a reply to the TUI's color queries) makes Neovim
-- re-queue the terminal teardown forever at full CPU (term_delayed_free in src/nvim/channel.c).
local function stop_session(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].herdr_stopping then
    return
  end
  vim.b[bufnr].herdr_stopping = true
  for record_key, record in pairs(terminals) do
    if record.bufnr == bufnr then
      terminals[record_key] = nil
      pcall(jobstop, record.job_id)
      return
    end
  end
  -- No record means the job's exit callback already ran, so its PTY streams are closed.
  vim.schedule(function()
    wipe_buffer(bufnr)
  end)
end

-- Exit callbacks call this first; a session stopped by Neovim only needs its buffer wiped.
local function finish_stopped(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].herdr_stopping then
    wipe_buffer(bufnr)
    return true
  end
  return false
end

local function return_to_board(bufnr, agent_key)
  stop_session(bufnr)
  local window = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(window) == bufnr and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(window, true)
  end
  vim.schedule(function()
    require("herdr.board").open({ key = agent_key })
  end)
end

-- `selected_key` is read when the key is pressed, so a machine session returns to the latest agent.
local function install_return_mapping(bufnr, selected_key)
  local opts = {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Return to Herdr",
  }
  vim.keymap.set({ "t", "n" }, config.get().terminal.return_key, function()
    return_to_board(bufnr, selected_key())
  end, opts)
end

local function track(record_key, bufnr, job_id, extra)
  terminals[record_key] = vim.tbl_extend("force", { bufnr = bufnr, job_id = job_id }, extra or {})
  -- Closing the last window on a session ends it, however the window was closed.
  vim.api.nvim_create_autocmd("BufHidden", {
    buffer = bufnr,
    once = true,
    callback = function()
      stop_session(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      local record = terminals[record_key]
      if record and record.bufnr == bufnr then
        terminals[record_key] = nil
      end
    end,
  })
end

local function release(record_key, bufnr)
  local record = terminals[record_key]
  local active = record and record.bufnr == bufnr
  if active then
    terminals[record_key] = nil
  end
  return active
end

local function focus_existing(record_key)
  local existing = terminals[record_key]
  if existing and vim.api.nvim_buf_is_valid(existing.bufnr) then
    focus_buffer(existing.bufnr)
    if config.get().terminal.auto_insert then
      vim.cmd("startinsert")
    end
    return existing
  end
  return nil
end

function M.attach(agent, opts)
  opts = opts or {}
  local agent_key = agent.key or agent.terminal_id
  local existing = focus_existing(agent_key)
  if existing then
    return existing.bufnr
  end

  local _, bufnr = open_split()
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.b[bufnr].herdr_terminal_id = agent.terminal_id
  vim.b[bufnr].herdr_agent_key = agent_key
  install_return_mapping(bufnr, function()
    return agent_key
  end)
  local attach_output = ""
  local job_id, attach_err = client.attach(agent.target or agent.pane_id, opts.takeover == true, {
    on_stdout = function(_, data)
      -- Keep diagnostics intact before terminal wrapping and blank-row padding.
      attach_output = (attach_output .. table.concat(data, "\n")):sub(-4096)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if finish_stopped(bufnr) then
          return
        end
        local active = release(agent_key, bufnr)
        if active and code == 0 and vim.v.exiting == vim.NIL and vim.api.nvim_get_current_buf() == bufnr then
          return_to_board(bufnr, agent_key)
        elseif active and code ~= 0 and vim.v.exiting == vim.NIL then
          local lower = attach_output:lower()
          if lower:find("takeover", 1, true) or lower:find("another client", 1, true) then
            vim.notify(
              string.format(
                "Herdr attach for %s is owned by another client; use :HerdrAttach! %s to take over",
                agent.name,
                agent_key
              ),
              vim.log.levels.WARN,
              { title = "Herdr" }
            )
          else
            vim.notify(
              string.format("Herdr attach for %s exited with code %d; run :HerdrHealth", agent.name, code),
              vim.log.levels.WARN,
              { title = "Herdr" }
            )
          end
        end
      end)
    end,
  })
  if not job_id then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.notify(attach_err.message, vim.log.levels.ERROR, { title = "Herdr" })
    return nil
  end
  track(agent_key, bufnr, job_id)
  if config.get().terminal.auto_insert then
    vim.cmd("startinsert")
  end
  return bufnr
end

-- Opens (or reuses) the saved machine's Herdr session; the operator selects the agent there.
function M.attach_machine(agent, profile)
  local record_key = machine_record_key(agent.machine)
  local existing = focus_existing(record_key)
  if existing then
    existing.agent_key = agent.key
    return existing.bufnr
  end

  local _, bufnr = open_split()
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.b[bufnr].herdr_machine = agent.machine
  install_return_mapping(bufnr, function()
    local record = terminals[record_key]
    return record and record.agent_key or agent.key
  end)
  local job_id, attach_err = client.attach_machine(profile, {
    on_exit = function(_, code)
      vim.schedule(function()
        if finish_stopped(bufnr) then
          return
        end
        local record = terminals[record_key]
        local selected = record and record.agent_key or agent.key
        local active = release(record_key, bufnr)
        if active and code == 0 and vim.v.exiting == vim.NIL and vim.api.nvim_get_current_buf() == bufnr then
          return_to_board(bufnr, selected)
        elseif active and code ~= 0 and vim.v.exiting == vim.NIL then
          vim.notify(
            string.format("Herdr session for %s exited with code %d; run :HerdrHealth", agent.machine, code),
            vim.log.levels.WARN,
            { title = "Herdr" }
          )
        end
      end)
    end,
  })
  if not job_id then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.notify(attach_err.message, vim.log.levels.ERROR, { title = "Herdr" })
    return nil
  end
  track(record_key, bufnr, job_id, { agent_key = agent.key })
  if config.get().terminal.auto_insert then
    vim.cmd("startinsert")
  end
  return bufnr
end

function M.cleanup()
  for _, record in pairs(terminals) do
    if type(record.job_id) == "number" and record.job_id > 0 then
      pcall(jobstop, record.job_id)
    end
  end
  terminals = {}
end

function M.is_attached(agent_key, bufnr)
  local record = terminals[agent_key]
  if record == nil or not vim.api.nvim_buf_is_valid(record.bufnr) then
    return false
  end
  return bufnr == nil or record.bufnr == bufnr
end

function M._set_termopen(value)
  client._set_termopen(value)
end

function M._set_jobstop(value)
  jobstop = value or vim.fn.jobstop
end

function M._terminals()
  return terminals
end

function M._reset()
  for _, record in pairs(terminals) do
    if vim.api.nvim_buf_is_valid(record.bufnr) then
      vim.api.nvim_buf_delete(record.bufnr, { force = true })
    end
  end
  terminals = {}
  client._set_termopen(nil)
  jobstop = vim.fn.jobstop
end

return M
