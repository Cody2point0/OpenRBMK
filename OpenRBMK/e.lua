local HELP_TEXT = [[
OpenRBMK Command Interface

Usage:
  openrbmk start
  openrbmk settings
  openrbmk help
  openrbmk

Commands:
  start      Start the OpenRBMK runtime
  settings   Open the settings interface
  help       Show this help page

Configuration:
  OpenRBMK uses on-disk configuration stored at:
    /etc/openrbmk/settings.lua

  Settings can be edited through:
    openrbmk settings

  Floppy disks are not used for normal configuration editing.

Runtime Behavior:
  While running, inserting a floppy does nothing.

  Pressing 's' will:
    - Load configuration from a floppy (if present)
    - Copy it to on-disk settings
    - Apply changes live

  This does not interrupt reactor operation or control state.

Manual:
  See 'man openrbmk' for full documentation.
]]

local function showHelp()
  io.write(HELP_TEXT)
end

local args = {...}
local command = args[1]

if command == nil or command == "" or command == "help" then
  showHelp()
  
end

if command == "settings" then
  local ok, settingsui = pcall(require, "openrbmk.settingsui")
  if not ok then
    io.stderr:write("OpenRBMK: failed to load settings interface: " .. tostring(settingsui) .. "\n")
    return
  end
  local runOk, runErr = pcall(settingsui.run)
  if not runOk then
    io.stderr:write("OpenRBMK settings: " .. tostring(runErr) .. "\n")
  end
  return
end

if command == "start" then
  local ok, runtime = pcall(require, "openrbmk.runtime")
  if not ok then
    io.stderr:write("OpenRBMK: runtime module is not installed yet.\n")
    return
  end
  if type(runtime) == "table" and type(runtime.run) == "function" then
    return runtime.run(table.unpack(args, 2))
  end
  if type(runtime) == "function" then
    return runtime(table.unpack(args, 2))
  end
  io.stderr:write("OpenRBMK: runtime module has no runnable entrypoint.\n")
  return
end

io.stderr:write("OpenRBMK: unknown command: " .. tostring(command) .. "\n\n")
showHelp()
