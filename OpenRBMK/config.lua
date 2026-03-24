local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")

local M = {}

M.onDiskPath = "/etc/openrbmk/settings.lua"
M.floppyFileName = "settings.lua"

M.sideOrder = {
  { name = "bottom", value = 0 },
  { name = "top",    value = 1 },
  { name = "north",  value = 2 },
  { name = "south",  value = 3 },
  { name = "west",   value = 4 },
  { name = "east",   value = 5 }
}

M.sideNameByValue = {}
for _, side in ipairs(M.sideOrder) do
  M.sideNameByValue[side.value] = side.name
end

M.defaults = {
  shutdownTempC = 900,
  scramPredictTempC = 1500,
  tempStableReq = 5.0,
  maxTargetTempC = 1100,
  updateEvery = 0.10,
  tempOffsetC = 0,
  adaptiveControl = true,
  fluxScram = 1300,
  withdrawStep = 1,
  insertStep = 6,
  rodHoldCold = 10,
  heaterExportOkMb = 2,
  titleOverride = nil,
  versionOverride = nil,
  defaultMode = "AUTO",
  scramRedstoneIo = 3,
  scramResetRedstoneIo = 2,
  modeSwitchRedstoneIo = 3,
  manualControlRedstoneIo = 2,
  redstoneMainAddr = "d70380a6-aa4c-425b-b934-867dbc4b3eb5",
  redstoneAuxAddr = "a0a556a7-4602-4eaf-a61a-d479de8805bb",
  redstoneManualAddr = "bab2a090-a584-4eef-809b-ce26ecdf2b68"
}

M.categoryOrder = {
  "Automatic Control",
  "Safety",
  "Setup",
  "Redstone I/O"
}

M.schema = {
  ["Automatic Control"] = {
    {
      key = "maxTargetTempC",
      label = "Maximum Target Temperature (°C)",
      kind = "number",
      min = 0,
      max = 2865,
      integer = false
    },
    {
      key = "adaptiveControl",
      label = "Adaptive Control",
      kind = "enum",
      options = {
        { label = "Disabled", value = false },
        { label = "Enabled", value = true }
      }
    },
    {
      key = "withdrawStep",
      label = "Withdrawal Step Limit (% per cycle)",
      kind = "number",
      min = 0,
      max = 100,
      integer = false
    },
    {
      key = "insertStep",
      label = "Insertion Step Limit (% per cycle)",
      kind = "number",
      min = 0,
      max = 100,
      integer = false
    },
    {
      key = "rodHoldCold",
      label = "Minimum Rod Hold at Cold (%)",
      kind = "number",
      min = 0,
      max = 100,
      integer = false
    }
  },
  ["Safety"] = {
    {
      key = "shutdownTempC",
      label = "Shutdown Temperature (°C)",
      kind = "number",
      min = 0,
      max = 2865,
      integer = false
    },
    {
      key = "scramPredictTempC",
      label = "Predictive SCRAM Temperature (°C)",
      kind = "number",
      min = 0,
      max = 2865,
      integer = false
    },
    {
      key = "tempStableReq",
      label = "SCRAM Predictor Requirement (seconds)",
      kind = "number",
      min = 0.0,
      max = 60.0,
      integer = false
    },
    {
      key = "fluxScram",
      label = "Flux SCRAM Threshold",
      kind = "number",
      min = nil,
      max = nil,
      integer = false
    }
  },
  ["Setup"] = {
    {
      key = "updateEvery",
      label = "Runtime Update Interval (seconds)",
      kind = "number",
      min = 0.1,
      max = 10,
      integer = false
    },
    {
      key = "tempOffsetC",
      label = "Temperature Offset (°C)",
      kind = "number",
      min = -1000,
      max = 1000,
      integer = false
    },
    {
      key = "heaterExportOkMb",
      label = "Heater Export OK Threshold (mB/t)",
      kind = "number",
      min = 0,
      max = 16000,
      integer = false
    },
    {
      key = "titleOverride",
      label = "Title Override",
      kind = "textdefault",
      defaultLabel = "default title"
    },
    {
      key = "versionOverride",
      label = "Version Override",
      kind = "textdefault",
      defaultLabel = "default version"
    },
    {
      key = "defaultMode",
      label = "Default Mode",
      kind = "enum",
      options = {
        { label = "SCRAM", value = "SCRAM" },
        { label = "MANUAL", value = "MANUAL" },
        { label = "AUTO", value = "AUTO" }
      }
    }
  },
  ["Redstone I/O"] = {
    {
      key = "scramRedstoneIo",
      label = "SCRAM Redstone I/O",
      kind = "side"
    },
    {
      key = "scramResetRedstoneIo",
      label = "SCRAM Reset Redstone I/O",
      kind = "side"
    },
    {
      key = "modeSwitchRedstoneIo",
      label = "Mode Switch Redstone I/O",
      kind = "side"
    },
    {
      key = "manualControlRedstoneIo",
      label = "Manual Control Redstone I/O",
      kind = "side"
    },
    {
      key = "redstoneMainAddr",
      label = "Main Redstone I/O Address",
      kind = "address"
    },
    {
      key = "redstoneAuxAddr",
      label = "Auxiliary Redstone I/O Address",
      kind = "address"
    },
    {
      key = "redstoneManualAddr",
      label = "Manual Control Redstone I/O Address",
      kind = "address"
    }
  }
}

