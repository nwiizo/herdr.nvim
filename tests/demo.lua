-- Render reproducible documentation screenshots without a server or AI account.
-- From this checkout: nvim -u NONE -i NONE '+lua dofile("tests/demo.lua")'
-- Also works with the normal Neovim config under isolated HOME/XDG directories.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local client = require("herdr.client")
local snapshot = {
  agents = {},
  workspaces = { { workspace_id = "demo", label = "herdr.nvim" } },
}
for index, kind in ipairs({ "codex", "claude" }) do
  table.insert(snapshot.agents, {
    terminal_id = "demo-" .. index,
    pane_id = "demo-pane-" .. index,
    target = "demo-pane-" .. index,
    workspace_id = "demo",
    name = kind .. "-reviewer",
    registered_name = kind .. "-reviewer",
    kind = kind,
    status = "done",
    revision = 1,
    cwd = vim.fn.getcwd(),
  })
end
client.ensure_server = function(callback)
  callback(true)
end
client.snapshot = function(callback)
  callback(snapshot)
end
client.read = function(_, _, callback)
  callback(table.concat({
    "Review complete.",
    "",
    "The Neovim plugin is now herdr.nvim.",
    "",
    "  :Herdr           Open the attention board",
    "  :HerdrHealth     Check the Herdr connection",
    "  <C-g>            Return from an attached terminal",
    "",
    "Herdr keeps agents running when Neovim closes.",
    "The board shows the work that needs your attention.",
    "",
    "Demo data; no coding agent or server is running.",
  }, "\n"))
end
require("herdr").setup({ auto_start_server = false })
vim.cmd("runtime plugin/herdr.lua")
vim.cmd("Herdr")
