local term = require("term")
local event = require("event")
local keyboard = require("keyboard")
local config = require("openrbmk.config")

local M = {}

local function clearAndHome()
  term.clear()
  term.setCursor(1, 1)
end

local function drawMenu(title, items, selected)
  clearAndHome()
  print(title)
  print("")
  for i, item in ipairs(items) do
    if i == selected then
      io.write("[" .. i .. "] " .. item .. "\n")
    else
      io.write(" " .. i .. "  " .. item .. "\n")
    end
  end
end

local function runMenu(title, items)
  local selected = 1
  while true do
    drawMenu(title, items, selected)
    local _, _, _, key = event.pull("key_down")
    if key == keyboard.keys.down then
      selected = selected + 1
      if selected > #items then
        selected = 1
      end
    elseif key == keyboard.keys.up then
      selected = selected - 1
      if selected < 1 then
        selected = #items
      end
    elseif key == keyboard.keys.enter then
      return selected
    elseif key == keyboard.keys.q then
      return nil
    end
  end
end

local function readLinePrompt(title, line1, line2)
  clearAndHome()
  print(title)
  print("")
  if line1 then print(line1) end
  if line2 then print(line2) end
  io.write("> ")
  local input = term.read() or ""
  return input:gsub("[\r\n]+$", "")
end

local function showMessage(title, message)
  clearAndHome()
  print(title)
  print("")
  print(message)
  print("")
  print("Press Enter to continue.")
  while true do
    local _, _, _, key = event.pull("key_down")
    if key == keyboard.keys.enter or key == keyboard.keys.q then
      return
    end
  end
end

local function enumIndexForValue(options, value)
  for i, option in ipairs(options) do
    if option.value == value then
      return i
    end
  end
  return 1
end

local function editEnum(field, currentValue)
  local options = field.options
  local index = enumIndexForValue(options, currentValue)
  while true do
    clearAndHome()
    print(field.label)
    print("")
    for i, option in ipairs(options) do
      if i == index then
        print("[" .. i .. "] " .. option.label)
      else
        print(" " .. i .. "  " .. option.label)
      end
    end
    local _, _, _, key = event.pull("key_down")
    if key == keyboard.keys.down then
      index = index + 1
      if index > #options then index = 1 end
    elseif key == keyboard.keys.up then
      index = index - 1
      if index < 1 then index = #options end
    elseif key == keyboard.keys.enter then
      return options[index].value
    elseif key == keyboard.keys.q then
      return nil, "cancel"
    end
  end
end

local function editSide(field, currentValue)
  local index = enumIndexForValue(config.sideOrder, { value = currentValue })
  index = 1
  for i, option in ipairs(config.sideOrder) do
    if option.value == currentValue then
      index = i
      break
    end
  end
  while true do
    clearAndHome()
    print(field.label)
    print("")
    for i, option in ipairs(config.sideOrder) do
      if i == index then
        print("[" .. i .. "] " .. option.name)
      else
        print(" " .. i .. "  " .. option.name)
      end
    end
    local _, _, _, key = event.pull("key_down")
    if key == keyboard.keys.down then
      index = index + 1
      if index > #config.sideOrder then index = 1 end
    elseif key == keyboard.keys.up then
      index = index - 1
      if index < 1 then index = #config.sideOrder end
    elseif key == keyboard.keys.enter then
      return config.sideOrder[index].value
    elseif key == keyboard.keys.q then
      return nil, "cancel"
    end
  end
end

local function editNumber(field, currentValue)
  local line1 = "Current Setting: " .. tostring(currentValue)
  local range = config.rangeText(field)
  if range then
    line1 = line1 .. " " .. range
  end
  while true do
    local input = readLinePrompt(field.label, line1)
    if input == "q" then
      return nil, "cancel"
    end
    local value = config.parseNumber(input)
    if value == nil then
      showMessage(field.label, "Enter a valid number.")
    else
      local ok, err = config.validateField(field, value)
      if ok then
        return value
      end
      showMessage(field.label, err)
    end
  end
