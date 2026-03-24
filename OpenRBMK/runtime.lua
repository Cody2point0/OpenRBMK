local component = require("component")
local event = require("event")
local term = require("term")
local keyboard = require("keyboard")
local config = require("openrbmk.config")

local M = {}

local gpu = component.gpu

local defaultTitle = "OpenRBMK Any-Core Monitor"
local defaultVersion = "V14.20.02"
local defaultMeltC = 2865

local scrW, scrH = 60, 24
local xScale = 2
local yScale = 1
local cellSize = 2
local mapX1, mapY1 = 2, 4
local mapX2, mapY2 = 59, 24
local mapW, mapH = mapX2 - mapX1 + 1, mapY2 - mapY1 + 1

local GREEN = 0x00FF00
local YELLOW = 0xFFFF00
local RED = 0xFF0000
local WHITE = 0xFFFFFF
local MID_GRAY = 0x555555

local runtimeConfig = config.getDefaultConfig()

local titleStr = defaultTitle
local versionStr = defaultVersion

local shutdownTempC = runtimeConfig.shutdownTempC
local scramPredictTempC = runtimeConfig.scramPredictTempC
local tempStableReq = runtimeConfig.tempStableReq
local maxTargetTempC = runtimeConfig.maxTargetTempC
local updateEvery = runtimeConfig.updateEvery
local tempOffsetC = runtimeConfig.tempOffsetC
local adaptiveControlOn = runtimeConfig.adaptiveControl
local fluxScram = runtimeConfig.fluxScram
local withdrawStep = runtimeConfig.withdrawStep
local insertStep = runtimeConfig.insertStep
local rodHoldCold = runtimeConfig.rodHoldCold
local heaterExportOkMb = runtimeConfig.heaterExportOkMb

local redstoneMainAddr = runtimeConfig.redstoneMainAddr
local redstoneAuxAddr = runtimeConfig.redstoneAuxAddr
local redstoneManualAddr = runtimeConfig.redstoneManualAddr
local scramSide = runtimeConfig.scramRedstoneIo
local scramResetSide = runtimeConfig.scramResetRedstoneIo
local modeSwitchSide = runtimeConfig.modeSwitchRedstoneIo
local manualControlSide = runtimeConfig.manualControlRedstoneIo

local rsMain = nil
local rsAux = nil
local rsManual = nil
local gauge = nil

local rodsRaw, rods = {}, {}
local ctrlRaw, ctrlCols = {}, {}
local heatersRaw, heaters = {}, {}
local controlRods = {}

local haveLayout = false
local originX, originY = 2, 4
local nx, nz = 0, 0
local mapCache = {}
local mapDirty = true

local flowSec = 0
local manualTargetLevel = 0
local scramOn = false
local scramPulsed = false
local autoControlOn = false
local debounceTop = false
local debounceBottom = false
local fluxAvg, fluxTotal, fluxMax = 0, 0, 0
local lastCmdByAddr = {}

local tempStableTime = 0
local predTripSec = 0
local mState = { lastMaxT = nil, lastSlope = 0 }
local sState = { lastMaxT = nil, lastSlope = 0 }

local statusText = nil
local statusTtl = 0
local running = false
local refreshTimerId = nil
local listenersBound = false

local meltByKey = {
  nu = 2865, meu = 2865, heu235 = 2865, heu233 = 2865, thmeu = 3350,
  lep239 = 2744, mep239 = 2744, hep239 = 2744, hep241 = 2744,
  lea = 2386, mea = 2386, hea241 = 2386, hea242 = 2386, men = 2800, hen = 2800,
  mox = 2815, les = 2500, mes = 2750, hes = 3000,
  leaus = 7029, heaus = 5211, ra226be = 700, po210be = 1287, pu238be = 1287,
  bismuth = 2744, pu241 = 2865, rga = 2744, flashgold = 2000, flashlead = 2050,
  balefire = 3652, digamma = 100000, rbmkfueltest = 100000
}

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function rgb(r, g, b)
  return r * 65536 + g * 256 + b
end

local function lerpColorGR(t)
  t = clamp(t, 0, 1)
  return rgb(math.floor(255 * t + 0.5), math.floor(255 * (1 - t) + 0.5), 0)
end