local saveOrder = {
  "shutdownTempC",
  "scramPredictTempC",
  "tempStableReq",
  "maxTargetTempC",
  "updateEvery",
  "tempOffsetC",
  "adaptiveControl",
  "fluxScram",
  "withdrawStep",
  "insertStep",
  "rodHoldCold",
  "heaterExportOkMb",
  "titleOverride",
  "versionOverride",
  "defaultMode",
  "scramRedstoneIo",
  "scramResetRedstoneIo",
  "modeSwitchRedstoneIo",
  "manualControlRedstoneIo",
  "redstoneMainAddr",
  "redstoneAuxAddr",
  "redstoneManualAddr"
}

local saveComments = {
  shutdownTempC = "°C hard SCRAM",
  scramPredictTempC = "°C anticipatory SCRAM",
  tempStableReq = "seconds prediction must persist",
  maxTargetTempC = "°C full AUTO authority reached at (this - 300)",
  updateEvery = "seconds",
  tempOffsetC = "°C display / control offset",
  adaptiveControl = "enable adaptive AUTO clamp logic",
  fluxScram = "hard SCRAM on prompt excursion",
  withdrawStep = "% per cycle (out)",
  insertStep = "% per cycle (in)",
  rodHoldCold = "% minimum at cold",
  heaterExportOkMb = "mB/t heater export threshold",
  titleOverride = "nil = default title",
  versionOverride = "nil = default version",
  defaultMode = "SCRAM, MANUAL, AUTO",
  scramRedstoneIo = "side number",
  scramResetRedstoneIo = "side number",
  modeSwitchRedstoneIo = "side number",
  manualControlRedstoneIo = "side number",
  redstoneMainAddr = "SCRAM + reset component address",
  redstoneAuxAddr = "mode switch component address",
  redstoneManualAddr = "manual control component address"
}

local function copyTable(source)
  local out = {}
  for key, value in pairs(source) do
    out[key] = value
  end
  return out
end

function M.getDefaultConfig()
  return copyTable(M.defaults)
end

function M.findFieldByKey(key)
  for _, category in ipairs(M.categoryOrder) do
    for _, field in ipairs(M.schema[category]) do
      if field.key == key then
        return field, category
      end
    end
  end
  return nil, nil
end

function M.getSideName(value)
  return M.sideNameByValue[value] or ("unknown(" .. tostring(value) .. ")")
end