end

local function editTextDefault(field, currentValue)
  local currentText = currentValue
  if currentText == nil or currentText == "" then
    currentText = "<" .. (field.defaultLabel or "default") .. ">"
  end
  local input = readLinePrompt(field.label, "Current Setting: " .. tostring(currentText), "Blank input restores " .. (field.defaultLabel or "default") .. ".")
  if input == "q" then
    return nil, "cancel"
  end
  if input == "" then
    return nil
  end
  local ok, err = config.validateField(field, input)
  if not ok then
    showMessage(field.label, err)
    return editTextDefault(field, currentValue)
  end
  return input
end

local function editAddress(field, currentValue)
  while true do
    local input = readLinePrompt(field.label, "Current Setting: " .. tostring(currentValue))
    if input == "q" then
      return nil, "cancel"
    end
    local ok, err = config.validateField(field, input)
    if ok then
      return input
    end
    showMessage(field.label, err)
  end
end

local function editField(path, working, field)
  local currentValue = working[field.key]
  local newValue, err

  if field.kind == "number" then
    newValue, err = editNumber(field, currentValue)
  elseif field.kind == "enum" then
    newValue, err = editEnum(field, currentValue)
  elseif field.kind == "side" then
    newValue, err = editSide(field, currentValue)
  elseif field.kind == "textdefault" then
    newValue, err = editTextDefault(field, currentValue)
  elseif field.kind == "address" then
    newValue, err = editAddress(field, currentValue)
  else
    showMessage("Error", "Unsupported field type: " .. tostring(field.kind))
    return working
  end

  if err == "cancel" then
    return working
  end

  local updated = {}
  for key, value in pairs(working) do
    updated[key] = value
  end
  updated[field.key] = newValue

  local ok, validateErr = config.validateConfig(updated)
  if not ok then
    showMessage(field.label, validateErr)
    return working
  end

  local saveOk, saveErr = config.saveConfig(path, updated)
  if not saveOk then
    showMessage(field.label, "Failed to save: " .. tostring(saveErr))
    return working
  end

  return updated
end

local function runCategory(targetName, path, configTable, categoryName)
  local fields = config.schema[categoryName]
  while true do
    local items = {}
    for _, field in ipairs(fields) do
      table.insert(items, field.label .. " = " .. config.displayValue(field, configTable[field.key]))
    end
    table.insert(items, "Back")

    local index = runMenu(targetName .. " / " .. categoryName, items)
    if index == nil or index == #items then
      return configTable
    end

    configTable = editField(path, configTable, fields[index])
  end
end

local function runTarget(targetKey, targetLabel)
  local path = config.resolveTarget(targetKey)
  if targetKey == "floppy" then
    if not path then
      print("OpenRBMK: no floppy found.")
      return nil, "exit"
    end
  end

  local cfg, err = config.loadOrCreate(path)
  if not cfg then
    showMessage("OpenRBMK", "Failed to load settings: " .. tostring(err))
    return nil, "exit"
  end

  while true do
    local items = {}
    for _, category in ipairs(config.categoryOrder) do
      table.insert(items, category)
    end
    table.insert(items, "Exit")

    local index = runMenu(targetLabel, items)
    if index == nil or index == #items then
      return cfg, "exit"
    end

    cfg = runCategory(targetLabel, path, cfg, config.categoryOrder[index])
  end
end

function M.run()
  while true do
    local index = runMenu("OpenRBMK Settings", {
      "On-Disk Settings",
      "Floppy Settings",
      "Exit"
    })

    if index == nil or index == 3 then
      return
    elseif index == 1 then
      local _, action = runTarget("disk", "On-Disk Settings")
      if action == "exit" then
        return
      end
    elseif index == 2 then
      local _, action = runTarget("floppy", "Floppy Settings")
      if action == "exit" then
        return
      end
    end
  end
end

return M
