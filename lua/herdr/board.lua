local config = require("herdr.config")
local state = require("herdr.state")

local M = {}

local list_buffer
local list_window
local preview_buffer
local preview_window
local line_agents = {}
local help_visible = false
local show_all = false
local preview_enabled = true
local preview_mode = "output"
local preview_generation = 0
local preview_target
local preview_in_flight
local preview_last_read = 0
local preview_cache = {}
local paused_preview
local closing_windows = false
local origin_root
local augroup
local namespace = vim.api.nvim_create_namespace("herdr-board")
-- Stay below Snacks layout 30, picker preview 40, and the default modal layer 50.
local board_zindex = 25

local highlight_for = {
  blocked = "HerdrBlocked",
  working = "HerdrWorking",
  done = "HerdrDone",
  idle = "HerdrIdle",
  unknown = "HerdrUnknown",
}

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function focus_list_window()
  if valid_window(list_window) then
    vim.api.nvim_set_current_win(list_window)
  end
end

local function focus_preview_window()
  if valid_window(preview_window) then
    vim.api.nvim_set_current_win(preview_window)
  end
end

function M.is_open()
  return valid_window(list_window)
end

function M.is_visible()
  return M.is_open() and vim.api.nvim_win_get_tabpage(list_window) == vim.api.nvim_get_current_tabpage()
end

local function dimension(value, total, minimum)
  local size = value < 1 and math.floor(total * value) or value
  return math.min(math.max(minimum, size), math.max(1, total - 4))
end

local function geometry()
  local board = config.get().board
  local total_width = dimension(board.width, vim.o.columns, 68)
  local height = dimension(board.height, vim.o.lines - vim.o.cmdheight, 10)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))
  if not preview_enabled and not help_visible then
    return { row = row, col = col, height = height, list_width = total_width }
  end
  local usable_width = total_width - 2
  if help_visible then
    local list_width = math.min(28, math.max(16, math.floor(usable_width * 0.25)))
    local preview_width = usable_width - list_width
    return {
      row = row,
      col = col,
      height = height,
      list_width = list_width,
      preview_col = col + total_width - preview_width,
      preview_width = preview_width,
    }
  end
  local minimum_list_width = math.min(36, math.max(24, math.floor(usable_width * 0.6)))
  local maximum_preview_width = math.max(16, usable_width - minimum_list_width)
  local preview_width = math.min(math.floor(usable_width * board.preview_ratio), maximum_preview_width)
  return {
    row = row,
    col = col,
    height = height,
    list_width = total_width - preview_width - 2,
    preview_col = col + total_width - preview_width,
    preview_width = preview_width,
  }
end

local function truncate(value, width)
  value = tostring(value or "")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(value) <= width then
    return value
  end
  local result = ""
  for index = 0, vim.fn.strchars(value) - 1 do
    local candidate = result .. vim.fn.strcharpart(value, index, 1)
    if vim.fn.strdisplaywidth(candidate .. "…") > width then
      break
    end
    result = candidate
  end
  return result .. "…"
end

-- Buffer lines cannot contain newlines; Herdr and SSH errors can span several lines.
local function one_line(value)
  return (tostring(value or ""):gsub("%s+", " "))
end

local function pad(value, width)
  local result = truncate(value, width)
  return result .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(result)))
end

local function agent_line(agent, marker, width)
  if width >= 35 then
    return string.format(" %s %s %s %s", marker, pad(agent.name, 15), pad(agent.kind, 7), agent.status)
  end
  local status_width = vim.fn.strdisplaywidth(agent.status)
  local name_width = math.max(6, width - status_width - 5)
  return string.format(" %s %s %s", marker, pad(agent.name, name_width), agent.status)
end

local function summary_title()
  local counts = state.counts()
  local markers = config.get().board.markers
  local parts = { { " [1]-Herdr ", "HerdrTitle" } }
  for _, key in ipairs({ "blocked", "working", "done" }) do
    if counts[key] > 0 then
      table.insert(parts, { " " .. markers[key] .. counts[key] .. " ", highlight_for[key] })
    end
  end
  if state.get().stale then
    table.insert(parts, { " ~stale ", "HerdrUnknown" })
  end
  table.insert(parts, { " ? guide ", "HerdrMuted" })
  return parts
end

