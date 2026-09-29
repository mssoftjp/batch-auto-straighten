local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
--[[
  Per-photo tilt correction: JPEG preview -> selected helper -> straightenAngle.
  DirectCrop writes eligible frames in Library; other photos use Develop's crop tool.
  Each photo is analyzed independently, or same-folder stems share one final UI angle.
]]

local LrApplication = import "LrApplication"
local LrApplicationView = import "LrApplicationView"
local LrDate = import "LrDate"
local LrDevelopController = import "LrDevelopController"
local LrDialogs = import "LrDialogs"
local LrFileUtils = import "LrFileUtils"
local LrFunctionContext = import "LrFunctionContext"
local LrPathUtils = import "LrPathUtils"
local LrPrefs = import "LrPrefs"
local LrTasks = import "LrTasks"

local json = dofile(LrPathUtils.child(_PLUGIN.path, "dkjson.lua"))
local HorizonMath = dofile(LrPathUtils.child(_PLUGIN.path, "HorizonMath.lua"))
local SkipRules = dofile(LrPathUtils.child(_PLUGIN.path, "SkipRules.lua"))
local HelperLaunch = dofile(LrPathUtils.child(_PLUGIN.path, "HelperLaunch.lua"))
local GroupPlan = dofile(LrPathUtils.child(_PLUGIN.path, "GroupPlan.lua"))

local RunPolicy = dofile(LrPathUtils.child(_PLUGIN.path, "RunPolicy.lua"))
local DirectCrop = dofile(LrPathUtils.child(_PLUGIN.path, "DirectCrop.lua"))
local SaveCheckpoint = dofile(LrPathUtils.child(_PLUGIN.path, "SaveCheckpoint.lua"))
local RecoveryDialog = dofile(LrPathUtils.child(_PLUGIN.path, "RecoveryDialog.lua"))

local HelperProtocol = dofile(_PLUGIN.path .. "/HelperProtocol.lua")
local RunReport = dofile(_PLUGIN.path .. "/RunReport.lua")
local PhotoMarks = dofile(_PLUGIN.path .. "/PhotoMarks.lua")

local CropControl = dofile(_PLUGIN.path .. "/CropControl.lua")

local THUMB_SIZE = 1600
local PREVIEW_TIMEOUT = 20
local Timing = CropControl.timing
local STOP_SELECTION = LOC("$$$/BatchAutoStraighten/Text016=Stopped because the selection changed.")
local STOP_MODULE = LOC("$$$/BatchAutoStraighten/Text017=Stopped because the module changed.")
local STOP_SETTINGS = LOC("$$$/BatchAutoStraighten/Text018=Stopped because Develop settings changed after analysis.")
local STOP_ERROR = LOC("$$$/BatchAutoStraighten/Text019=Stopped due to an error.")

-- Menu scripts re-execute; locals do not persist across invocations.
if _G.BatchAutoStraightenShared == nil then
  _G.BatchAutoStraightenShared = { running = false }
end
local shared = _G.BatchAutoStraightenShared

local function copySeq(seq)
  local out = {}
  if not seq then
    return out
  end
  for i = 1, #seq do
    out[i] = seq[i]
  end
  return out
end

local function tempDir()
  local base = LrPathUtils.getStandardFilePath("temp") or "/tmp"
  local dir = LrPathUtils.child(
    base,
    "batch-auto-straighten-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
  )
  LrFileUtils.createAllDirectories(dir)
  if not LrFileUtils.exists(dir) then
    return nil
  end
  return dir
end

local function rmTree(dir)
  if dir and LrFileUtils.exists(dir) then
    LrFileUtils.delete(dir)
  end
end

local function photoId(photo)
  if not photo then
    return nil
  end
  if photo.getRawMetadata then
    local uuid = photo:getRawMetadata("uuid")
    if type(uuid) == "string" and uuid ~= "" then
      return uuid
    end
  end
  if photo.localIdentifier ~= nil then
    return tostring(photo.localIdentifier)
  end
  return tostring(photo)
end

local photoNames = {}
local function photoName(photo)
  if photoNames[photo] then return photoNames[photo] end
  if photo and photo.getFormattedMetadata then
    local name = photo:getFormattedMetadata("fileName")
    if type(name) == "string" and name ~= "" then
      local copyName = photo:getFormattedMetadata("copyName")
      if type(copyName) == "string" and copyName ~= "" then name = name .. " · " .. copyName end
      photoNames[photo]=name
      return name
    end
  end
  if photo and photo.getRawMetadata then
    local path = photo:getRawMetadata("path")
    if type(path) == "string" and path ~= "" then
      local _, _, _, leaf = GroupPlan.splitPath(path)
      if type(leaf) == "string" and leaf ~= "" then
        return leaf
      end
    end
  end
  return photoId(photo) or "?"
end

local function describePhoto(photo, origIndex)
  local path = ""
  local fileFormat = nil
  if photo and photo.getRawMetadata then
    local rawPath = photo:getRawMetadata("path")
    if type(rawPath) == "string" then
      path = rawPath
    end
    fileFormat = photo:getRawMetadata("fileFormat")
  end
  local _, _, ext, leaf = GroupPlan.splitPath(path)
  return {
    photo = photo,
    id = photoId(photo),
    path = path,
    fileFormat = fileFormat,
    isRaw = RunPolicy.isRaw(fileFormat, ext),
    ext = ext,
    leaf = leaf,
    origIndex = origIndex,
    isVideo = SkipRules.isVideo(photo),
    missingOriginal = SkipRules.missingOriginal(photo),
  }
end

local function waitFor(requests, timeoutSec, onPoll)
  local deadline = LrDate.currentTime() + timeoutSec
  while LrDate.currentTime() < deadline do
    if onPoll and onPoll()==false then
      for _,req in ipairs(requests) do req.done=true;req.ok=false;req.detail="canceled" end
      return false
    end
    local pending = 0
    for _, req in ipairs(requests) do
      if req.done ~= true then
        pending = pending + 1
      end
    end
    if pending == 0 then
      return true
    end
    LrTasks.sleep(0.05)
  end
  for _, req in ipairs(requests) do
    if req.done ~= true then
      req.done = true
      req.ok = false
      req.detail = "timeout"
    end
  end
  return false
end

local function requestPreview(photo, jpegPath)
  local slot = { done = false, ok = false, hold = nil, detail = nil }
  slot.hold = photo:requestJpegThumbnail(THUMB_SIZE, THUMB_SIZE, function(jpegData, err)
    if slot.done then
      return
    end
    slot.done = true
    if jpegData then
      local handle = io.open(jpegPath, "wb")
      if not handle then
        slot.ok = false
        slot.detail = "jpeg_write_open_failed"
      else
        local written = handle:write(jpegData)
        handle:close()
        if not written then
          slot.ok = false
          slot.detail = "jpeg_write_failed"
        else
          slot.ok = true
        end
      end
    elseif err ~= nil then
      slot.ok = false
      slot.detail = "callback_error"
      if type(err) == "string" then
        slot.callbackErr = err
      else
        slot.callbackErr = tostring(err)
      end
    else
      slot.ok = false
      slot.detail = "jpeg_missing"
    end
    jpegData = nil
  end)
  return slot
end

local function restoreSelection(catalog, active, selected)
  if not active or not selected or #selected == 0 then
    return false
  end
  catalog:setSelectedPhotos(active, selected)
  return true
end

local function rowHasId(rows, id)
  for _, row in ipairs(rows) do
    if row.id == id then
      return true
    end
  end
  return false
end

local function makeShareFail(photo, reason)
  local followerReason, followerStatus = "reference_failed", "fail"
  if reason == "no_horizon" then
    followerReason, followerStatus = "reference_no_horizon", "skip"
  elseif reason == "angle_limit" or reason == "review_skipped" or reason == "reference_excluded" or reason == "angle_outside_sdk" then
    followerReason, followerStatus = "reference_excluded", "skip"
  end
  return {
    ok = false,
    followerReason = followerReason,
    followerStatus = followerStatus,
    referenceName = photoName(photo),
    reference = photo,
  }
end

local showStartDialog = dofile(LrPathUtils.child(_PLUGIN.path, "StartDialog.lua"))

local ResultDialog = dofile(LrPathUtils.child(_PLUGIN.path, "ResultDialog.lua"))
local ReviewDialog = dofile(LrPathUtils.child(_PLUGIN.path, "ReviewDialog.lua"))

