-- OpenRBMK Any-Core Monitor — v14.20 (60x24 display)
-- Adaptive Control + RBMK Heater (HEATEX) map support + Flux + Unattended-safe AUTO
--
-- FIXES / CHANGES (from v14.19):
-- v14.20:
--  1) Fix flux return unpack bug (avg/total/max were being mis-assigned).
--  2) FLUX[] now displays average core flux (human readable).
--  3) Flux SCRAM uses max-per-rod flux (prevents harmless total-flux insertion blips from SCRAM).
--  4) AUTO authority clamp is temperature-based: 20C -> rodHoldCold, (maxTargetTempC-300) -> full authority, linear between.
--  5) Remove flux-based AUTO magnitude (flux is safety/display only).
--  6) Fix GLOBAL AUTO path using undefined variable (adjustedTemp).

local component = require("component")
local event     = require("event")
local term      = require("term")
local fs        = require("filesystem")
local gpu       = component.gpu

-- ================== CONFIG ==================
local diskDriveAddr      = "7ebf20f8-972f-4695-b357-f5d6aed24274" -- Config floppy drive
local redstoneMainAddr   = "d70380a6-aa4c-425b-b934-867dbc4b3eb5" -- scram on front side, scram reset on back side
local redstoneAuxAddr    = "a0a556a7-4602-4eaf-a61a-d479de8805bb" -- mode switch (manual/auto)
local redstoneManualAddr = "bab2a090-a584-4eef-809b-ce26ecdf2b68" -- manual control rods in/out
local buttonSide, resetSide, auxToggleSide = 3, 2, 3 -- dn=0 up=1 n=2 s=3 w=3 e=4

local titleStr    = "OpenRBMK Any-Core Monitor"
local versionStr  = "V14.20"

-- Default config values (overridden by floppy)
local shutdownTempC    = 550
local maxTargetTempC   = 400
local updateEvery      = 0.5
local tempOffsetC      = 0
local autoControlOn    = false

local tempStableTime = 0
local tempStableReq  = 10  -- seconds (configurable if you want)

local predTripSec = 0
local scramPredictTempC = 1500   -- prediction SCRAM threshold (°C)
local tempStableReq = 5.0        -- seconds prediction must persist

-- Adaptive control default OFF (must be explicitly enabled via floppy)
local adaptiveControlOn = false

-- Heater export threshold (mB)
local heaterExportOkMb = 2

-- Flux safety
local fluxScram = 1300  -- hard SCRAM threshold (use MAX-per-rod flux)

-- Rate limiting (CONFIGURABLE)
local withdrawStep = 1      -- % per loop maximum withdrawal step (out)
local insertStep   = 6      -- % per loop maximum insertion step (in)

-- Optional minimum at cold
local rodHoldCold  = 0      -- % minimum at cold (20C). Can be 0.

-- floppy config system
local lastMedia = nil

local function loadSettingsFromDisk()
  local drive = component.proxy(diskDriveAddr)
  if not drive or drive.isEmpty() then return nil, "no floppy" end

  local mediaAddr = drive.media()
  if not mediaAddr then return nil, "no media" end
  local mount = "/mnt/" .. mediaAddr:sub(1, 3)
  local cfgPath = mount .. "/openrbmk_settings.lua"
  if not fs.exists(cfgPath) then return nil, "no config file" end

  local ok, data = pcall(dofile, cfgPath)
  if ok and type(data) == "table" then return data else return nil, "invalid config" end
end

