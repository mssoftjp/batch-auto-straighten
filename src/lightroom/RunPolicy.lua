local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
-- Pure, persisted run options. UI signs follow Lightroom's Angle control.
local P = {}
P.rawExtensions = { "3FR", "ARI", "ARW", "BAY", "BMQ", "CAP", "CR2", "CR3", "CRW", "CS1", "DC2", "DCR", "DNG", "ERF", "FFF", "GPR", "IIQ", "K25", "KDC", "MDC", "MEF", "MOS", "MRW", "NEF", "NRW", "ORF", "PEF", "PTX", "PXN", "R3D", "RAF", "RAW", "RW2", "RWL", "RWZ", "SR2", "SRF", "SRW", "STI", "X3F" }
local raw = {}
for _, ext in ipairs(P.rawExtensions) do raw[ext] = true end
function P.isRaw(format, ext)
  return format == "RAW" or format == "DNG" or raw[string.upper(ext or "")] == true
end
function P.defaults(prefs)
  prefs = prefs or {}
  local saved = prefs.runOptions or {}
  local o = {
    sameNameMode = "matchRaw",
    maxLeftAngle = 3,
    maxRightAngle = 3,
    angleLimitsLinked = true,
    overLimitAction = "review",
    adjustedPhotoAction = "skip",
    tiltSource = "inCameraData",
    photoDisplayMode = "minimizeSwitching",
    processedQuickCollectionAction = "keep",
    processedFlagAction = "keep",
    processedColorLabelAction = "keep",
    skippedQuickCollectionAction = "keep",
    skippedFlagAction = "keep",
    skippedColorLabelAction = "keep",
  }
  for k in pairs(o) do if saved[k] ~= nil then o[k] = saved[k] end end
  -- Unequal or invalid limits cannot be linked; leave both values editable.
  local left, right = P.normalizeAngleLimit(o.maxLeftAngle), P.normalizeAngleLimit(o.maxRightAngle)
  o.angleLimitsLinked = saved.angleLimitsLinked ~= false and left ~= nil and left == right
  return o
end
function P.normalizeAngleLimit(value)
  local v = tonumber(value)
  if not v or v ~= v or v < 0 or v > 45 then return nil end
  return math.floor(v * 10 + 0.5) / 10
end
function P.validate(o)
  for _, k in ipairs({"maxLeftAngle", "maxRightAngle"}) do
    local normalized = P.normalizeAngleLimit(o[k])
    if not normalized then return nil, LOC("$$$/BatchAutoStraighten/Text009=Enter a number from 0 to 45 for each angle limit.") end
    o[k] = normalized
  end
  o.angleLimitsLinked = o.angleLimitsLinked ~= false and o.maxLeftAngle == o.maxRightAngle
  local collectionActions={keep=true,add=true,remove=true}
  local flags={keep=true,pick=true,reject=true,clear=true}
  local colorLabels={keep=true,red=true,yellow=true,green=true,blue=true,purple=true,none=true}
  local allowed = {
    sameNameMode={individual=true,matchRendered=true,matchRaw=true},
    overLimitAction={skip=true,review=true},
    adjustedPhotoAction={skip=true,reset=true},
    tiltSource={inCameraData=true,imageAnalysis=true},
    photoDisplayMode={minimizeSwitching=true,openEachPhoto=true},
    processedQuickCollectionAction=collectionActions,
    processedFlagAction=flags,
    processedColorLabelAction=colorLabels,
    skippedQuickCollectionAction=collectionActions,
    skippedFlagAction=flags,
    skippedColorLabelAction=colorLabels,
  }
  for k, values in pairs(allowed) do if not values[o[k]] then return nil, LOC("$$$/BatchAutoStraighten/Text011=Select a valid option: ") .. k end end
  return o
end
-- Lightroom 15.5 returns "gray" for an unlabelled photo on macOS.
function P.normalizedLabel(value)
  return value == "gray" and "none" or value
end
function P.exceeds(o, target)
  return target < -o.maxLeftAngle - 1e-6 or target > o.maxRightAngle + 1e-6
end
function P.hasAngle(settings)
  return type(settings) == "table" and type(settings.CropAngle) == "number" and math.abs(settings.CropAngle) > 1e-6
end
return P
