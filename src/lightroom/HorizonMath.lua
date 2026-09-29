--[[
  Angle math shared by image analysis, camera metadata and crop writes.
  Residual degrees are the remaining CCW tilt of an already-upright preview (Y-up).
  UI target: straightenAngle_target = current - residualDegrees.
]]

local HorizonMath = {}

HorizonMath.IMAGE_ANALYSIS_DEADBAND_DEG = 0.05
HorizonMath.IN_CAMERA_DATA_DEADBAND_DEG = 0.01
HorizonMath.READBACK_EPS = 0.05
HorizonMath.VALUE_EPS = 0.01 + 1e-6 -- Shared angles allow one UI step plus float noise.
HorizonMath.DEFAULT_MIN = -45.0
HorizonMath.DEFAULT_MAX = 45.0

function HorizonMath.isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Camera roll describes the original image, not a transformed preview.
function HorizonMath.inCameraDataGeometrySafe(settings)
  if type(settings)~='table' then return false end
  for _,key in ipairs({'PerspectiveVertical','PerspectiveHorizontal','PerspectiveRotate','PerspectiveAspect',
    'PerspectiveX','PerspectiveY','PerspectiveUpright','LensManualDistortionAmount'}) do
    if settings[key]~=nil and settings[key]~=0 then return false end
  end
  if settings.PerspectiveScale~=nil and settings.PerspectiveScale~=100 then return false end
  if settings.CropConstrainToWarp~=nil and settings.CropConstrainToWarp~=false and settings.CropConstrainToWarp~=0 then return false end
  return true
end

function HorizonMath.targetStraighten(current, residualDegrees)
  return current - residualDegrees
end

-- User limits apply to the final angle in RunPolicy, not to this residual.
function HorizonMath.classifyResidual(residualDegrees, deadband)
  if not HorizonMath.isFiniteNumber(residualDegrees) then
    return "fail", "non_finite"
  end
  local absAngle = math.abs(residualDegrees)
  if absAngle < (deadband or HorizonMath.IMAGE_ANALYSIS_DEADBAND_DEG) then
    return "noop", "below_deadband"
  end
  return "apply", "applied"
end

-- Map a camera roll angle onto [-45, 45) from the nearest 0/±90/±180 axis.
function HorizonMath.wrapToCardinal(roll)
  if not HorizonMath.isFiniteNumber(roll) then
    return nil
  end
  local y = roll / 90.0
  y = y - math.floor(y + 0.5)
  local remainder = y * 90.0
  if math.abs(remainder) < 1e-12 then
    remainder = 0
  end
  return remainder
end

function HorizonMath.makerRollSign(make)
  local name = string.upper(tostring(make or ""))
  if string.find(name, "NIKON", 1, true) then
    return -1
  end
  return 1
end

function HorizonMath.rollIsUsable(roll, make)
  if not HorizonMath.isFiniteNumber(roll) then
    return false
  end
  local name = string.upper(tostring(make or ""))
  -- Some Fuji bodies store |roll| < 1° as 0. Treat 0 as missing.
  if math.abs(roll) < 1e-9 and (string.find(name, "FUJI", 1, true) ~= nil) then
    return false
  end
  return true
end

-- Desired final UI straightenAngle that levels a capture-time camera roll.
function HorizonMath.rollToUi(roll, make)
  if not HorizonMath.rollIsUsable(roll, make) then
    return nil
  end
  local wrapped = HorizonMath.wrapToCardinal(roll)
  if wrapped == nil then
    return nil
  end
  return wrapped * HorizonMath.makerRollSign(make)
end

-- Same residual contract: remaining tilt of the current preview.
function HorizonMath.residualFromRoll(roll, make, currentUi)
  local target = HorizonMath.rollToUi(roll, make)
  if target == nil then
    return nil
  end
  if not HorizonMath.isFiniteNumber(currentUi) then
    currentUi = 0
  end
  return currentUi - target
end

function HorizonMath.inAllowedRange(value, minv, maxv)
  if not HorizonMath.isFiniteNumber(value) then
    return false
  end
  if not HorizonMath.isFiniteNumber(minv) then
    minv = HorizonMath.DEFAULT_MIN
  end
  if not HorizonMath.isFiniteNumber(maxv) then
    maxv = HorizonMath.DEFAULT_MAX
  end
  return value >= minv and value <= maxv
end

local function tablesEqual(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    if type(a) == "number" and type(b) == "number" then
      return math.abs(a - b) <= 1e-4
    end
    return a == b
  end
  for key, value in pairs(a) do
    if not tablesEqual(value, b[key]) then
      return false
    end
  end
  for key, _ in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

HorizonMath.tablesEqual = tablesEqual

-- Develop materializes empty AILook defaults both here and in Look.Parameters,
-- and refreshes Look.Parameters.Version (the Camera Raw writer version).
-- This is not ProcessVersion: the rendering process, profile identity, amount,
-- curves and nonempty AI settings must all remain guarded. Never alter the
-- SDK's settings table or recursively ignore similarly named custom fields.
function HorizonMath.normalizeDevelopSettings(settings)
  local function empty(value) return type(value)=="table" and next(value)==nil end
  local function copy(value)
    local out={};for k,v in pairs(value) do out[k]=v end;return out
  end
  local normalized=settings
  if empty(settings.AILook) then
    normalized=copy(settings);normalized.AILook=nil
  end
  local look=settings.Look
  local parameters=type(look)=="table" and look.Parameters
  if type(parameters)=="table" and (empty(parameters.AILook) or type(parameters.Version)=="string") then
    if normalized==settings then normalized=copy(settings) end
    normalized.Look=copy(look)
    normalized.Look.Parameters=copy(parameters)
    if empty(parameters.AILook) then normalized.Look.Parameters.AILook=nil end
    if type(parameters.Version)=="string" then normalized.Look.Parameters.Version=nil end
  end
  return normalized
end

-- These are the only settings Lightroom may update as a consequence of our
-- native crop reset / straighten write. All other develop edits remain guarded
-- while waiting for the crop save to settle.
local nativeCropKeys = {
  CropAngle=true, CropLeft=true, CropTop=true, CropRight=true, CropBottom=true,
  CropConstrainAspectRatio=true,
}
function HorizonMath.nonCropSettingsEqual(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k,v in pairs(a) do
    if not nativeCropKeys[k] and not tablesEqual(v,b[k]) then return false end
  end
  for k,v in pairs(b) do
    if not nativeCropKeys[k] and not tablesEqual(v,a[k]) then return false end
  end
  return true
end

return HorizonMath
