local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
-- Queue and verify flags, color labels and Quick Collection changes.
local LrTasks = import "LrTasks"
local QuickCollection = dofile(_PLUGIN.path .. "/QuickCollection.lua")
local RunPolicy = dofile(_PLUGIN.path .. "/RunPolicy.lua")
local M = {}

local markReasons = { angle_limit=true, review_skipped=true, existing_angle=true,
  no_horizon=true, reference_no_horizon=true, reference_excluded=true, angle_outside_sdk=true }
local flagValues = {pick=1, reject=-1, clear=0}

-- Name each applied mark so results show what changed, in a fixed order.
local function describe(target)
  local flags = {pick=LOC("$$$/BatchAutoStraighten/Text066=Pick"), reject=LOC("$$$/BatchAutoStraighten/Text067=Reject")}
  local colors = {red=LOC("$$$/BatchAutoStraighten/Text070=Red"), yellow=LOC("$$$/BatchAutoStraighten/Text071=Yellow"),
    green=LOC("$$$/BatchAutoStraighten/Text072=Green"), blue=LOC("$$$/BatchAutoStraighten/Text073=Blue"),
    purple=LOC("$$$/BatchAutoStraighten/Text074=Purple")}
  local parts = {}
  if target.flagAction == "clear" then
    parts[#parts+1] = LOC("$$$/BatchAutoStraighten/MarkFlagCleared=Flag cleared")
  elseif flags[target.flagAction] then
    parts[#parts+1] = string.format(LOC("$$$/BatchAutoStraighten/MarkFlag=Flag: %s"), flags[target.flagAction])
  end
  if target.colorLabelAction == "none" then
    parts[#parts+1] = LOC("$$$/BatchAutoStraighten/MarkColorLabelCleared=Color label cleared")
  elseif colors[target.colorLabelAction] then
    parts[#parts+1] = string.format(LOC("$$$/BatchAutoStraighten/MarkColorLabel=Color label: %s"), colors[target.colorLabelAction])
  end
  if target.quickCollectionAction == "add" then
    parts[#parts+1] = LOC("$$$/BatchAutoStraighten/MarkQuickAdded=Added to Quick Collection")
  elseif target.quickCollectionAction == "remove" then
    parts[#parts+1] = LOC("$$$/BatchAutoStraighten/MarkQuickRemoved=Removed from Quick Collection")
  end
  return table.concat(parts, LOC("$$$/BatchAutoStraighten/MarkSeparator=, "))
end

function M.new(catalog, options)
  local self = {}
  local marks = {}
  local quickCollection, quickBefore, quickError
  if options.skippedQuickCollectionAction ~= "keep" or options.processedQuickCollectionAction ~= "keep" then
    local ok, err = LrTasks.pcall(function()
      quickCollection = QuickCollection.get(catalog)
      quickBefore = QuickCollection.members(quickCollection)
    end)
    if not ok then quickCollection=nil; quickError=tostring(err) end
  end

  function self:queue(photo, row)
    local status, reason = row.status, row.reason
    local target
    if status == "applied" or status == "noop" then
      target={flagAction=options.processedFlagAction,colorLabelAction=options.processedColorLabelAction,
        quickCollectionAction=options.processedQuickCollectionAction}
    elseif status == "skip" and markReasons[reason] then
      target={flagAction=options.skippedFlagAction,colorLabelAction=options.skippedColorLabelAction,
        quickCollectionAction=options.skippedQuickCollectionAction}
    end
    if photo and target and (target.flagAction ~= "keep" or target.colorLabelAction ~= "keep"
      or target.quickCollectionAction ~= "keep") then
      marks[#marks+1] = {photo=photo,row=row,target=target,
        originalFlag=photo:getRawMetadata("pickStatus"),
        originalColorLabel=photo:getRawMetadata("colorNameForLabel"),
        wasInQuickCollection=quickBefore and quickBefore[photo.localIdentifier] == true}
    end
  end

  local nextMark=1
  function self:pending()
    while marks[nextMark] and marks[nextMark].attempted do nextMark=nextMark+1 end
    local pending={}
    for i=nextMark,#marks do pending[#pending+1]=marks[i] end
    return pending
  end

  function self:save(markScopeOwned)
    local pending=self:pending()
    if #pending==0 then return end
    -- These rows have finished saving (or were explicitly skipped). A stop
    -- request ends new photo work, but must retain their requested marks.
    local markOk, markErr = LrTasks.pcall(function()
      return catalog:withWriteAccessDo(LOC("$$$/BatchAutoStraighten/Text049=Batch Auto Straighten: Photo Marks"), function()
        if not markScopeOwned() then error("selection_changed") end
        local quickCurrent = quickCollection and QuickCollection.members(quickCollection) or {}
        local startedMarks=false
        for _, m in ipairs(pending) do
          local p,t = m.photo,m.target
          if t.quickCollectionAction ~= "keep" and not quickCollection then
            m.row.mark = LOC("$$$/BatchAutoStraighten/Text050=Could not set marks: ") .. tostring(quickError)
          elseif (t.flagAction == "keep" or p:getRawMetadata("pickStatus") == m.originalFlag)
            and (t.colorLabelAction == "keep" or p:getRawMetadata("colorNameForLabel") == m.originalColorLabel)
            and (t.quickCollectionAction == "keep"
              or (quickCurrent[p.localIdentifier] == true) == m.wasInQuickCollection) then
            if not startedMarks and not markScopeOwned() then error("selection_changed") end
            startedMarks=true
            if t.flagAction ~= "keep" then p:setRawMetadata("pickStatus", flagValues[t.flagAction]) end
            if t.colorLabelAction ~= "keep" then p:setRawMetadata("colorNameForLabel", t.colorLabelAction) end
            if t.quickCollectionAction == "add" then quickCollection:addPhotos({p})
            elseif t.quickCollectionAction == "remove" then quickCollection:removePhotos({p}) end
            -- Name the marks only after readback confirms them below.
            m.row.mark = LOC("$$$/BatchAutoStraighten/Text053=Could not verify saved marks")
            m.written = true
          else m.row.mark = LOC("$$$/BatchAutoStraighten/Text052=Marks not set: conflicting changes") end
        end
      end, {timeout=5})
    end)
    local quickAfter
    if quickCollection then
      local ok, value = LrTasks.pcall(function() return QuickCollection.members(quickCollection) end)
      if ok then quickAfter=value end
    end
    for _, m in ipairs(pending) do
      m.attempted=true
      local p,t = m.photo,m.target
      if m.written then
        if (t.flagAction ~= "keep" and p:getRawMetadata("pickStatus") ~= flagValues[t.flagAction])
          or (t.colorLabelAction ~= "keep"
            and RunPolicy.normalizedLabel(p:getRawMetadata("colorNameForLabel")) ~= t.colorLabelAction)
          or (t.quickCollectionAction ~= "keep"
            and (not quickAfter or (quickAfter[p.localIdentifier] == true) ~= (t.quickCollectionAction == "add"))) then
          m.row.mark = LOC("$$$/BatchAutoStraighten/Text053=Could not verify saved marks")
        else
          m.row.mark = describe(t)
        end
      elseif not markOk or markErr ~= "executed" then
        m.row.mark = LOC("$$$/BatchAutoStraighten/Text050=Could not set marks: ") .. tostring(markErr)
      elseif not m.row.mark then m.row.mark = LOC("$$$/BatchAutoStraighten/Text054=Marks not verified") end
    end
  end

  function self:hasEntries()
    return #marks > 0
  end

  function self:discardPending()
    for _, mark in ipairs(self:pending()) do
      mark.attempted = true
      mark.row.mark = LOC("$$$/BatchAutoStraighten/Text048=Marks not set: selection changed or save unconfirmed")
    end
  end

  return self
end

return M
