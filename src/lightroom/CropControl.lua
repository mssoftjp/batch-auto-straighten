-- Own Lightroom selection/module checks, crop-tool readiness and save readback.
local LrApplicationView = import "LrApplicationView"
local LrDate = import "LrDate"
local LrDevelopController = import "LrDevelopController"
local LrTasks = import "LrTasks"
local HorizonMath = dofile(_PLUGIN.path .. "/HorizonMath.lua")

local M = {}
M.timing = {library=8, develop=8, readback=5, stable=0.25, retryDelay=0.35}
local Timing = M.timing

local function samePhotoSeq(a, b)
  if a == nil or b == nil then
    return a == b
  end
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

function M.waitUntil(timeoutSec, predicate)
  local deadline = LrDate.currentTime() + timeoutSec
  while LrDate.currentTime() < deadline do
    if predicate() then
      return true
    end
    LrTasks.sleep(0.05)
  end
  return false
end

function M.stillIsolated(catalog, photo)
  if catalog:getTargetPhoto() ~= photo then
    return false
  end
  local selected = catalog:getTargetPhotos() or {}
  return #selected == 1 and selected[1] == photo
end

function M.selectionIs(catalog, active, selected)
  return catalog:getTargetPhoto() == active and samePhotoSeq(catalog:getTargetPhotos(), selected)
end

function M.currentModule()
  return LrApplicationView.getCurrentModuleName()
end

function M.readStraighten()
  local ok, value = LrTasks.pcall(function()
    return LrDevelopController.getValue("straightenAngle")
  end)
  if not ok then
    return nil
  end
  return value
end

local function readSelectedTool()
  local ok, value = LrTasks.pcall(function()
    return LrDevelopController.getSelectedTool()
  end)
  if not ok then
    return nil
  end
  return value
end

function M.libraryOwned(catalog, photo)
  return M.currentModule() == "library" and M.stillIsolated(catalog, photo)
end

local function developOwned(catalog, photo)
  return M.currentModule() == "develop" and M.stillIsolated(catalog, photo)
end

function M.developCropOwned(catalog, photo)
  return developOwned(catalog, photo) and readSelectedTool() == "crop"
end

function M.isolateInLibrary(catalog, photo, priorActive, priorSelected, onSelect)
  -- Finish leaving Develop on the previous photo before loading the next one.
  -- Selecting a follower in Develop starts a second develop-load transition
  -- immediately before the library switch and its settings conflict check.
  if M.currentModule() ~= "library" then
    LrApplicationView.switchToModule("library")
  end
  if M.currentModule() ~= "library" or not M.selectionIs(catalog, priorActive, priorSelected) then
    return false
  end
  if onSelect then onSelect(photo) end
  catalog:setSelectedPhotos(photo, { photo })
  return M.waitUntil(Timing.library, function()
    return M.libraryOwned(catalog, photo)
  end)
end

function M.enterDevelopCrop(catalog, photo)
  if M.currentModule() ~= "develop" then
    LrApplicationView.switchToModule("develop")
  end
  local loaded = M.waitUntil(Timing.develop, function()
    if M.currentModule() ~= "develop" or not M.stillIsolated(catalog, photo) then
      return false
    end
    return HorizonMath.isFiniteNumber(M.readStraighten())
  end)
  if not loaded then
    return false
  end
  if not developOwned(catalog, photo) then
    return false
  end
  if readSelectedTool() ~= "crop" then
    LrDevelopController.selectTool("crop")
  end
  return M.waitUntil(Timing.develop, function()
    return M.developCropOwned(catalog, photo) and HorizonMath.isFiniteNumber(M.readStraighten())
  end)
end

function M.snapshotDevelop(photo)
  return HorizonMath.normalizeDevelopSettings(photo:getDevelopSettings() or {})
end