local function lerpColorWR(t)
  t = clamp(t, 0, 1)
  return rgb(255, math.floor(255 * (1 - t) + 0.5), math.floor(255 * (1 - t) + 0.5))
end

local function roundTo5(x)
  return math.floor((x + 2.5) / 5) * 5
end

local function setStatus(text, ttl)
  statusText = text
  statusTtl = ttl or 20
end

local function statusSuffix()
  if statusText and statusTtl > 0 then
    return " [" .. statusText .. "]"
  end
  return ""
end

local function inferMeltC(typeStr)
  if type(typeStr) == "string" then
    local s = typeStr:lower()
    for key, melt in pairs(meltByKey) do
      if s:find(key, 1, true) then
        return melt
      end
    end
  end
  return defaultMeltC
end

local function resetPredictors()
  tempStableTime = 0
  predTripSec = 0
  mState.lastMaxT = nil
  mState.lastSlope = 0
  sState.lastMaxT = nil
  sState.lastSlope = 0
end

local function computeRetract(tempC)
  local adjusted = tempC + tempOffsetC
  local a = -adjusted / 100 + ((maxTargetTempC / 100) + 1)
  if a <= 0 then return 0 end
  return clamp(1.183 * (math.log(a) / math.log(10)), 0, 1)
end

local function tempAuthorityK(maxFuelT)
  local Tmin = 20
  local Tfull
  if (maxTargetTempC - 300) < 300 then
    Tfull = maxTargetTempC - 450
  else
    Tfull = 400
  end
  if Tfull <= Tmin then return 1 end
  return clamp((maxFuelT - Tmin) / (Tfull - Tmin), 0, 1)
end

local function predictMaxTemp(state, maxTemp, updateEvery_, horizonSec)
  if not maxTemp or maxTemp <= 0 then return 0 end
  if not state.lastMaxT then
    state.lastMaxT = maxTemp
    return maxTemp
  end
  local dT = maxTemp - state.lastMaxT
  local slope = dT / updateEvery_
  if slope ~= 0 then
    state.lastSlope = slope
  end
  local prediction = maxTemp + state.lastSlope * horizonSec
  state.lastMaxT = maxTemp
  return prediction
end

local function controlRodAverages()
  if #controlRods == 0 then return 0, 0 end
  local sumL, sumT, n = 0, 0, 0
  for i = 1, #controlRods do
    local cr = controlRods[i]
    local okL, L = pcall(function() return cr.getLevel() end)
    local okT, T = pcall(function() return cr.getTargetLevel() end)
    if okL and type(L) == "number" then
      sumL = sumL + L
      n = n + 1
    end
    if okT and type(T) == "number" then
      sumT = sumT + T
    end
  end
  if n == 0 then return 0, 0 end
  return sumL / n, sumT / n
end

local function avgAllRodTemp()
  local sum, n = 0, 0
  for i = 1, #rods do
    local ok, t = pcall(function() return rods[i].p.getSkinHeat() end)
    if ok and type(t) == "number" then
      sum = sum + t
      n = n + 1
    end
  end
  for i = 1, #controlRods do
    local ok, t = pcall(function() return controlRods[i].getHeat() end)
    if ok and type(t) == "number" then
      sum = sum + t
      n = n + 1
    end
  end
  if n == 0 then return 0 end
  return sum / n
end

local function computeFluxStats()
  local total, maxv, count = 0, 0, 0
  for i = 1, #rods do
    local ok, f = pcall(function() return rods[i].p.getFluxQuantity() end)
    if ok and type(f) == "number" then
      total = total + f
      count = count + 1
      if f > maxv then
        maxv = f
      end
    end
  end
  local avg = 0
  if count > 0 then
    avg = total / count
  end
  return avg, total, maxv
end

local function wireProxies()
  rsMain = nil
  rsAux = nil
  rsManual = nil

  if component.isAvailable("redstone") then
    if redstoneMainAddr and component.isAvailable(redstoneMainAddr) then
      rsMain = component.proxy(redstoneMainAddr)
    elseif redstoneMainAddr then
      pcall(function() rsMain = component.proxy(redstoneMainAddr) end)
    end

    if redstoneAuxAddr and component.isAvailable(redstoneAuxAddr) then
      rsAux = component.proxy(redstoneAuxAddr)
    elseif redstoneAuxAddr then
      pcall(function() rsAux = component.proxy(redstoneAuxAddr) end)
    end

    if redstoneManualAddr and component.isAvailable(redstoneManualAddr) then
      rsManual = component.proxy(redstoneManualAddr)
    elseif redstoneManualAddr then
      pcall(function() rsManual = component.proxy(redstoneManualAddr) end)
    end
  end

  if component.isAvailable("ntm_fluid_gauge") then
    gauge = component.ntm_fluid_gauge
  else
    gauge = nil
  end
