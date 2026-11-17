local M = {}

local health = vim.health
local compatibility = require("herdr.compatibility")
local manifest_stale_after_seconds = 7 * 24 * 60 * 60

local function json_optional(value)
  if value == vim.NIL then
    return nil
  end
  return value
end

local function run(argv, timeout_ms)
  local ok, process = pcall(vim.system, argv, { text = true })
  if not ok then
    return false, "", tostring(process)
  end
  local result = process:wait(timeout_ms or 3000)
  return result.code == 0, result.stdout or "", result.stderr or ""
end

-- SSH checks include Herdr's 10-second connect timeout.
local machine_check_timeout_ms = 15000

local function version_at_least(output, minimum)
  local version = output:match("(%d+%.%d+%.%d+)")
  if not version then
    return false
  end
  local parsed = vim.version.parse(version)
  return parsed ~= nil and vim.version.ge(parsed, minimum)
end

local function supported_herdr_version(output)
  return version_at_least(output, compatibility.minimum_herdr)
end

local function newer_than_verified(output)
  local version = output:match("(%d+%.%d+%.%d+)")
  local parsed = version and vim.version.parse(version) or nil
  return parsed ~= nil
    and vim.version.ge(parsed, compatibility.verified_herdr)
    and not compatibility.same_version(parsed, compatibility.verified_herdr)
end

local function check_executable(command, label, required)
  local path = vim.fn.exepath(command)
  if path ~= "" then
    health.ok(string.format("%s: %s", label, path))
    return true
  end
  if required then
    health.error(label .. " is not executable")
  else
    health.warn(string.format("%s is not executable (%s); its launch preset will not work", label, command))
  end
  return false
end

function M._parse_manifest_status(output)
  local ok, decoded = pcall(vim.json.decode, output or "")
  local result = ok and type(decoded) == "table" and decoded.result or nil
  if type(result) ~= "table" or type(result.manifests) ~= "table" or not vim.islist(result.manifests) then
    return nil, "Herdr returned an invalid agent manifest status"
  end
  local status = {
    last_check_unix = tonumber(json_optional(result.last_check_unix)),
    manifests = {},
  }
  for _, manifest in ipairs(result.manifests) do
    if type(manifest) == "table" and type(manifest.agent) == "string" then
      local normalized = {}
      for key, value in pairs(manifest) do
        normalized[key] = json_optional(value)
      end
      status.manifests[manifest.agent] = normalized
    end
  end
  return status
end

function M._manifest_check_age(status, manifest, now)
  local checked_at = tonumber(manifest.remote_last_checked_unix) or tonumber(status.last_check_unix)
  if not checked_at then
    return nil
  end
  return math.max(0, (now or os.time()) - checked_at)
end

function M._manifest_status_argv(command)
  return { command, "server", "agent-manifests", "--json" }
end

function M._manifest_update_argv(command)
  return { command, "server", "update-agent-manifests" }
end

local function decode_list(output)
  local ok, decoded = pcall(vim.json.decode, output or "")
  if not ok or type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil
  end
  return decoded
end

-- Returns { [selector] = profile } for configured selectors (label or ID), plus unwatched profiles.
function M._match_machine_profiles(output, machines)
  local profiles = decode_list(output)
  if not profiles then
    return nil, "Herdr returned an invalid saved machine list"
  end
  local matched, watched_ids, unwatched = {}, {}, {}
  for _, selector in ipairs(machines) do
    for _, profile in ipairs(profiles) do
      if type(profile) == "table" and (profile.id == selector or profile.label == selector) then
        matched[selector] = profile
        watched_ids[profile.id] = true
      end
    end
  end
  for _, profile in ipairs(profiles) do
    if type(profile) == "table" and profile.enabled ~= false and not watched_ids[profile.id] then
      table.insert(unwatched, tostring(profile.label or profile.id))
    end
  end
  return matched, unwatched
end

function M._parse_machine_status(output)
  local entries = decode_list(output)
  local entry = entries and entries[1]
  if type(entry) ~= "table" or type(entry.status) ~= "string" then
    return nil, "Herdr returned an invalid machine status"
  end
  return { status = entry.status, error = json_optional(entry.error) }