local function applySettings(cfg)
  if not cfg then return end
  if cfg.shutdownTempC     then shutdownTempC     = cfg.shutdownTempC end
  if cfg.maxTargetTempC    then maxTargetTempC    = cfg.maxTargetTempC end
  if cfg.updateEvery       then updateEvery       = cfg.updateEvery end
  if cfg.tempOffsetC       then tempOffsetC       = cfg.tempOffsetC end
  if cfg.autoStart ~= nil  then autoControlOn     = cfg.autoStart end
  if cfg.titleOverride     then titleStr          = cfg.titleOverride end
  if cfg.versionOverride   then versionStr        = cfg.versionOverride end
  if cfg.scramPredictTempC then scramPredictTempC = cfg.scramPredictTempC end
  if cfg.tempStableReq     then tempStableReq     = cfg.tempStableReq end

  if cfg.adaptiveControl ~= nil then adaptiveControlOn = cfg.adaptiveControl end

  if cfg.fluxScram then fluxScram = cfg.fluxScram end

  if cfg.withdrawStep then withdrawStep = cfg.withdrawStep end
  if cfg.insertStep   then insertStep   = cfg.insertStep end
  if cfg.rodHoldCold  ~= nil then rodHoldCold = cfg.rodHoldCold end

  if cfg.heaterExportOkMb then heaterExportOkMb = cfg.heaterExportOkMb end
end

-- load at startup
do
  local cfg, err = loadSettingsFromDisk()
  if cfg then
    applySettings(cfg)
    print("[OpenRBMK] Settings loaded from floppy.")
  else
    print("[OpenRBMK] Defaults in use (" .. (err or "ok") .. ")")
  end
end

--============================================================

local headStr=titleStr
local prevCfg=0

local defaultMeltC=2865
local scrW,scrH=60,24; gpu.setResolution(scrW,scrH)
local xScale=2
local yScale=1
local cellSize=2
local mapX1,mapY1=2,4; local mapX2,mapY2=59,24
local mapW,mapH=mapX2-mapX1+1,mapY2-mapY1+1

local rodsRaw,rods={},{}
local ctrlRaw,ctrlCols={},{}
local heatersRaw,heaters={},{}  -- rbmk_heater support

local controlRods={}
local scramOn,scramPulsed=false,false
local haveLayout=false; local originX,originY=2,4
local nx,nz=0,0; local rsMain,rsAux,rsManual=nil,nil,nil
local flowSec=0; local gauge=nil
local manualTargetLevel=0
local debounceTop,debounceBottom=false,false
local GREEN,YELLOW,RED,WHITE,MID_GRAY=0x00FF00,0xFFFF00,0xFF0000,0xFFFFFF,0x555555
local mapCache={}
local mapDirty=true

-- Flux state (computed per loop)
local fluxAvg, fluxTotal, fluxMax = 0, 0, 0

-- rate limiting state (per control rod address)
local lastCmdByAddr = {}

local function clamp(x,a,b) if x<a then return a elseif x>b then return b else return x end end
local function rgb(r,g,b) return (r<<16)+(g<<8)+b end
local function lerpColorGR(t) t=clamp(t,0,1); return rgb(math.floor(255*t+0.5), math.floor(255*(1-t)+0.5), 0) end
local function lerpColorWR(t) t=clamp(t,0,1); return rgb(255, math.floor(255*(1-t)+0.5), math.floor(255*(1-t)+0.5)) end
local function roundTo5(x) return math.floor((x+2.5)/5)*5 end

-- Original AUTO curve (desired position from temperature error)
local function computeRetract(tempC)
  local adjusted=tempC+tempOffsetC
  local a=-adjusted/100+((maxTargetTempC/100)+1)
  if a<=0 then return 0 end
  return clamp(1.183*(math.log(a)/math.log(10)),0,1)
end

-- NEW: temperature authority scalar (0..1)
-- 20C -> 0 authority (rodHoldCold only)
-- (maxTargetTempC-300) -> full authority
local function tempAuthorityK(maxFuelT)
  local Tmin = 20
  if (maxTargetTempC - 300) < 300 then Tfull = maxTargetTempC - 450 else Tfull = 400 end
  if Tfull <= Tmin then return 1 end
  return clamp((maxFuelT - Tmin) / (Tfull - Tmin), 0, 1)
end

-- MELT TABLE
local meltByKey={
  nu=2865,meu=2865,heu235=2865,heu233=2865,thmeu=3350,lep239=2744,mep239=2744,hep239=2744,hep241=2744,
  lea=2386,mea=2386,hea241=2386,hea242=2386,men=2800,hen=2800,mox=2815,les=2500,mes=2750,hes=3000,
  leaus=7029,heaus=5211,ra226be=700,po210be=1287,pu238be=1287,bismuth=2744,pu241=2865,rga=2744,
  flashgold=2000,flashlead=2050,balefire=3652,digamma=100000,rbmkfueltest=100000
}
local function inferMeltC(typeStr)
  if typeStr and type(typeStr)=="string" then
    local s=typeStr:lower()
    for k,m in pairs(meltByKey) do if s:find(k,1,true) then return m end end
  end
  return defaultMeltC