LrFunctionContext.postAsyncTaskWithContext("BatchAutoStraightenRun", function(taskContext)
  if WIN_ENV then
    LrDialogs.message(LOC("$$$/BatchAutoStraighten/Text042=Batch Auto Straighten requires an Apple silicon Mac with macOS 26 or later."))
    return
  end
  if shared.running then
    LrDialogs.message(LOC("$$$/BatchAutoStraighten/Text043=Batch Auto Straighten"), LOC("$$$/BatchAutoStraighten/Text044=A batch is already running. Wait for it to finish before starting another."))
    return
  end
  local lockToken = {}
  shared.running = lockToken

  local function releaseLock()
    if shared.running == lockToken then shared.running = false end
  end
  -- Release even if the task dies outside the guarded body; otherwise every
  -- later run reports "already running" until Lightroom restarts.
  taskContext:addCleanupHandler(releaseLock)

  local resultReport
  local progressOpened = false
  local bodyOk, bodyErr = LrTasks.pcall(function()
    local catalog = LrApplication.activeCatalog()
    local checkpoint=SaveCheckpoint.open(catalog)
    if not RecoveryDialog.check(catalog,checkpoint) then releaseLock();return end
    local photos = catalog:getTargetPhotos()
    local active = catalog:getTargetPhoto()
    if not active or not photos or #photos == 0 then
      releaseLock()
      LrDialogs.message(LOC("$$$/BatchAutoStraighten/Text045=Select at least one photo, then run Batch Auto Straighten again."))
      return
    end

    local initialPhotos = copySeq(photos)
    local initialActive = active
    local prefs = LrPrefs.prefsForPlugin()
    if type(prefs) ~= "table" then
      prefs = {}
    end
    local options = showStartDialog(#initialPhotos, prefs)
    if options == nil then
      releaseLock()
      return
    end

    local sameNameMode = options.sameNameMode
    LrFunctionContext.callWithContext("BatchAutoStraighten", function(context)
      local progress = LrDialogs.showModalProgressDialog({
        title = LOC("$$$/BatchAutoStraighten/Text001=Batch Auto Straighten"),
        caption = LOC("$$$/BatchAutoStraighten/Text046=Editing is unavailable during processing. Stopping keeps completed adjustments."),
        cannotCancel = false,
        width = 520,
        functionContext = context,
      })
      progressOpened = true
      local workDir = nil
      local finished = false
      local rows = {}
      local restored = false
      local isolatedPhoto = nil
      -- Last single-photo selection requested by the plug-in itself, kept even
      -- when a timed-out wait makes ownership checks blame the user.
      local pluginSelected = nil
      local directPhoto, directSettings

      local maybeChanged = false
      local saveInProgress = false
      local saveFields
      local owned = true
      local expectedActive = initialActive
      local expectedSelected = copySeq(initialPhotos)
      local initialModule = CropControl.currentModule()
      local expectedModule = initialModule
      local function applyOwned(photo)
        if directPhoto == photo then
          return CropControl.currentModule()=="library" and CropControl.selectionIs(catalog,expectedActive,expectedSelected)
        end
        return CropControl.developCropOwned(catalog,photo)
      end
      local jobs = {}
      local loopIndex = 1
      local stopTitle = nil
      local currentOrigIndex = nil
      local currentPhotoNumber = nil
      local currentRefName = nil

      local diagnostics = {schema="batch-auto-straighten.run.v2", started=os.time(), sameNameMode=sameNameMode,
        selected=#initialPhotos, photoDisplayMode=options.photoDisplayMode, settingsChecks={}, timings={}}
      local runStarted=LrDate.currentTime()
      local stageName,stagePhoto,stageStarted=nil,nil,runStarted
      local function recordSettingsCheck(before, after, photo, phase)
        local keys, changes = {}, {}
        for k in pairs(before or {}) do keys[k]=true end
        for k in pairs(after or {}) do keys[k]=true end
        for k in pairs(keys) do
          local a,b=(before or {})[k],(after or {})[k]
          if not HorizonMath.tablesEqual(a,b) then
            -- Keep changed field names and scalar values, not whole mask/profile
            -- payloads or images. The latest run is stored locally only.
            changes[#changes+1]={key=tostring(k), before=type(a)=="table" and "<table>" or a,
              after=type(b)=="table" and "<table>" or b}
          end
        end
        table.sort(changes,function(a,b) return a.key<b.key end)
        local check={photo=photoName(photo), id=photoId(photo), phase=phase,
          module=CropControl.currentModule(), changes=changes, recovered=false}
        diagnostics.settingsChecks[#diagnostics.settingsChecks+1]=check
        return check
      end
      local function settingsUnchanged(before, photo, phase)
        local after=CropControl.snapshotDevelop(photo)
        if HorizonMath.tablesEqual(before,after) then return true end
        local check=recordSettingsCheck(before,after,photo,phase)
        local deadline=LrDate.currentTime()+0.5
        local matches=0
        while LrDate.currentTime()<deadline do
          if progress:isCanceled() or CropControl.currentModule()~=expectedModule
            or not CropControl.selectionIs(catalog,expectedActive,expectedSelected) then return false end
          LrTasks.sleep(0.05)
          after=CropControl.snapshotDevelop(photo)
          if HorizonMath.tablesEqual(before,after) then matches=matches+1 else matches=0 end
          -- Accept only the original expected settings, never rebase a genuine
          -- edit. Two matching reads avoid trusting a single transitional read.
          if matches>=2 then check.recovered=true; return true end
        end
        return false
      end

      local markQueue = PhotoMarks.new(catalog, options)
      local function updateProgress(done)
        progress:setPortionComplete(done, #initialPhotos)
        local caption=string.format(LOC("$$$/BatchAutoStraighten/Text047=Photos: %d/%d · Editing is unavailable. Stopping keeps completed adjustments."),currentPhotoNumber or done,#initialPhotos)
        if progress:isCanceled() then
          caption=caption .. "\n" .. (saveInProgress and LOC("$$$/BatchAutoStraighten/StoppingSave=Stopping after the current photo is saved and checked.")
            or LOC("$$$/BatchAutoStraighten/Stopping=Stopping…"))
          -- Lightroom closes this modal on Cancel. Continue only the active
          -- save with ownership/settings guards; never reopen a second SDK
          -- progress modal (nested scopes can strand a completed dialog).
        elseif stageName then
          caption=caption .. "\n" .. stageName .. (stagePhoto and (" · "..stagePhoto) or "")
        end
        progress:setCaption(caption)
      end
      local function stage(name, photo)
        local now=LrDate.currentTime()
        if stageName then diagnostics.timings[#diagnostics.timings+1]={stage=stageName,photo=stagePhoto,seconds=now-stageStarted} end
        stageName,stagePhoto,stageStarted=name,photo and photoName(photo) or nil,now
        updateProgress(#rows)
      end
      stage(LOC("$$$/BatchAutoStraighten/Preparing=Preparing selected photos"))
      local function addRow(photo, status, reason, extra)
        extra = extra or {}
        extra.id = extra.id or photoId(photo)
        extra.status = status
        extra.reason = reason
        extra.filename = extra.filename or (photo and photoName(photo) or extra.filename)
        extra.origIndex = extra.origIndex or currentOrigIndex
        if extra.referenceFilename == nil and currentRefName then
          extra.referenceFilename = currentRefName
        end
        rows[#rows + 1] = extra
        markQueue:queue(photo, extra)
        return extra
      end

      local function markRemainingJobs(startIndex, reason)
        for j = startIndex, #jobs do
          local job = jobs[j]
          local photo = job.photo
          local id = photoId(photo)
          if not rowHasId(rows, id) then
            local extra = {
              filename = photoName(photo),
              origIndex = job.entry and job.entry.origIndex or j,
              referenceFilename = false,
            }
            if job.role == "follower" and job.group and job.group.reference then
              extra.referenceFilename = job.group.reference.leaf or photoName(job.group.reference.photo)
            end
            addRow(photo, "unprocessed", reason, extra)
          end
        end
      end

      local function stopWith(fromIndex, reason, title, loseOwned)
        if loseOwned then
          owned = false
        end
        markRemainingJobs(fromIndex, reason)
        stopTitle = title or (reason == "canceled" and LOC("$$$/BatchAutoStraighten/Text058=Processing stopped.") or STOP_ERROR)
      end

      local function savePendingMarks()
        if #markQueue:pending()==0 then return end
        local markActive=catalog:getTargetPhoto()
        local markSelected=copySeq(catalog:getTargetPhotos())
        local markModule=CropControl.currentModule()
        local function markScopeOwned()
          return CropControl.selectionIs(catalog,markActive,markSelected) and CropControl.currentModule()==markModule
        end
        markQueue:save(markScopeOwned)
      end

      local function markBeforeNextPhoto(nextPhoto)
        if #markQueue:pending()==0 or not nextPhoto or progress:isCanceled() then return true end
        if not owned or (checkpoint.record and checkpoint.record.state=="pending")
          or not CropControl.selectionIs(catalog,expectedActive,expectedSelected) or CropControl.currentModule()~=expectedModule then return false end
        -- Marking an isolated photo can hide it under a flag/color filter or
        -- remove it from the active Quick Collection. Select the next queued
        -- photo first so that our own mark does not invalidate its selection.
        if CropControl.currentModule()~="library" then
          LrApplicationView.switchToModule("library");expectedModule="library"
          if not CropControl.waitUntil(Timing.library,function()
            return CropControl.currentModule()=="library" and CropControl.selectionIs(catalog,expectedActive,expectedSelected)
          end) then return false end
        end
        if not CropControl.selectionIs(catalog,expectedActive,expectedSelected) then return false end
        pluginSelected=nextPhoto
        catalog:setSelectedPhotos(nextPhoto,{nextPhoto})
        expectedActive,expectedSelected,isolatedPhoto=nextPhoto,{nextPhoto},nextPhoto
        directPhoto,directSettings=nil,nil
        if not CropControl.waitUntil(Timing.library,function()return CropControl.libraryOwned(catalog,nextPhoto)end) then return false end
        savePendingMarks()
        return CropControl.selectionIs(catalog,expectedActive,expectedSelected) and CropControl.currentModule()==expectedModule
      end

      local function writeDiagnostics()
        -- Best-effort diagnostics must never turn a completed batch into an
        -- error, and must survive deletion of the temporary preview directory.
        LrTasks.pcall(function()
          local path=LrPathUtils.child(LrPathUtils.getStandardFilePath("temp") or "/tmp",
            "batch-auto-straighten-last-run.json")
          local f=io.open(path,"wb")
          if f then f:write(json.encode(diagnostics)); f:close() end
        end)
      end

      local function finish(titleExtra, fromCleanup)
        if finished then
          return restored
        end
        if not titleExtra and progress:isCanceled() then titleExtra=LOC("$$$/BatchAutoStraighten/Text058=Processing stopped.") end
        stage(LOC("$$$/BatchAutoStraighten/Finishing=Preparing results"))
        diagnostics.elapsedSeconds=LrDate.currentTime()-runStarted
        finished = true
        -- Selection, module and catalog calls can throw. Guard each step
        -- separately so a failure still reports adjusted photos and does not
        -- skip unrelated cleanup such as clearing a completed checkpoint.
        local finishErrors = {}
        local function guarded(step, fn)
          local ok, err = LrTasks.pcall(fn)
          if not ok then finishErrors[#finishErrors+1] = step .. ": " .. tostring(err):sub(1,512) end
        end
        local allowMarks = false
        guarded("selection", function()
          allowMarks = owned and not (checkpoint.record and checkpoint.record.state=="pending")
            and CropControl.selectionIs(catalog, expectedActive, expectedSelected) and CropControl.currentModule() == expectedModule
          if owned
            and isolatedPhoto
            and CropControl.stillIsolated(catalog, isolatedPhoto)
            and CropControl.currentModule() == expectedModule
          then
            restored = restoreSelection(catalog, initialActive, initialPhotos)
            if initialModule and CropControl.currentModule() ~= initialModule then
              LrApplicationView.switchToModule(initialModule)
            end
          elseif pluginSelected and not progress:isCanceled()
            and CropControl.currentModule() == expectedModule
            and CropControl.stillIsolated(catalog, pluginSelected)
          then
            -- A transitional read can make ownership checks blame the user
            -- for the plug-in's own isolation. Without Cancel the modal
            -- blocks user input, so a selection that is still exactly the
            -- plug-in's photo in the expected module is still ours.
            restored = restoreSelection(catalog, initialActive, initialPhotos)
          end
          if owned and not isolatedPhoto and CropControl.selectionIs(catalog,expectedActive,expectedSelected)
            and CropControl.currentModule()==expectedModule and initialModule and initialModule~=expectedModule then
            LrApplicationView.switchToModule(initialModule)
          end
        end)
        guarded("marks", function()
          if not allowMarks then
            markQueue:discardPending()
          else savePendingMarks() end
        end)
        guarded("checkpoint", function()
          if checkpoint.record and checkpoint.record.state=="complete" then checkpoint:clear() end
        end)
        if #finishErrors > 0 then
          diagnostics.finishError=table.concat(finishErrors, "\n")
          LrTasks.pcall(function()markQueue:discardPending()end)
          local warning=LOC("$$$/BatchAutoStraighten/FinishFailed=Adjustments were kept, but the selection, marks or processing record could not be finalized.")
          titleExtra = titleExtra and (titleExtra .. " " .. warning) or warning
        end
        local ordered, body, details = RunReport.build(rows, {
          sameNameMode=sameNameMode, hasMarks=markQueue:hasEntries(),
          maybeChanged=maybeChanged, stopTitle=titleExtra,
        })
        diagnostics.summary=body
        diagnostics.details=details
        writeDiagnostics()
        resultReport = {rows=ordered, stopTitle=titleExtra, maybeChanged=maybeChanged}
        if not fromCleanup and not progress:isCanceled() then
          -- Present results while the progress modal is still open, as
          -- ReviewDialog does. Opening them after the modal closes races
          -- Lightroom's asynchronous progress teardown, which can end the
          -- results' modal session and strand a window that Done cannot close.
          -- Cancel closes the modal immediately, so that case is deferred.
          resultReport.shown = true
          local shown, dialogResult = LrTasks.pcall(ResultDialog.show, ordered, titleExtra, maybeChanged)
          if shown then
            diagnostics.resultDialog = tostring(dialogResult)
          else
            resultReport.dialogErr = dialogResult
            diagnostics.resultDialog = "error: " .. tostring(dialogResult):sub(1,1024)
          end
          writeDiagnostics()
        end
        progress:done()
        return restored
      end

      context:addCleanupHandler(function()
        LrTasks.pcall(function()rmTree(workDir)end)
        if not finished then
          if loopIndex <= #jobs then
            local job = jobs[loopIndex]
            if job and job.photo then
              local id = photoId(job.photo)
              if not rowHasId(rows, id) then
                addRow(job.photo, "fail", "exception")
                loopIndex = loopIndex + 1
              end
            end
            markRemainingJobs(loopIndex, "unprocessed")
          end
          finish(LOC("$$$/BatchAutoStraighten/Text019=Stopped due to an error."), true)
        end
      end)

      -- Every selected photo remains reportable even if workspace creation fails.
      for idx, photo in ipairs(initialPhotos) do
        jobs[idx] = {photo=photo,entry={origIndex=idx}}
      end
      local tempOk,tempResult=LrTasks.pcall(tempDir)
      workDir=tempOk and tempResult or nil
      if not workDir then
        diagnostics.batchError="temp_dir_failed"
        markRemainingJobs(1,"unprocessed")
        finish(LOC("$$$/BatchAutoStraighten/Text126=Could not create temporary files"))
        return
      end

      local function preflightOwned()
        local reason, title, loseOwned
        if progress:isCanceled() then
          reason, title = "canceled", LOC("$$$/BatchAutoStraighten/Text058=Processing stopped.")
        elseif not CropControl.selectionIs(catalog,expectedActive,expectedSelected) then
          reason, title, loseOwned = "selection_changed", STOP_SELECTION, true
        elseif CropControl.currentModule() ~= expectedModule then
          reason, title = "module_changed", STOP_MODULE
        end
        if reason then
          stopWith(1,reason,title,loseOwned)
          finish(title)
          return false
        end
        return true
      end
      if CropControl.currentModule()~="library" then
        stage(LOC("$$$/BatchAutoStraighten/PreparingLibrary=Preparing the Library module"))
        LrApplicationView.switchToModule("library")
        expectedModule="library"
        if not CropControl.waitUntil(Timing.library,function()return CropControl.currentModule()=="library" end) then
          stopWith(1,"not_ready",STOP_MODULE,false);finish(STOP_MODULE);return
        end
      end
      local entries = {}
      for idx = 1, #initialPhotos do
        if sameNameMode=="individual" then
          entries[#entries+1]={photo=initialPhotos[idx],origIndex=idx,id=tostring(idx)}
        else
          if not preflightOwned() then return end
          stage(string.format(LOC("$$$/BatchAutoStraighten/CheckingPhoto=Checking selected photos %d/%d"),idx,#initialPhotos),initialPhotos[idx])
          if idx==1 or idx%10==0 then LrTasks.sleep(0.01) end
          local entry = describePhoto(initialPhotos[idx], idx)
          local preSettings = options.adjustedPhotoAction == "skip" and not entry.isVideo and not entry.missingOriginal
            and CropControl.snapshotDevelop(entry.photo) or nil
          if not preflightOwned() then return end
          if RunPolicy.hasAngle(preSettings) then
            addRow(entry.photo,"skip","existing_angle",{origIndex=idx,before=-preSettings.CropAngle,after=-preSettings.CropAngle})
          else
            entries[#entries + 1] = entry
          end
        end
        if not markBeforeNextPhoto(initialPhotos[idx+1]) then
          -- Earlier entries are only queued, not processed, during preflight.
          stopWith(1,"selection_changed",STOP_SELECTION,true);finish(STOP_SELECTION);return
        end
      end
      if not preflightOwned() then return end
      jobs = GroupPlan.jobs(GroupPlan.plan(entries, sameNameMode, photoId(initialActive)))
      if not markBeforeNextPhoto(jobs[1] and jobs[1].photo) then
        stopWith(1,"selection_changed",STOP_SELECTION,true);finish(STOP_SELECTION);return
      end

      local function requiresCropReset(angle)
        return options.adjustedPhotoAction=="reset" and HorizonMath.isFiniteNumber(angle) and math.abs(angle)>1e-6
      end

      local function isolateAndTrack(photo, i)
        -- Settings/metadata reads can yield after the loop's ownership check.
        if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
          stopWith(i, "selection_changed", STOP_SELECTION, true)
          return nil
        end
        if CropControl.currentModule() ~= expectedModule then
          stopWith(i, "module_changed", STOP_MODULE, false)
          return nil
        end
        stage(LOC("$$$/BatchAutoStraighten/PreparingPhoto=Preparing photo"),photo)
        directPhoto,directSettings=nil,nil
        if CropControl.currentModule()~="library" then
          LrApplicationView.switchToModule("library")
          expectedModule="library"
          if not CropControl.waitUntil(Timing.library,function()return CropControl.currentModule()=="library" end) then
            stopWith(i,"not_ready",STOP_MODULE,false);return nil
          end
        end
        if options.photoDisplayMode=="minimizeSwitching" and CropControl.currentModule()=="library" then
          local settings=CropControl.snapshotDevelop(photo)
          local context=DirectCrop.context(photo,settings,requiresCropReset(settings.CropAngle))
          if context then
            directPhoto,directSettings=photo,settings
            return true,true
          end
        end
        local priorActive, priorSelected = expectedActive, expectedSelected
        local isoOk, isoResult = LrTasks.pcall(function()
          return CropControl.isolateInLibrary(catalog, photo, priorActive, priorSelected,
            function(selected) pluginSelected = selected end)
        end)
        -- Adopt the singleton expectation only after Lightroom actually exposes
        -- it. If isolation fails without changing selection, retain ownership of
        -- the original selection and report readiness failure, not user action.
        if CropControl.stillIsolated(catalog, photo) then
          expectedActive = photo
          expectedSelected = { photo }
          isolatedPhoto = photo
        end
        expectedModule = "library"
        return isoOk, isoResult
      end

      local function afterIsolate(photo, i, isoOk, isoResult)
        if directPhoto==photo and isoOk and isoResult then
          if applyOwned(photo) then return "ready" end
          stopWith(i,"selection_changed",STOP_SELECTION,true);return "stop"
        end
        if isoOk == nil then
          return "stop"
        end
        if not isoOk then
          addRow(photo, "fail", "exception", { detail = tostring(isoResult) })
          if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
          else
            stopWith(i + 1, "unprocessed", STOP_ERROR, false)
          end
          return "stop"
        end
        if not isoResult then
          addRow(photo, "fail", "not_ready")
          if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
            return "stop"
          end
          if CropControl.currentModule() ~= "library" then
            stopWith(i + 1, "module_changed", STOP_MODULE, false)
            return "stop"
          end
          if not CropControl.stillIsolated(catalog, photo) then
            stopWith(i + 1, "unprocessed", STOP_ERROR, false)
            return "stop"
          end
          return "fail"
        end
        if not CropControl.libraryOwned(catalog, photo) then
          addRow(photo, "fail", "not_ready")
          if not CropControl.stillIsolated(catalog, photo) then
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
            return "stop"
          end
          stopWith(i + 1, "module_changed", STOP_MODULE, false)
          return "stop"
        end
        return "ready"
      end

      local function enterApplyContext(photo, i, settingsBefore, extraCheck)
        if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop" end
        if CropControl.currentModule() ~= "library" then
          stopWith(i, "module_changed", STOP_MODULE, false)
          return "stop"
        end
        if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
          stopWith(i, "selection_changed", STOP_SELECTION, true)
          return "stop"
        end
        if not settingsUnchanged(settingsBefore, photo, "before_develop") then
          stopWith(i, "settings_changed", STOP_SETTINGS, false)
          return "stop"
        end
        if extraCheck then
          local extraReason = extraCheck()
          if extraReason then
            stopWith(i, extraReason, STOP_SETTINGS, false)
            return "stop"
          end
        end

        if directPhoto==photo then return "ready" end
        stage(LOC("$$$/BatchAutoStraighten/PreparingDevelop=Opening Crop & Straighten in Develop"),photo)
        local enterOk, enterResult = LrTasks.pcall(function()
          return CropControl.enterDevelopCrop(catalog, photo)
        end)
        expectedModule = "develop"
        if not enterOk then
          addRow(photo, "fail", "exception", { detail = tostring(enterResult) })
          if not CropControl.stillIsolated(catalog, photo) then
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
          else
            stopWith(i + 1, "unprocessed", STOP_ERROR, false)
          end
          return "stop"
        end
        if not enterResult then
          addRow(photo, "fail", "not_ready")
          if not CropControl.stillIsolated(catalog, photo) then
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
            return "stop"
          end
          if CropControl.currentModule() ~= "develop" then
            stopWith(i + 1, "module_changed", STOP_MODULE, false)
            return "stop"
          end
          return "fail"
        end
        if not CropControl.developCropOwned(catalog, photo) then
          addRow(photo, "fail", "not_ready")
          if not CropControl.stillIsolated(catalog, photo) then
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
            return "stop"
          end
          stopWith(i + 1, "module_changed", STOP_MODULE, false)
          return "stop"
        end
        if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
          stopWith(i, "selection_changed", STOP_SELECTION, true)
          return "stop"
        end
        if CropControl.currentModule() ~= expectedModule then
          stopWith(i, "module_changed", STOP_MODULE, false)
          return "stop"
        end
        if not settingsUnchanged(settingsBefore, photo, "after_develop") then
          stopWith(i, "settings_changed", STOP_SETTINGS, false)
          return "stop"
        end
        if extraCheck then
          local extraReason = extraCheck()
          if extraReason then
            stopWith(i, extraReason, STOP_SETTINGS, false)
            return "stop"
          end
        end
        return "ready"
      end

      local remainingOverLimitAction = nil
      local function allowTarget(photo, i, target, fields)
        if fields.limitOverride then return "allow" end
        if not RunPolicy.exceeds(options, target) then return "allow" end
        if options.overLimitAction == "skip" or remainingOverLimitAction == "skip" then
          fields.target, fields.after = target, fields.before
          addRow(photo, "skip", remainingOverLimitAction and "review_skipped" or "angle_limit", fields)
          return "skip"
        end
        if remainingOverLimitAction == "apply" then
          fields.limitOverride = true
          return "allow"
        end
        local before = CropControl.snapshotDevelop(photo)
        local previewPath = LrPathUtils.child(workDir, photoId(photo) .. "-crop-preview.png")
        local previewOk = fields.previewPath and HelperLaunch.preview(fields.previewPath,previewPath,target-(fields.before or 0))
        if progress:isCanceled() then
          stopWith(i,"canceled",LOC("$$$/BatchAutoStraighten/Text058=Processing stopped."),false)
          return "stop"
        end
        if not applyOwned(photo) then
          stopWith(i,"selection_changed",STOP_SELECTION,true)
          return "stop"
        end
        if not settingsUnchanged(before, photo, "before_review") then
          stopWith(i,"settings_changed",STOP_SETTINGS,false)
          return "stop"
        end
        local reviewAction, reviewError = ReviewDialog(photoName(photo), photo, previewOk and previewPath or nil,
          target, target<0 and -options.maxLeftAngle or options.maxRightAngle,
          {isCanceled=function() return progress:isCanceled() end})
        if not applyOwned(photo) then
          stopWith(i,"selection_changed",STOP_SELECTION,true)
          return "stop"
        end
        if not settingsUnchanged(before, photo, "after_review") then
          stopWith(i,"settings_changed",STOP_SETTINGS,false)
          return "stop"
        end
        if reviewError then
          fields.reviewError=reviewError
          stopWith(i,"review_failed",LOC("$$$/BatchAutoStraighten/ReviewFailed=The review dialog could not complete. Processing stopped."),false)
          return "stop"
        end
        if reviewAction == "stop" or progress:isCanceled() then
          stopWith(i,"canceled",LOC("$$$/BatchAutoStraighten/Text058=Processing stopped."),false)
          return "stop"
        end
        if reviewAction == "skip" or reviewAction == "skip_all_remaining" then
          if reviewAction == "skip_all_remaining" then remainingOverLimitAction = "skip" end
          fields.target, fields.after = target, fields.before
          addRow(photo,"skip","review_skipped",fields)
          return "skip"
        end
        if reviewAction == "apply_all_remaining" then
          remainingOverLimitAction = "apply"
          reviewAction = "apply"
        end
        if reviewAction ~= "apply" then
          fields.reviewError="unknown review action"
          stopWith(i,"review_failed",LOC("$$$/BatchAutoStraighten/ReviewFailed=The review dialog could not complete. Processing stopped."),false)
          return "stop"
        end
        fields.limitOverride = true
        return "allow"
      end

      local function resetMatches(before, after)
        local expected = {}
        for k,v in pairs(before) do expected[k] = v end
        expected.CropAngle, expected.CropLeft, expected.CropTop = 0, 0, 0
        expected.CropRight, expected.CropBottom = 1, 1
        -- Native reset may remove this optional aspect-lock key.
        expected.CropConstrainAspectRatio = after.CropConstrainAspectRatio
        return HorizonMath.tablesEqual(expected,after)
      end

      local function commitDirect(photo,i,target,fields)
        local rounded=DirectCrop.roundAngle(target)
        if not HorizonMath.inAllowedRange(rounded,-45,45) then
          addRow(photo,"skip","angle_outside_sdk",fields);return "continue"
        end
        local allowed=allowTarget(photo,i,rounded,fields)
        if allowed=="stop" then return "stop" end
        if allowed~="allow" then return "continue" end
        local before=fields.expectedSettings or CropControl.snapshotDevelop(photo)
        if not applyOwned(photo) or not settingsUnchanged(before,photo,"before_direct_write") then
          stopWith(i,"settings_changed",STOP_SETTINGS,false);return "stop"
        end
        if fields.referenceCheck and fields.referenceCheck() then
          stopWith(i,"reference_settings_changed",STOP_SETTINGS,false);return "stop"
        end
        if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop" end
        local context=DirectCrop.context(photo,before,requiresCropReset(before.CropAngle))
        if not context then
          stopWith(i,"settings_changed",STOP_SETTINGS,false);return "stop"
        end
        local frame=DirectCrop.frame(context,rounded)
        local prepared,prepareError=LrTasks.pcall(function()
          checkpoint:begin(photo,photoName(photo),before,rounded,frame)
        end)
        if not prepared then
          fields.detail=tostring(prepareError);addRow(photo,"fail","checkpoint_failed",fields)
          stopWith(i+1,"unprocessed",LOC("$$$/BatchAutoStraighten/CheckpointFailed=Stopped because the processing record could not be saved."),false);return "stop"
        end
        stage(LOC("$$$/BatchAutoStraighten/SavingDirect=Saving angle without changing the displayed photo"),photo)
        local wrote=false
        local ok,err=LrTasks.pcall(function()
          local status=catalog:withWriteAccessDo(LOC("$$$/BatchAutoStraighten/Text001=Batch Auto Straighten"),function()
            if progress:isCanceled() then error("canceled") end
            if not applyOwned(photo) then error("ownership_lost") end
            if fields.referenceCheck and fields.referenceCheck() then error("reference_settings_changed") end
            if not settingsUnchanged(before,photo,"direct_write") then error("settings_changed") end
            if progress:isCanceled() then error("canceled") end
            if not applyOwned(photo) then error("ownership_lost") end
            if fields.referenceCheck and fields.referenceCheck() then error("reference_settings_changed") end
            if progress:isCanceled() then error("canceled") end
            wrote=true
            saveInProgress=true;saveFields=fields;fields.target=rounded
            photo:applyDevelopSettings(frame,LOC("$$$/BatchAutoStraighten/Text001=Batch Auto Straighten"))
          end,{timeout=5})
          if status~="executed" then error(tostring(status)) end
        end)
        if not ok then
          saveInProgress=false
          if not wrote then
            LrTasks.pcall(function()checkpoint:clear()end)
            if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop" end
          end
          maybeChanged=maybeChanged or wrote
          fields.applyErr=tostring(err);addRow(photo,"fail","apply_failed",fields)
          stopWith(i+1,"unprocessed",STOP_ERROR,false);return "stop"
        end
        stage(LOC("$$$/BatchAutoStraighten/CheckingSave=Checking saved angle and crop"),photo)
        local deadline=LrDate.currentTime()+Timing.readback
        local stableSince,previous=nil,nil
        local observed,why
        while LrDate.currentTime()<deadline do
          updateProgress(#rows)
          if not applyOwned(photo) then why="ownership_lost";break end
          observed=CropControl.snapshotDevelop(photo)
          if not HorizonMath.nonCropSettingsEqual(before,observed) then why="settings_changed_during_save";break end
          if DirectCrop.matches(observed,frame) then
            if previous and HorizonMath.tablesEqual(previous,observed) then
              if LrDate.currentTime()-stableSince>=Timing.stable then
                saveInProgress=false
                fields.after=-observed.CropAngle;fields.application="direct"
                addRow(photo,"applied","applied",fields)
                local saved=LrTasks.pcall(function()checkpoint:complete(observed)end)
                if not saved then
                  stopWith(i+1,"unprocessed",LOC("$$$/BatchAutoStraighten/CheckpointFailed=Stopped because the processing record could not be saved."),false);return "stop"
                end
                return "continue",observed
              end
            else stableSince=LrDate.currentTime() end
            previous=observed
          else stableSince,previous=nil,nil end
          updateProgress(#rows);LrTasks.sleep(.05)
        end
        saveInProgress=false
        maybeChanged=true;fields.detail=why or "direct_crop_unconfirmed";fields.target=rounded
        fields.after=observed and observed.CropAngle and -observed.CropAngle or nil
        addRow(photo,"fail","apply_unconfirmed",fields)
        stopWith(i+1,"unprocessed",STOP_ERROR,false);return "stop"
      end

      local function commitAngle(photo, i, target, fields, readbackEps)
        fields = fields or {}
        if fields.source=="image_analysis" then readbackEps=HorizonMath.VALUE_EPS end
        if directPhoto==photo then return commitDirect(photo,i,target,fields) end
        stage(LOC("$$$/BatchAutoStraighten/SavingDevelop=Saving angle in Develop"),photo)
        local minv, maxv = LrDevelopController.getRange("straightenAngle")
        if not HorizonMath.inAllowedRange(target, minv, maxv) then
          fields.target, fields.after = target, fields.before
          addRow(photo, "skip", "angle_outside_sdk", fields)
          return "continue"
        end
        if not CropControl.developCropOwned(catalog, photo) then
          if not CropControl.stillIsolated(catalog, photo) then
            stopWith(i, "selection_changed", STOP_SELECTION, true)
          else
            stopWith(i, "module_changed", STOP_MODULE, false)
          end
          return "stop"
        end
        local allowed = allowTarget(photo, i, target, fields)
        if allowed == "stop" then return "stop" end
        if allowed ~= "allow" then return "continue" end
        if fields.referenceCheck and fields.referenceCheck() then
          stopWith(i,"reference_settings_changed",STOP_SETTINGS,false)
          return "stop"
        end
        if progress:isCanceled() then
          stopWith(i,"canceled",LOC("$$$/BatchAutoStraighten/Text058=Processing stopped."),false)
          return "stop"
        end
        local appliedFromSettings
        local wrote=false
        local function retryAllowed(expected)
          if progress:isCanceled() or not CropControl.developCropOwned(catalog,photo) then return false end
          if fields.referenceCheck and fields.referenceCheck() then return false end
          if not HorizonMath.tablesEqual(expected,CropControl.snapshotDevelop(photo)) then return false end
          return not progress:isCanceled() and CropControl.developCropOwned(catalog,photo)
        end
        local function writeAngle()
          if not CropControl.developCropOwned(catalog, photo) then return false end
          wrote=true;saveInProgress=true;saveFields=fields;fields.target=target
          LrDevelopController.setValue("straightenAngle", target)
          if not CropControl.developCropOwned(catalog, photo) then return false end
          LrDevelopController.stopTracking()
          return true
        end
        local applyOk, applyErr = LrTasks.pcall(function()
          local expectedSettings = fields.expectedSettings or CropControl.snapshotDevelop(photo)
          if not settingsUnchanged(expectedSettings, photo, "before_write") then error("settings_changed") end
          if not CropControl.developCropOwned(catalog,photo) then error("apply_ownership_lost") end
          if progress:isCanceled() then stopWith(i,"canceled",nil,false);return end
          local reset
          if requiresCropReset(fields.before) then
            reset=SaveCheckpoint.crop(expectedSettings)
            reset.CropAngle=0;reset.CropLeft=0;reset.CropTop=0;reset.CropRight=1;reset.CropBottom=1
          end
          local prepared,prepareError=LrTasks.pcall(function()
            checkpoint:begin(photo,photoName(photo),expectedSettings,target,nil,reset)
          end)
          if not prepared then error("checkpoint_failed: "..tostring(prepareError)) end
          if not settingsUnchanged(expectedSettings,photo,"after_checkpoint") then error("settings_changed") end
          if not CropControl.developCropOwned(catalog,photo) then error("apply_ownership_lost") end
          if progress:isCanceled() then stopWith(i,"canceled",nil,false);return end
          if requiresCropReset(fields.before) then
            wrote=true;saveInProgress=true;saveFields=fields;fields.target=target
            LrDevelopController.resetCrop()
            if not CropControl.developCropOwned(catalog,photo) then error("reset_crop_ownership_lost") end
            LrDevelopController.stopTracking()
            local resetOk, resetWhy, resetObserved = CropControl.waitReadback(catalog,photo,0,HorizonMath.VALUE_EPS,
              expectedSettings, function() updateProgress(#rows);return false end,
              function()
                -- As with setValue, a newly opened crop control can drop its
                -- first reset. Retry once only if the entire photo is still
                -- unchanged; never reset over a crop edit made while waiting.
                if not retryAllowed(expectedSettings) then return false end
                LrDevelopController.resetCrop()
                if not CropControl.developCropOwned(catalog,photo) then return false end
                LrDevelopController.stopTracking()
                return true
              end, function()return not progress:isCanceled()end)
            diagnostics.resetChecks=diagnostics.resetChecks or {}
            diagnostics.resetChecks[#diagnostics.resetChecks+1]={photo=photoName(photo),ok=resetOk,
              ui=resetObserved.ui,saved=resetObserved.saved,writeAttempts=resetObserved.writeAttempts or 1}
            if not resetOk then
              if resetWhy == "settings_changed_during_save" then
                recordSettingsCheck(expectedSettings, resetObserved.settings, photo, "during_reset")
              end
              error("reset_crop_unconfirmed: " .. tostring(resetWhy)
                .. " ui=" .. tostring(resetObserved.ui) .. " saved=" .. tostring(resetObserved.saved))
            end
            if not resetMatches(expectedSettings,resetObserved.settings) then error("reset_crop_settings_changed") end
            expectedSettings = resetObserved.settings
          end
          -- Both reads may yield. Recheck the source, then the complete current
          -- settings, and finally ownership immediately before the angle write.
          if fields.referenceCheck and fields.referenceCheck() then error("reference_settings_changed") end
          if wrote then
            if not HorizonMath.tablesEqual(expectedSettings,CropControl.snapshotDevelop(photo)) then error("settings_changed") end
          elseif not settingsUnchanged(expectedSettings, photo, "before_write") then error("settings_changed") end
          if not wrote and progress:isCanceled() then stopWith(i,"canceled",nil,false);return end
          if not CropControl.developCropOwned(catalog,photo) then error("apply_ownership_lost") end
          appliedFromSettings = expectedSettings
          if not writeAngle() then error("apply_ownership_lost") end
        end)
        if not wrote and progress:isCanceled() then
          LrTasks.pcall(function()if checkpoint.record and checkpoint.record.state=="pending" then checkpoint:clear()end end)
          stopWith(i,"canceled",nil,false);return "stop"
        end
        if not applyOk then
          saveInProgress=false
          if not wrote then LrTasks.pcall(function()if checkpoint.record and checkpoint.record.state=="pending" then checkpoint:clear()end end) end
          maybeChanged = maybeChanged or wrote
          local reason=tostring(applyErr):find("checkpoint_failed",1,true) and "checkpoint_failed" or "apply_failed"
          fields.applyErr=tostring(applyErr):sub(1,1024)
          addRow(photo, "fail", reason, fields)
          stopWith(i + 1, "unprocessed", nil, false)
          return "stop"
        end
        local readOk, readWhy, observed = CropControl.waitReadback(catalog, photo, target, readbackEps,
          appliedFromSettings, function() updateProgress(#rows);return false end,
          function()if not retryAllowed(appliedFromSettings) then return false end;return writeAngle()end,
          function()return not progress:isCanceled()end)
        saveInProgress=false
        if readOk then
          local confirmed = readWhy
          if not HorizonMath.isFiniteNumber(confirmed) then
            confirmed = CropControl.readStraighten()
          end
          if not HorizonMath.isFiniteNumber(confirmed) then
            maybeChanged = true
            fields.detail = "read_failed"
            addRow(photo, "fail", "apply_unconfirmed", fields)
            stopWith(i + 1, "unprocessed", nil, false)
            return "stop"
          end
          if not fields.limitOverride and (RunPolicy.exceeds(options,confirmed) or RunPolicy.exceeds(options,observed.saved)) then
            maybeChanged = true
            fields.detail, fields.target = "saved_angle_outside_limits", target
            fields.uiAfter, fields.after = confirmed, observed.saved
            addRow(photo,"fail","apply_unconfirmed",fields)
            stopWith(i+1,"unprocessed",LOC("$$$/BatchAutoStraighten/Text059=Stopped because the saved angle exceeded the limit."),false)
            return "stop"
          end
          fields.after = confirmed
          addRow(photo, "applied", "applied", fields)
          local saved=LrTasks.pcall(function()checkpoint:complete(observed.settings)end)
          if not saved then
            stopWith(i+1,"unprocessed",LOC("$$$/BatchAutoStraighten/CheckpointFailed=Stopped because the processing record could not be saved."),false);return "stop"
          end
          return "continue", observed.settings
        end
        if readWhy == "settings_changed_during_save" then
          recordSettingsCheck(appliedFromSettings, observed.settings, photo, "during_save")
        end
        maybeChanged = true
        if readWhy == "selection_changed" then
          owned = false
        end
        fields.detail = readWhy
        fields.target = target
        fields.uiAfter = observed.ui
        fields.after = observed.saved
        addRow(photo, "fail", "apply_unconfirmed", fields)
        stopWith(i + 1, "unprocessed", nil, false)
        return "stop"
      end

      local function referenceGuard(share)
        return function()
          if not share or not share.ok or not share.reference then
            return "reference_settings_changed"
          end
          if not settingsUnchanged(share.refSettings, share.reference, "reference") then
            return "reference_settings_changed"
          end
          return nil
        end
      end

      local function processEstimated(photo, i, settingsBefore, wantShare)
        local share = wantShare and makeShareFail(photo, "reference_failed") or nil
        local id = photoId(photo)
        if sameNameMode=="individual" then
          stage(LOC("$$$/BatchAutoStraighten/PreparingPhoto=Preparing photo"),photo)
          if not CropControl.selectionIs(catalog,expectedActive,expectedSelected) then
            stopWith(i,"selection_changed",STOP_SELECTION,true);return "stop",share
          end
          if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop",share end
        end
        if options.adjustedPhotoAction=="skip" and settingsBefore==nil then
          settingsBefore=CropControl.snapshotDevelop(photo)
          if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop",share end
          if not CropControl.selectionIs(catalog,expectedActive,expectedSelected) then
            stopWith(i,"selection_changed",STOP_SELECTION,true);return "stop",share
          end
        end
        if options.adjustedPhotoAction == "skip" and RunPolicy.hasAngle(settingsBefore or CropControl.snapshotDevelop(photo)) then
          local angle = -(settingsBefore or CropControl.snapshotDevelop(photo)).CropAngle
          addRow(photo,"skip","existing_angle",{before=angle,after=angle})
          if wantShare then share = makeShareFail(photo,"reference_excluded") end
          return "continue", share
        end
        if SkipRules.isVideo(photo) then
          addRow(photo, "skip", "not_still")
          return "continue", share
        end
        if SkipRules.missingOriginal(photo) then
          addRow(photo, "skip", "missing_original")
          return "continue", share
        end

        local isoOk, isoResult = isolateAndTrack(photo, i)
        local isoState = afterIsolate(photo, i, isoOk, isoResult)
        if isoState ~= "ready" then
          return isoState, share
        end

        if settingsBefore == nil then
          settingsBefore = directSettings or CropControl.snapshotDevelop(photo)
        end
        if not settingsUnchanged(settingsBefore, photo, "before_tilt_analysis") then
          stopWith(i, "settings_changed", STOP_SETTINGS, false)
          return "stop", share
        end

        local jpegPath = LrPathUtils.child(workDir, id .. ".jpg")
        stage(LOC("$$$/BatchAutoStraighten/RenderingPreview=Preparing image preview"),photo)
        local preview = requestPreview(photo, jpegPath)
        waitFor({ preview }, PREVIEW_TIMEOUT,function()updateProgress(#rows);return not progress:isCanceled()end)
        if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop",share end
        if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
          owned = false
          if not preview.ok then
            addRow(photo, "fail", "no_preview", {
              detail = preview.detail or "unspecified",
              callbackErr = preview.callbackErr,
            })
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
          else
            stopWith(i, "selection_changed", STOP_SELECTION, true)
          end
          return "stop", share
        end
        if CropControl.currentModule() ~= expectedModule then
          if not preview.ok then
            addRow(photo, "fail", "no_preview", {
              detail = preview.detail or "unspecified",
              callbackErr = preview.callbackErr,
            })
            stopWith(i + 1, "module_changed", STOP_MODULE, false)
          else
            stopWith(i, "module_changed", STOP_MODULE, false)
          end
          return "stop", share
        end
        if not preview.ok then
          addRow(photo, "fail", "no_preview", {
            detail = preview.detail or "unspecified",
            callbackErr = preview.callbackErr,
          })
          return "continue", share
        end

        local outputPath = LrPathUtils.child(workDir, id .. ".json")
        local originalPath = nil
        local tiltSource = options.tiltSource
        if tiltSource == "inCameraData" and not HorizonMath.inCameraDataGeometrySafe(settingsBefore) then tiltSource = "imageAnalysis" end
        if tiltSource == "inCameraData" then
          local path = photo:getRawMetadata("path")
          if type(path) == "string" and path ~= "" then
            originalPath = path
          end
        end

        stage(tiltSource=="inCameraData" and LOC("$$$/BatchAutoStraighten/ReadingCamera=Reading recorded camera-level data") or LOC("$$$/BatchAutoStraighten/Analyzing=Analyzing image"),photo)
        local helperOk, helperErr = HelperLaunch.run(id, jpegPath, outputPath, originalPath, tiltSource)
        if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop",share end
        local payload, decodeErr
        if helperOk then payload,decodeErr=HelperProtocol.decode(outputPath,id,tiltSource) end
        local cameraDataUnavailable = payload and tiltSource=="inCameraData" and (payload.kind=="none" or (payload.kind=="horizon"
          and not HorizonMath.rollIsUsable(payload.roll_degrees,payload.make)))
        if helperOk and cameraDataUnavailable then
          tiltSource="imageAnalysis"
          stage(LOC("$$$/BatchAutoStraighten/Analyzing=Analyzing image"),photo)
          helperOk, helperErr = HelperLaunch.run(id,jpegPath,outputPath,nil,tiltSource)
          if progress:isCanceled() then stopWith(i,"canceled",nil,false);return "stop",share end
          payload,decodeErr=nil,nil
          if helperOk then payload,decodeErr=HelperProtocol.decode(outputPath,id,tiltSource) end
        end
        if not helperOk and HelperLaunch.isBlockedError(helperErr) then
          addRow(photo, "fail", "helper_blocked", { detail = helperErr, source = (tiltSource == "imageAnalysis" or cameraDataUnavailable) and "image_analysis" or "camera_roll" })
          stopWith(i + 1, "unprocessed", helperErr, false)
          return "stop", share
        end
        if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
          owned = false
          if not helperOk then
            addRow(photo, "fail", "helper_failed", { detail = helperErr })
            stopWith(i + 1, "selection_changed", STOP_SELECTION, true)
          else
            stopWith(i, "selection_changed", STOP_SELECTION, true)
          end
          return "stop", share
        end
        if CropControl.currentModule() ~= expectedModule then
          if not helperOk then
            addRow(photo, "fail", "helper_failed", { detail = helperErr })
            stopWith(i + 1, "module_changed", STOP_MODULE, false)
          else
            stopWith(i, "module_changed", STOP_MODULE, false)
          end
          return "stop", share
        end
        if not helperOk then
          addRow(photo, "fail", "helper_failed", { detail = helperErr, source = (tiltSource == "imageAnalysis" or cameraDataUnavailable) and "image_analysis" or "camera_roll" })
          return "continue", share
        end

        if payload and payload.kind=="horizon" and tiltSource == "inCameraData" then
          local beforeUi = 0
          if type(settingsBefore) == "table" and type(settingsBefore.CropAngle) == "number" then
            beforeUi = -settingsBefore.CropAngle
          end
          local residual = HorizonMath.residualFromRoll(payload.roll_degrees, payload.make, beforeUi)
          if residual ~= nil then
            payload.kind = "horizon"
            payload.residual_degrees = residual
            payload.source = "camera_roll"
          end
        end
        if not payload then
          addRow(photo, "fail", "helper_protocol", {
            detail = decodeErr or "unspecified",
          })
          return "continue", share
        end
        if payload.timing then diagnostics.timings[#diagnostics.timings+1]={stage="image_analysis_runtime",photo=photoName(photo),timing=payload.timing} end
        local resultSource = payload.source == "camera_roll" and "camera_roll"
          or "image_analysis"
        if payload.kind == "none" then
          local unchanged = HorizonMath.isFiniteNumber(settingsBefore.CropAngle) and -settingsBefore.CropAngle or nil
          addRow(photo, "skip", "no_horizon", {before=unchanged,after=unchanged,source=resultSource})
          if wantShare then
            share = makeShareFail(photo, "no_horizon")
          end
          return "continue", share
        end
        if payload.kind == "error" then
          addRow(photo, "fail", "helper_error", { detail = tostring(payload.detail or "unspecified"):sub(1,256), error = type(payload.error)=="string" and payload.error:sub(1,1024) or nil, source = resultSource })
          return "continue", share
        end

        local deadband = resultSource == "camera_roll"
          and HorizonMath.IN_CAMERA_DATA_DEADBAND_DEG
          or HorizonMath.IMAGE_ANALYSIS_DEADBAND_DEG
        local decision, reason = HorizonMath.classifyResidual(payload.residual_degrees, deadband)
        if decision ~= "apply" then
          if decision == "noop" then
            local enterState = enterApplyContext(photo, i, settingsBefore)
            if enterState == "stop" then
              return "stop", share
            end
            if enterState ~= "ready" then
              return "continue", share
            end
            -- A no-op has no save/readback cycle. Confirm its catalog angle
            -- before sharing it; a merely readable Crop control may be stale.
            local currentSettings = CropControl.snapshotDevelop(photo)
            local current = HorizonMath.isFiniteNumber(currentSettings.CropAngle) and -currentSettings.CropAngle or nil
            local ui = directPhoto==photo and current or CropControl.readStraighten()
            if not HorizonMath.isFiniteNumber(current) or not HorizonMath.isFiniteNumber(ui)
              or math.abs(ui-current)>HorizonMath.VALUE_EPS then
              addRow(photo, "fail", "not_ready")
              return "continue", share
            end
            if not HorizonMath.tablesEqual(settingsBefore,currentSettings) then
              recordSettingsCheck(settingsBefore,currentSettings,photo,"before_noop")
              stopWith(i,"settings_changed",STOP_SETTINGS,false)
              return "stop",share
            end
            if (options.adjustedPhotoAction == "reset" and math.abs(current) > 1e-6) or RunPolicy.exceeds(options,current) then
              local action, confirmedSettings = commitAngle(photo,i,current,{before=current,expectedSettings=settingsBefore,previewPath=jpegPath,source=resultSource})
              local last = rows[#rows]
              if wantShare and last and last.status == "applied" then
                share = {ok=true,target=last.after,refSettings=confirmedSettings,reference=photo,referenceName=photoName(photo),limitOverride=last.limitOverride}
              elseif wantShare then share = makeShareFail(photo,last and last.reason) end
              return action,share
            end
            addRow(photo, "noop", reason, { before = current, after = current, source = resultSource })
            if wantShare then
              share = {
                ok = true,
                target = current,
                refSettings = currentSettings,
                reference = photo,
                referenceName = photoName(photo),
              }
            end
            return "continue", share
          end
          addRow(photo, "fail", reason, { source = resultSource })
          if wantShare then
            share = makeShareFail(photo, reason)
          end
          return "continue", share
        end

        local enterState = enterApplyContext(photo, i, settingsBefore)
        if enterState == "stop" then
          return "stop", share
        end
        if enterState ~= "ready" then
          return "continue", share
        end
        local current = directPhoto==photo and -(CropControl.snapshotDevelop(photo).CropAngle or 0) or CropControl.readStraighten()
        if not HorizonMath.isFiniteNumber(current) then
          addRow(photo, "fail", "not_ready")
          return "continue", share
        end
        local target = HorizonMath.targetStraighten(current, payload.residual_degrees)
        local commitState, confirmedSettings = commitAngle(photo, i, target, { before = current, expectedSettings = settingsBefore, previewPath = jpegPath, source = resultSource })
        if commitState == "continue" then
          local last = rows[#rows]
          if wantShare and last and last.status == "applied" and HorizonMath.isFiniteNumber(last.after) then
            share = {
              ok = true,
              target = last.after,
              limitOverride = last.limitOverride,
              refSettings = confirmedSettings,
              reference = photo,
              referenceName = photoName(photo),
            }
          elseif wantShare then
            share = makeShareFail(photo, last and last.reason or "reference_failed")
          end
        end
        return commitState, share
      end

      local function processFollower(photo, i, settingsBefore, share)
        if options.adjustedPhotoAction == "skip" and RunPolicy.hasAngle(settingsBefore or CropControl.snapshotDevelop(photo)) then
          local angle = -(settingsBefore or CropControl.snapshotDevelop(photo)).CropAngle
          addRow(photo,"skip","existing_angle",{before=angle,after=angle})
          return "continue"
        end
        if SkipRules.isVideo(photo) then
          addRow(photo, "skip", "not_still")
          return "continue"
        end
        if SkipRules.missingOriginal(photo) then
          addRow(photo, "skip", "missing_original")
          return "continue"
        end
        if not share or not share.ok then
          local status = (share and share.followerStatus) or "fail"
          local reason = (share and share.followerReason) or "reference_failed"
          local unchanged = settingsBefore and HorizonMath.isFiniteNumber(settingsBefore.CropAngle) and -settingsBefore.CropAngle or nil
          addRow(photo, status, reason, {
            referenceFilename = share and share.referenceName or currentRefName,
            before=unchanged, after=unchanged,
          })
          return "continue"
        end
        if settingsBefore and not settingsUnchanged(settingsBefore, photo, "follower_before_isolation") then
          stopWith(i, "settings_changed", STOP_SETTINGS, false)
          return "stop"
        end
        if referenceGuard(share)() then
          stopWith(i, "reference_settings_changed", STOP_SETTINGS, false)
          return "stop"
        end

        local isoOk, isoResult = isolateAndTrack(photo, i)
        local isoState = afterIsolate(photo, i, isoOk, isoResult)
        if isoState ~= "ready" then
          return isoState
        end
        if settingsBefore and not settingsUnchanged(settingsBefore, photo, "follower_after_isolation") then
          stopWith(i, "settings_changed", STOP_SETTINGS, false)
          return "stop"
        end

        local enterState = enterApplyContext(photo, i, settingsBefore, referenceGuard(share))
        if enterState == "stop" then
          return "stop"
        end
        if enterState ~= "ready" then
          return "continue"
        end
        local current = directPhoto==photo and -(CropControl.snapshotDevelop(photo).CropAngle or 0) or CropControl.readStraighten()
        if not HorizonMath.isFiniteNumber(current) then
          addRow(photo, "fail", "not_ready")
          return "continue"
        end
        local fields = {
          before = current,
          referenceFilename = share.referenceName,
          limitOverride = share.limitOverride,
          referenceCheck = referenceGuard(share),
          expectedSettings = settingsBefore,
          source = "reference",
          referenceFormat = share.reference:getRawMetadata("fileFormat"),
        }
        if not HorizonMath.isFiniteNumber(share.target) then
          addRow(photo, "fail", "reference_failed", fields)
          return "continue"
        end
        if math.abs(current - share.target) <= HorizonMath.VALUE_EPS
          and not RunPolicy.exceeds(options,share.target)
          and not (options.adjustedPhotoAction == "reset" and math.abs(current) > 1e-6) then
          fields.after = current
          addRow(photo, "noop", "aligned", fields)
          return "continue"
        end
        return commitAngle(photo, i, share.target, fields, HorizonMath.VALUE_EPS)
      end

      local loopOk, loopErr = LrTasks.pcall(function()
        local groupSnaps = {}
        local groupShare = {}
        for i, job in ipairs(jobs) do
          loopIndex = i
          currentOrigIndex = job.entry and job.entry.origIndex or i
          currentPhotoNumber = #rows + 1
          currentRefName = nil
          stage(LOC("$$$/BatchAutoStraighten/PreparingPhoto=Preparing photo"),job.photo)
          if progress:isCanceled() then
            stopWith(i, "canceled", nil, false)
            return
          end

          if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
            owned = false
            markRemainingJobs(i, "selection_changed")
            stopTitle = STOP_SELECTION
            return
          end
          if CropControl.currentModule() ~= expectedModule then
            markRemainingJobs(i, "module_changed")
            stopTitle = STOP_MODULE
            return
          end

          local photo = job.photo
          if job.group and job.group.shared and groupSnaps[job.group.key] == nil then
            -- A completed/skipped reference can leave us in Develop on the
            -- previous group. Lightroom may expose a transitional settings
            -- table when an inactive photo is queried there. Always establish
            -- the next shared group's baseline in Library before reading any
            -- of its members.
            if CropControl.currentModule() ~= "library" then
              LrApplicationView.switchToModule("library")
              expectedModule = "library"
              local libraryReady = CropControl.waitUntil(Timing.library, function()
                return CropControl.currentModule() == "library"
                  and CropControl.selectionIs(catalog, expectedActive, expectedSelected)
              end)
              if not libraryReady then
                if not CropControl.selectionIs(catalog, expectedActive, expectedSelected) then
                  owned = false
                  stopWith(i, "selection_changed", STOP_SELECTION, true)
                else
                  stopWith(i, "module_changed", STOP_MODULE, false)
                end
                return
              end
            end
            local snaps = {}
            for m = 1, #job.group.members do
              local member = job.group.members[m]
              snaps[member.id] = CropControl.snapshotDevelop(member.photo)
            end
            groupSnaps[job.group.key] = snaps
          end

          if job.role == "follower" then
            currentRefName = (job.group.reference and (job.group.reference.leaf or photoName(job.group.reference.photo)))
              or nil
            local snaps = groupSnaps[job.group.key]
            local settingsBefore = snaps and snaps[job.entry.id] or nil
            local share = groupShare[job.group.key]
            local action = processFollower(photo, i, settingsBefore, share)
            if action == "stop" then
              return
            end
          else
            local settingsBefore = nil
            if job.role == "reference" then
              local snaps = groupSnaps[job.group.key]
              settingsBefore = snaps and snaps[job.entry.id] or nil
            end
            local action, share = processEstimated(
              photo,
              i,
              settingsBefore,
              job.role == "reference"
            )
            if job.role == "reference" then
              groupShare[job.group.key] = share or makeShareFail(photo, "reference_failed")
            end
            if action == "stop" then
              return
            end
          end
          if not markBeforeNextPhoto(jobs[i+1] and jobs[i+1].photo) then
            stopWith(i+1,"selection_changed",STOP_SELECTION,true)
            return
          end
          updateProgress(#rows)
        end
      end)

      if not loopOk then
        local job = jobs[loopIndex]
        local photo = job and job.photo or initialPhotos[loopIndex]
        if photo then
          local id = photoId(photo)
          if not rowHasId(rows, id) then
            local fields=saveInProgress and saveFields or {}
            fields.detail=tostring(loopErr):sub(1,1024)
            if saveInProgress then maybeChanged=true end
            addRow(photo, "fail", saveInProgress and "apply_unconfirmed" or "exception", fields)
            loopIndex = loopIndex + 1
          end
          markRemainingJobs(loopIndex, "unprocessed")
        end
        if isolatedPhoto and not CropControl.stillIsolated(catalog, isolatedPhoto) then
          owned = false
        end
        finish(LOC("$$$/BatchAutoStraighten/Text019=Stopped due to an error."))
        return
      end

      finish(stopTitle)
    end)
  end)

  -- Lightroom closes the progress modal asynchronously, after Cancel or once
  -- its context exits. A modal opened before that teardown finishes can have
  -- its session ended by it, stranding the window. Wait before any later modal.
  local teardownWaited = false
  local function afterProgressTeardown()
    if progressOpened and not teardownWaited then
      teardownWaited = true
      LrTasks.sleep(0.5)
    end
  end
  if resultReport and resultReport.dialogErr and bodyOk then
    bodyOk, bodyErr = false, resultReport.dialogErr
  elseif resultReport and not resultReport.shown then
    -- Cancel and the cleanup-handler path: results cannot nest inside a
    -- progress modal that is already closing.
    local dialogOk, dialogErr = LrTasks.pcall(function()
      afterProgressTeardown()
      ResultDialog.show(resultReport.rows, resultReport.stopTitle, resultReport.maybeChanged)
    end)
    if not dialogOk and bodyOk then bodyOk, bodyErr = dialogOk, dialogErr end
  end
  if not bodyOk then
    -- Keep the lock through the wait so another run cannot open its dialogs
    -- while this run's progress teardown or error alert is still pending.
    LrTasks.pcall(afterProgressTeardown)
    LrDialogs.message(LOC("$$$/BatchAutoStraighten/Text001=Batch Auto Straighten"), LOC("$$$/BatchAutoStraighten/Text060=Stopped due to an error.^n") .. tostring(bodyErr))
  end
  releaseLock()
end)