local function selected_agent()
  if not M.is_open() then
    return nil
  end
  return line_agents[vim.api.nvim_win_get_cursor(list_window)[1]]
end

local function selected_id()
  local agent = selected_agent()
  return agent and agent.key or nil
end

local function agent_label(agent)
  return require("herdr.client").agent_label(agent)
end

local function set_lines(buffer, lines)
  if not valid_buffer(buffer) then
    return false
  end
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), lines) then
    return false
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  return true
end

local function preview_message(lines)
  return set_lines(preview_buffer, lines)
end

local function set_title(window, title)
  if not valid_window(window) or vim.deep_equal(vim.api.nvim_win_get_config(window).title, title) then
    return
  end
  pcall(vim.api.nvim_win_set_config, window, { title = title })
end

local function preview_title(agent, suffix_group)
  local hint = paused_preview and "· paused · P resume · i attach · ? guide "
    or preview_mode == "explain" and "· detection · e output · i attach · ? guide "
    or "· read-only · P pause · e explain · i attach · ? guide "
  return {
    { " [2]-Preview ", "HerdrTitle" },
    { "· " .. agent_label(agent) .. " ", highlight_for[agent.status] },
    { hint, suffix_group or "HerdrMuted" },
  }
end

local function empty_preview_title()
  return {
    { " [2]-Preview ", "HerdrTitle" },
    { "· read-only · select agent · i attach · ? guide ", "HerdrMuted" },
  }
end

local function guide_title()
  return {
    { " [2]-Preview ", "HerdrTitle" },
    { "· guide · input → result · ? close ", "HerdrMuted" },
  }
end

