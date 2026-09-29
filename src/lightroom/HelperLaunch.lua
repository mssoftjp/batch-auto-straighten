local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
--[[
  Launch the selected helper once per photo. JSON files are the API, not stdout.
  LrTasks.execute is yield-safe. Both helpers enforce their own process bound.
]]

local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

local HelperLaunch = {}

local function shellQuote(path)
  return "'" .. string.gsub(tostring(path), "'", "'\\''") .. "'"
end

function HelperLaunch.blockedMessage()
  return LOC("$$$/BatchAutoStraighten/HelperBlocked=A bundled tool could not run. macOS may have blocked it. Connect to the internet and retry with the latest signed, notarized release. If it still fails, check System Settings → Privacy & Security.")
end

function HelperLaunch.isBlockedStatus(status)
  return status == 9 or status == 126 or status == 137
end

function HelperLaunch.isBlockedError(err)
  return err == HelperLaunch.blockedMessage()
end

local function binaryPath()
  return LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, "bin"), "horizon-helper")
end

function HelperLaunch.run(photoId, imagePath, outputPath, originalPath, tiltSource)
  local usesImageAnalysis = tiltSource == "imageAnalysis"
  local bin = usesImageAnalysis and LrPathUtils.child(_PLUGIN.path, "bin/image-analysis-helper") or binaryPath()
  if not LrFileUtils.exists(bin) then
    if usesImageAnalysis then return false, LOC("$$$/BatchAutoStraighten/ImageAnalysisMissing=The bundled image-analysis tool is missing. Reinstall the plug-in from the official GitHub Releases page.") end
    return false, LOC("$$$/BatchAutoStraighten/Text096=The bundled camera-level tool is missing. Reinstall the plug-in from the official GitHub Releases page.")
  end
  if LrFileUtils.exists(outputPath) then
    LrFileUtils.delete(outputPath)
  end
  local extra = ""
  if not usesImageAnalysis and type(originalPath) == "string" and originalPath ~= "" then
    extra = " --original " .. shellQuote(originalPath)
  end
  local cmd = string.format(
    "%s --id %s --image %s --output %s%s",
    shellQuote(bin),
    shellQuote(photoId),
    shellQuote(imagePath),
    shellQuote(outputPath),
    extra
  )
  local status = LrTasks.execute(cmd)
  if HelperLaunch.isBlockedStatus(status) then
    return false, HelperLaunch.blockedMessage()
  end
  if status ~= 0 then
    return false, "helper exit " .. tostring(status)
  end
  if not LrFileUtils.exists(outputPath) then
    return false, "helper produced no output"
  end
  return true
end

function HelperLaunch.preview(imagePath, outputPath, degrees)
  if not LrFileUtils.exists(binaryPath()) then return false end
  if LrFileUtils.exists(outputPath) then LrFileUtils.delete(outputPath) end
  local cmd = string.format("%s --id preview --image %s --output %s --preview-degrees %s",
    shellQuote(binaryPath()),shellQuote(imagePath),shellQuote(outputPath),shellQuote(string.format("%.10f",degrees)))
  return LrTasks.execute(cmd) == 0 and LrFileUtils.exists(outputPath) ~= false and LrFileUtils.exists(outputPath) ~= nil
end

return HelperLaunch
