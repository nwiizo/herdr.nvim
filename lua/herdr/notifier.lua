local config = require("herdr.config")

local M = {}

local notify
local seen = {}
local visibility_probe

local function attention_is_visible(event)
  if visibility_probe then
    return visibility_probe(event)
  end
  local ok, board = pcall(require, "herdr.board")
  if ok and board.is_visible() then
    return true
  end
  local agent_key = event.key or event.terminal_id
  local buffer = vim.api.nvim_get_current_buf()
  if vim.b[buffer].herdr_agent_key ~= agent_key then
    return false
  end
  local terminal_ok, terminal = pcall(require, "herdr.terminal")
  return terminal_ok and terminal.is_attached(agent_key, buffer)
end

function M.on_transition(event)
  if not config.get().notifications[event.status] then
    return
  end
  local revision = event.status == "done" and event.completion_seq ~= nil and ("completion:" .. event.completion_seq)
    or tostring(event.revision)
  local key = table.concat({ event.key or event.terminal_id, event.status, revision }, ":")
  if seen[key] then
    return
  end
  if event.status == "blocked" and attention_is_visible(event) then
    return
  end
  seen[key] = true
  local name = require("herdr.client").agent_label({ name = event.name or event.terminal_id, machine = event.machine })
  local message = string.format("%s is %s", name, event.status)
  if event.title and event.title ~= "" then
    message = message .. ": " .. event.title
  end
  local level = event.status == "blocked" and vim.log.levels.WARN or vim.log.levels.INFO
  local deliver = notify or vim.notify
  deliver(message, level, { title = "Herdr" })
end

function M._set_notify(value)
  notify = value
end

function M._set_visibility_probe(value)
  visibility_probe = value
end

function M._reset()
  notify = nil
  seen = {}
  visibility_probe = nil
end

return M