end

local function pulseScramOutput()
  if rsMain and not scramPulsed then
    pcall(function() rsMain.setOutput(2, 15) end)
    os.sleep(2)
    pcall(function() rsMain.setOutput(2, 0) end)
    scramPulsed = true
  end
end

local function triggerAz5()
  scramOn = true
  manualTargetLevel = 0
  for i = 1, #controlRods do
    pcall(function() controlRods[i].setLevel(0) end)
  end
  pulseScramOutput()
end

local function scanComponents()
  controlRods = {}
  ctrlRaw = {}
  rodsRaw = {}
  heatersRaw = {}

  for addr in component.list("rbmk_control_rod") do
    local p = component.proxy(addr)
    controlRods[#controlRods + 1] = p
    local okC, x, _, z = pcall(function() return p.getCoordinates() end)
    ctrlRaw[#ctrlRaw + 1] = { p = p, x = okC and x or nil, z = okC and z or nil }
  end

  for addr in component.list("rbmk_fuel_rod") do
    local p = component.proxy(addr)
    local okC, x, _, z = pcall(function() return p.getCoordinates() end)
    local okT, tStr = pcall(function() return p.getType() end)
    rodsRaw[#rodsRaw + 1] = {
      p = p,
      x = okC and x or nil,
      z = okC and z or nil,
      melt = inferMeltC(okT and tStr or nil)
    }
  end

  for addr in component.list("rbmk_heater") do
    local p = component.proxy(addr)
    local okC, x, _, z = pcall(function() return p.getCoordinates() end)
    heatersRaw[#heatersRaw + 1] = { p = p, x = okC and x or nil, z = okC and z or nil }
  end

  haveLayout = false
  mapCache = {}
  mapDirty = true
end

local function buildLayout()
  rods = {}
  ctrlCols = {}
  heaters = {}

  if (#rodsRaw + #ctrlRaw + #heatersRaw) == 0 then
    return
  end

  local xSet, zSet = {}, {}
  for i = 1, #rodsRaw do
    local r = rodsRaw[i]
    if r.x and r.z then
      xSet[r.x] = true
      zSet[r.z] = true
    end
  end
  for i = 1, #ctrlRaw do
    local c = ctrlRaw[i]
    if c.x and c.z then
      xSet[c.x] = true
      zSet[c.z] = true
    end
  end
  for i = 1, #heatersRaw do
    local h = heatersRaw[i]
    if h.x and h.z then
      xSet[h.x] = true
      zSet[h.z] = true
    end
  end

  local xs, zs = {}, {}
  for k in pairs(xSet) do xs[#xs + 1] = k end
  for k in pairs(zSet) do zs[#zs + 1] = k end
  table.sort(xs)
  table.sort(zs)

  if #xs == 0 or #zs == 0 then
    local total = #rodsRaw + #ctrlRaw + #heatersRaw
    local cols = math.ceil(math.sqrt(math.max(1, total)))
    local rows = math.ceil(total / cols)
    xs, zs = {}, {}
    for i = 1, cols do xs[i] = i end
    for j = 1, rows do zs[j] = j end
  end

  local xIndex, zIndex = {}, {}
  for i = 1, #xs do xIndex[xs[i]] = i end
  for j = 1, #zs do zIndex[zs[j]] = j end
  nx, nz = #xs, #zs

  local spacing = cellSize
  local contentW = (nx - 1) * spacing * xScale + 2
  local contentH = (nz - 1) * spacing * yScale + 2

  originX = mapX1 + math.floor((mapW - contentW) / 2)
  originY = mapY1 + math.floor((mapH - contentH) / 2)

  for i = 1, #rodsRaw do
    local r = rodsRaw[i]
    local ix = r.x and xIndex[r.x] or (((i - 1) % nx) + 1)
    local iz = r.z and zIndex[r.z] or ((math.floor((i - 1) / nx) % nz) + 1)
    rods[#rods + 1] = { p = r.p, ix = ix, iz = iz, melt = r.melt, x = r.x, z = r.z }
  end

  for i = 1, #ctrlRaw do
    local c = ctrlRaw[i]
    local ix = c.x and xIndex[c.x] or (((i - 1) % nx) + 1)
    local iz = c.z and zIndex[c.z] or ((math.floor((i - 1) / nx) % nz) + 1)
    ctrlCols[#ctrlCols + 1] = { p = c.p, ix = ix, iz = iz, x = c.x, z = c.z }
  end

  for i = 1, #heatersRaw do
    local h = heatersRaw[i]
    local ix = h.x and xIndex[h.x] or (((i - 1) % nx) + 1)
    local iz = h.z and zIndex[h.z] or ((math.floor((i - 1) / nx) % nz) + 1)
    heaters[#heaters + 1] = { p = h.p, ix = ix, iz = iz, x = h.x, z = h.z }
  end

  haveLayout = true
  mapCache = {}
  mapDirty = true
end

local function refreshLayout()
  scanComponents()
  buildLayout()
end

local function plotBox(px, py, w, h, color)
  local x1 = clamp(px, mapX1, mapX2)
  local y1 = clamp(py, mapY1, mapY2)
  local x2 = clamp(px + (w - 1), mapX1, mapX2)
  local y2 = clamp(py + (h - 1), mapY1, mapY2)
  local ww = x2 - x1 + 1
  local hh = y2 - y1 + 1
  if ww <= 0 or hh <= 0 then return end
  local oldBg = gpu.getBackground()
  gpu.setBackground(color)
  gpu.fill(x1, y1, ww, hh, " ")
  gpu.setBackground(oldBg)
end

local function drawMap()
  if not haveLayout then
    buildLayout()
  end
  if nx <= 0 or nz <= 0 then
    return
  end

  local spacing = cellSize
  local desired = {}
  for ix = 1, nx do
    desired[ix] = {}
    for iz = 1, nz do
      desired[ix][iz] = MID_GRAY
    end
  end

  for i = 1, #rods do
    local r = rods[i]
    local okT, t = pcall(function() return r.p.getSkinHeat() end)
    local tc = (okT and type(t) == "number") and t or 0
    desired[r.ix][r.iz] = (tc >= shutdownTempC) and RED or lerpColorGR(tc / shutdownTempC)
  end

  for i = 1, #ctrlCols do
    local r = ctrlCols[i]
    local okL, l = pcall(function() return r.p.getLevel() end)
    local lv = (okL and type(l) == "number") and l or 0
    desired[r.ix][r.iz] = lerpColorWR(lv / 100)
  end

  for i = 1, #heaters do
    local h = heaters[i]
    local okE, e = pcall(function() return h.p.getExport() end)
    local exp = (okE and type(e) == "number") and e or 0
    desired[h.ix][h.iz] = (exp > heaterExportOkMb) and GREEN or RED
  end

  if mapDirty then
    gpu.setBackground(0x000000)
    gpu.fill(mapX1, mapY1, mapW, mapH, " ")
    mapCache = {}
  end

  for ix = 1, nx do
    if not mapCache[ix] then
      mapCache[ix] = {}
    end
    for iz = 1, nz do
      local color = desired[ix][iz]
      if mapDirty or mapCache[ix][iz] ~= color then
        local sx = originX + (ix - 1) * spacing * xScale
        local sy = originY + (iz - 1) * spacing * yScale
        plotBox(sx, sy, 2, 2, color)
        mapCache[ix][iz] = color
      end
    end
  end

  mapDirty = false
end

local function drawFrame(flowVal, avgTemp, maxFuelT, fluxAvgVal)
  gpu.fill(1, 1, scrW, 3, " ")
  local head = titleStr .. statusSuffix()
  gpu.setForeground(WHITE)
  gpu.set(1, 1, head:sub(1, math.max(0, scrW - #versionStr - 1)))
  gpu.set(math.max(1, scrW - #versionStr + 1), 1, versionStr)

  local avgL, avgT = controlRodAverages()
  local modeText, modeColor
  if scramOn then
    modeText, modeColor = "[SCRAM]", RED
  elseif autoControlOn then
    if adaptiveControlOn then
      modeText, modeColor = string.format("[AUTO-A %04.0fM]", maxTargetTempC), GREEN
    else
      modeText, modeColor = string.format("[AUTO %04.0fM]", maxTargetTempC), GREEN
    end
  else
    modeText, modeColor = string.format("[MANUAL %02.0f%%]", manualTargetLevel), YELLOW
  end

  local flwStr = string.format("FLOW[%05.0f mB/s]", flowVal)
  local xFlw = scrW - #flwStr + 1
  if xFlw < 1 then xFlw = 1 end

  gpu.setForeground(modeColor)
  gpu.set(1, 2, modeText)
  gpu.setForeground(WHITE)

  local leftL2 = string.format(" CONTROL[%5.1f%%] TGT[%5.1f%%]", avgL, avgT)
  local startL2 = 1 + #modeText
  local maxLeft2 = xFlw - startL2
  if maxLeft2 > 0 then
    gpu.set(startL2, 2, leftL2:sub(1, maxLeft2))
  end
  gpu.set(xFlw, 2, flwStr)

  local predicted10 = predictMaxTemp(mState, maxFuelT, updateEvery, 10)
  local leftL3 = string.format("FLUX[%05.1f] MAX10[%06.1f] ", fluxAvgVal or 0, predicted10)
  local tempStr = string.format("TEMP[%06.1f]", avgTemp)
  local maxTStr = string.format("MAXT[%06.1f]", maxFuelT)
  local xTemp = scrW - #tempStr + 1
  local xMaxT = xTemp - #maxTStr - 1
  gpu.setForeground(WHITE)
  gpu.set(1, 3, leftL3:sub(1, math.max(0, xMaxT - 2)))
  gpu.set(xMaxT, 3, maxTStr)
  gpu.set(xTemp, 3, tempStr)
end

local function applyConfigCommon(cfg)
  runtimeConfig = cfg
  shutdownTempC = cfg.shutdownTempC
  scramPredictTempC = cfg.scramPredictTempC
  tempStableReq = cfg.tempStableReq
  maxTargetTempC = cfg.maxTargetTempC
  updateEvery = cfg.updateEvery
  tempOffsetC = cfg.tempOffsetC
  adaptiveControlOn = cfg.adaptiveControl
  fluxScram = cfg.fluxScram
  withdrawStep = cfg.withdrawStep
  insertStep = cfg.insertStep
  rodHoldCold = cfg.rodHoldCold
  heaterExportOkMb = cfg.heaterExportOkMb

  titleStr = cfg.titleOverride or defaultTitle
  versionStr = cfg.versionOverride or defaultVersion

  redstoneMainAddr = cfg.redstoneMainAddr
  redstoneAuxAddr = cfg.redstoneAuxAddr
  redstoneManualAddr = cfg.redstoneManualAddr
  scramSide = cfg.scramRedstoneIo
  scramResetSide = cfg.scramResetRedstoneIo
  modeSwitchSide = cfg.modeSwitchRedstoneIo
  manualControlSide = cfg.manualControlRedstoneIo

  wireProxies()
end

local function applyStartupConfig(cfg)
  applyConfigCommon(cfg)
  lastCmdByAddr = {}
  resetPredictors()

  local mode = cfg.defaultMode or "AUTO"
  if mode == "SCRAM" then
    scramOn = true
    scramPulsed = false
    autoControlOn = false
    manualTargetLevel = 0
  elseif mode == "MANUAL" then
    scramOn = false
    scramPulsed = false
    autoControlOn = false
    manualTargetLevel = 0
  else
    scramOn = false
    scramPulsed = false
    autoControlOn = true
  end
end

local function applyLiveConfig(cfg)
  applyConfigCommon(cfg)
  setStatus("SETTINGS APPLIED", 20)
end

local function importFloppyConfig()
  local path = config.getFloppyPath()
  if not path then
    setStatus("NO FLOPPY FOUND", 20)
    return
  end

  local cfg, err = config.loadConfig(path)
  if not cfg then
    setStatus("INVALID FLOPPY CONFIG", 20)
    return
  end

  local ok, saveErr = config.saveConfig(config.onDiskPath, cfg)
  if not ok then
    setStatus("DISK SAVE FAILED", 20)
    return
  end

  applyLiveConfig(cfg)
  setStatus("FLOPPY IMPORTED", 24)
end

local function handleRedstoneChanged(_, addr, side, _, new)
  if not running or new == 0 then
    if addr == redstoneManualAddr then
      if side == 1 then
        debounceTop = false
      elseif side == 0 then
        debounceBottom = false
      end
    end
    return
  end

  if rsMain and addr == rsMain.address then
    if side == scramSide then
      triggerAz5()
      return
    elseif side == scramResetSide then
      scramOn = false
      scramPulsed = false
      setStatus("SCRAM RESET", 16)
      return
    end
  end

  if rsAux and addr == rsAux.address then
    if side == modeSwitchSide then
      if scramOn then return end
      autoControlOn = not autoControlOn
      if not autoControlOn and #controlRods > 0 then
        local avgL = select(1, controlRodAverages())
        manualTargetLevel = roundTo5(clamp(avgL, 0, 100))
        for i = 1, #controlRods do
          pcall(function() controlRods[i].setLevel(manualTargetLevel) end)
        end
      end
      setStatus(autoControlOn and "AUTO TOGGLE ON" or "AUTO TOGGLE OFF", 16)
      return
    end
  end

  if rsManual and addr == rsManual.address then
    if autoControlOn or scramOn then return end

    if side == 1 then
      if not debounceTop then
        manualTargetLevel = clamp(roundTo5(manualTargetLevel + 5), 0, 100)
        for i = 1, #controlRods do
          pcall(function() controlRods[i].setLevel(manualTargetLevel) end)
        end
        debounceTop = true
      end
    elseif side == 0 then
      if not debounceBottom then
        manualTargetLevel = clamp(roundTo5(manualTargetLevel - 5), 0, 100)
        for i = 1, #controlRods do
          pcall(function() controlRods[i].setLevel(manualTargetLevel) end)
        end
        debounceBottom = true
      end
    end
  end
end

local function handleKeyDown(_, _, char, code)
  if not running then return end
  if code == keyboard.keys.s or char == string.byte("s") or char == string.byte("S") then
    importFloppyConfig()
  end
end

local function bindListeners()
  if listenersBound then return end
  event.listen("redstone_changed", handleRedstoneChanged)
  event.listen("key_down", handleKeyDown)
  listenersBound = true
end

local function unbindListeners()
  if not listenersBound then return end
  pcall(function() event.ignore("redstone_changed", handleRedstoneChanged) end)
  pcall(function() event.ignore("key_down", handleKeyDown) end)
  listenersBound = false
end

local function runControlLoop(maxFuelT)
  if scramOn then
    for i = 1, #controlRods do
      pcall(function() controlRods[i].setLevel(0) end)
    end
    return
  end

  if #controlRods == 0 then return end

  if autoControlOn then
    local k = tempAuthorityK(maxFuelT + tempOffsetC)

    if adaptiveControlOn then
      local sumByRod = {}
      local cntByRod = {}

      for i = 1, #rods do
        local fr = rods[i]
        local okSkin, skin = pcall(function() return fr.p.getSkinHeat() end)
        local tc = (okSkin and type(skin) == "number") and skin or 0
        local desiredLocal = math.floor(computeRetract(tc) * 100 + 0.5)

        if fr.x ~= nil and fr.z ~= nil then
          for j = 1, #ctrlRaw do
            local cr = ctrlRaw[j]
            if cr.x ~= nil and cr.z ~= nil then
              local dx = cr.x - fr.x
              local dz = cr.z - fr.z
              if dx >= -1 and dx <= 1 and dz >= -1 and dz <= 1 then
                local key = cr.p.address
                sumByRod[key] = (sumByRod[key] or 0) + desiredLocal
                cntByRod[key] = (cntByRod[key] or 0) + 1
              end
            end
          end
        end
      end

      local desiredGlobal = math.floor(computeRetract(maxFuelT) * 100 + 0.5)

      for i = 1, #controlRods do
        local cr = controlRods[i]
        local key = cr.address
        local s = sumByRod[key]
        local c = cntByRod[key]
        local desired
        if c and c > 0 then
          desired = math.floor((s / c) + 0.5)
        else
          desired = desiredGlobal
        end

        local commanded = rodHoldCold + k * (desired - rodHoldCold)
        local last = lastCmdByAddr[key]
        if last ~= nil then
          if commanded > last then
            commanded = math.min(last + withdrawStep, commanded)
          else
            commanded = math.max(last - insertStep, commanded)
          end
        end
        commanded = clamp(commanded, 0, 100)
        lastCmdByAddr[key] = commanded
        pcall(function() cr.setLevel(math.floor(commanded + 0.5)) end)
      end
    else
      local desired = math.floor(computeRetract(maxFuelT) * 100 + 0.5)
      for i = 1, #controlRods do
        local cr = controlRods[i]
        local key = cr.address
        local commanded = rodHoldCold + k * (desired - rodHoldCold)
        local last = lastCmdByAddr[key]
        if last ~= nil then
          if commanded > last then
            commanded = math.min(last + withdrawStep, commanded)
          else
            commanded = math.max(last - insertStep, commanded)
          end
        end
        commanded = clamp(commanded, 0, 100)
        lastCmdByAddr[key] = commanded
        pcall(function() cr.setLevel(math.floor(commanded + 0.5)) end)
      end
    end
  else
    for i = 1, #controlRods do
      pcall(function() controlRods[i].setLevel(manualTargetLevel) end)
    end
  end
end

function M.run()
  gpu.setResolution(scrW, scrH)
  gpu.setBackground(0x000000)
  gpu.setForeground(WHITE)
  term.clear()

  local cfg, err = config.loadOrCreate(config.onDiskPath)
  if not cfg then
    cfg = config.getDefaultConfig()
    setStatus("DEFAULTS IN USE", 20)
  else
    setStatus("DISK SETTINGS LOADED", 16)
  end

  applyStartupConfig(cfg)
  refreshLayout()
  bindListeners()

  if refreshTimerId then
    pcall(function() event.cancel(refreshTimerId) end)
  end
  refreshTimerId = event.timer(3.0, refreshLayout, math.huge)

  running = true

  while true do
    if gauge then
      local ok, mbt, mbs = pcall(function() return gauge.getTransfer() end)
      if ok and type(mbs) == "number" then
        flowSec = mbt * 20
      else
        flowSec = 0
      end
    else
      flowSec = 0
    end

    fluxAvg, fluxTotal, fluxMax = computeFluxStats()

    local maxFuelT, maxCtrlT = 0, 0
    for i = 1, #rods do
      local p = rods[i].p
      local okSkin, skin = pcall(function() return p.getSkinHeat() end)
      local tc = (okSkin and type(skin) == "number") and skin or 0
      if (not scramOn) and tc >= shutdownTempC then
        triggerAz5()
      end
      if tc > maxFuelT then
        maxFuelT = tc
      end
    end

    for i = 1, #controlRods do
      local okH, h = pcall(function() return controlRods[i].getHeat() end)
      if okH and type(h) == "number" then
        if (not scramOn) and h >= shutdownTempC then
          triggerAz5()
        end
        if h > maxCtrlT then
          maxCtrlT = h
        end
      end
    end

    if math.abs(maxFuelT - (sState.lastMaxT or maxFuelT)) < 5 then
      tempStableTime = tempStableTime + updateEvery
    else
      tempStableTime = 0
    end

    if tempStableTime >= tempStableReq then
      local predicted10 = predictMaxTemp(sState, maxFuelT, updateEvery, 10)
      if predicted10 >= scramPredictTempC then
        predTripSec = predTripSec + updateEvery
        if (not scramOn) and predTripSec >= tempStableReq then
          triggerAz5()
        end
      else
        predTripSec = 0
      end
    else
      sState.lastMaxT = maxFuelT
      sState.lastSlope = 0
      predTripSec = 0
    end

    if (not scramOn) and fluxMax >= fluxScram then
      triggerAz5()
    end

    runControlLoop(maxFuelT)
    drawFrame(flowSec, avgAllRodTemp(), maxFuelT, fluxAvg)
    drawMap()

    if statusTtl > 0 then
      statusTtl = statusTtl - 1
      if statusTtl <= 0 then
        statusText = nil
      end
    end

    os.sleep(updateEvery)
  end
end

function M.stop()
  running = false
  if refreshTimerId then
    pcall(function() event.cancel(refreshTimerId) end)
    refreshTimerId = nil
  end
  unbindListeners()
end

return M
