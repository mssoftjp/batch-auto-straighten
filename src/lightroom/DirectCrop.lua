-- Numeric crop frame for a centered, original-aspect straighten.
-- CropLeft/Top and CropRight/Bottom describe opposite rotated corners, not
-- an axis-aligned bounding box. Angle-only writes do not preserve aspect.
local M = {}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function near(a,b) return finite(a) and math.abs(a-b)<1e-5 end
function M.context(photo, settings, reset)
  if type(photo.applyDevelopSettings)~='function' or type(settings)~='table' then return nil,'unsupported_sdk' end
  if settings.CropConstrainAspectRatio==false then return nil,'unlocked_aspect' end
  if settings.orientation and settings.orientation~='AB' then return nil,'orientation' end
  for _,key in ipairs({'PerspectiveVertical','PerspectiveHorizontal','PerspectiveRotate','PerspectiveAspect',
    'PerspectiveX','PerspectiveY','PerspectiveUpright','LensManualDistortionAmount'}) do
    if settings[key]~=nil and not near(settings[key],0) then return nil,'transform' end
  end
  if settings.PerspectiveScale~=nil and not near(settings.PerspectiveScale,100) then return nil,'transform' end
  if settings.CropConstrainToWarp~=nil and settings.CropConstrainToWarp~=0 and settings.CropConstrainToWarp~=false then return nil,'warp' end
  if not reset and not (near(settings.CropAngle,0) and near(settings.CropLeft,0)
    and near(settings.CropTop,0) and near(settings.CropRight,1) and near(settings.CropBottom,1)) then return nil,'manual_crop' end
  local d=photo:getRawMetadata('dimensions')
  if type(d)~='table' or not finite(d.width) or not finite(d.height) or d.width<=0 or d.height<=0 then return nil,'dimensions' end
  return {width=d.width,height=d.height}
end
function M.roundAngle(angle)
  if not finite(angle) then return nil end
  local sign=angle<0 and -1 or 1
  return sign*math.floor(math.abs(angle)*100+.5)/100
end
function M.frame(context, angle)
  angle=M.roundAngle(angle)
  if not angle or math.abs(angle)>45 then return nil end
  local r=context.width/context.height
  local a=math.rad(angle);local c,s=math.cos(a),math.sin(a)
  local scale=math.min(1/(c+math.abs(s)/r),1/(c+math.abs(s)*r))
  local dx,dy=scale*(c+s/r),scale*(c-s*r)
  -- Lightroom accepts signed opposite-corner spans for larger angles too.
  return {CropAngle=-angle,CropLeft=(1-dx)/2,CropRight=(1+dx)/2,
    CropTop=(1-dy)/2,CropBottom=(1+dy)/2,CropConstrainAspectRatio=true}
end
function M.matches(settings, frame)
  if type(settings)~='table' then return false end
  for key,value in pairs(frame) do
    if type(value)=='number' then
      if not finite(settings[key]) or math.abs(settings[key]-value)>2e-6 then return false end
    elseif settings[key]~=value then return false end
  end
  return true
end
return M