end

local function check_machines(command, machines, version_line)
  if #machines == 0 then
    return
  end
  health.start("herdr.nvim saved machines")
  if version_line and not version_at_least(version_line, compatibility.machine_forwarding_herdr) then
    health.error(
      "watching saved machines needs Herdr " .. compatibility.machine_forwarding_herdr_string .. " or newer here",
      { "Update Herdr on this machine and on each saved machine" }
    )
    return
  end
  local ok, stdout, stderr = run({ command, "machine", "list", "--json" })
  if not ok then
    health.error("could not list saved Herdr machines: " .. stderr:gsub("%s+$", ""))
    return
  end
  local matched, unwatched = M._match_machine_profiles(stdout, machines)
  if not matched then
    health.error(unwatched)
    return
  end
  for _, selector in ipairs(machines) do
    local profile = matched[selector]
    if not profile then
      health.error(selector .. " is not a saved Herdr machine", {
        "Run: " .. command .. " machine list",
        "Save it with: " .. command .. " machine add <ssh-target>",
      })
    elseif profile.enabled == false then
      health.warn(selector .. " is disabled", { "Run: " .. command .. " machine enable " .. selector })
    else
      local status_ok, status_out, status_err =
        run({ command, "machine", "status", selector, "--json" }, machine_check_timeout_ms)
      local status = status_ok and M._parse_machine_status(status_out) or nil
      if not status or status.status ~= "reachable" then
        local detail = status and (status.error or status.status) or status_err:gsub("%s+$", "")
        health.warn(string.format("%s is not reachable: %s", selector, detail), {
          "Authenticate in a terminal: " .. command .. " machine reconnect " .. selector,
        })
      else
        local server_ok, server_out, server_err =
          run({ command, "--machine", selector, "status", "server" }, machine_check_timeout_ms)
        local kind = server_ok and compatibility.parse_server_status(server_out) or nil
        if kind == "compatible" then
          health.ok(string.format("%s (%s) is reachable and its Herdr server is compatible", selector, profile.target))
        elseif kind == "not_running" then
          health.warn(selector .. " is reachable, but its Herdr server is not running", {
            "Forwarding never starts a remote server; open it once with: " .. command .. " --remote " .. profile.target,
          })
        else
          health.warn(
            string.format("%s did not report a compatible Herdr server: %s", selector, server_err:gsub("%s+$", "")),
            { "Update Herdr on " .. selector }
          )
        end
      end
    end
  end
  for _, label in ipairs(unwatched) do
    health.info(string.format("Saved machine %s is not watched; add it to machines to show its agents", label))
  end
end

function M._configured_agent_names(agents)
  local configured = {}
  local integrations = {}
  for name in pairs(agents) do
    table.insert(configured, name)
    if name == "codex" or name == "claude" then
      table.insert(integrations, name)
    end
  end
  table.sort(configured)
  table.sort(integrations)
  return configured, integrations
end

