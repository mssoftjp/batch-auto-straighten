local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
-- Validate bounded helper responses before any angle conversion or catalog write.
local json = dofile(_PLUGIN.path .. "/dkjson.lua")
local HorizonMath = dofile(_PLUGIN.path .. "/HorizonMath.lua")
local M = { SCHEMA = "batch-auto-straighten.horizon.v2" }

local VALID_KINDS = {
  horizon = true,
  none = true,
  error = true,
}

local function readFile(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read(65537)
  handle:close()
  return data
end

local function validateHelperPayload(payload, expectedId, tiltSource)
  if type(payload) ~= "table" then
    return nil, LOC("$$$/BatchAutoStraighten/Text036=Not a JSON object")
  end
  if payload.schema ~= M.SCHEMA then
    return nil, LOC("$$$/BatchAutoStraighten/Text037=Expected schema ") .. M.SCHEMA .. LOC("$$$/BatchAutoStraighten/Text038= was not found")
  end
  if payload.id ~= expectedId then
    return nil, LOC("$$$/BatchAutoStraighten/Text039=Invalid result id")
  end
  if type(payload.kind) ~= "string" or not VALID_KINDS[payload.kind] then
    return nil, LOC("$$$/BatchAutoStraighten/Text040=Invalid kind: ") .. tostring(payload.kind)
  end
  if payload.source ~= (tiltSource == "inCameraData" and "camera_roll" or "image_analysis") then
    return nil, "unexpected_helper_source"
  end
  if payload.source == "image_analysis" then
    if payload.kind ~= "error" and (type(payload.model_id) ~= "string" or payload.model_id == "") then
      return nil, LOC("$$$/BatchAutoStraighten/SourceMismatch=Analysis method does not match the selected method")
    end
  end
  if payload.kind == "horizon" then
    if payload.source == "image_analysis" then
      if not HorizonMath.isFiniteNumber(payload.correction_degrees) or math.abs(payload.correction_degrees) > 15 then
        return nil, LOC("$$$/BatchAutoStraighten/InvalidImageAnalysisAngle=Invalid image-analysis correction angle")
      end
      payload.residual_degrees = -payload.correction_degrees
    elseif not HorizonMath.isFiniteNumber(payload.roll_degrees) or math.abs(payload.roll_degrees)>180 or type(payload.make)~="string" then
      return nil, LOC("$$$/BatchAutoStraighten/InvalidCameraAngle=Invalid camera correction angle")
    end
  end
  return payload, nil
end

-- Validate the complete wire response before conversion or fallback decisions.
function M.decode(path, id, tiltSource)
  local raw=readFile(path) or ""
  if #raw>65536 then return nil,"helper_response_too_large" end
  local payload,position,err=json.decode(raw)
  if err or not position or raw:sub(position):find("%S") then return nil,err or "trailing_json_data" end
  return validateHelperPayload(payload,id,tiltSource)
end

return M