end

-- DISCOVERY
local function scanComponents()
  controlRods,ctrlRaw={},{ }
  for addr in component.list("rbmk_control_rod") do
    local p=component.proxy(addr)
    controlRods[#controlRods+1]=p
    local okC,x,_,z=pcall(function() return p.getCoordinates() end)
    ctrlRaw[#ctrlRaw+1]={p=p,x=okC and x or nil,z=okC and z or nil}
  end

  rodsRaw={}
  for addr in component.list("rbmk_fuel_rod") do
    local p=component.proxy(addr)
    local okC,x,_,z=pcall(function() return p.getCoordinates() end)
    local okT,tStr=pcall(function() return p.getType() end)
    rodsRaw[#rodsRaw+1]={p=p,x=okC and x or nil,z=okC and z or nil,melt=inferMeltC(okT and tStr or nil)}
  end

  heatersRaw={}
  for addr in component.list("rbmk_heater") do
    local p=component.proxy(addr)
    local okC,x,_,z=pcall(function() return p.getCoordinates() end)
    heatersRaw[#heatersRaw+1]={p=p,x=okC and x or nil,z=okC and z or nil}
  end

  if component.isAvailable("ntm_fluid_gauge") then gauge=component.ntm_fluid_gauge end
  haveLayout=false
  mapCache={}
  mapDirty=true
end

-- prediction function with independent state
local function predictMaxTemp(state, maxTemp, updateEvery_, horizonSec)
  if not maxTemp or maxTemp <= 0 then return 0 end
  if not state.lastMaxT then
    state.lastMaxT = maxTemp
    return maxTemp
  end
  local dT = maxTemp - state.lastMaxT
  local slope = dT / updateEvery_
  if slope ~= 0 then state.lastSlope = slope end
  local prediction = maxTemp + state.lastSlope * horizonSec
  state.lastMaxT = maxTemp
  return prediction
end

-- separate predictor states
local mState = { lastMaxT=nil, lastSlope=0 }  -- for MAX10 display
local sState = { lastMaxT=nil, lastSlope=0 }  -- for SCRAM prediction

-- LAYOUT
local function buildLayout()
  rods,ctrlCols,heaters={}, {}, {}
  if (#rodsRaw+#ctrlRaw+#heatersRaw)==0 then return end

  local xSet,zSet={},{ }
  for i=1,#rodsRaw do local r=rodsRaw[i]; if r.x and r.z then xSet[r.x]=true; zSet[r.z]=true end end
  for i=1,#ctrlRaw do local c=ctrlRaw[i]; if c.x and c.z then xSet[c.x]=true; zSet[c.z]=true end end
  for i=1,#heatersRaw do local h=heatersRaw[i]; if h.x and h.z then xSet[h.x]=true; zSet[h.z]=true end end

  local xs,zs={},{ }
  for k in pairs(xSet) do xs[#xs+1]=k end; table.sort(xs)
  for k in pairs(zSet) do zs[#zs+1]=k end; table.sort(zs)

  if #xs==0 or #zs==0 then
    local tot=#rodsRaw+#ctrlRaw+#heatersRaw
    local cols=math.ceil(math.sqrt(math.max(1,tot)))
    local rows=math.ceil(tot/cols)
    xs, zs = {}, {}
    for i=1,cols do xs[i]=i end
    for j=1,rows do zs[j]=j end
  end

  xIndex,zIndex={},{}
  for i=1,#xs do xIndex[xs[i]]=i end
  for j=1,#zs do zIndex[zs[j]]=j end
  nx,nz=#xs,#zs

  local spacing = cellSize
  local contentW = (nx - 1) * spacing * xScale + 2
  local contentH = (nz - 1) * spacing * yScale + 2

  originX = mapX1 + math.floor((mapW - contentW) / 2)
  originY = mapY1 + math.floor((mapH - contentH) / 2)

  for i=1,#rodsRaw do
    local r=rodsRaw[i]
    local ix=r.x and xIndex[r.x] or ((i-1)%nx)+1
    local iz=r.z and zIndex[r.z] or (math.floor((i-1)/nx)%nz)+1
    rods[#rods+1]={p=r.p,ix=ix,iz=iz,melt=r.melt,x=r.x,z=r.z}
  end

  for i=1,#ctrlRaw do
    local c=ctrlRaw[i]
    local ix=c.x and xIndex[c.x] or ((i-1)%nx)+1
    local iz=c.z and zIndex[c.z] or (math.floor((i-1)/nx)%nz)+1
    ctrlCols[#ctrlCols+1]={p=c.p,ix=ix,iz=iz,x=c.x,z=c.z}
  end

  for i=1,#heatersRaw do
    local h=heatersRaw[i]
    local ix=h.x and xIndex[h.x] or ((i-1)%nx)+1
    local iz=h.z and zIndex[h.z] or (math.floor((i-1)/nx)%nz)+1
    heaters[#heaters+1]={p=h.p,ix=ix,iz=iz,x=h.x,z=h.z}
  end

  haveLayout=true
  mapCache={}
  mapDirty=true
end

-- AVERAGES
local function controlRodAverages()
  if #controlRods==0 then return 0,0 end
  local sumL,sumT,n=0,0,0
  for i=1,#controlRods do
    local cr=controlRods[i]
    local okL,L=pcall(function() return cr.getLevel() end)
    local okT,T=pcall(function() return cr.getTargetLevel() end)
    if okL and type(L)=="number" then sumL=sumL+L; n=n+1 end
    if okT and type(T)=="number" then sumT=sumT+T end
  end
  if n==0 then return 0,0 end
  return (sumL/n),(sumT/n)
end

local function avgAllRodTemp()
  local sum,n=0,0
  for i=1,#rods do
    local ok,t=pcall(function() return rods[i].p.getSkinHeat() end)
    if ok and type(t)=="number" then sum=sum+t; n=n+1 end
  end
  for i=1,#controlRods do
    local ok,t=pcall(function() return controlRods[i].getHeat() end)
    if ok and type(t)=="number" then sum=sum+t; n=n+1 end
  end
  return (n>0) and (sum/n) or 0
end

-- compute flux avg + total + max per loop (fuel rods only)
local function computeFluxTotalAndMax()
  local total, maxv = 0, 0
  for i = 1, #rods do
    local ok, f = pcall(function() return rods[i].p.getFluxQuantity() end)
    if ok and type(f) == "number" then
      total = total + f
      if f > maxv then maxv = f end
    end
  end
  return total, maxv
end


-- UI
gpu.setBackground(0x000000)

local function drawFrame(flowVal,avgTemp,updateEvery_,maxFuelT,fluxAvgVal)
  gpu.fill(1,1,scrW,3," ")
  gpu.set(1,1,headStr); gpu.set(scrW-#versionStr+1,1,versionStr)
  local avgL,avgT=controlRodAverages()

  local modeText,modeColor
  if scramOn then
    modeText,modeColor="[SCRAM]",RED
  elseif autoControlOn then
    if adaptiveControlOn then
      modeText,modeColor=string.format("[AUTO-A %04.0fM]", maxTargetTempC),GREEN
    else
      modeText,modeColor=string.format("[AUTO %04.0fM]", maxTargetTempC),GREEN
    end
  else
    modeText,modeColor=string.format("[MANUAL %02.0f%%]", manualTargetLevel),YELLOW
  end

  local flwStr=string.format("FLOW[%05.0f mB/s]",flowVal)
  local xFlw=scrW-#flwStr+1; if xFlw<1 then xFlw=1 end
  gpu.setForeground(modeColor); gpu.set(1,2,modeText); gpu.setForeground(WHITE)
  local leftL2=string.format(" CONTROL[%5.1f%%] TGT[%5.1f%%]",avgL,avgT)
  local startL2=1+#modeText
  local maxLeft2=xFlw-1-startL2+1
  if maxLeft2 and maxLeft2>0 then gpu.set(startL2,2,leftL2:sub(1,maxLeft2)) end
  gpu.set(xFlw,2,flwStr)

  local leftL3 = string.format(
    "FLUX[%06.1f] MAX10[%06.1f] ",
    fluxAvgVal or 0,
    predictMaxTemp(mState, maxFuelT, updateEvery_, 10)
  )
  local tempStr=string.format("TEMP[%06.1f]",avgTemp)
  local maxtStr=string.format("MAXT[%06.1f]",maxFuelT)
  local xTemp=scrW-#tempStr+1
  local xMaxT=xTemp-#maxtStr-1
  gpu.set(1,3,leftL3:sub(1,math.max(0,xMaxT-2)))
  gpu.set(xMaxT,3,maxtStr)
  gpu.set(xTemp,3,tempStr)
end

-- box draw (clipped)
local function plotBox(px,py,w,h,color)
  local x1=clamp(px, mapX1, mapX2)
  local y1=clamp(py, mapY1, mapY2)
  local x2=clamp(px+(w-1), mapX1, mapX2)
  local y2=clamp(py+(h-1), mapY1, mapY2)
  local ww=x2-x1+1
  local hh=y2-y1+1
  if ww<=0 or hh<=0 then return end
  local obg=gpu.getBackground()
  gpu.setBackground(color); gpu.fill(x1,y1,ww,hh," "); gpu.setBackground(obg)
end

local function drawMap()
  if not haveLayout then buildLayout() end
  if nx<=0 or nz<=0 then return end

  local spacing = cellSize
  local desired = {}

  for ix=1,nx do
    desired[ix]={}
    for iz=1,nz do
      desired[ix][iz]=MID_GRAY
    end
  end

  -- fuel rods
  for i=1,#rods do
    local r=rods[i]
    local okT,t=pcall(function() return r.p.getSkinHeat() end)
    local tc=(okT and type(t)=="number") and t or 0
    desired[r.ix][r.iz]=(tc>=shutdownTempC) and RED or lerpColorGR(tc/shutdownTempC)
  end

  -- control rods
  for i=1,#ctrlCols do
    local r=ctrlCols[i]
    local okL,l=pcall(function() return r.p.getLevel() end)
    local lv=(okL and type(l)=="number") and l or 0
    desired[r.ix][r.iz]=lerpColorWR(lv/100)
  end

  -- heaters
  for i=1,#heaters do
    local h=heaters[i]
    local okE,e=pcall(function() return h.p.getExport() end)
    local exp=(okE and type(e)=="number") and e or 0
    desired[h.ix][h.iz]=(exp>heaterExportOkMb) and GREEN or RED
  end

  if mapDirty then
    gpu.setBackground(0x000000)
    gpu.fill(mapX1, mapY1, mapW, mapH, " ")
    mapCache={}
  end

  for ix=1,nx do
    if not mapCache[ix] then mapCache[ix]={} end
    for iz=1,nz do
      local color = desired[ix][iz]
      if mapDirty or mapCache[ix][iz] ~= color then
        local sx=originX + (ix - 1) * spacing * xScale
        local sy=originY + (iz - 1) * spacing * yScale
        plotBox(sx, sy, 2, 2, color)
        mapCache[ix][iz]=color
      end
    end
  end

  mapDirty=false
end

-- SCRAM
function triggerAz5()
  -- AUTO remains latched; SCRAM is an override layer
  scramOn = true
  manualTargetLevel = 0
  for i=1,#controlRods do
    pcall(function() return controlRods[i].setLevel(0) end)
  end
  if rsMain and not scramPulsed then
    pcall(function() rsMain.setOutput(2,15) end)
    os.sleep(2)
    pcall(function() rsMain.setOutput(2,0) end)
    scramPulsed = true
  end
end

-- REDSTONE INPUT
local function wireRedstone()
  if component.isAvailable("redstone") then
    if redstoneMainAddr then rsMain=component.proxy(redstoneMainAddr) end
    if redstoneAuxAddr  then rsAux =component.proxy(redstoneAuxAddr ) end
    if redstoneManualAddr then rsManual=component.proxy(redstoneManualAddr) end

    -- SCRAM/reset from rsMain
    if rsMain then
      event.listen("redstone_changed", function(_,addr,side,old,new)
        if addr==rsMain.address and new>0 then
          if side==buttonSide then triggerAz5()
          elseif side==resetSide then
            scramOn=false; scramPulsed=false
          end
        end
      end)
    end

    -- AUTO toggle from rsAux
    if rsAux then
      event.listen("redstone_changed", function(_, addr, side, old, new)
        if addr ~= rsAux.address or side ~= auxToggleSide or new == 0 then return end
        if scramOn then return end
        autoControlOn = not autoControlOn
        if not autoControlOn and #controlRods > 0 then
          local avgL = select(1, controlRodAverages())
          manualTargetLevel = roundTo5(clamp(avgL, 0, 100))
          for i=1,#controlRods do
            pcall(function() return controlRods[i].setLevel(manualTargetLevel) end)
          end
        end
      end)
    end

    -- Manual UP/DOWN on rsManual (ignored in AUTO or SCRAM)
    if rsManual then
      event.listen("redstone_changed", function(_, addr, side, old, new)
        if addr ~= rsManual.address then return end
        if autoControlOn then return end
        if scramOn then return end

        if side == 1 then
          if new > 0 and not debounceTop then
            manualTargetLevel = clamp(roundTo5(manualTargetLevel + 5), 0, 100)
            for i=1,#controlRods do
              pcall(function() return controlRods[i].setLevel(manualTargetLevel) end)
            end
            debounceTop = true
          elseif new == 0 then
            debounceTop = false
          end

        elseif side == 0 then
          if new > 0 and not debounceBottom then
            manualTargetLevel = clamp(roundTo5(manualTargetLevel - 5), 0, 100)
            for i=1,#controlRods do
              pcall(function() return controlRods[i].setLevel(manualTargetLevel) end)
            end
            debounceBottom = true
          elseif new == 0 then
            debounceBottom = false
          end
        end
      end)
    end
  end
end

-- RUNTIME
local function refresh() scanComponents(); buildLayout() end
scanComponents(); buildLayout(); wireRedstone()
event.timer(3.0, refresh)
term.clear()

while true do

  if prevCfg == 0 then headStr=titleStr end
  if prevCfg > 0 then prevCfg=prevCfg-1 end

  -- flow from gauge
  if gauge then
    local ok,mbt,mbs = pcall(function() return gauge.getTransfer() end)
    if ok and type(mbs)=="number" then flowSec=mbs else flowSec=0 end
  end

  -- FIX: correct flux unpack (avg, total, max)
  fluxTotal, fluxMax = computeFluxTotalAndMax()

  local maxFuelT,maxCtrlT=0,0
  for i=1,#rods do
    local p=rods[i].p
    local okSkin,skin=pcall(function() return p.getSkinHeat() end)
    local tc=(okSkin and type(skin)=="number") and skin or 0
    if (not scramOn) and tc>=shutdownTempC then triggerAz5() end
    if tc>maxFuelT then maxFuelT=tc end
  end

  for i=1,#controlRods do
    local okH,h=pcall(function() return controlRods[i].getHeat() end)
    if okH and type(h)=="number" then
      if (not scramOn) and h>=shutdownTempC then triggerAz5() end
      if h>maxCtrlT then maxCtrlT=h end
    end
  end

  -- predictive protection (10s horizon, 1500 °C)
  -- Temperature stability gating for predictor
  if math.abs(maxFuelT - (sState.lastMaxT or maxFuelT)) < 5 then
    tempStableTime = tempStableTime + updateEvery
  else
    tempStableTime = 0
  end

  if tempStableTime >= tempStableReq then
    -- 10-second temperature prediction SCRAM (time-qualified)
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
    -- Reset predictor during transients
    sState.lastMaxT = maxFuelT
  end


  -- FIX: flux SCRAM uses MAX PER-ROD flux (not avg/total)
  if (not scramOn) and fluxMax >= fluxScram then
    triggerAz5()
  end

  -- rod control
  if scramOn then
    -- force rods fully in every loop (SCRAM overrides ALL modes)
    for i=1,#controlRods do
      pcall(function() return controlRods[i].setLevel(0) end)
    end

  elseif #controlRods>0 then
    if autoControlOn then
      -- FIX: temperature authority scalar (0..1)
      local k = tempAuthorityK(maxFuelT + tempOffsetC)

      if adaptiveControlOn then
        local sumByRod = {}
        local cntByRod = {}

        for i=1,#rods do
          local fr = rods[i]
          local okSkin,skin=pcall(function() return fr.p.getSkinHeat() end)
          local tc=(okSkin and type(skin)=="number") and skin or 0

          local desiredLocal = math.floor(computeRetract(tc) * 100 + 0.5)

          if fr.x ~= nil and fr.z ~= nil then
            for j=1,#ctrlRaw do
              local cr = ctrlRaw[j]
              if cr.x ~= nil and cr.z ~= nil then
                local dx = cr.x - fr.x
                local dz = cr.z - fr.z
                if dx >= -1 and dx <= 1 and dz >= -1 and dz <= 1 then
                  local key = cr.p
                  sumByRod[key] = (sumByRod[key] or 0) + desiredLocal
                  cntByRod[key] = (cntByRod[key] or 0) + 1
                end
              end
            end
          end
        end

        local desiredGlobal = math.floor(computeRetract(maxFuelT) * 100 + 0.5)

        for i=1,#controlRods do
          local cr = controlRods[i]
          local s = sumByRod[cr]
          local c = cntByRod[cr]

          local desired
          if c and c > 0 then
            desired = math.floor((s / c) + 0.5)
          else
            desired = desiredGlobal
          end

          -- temperature authority clamp
          local commanded = rodHoldCold + k * (desired - rodHoldCold)

          -- rate limiting
          local addr = cr.address
          local last = lastCmdByAddr[addr]
          if last ~= nil then
            if commanded > last then
              commanded = math.min(last + withdrawStep, commanded)
            else
              commanded = math.max(last - insertStep, commanded)
            end
          end
          commanded = clamp(commanded, 0, 100)
          lastCmdByAddr[addr] = commanded

          pcall(function() return cr.setLevel(math.floor(commanded + 0.5)) end)
        end

      else
        -- GLOBAL AUTO: desired from computeRetract(maxFuelT), then authority clamp
        local desired = math.floor(computeRetract(maxFuelT) * 100 + 0.5)

        for i=1,#controlRods do
          local cr = controlRods[i]

          local commanded = rodHoldCold + k * (desired - rodHoldCold)

          local addr = cr.address
          local last = lastCmdByAddr[addr]
          if last ~= nil then
            if commanded > last then
              commanded = math.min(last + withdrawStep, commanded)
            else
              commanded = math.max(last - insertStep, commanded)
            end
          end
          commanded = clamp(commanded, 0, 100)
          lastCmdByAddr[addr] = commanded

          pcall(function() return cr.setLevel(math.floor(commanded + 0.5)) end)
        end
      end

    else
      -- MANUAL
      for i=1,#controlRods do
        pcall(function() return controlRods[i].setLevel(manualTargetLevel) end)
      end
    end
  end

  -- draw (FLUX shows average)
  drawFrame(flowSec, avgAllRodTemp(), updateEvery, maxFuelT, fluxTotal)
  drawMap()

  -- === floppy config auto-detect ===
  local drive = component.proxy(diskDriveAddr)
  if drive then
    local mediaAddr = nil
    if not drive.isEmpty() then
      mediaAddr = drive.media()
    end
    if mediaAddr ~= lastMedia and mediaAddr ~= nil then
      local cfg, err = loadSettingsFromDisk()
      if cfg then
        applySettings(cfg)
        headStr=titleStr .. " [LOAD FLOPPY]"
        prevCfg=2
      else
        headStr=titleStr .. " [LOAD FLOPPY FAIL]"
      end
    end
    lastMedia = mediaAddr
  end

  os.sleep(updateEvery)
end