local function check_agent_manifests(command, agents)
  local ok, stdout, stderr = run(M._manifest_status_argv(command))
  if not ok then
    health.warn("could not inspect Herdr agent detection manifests: " .. stderr:gsub("%s+$", ""))
    return
  end
  local status, parse_err = M._parse_manifest_status(stdout)
  if not status then
    health.warn(parse_err)
    return
  end
  local update_command = table.concat(M._manifest_update_argv(command), " ")
  for _, name in ipairs(agents) do
    local manifest = status.manifests[name]
    if not manifest then
      health.warn("Herdr did not report the " .. name .. " detection manifest")
    else
      local version = tostring(manifest.active_version or "unknown version")
      local source = tostring(manifest.source_kind or "unknown source")
      local update = tostring(manifest.remote_update_result or "unknown update state")
      local check_age = M._manifest_check_age(status, manifest)
      local check_age_days = check_age and math.floor(check_age / 86400) or nil
      if manifest.local_override_shadowing_remote == true then
        health.info(string.format("Herdr %s detection manifest %s uses a local override", name, version))
      elseif manifest.remote_update_error or (update ~= "current" and update ~= "updated") then
        health.warn(string.format("Herdr %s detection manifest %s update is %s", name, version, update), {
          tostring(manifest.remote_update_error or manifest.warning or "Run a manual manifest update"),
          "Run: " .. update_command,
        })
      elseif check_age == nil then
        health.warn(string.format("Herdr %s detection manifest %s update age is unknown", name, version), {
          "Run: " .. update_command,
        })
      elseif check_age > manifest_stale_after_seconds then
        health.warn(
          string.format("Herdr %s detection manifest %s was last checked %d days ago", name, version, check_age_days),
          { "Run: " .. update_command }
        )
      elseif manifest.warning then
        health.warn(string.format("Herdr %s detection manifest %s: %s", name, version, manifest.warning))
      else
        health.ok(
          string.format(
            "Herdr %s detection manifest %s (%s, %s, checked %dd ago)",
            name,
            version,
            source,
            update,
            check_age_days
          )
        )
      end
    end
  end
end

function M.check()
  health.start("herdr.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim 0.10 or newer")
  else
    health.error("Neovim 0.10 or newer is required")
  end

  local config = require("herdr.config").get()
  local herdr_path = vim.fn.exepath(config.herdr_cmd)
  local version_line
  if herdr_path == "" then
    health.error("Herdr is not executable", { "Install Herdr TUI from https://herdr.dev/tui/" })
  else
    local ok, stdout, stderr = run({ config.herdr_cmd, "--version" })
    if ok then
      version_line = stdout:gsub("%s+$", "")
      if newer_than_verified(version_line) then
        health.warn(
          version_line
            .. " is newer than the latest Herdr compatibility audit ("
            .. compatibility.verified_herdr_string
            .. ")",
          {
            "Check the Herdr upgrade issue before relying on unverified behavior",
          }
        )
      elseif supported_herdr_version(version_line) then
        health.ok(version_line)
      else
        health.error(
          version_line .. " is unsupported; Herdr " .. compatibility.minimum_herdr_string .. " or newer is required"
        )
      end
    else
      health.error("failed to run Herdr: " .. (stderr:gsub("%s+$", "")))
    end

    ok, stdout, stderr = run({ config.herdr_cmd, "status", "server" })
    if ok then
      local status_kind = compatibility.parse_server_status(stdout)
      if status_kind == "not_running" then
        health.warn("Herdr server is not running", {
          "Run: " .. config.herdr_cmd .. " server",
        })
      elseif status_kind == "compatible" then
        health.ok("Herdr server is running and compatible with this client")
      else
        health.warn("Herdr server responded but did not report compatibility with this client")
      end
    else
      health.warn("Herdr server is not reachable: " .. stderr:gsub("%s+$", ""), {
        "Run: " .. config.herdr_cmd .. " server",
      })
    end
  end

  local configured_agents, configured_integrations = M._configured_agent_names(config.agents)
  for _, name in ipairs(configured_agents) do
    check_executable(name, name, false)
  end

  if herdr_path ~= "" then
    local ok, stdout, stderr = run({ config.herdr_cmd, "integration", "status" })
    if not ok then
      health.warn("could not inspect Herdr integrations: " .. stderr)
    else
      for _, name in ipairs(configured_integrations) do
        local line = stdout:match("[\n^]" .. name .. ": ([^\n]+)") or stdout:match("^" .. name .. ": ([^\n]+)")
        if line and line:match("^current") then
          health.ok(string.format("Herdr %s integration is %s", name, line))
        elseif line then
          health.warn(string.format("Herdr %s integration is %s", name, line), {
            string.format("Run: herdr integration install %s", name),
          })
        else
          health.warn("Herdr did not report the " .. name .. " integration")
        end
      end
    end
    check_agent_manifests(config.herdr_cmd, configured_agents)
    check_machines(config.herdr_cmd, config.machines, version_line)
  end
end

return M
