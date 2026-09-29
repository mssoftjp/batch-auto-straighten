--[[
  Basic eligibility: still photos with an available original.
  RunPolicy controls how existing adjustments are handled.
]]

local LrFileUtils = import "LrFileUtils"

local SkipRules = {}

function SkipRules.isVideo(photo)
  if photo.getRawMetadata then
    local isVideo = photo:getRawMetadata("isVideo")
    if isVideo then
      return true
    end
    local format = photo:getRawMetadata("fileFormat")
    if format == "VIDEO" then
      return true
    end
  end
  return false
end

function SkipRules.missingOriginal(photo)
  if not photo.getRawMetadata then
    return true
  end
  local path = photo:getRawMetadata("path")
  if type(path) ~= "string" or path == "" then
    return true
  end
  local exists = LrFileUtils.exists(path)
  return exists ~= true and exists ~= "file"
end

return SkipRules