local function ensureDirForFile(path)
  local dir = fs.path(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDirectory(dir)
  end
end

local function quoteValue(value)
  if value == nil then
    return "nil"
  end
  return serialization.serialize(value)
end

function M.serializeConfig(config)
  local lines = {
    "-- OpenRBMK configuration file",
    "-- Generated by the OpenRBMK settings interface",
    "",
    "return {"
  }

  for _, key in ipairs(saveOrder) do
    local value = config[key]
    local rendered = quoteValue(value)
    local comment = saveComments[key]
    local line = "  " .. key
    if #key < 22 then
      line = line .. string.rep(" ", 22 - #key)
    else
      line = line .. " "
    end
    line = line .. "= " .. rendered .. ","
    if comment then
      line = line .. " -- " .. comment
    end
    table.insert(lines, line)
  end

  table.insert(lines, "}")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

function M.saveConfig(path, config)
  ensureDirForFile(path)
  local handle, err = io.open(path, "w")
  if not handle then
    return nil, err
  end
  local ok, writeErr = handle:write(M.serializeConfig(config))
  handle:close()
  if not ok then
    return nil, writeErr
  end
  return true
end

function M.loadConfig(path)
  if not fs.exists(path) then
    return nil, "missing"
  end

  local ok, result = pcall(dofile, path)
  if not ok then
    return nil, result
  end
  if type(result) ~= "table" then
    return nil, "invalid config type"
  end

  local merged = M.getDefaultConfig()
  for key, value in pairs(result) do
    merged[key] = value
  end

  local valid, err = M.validateConfig(merged)
  if not valid then
    return nil, err
  end

  return merged
end

function M.loadOrCreate(path)
  local config, err = M.loadConfig(path)
  if config then
    return config
  end
  local defaults = M.getDefaultConfig()
  local ok, saveErr = M.saveConfig(path, defaults)
  if not ok then
    return nil, saveErr or err
  end
  return defaults
end

function M.getFloppyPath()
  for address in component.list("disk_drive") do
    local drive = component.proxy(address)
    if drive and not drive.isEmpty() then
      local media = drive.media()
      if media then
        local mount = "/mnt/" .. media:sub(1, 3)
        if fs.exists(mount) and fs.isDirectory(mount) then
          return fs.concat(mount, M.floppyFileName), address, media
        end
      end
    end
  end
  return nil, nil, nil
end

function M.resolveTarget(target)
  if target == "disk" then
    return M.onDiskPath
  end
  if target == "floppy" then
    return M.getFloppyPath()
  end
  return nil, "unknown target"
end

local function inRange(value, min, max)
  if min ~= nil and value < min then
    return false
  end
  if max ~= nil and value > max then
    return false
  end
  return true
end

function M.validateField(field, value)
  if field.kind == "number" then
    if type(value) ~= "number" then
      return nil, field.label .. " must be a number"
    end
    if field.integer and math.floor(value) ~= value then
      return nil, field.label .. " must be an integer"
    end
    if not inRange(value, field.min, field.max) then
      if field.min ~= nil or field.max ~= nil then
        return nil, field.label .. " is out of range"
      end
      return nil, field.label .. " is invalid"
    end
    return true
  end

  if field.kind == "enum" then
    for _, option in ipairs(field.options) do
      if option.value == value then
        return true
      end
    end
    return nil, field.label .. " is invalid"
  end

  if field.kind == "side" then
    for _, side in ipairs(M.sideOrder) do
      if side.value == value then
        return true
      end
    end
    return nil, field.label .. " is invalid"
  end

  if field.kind == "address" then
    if type(value) ~= "string" or value == "" then
      return nil, field.label .. " must not be blank"
    end
    return true
  end

  if field.kind == "textdefault" then
    if value ~= nil and type(value) ~= "string" then
      return nil, field.label .. " is invalid"
    end
    return true
  end

  return nil, "unknown field type"
end

function M.validateConfig(config)
  for _, category in ipairs(M.categoryOrder) do
    for _, field in ipairs(M.schema[category]) do
      local ok, err = M.validateField(field, config[field.key])
      if not ok then
        return nil, err
      end
    end
  end
  return true
end

function M.parseNumber(text)
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil
  end
  return tonumber(trimmed)
end

function M.displayValue(field, value)
  if field.kind == "enum" then
    for _, option in ipairs(field.options) do
      if option.value == value then
        return option.label
      end
    end
  elseif field.kind == "side" then
    return M.getSideName(value)
  elseif field.kind == "textdefault" then
    if value == nil or value == "" then
      return "<" .. (field.defaultLabel or "default") .. ">"
    end
    return value
  elseif value == nil then
    return "nil"
  end
  return tostring(value)
end

function M.rangeText(field)
  if field.kind ~= "number" then
    return nil
  end
  if field.min == nil and field.max == nil then
    return nil
  end
  return string.format("Range [%s, %s]", tostring(field.min), tostring(field.max))
end

return M