function M.waitReadback(catalog, photo, target, eps, before, isCanceled, retryWrite, canRetry)
  if not HorizonMath.isFiniteNumber(eps) then
    eps = HorizonMath.READBACK_EPS
  end
  local deadline = LrDate.currentTime() + Timing.readback
  local observed = {}
  local stableSince, stableSamples, previous = nil, 0, nil
  local baseline = before and HorizonMath.isFiniteNumber(before.CropAngle) and -before.CropAngle or nil
  -- Never let the unchanged baseline satisfy a requested correction, even
  -- when the correction is smaller than the usual SDK readback tolerance.
  if HorizonMath.isFiniteNumber(baseline) and math.abs(target-baseline)>1e-6 then
    eps=math.min(eps,math.abs(target-baseline)/2)
  end
  local retryAfter = LrDate.currentTime() + Timing.retryDelay
  local retried = false
  while LrDate.currentTime() < deadline do
    if isCanceled and isCanceled() then return false, "canceled", observed end
    if M.currentModule() ~= "develop" then
      return false, "module_changed", observed
    end
    if not M.stillIsolated(catalog, photo) then
      return false, "selection_changed", observed
    end
    if readSelectedTool() ~= "crop" then
      return false, "tool_changed", observed
    end
    local value = M.readStraighten()
    observed.ui = value
    if value == nil then
      -- The SDK can transiently return nil while the Crop control refreshes.
      -- Retry only inside the existing bounded verification window; a later
      -- success must still satisfy the stable UI and catalog checks below.
      stableSince, stableSamples, previous = nil, 0, nil
      while value == nil and LrDate.currentTime() < deadline do
        observed.readFailures = (observed.readFailures or 0) + 1
        LrTasks.sleep(0.05)
        if isCanceled and isCanceled() then return false, "canceled", observed end
        if M.currentModule() ~= "develop" then return false, "module_changed", observed end
        if not M.stillIsolated(catalog, photo) then return false, "selection_changed", observed end
        if readSelectedTool() ~= "crop" then return false, "tool_changed", observed end
        value = M.readStraighten()
        observed.ui = value
      end
      if value == nil then return false, "read_failed", observed end
    end
    -- UI values can update before the photo is committed. CropAngle is read-only
    -- here and has the opposite sign from the Develop straightenAngle control.
    observed.settings = M.snapshotDevelop(photo)
    local crop = observed.settings.CropAngle
    observed.saved = HorizonMath.isFiniteNumber(crop) and -crop or nil
    if before and not HorizonMath.nonCropSettingsEqual(before, observed.settings) then
      return false, "settings_changed_during_save", observed
    end
    -- A newly selected Crop tool may report a readable value before it accepts
    -- the first SDK write. Retry once only while both UI and saved values are
    -- still the exact pre-write value. Never chase rounding or a changed value.
    if retryWrite and (not canRetry or canRetry()) and not retried and HorizonMath.isFiniteNumber(baseline)
      and math.abs(target - baseline) > eps
      and HorizonMath.isFiniteNumber(value) and math.abs(value - baseline) <= eps
      and HorizonMath.isFiniteNumber(observed.saved) and math.abs(observed.saved - baseline) <= eps
      and LrDate.currentTime() >= retryAfter
    then
      local retryOk, retryResult = LrTasks.pcall(retryWrite)
      if not retryOk or retryResult ~= true then
        observed.writeAttempts = 2
        return false, "write_retry_failed", observed
      end
      retried = true
      observed.writeAttempts = 2
      stableSince, stableSamples, previous = nil, 0, nil
    end
    if HorizonMath.isFiniteNumber(value) and math.abs(value - target) <= eps
      and HorizonMath.isFiniteNumber(observed.saved) and math.abs(observed.saved - target) <= eps
    then
      -- CropAngle can precede Lightroom's crop-frame/aspect-lock save. Require
      -- a stable complete snapshot, not just the first matching angle, before
      -- declaring success or publishing this photo as a group reference.
      if previous and HorizonMath.tablesEqual(previous.settings, observed.settings)
        and HorizonMath.tablesEqual(previous.ui, value) then
        stableSamples = stableSamples + 1
      else
        stableSince, stableSamples = LrDate.currentTime(), 1
      end
      previous = {settings=observed.settings, ui=value}
      if stableSamples >= 3 and LrDate.currentTime() - stableSince >= Timing.stable
        and M.developCropOwned(catalog, photo) then
        return true, value, observed
      end
      if not M.stillIsolated(catalog, photo) then
        return false, "selection_changed", observed
      end
      if M.currentModule() ~= "develop" then return false, "module_changed", observed end
    else
      stableSince, stableSamples, previous = nil, 0, nil
    end
    LrTasks.sleep(0.05)
  end
  return false, "timeout", observed
end

return M