local function guide_content(width)
  local entries = {
    { key = "j / k", result = "Next / previous agent; in the right pane, scroll." },
    { key = "1 / 2", result = "Focus agent list / right pane." },
    { key = "<Tab>", result = "Switch between list and right pane." },
    { key = "<C-d/u>", result = "In the right pane, scroll half a page." },
    { heading = "SELECTED AGENT" },
    {
      key = "<CR> / i",
      result = "Attach to type or answer approval/question UI."
        .. (vim.env.HERDR_ENV == "1" and " Cross-Space attach moves Neovim first." or "")
        .. (#config.get().machines > 0 and " name@machine opens that machine's Herdr session." or ""),
    },
    { key = "p / s", result = "Send instruction; blocked agents need attach first." },
    { key = "e", result = "Show Herdr state evidence." },
    { key = "n", result = "Enter name → rename agent." },
    { key = "x", result = "Acknowledge done → hide until next completion; A shows all." },
    { heading = "ATTACHED TERMINAL — INPUT MODE" },
    { key = config.get().terminal.return_key, result = "Detach and select the same agent; agent keeps running." },
    { key = "PgUp/PgDn", result = "Scroll Herdr history; typing returns to the bottom." },
    { key = "<C-b> q", result = "Herdr native detach; return to Herdr." },
    { key = "<C-b> twice", result = "Send a literal Ctrl-b to the agent." },
    { key = "<C-\\><C-n>", result = "Neovim Normal mode to select/copy; i resumes input." },
    { heading = "NEW WORK" },
    { key = "a", result = "Agent + instruction → start + attach." },
    { key = "R", result = "Agent → resume picker + attach." },
    { heading = "VIEW AND TOOLS" },
    { key = "A", result = "Attention view ↔ all agents." },
    { key = "v", result = "Show / hide output preview." },
    { key = "P", result = "Pause / resume output for reading and copying; agent keeps running." },
    { key = "g / d", result = "Lazygit / Diffview at agent repo." },
    { key = "r", result = "Refresh Herdr state." },
    { key = "? / q", result = "Close guide / close Herdr." },
  }
  local lines = { "INPUT → RESULT" }
  local highlights = { { line = 1, group = "HerdrGuideHeader", start_col = 0, end_col = -1 } }
  local wide = width >= 40
  for _, entry in ipairs(entries) do
    if entry.heading then
      table.insert(lines, entry.heading)
      table.insert(highlights, { line = #lines, group = "HerdrGuideHeader", start_col = 0, end_col = -1 })
    elseif wide then
      table.insert(lines, string.format("%-10s %s", entry.key, entry.result))
      table.insert(highlights, { line = #lines, group = "HerdrGuideKey", start_col = 0, end_col = #entry.key })
    else
      table.insert(lines, entry.key)
      table.insert(highlights, { line = #lines, group = "HerdrGuideKey", start_col = 0, end_col = -1 })
      table.insert(lines, "  " .. entry.result)
    end
  end
  return lines, highlights
end

local function render_guide()
  local width = vim.api.nvim_win_get_width(preview_window)
  local guide_target = string.format("guide:%d:%s", width, config.get().terminal.return_key)
  if preview_target == guide_target then
    return
  end
  preview_target = guide_target
  preview_in_flight = nil
  local lines, highlights = guide_content(width)
  preview_message(lines)
  vim.api.nvim_buf_clear_namespace(preview_buffer, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(
      preview_buffer,
      namespace,
      highlight.group,
      highlight.line - 1,
      highlight.start_col,
      highlight.end_col
    )
  end
  set_title(preview_window, guide_title())
end

function M.refresh_preview(opts)
  opts = opts or {}
  if (not preview_enabled and not help_visible) or not valid_window(preview_window) then
    return
  end
  if help_visible then
    render_guide()
    return
  end
  vim.api.nvim_buf_clear_namespace(preview_buffer, namespace, 0, -1)
  local agent = selected_agent()
  if not agent then
    paused_preview = nil
    if preview_target ~= false then
      preview_generation = preview_generation + 1
      preview_target = false
      preview_in_flight = nil
      preview_message({
        "Select an agent to inspect its recent output.",
        "",
        "This preview is read-only. Press i or <CR> to attach and type.",
        "Its contents are ephemeral and are never written to disk.",
      })
      set_title(preview_window, empty_preview_title())
    end
    return
  end
  local cache_key = preview_mode .. ":" .. agent.key
  if paused_preview == cache_key then
    preview_target = cache_key
    preview_message(preview_cache[cache_key])
    set_title(preview_window, preview_title(agent))
    return
  end
  paused_preview = nil
  -- Reading from a failing machine would bypass its retry backoff; keep the last output instead.
  local endpoint = agent.machine and state.endpoint(agent.machine)
  if endpoint and endpoint.error then
    preview_target = cache_key
    preview_in_flight = nil
    preview_message(preview_cache[cache_key] or {
      string.format("%s is unavailable, so its output is not read.", agent.machine),
      "",
      "Press r to retry now; the preview resumes after the machine responds.",
    })
    set_title(preview_window, preview_title(agent, "HerdrUnknown"))
    return
  end
  local changed = preview_target ~= cache_key
  local now = vim.uv.now()
  local throttle_ms = math.max(500, config.get().refresh.board_ms)
  if preview_in_flight == cache_key or (not changed and not opts.force and now - preview_last_read < throttle_ms) then
    return
  end

  preview_target = cache_key
  preview_in_flight = cache_key
  preview_last_read = now
  preview_generation = preview_generation + 1
  local generation = preview_generation
  if changed then
    local cached = preview_cache[cache_key]
    local pending = preview_mode == "explain" and string.format("Explaining %s state…", agent_label(agent))
      or string.format("Reading %s…", agent_label(agent))
    preview_message(cached or { pending })
    set_title(preview_window, preview_title(agent))
  end
  local callback = function(output, err)
    if generation ~= preview_generation or not valid_buffer(preview_buffer) then
      return
    end
    preview_in_flight = nil
    if err then
      if not preview_cache[cache_key] then
        local label = preview_mode == "explain" and "Explanation unavailable" or "Preview unavailable"
        local preview_lines = { label, "" }
        vim.list_extend(
          preview_lines,
          vim.split(tostring(err.message or err.kind or err), "\n", { plain = true, trimempty = true })
        )
        preview_message(preview_lines)
      end
      set_title(preview_window, preview_title(agent, "HerdrUnknown"))
      return
    end
    local lines = vim.split((output or ""):gsub("%s+$", ""), "\n", { plain = true })
    if #lines == 1 and lines[1] == "" then
      lines = { preview_mode == "explain" and "Herdr returned no detection explanation." or "No terminal output yet." }
    end
    preview_cache[cache_key] = lines
    set_lines(preview_buffer, lines)
    set_title(preview_window, preview_title(agent))
  end
  if preview_mode == "explain" then
    require("herdr.client").explain(agent.target, callback, agent.machine)
  else
    require("herdr.client").read(agent.target, config.get().board.preview_lines, callback, agent.machine)
  end
end

local function render_guidance(lines, err)
  if err.kind == "executable" then
    table.insert(lines, "Install Herdr TUI: https://herdr.dev/tui/")
    table.insert(lines, "Run :checkhealth herdr")
  elseif err.kind == "server" then
    table.insert(lines, "Run: " .. config.get().herdr_cmd .. " server")
    table.insert(lines, "Press r to retry")
  elseif err.kind == "protocol" then
    table.insert(lines, "Update Herdr, then run :HerdrHealth")
  else
    table.insert(lines, "Press r to retry; run :HerdrHealth")
  end
end

local function empty_view_lines(stale)
  if stale then
    return { "No agents in the last view.", "r: retry   A: show all agents", "q: return to editing" }
  end
  local agents = state.agents()
  if #agents == 0 then
    return { "No agents in this Herdr session.", "a: start   R: resume", "q: return to editing" }
  end
  local all_reviewed = state.counts().done == 0
  for _, agent in ipairs(agents) do
    all_reviewed = all_reviewed and agent.status == "done"
  end
  if all_reviewed then
    return { "All completions reviewed.", "A: show reviewed agents", "q: return to editing" }
  end
  return { "No agents match this view.", "A: show all agents", "q: return to editing" }
end

-- Per-endpoint failures are listed only when saved machines are watched; a Local-only board
-- keeps its single "Last refresh failed" line.
local function endpoint_failure_lines(width)
  local result = {}
  for _, endpoint in ipairs(state.endpoints()) do
    if endpoint.error then
      local detail = one_line(endpoint.error.message or endpoint.error.kind or "refresh failed")
      local outcome = endpoint.stale and "showing last view" or "unavailable"
      table.insert(result, {
        text = truncate(string.format("%s %s: %s", endpoint.machine or "Local", outcome, detail), width - 2),
        group = endpoint.stale and "HerdrUnknown" or "HerdrBlocked",
      })
    end
  end
  return result
end

local function group_heading(group)
  return group.machine and (group.machine .. " › " .. group.label) or group.label
end

function M.render(preferred_id)
  if not valid_buffer(list_buffer) then
    return
  end
  local selected = preferred_id or selected_id()
  local status = state.get()
  local width = valid_window(list_window) and vim.api.nvim_win_get_width(list_window) or 44
  local view_label = show_all and "all agents" or "this project + attention elsewhere"
  local lines = { truncate(" " .. view_label, width - 1), "" }
  local highlights = { [1] = "HerdrMuted" }
  line_agents = {}

  if not status.snapshot then
    if status.error then
      table.insert(lines, "Herdr unavailable")
      highlights[#lines] = "HerdrBlocked"
      table.insert(lines, truncate(one_line(status.error.message or "unknown error"), width - 2))
      render_guidance(lines, status.error)
    else
      table.insert(lines, "Loading Herdr agents…")
      highlights[#lines] = "HerdrWorking"
    end
  else
    if #config.get().machines > 0 then
      local failures = endpoint_failure_lines(width)
      for _, failure in ipairs(failures) do
        table.insert(lines, failure.text)
        highlights[#lines] = failure.group
      end
      if #failures > 0 then
        table.insert(lines, truncate("r: retry now   :HerdrHealth for details", width - 2))
        highlights[#lines] = "HerdrMuted"
        table.insert(lines, "")
      end
    elseif status.stale and status.error then
      table.insert(
        lines,
        truncate("Last refresh failed: " .. one_line(status.error.message or status.error.kind), width - 2)
      )
      table.insert(lines, "")
    end
    local groups = state.grouped_agents({ root = origin_root, all = show_all })
    if not show_all then
      local visible = {}
      for _, group in ipairs(groups) do
        for _, agent in ipairs(group.agents) do
          visible[agent.key] = true
        end
      end
      local hidden_working = 0
      for _, agent in ipairs(state.agents()) do
        if agent.status == "working" and not visible[agent.key] then
          hidden_working = hidden_working + 1
        end
      end
      if hidden_working > 0 then
        lines[2] = truncate(string.format(" A: %d working elsewhere", hidden_working), width - 1)
        highlights[2] = "HerdrWorking"
      end
    end
    if #groups == 0 then
      -- A failing machine is reported above; "last view" wording follows the Local session.
      for _, line in ipairs(empty_view_lines(state.endpoints()[1].stale)) do
        table.insert(lines, truncate(line, width - 1))
      end
    end
    for _, group in ipairs(groups) do
      table.insert(lines, truncate(group_heading(group), width - 2))
      highlights[#lines] = "HerdrWorkspace"
      for _, agent in ipairs(group.agents) do
        local marker = config.get().board.markers[agent.status]
        local line = agent_line(agent, marker, width)
        table.insert(lines, truncate(line, width - 1))
        line_agents[#lines] = agent
        highlights[#lines] = highlight_for[agent.status]
      end
      table.insert(lines, "")
    end
  end

  local contents_changed = set_lines(list_buffer, lines)
  if contents_changed then
    vim.api.nvim_buf_clear_namespace(list_buffer, namespace, 0, -1)
    for line, group in pairs(highlights) do
      vim.api.nvim_buf_add_highlight(list_buffer, namespace, group, line - 1, 0, -1)
    end
  end

  if valid_window(list_window) then
    set_title(list_window, summary_title())
    local target_line
    if selected then
      for line, agent in pairs(line_agents) do
        if agent.key == selected then
          target_line = line
          break
        end
      end
    end
    if not target_line then
      for line = 1, #lines do
        if line_agents[line] then
          target_line = line
          break
        end
      end
    end
    target_line = target_line or 1
    if vim.api.nvim_win_get_cursor(list_window)[1] ~= target_line then
      pcall(vim.api.nvim_win_set_cursor, list_window, { target_line, 0 })
    end
  end
  vim.schedule(M.refresh_preview)
end

local function move_selection(direction)
  local rows = vim.tbl_keys(line_agents)
  table.sort(rows)
  if #rows == 0 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(list_window)[1]
  local index = direction > 0 and #rows or 1
  for position, line in ipairs(rows) do
    if direction > 0 and line > cursor then
      index = math.min(#rows, position + vim.v.count1 - 1)
      break
    elseif direction < 0 and line < cursor then
      index = math.max(1, position - vim.v.count1 + 1)
    end
  end
  vim.api.nvim_win_set_cursor(list_window, { rows[index], 0 })
  M.refresh_preview()
end

local function require_agent_row()
  local agent = selected_agent()
  if not agent then
    vim.notify("Select an agent row first", vim.log.levels.INFO, { title = "Herdr" })
  end
  return agent
end

local function attach_selected()
  local agent = require_agent_row()
  if agent then
    require("herdr").attach(agent.key)
  end
end

local function prompt_selected()
  local agent = require_agent_row()
  if agent then
    require("herdr").prompt(agent.key)
  end
end

local function rename_selected()
  local agent = require_agent_row()
  if agent then
    require("herdr").rename(agent.key)
  end
end

-- Lazygit and Diffview run locally; a remote agent's cwd is a path on its own machine.
local function open_repository_tool(action)
  local agent = selected_agent()
  if agent and agent.machine then
    vim.notify(
      string.format("%s works in a repository on %s; inspect it on that machine", agent_label(agent), agent.machine),
      vim.log.levels.INFO,
      { title = "Herdr" }
    )
    return
  end
  M.close()
  require("herdr.actions")[action](agent, origin_root)
end

local function acknowledge_selected()
  local agent = require_agent_row()
  if not agent then
    return
  end
  if not state.acknowledge(agent.key) then
    vim.notify("Select a completed agent with fresh state first", vim.log.levels.INFO, { title = "Herdr" })
    return
  end
  M.render()
end

local function toggle_explanation()
  if not require_agent_row() then
    return
  end
  preview_mode = preview_mode == "explain" and "output" or "explain"
  paused_preview = nil
  preview_target = nil
  M.refresh_preview({ force = true })
end

local function toggle_preview_pause()
  local agent = require_agent_row()
  if not agent then
    return
  end
  local cache_key = "output:" .. agent.key
  if help_visible or not valid_window(preview_window) or preview_mode ~= "output" or not preview_cache[cache_key] then
    vim.notify("Show the agent's output preview before pausing it", vim.log.levels.INFO, { title = "Herdr" })
    return
  end
  paused_preview = paused_preview ~= cache_key and cache_key or nil
  -- A response already in flight must not replace the text being copied.
  preview_generation = preview_generation + 1
  preview_in_flight = nil
  preview_target = nil
  M.refresh_preview({ force = true })
end

local function toggle_help()
  help_visible = not help_visible
  preview_generation = preview_generation + 1
  preview_target = nil
  preview_in_flight = nil
  local needs_preview = preview_enabled or help_visible
  if valid_window(preview_window) ~= needs_preview then
    M._reopen_windows()
  else
    M._resize_windows()
  end
end

local function configure_buffer(buffer, filetype, name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = filetype
  vim.bo[buffer].buflisted = false
  pcall(vim.api.nvim_buf_set_name, buffer, "herdr://" .. name)
  local function map(lhs, callback, description)
    vim.keymap.set("n", lhs, callback, { buffer = buffer, silent = true, nowait = true, desc = description })
  end

  map("<CR>", attach_selected, "Attach to agent")
  map("i", attach_selected, "Attach and type in agent")
  map("p", prompt_selected, "Prompt agent")
  map("s", prompt_selected, "Prompt agent")
  map("n", rename_selected, "Rename agent")
  map("x", acknowledge_selected, "Acknowledge completion")
  map("e", toggle_explanation, "Toggle agent state explanation")
  map("P", toggle_preview_pause, "Pause or resume output preview")
  map("a", function()
    require("herdr").start(nil, { cwd = origin_root })
  end, "Start agent")
  map("R", function()
    require("herdr").resume(nil, { cwd = origin_root })
  end, "Resume conversation in Herdr")
  map("g", function()
    open_repository_tool("lazygit")
  end, "Open Lazygit")
  map("d", function()
    open_repository_tool("diffview")
  end, "Open Diffview")
  map("v", function()
    preview_enabled = not preview_enabled
    M._reopen_windows()
  end, "Toggle preview")
  map("A", function()
    show_all = not show_all
    M.render()
  end, "Toggle all agents")
  map("r", function()
    require("herdr").refresh()
  end, "Refresh agents")
  map("q", M.close, "Close Herdr")
  map("?", toggle_help, "Toggle input guide")
  map("1", focus_list_window, "Focus agent list")
  map("2", focus_preview_window, "Focus right pane")
  if buffer == list_buffer then
    map("j", function()
      move_selection(1)
    end, "Next agent")
    map("k", function()
      move_selection(-1)
    end, "Previous agent")
    map("<Tab>", focus_preview_window, "Focus read-only preview")
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buffer,
      callback = function()
        vim.schedule(M.refresh_preview)
      end,
    })
  else
    map("<Tab>", focus_list_window, "Focus agent list")
  end
end

local function open_windows()
  local layout = geometry()
  list_window = vim.api.nvim_open_win(list_buffer, true, {
    relative = "editor",
    row = layout.row,
    col = layout.col,
    width = layout.list_width,
    height = layout.height,
    style = "minimal",
    border = "rounded",
    title = summary_title(),
    title_pos = "center",
    zindex = board_zindex,
  })
  vim.wo[list_window].wrap = false
  vim.wo[list_window].cursorline = true
  vim.wo[list_window].signcolumn = "no"
  vim.wo[list_window].winhighlight = table.concat({
    "Normal:NormalFloat",
    "FloatBorder:HerdrBorder",
    "FloatTitle:HerdrTitle",
    "CursorLine:CursorLine",
  }, ",")

  if preview_enabled or help_visible then
    preview_window = vim.api.nvim_open_win(preview_buffer, false, {
      relative = "editor",
      row = layout.row,
      col = layout.preview_col,
      width = layout.preview_width,
      height = layout.height,
      style = "minimal",
      border = "rounded",
      title = empty_preview_title(),
      title_pos = "center",
      zindex = board_zindex,
    })
    vim.wo[preview_window].wrap = true
    vim.wo[preview_window].signcolumn = "no"
    vim.wo[preview_window].winhighlight = table.concat({
      "Normal:NormalFloat",
      "FloatBorder:HerdrBorder",
      "FloatTitle:HerdrTitle",
    }, ",")
  else
    preview_window = nil
  end
end

function M._reopen_windows()
  if not M.is_open() then
    return
  end
  closing_windows = true
  if valid_window(preview_window) then
    vim.api.nvim_win_close(preview_window, true)
  end
  if valid_window(list_window) then
    vim.api.nvim_win_close(list_window, true)
  end
  list_window = nil
  preview_window = nil
  preview_target = nil
  open_windows()
  closing_windows = false
  M.render()
end

function M._resize_windows()
  if not M.is_open() then
    return
  end
  local layout = geometry()
  vim.api.nvim_win_set_config(list_window, {
    relative = "editor",
    row = layout.row,
    col = layout.col,
    width = layout.list_width,
    height = layout.height,
  })
  if valid_window(preview_window) then
    vim.api.nvim_win_set_config(preview_window, {
      relative = "editor",
      row = layout.row,
      col = layout.preview_col,
      width = layout.preview_width,
      height = layout.height,
    })
  end
  M.render()
end

function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    vim.api.nvim_set_current_win(list_window)
  else
    origin_root = require("herdr.context").project_root(0)
    preview_enabled = config.get().board.preview
    help_visible = false
    preview_mode = "output"
    preview_target = nil
    if not valid_buffer(list_buffer) then
      list_buffer = vim.api.nvim_create_buf(false, true)
      configure_buffer(list_buffer, "herdr", "board")
    end
    if not valid_buffer(preview_buffer) then
      preview_buffer = vim.api.nvim_create_buf(false, true)
      configure_buffer(preview_buffer, "herdr-preview", "preview")
    end
    open_windows()
    state.set_board_visible(true)
  end
  local key = opts.key or opts.terminal_id
  M.render(key)
  if key and selected_id() ~= key and state.agent(key) then
    show_all = true
    M.render(key)
  end
end

function M.close()
  paused_preview = nil
  preview_generation = preview_generation + 1
  preview_target = nil
  preview_in_flight = nil
  closing_windows = true
  if valid_window(preview_window) then
    vim.api.nvim_win_close(preview_window, true)
  end
  if valid_window(list_window) then
    vim.api.nvim_win_close(list_window, true)
  end
  list_window = nil
  preview_window = nil
  closing_windows = false
  state.set_board_visible(false)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

local function apply_highlights()
  vim.api.nvim_set_hl(0, "HerdrBlocked", { link = "ErrorMsg" })
  vim.api.nvim_set_hl(0, "HerdrWorking", { link = "Function" })
  vim.api.nvim_set_hl(0, "HerdrDone", { link = "String" })
  vim.api.nvim_set_hl(0, "HerdrIdle", { link = "Comment" })
  vim.api.nvim_set_hl(0, "HerdrUnknown", { link = "WarningMsg" })
  vim.api.nvim_set_hl(0, "HerdrTitle", { link = "Title" })
  vim.api.nvim_set_hl(0, "HerdrWorkspace", { link = "Function" })
  vim.api.nvim_set_hl(0, "HerdrBorder", { link = "FloatBorder" })
  vim.api.nvim_set_hl(0, "HerdrMuted", { link = "Comment" })
  vim.api.nvim_set_hl(0, "HerdrGuideHeader", { link = "Title" })
  vim.api.nvim_set_hl(0, "HerdrGuideKey", { link = "Special" })
end

function M.setup()
  apply_highlights()
  augroup = vim.api.nvim_create_augroup("HerdrBoard", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = apply_highlights,
  })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "HerdrUpdated",
    callback = function()
      if M.is_open() then
        M.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if M.is_open() then
        M._resize_windows()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if closing_windows or (closed ~= list_window and closed ~= preview_window) then
        return
      end
      vim.schedule(function()
        if not closing_windows and (list_window ~= nil or preview_window ~= nil) then
          M.close()
        end
      end)
    end,
  })
end

function M._buffer()
  return list_buffer
end

function M._preview_buffer()
  return preview_buffer
end

function M._line_agents()
  return line_agents
end

function M._reset()
  M.close()
  for _, buffer in ipairs({ list_buffer, preview_buffer }) do
    if valid_buffer(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  list_buffer = nil
  preview_buffer = nil
  line_agents = {}
  help_visible = false
  show_all = false
  preview_enabled = true
  preview_mode = "output"
  preview_target = nil
  preview_in_flight = nil
  preview_last_read = 0
  preview_cache = {}
  closing_windows = false
  origin_root = nil
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = nil
end

return M
