if vim.g.loaded_herdr_nvim == 1 then
  return
end
vim.g.loaded_herdr_nvim = 1

vim.api.nvim_create_user_command("Herdr", function()
  require("herdr").toggle()
end, { desc = "Toggle the Herdr attention board" })

vim.api.nvim_create_user_command("HerdrRefresh", function()
  require("herdr").refresh()
end, { desc = "Refresh Herdr agent state" })

vim.api.nvim_create_user_command("HerdrUpdateAll", function()
  require("herdr").update_all()
end, { desc = "Update Herdr server, integrations, and detection manifests" })

vim.api.nvim_create_user_command("HerdrStart", function(args)
  require("herdr").start(args.args ~= "" and args.args or nil)
end, {
  nargs = "?",
  complete = function()
    return require("herdr")._complete_agent_kinds()
  end,
  desc = "Start a persistent coding agent through Herdr",
})

vim.api.nvim_create_user_command("HerdrResume", function(args)
  require("herdr").resume(args.args ~= "" and args.args or nil)
end, {
  nargs = "?",
  complete = function()
    return require("herdr")._complete_agent_kinds()
  end,
  desc = "Resume a saved coding-agent conversation through Herdr",
})

vim.api.nvim_create_user_command("HerdrAttach", function(args)
  require("herdr").attach(args.args ~= "" and args.args or nil, { takeover = args.bang })
end, {
  nargs = "?",
  bang = true,
  complete = function()
    return require("herdr")._complete_agents()
  end,
  desc = "Attach to a persistent Herdr agent",
})

vim.api.nvim_create_user_command("HerdrPrompt", function(args)
  local target = args.args ~= "" and args.args or nil
  if args.range > 0 then
    require("herdr")._send_range(target, vim.api.nvim_get_current_buf(), args.line1, args.line2)
  else
    require("herdr").prompt(target)
  end
end, {
  nargs = "?",
  range = true,
  complete = function()
    return require("herdr")._complete_agents()
  end,
  desc = "Prompt an agent, optionally with a line range",
})

vim.api.nvim_create_user_command("HerdrRename", function(args)
  require("herdr").rename(args.args ~= "" and args.args or nil)
end, {
  nargs = "?",
  complete = function()
    return require("herdr")._complete_agents()
  end,
  desc = "Give a Herdr agent a stable role name",
})

vim.api.nvim_create_user_command("HerdrSendVisual", function(args)
  if args.range == 0 then
    vim.notify("HerdrSendVisual requires a visual range", vim.log.levels.ERROR, { title = "Herdr" })
    return
  end
  require("herdr")._send_visual(
    args.args ~= "" and args.args or nil,
    vim.api.nvim_get_current_buf(),
    args.line1,
    args.line2
  )
end, {
  nargs = "?",
  range = true,
  complete = function()
    return require("herdr")._complete_agents()
  end,
  desc = "Send an exact visual selection to an agent",
})

vim.api.nvim_create_user_command("HerdrSendFile", function(args)
  require("herdr")._send_file(args.args ~= "" and args.args or nil, vim.api.nvim_get_current_buf())
end, {
  nargs = "?",
  complete = function()
    return require("herdr")._complete_agents()
  end,
  desc = "Send the current file reference to an agent",
})

vim.api.nvim_create_user_command("HerdrSendDiagnostics", function(args)
  require("herdr")._send_diagnostics(args.args ~= "" and args.args or nil, vim.api.nvim_get_current_buf())
end, {
  nargs = "?",
  complete = function()
    return require("herdr")._complete_agents()
  end,
  desc = "Send current-buffer diagnostics to an agent",
})

vim.api.nvim_create_user_command("HerdrHealth", function()
  vim.cmd("checkhealth herdr")
end, { desc = "Run herdr.nvim health checks" })
