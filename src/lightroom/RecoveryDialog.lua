local LOC = dofile(_PLUGIN.path .. '/Localization.lua')
local Tasks = import 'LrTasks'
local Date = import 'LrDate'
local View = import 'LrView'
local AppView = import 'LrApplicationView'
local Dialogs = import 'LrDialogs'
local Math = dofile(_PLUGIN.path .. '/HorizonMath.lua')
local M={}

function M.show(record, canRestore, missing, relocated)
  local f=View.osFactory()
  local choice='review'
  local body={spacing=12,
    f:static_text{title=record and LOC("$$$/BatchAutoStraighten/RecoveryBody=The saved crop and angle could not be verified. Review this photo before starting another batch.")
      or LOC("$$$/BatchAutoStraighten/RecoveryUnreadable=The previous processing record could not be read. Review the last photo you processed."),width=480,height_in_lines=3},
    f:static_text{title=record and record.filename or '',width=480,height_in_lines=2,font='<system/bold>'},
  }
  if missing and record then body[#body+1]=f:static_text{title=LOC("$$$/BatchAutoStraighten/RecoveryMissing=This photo could not be found in the current catalog."),width=480} end
  if relocated then body[#body+1]=f:static_text{title=LOC("$$$/BatchAutoStraighten/RecoveryRelocated=This record refers to a catalog at another location. Check whether the catalog was moved or renamed. Keep Current Edits dismisses this notice and preserves the original record.") .. "\n" .. record.catalog,width=480,height_in_lines=5} end
  local buttons={spacing=10}
  buttons[#buttons+1]=f:push_button{title=LOC("$$$/BatchAutoStraighten/RecoveryKeep=Keep Current Edits"),
    tooltip=LOC("$$$/BatchAutoStraighten/RecoveryKeepTip=Keep the current edits and dismiss this notice."),action=function(button)
    choice='keep';Dialogs.stopModalWithResult(button,'ok')
  end}
  if canRestore then buttons[#buttons+1]=f:push_button{title=LOC("$$$/BatchAutoStraighten/RecoveryRestore=Restore Crop and Angle"),
    tooltip=LOC("$$$/BatchAutoStraighten/RecoveryRestoreTip=Restore the crop and angle saved before the interrupted adjustment."),action=function(button)
    choice='restore';Dialogs.stopModalWithResult(button,'ok')
  end} end
  body[#body+1]=f:row(buttons)
  body[#body+1]=f:static_text{title=LOC("$$$/BatchAutoStraighten/RecoveryNextRun=When you finish reviewing, open Batch Auto Straighten again to start another batch."),width=480,height_in_lines=2}
  local response=Dialogs.presentModalDialog{title=LOC("$$$/BatchAutoStraighten/RecoveryTitle=Review Previous Adjustment"),
    contents=f:column(body),actionVerb=missing and LOC("$$$/BatchAutoStraighten/Text151=Close") or LOC("$$$/BatchAutoStraighten/RecoveryReview=Show Photo"),
    cancelVerb=LOC("$$$/BatchAutoStraighten/Text151=Close")}
  return response=='ok' and choice or 'close'
end

-- Returns true only for a quietly reconciled checkpoint. A human recovery
-- choice always ends this invocation; it never silently starts another batch.
local function check(catalog, checkpoint)
  local r=not checkpoint.unreadable and checkpoint.record or nil
  if not checkpoint.unreadable and (not r or r.state=='clear') then return true end
  local originalModule=AppView.getCurrentModuleName()
  local photo=r and catalog:findPhotoByUuid(r.uuid) or nil
  local current,classification
  if photo then
    AppView.switchToModule('library')
    Tasks.sleep(.25)
    current=photo:getDevelopSettings();Tasks.sleep(.25)
    local second=photo:getDevelopSettings()
    classification=Math.tablesEqual(current,second) and checkpoint:classify(second) or 'changing'
    current=second
  end
  if not checkpoint.relocated and (classification=='unchanged' or classification=='applied') then
    checkpoint:clear()
    if originalModule then AppView.switchToModule(originalModule) end
    return true
  end
  local restore=not checkpoint.relocated and classification=='reset' and checkpoint:restoreValues() or nil
  local choice=M.show(r,restore~=nil,not photo,checkpoint.relocated and r~=nil)
  if choice=='review' and photo then
    catalog:setSelectedPhotos(photo,{photo})
    Tasks.sleep(.25)
    -- Lightroom can ignore selection outside the active source/filter. Never
    -- open Develop on another photo and imply that it is the pending one.
    if catalog:getTargetPhoto()~=photo then
      error('recovery photo selection failed')
    end
    AppView.switchToModule('develop')
    return false
  end
  if choice=='keep' then
    -- Acknowledge only the state that was shown, never a concurrent edit.
    if not photo or Math.tablesEqual(current,photo:getDevelopSettings()) then checkpoint:clear() end
  elseif choice=='restore' and restore then
    local status=catalog:withWriteAccessDo(LOC("$$$/BatchAutoStraighten/RecoveryRestore=Restore Crop and Angle"),function()
      if not Math.tablesEqual(current,photo:getDevelopSettings()) then error('recovery settings changed') end
      photo:applyDevelopSettings(restore,LOC("$$$/BatchAutoStraighten/RecoveryRestore=Restore Crop and Angle"))
    end,{timeout=5})
    assert(status=='executed','recovery save failed')
    local deadline=Date.currentTime()+5
    local previous
    local restored=false
    while Date.currentTime()<deadline do
      local settings=photo:getDevelopSettings()
      if checkpoint:classify(settings)=='unchanged' and previous and Math.tablesEqual(previous,settings) then restored=true;break end
      previous=settings;Tasks.sleep(.25)
    end
    if restored then checkpoint:clear()
    else Dialogs.message(LOC("$$$/BatchAutoStraighten/RecoveryTitle=Review Previous Adjustment"),LOC("$$$/BatchAutoStraighten/RecoveryStillUnconfirmed=The saved crop and angle could not be verified. Check this photo in the Develop module.")) end
  end
  if originalModule then AppView.switchToModule(originalModule) end
  return false
end
function M.check(catalog, checkpoint)
  local originalModule=AppView.getCurrentModuleName()
  local ok,result=Tasks.pcall(function()return check(catalog,checkpoint)end)
  if ok then return result end
  if originalModule then Tasks.pcall(function()AppView.switchToModule(originalModule)end) end
  Dialogs.message(LOC("$$$/BatchAutoStraighten/RecoveryTitle=Review Previous Adjustment"),
    LOC("$$$/BatchAutoStraighten/RecoveryStillUnconfirmed=The saved crop and angle could not be verified. Check this photo in the Develop module."))
  return false
end
return M
