-- OpenRBMK configuration file for v14.19 and up
-- Strong unattended-operation configuration

return {
  shutdownTempC     = 900,    -- °C hard SCRAM
  scramPredictTempC = 1500,  -- °C anticipatory (soft) SCRAM
  tempStableReq     = 5.0,
  maxTargetTempC    = 1100,    -- °C full AUTO authority reached at (this - 300)
  updateEvery       = 0.10,   -- seconds
  tempOffsetC       = 0,

  autoStart         = true,  -- AUTO only via mode switch
  adaptiveControl   = true,

  -- Flux safety (NO LONGER used for AUTO magnitude)
  fluxScram         = 1300,   -- hard SCRAM on prompt excursion
  fluxFilterSec     = 3.0,    -- smoothing for rate limiting only

  -- Rod motion limits
  withdrawStep      = 1,      -- % per cycle (out)
  insertStep        = 6,      -- % per cycle (in)

  -- Optional
  rodHoldCold       = 10,      -- % minimum at cold (can be 0 now)
  heaterExportOkMb  = 2,

  titleOverride     = nil,
  versionOverride   = nil
}
