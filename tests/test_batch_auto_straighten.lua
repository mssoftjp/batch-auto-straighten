--[[
  Behavioral tests for BatchAutoStraighten.lua and HelperLaunch.lua.
  Mocked Lightroom SDK. No framework. Lua 5.1.
]]

local function dirname(path)
  local dir = string.match(path, "^(.*)/[^/]+$")
  if dir == nil or dir == "" then
    return "."
  end
  return dir
end

local this = debug.getinfo(1, "S").source
if string.sub(this, 1, 1) == "@" then
  this = string.sub(this, 2)
end
local root = dirname(dirname(this))
local plugin = root .. "/src/lightroom"
local realDofile = dofile
local translations={}
for line in io.lines(plugin .. "/TranslatedStrings_ja.txt") do
  line=line:gsub("^\239\187\191", "")
  local value=assert(loadstring("return " .. line))()
  local key,text=value:match("^(.-)=(.*)$")
  translations[key]=text:gsub("%^n","\n")
end
function LOC(value)
  local key,text=value:match("^(.-)=(.*)$")
  return translations[key] or text:gsub("%^n","\n")
end

local failed = 0
local passed = 0

local function fail(msg)
  failed = failed + 1
  io.stderr:write("FAIL " .. msg .. "\n")
end

local function ok(cond, msg)
  if cond then
    passed = passed + 1
  else
    fail(msg)
  end
end

local function eq(a, b, msg)
  if a == b then
    passed = passed + 1
  else
    fail(string.format("%s: got %s expected %s", msg, tostring(a), tostring(b)))
  end
end

local function summaryOf(messages)
  for i = #messages, 1, -1 do
    local body = messages[i].body or ""
    local a, n, u, f, un = string.match(
      body,
      "補正済み (%d+) / 変更不要 (%d+) / スキップ (%d+) / 要確認 (%d+) / 未処理 (%d+)"
    )
    if a then
      return {
        applied = tonumber(a),
        noop = tonumber(n),
        skip = tonumber(u),
        fail = tonumber(f),
        unprocessed = tonumber(un),
        body = body,
        details = messages[i].details or "",
        title = messages[i].title,
      }
    end
  end
  return nil
end

local function loadChunk(path, env)
  local fn = assert(loadfile(path))
  setfenv(fn, env)
  return fn
end

local HorizonMath = realDofile(plugin .. "/HorizonMath.lua")
local GroupPlan = realDofile(plugin .. "/GroupPlan.lua")

eq(HorizonMath.targetStraighten(0.0, 3.125), -3.125, "math 0-3.125")
eq(HorizonMath.targetStraighten(2.0, 3.125), -1.125, "math 2-3.125")
eq(HorizonMath.targetStraighten(-1.0, -8.0), 7.0, "math -1--8")
eq(HorizonMath.targetStraighten(0.0, -3.0), 3.0, "math 0--3")
do
  local d, r = HorizonMath.classifyResidual(0.049)
  eq(d, "noop", "classify deadband decision")
  eq(r, "below_deadband", "classify deadband reason")
  d, r = HorizonMath.classifyResidual(0.05)
  eq(d, "apply", "classify image analysis threshold boundary")
  eq(r, "applied", "classify image analysis threshold reason")
  d, r = HorizonMath.classifyResidual(10.1)
  eq(d, "apply", "residual above ten degrees is evaluated against final-angle limits")
  eq(r, "applied", "finite residual remains a candidate")
  d, r = HorizonMath.classifyResidual(3.125)
  eq(d, "apply", "classify apply")
  eq(r, "applied", "classify apply reason")
  d, r = HorizonMath.classifyResidual(-8.0)
  eq(d, "apply", "classify -8")
  eq(r, "applied", "classify -8 reason")
  d, r = HorizonMath.classifyResidual(0 / 0)
  eq(d, "fail", "classify nan")
  eq(r, "non_finite", "classify nan reason")
  d, r = HorizonMath.classifyResidual(0.1, HorizonMath.IN_CAMERA_DATA_DEADBAND_DEG)
  eq(d, "apply", "camera classifier applies sub-quarter-degree residual")
  eq(r, "applied", "camera classifier sub-quarter-degree reason")
  d, r = HorizonMath.classifyResidual(0.005, HorizonMath.IN_CAMERA_DATA_DEADBAND_DEG)
  eq(d, "noop", "camera classifier ignores sub-UI-step residual")
end
ok(HorizonMath.inAllowedRange(-1, -45, 45), "range ok")
ok(not HorizonMath.inAllowedRange(-50, -45, 45), "range low")
ok(HorizonMath.isFiniteNumber(2.76), "finite 2.76")
ok(not HorizonMath.isFiniteNumber(0 / 0), "nan is not finite")
eq(HorizonMath.READBACK_EPS, 0.05, "independent readback eps")
eq(HorizonMath.VALUE_EPS, 0.01 + 1e-6, "shared value eps")

local function approx(a, b, msg)
  ok(type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-9, msg .. " got " .. tostring(a))
end
approx(HorizonMath.wrapToCardinal(2.5), 2.5, "wrap 2.5")
approx(HorizonMath.wrapToCardinal(92.3), 2.3, "wrap 92.3")
approx(HorizonMath.wrapToCardinal(87.7), -2.3, "wrap 87.7")
approx(HorizonMath.wrapToCardinal(0), 0, "wrap 0")
approx(HorizonMath.wrapToCardinal(90), 0, "wrap 90")
approx(HorizonMath.wrapToCardinal(-90), 0, "wrap -90")
approx(HorizonMath.wrapToCardinal(180), 0, "wrap 180")
approx(HorizonMath.wrapToCardinal(-180), 0, "wrap -180")
approx(HorizonMath.rollToUi(2.5, "Canon"), 2.5, "canon roll to UI")
approx(HorizonMath.rollToUi(2.5, "NIKON CORPORATION"), -2.5, "nikon sign")
ok(HorizonMath.rollToUi(0, "FUJIFILM") == nil, "fuji 0 unusable")
ok(HorizonMath.rollToUi(0 / 0, "Canon") == nil, "nan roll unusable")
approx(HorizonMath.residualFromRoll(2.5, "Canon", 0), -2.5, "residual at 0")
approx(HorizonMath.residualFromRoll(2.5, "Canon", 1), -1.5, "residual at 1")
approx(HorizonMath.targetStraighten(0, HorizonMath.residualFromRoll(2.5, "Canon", 0)), 2.5, "roll residual feeds targetStraighten")
approx(HorizonMath.targetStraighten(1, HorizonMath.residualFromRoll(2.5, "Canon", 1)), 2.5, "roll residual with current angle")
approx(HorizonMath.rollToUi(92.3, "Canon"), 2.3, "portrait remainder")

ok(GroupPlan.isRenderedExt("JPG"), "rendered JPG")
ok(GroupPlan.isRenderedExt("heic"), "rendered heic")
ok(GroupPlan.isRenderedExt("HIF"), "rendered HIF")
ok(not GroupPlan.isRenderedExt("CR2"), "CR2 not rendered")
ok(GroupPlan.isRawFormat("RAW"), "RAW format")
ok(GroupPlan.isRawFormat("DNG"), "DNG format")
ok(not GroupPlan.isRawFormat("JPEG"), "JPEG not raw format")

do
  local parent, stem, ext, leaf = GroupPlan.splitPath("/a/b/IMG_1.JPG")
  eq(parent, "/a/b", "split parent")
  eq(stem, "IMG_1", "split stem")
  eq(ext, "JPG", "split ext")
  eq(leaf, "IMG_1.JPG", "split leaf")
end

do
  local entries = {
    { id = "j", path = "/dir/IMG.jpg", fileFormat = "JPEG", ext = "jpg" },
    { id = "r", path = "/dir/IMG.CR2", fileFormat = "RAW", ext = "CR2" },
  }
  local groups = GroupPlan.plan(entries, "matchRendered", "r")
  eq(#groups, 1, "jpg+raw one group")
  ok(groups[1].shared == true, "jpg+raw shared")
  eq(groups[1].reference.id, "j", "rendered prefers jpeg over active raw")
  local jobs = GroupPlan.jobs(groups)
  eq(jobs[1].role, "reference", "reference first")
  eq(jobs[1].entry.id, "j", "jpeg processed first")
  eq(jobs[2].entry.id, "r", "raw follows")
end

do
  local entries = {
    { id = "r", path = "/dir/IMG.CR2", fileFormat = "RAW", ext = "CR2" },
    { id = "j", path = "/dir/IMG.jpg", fileFormat = "JPEG", ext = "jpg" },
  }
  local groups = GroupPlan.plan(entries, "matchRendered", "r")
  eq(groups[1].reference.id, "j", "reversed selection still jpeg reference")
  groups = GroupPlan.plan(entries, "matchRaw", "j")
  eq(groups[1].reference.id, "r", "raw priority prefers raw over active jpeg")
end

do
  local entries = {
    { id = "h", path = "/dir/IMG.heic", fileFormat = "HEIF", ext = "heic" },
    { id = "d", path = "/dir/IMG.dng", fileFormat = "DNG", ext = "dng" },
  }
  local groups = GroupPlan.plan(entries, "matchRendered", "d")
  eq(groups[1].reference.id, "h", "heif preferred over dng")
  groups = GroupPlan.plan(entries, "matchRaw", "h")
  eq(groups[1].reference.id, "d", "dng preferred in raw mode")
end

do
  local entries = {
    { id = "b", path = "/dir/img.DNG", fileFormat = "DNG", ext = "DNG" },
    { id = "a", path = "/dir/img.CR2", fileFormat = "RAW", ext = "CR2" },
  }
  local groups = GroupPlan.plan(entries, "matchRendered", "b")
  eq(groups[1].reference.id, "b", "missing jpeg falls back to active still")
  groups = GroupPlan.plan(entries, "matchRendered", "missing")
  eq(groups[1].reference.id, "a", "missing jpeg without active uses path order")
end

do
  local entries = {
    { id = "1", path = "/a/img.jpg", fileFormat = "JPEG", ext = "jpg" },
    { id = "2", path = "/b/img.CR2", fileFormat = "RAW", ext = "CR2" },
  }
  local groups = GroupPlan.plan(entries, "matchRendered", "1")
  eq(#groups, 2, "different directories not grouped")
  eq(groups[1].shared, false, "dir a singleton")
  eq(groups[2].shared, false, "dir b singleton")
end

do
  local entries = {
    { id = "a", path = "/tmp/x\\y.JPG", fileFormat = "JPEG" },
    { id = "b", path = "/tmp/x/y.ARW", fileFormat = "RAW" },
  }
  local groups = GroupPlan.plan(entries, GroupPlan.MODE_RENDERED, nil)
  eq(#groups, 2, "backslash filename different parent group count")
  eq(groups[1].shared, false, "backslash filename stays ungrouped")
  eq(groups[2].shared, false, "slash child path stays ungrouped")
end

do
  local entries = {
    { id = "1", path = "/dir/only.jpg", fileFormat = "JPEG", ext = "jpg" },
  }
  local groups = GroupPlan.plan(entries, "matchRendered", "1")
  eq(groups[1].shared, false, "singleton stays individual")
end

do
  local entries = {
    { id = "1", path = "/dir/IMG.jpg", fileFormat = "JPEG", ext = "jpg" },
    { id = "2", path = "/dir/IMG.CR2", fileFormat = "RAW", ext = "CR2" },
  }
  local groups = GroupPlan.plan(entries, "individual", "1")
  eq(#groups, 2, "individual mode does not group")
  eq(groups[1].shared, false, "individual first")
  eq(groups[2].shared, false, "individual second")
end

local function collectText(node, acc)
  if type(node) ~= "table" then
    return
  end
  if type(node.title) == "string" then
    acc[#acc + 1] = node.title
  end
  if node.items then collectText(node.items, acc) end
  for i = 1, #node do
    collectText(node[i], acc)
  end
end

local function viewHasType(node, name)
  if type(node) ~= "table" then
    return false
  end
  if node._type == name then
    return true
  end
  for i = 1, #node do
    if viewHasType(node[i], name) then
      return true
    end
  end
  return false
end

local function extractDialogTexts(contents)
  local summaryParts = {}
  local detailParts = {}
  local function walk(node, inScroll)
    if type(node) ~= "table" then
      return
    end
    local nowScroll = inScroll or node._type == "scrolled_view"
    if type(node.title) == "string" then
      if nowScroll then
        detailParts[#detailParts + 1] = node.title
      else
        summaryParts[#summaryParts + 1] = node.title
      end
    end
    for i = 1, #node do
      walk(node[i], nowScroll)
    end
  end
  walk(contents, false)
  return table.concat(summaryParts, "\n"), table.concat(detailParts, "\n")
end

local function makeViewFactory()
  local factory = {}
  local function makeView(name, spec)
    if name == "tab_view_item" then assert(type(spec.identifier)=="string", "SDK tab requires identifier") end
    if spec == factory or type(spec) ~= "table" then
      return { _type = name }
    end
    spec._type = name
    return spec
  end
  setmetatable(factory, {
    __index = function(_, name)
      return function(_, spec)
        return makeView(name, spec)
      end
    end,
  })
  return factory
end

local function run(opts)
  opts = opts or {}
  local n = opts.n or 2
  local moduleName = opts.module or "develop"
  local ctx
  local thumbnailModules = {}
  local helperModules = {}
  local getValueEvents = {}
  local photos = {}
  local settings = { Exposure2012 = 0, Contrast2012 = 0, CropAngle = 0 }
  local function makePhoto(spec, i)
    spec = spec or {}
    local angle = opts.startAngle or 0
    if spec.angle ~= nil then
      angle = spec.angle
    end
    local photo = {
      localIdentifier = spec.localIdentifier or i,
      angle = angle,
      savedAngle = angle,
      path = spec.path or "/fake.jpg",
      fileFormat = spec.fileFormat or "JPEG",
      settings = spec.settings or settings,
    }
    if opts.direct then
      local copy={CropLeft=0,CropTop=0,CropRight=1,CropBottom=1,orientation="AB"}
      for k,v in pairs(photo.settings) do copy[k]=v end
      photo.settings=copy
      photo.dimensions=spec.dimensions or {width=6000,height=4000}
      function photo:applyDevelopSettings(frame)
        if opts.onDirectWrite then opts.onDirectWrite(self,frame,ctx) end
        if opts.directFails then error("direct SDK write failed") end
        self.directWrites=(self.directWrites or 0)+1
        if not opts.directIgnores then
          for k,v in pairs(frame) do self.settings[k]=v end
          self.savedAngle=-frame.CropAngle;self.angle=self.savedAngle
        end
      end
    end
    photo.pickStatus, photo.colorNameForLabel = spec.pickStatus or 0, spec.colorNameForLabel or "none"
    function photo:setRawMetadata(key,value)
      self[key] = value
      if opts.onMark then opts.onMark(self,key,value,ctx) end
    end
    photo.fileName = spec.fileName or string.match(photo.path, "([^/\\]+)$") or photo.path
    function photo:getRawMetadata(key)
      if key == "uuid" then
        return spec.uuid or ("p" .. tostring(self.localIdentifier))
      elseif key == "fileFormat" then
        return self.fileFormat
      elseif key == "path" then
        return self.path
      elseif key == "isVideo" then
        return spec.isVideo == true
      end
      return self[key]
    end
    function photo:getFormattedMetadata(key)
      if key == "fileName" then
        return self.fileName
      end
      return nil
    end
    function photo:getDevelopSettings()
      if opts.onGetDevelopSettings then
        opts.onGetDevelopSettings(self, ctx)
      end
      local copy = {}
      for k, v in pairs(self.settings) do
        copy[k] = v
      end
      copy.CropAngle = -self.savedAngle
      return copy
    end
    function photo:requestJpegThumbnail(w, h, callback)
      thumbnailModules[#thumbnailModules + 1] = moduleName
      if opts.onThumbnail then
        opts.onThumbnail(ctx)
      end
      if opts.thumbnail then
        opts.thumbnail(self, w, h, callback)
        return {}
      end
      callback("jpeg")
      return {}
    end
    return photo
  end
  if opts.photos then
    n = #opts.photos
    for i = 1, n do
      photos[i] = makePhoto(opts.photos[i], i)
    end
  else
    for i = 1, n do
      photos[i] = makePhoto({}, i)
    end
  end

  local extraPhotos = {}
  if opts.extraPhotos then
    for i = 1, #opts.extraPhotos do
      extraPhotos[i] = makePhoto(opts.extraPhotos[i], 1000 + i)
    end
  end

  local userPhoto = { localIdentifier = 99, angle = opts.userAngle or 0, path = "/user.jpg", fileFormat = "JPEG", settings = settings }
  userPhoto.fileName = "user.jpg"
  function userPhoto:getRawMetadata(key)
    if key == "uuid" then
      return "user"
    end
    return nil
  end
  function userPhoto:getFormattedMetadata(key)
    if key == "fileName" then
      return self.fileName
    end
    return nil
  end
  function userPhoto:getDevelopSettings()
    local copy = {}
    for k, v in pairs(self.settings) do
      copy[k] = v
    end
    return copy
  end

  local active
  local selection
  if opts.noSelection then
    active = nil
    selection = photos
  else
    active = photos[opts.activeIndex or 1]
    selection = {}
    for i = 1, n do
      selection[i] = photos[i]
    end
  end

  local result = {
    confirms = 0,
    overwritten = 0,
    alreadyRunning = 0,
    noSelection = 0,
    prefs = opts.prefs or {},
    extraPhotos = extraPhotos,
  }
  local messages = {}
  local setValues = {}
  local selectToolEvents = {}
  local switchEvents = {}
  local setSelectedEvents = {}
  local progressDone = false
  local canceledAt = opts.canceledAt
  local portion = 0
  local tool = opts.tool or "loupe"
  local now = 1000
  local helperCalls = 0
  local env
  ctx = {
    settings = settings,
    userPhoto = userPhoto,
    photos = photos,
  }
  function ctx.moduleName() return moduleName end
  function ctx.activePhoto() return active end
  function ctx.setUser()
    active = userPhoto
    selection = { userPhoto }
  end
  function ctx.setModule(name)
    moduleName = name
  end
  function ctx.setTool(name) tool = name end
  function ctx.cancel() canceledAt = 0 end
  local hidden={}
  function ctx.hide(photo)
    hidden[photo]=true
    local kept={};for _,p in ipairs(selection) do if not hidden[p] then kept[#kept+1]=p end end
    selection=kept
    if hidden[active] then
      active=selection[1]
      if not active then for _,p in ipairs(photos) do if not hidden[p] then active=p;selection={p};break end end end
    end
  end

  local quickMembers = {}
  for _,i in ipairs(opts.quickMembers or {}) do quickMembers[photos[i]]=true end
  local quickCollection = {}
  function quickCollection:getName() return opts.quickName or "quick collection" end
  function quickCollection:getPhotos()
    if opts.onQuickRead then opts.onQuickRead(quickMembers,photos) end
    local list={};for p in pairs(quickMembers) do list[#list+1]=p end;return list
  end
  function quickCollection:addPhotos(ps)
    if opts.quickWriteFails then return end
    for _,p in ipairs(ps) do quickMembers[p]=true end
  end
  function quickCollection:removePhotos(ps)
    if opts.quickWriteFails then return end
    for _,p in ipairs(ps) do quickMembers[p]=nil;if opts.onQuickRemove then opts.onQuickRemove(p,ctx) end end
  end
  result.quickMembers=quickMembers
  local catalog = {}
  function catalog:getCollectionByLocalIdentifier(id)
    assert(id==2)
    if opts.quickMissing then return nil end
    return quickCollection
  end
  function catalog:withWriteAccessDo(name,fn,params)
    if opts.markTimeout then return "aborted" end
    fn()
    return "executed"
  end
  function catalog:getTargetPhoto()
    return active
  end
  function catalog:getTargetPhotos()
    if opts.onGetTargetPhotos then
      local override = opts.onGetTargetPhotos(selection, ctx)
      if override then return override end
    end
    return selection
  end
  function catalog:setSelectedPhotos(p, ps)
    setSelectedEvents[#setSelectedEvents + 1] = { active = p, count = ps and #ps or 0, module=moduleName }
    if opts.selectionSetError then error("setSelectedPhotos failed") end
    if opts.restoreSelectionError and ps and #ps > 1 then error("restore selection failed") end
    if opts.ignoreSelectionSet then return end
    if active == userPhoto or (selection and #selection == 1 and selection[1] == userPhoto) then
      result.overwritten = result.overwritten + 1
    end
    if active and active ~= p and active.pendingAngle ~= nil then
      active.angle = active.savedAngle
      active.pendingAngle = nil
    end
    local visible={};for _,photo in ipairs(ps or {}) do if not hidden[photo] then visible[#visible+1]=photo end end
    active = hidden[p] and visible[1] or p
    selection = visible
    if opts.onSelectionSet then opts.onSelectionSet(p, ps, ctx) end
  end

  local function execute()
    local fn = loadChunk(plugin .. "/BatchAutoStraighten.lua", env)
    fn()
  end

  function ctx.reenter() execute() end

  local imports = {
    LrLocalization = {currentLanguage=function() return opts.language or "ja" end},
    LrApplication = {
      activeCatalog = function()
        return catalog
      end,
    },
    LrApplicationView = {
      switchToModule = function(name)
        switchEvents[#switchEvents + 1] = name
        if not opts.ignoreSwitch then
          moduleName = name
        end
        if opts.onSwitch then opts.onSwitch(name, ctx) end
      end,
      getCurrentModuleName = function()
        return moduleName
      end,
    },
    LrDate = {
      currentTime = function()
        now = now + (opts.clockStep or 0.5)
        return now
      end,
    },
    LrDevelopController = {
      selectTool = function(name)
        selectToolEvents[#selectToolEvents + 1] = { tool = name, module = moduleName }
        if moduleName ~= "develop" then
          error("selectTool before Develop loaded")
        end
        tool = name
      end,
      getSelectedTool = function()
        return tool
      end,
      getValue = function(key)
        local value = nil
        if key == "straightenAngle" then
          if active and active.angle ~= nil then
            value = active.angle
          else
            value = 0
          end
        end
        if opts.onGetValue then value = opts.onGetValue(key, value, ctx) end
        getValueEvents[#getValueEvents + 1] = {
          key = key,
          module = moduleName,
          value = value,
        }
        return value
      end,
      setValue = function(key, value)
        setValues[#setValues + 1] = {
          key = key,
          value = value,
          module = moduleName,
          id = active and active:getRawMetadata("uuid") or nil,
        }
        if opts.dropSetValue and opts.dropSetValue(#setValues,ctx) then return end
        if opts.dropFirstSetValue and #setValues == 1 then
          return
        end
        if active then
          active.angle = value
          active.pendingAngle = value
        end
        if opts.onSetValue then
          opts.onSetValue(key, value, ctx)
        end
      end,
      stopTracking = function()
        if opts.onStopTracking then opts.onStopTracking(active, ctx) end
        if active and active.pendingAngle ~= nil and not opts.deferPersistence then
          active.savedAngle = active.angle
          active.pendingAngle = nil
        end
      end,
      resetCrop = function()
        result.resets = (result.resets or 0) + 1
        if opts.dropReset and opts.dropReset(result.resets,ctx) then return end
        active.angle, active.savedAngle = 0, 0
        local cropSettings = {}
        for k,v in pairs(active.settings) do cropSettings[k]=v end
        active.settings = cropSettings
        cropSettings.CropLeft, cropSettings.CropTop = 0, 0
        cropSettings.CropRight, cropSettings.CropBottom = 1, 1
        cropSettings.CropConstrainAspectRatio = nil
        if opts.onReset then opts.onReset(ctx) end
      end,
      getRange = function()
        return -45, 45
      end,
    },
    LrDialogs = {
      showModalProgressDialog = function(info)
        result.progressContexts=result.progressContexts or {}
        ok(not result.progressContexts[info.functionContext],"one SDK modal per run; do not reopen after cancellation")
        result.progressContexts[info.functionContext]=true
        result.progressInfo = info
        result.progressVisible = true
        result.teardownWaited = false
        progressDone = false
        return {
          setPortionComplete = function(_, done) portion = done end,
          isCanceled = function()
            local canceled = canceledAt ~= nil and portion >= canceledAt
            -- Lightroom closes the progress modal as soon as Cancel is pressed.
            if canceled then result.progressVisible = false end
            return canceled
          end,
          setCaption = function(_, caption)
            result.captions=result.captions or {};result.captions[#result.captions+1]=caption
          end,
          done = function() progressDone = true end,
        }
      end,
      confirm = function()
        error("LrDialogs.confirm is not used")
      end,
      stopModalWithResult = function(_, sdkResult)
        result.stoppedModalResult = sdkResult
      end,
      presentModalDialog = function(info)
        info = info or {}
        if info.actionVerb == "角度を補正" or info.actionVerb == "Straighten Photos" then
          result.confirms = result.confirms + 1
          result.startInfo = info
          if opts.reenterOnConfirm then
            execute()
          end
          if opts.confirm then
            return opts.confirm
          end
          if result.lastProps then
            result.lastProps.sameNameMode = opts.sameNameMode or opts.mode or "individual"
            result.lastProps.adjustedPhotoAction = "reset"
            result.lastProps.tiltSource = "imageAnalysis"
            result.lastProps.overLimitAction = "skip"
            for k,v in pairs(opts.options or {}) do result.lastProps[k] = v end
          end
          return "ok"
        end
        if info.title == "角度が上限を超えています" or info.title == "Angle Exceeds Limit" then
          result.reviews = (result.reviews or 0) + 1
          result.reviewInfo = info
          if opts.onReview then opts.onReview(ctx) end
          if opts.reviewFail then error("test native review failure") end
          local action = opts.reviewAction or "apply"
          if action == "close" then return nil end
          if action == "cancel_result" then return "cancel" end
          if action == "skip" then return "ok" end
          local buttonIndex = ({stop=1,apply_all_remaining=2,skip_all_remaining=3,apply=5})[action]
          assert(buttonIndex, "unknown test review action: " .. tostring(action))
          local button = info.accessoryView[buttonIndex]
          button.action(button)
          local sdkResult = result.stoppedModalResult
          result.stoppedModalResult = nil
          return sdkResult
        end
        local summaryText, detailsText = extractDialogTexts(info.contents)
        messages[#messages + 1] = {
          title = info.title or "",
          body = summaryText,
          details = detailsText,
        }
        result.resultInfo = info
        return "ok"
      end,
      message = function(title, body)
        if result.progressInfo and result.progressInfo.functionContext.completed then
          eq(result.teardownWaited, true, "message waits for progress teardown")
        end
        messages[#messages + 1] = { title = title, body = body or "" }
      end,
    },
    LrView = {
      osFactory = makeViewFactory,
      bind = function(key)
        if type(key) == "table" then
          return key
        end
        return { bind = key }
      end,
    },
    LrBinding = {
      makePropertyTable = function()
        result.lastProps = { mode = "individual", addObserver = function() end }
        return result.lastProps
      end,
    },
    LrPrefs = {
      prefsForPlugin = function()
        return result.prefs
      end,
    },
    LrFileUtils = {
      createAllDirectories = function() if opts.tempThrows then error("mkdir failed") end end,
      exists = function()
        if opts.tempMissing then return false end
        return true
      end,
      delete = function() if opts.onCleanup then opts.onCleanup(ctx) end end,
    },
    LrPathUtils = {
      getStandardFilePath = function()
        return "/tmp"
      end,
      child = function(a, b)
        return tostring(a) .. "/" .. tostring(b)
      end,
    },
    LrTasks = {
      startAsyncTask = function(f)
        f()
      end,
      sleep = function(s)
        now = now + (s or 0)
        if progressDone and result.progressInfo.functionContext.completed then result.progressVisible=false end
        if result.progressInfo and result.progressInfo.functionContext.completed and (s or 0) >= 0.5 then
          result.teardownWaited = true
        end
        if opts.onSleep then opts.onSleep(s, ctx) end
      end,
      pcall = pcall,
      execute = function()
        error("product HelperLaunch should be mocked in plugin tests")
      end,
    },
    LrFunctionContext = {
      callWithContext = function(_, f)
        local handlers = {}
        local ctx = {
          addCleanupHandler = function(_, h)
            handlers[#handlers + 1] = h
          end,
        }
        local cok, cerr = pcall(f, ctx)
        for i = #handlers, 1, -1 do
          pcall(handlers[i])
        end
        ctx.completed = true
        if not cok then
          error(cerr)
        end
      end,
      postAsyncTaskWithContext = function(name, f)
        -- Cleanup handlers run as in the SDK; errors still surface in tests.
        env.import("LrFunctionContext").callWithContext(name, f)
      end,
    },
  }

  local fs = {}
  local fakeIO = {
    open = function(path, mode)
      mode = mode or "r"
      if opts.diagnosticWriteFails and path:find("batch-auto-straighten-last-run.json",1,true) then return nil end
      if string.find(mode, "w", 1, true) then
        fs[path] = ""
        return {
          write = function(_, data)
            fs[path] = (fs[path] or "") .. tostring(data)
            return true
          end,
          close = function() end,
        }
      end
      local data = fs[path]
      if data == nil then
        return nil
      end
      return {
        read = function()
          return data
        end,
        close = function() end,
      }
    end,
  }

  env = {
    _PLUGIN = { path = plugin },
    WIN_ENV = false,
    io = fakeIO,
    import = function(name)
      local mod = imports[name]
      assert(mod, "missing import " .. tostring(name))
      return mod
    end,
  }
  env._G = env
  setmetatable(env, { __index = _G })

  env.dofile = function(path)
    if path:match('SaveCheckpoint%.lua$') then
      return {crop=function(settings)
        local crop={};for k,v in pairs(settings) do if k:match('^Crop') then crop[k]=v end end;return crop
      end,open=function()
        local checkpoint={}
        function checkpoint:begin(photo,name,before,target,frame,reset)
          if opts.checkpointBeginFails then error('checkpoint write failed') end
          self.record={state='pending',uuid=photo:getRawMetadata('uuid'),before=before,target=target,frame=frame,reset=reset}
          result.checkpointBegins=(result.checkpointBegins or 0)+1
          if opts.onCheckpoint then opts.onCheckpoint(ctx) end
        end
        function checkpoint:complete(settings)
          if opts.checkpointCompleteFails then error('checkpoint close failed') end
          self.record.state='complete';self.record.after=settings
          result.checkpointCompletes=(result.checkpointCompletes or 0)+1
        end
        function checkpoint:clear() self.record={state='clear'} end
        result.checkpoint=checkpoint;return checkpoint
      end}
    end
    if path:match('RecoveryDialog%.lua$') then return {check=function()return opts.recoveryAllowed~=false end} end
    if string.match(path, "HelperLaunch%.lua$") then
      return {
        isBlockedError = function(err)
          return err == "macOS blocked a helper"
        end,
        blockedMessage = function()
          return "macOS blocked a helper"
        end,
        preview = function(imagePath, outputPath, degrees)
          result.previewDegrees = degrees
          if opts.onPreview then opts.onPreview(ctx) end
          return opts.previewOk ~= false
        end,
        run = function(id, jpegPath, outputPath, originalPath, tiltSource)
          helperCalls = helperCalls + 1
          helperModules[#helperModules + 1] = moduleName
          result.lastOriginal = originalPath
          result.lastTiltSource = tiltSource
          if opts.onHelper then
            opts.onHelper(id, ctx)
          end
          if opts.reenterOnHelper and helperCalls == 1 then
            execute()
          end
          local spec = { ok = true, kind = "horizon", degrees = 3 }
          if opts.helper then
            spec = opts.helper(id) or spec
          end
          if spec.ok == false then
            return false, spec.err or "test helper failure"
          end
          local body
          if spec.kind == "none" then
            body = string.format(
              '{"schema":"batch-auto-straighten.horizon.v2","id":"%s","kind":"none"}',
              id
            )
          elseif spec.kind == "error" then
            body = string.format(
              '{"schema":"batch-auto-straighten.horizon.v2","id":"%s","kind":"error","detail":"x"}',
              id
            )
          elseif spec.roll_only then
            body = string.format(
              '{"schema":"batch-auto-straighten.horizon.v2","id":"%s","kind":"horizon","roll_degrees":%s,"make":"%s"}',
              id,
              tostring(spec.roll_degrees),
              spec.make or "Canon"
            )
          else
            local extra = ""
            if spec.roll_degrees ~= nil then
              extra = string.format(',"roll_degrees":%s,"make":"%s"', tostring(spec.roll_degrees), spec.make or "Canon")
            end
            body = string.format(
              '{"schema":"batch-auto-straighten.horizon.v2","id":"%s","kind":"horizon","residual_degrees":%s%s}',
              id,
              tostring(spec.degrees or 3),
              extra
            )
          end
          local codec=realDofile(plugin .. "/dkjson.lua")
          if tiltSource == "inCameraData" then
            local payload=assert(codec.decode(body));payload.source="camera_roll"
            if not payload.roll_degrees then payload.kind="none" end
            body=codec.encode(payload)
          end
          if tiltSource == "imageAnalysis" and not spec.wrongSource then
            local codec=realDofile(plugin .. "/dkjson.lua")
            local payload=assert(codec.decode(body))
            payload.source="image_analysis"
            payload.model_id="image-analysis-test"
            payload.correction_degrees=(opts.options and opts.options.tiltSource=="imageAnalysis" and not opts.imageAngleIsResidual) and (spec.degrees or 0) or -(spec.degrees or 3)
            payload.residual_degrees=nil
            body=codec.encode(payload)
          end
          fs[outputPath] = opts.rawHelper and opts.rawHelper(id,tiltSource) or body
          return true
        end,
      }
    end
    if string.match(path, "SkipRules%.lua$") then
      return {
        isVideo = function()
          return opts.isVideo == true
        end,
        missingOriginal = function()
          return opts.missingOriginal == true
        end,
      }
    end
    if string.match(path, "ResultDialog%.lua$") then
      local dialog=loadChunk(path,env)()
      local show=dialog.show
      dialog.show=function(rows,stopTitle,maybeChanged)
        -- Keep behavioral assertions on the complete report data, independently
        -- of the compact user-facing table. The production path writes this
        -- detail to its local diagnostic record before opening the dialog.
        if result.progressVisible then
          -- Results nest inside the live progress modal, like ReviewDialog.
          eq(progressDone, false, "results open before progress is done")
          result.resultNested = true
        else
          -- Cancel or cleanup-handler path: the modal is already closing.
          eq(result.progressInfo.functionContext.completed, true, "deferred results open after progress scope")
          eq(result.teardownWaited, true, "deferred results wait for progress teardown")
        end
        result.resultDialogs = (result.resultDialogs or 0) + 1
        if opts.resultDialogError then error("test result dialog failure") end
        local codec=realDofile(plugin .. "/dkjson.lua")
        local diagnosticText=fs["/tmp/batch-auto-straighten-last-run.json"]
        local diagnostic=diagnosticText and assert(codec.decode(diagnosticText)) or nil
        if not diagnostic then
          local counts={applied=0,noop=0,skip=0,fail=0,unprocessed=0}
          for _,row in ipairs(rows) do counts[row.status]=(counts[row.status] or 0)+1 end
          diagnostic={summary=string.format(
            "補正済み %d / 変更不要 %d / スキップ %d / 要確認 %d / 未処理 %d",
            counts.applied,counts.noop,counts.skip,counts.fail,counts.unprocessed),details=""}
        end
        result.report={title=stopTitle,body=diagnostic.summary,details=diagnostic.details,rows=rows}
        return show(rows,stopTitle,maybeChanged)
      end
      return dialog
    end
    if string.match(path,"Localization%.lua$") then return loadChunk(path,setmetatable({io=io},{__index=env}))() end
    if path:match("CropControl%.lua$") or path:match("HelperProtocol%.lua$") or path:match("RunReport%.lua$") or path:match("PhotoMarks%.lua$") then return loadChunk(path,env)() end
    if string.match(path, "StartDialog%.lua$") or string.match(path, "ReviewDialog%.lua$") then return loadChunk(path,env)() end
    return realDofile(path)
  end

  execute()

  for _, msg in ipairs(messages) do
    if string.find(msg.body, "すでに処理中", 1, true) or string.find(msg.title, "すでに処理中", 1, true) then
      result.alreadyRunning = result.alreadyRunning + 1
    end
    if string.find(msg.body, "写真を選択してから", 1, true) or string.find(msg.title, "写真を選択してから", 1, true) then
      result.noSelection = result.noSelection + 1
    end
  end

  result.messages = messages
  result.diagnostics = fs["/tmp/batch-auto-straighten-last-run.json"]
  result.setValues = setValues
  result.selectToolEvents = selectToolEvents
  result.switchEvents = switchEvents
  result.setSelectedEvents = setSelectedEvents
  result.thumbnailModules = thumbnailModules
  result.helperModules = helperModules
  result.getValueEvents = getValueEvents
  result.progressDone = progressDone
  result.helperCalls = helperCalls
  result.running = env.BatchAutoStraightenShared and env.BatchAutoStraightenShared.running
  result.shared = env.BatchAutoStraightenShared
  result.env = env
  result.execute = execute
  result.summary = result.report and summaryOf({result.report}) or summaryOf(messages)
  result.settings = settings
  result.photos = photos
  result.userPhoto = userPhoto
  result.extraPhotos = extraPhotos
  result.moduleName = function()
    return moduleName
  end
  result.setUser = ctx.setUser
  return result
end

-- 1. No active target: filmstrip must not be treated as a selection.
do
  local r = run({ n = 2, noSelection = true })
  eq(r.confirms, 0, "no_selection confirmations")
  eq(r.noSelection, 1, "no_selection message")
  eq(#r.setValues, 0, "no_selection setValue")
  eq(r.running, false, "no_selection lock released")
end

-- 2. Reentry during confirmation must not start a second run.
do
  local r = run({ n = 2, reenterOnConfirm = true, helper = function()
    return { ok = false }
  end })
  eq(r.confirms, 1, "reentry_confirm confirmations")
  eq(r.alreadyRunning, 1, "reentry_confirm already-running message")
  eq(r.running, false, "reentry_confirm lock released")
end

-- 3. Reentry during helper (Codex repro path).
do
  local r = run({ n = 2, reenterOnHelper = true, helper = function()
    return { ok = false }
  end })
  eq(r.confirms, 1, "reentry_helper confirmations")
  eq(r.alreadyRunning, 1, "reentry_helper already-running message")
  eq(r.running, false, "reentry_helper lock released")
end

-- 4. Selection conflict on helper error: do not overwrite the user's photos.
do
  local r = run({
    n = 2,
    helper = function()
      return { ok = false }
    end,
    onHelper = function(_, ctx)
      ctx.setUser()
    end,
  })
  eq(r.confirms, 1, "conflict_error confirmations")
  eq(r.overwritten, 0, "conflict_error overwritten_user_selection")
  ok(r.summary ~= nil, "conflict_error has summary")
  if r.summary then
    eq(r.summary.fail, 1, "conflict_error fail count")
    eq(r.summary.unprocessed, 1, "conflict_error unprocessed count")
  end
  eq(#r.setValues, 0, "conflict_error no apply")
  eq(r.running, false, "conflict_error lock released")
end

-- 5. Selection conflict on skip/noop path.
do
  local r = run({
    n = 2,
    helper = function()
      return { ok = true, kind = "none" }
    end,
    onHelper = function(_, ctx)
      ctx.setUser()
    end,
  })
  eq(r.overwritten, 0, "conflict_skip overwritten_user_selection")
  eq(#r.setValues, 0, "conflict_skip no apply")
  if r.summary then
    eq(r.summary.unprocessed, 2, "conflict_skip remaining unprocessed")
  end
end

do
  local r = run({
    n = 2,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 0.049 }
    end,
    onHelper = function(_, ctx)
      ctx.setUser()
    end,
  })
  eq(r.overwritten, 0, "conflict_noop overwritten_user_selection")
  eq(#r.setValues, 0, "conflict_noop no apply")
end

-- 6. Readback must not count another photo's matching angle as success.
do
  local r = run({
    n = 2,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
    onSetValue = function(_, value, ctx)
      ctx.userPhoto.angle = value
      ctx.setUser()
    end,
  })
  eq(r.overwritten, 0, "conflict_readback overwritten_user_selection")
  eq(#r.setValues, 1, "conflict_readback one apply attempt")
  ok(r.summary ~= nil, "conflict_readback has summary")
  if r.summary then
    eq(r.summary.applied, 0, "conflict_readback not applied")
    eq(r.summary.fail, 1, "conflict_readback fail")
    eq(r.summary.unprocessed, 1, "conflict_readback unprocessed")
    ok(string.find(r.summary.body, "変更済みの可能性", 1, true) ~= nil, "conflict_readback maybeChanged")
  end
end

-- 7. Settings conflict snapshots the whole develop table, not a whitelist.
do
  local r = run({
    n = 2,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
    onHelper = function(_, ctx)
      ctx.settings.Contrast2012 = 40
    end,
  })
  eq(#r.setValues, 0, "settings_conflict no apply")
  eq(r.overwritten, 0, "settings_conflict no user overwrite")
  ok(r.summary ~= nil, "settings_conflict has summary")
  if r.summary then
    eq(r.summary.applied, 0, "settings_conflict applied")
    eq(r.summary.unprocessed, 2, "settings_conflict unprocessed")
    ok(string.find(r.summary.body, "settings_changed", 1, true) ~= nil, "settings_conflict reason")
  end
  eq(r.progressDone, true, "settings_conflict progress done")
  eq(r.running, false, "settings_conflict lock released")
end

-- 8. Cancellation marks remaining and still cleans up.
do
  local r = run({
    n = 3,
    canceledAt = 1,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
  })
  eq(r.progressDone, true, "cancel progress done")
  eq(r.running, false, "cancel lock released")
  ok(r.summary ~= nil, "cancel has summary")
  if r.summary then
    eq(r.summary.applied, 1, "cancel applied first")
    eq(r.summary.unprocessed, 2, "cancel remaining")
    ok(string.find(r.summary.body, "canceled", 1, true) ~= nil, "cancel reason")
  end
end

-- 9. Exception during snapshot still restores (if owned), counts remaining, releases lock.
do
  local r = run({
    n = 2,
    onGetDevelopSettings = function()
      error("sdk boom")
    end,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
  })
  eq(r.progressDone, true, "exception progress done")
  eq(r.running, false, "exception lock released")
  eq(#r.setValues, 0, "exception no apply")
  ok(r.summary ~= nil, "exception has summary")
  if r.summary then
    eq(r.summary.fail, 1, "exception fail current")
    eq(r.summary.unprocessed, 1, "exception remaining")
  end
  local restored = false
  for _, ev in ipairs(r.setSelectedEvents) do
    if ev.count == 2 then
      restored = true
    end
  end
  ok(restored or #r.setSelectedEvents==0, "exception preserves initial selection")
end

-- 10. setValue exception is a partial change and stops the batch.
do
  local r = run({
    n = 2,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
    onSetValue = function()
      error("setValue boom")
    end,
  })
  eq(#r.setValues, 1, "apply_exception attempted once")
  ok(r.summary ~= nil, "apply_exception has summary")
  if r.summary then
    eq(r.summary.fail, 1, "apply_exception fail")
    eq(r.summary.unprocessed, 1, "apply_exception remaining")
    ok(string.find(r.summary.body, "変更済みの可能性", 1, true) ~= nil, "apply_exception maybeChanged")
    ok(string.find(r.summary.body, "apply_failed", 1, true) ~= nil, "apply_exception reason")
  end
  eq(r.running, false, "apply_exception lock released")
  eq(r.progressDone, true, "apply_exception progress done")
end

-- 11. Different estimated angles per photo; only straightenAngle is written.
do
  local r = run({
    n = 2,
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    helper = function(id)
      if id == "p1" then
        return { ok = true, kind = "horizon", degrees = 3 }
      end
      return { ok = true, kind = "horizon", degrees = -4 }
    end,
  })
  eq(#r.setValues, 2, "angles two writes")
  if #r.setValues == 2 then
    eq(r.setValues[1].key, "straightenAngle", "angles key 1")
    eq(r.setValues[2].key, "straightenAngle", "angles key 2")
    eq(r.setValues[1].id, "p1", "angles id 1")
    eq(r.setValues[2].id, "p2", "angles id 2")
    eq(r.setValues[1].value, -3, "angles p1 target = 0 - 3")
    eq(r.setValues[2].value, 4, "angles p2 target = 0 - (-4)")
    ok(r.setValues[1].value ~= r.setValues[2].value, "angles differ")
  end
  if r.summary then
    eq(r.summary.applied, 2, "angles applied")
  end
end

-- 12. selectTool is not called until Develop is the current module.
-- Apply-only Develop: helper succeeds so the plugin attempts the switch.
do
  local r = run({
    n = 1,
    module = "library",
    ignoreSwitch = true,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
  })
  eq(#r.selectToolEvents, 0, "selectTool not called while stuck in library")
  eq(#r.switchEvents, 1, "switchToModule attempted once")
  if r.summary then
    eq(r.summary.fail, 1, "not_ready when Develop never loads")
  end
  for _, ev in ipairs(r.selectToolEvents) do
    ok(ev.module == "develop", "selectTool module was develop")
  end
end

-- HelperLaunch: LrTasks.execute, exit status, no background jobs.
do
  local executed = {}
  local exist = {
    ["/plugin/bin/horizon-helper"] = true,
  }
  local hlEnv = {}
  hlEnv._PLUGIN = { path = "/plugin" }
  function hlEnv.import(name)
    if name == "LrFileUtils" then
      return {
        exists = function(path)
          return exist[path] == true
        end,
        delete = function(path)
          exist[path] = nil
        end,
      }
    elseif name == "LrPathUtils" then
      return {
        child = function(a, b)
          return tostring(a) .. "/" .. tostring(b)
        end,
      }
    elseif name == "LrTasks" then
      return {
        execute = function(cmd)
          executed[#executed + 1] = cmd
          local status = hlEnv.status
          if status == nil then
            status = 0
          end
          if status == 0 and hlEnv.writeOutput then
            exist[hlEnv.out] = true
          elseif hlEnv.writeOutputAlways then
            exist[hlEnv.out] = true
          end
          return status
        end,
      }
    end
    error("unexpected import " .. tostring(name))
  end
  setmetatable(hlEnv, { __index = _G })
  hlEnv.dofile=function(path) if path:match("Localization%.lua$") then return LOC end;return realDofile(path) end
  local HelperLaunch = loadChunk(plugin .. "/HelperLaunch.lua", hlEnv)()

  hlEnv.out = "/tmp/out.json"
  hlEnv.writeOutput = true
  hlEnv.status = 0
  local hok, herr = HelperLaunch.run("id1", "/tmp/in.jpg", hlEnv.out)
  ok(hok == true, "helper launch status 0 with output")
  eq(#executed, 1, "helper launch execute once")
  ok(executed[1] ~= nil and string.find(executed[1], "horizon%-helper", 1) ~= nil, "helper cmd contains binary")
  ok(executed[1] ~= nil and string.find(executed[1], " &") == nil, "helper cmd is not backgrounded")
  ok(string.find(executed[1], "|") == nil, "helper cmd has no pipe")
  ok(string.find(executed[1], "--original") == nil, "helper omits original when not passed")

  executed = {}
  exist[hlEnv.out] = true
  hlEnv.writeOutput = true
  hlEnv.status = 0
  hok, herr = HelperLaunch.run("id1", "/tmp/in.jpg", hlEnv.out, "/tmp/orig.CR3")
  ok(hok == true, "helper launch with original path")
  ok(string.find(executed[1], "--original", 1, true) ~= nil, "helper cmd includes original flag")
  ok(string.find(executed[1], "/tmp/orig.CR3", 1, true) ~= nil, "helper cmd includes original path")

  executed = {}
  exist[hlEnv.out] = nil
  hlEnv.writeOutput = false
  hlEnv.writeOutputAlways = true
  hlEnv.status = 12
  hok, herr = HelperLaunch.run("id1", "/tmp/in.jpg", hlEnv.out)
  ok(hok == false, "helper launch rejects non-zero status even with output file")
  ok(herr ~= nil and string.find(herr, "12", 1, true) ~= nil, "helper launch reports exit status")

  executed = {}
  exist[hlEnv.out] = nil
  hlEnv.writeOutputAlways = false
  hlEnv.writeOutput = false
  hlEnv.status = 0
  hok, herr = HelperLaunch.run("id1", "/tmp/in.jpg", hlEnv.out)
  ok(hok == false, "helper launch rejects missing output")
  ok(herr ~= nil and string.find(herr, "no output", 1, true) ~= nil, "helper launch missing output message")
  hlEnv.writeOutput=true
  exist["/plugin/bin/image-analysis-helper"]=true
  executed={}
  hok,herr=HelperLaunch.run("id1","/tmp/in ' photo.jpg",hlEnv.out,"/tmp/orig.CR3","imageAnalysis")
  ok(hok,"image-analysis helper launch succeeds")
  ok(executed[1]:find("image-analysis-helper",1,true),"image analysis uses dedicated binary")
  ok(not executed[1]:find("--original",1,true),"image analysis suppresses original even if passed")
  ok(not executed[1]:find("horizon-helper",1,true),"image analysis never invokes the in-camera helper")
  exist["/plugin/bin/image-analysis-helper"]=nil
  executed={}
  hok,herr=HelperLaunch.run("id1","/tmp/in.jpg",hlEnv.out,nil,"imageAnalysis")
  ok(not hok,"missing image-analysis binary fails")
  eq(#executed,0,"missing image-analysis binary does not fallback")

  exist["/plugin/bin/image-analysis-helper"]=true
  for _, source in ipairs({"inCameraData", "imageAnalysis"}) do
    for _, status in ipairs({9,126,137}) do
      executed={}
      exist[hlEnv.out]=nil
      hlEnv.writeOutput=false
      hlEnv.status=status
      hok,herr=HelperLaunch.run("id1","/tmp/in.jpg",hlEnv.out,nil,source)
      ok(not hok,"blocked helper fails")
      ok(HelperLaunch.isBlockedError(herr),"blocked helper uses the signed-release guidance")
      eq(#executed,1,"blocked helper does not clear quarantine or retry")
      ok(not executed[1]:find("xattr",1,true),"helper launch preserves macOS quarantine")
    end
  end
  executed={}
  ok(not HelperLaunch.preview("/tmp/in.jpg",hlEnv.out,1),"blocked preview fails")
  eq(#executed,1,"blocked preview does not clear quarantine or retry")

  executed={}
  hlEnv.status=12
  hok,herr=HelperLaunch.run("id1","/tmp/in.jpg",hlEnv.out)
  ok(not hok,"non-blocked failure is unchanged")
  ok(herr:find("12",1,true),"non-blocked failure keeps the exit status")
  eq(#executed,1,"non-blocked failure does not retry")

end

-- SDK thumbnail callback err text reaches the no_preview summary.
do
  local r = run({
    n = 1,
    thumbnail = function(_, _, _, callback)
      callback(nil, "sdk thumbnail boom")
    end,
  })
  ok(
    r.summary ~= nil and string.find(r.summary.body, "sdk thumbnail boom", 1, true) ~= nil,
    "no_preview summary includes nonempty SDK callback err"
  )
end

-- A blocked helper stops the batch after one instruction, and later photos stay unprocessed.
do
  local r=run{n=2,helper=function() return {ok=false,err="macOS blocked a helper"} end}
  eq(r.helperCalls,1,"blocked helper does not continue to the next photo")
  eq(r.summary.fail,1,"blocked helper fails the current photo")
  eq(r.summary.unprocessed,1,"blocked helper leaves later photos unprocessed")
  ok(string.find(r.summary.body,"helper_blocked",1,true),"blocked helper uses a dedicated reason")
end

-- Sequential run after completion can acquire the lock again.
do
  local r = run({
    n = 1,
    helper = function()
      return { ok = false }
    end,
  })
  eq(r.shared.running, false, "sequential first run released lock")
  local confirmsBefore = r.confirms
  r.execute()
  eq(r.confirms, confirmsBefore + 1, "sequential second run confirms")
  eq(r.shared.running, false, "sequential second run released lock")
end

-- Thumbnail and helper run in Library; straightenAngle read/write only in Develop.
do
  local r = run({
    n = 1,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
  })
  eq(#r.thumbnailModules, 1, "preview_library thumbnail count")
  eq(r.thumbnailModules[1], "library", "preview_library thumbnail module")
  eq(#r.helperModules, 1, "preview_library helper count")
  eq(r.helperModules[1], "library", "preview_library helper module")
  eq(#r.setValues, 1, "preview_library one apply")
  eq(r.setValues[1].module, "develop", "preview_library setValue module")
  ok(#r.getValueEvents > 0, "preview_library getValue used")
  local allDevelop = true
  for _, ev in ipairs(r.getValueEvents) do
    if ev.module ~= "develop" then
      allDevelop = false
    end
  end
  ok(allDevelop, "preview_library getValue only in develop")
  eq(#r.selectToolEvents, 1, "preview_library selectTool once")
  if #r.selectToolEvents > 0 then
    eq(r.selectToolEvents[1].module, "develop", "preview_library selectTool module")
  end
end

-- Existing UI angle is the current; target = current - image analysis residual.
do
  local r = run({
    n = 1,
    startAngle = 2.76,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
  })
  eq(#r.setValues, 1, "nonzero_start one write")
  if #r.setValues == 1 then
    eq(r.setValues[1].value, 2.76 - 3, "nonzero_start target = current - image analysis")
    eq(r.setValues[1].module, "develop", "nonzero_start setValue in develop")
  end
  if r.summary then
    eq(r.summary.applied, 1, "nonzero_start applied")
  end
end

-- User leaves Library during thumbnail: stop, do not switch back.
do
  local r = run({
    n = 2,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
    onThumbnail = function(ctx)
      ctx.setModule("develop")
    end,
  })
  eq(#r.setValues, 0, "thumb_module_change no apply")
  eq(r.overwritten, 0, "thumb_module_change no overwrite")
  eq(#r.helperModules, 0, "thumb_module_change no helper")
  eq(r.thumbnailModules[1], "library", "thumb_module_change requested in library")
  eq(r.switchEvents[#r.switchEvents], "library", "thumb_module_change last plugin switch is library")
  eq(r.moduleName(), "develop", "thumb_module_change leaves user module")
  if r.summary then
    eq(r.summary.unprocessed, 2, "thumb_module_change unprocessed")
    ok(string.find(r.summary.body, "module_changed", 1, true) ~= nil, "thumb_module_change reason")
  end
end

-- User leaves Library during helper: stop, do not switch back.
do
  local r = run({
    n = 2,
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
    onHelper = function(_, ctx)
      ctx.setModule("slideshow")
    end,
  })
  eq(#r.setValues, 0, "helper_module_change no apply")
  eq(r.overwritten, 0, "helper_module_change no overwrite")
  eq(r.helperModules[1], "library", "helper_module_change helper in library")
  eq(r.switchEvents[#r.switchEvents], "library", "helper_module_change last plugin switch is library")
  eq(r.moduleName(), "slideshow", "helper_module_change leaves user module")
  if r.summary then
    eq(r.summary.unprocessed, 2, "helper_module_change unprocessed")
    ok(string.find(r.summary.body, "module_changed", 1, true) ~= nil, "helper_module_change reason")
  end
end

local function restoredCount(r, count)
  for _, ev in ipairs(r.setSelectedEvents) do
    if ev.count == count then
      return true
    end
  end
  return false
end

-- Dialog cancel: no processing, lock released, settings not persisted.
do
  local prefs = { runOptions = { sameNameMode = "individual" } }
  local r = run({ n = 2, confirm = "cancel", mode = "matchRaw", prefs = prefs })
  eq(r.confirms, 1, "dialog_cancel confirmations")
  eq(#r.setValues, 0, "dialog_cancel no apply")
  eq(r.running, false, "dialog_cancel lock released")
  eq(r.summary, nil, "dialog_cancel no result summary")
  eq(prefs.runOptions.sameNameMode, "individual", "dialog_cancel does not persist settings")
  ok(r.startInfo ~= nil, "dialog_cancel has start dialog")
  local titles = {}
  collectText(r.startInfo.contents, titles)
  local blob = table.concat(titles, "\n")
  ok(string.find(blob, "選択中の写真：2枚", 1, true) ~= nil, "dialog_cancel shows count")
  ok(string.find(blob, "写真ごとに角度補正", 1, true) ~= nil, "dialog_cancel individual mode")
  ok(string.find(blob, "JPEG/HEIFに合わせる", 1, true) ~= nil, "dialog_cancel rendered mode")
  ok(string.find(blob, "RAW/DNGに合わせる", 1, true) ~= nil, "dialog_cancel raw mode")
  ok(string.find(blob, "撮影時の水準器情報を優先（試験的）", 1, true) ~= nil, "start dialog experimental capture-time tiltSource")
  ok(string.find(blob, "※ 撮影時の水準器情報：", 1, true) == nil, "start dialog omits camera-data footnote")
  ok(string.find(blob, "Apple Image analysis", 1, true) == nil, "start dialog removes Image analysis")
end

-- Mode is persisted only after OK, and result list is scrollable.
do
  local prefs = {}
  local r = run({
    n = 1,
    mode = "matchRendered",
    prefs = prefs,
    helper = function()
      return { ok = false }
    end,
  })
  eq(prefs.runOptions.sameNameMode, "matchRendered", "same-name mode persisted on ok")
  ok(r.summary ~= nil and string.find(r.summary.body, "JPEG/HEIFに合わせる", 1, true) ~= nil, "result shows mode")
  ok(r.resultInfo ~= nil and viewHasType(r.resultInfo.contents, "scrolled_view"), "result uses scrolled_view")
  local contents = r.resultInfo and r.resultInfo.contents
  ok(contents ~= nil and contents[1] ~= nil and contents[1]._type == "static_text", "result summary is static_text")
  ok(contents ~= nil and contents[#contents] ~= nil and contents[#contents]._type == "scrolled_view", "result details are scrolled_view")
  local summaryTitle = contents and contents[1] and contents[1].title or ""
  local scrollTitles = {}
  if contents and contents[#contents] then
    collectText(contents[#contents], scrollTitles)
  end
  local details = table.concat(scrollTitles, "\n")
  ok(string.find(summaryTitle, "fake.jpg", 1, true) == nil, "summary static_text does not list filename")
  ok(string.find(details, "fake.jpg", 1, true) ~= nil, "scrolled_view lists filename")
  ok(string.find(summaryTitle, "前=", 1, true) == nil, "summary static_text does not duplicate row details")
  ok(string.find(details, "傾きの解析を実行できませんでした", 1, true) ~= nil, "scrolled_view explains failure")
end

-- Individual mode: same-stem JPG/RAW keep different estimates.
do
  local r = run({
    mode = "individual",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 0 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 0 },
    },
    helper = function(id)
      if id == "p1" then
        return { ok = true, kind = "horizon", degrees = 3 }
      end
      return { ok = true, kind = "horizon", degrees = -4 }
    end,
  })
  eq(r.helperCalls, 2, "individual pair helper twice")
  eq(#r.setValues, 2, "individual pair two writes")
  if #r.setValues == 2 then
    eq(r.setValues[1].value, -3, "individual jpg target")
    eq(r.setValues[2].value, 4, "individual raw target")
    ok(r.setValues[1].value ~= r.setValues[2].value, "individual estimates differ")
  end
end

-- Rendered-priority JPG/RAW share the JPEG final UI angle.
do
  local r = run({
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 2 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5 },
    },
    helper = function(id)
      if id == "p1" then
        return { ok = true, kind = "horizon", degrees = 3 }
      end
      return { ok = true, kind = "horizon", degrees = 8 }
    end,
  })
  eq(r.helperCalls, 1, "rendered jpg/raw helper once")
  eq(#r.setValues, 2, "rendered jpg/raw two writes")
  if #r.setValues == 2 then
    eq(r.setValues[1].id, "p1", "rendered writes jpeg first")
    eq(r.setValues[2].id, "p2", "rendered writes raw follower")
    eq(r.setValues[1].value, 2 - 3, "rendered jpeg final = current - image analysis")
    eq(r.setValues[2].value, 2 - 3, "rendered raw shares jpeg final not residual")
    eq(r.setValues[1].key, "straightenAngle", "rendered key 1")
    eq(r.setValues[2].key, "straightenAngle", "rendered key 2")
  end
  ok(r.summary ~= nil and string.find(r.summary.details, "基準=IMG.jpg", 1, true) ~= nil, "rendered lists reference filename")
  ok(r.summary ~= nil and string.find(r.summary.body, "基準=IMG.jpg", 1, true) == nil, "reference filename stays in scroll area")
  if r.summary then
    eq(r.summary.applied, 2, "rendered jpg/raw applied")
  end
end

-- HEIF/RAW grouped common final target.
do
  local r = run({
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.heic", fileFormat = "HEIF", angle = 1.5 },
      { path = "/dir/IMG.dng", fileFormat = "DNG", angle = 4 },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = 2.5 }
    end,
  })
  eq(r.helperCalls, 1, "heif/raw helper once")
  eq(#r.setValues, 2, "heif/raw two writes")
  if #r.setValues == 2 then
    eq(r.setValues[1].id, "p1", "heif is reference")
    eq(r.setValues[1].value, 1.5 - 2.5, "heif final")
    eq(r.setValues[2].value, 1.5 - 2.5, "dng shares heif final")
  end
end

-- Reversed selection still uses JPEG for rendered, RAW for raw-priority.
do
  local r = run({
    mode = "matchRendered",
    activeIndex = 1,
    photos = {
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5 },
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 2 },
    },
    helper = function(id)
      if id == "p2" then
        return { ok = true, kind = "horizon", degrees = 3 }
      end
      return { ok = true, kind = "horizon", degrees = 9 }
    end,
  })
  eq(r.helperCalls, 1, "reversed rendered helper once")
  eq(#r.setValues, 2, "reversed rendered two writes")
  if #r.setValues == 2 then
    eq(r.setValues[1].id, "p2", "reversed rendered estimates jpeg")
    eq(r.setValues[2].id, "p1", "reversed rendered then raw")
    eq(r.setValues[1].value, -1, "reversed jpeg final")
    eq(r.setValues[2].value, -1, "reversed raw shares jpeg final")
  end
end

do
  local r = run({
    mode = "matchRaw",
    activeIndex = 2,
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 1 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5 },
    },
    helper = function(id)
      if id == "p2" then
        return { ok = true, kind = "horizon", degrees = 3 }
      end
      return { ok = true, kind = "horizon", degrees = 9 }
    end,
  })
  eq(r.helperCalls, 1, "raw-priority helper once")
  if #r.setValues == 2 then
    eq(r.setValues[1].id, "p2", "raw-priority estimates raw")
    eq(r.setValues[2].id, "p1", "raw-priority jpeg follows")
    eq(r.setValues[1].value, 5 - 3, "raw-priority raw final")
    eq(r.setValues[2].value, 5 - 3, "raw-priority jpeg shares raw final")
  else
    fail("raw-priority expected two writes")
  end
end

-- Same-name followers must match the confirmed angle, not READBACK_EPS 0.05.
do
  local r = run({
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 2.76 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 2.80 },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = 0.049 }
    end,
  })
  eq(#r.setValues, 2, "reprocessing resets reference and follower")
  if #r.setValues == 2 then
    eq(r.setValues[2].id, "p2", "near-aligned writes follower")
    eq(r.setValues[2].value, 2.76, "near-aligned shares confirmed 2.76")
  end
  eq(r.photos[2].angle, 2.76, "follower 2.80 becomes 2.76")
end

-- Reference SDK quantization: planned 3.125, confirmed 3.12, follower 3.16 -> 3.12.
do
  local r = run({
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 0 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 3.16 },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = -3.125 }
    end,
    onSetValue = function(key, value, ctx)
      if key == "straightenAngle" and math.abs(value - 3.125) <= 1e-12 then
        ctx.photos[1].angle = 3.12
      end
    end,
  })
  eq(#r.setValues, 2, "quantized reference two writes")
  if #r.setValues == 2 then
    eq(r.setValues[1].value, 3.125, "quantized planned arithmetic target")
    eq(r.setValues[2].value, 3.12, "follower receives confirmed 3.12")
    eq(r.setValues[1].key, "straightenAngle", "quantized key 1")
    eq(r.setValues[2].key, "straightenAngle", "quantized key 2")
  end
  eq(r.photos[1].angle, 3.12, "reference confirmed 3.12")
  eq(r.photos[2].angle, 3.12, "follower 3.16 becomes 3.12")
  if r.summary then
    eq(r.summary.applied, 2, "quantized pair applied")
    ok(string.find(r.summary.details, "後=3.12", 1, true) ~= nil, "confirmed after is 3.12")
    ok(string.find(r.summary.body, "後=3.12", 1, true) == nil, "confirmed after stays in scroll area")
  end
end

-- Off-target follower readback is not success.
do
  local r = run({
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 0 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 3.16 },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = -3.125 }
    end,
    onSetValue = function(key, value, ctx)
      if key ~= "straightenAngle" then
        return
      end
      if math.abs(value - 3.125) <= 1e-12 then
        ctx.photos[1].angle = 3.12
      else
        ctx.photos[2].angle = 3.16
      end
    end,
  })
  eq(#r.setValues, 2, "off-target follower attempted")
  if #r.setValues == 2 then
    eq(r.setValues[2].value, 3.12, "off-target follower wrote confirmed")
  end
  eq(r.photos[2].angle, 3.16, "off-target follower did not land")
  if r.summary then
    eq(r.summary.applied, 1, "off-target follower not applied")
    eq(r.summary.fail, 1, "off-target follower unconfirmed")
    ok(string.find(r.summary.body, "apply_unconfirmed", 1, true) ~= nil, "off-target follower reason")
  end
end

-- A readable but stale Crop control must not become a no-op reference angle.
for _, adjustedAction in ipairs({"skip", "reset"}) do
  local resets=0
  local r=run {
    sameNameMode="matchRaw",
    options={photoDisplayMode="openEachPhoto",adjustedPhotoAction=adjustedAction},
    photos={
      {path="/dir/IMG.ARW",fileFormat="RAW",angle=0},
      {path="/dir/IMG.HIF",fileFormat="HEIF",angle=0},
    },
    helper=function() return {kind="horizon",degrees=0} end,
    onGetValue=function(_,value,ctx)
      return ctx.activePhoto()==ctx.photos[1] and 2 or value
    end,
    onReset=function() resets=resets+1 end,
  }
  eq(#r.setValues,0,adjustedAction .. " stale no-op UI never writes either photo")
  eq(resets,0,adjustedAction .. " stale no-op UI never resets the reference crop")
  eq(r.photos[1].savedAngle,0,adjustedAction .. " stale no-op UI preserves reference")
  eq(r.photos[2].savedAngle,0,adjustedAction .. " stale no-op UI is not shared")
  eq(r.summary.noop,0,adjustedAction .. " stale no-op UI is not confirmed")
end

-- Normal UI rounding is allowed, but the shared angle comes from the catalog.
for _, direct in ipairs({false,true}) do
  local r=run {
    sameNameMode="matchRaw",direct=direct,
    options={adjustedPhotoAction="skip",processedFlagAction="pick"},
    photos={
      {path="/dir/IMG.ARW",fileFormat="RAW",angle=0},
      {path="/dir/IMG.HIF",fileFormat="HEIF",angle=0},
    },
    helper=function() return {kind="horizon",degrees=0} end,
    onGetValue=function(_,value,ctx)
      return ctx.activePhoto()==ctx.photos[1] and 0.005 or value
    end,
  }
  eq(r.summary.noop,2,"confirmed no-op pair stays unchanged")
  eq(#r.setValues,0,"confirmed no-op pair needs no UI write")
  eq(r.photos[1].directWrites,nil,"confirmed no-op reference needs no direct write")
  eq(r.photos[2].directWrites,nil,"confirmed no-op follower needs no direct write")
  eq(r.report.rows[1].after,0,"no-op reference reports the catalog angle")
  eq(r.photos[1].pickStatus,1,"confirmed no-op reference retains requested marks")
  eq(r.photos[2].pickStatus,1,"confirmed no-op follower retains requested marks")
end

-- A concurrent edit cannot be adopted as the no-op reference's new baseline.
do
  local reads,edited=0,false
  local r=run {
    sameNameMode="matchRaw",options={photoDisplayMode="openEachPhoto",adjustedPhotoAction="reset"},
    photos={
      {path="/dir/IMG.ARW",fileFormat="RAW",angle=0,settings={Exposure2012=0}},
      {path="/dir/IMG.HIF",fileFormat="HEIF",angle=2},
    },
    helper=function() return {kind="horizon",degrees=0} end,
    onGetValue=function(_,value,ctx)
      if ctx.activePhoto()==ctx.photos[1] then
        reads=reads+1
        -- The first two samples establish Crop-tool readiness. An SDK read
        -- can yield to an edit while the no-op reference is being confirmed.
        if reads==3 then ctx.photos[1].settings.Exposure2012=1;edited=true end
      end
      return value
    end,
  }
  ok(edited,"concurrent edit occurs while confirming no-op reference")
  eq(#r.setValues,0,"no-op reference never adopts a concurrent edit as its baseline")
  eq(r.photos[1].settings.Exposure2012,1,"no-op reference preserves concurrent edit")
  eq(r.photos[2].savedAngle,2,"changed no-op reference leaves follower untouched")
  eq(r.summary.unprocessed,1,"changed no-op reference stops before follower")
end

-- A confirmed nonzero reference retains the requested crop reset behavior.
do
  local r = run({
    mode = "matchRendered",
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 2 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5 },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = 0.049 }
    end,
  })
  eq(#r.setValues, 2, "reprocessing resets deadband reference before sharing")
  if #r.setValues == 2 then
    eq(r.setValues[2].id, "p2", "noop reference follower id")
    eq(r.setValues[2].value, 2, "noop reference shares current 2 not residual")
  end
  if r.summary then
    eq(r.summary.applied, 2, "reset reference and follower applied")
    eq(r.summary.noop, 0, "reset reference is applied")
  end
end

-- Missing preferred format falls back to available stills.
do
  local r = run({
    mode = "matchRendered",
    activeIndex = 2,
    photos = {
      { path = "/dir/img.CR2", fileFormat = "RAW", angle = 0 },
      { path = "/dir/img.DNG", fileFormat = "DNG", angle = 1 },
    },
    helper = function(id)
      if id == "p2" then
        return { ok = true, kind = "horizon", degrees = 3 }
      end
      return { ok = true, kind = "horizon", degrees = 8 }
    end,
  })
  eq(r.helperCalls, 1, "fallback helper once")
  if #r.setValues == 2 then
    eq(r.setValues[1].id, "p2", "fallback uses active dng")
    eq(r.setValues[1].value, 1 - 3, "fallback dng final")
    eq(r.setValues[2].value, 1 - 3, "fallback cr2 shares dng final")
  else
    fail("fallback expected two writes")
  end
end

-- Different directories are not grouped.
do
  local r = run({
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/a/img.jpg", fileFormat = "JPEG", angle = 0 },
      { path = "/b/img.CR2", fileFormat = "RAW", angle = 0 },
    },
    helper = function(id)
      if id == "p1" then
        return { ok = true, kind = "horizon", degrees = 3 }
      end
      return { ok = true, kind = "horizon", degrees = 4 }
    end,
  })
  eq(r.helperCalls, 2, "diff dir helper twice")
  eq(#r.setValues, 2, "diff dir two writes")
  if #r.setValues == 2 then
    eq(r.setValues[1].value, -3, "diff dir jpg individual")
    eq(r.setValues[2].value, -4, "diff dir raw individual")
  end
end

-- Unselected same-name partner is not touched.
do
  local r = run({
    mode = "matchRendered",
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 0 },
    },
    extraPhotos = {
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 9 },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
  })
  eq(#r.setValues, 1, "unselected partner no extra write")
  eq(r.extraPhotos[1].angle, 9, "unselected partner angle unchanged")
  eq(r.helperCalls, 1, "unselected partner helper once")
end

-- Reference none/error does not publish a target.
do
  local r = run({
    mode = "matchRendered",
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 2 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5 },
    },
    helper = function()
      return { ok = true, kind = "none" }
    end,
  })
  eq(#r.setValues, 0, "reference none no writes")
  ok(r.summary ~= nil and string.find(r.summary.body, "no_horizon", 1, true) ~= nil, "reference none reason")
  ok(r.summary ~= nil and string.find(r.summary.body, "reference_no_horizon", 1, true) ~= nil, "follower none distinct reason")
  if r.summary then
    eq(r.summary.skip, 2, "reference none both skip")
    eq(r.summary.applied, 0, "reference none not applied")
  end
end

do
  local r = run({
    mode = "matchRendered",
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 2 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5 },
    },
    helper = function()
      return { ok = false, err = "boom" }
    end,
  })
  eq(#r.setValues, 0, "reference error no writes")
  ok(r.summary ~= nil and string.find(r.summary.body, "helper_failed", 1, true) ~= nil, "reference error reason")
  ok(r.summary ~= nil and string.find(r.summary.body, "reference_failed", 1, true) ~= nil, "follower error distinct reason")
  if r.summary then
    eq(r.summary.fail, 2, "reference error both fail")
  end
end

-- Member/reference setting conflict.
do
  local jpegSettings = { Exposure2012 = 0, Contrast2012 = 0, CropAngle = 0 }
  local rawSettings = { Exposure2012 = 0, Contrast2012 = 0, CropAngle = 0 }
  local r = run({
    mode = "matchRendered",
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 0, settings = jpegSettings },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5, settings = rawSettings },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
    onHelper = function(_, ctx)
      ctx.photos[2].settings.Contrast2012 = 40
    end,
  })
  eq(#r.setValues, 1, "follower settings conflict jpeg applied only")
  if r.summary then
    eq(r.summary.applied, 1, "follower settings conflict applied")
    eq(r.summary.unprocessed, 1, "follower settings conflict remaining")
    ok(string.find(r.summary.body, "settings_changed", 1, true) ~= nil, "follower settings conflict reason")
  end
end

do
  local jpegSettings = { Exposure2012 = 0, Contrast2012 = 0, CropAngle = 0 }
  local rawSettings = { Exposure2012 = 0, Contrast2012 = 0, CropAngle = 0 }
  local applied = false
  local r = run({
    mode = "matchRendered",
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 0, settings = jpegSettings },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5, settings = rawSettings },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
    onSetValue = function()
      applied = true
    end,
    onGetDevelopSettings = function(photo)
      if applied and photo.localIdentifier == 2 then
        jpegSettings.Contrast2012 = 12
      end
    end,
  })
  eq(#r.setValues, 1, "reference drift after apply does not write follower")
  if r.summary then
    eq(r.summary.applied, 1, "reference drift applied reference")
    eq(r.summary.unprocessed, 1, "reference drift follower unprocessed")
    ok(string.find(r.summary.body, "reference_settings_changed", 1, true) ~= nil, "reference drift reason")
  end
end

-- Grouped cancellation restores original multi-selection.
do
  local r = run({
    mode = "matchRendered",
    canceledAt = 1,
    photos = {
      { path = "/dir/IMG.jpg", fileFormat = "JPEG", angle = 0 },
      { path = "/dir/IMG.CR2", fileFormat = "RAW", angle = 5 },
      { path = "/dir/other.jpg", fileFormat = "JPEG", angle = 0 },
    },
    helper = function()
      return { ok = true, kind = "horizon", degrees = 3 }
    end,
  })
  eq(r.progressDone, true, "grouped cancel progress done")
  eq(r.running, false, "grouped cancel lock released")
  if r.summary then
    eq(r.summary.applied, 1, "grouped cancel applied reference")
    eq(r.summary.unprocessed, 2, "grouped cancel remaining")
    ok(string.find(r.summary.body, "canceled", 1, true) ~= nil, "grouped cancel reason")
  end
  ok(restoredCount(r, 3), "grouped cancel restored 3-photo selection")
end

-- Settings reads may yield before either reference or follower isolation.
for _, boundary in ipairs({ "group", "follower" }) do
  for _, conflict in ipairs({ "selection", "module" }) do
    local followerReads = 0
    local fired = false
    local r = run {
      mode = "matchRendered",
      photos = {
        { path = "/dir/IMG.JPG", fileFormat = "JPEG" },
        { path = "/dir/IMG.ARW", fileFormat = "RAW" },
      },
      onGetDevelopSettings = function(photo, ctx)
        if photo.localIdentifier == 2 then followerReads = followerReads + 1 end
        if not fired and (boundary == "group" or followerReads == 2) then
          fired = true
          if conflict == "selection" then ctx.setUser() else ctx.setModule("map") end
        end
      end,
    }
    local label = boundary .. " snapshot " .. conflict
    ok(fired, label .. " injected")
    eq(r.overwritten, 0, label .. " preserves user selection")
    eq(#r.setValues, boundary == "group" and 0 or 1, label .. " stops further writes")
    eq(r.summary.unprocessed, boundary == "group" and 2 or 1, label .. " remaining count")
    ok(string.find(r.summary.body, conflict .. "_changed", 1, true) ~= nil, label .. " reason")
    eq(r.running, false, label .. " releases lock")
    if conflict == "module" then
      eq(r.moduleName(), "map", label .. " preserves user module")
    end
  end
end

do
  local r = run {
    n = 1,
    startAngle = 2,
    helper = function() return { kind = "horizon", degrees = 0.049 } end,
  }
  eq(#r.setValues, 1, "individual existing deadband reapplied after reset")
  eq(r.summary.applied, 1, "individual existing deadband reset applied")
  ok(string.find(r.summary.details, "前=2.00  後=2.00", 1, true) ~= nil, "individual noop reports both angles")
end

-- Match the reported 60-photo shape: six no-horizon skips, then the first
-- successful RAW reference and its HIF follower, followed by other groups.
for _, scenario in ipairs({"late_source_crop", "transient_follower", "persistent_follower"}) do
  local specs={}
  local function photo(stem,ext)
    specs[#specs+1]={path="/dir/"..stem.."."..ext,fileFormat=ext=="ARW" and "RAW" or "HEIF",
      settings={Exposure2012=0,CropLeft=0,CropRight=1}}
  end
  photo("SAMPLE_A","HIF")
  photo("SAMPLE_B","ARW"); photo("SAMPLE_B","HIF"); photo("SAMPLE_B","HIF")
  photo("SAMPLE_C","ARW"); photo("SAMPLE_C","HIF")
  photo("SAMPLE_D","ARW"); photo("SAMPLE_D","HIF")
  for i=1,26 do photo("later"..i,"ARW"); photo("later"..i,"HIF") end
  local wrote,refReads,followerReads=false,0,0
  local r=run {
    sameNameMode="matchRaw",photos=specs,clockStep=0.01,
    helper=function(id)
      if id=="p1" or id=="p2" or id=="p5" then return {kind="none"} end
      return {kind="horizon",degrees=1.62}
    end,
    onSetValue=function() wrote=true end,
    onGetDevelopSettings=function(p)
      if wrote and p.localIdentifier==7 then
        refReads=refReads+1
        if scenario=="late_source_crop" and refReads==3 then
          p.settings.CropLeft,p.settings.CropRight=0.029392,0.970608
          p.settings.CropConstrainAspectRatio=true
        end
      end
      if wrote and p.localIdentifier==8 and scenario~="late_source_crop" then
        followerReads=followerReads+1
        p.settings.Exposure2012=(scenario=="transient_follower" and followerReads>1) and 0 or 1
      end
    end,
  }
  eq(r.summary.skip,6,scenario .. " 60 photos retains six real skips")
  eq(r.summary.applied,scenario=="persistent_follower" and 1 or 54,scenario .. " 60 photos applied")
  eq(r.summary.unprocessed,scenario=="persistent_follower" and 53 or 0,scenario .. " 60 photos remaining")
  eq(#r.report.rows,60,scenario .. " every selected photo reported")
end

-- UI readback alone is transient: persistence must precede the next photo.
do
  local r=run {n=2,diagnosticWriteFails=true}
  eq(r.summary.applied,2,"diagnostic write failure does not interrupt batch")
  eq(r.running,false,"diagnostic write failure releases lock")
end

-- A single unavailable SDK UI sample is transient. Verification remains
-- bounded and still requires stable UI and catalog agreement before success.
do
  local wrote, returnedNil = false, false
  local r=run {
    n=1,clockStep=0.01,options={photoDisplayMode="openEachPhoto"},
    onSetValue=function() wrote=true end,
    onGetValue=function(_,value)
      if wrote and not returnedNil then returnedNil=true;return nil end
      return value
    end,
  }
  ok(returnedNil,"transient readback test observed nil")
  eq(r.summary.applied,1,"transient nil readback recovers")
  eq(r.summary.fail,0,"transient nil readback does not fail the photo")
  wrote=false
  r=run {
    n=1,clockStep=0.05,options={photoDisplayMode="openEachPhoto"},
    onSetValue=function() wrote=true end,
    onGetValue=function(_,value) if wrote then return nil end;return value end,
  }
  eq(r.summary.applied,0,"persistent nil readback never confirms the photo")
  eq(r.summary.fail,1,"persistent nil readback fails within the deadline")
end

-- A transitional follower read may recover to the exact original state. A
-- persistent manual edit must still stop, including during the bounded retry.
for _, scenario in ipairs({"transient", "persistent", "selection", "module", "cancel"}) do
  local wrote, reads = false, 0
  local r = run {
    sameNameMode="matchRaw", clockStep=0.01,
    photos={
      {path="/dir/IMG.ARW",fileFormat="RAW",settings={Exposure2012=0}},
      {path="/dir/IMG.HIF",fileFormat="HEIF",settings={Exposure2012=0}},
    },
    onSetValue=function() wrote=true end,
    onGetDevelopSettings=function(p,ctx)
      if wrote and p.localIdentifier==2 then
        reads=reads+1
        p.settings.Exposure2012=(scenario=="transient" and reads>1) and 0 or 1
        if reads==1 then
          if scenario=="selection" then ctx.setUser() end
          if scenario=="module" then ctx.setModule("map") end
          if scenario=="cancel" then ctx.cancel() end
        end
      end
    end,
  }
  eq(r.summary.applied,scenario=="transient" and 2 or 1,scenario .. " follower read applied count")
  eq(r.summary.unprocessed,scenario=="transient" and 0 or 1,scenario .. " follower read remaining count")
  eq(r.overwritten,0,scenario .. " follower read preserves selection")
  ok(r.diagnostics and r.diagnostics:find('Exposure2012',1,true),scenario .. " diagnostic identifies field")
  if scenario=="transient" then
    ok(r.diagnostics:find('"recovered":true',1,true),"transient read recorded as recovered")
  elseif scenario=="module" then eq(r.moduleName(),"map","retry preserves changed module") end
end

for _, scenario in ipairs({"exposure", "transform", "crop_angle", "crop_unstable", "selection", "module", "tool", "cancel"}) do
  local wrote,reads=false,0
  local r=run {
    sameNameMode="matchRaw", clockStep=0.01,
    photos={
      {path="/dir/IMG.ARW",fileFormat="RAW",settings={Exposure2012=0,PerspectiveScale=100}},
      {path="/dir/IMG.HIF",fileFormat="HEIF"},
    },
    onSetValue=function() wrote=true end,
    onGetDevelopSettings=function(p,ctx)
      if wrote and p.localIdentifier==1 then
        reads=reads+1
        if reads>=2 then
          if scenario=="exposure" then p.settings.Exposure2012=1 end
          if scenario=="transform" then p.settings.PerspectiveScale=110 end
          if scenario=="crop_angle" then p.savedAngle=12 end
          if scenario=="crop_unstable" then p.settings.CropLeft=reads/1000 end
          if scenario=="selection" then ctx.setUser() end
          if scenario=="module" then ctx.setModule("map") end
          if scenario=="tool" then ctx.setTool("loupe") end
          if scenario=="cancel" then ctx.cancel() end
        end
      end
    end,
  }
  eq(#r.setValues,1,scenario .. " during save prevents follower write")
  eq(r.summary.applied,scenario=="cancel" and 1 or 0,scenario .. " during save completes only a verified current photo")
  eq(r.summary.fail,scenario=="cancel" and 0 or 1,scenario .. " during save flags uncertain state")
  eq(r.overwritten,0,scenario .. " during save preserves selection")
  eq(r.running,false,scenario .. " during save releases lock")
end

-- Leave Develop before selecting the next photo, and don't overwrite a user
-- selection made during that module switch.
do
  local r=run {n=2}
  for _,e in ipairs(r.setSelectedEvents) do
    if e.count==1 then eq(e.module,"library","isolation happens in Library") end
  end
  local interrupted=false
  r=run {n=2,onSwitch=function(name,ctx)
    if name=="library" and not interrupted then interrupted=true; ctx.setUser() end
  end}
  eq(r.overwritten,0,"user selection during library switch is preserved")
  eq(#r.setValues,0,"user selection during library switch stops writes")
end

-- Lightroom refusing a plug-in selection change is a readiness failure, not a
-- user selection change. The original multi-selection remains owned.
do
  local r=run {n=2,ignoreSelectionSet=true,options={photoDisplayMode="openEachPhoto"}}
  eq(#r.setValues,0,"failed isolation never writes")
  eq(r.summary.fail,1,"failed isolation reports current photo failure")
  eq(r.summary.unprocessed,1,"failed isolation leaves following photo unprocessed")
  ok(r.summary.body:find("not_ready",1,true)~=nil,"failed isolation reports not_ready")
  ok(r.summary.body:find("selection_changed",1,true)==nil,"failed isolation is not blamed on the user")
end

-- A skipped reference leaves Develop active. The next shared group's baseline
-- must be read in Library; Lightroom can otherwise return a transitional Look
-- table for the inactive next reference and trigger a false settings conflict.
do
  local inactiveDevelopRead = false
  local r = run {
    mode = "matchRaw",
    options = {maxLeftAngle=1,maxRightAngle=1,overLimitAction="skip"},
    photos = {
      {path="/dir/A.ARW",fileFormat="RAW",settings={Look={Name="Adobe Color"}}},
      {path="/dir/A.HIF",fileFormat="HEIF",settings={Look={Name="Adobe Color"}}},
      {path="/dir/B.ARW",fileFormat="RAW",settings={Look={Name="Adobe Color"}}},
      {path="/dir/B.HIF",fileFormat="HEIF",settings={Look={Name="Adobe Color"}}},
    },
    helper = function() return {kind="horizon",degrees=-7} end,
    onGetDevelopSettings = function(photo, ctx)
      if photo.localIdentifier == 3 then
        if ctx.moduleName() == "develop" and ctx.activePhoto() ~= photo then
          inactiveDevelopRead = true
          photo.settings.Look = {Name="transitional"}
        else
          photo.settings.Look = {Name="Adobe Color"}
        end
      end
    end,
  }
  eq(r.summary.skip,4,"consecutive skipped groups all complete")
  eq(r.summary.unprocessed,0,"next group has no false settings conflict")
  eq(#r.setValues,0,"overflow skips write no angles")
  eq(inactiveDevelopRead,false,"no shared baseline reads an inactive photo in Develop")
end

-- The Library boundary is a context fix, not a relaxation of edit guards.
do
  local changed = false
  local r = run {
    sameNameMode="matchRaw",clockStep=0.01,
    photos={
      {path="/dir/IMG.ARW",fileFormat="RAW",settings={Look={Name="Adobe Color"}}},
      {path="/dir/IMG.HIF",fileFormat="HEIF",settings={Look={Name="Adobe Color"}}},
    },
    onSetValue=function() changed=true end,
    onGetDevelopSettings=function(photo)
      if changed and photo.localIdentifier==2 then
        photo.settings.Look={Name="Camera Matching"}
      end
    end,
  }
  eq(#r.setValues,1,"real nested Look edit blocks follower write")
  eq(r.summary.unprocessed,1,"real nested Look edit remains protected")
  ok(r.diagnostics:find('Look',1,true),"real Look edit is diagnosed")
end

-- Crop geometry can finish saving after the angle first matches. A reference
-- snapshot taken between those writes must not abort all its followers.
for _, mode in ipairs({"matchRaw", "matchRendered"}) do
  local wrote, reads = false, 0
  local r = run {
    mode = mode,
    photos = {
      {path="/dir/late.ARW",fileFormat="RAW",settings={CropLeft=0,CropRight=1}},
      {path="/dir/late.HIF",fileFormat="HEIF",settings={CropLeft=0,CropRight=1}},
      {path="/dir/next.ARW",fileFormat="RAW"},
      {path="/dir/next.HIF",fileFormat="HEIF"},
    },
    onSetValue = function() wrote = true end,
    onGetDevelopSettings = function(photo)
      local refId = mode == "matchRaw" and 1 or 2
      if wrote and photo.localIdentifier == refId then
        reads = reads + 1
        if reads == 3 then
          photo.settings.CropLeft, photo.settings.CropRight = 0.02, 0.98
          photo.settings.CropConstrainAspectRatio = true
        end
      end
    end,
  }
  eq(r.summary.applied, 4, mode .. " late crop save finishes both groups")
  eq(r.summary.unprocessed, 0, mode .. " late crop save leaves no abandoned photos")
end

do
  local r = run {
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.HIF", fileFormat = "HEIF" },
      { path = "/dir/IMG.ARW", fileFormat = "RAW" },
    },
    helper = function() return { kind = "horizon", degrees = -8.375 } end,
  }
  eq(r.summary.applied, 2, "persistent pair applied")
  for _, photo in ipairs(r.photos) do
    eq(photo.savedAngle, 8.375, "pair angle persisted " .. photo.fileName)
    eq(photo.angle, 8.375, "pair angle survives photo switch " .. photo.fileName)
  end
end

do
  local r = run {
    n = 2,
    deferPersistence = true,
    onSleep = function(_, ctx)
      for _, photo in ipairs(ctx.photos) do
        if photo.pendingAngle ~= nil then
          photo.savedAngle = photo.angle
          photo.pendingAngle = nil
        end
      end
    end,
  }
  eq(r.summary.applied, 2, "delayed persistence waits before switching")
  eq(r.photos[1].savedAngle, -3, "delayed first photo persisted")
  eq(r.photos[2].savedAngle, -3, "delayed second photo persisted")
end

do
  local r = run { n = 1, dropFirstSetValue = true }
  eq(#r.setValues, 2, "unchanged first write is retried once")
  eq(r.summary.applied, 1, "retry recovers a dropped first write")
  eq(r.photos[1].savedAngle, -3, "retried write persists target")
end

do
  local r=run {n=1,startAngle=2,options={adjustedPhotoAction="reset"},
    dropReset=function(attempt)return attempt==1 end}
  eq(r.resets,2,"a dropped reset is retried once")
  eq(r.summary.applied,1,"retried reset completes the angle save")
  eq(r.summary.fail,0,"dropped reset is not reported as an unresolved edit")
end
for _,case in ipairs({"always_dropped","crop_edit","exposure_edit","selection","cancel"}) do
  local dropped=false
  local r=run {n=1,startAngle=2,options={adjustedPhotoAction="reset"},
    dropReset=function(attempt,c)
      dropped=true
      if case=="selection" then c.setUser() end
      if case=="cancel" then c.cancel() end
      return true
    end,
    onGetDevelopSettings=function(p,c)
      if dropped and case=="crop_edit" then p.settings.CropLeft=.2 end
      if dropped and case=="exposure_edit" then p.settings.Exposure2012=1 end
    end}
  eq(r.resets,case=="always_dropped" and 2 or 1,case.." never retries over a change")
  eq(#r.setValues,0,case.." never writes the target after an unconfirmed reset")
  eq(r.summary.applied,0,case.." cannot be reported as applied")
end

do
  local r = run { n = 2, deferPersistence = true }
  eq(r.summary.applied, 0, "transient UI match is not success")
  eq(r.summary.fail, 1, "missing persistence is failure")
  eq(r.summary.unprocessed, 1, "missing persistence stops batch")
  ok(string.find(r.summary.details, "保存=0.0000", 1, true) ~= nil, "failure reports stored angle")
  ok(string.find(r.summary.details, "timeout", 1, true) ~= nil, "failure reports readback cause")
end

for _, sign in ipairs({ 1, -1 }) do
  local r = run {
    mode = "matchRendered",
    options = { maxLeftAngle = 10, maxRightAngle = 10 },
    photos = {
      { path = "/dir/IMG.HIF", fileFormat = "HEIF" },
      { path = "/dir/IMG.ARW", fileFormat = "RAW" },
    },
    helper = function() return { kind = "horizon", degrees = -sign * 8.375 } end,
    onSetValue = function(_, value, ctx)
      for _, photo in ipairs(ctx.photos) do
        if photo.pendingAngle ~= nil then
          photo.angle = sign * math.ceil(sign * value * 100 + 1e-9) / 100
        end
      end
    end,
  }
  eq(#r.setValues, 2, "one-step rounding needs no extra write")
  eq(r.summary.applied, 2, "rounded pair succeeds")
  eq(r.photos[1].savedAngle, sign * 8.38, "reference rounded and persisted")
  ok(math.abs(r.photos[2].savedAngle - r.photos[1].savedAngle) <= HorizonMath.VALUE_EPS, "persisted follower within one UI step")
end

-- Limits apply to the final angle, including an existing adjustment.
do
  local r = run { n=1,startAngle=8,options={maxLeftAngle=3,maxRightAngle=3},helper=function() return {degrees=-1} end }
  eq(#r.setValues,0,"final angle 9 exceeds right3 despite residual1")
  eq(r.resets,nil,"excluded final angle never resets crop")
  ok(r.summary.details:find("angle_limit",1,true),"final angle skip reason")
  r = run {n=1,startAngle=20,options={tiltSource="inCameraData",maxLeftAngle=3,maxRightAngle=3},helper=function() return {roll_only=true,roll_degrees=2,make="Canon"} end}
  eq(r.photos[1].savedAngle,2,"residual18 allowed when final2 inside bounds")
  eq(r.resets,1,"reprocess reset once before final setting")
end
for _, sign in ipairs({-1,1}) do
  local r = run {n=1,options={maxLeftAngle=2,maxRightAngle=4},helper=function() return {degrees=sign*3} end}
  eq(r.summary.applied,sign == -1 and 1 or 0,"asymmetric final bounds")
end
-- Per-photo review: acceptance, skip, cancellation and interaction conflict.
for _, action in ipairs({"apply","skip","stop","cancel_result","close"}) do
  local r = run {n=2,startAngle=2,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},reviewAction=action,
    helper=function() return {degrees=-3} end}
  eq(r.reviews,(action=="stop" or action=="cancel_result" or action=="close") and 1 or 2,"review per photo or stop batch: "..action)
  eq(#r.setValues,action=="apply" and 2 or 0,"only explicit apply writes: "..action)
  eq(r.resets,action=="apply" and 2 or nil,"skip, stop, and close preserve crop: "..action)
end
do
  local r = run {n=3,startAngle=2,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},
    reviewAction="apply_all_remaining",helper=function() return {degrees=-3} end}
  eq(r.reviews,1,"apply all remaining asks only once")
  eq(#r.setValues,3,"apply all remaining writes every later over-limit photo")
  eq(r.summary.applied,3,"apply all remaining counts every applied photo")
  r = run {n=3,startAngle=2,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},
    reviewAction="skip_all_remaining",helper=function() return {degrees=-3} end}
  eq(r.reviews,1,"skip all remaining asks only once")
  eq(#r.setValues,0,"skip all remaining preserves every later over-limit photo")
  eq(r.summary.skip,3,"skip all remaining counts every skipped photo")
  r = run {n=3,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},
    reviewAction="skip_all_remaining",helper=function(id)
      return {degrees=id=="p2" and 0.5 or -3}
    end}
  eq(r.reviews,1,"skip all remaining still suppresses later over-limit prompts")
  eq(#r.setValues,1,"skip all remaining does not skip an in-limit correction")
  eq(r.summary.applied,1,"in-limit correction still applies after skip all remaining")
  eq(r.summary.skip,2,"only over-limit corrections are skipped by skip all remaining")
end
do
  local r = run {n=2,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},onReview=function(c) c.setUser() end}
  eq(#r.setValues,0,"review user selection stops writes")
  eq(r.overwritten,0,"review does not restore over user selection")
  r = run {n=1,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},onReview=function(c) c.settings.Exposure2012=2 end}
  eq(#r.setValues,0,"review develop edit stops writes")
end
-- Existing angle skip and failed tiltSource never reset or touch crop.
do
  local r = run {n=2,startAngle=2,options={adjustedPhotoAction="skip"}}
  eq(r.helperCalls,0,"existing skip avoids estimation")
  eq(#r.setValues,0,"existing skip no angle writes")
  eq(r.summary.skip,2,"existing skip count")
  r = run {n=1,startAngle=2,helper=function() return {kind="none"} end}
  eq(r.resets,nil,"no horizon leaves original crop")
  eq(r.photos[1].savedAngle,2,"no horizon retains original angle")
end
-- Metadata scope and write-access failure reporting.
do
  local r = run {n=1,options={maxLeftAngle=1,maxRightAngle=1,skippedFlagAction="reject",skippedColorLabelAction="red"}}
  eq(r.photos[1].pickStatus,-1,"excluded receives reject flag")
  eq(r.photos[1].colorNameForLabel,"red","excluded receives red label")
  ok(r.summary.details:find("目印設定済み",1,true),"verified mark reported")
  r = run {n=1,options={maxLeftAngle=1,maxRightAngle=1,skippedColorLabelAction="yellow"},markTimeout=true}
  eq(r.photos[1].colorNameForLabel,"none","mark timeout changes nothing")
  ok(r.summary.details:find("目印設定失敗",1,true),"mark timeout visible")
  r = run {n=1,options={skippedColorLabelAction="red"},helper=function() return {ok=false} end}
  eq(r.photos[1].colorNameForLabel,"none","helper failure not marked")
  r = run {n=1,canceledAt=0,options={skippedColorLabelAction="red"}}
  eq(r.photos[1].colorNameForLabel,"none","unprocessed not marked")
end
-- The Lightroom selection owns scope for every supported still format.
do
  local r = run {sameNameMode="matchRaw",photos={
    {path="/a/a.ARW",fileFormat="RAW"},{path="/a/a.HIF",fileFormat="HEIF"}}}
  eq(r.helperCalls,1,"selected pair estimated once")
  eq(r.setValues[1].id,"p1","selected RAW is the reference despite retired filter")
  eq(r.photos[1].savedAngle,-3,"all selected formats processed")
  r = run {sameNameMode="matchRaw",photos={{path="/a/a.HIF"},{path="/a/a.CR3",fileFormat="UNKNOWN"}}}
  eq(r.setValues[1].id,"p2","registered CR3 preferred without SDK RAW tag")
end
do
  local P=realDofile(plugin .. "/RunPolicy.lua")
  local o=P.defaults({})
  eq(o.sameNameMode,"matchRaw","new install matches same-name files to RAW/DNG")
  eq(o.overLimitAction,"review","new install reviews over-limit corrections")
  eq(o.adjustedPhotoAction,"skip","new install protects existing angles")
  eq(o.tiltSource,"inCameraData","new install prefers capture-time data")
  eq(o.maxLeftAngle,3,"new install uses three-degree left limit")
  eq(o.maxRightAngle,3,"new install uses three-degree right limit")
  eq(o.skippedColorLabelAction,"keep","default does not mark")
  eq(P.normalizedLabel("gray"),"none","native gray means no label")
  eq(P.normalizedLabel("yellow"),"yellow","colored label unchanged")
  for _, ext in ipairs(P.rawExtensions) do ok(P.isRaw("UNKNOWN",ext),"registered RAW "..ext) end
  ok(P.isRaw("RAW","future"),"SDK RAW fallback covers future formats")
  o.maxLeftAngle="not a number"; eq(P.validate(o),nil,"reject nonnumeric bound")
  o.maxLeftAngle=46; eq(P.validate(o),nil,"reject over45 bound")
  o.maxLeftAngle=3.14
  local normalized=P.validate(o)
  ok(normalized,"accept precision beyond Lightroom display rounding")
  eq(normalized.maxLeftAngle,3.1,"normalize angle to Lightroom's displayed precision")
  o.maxLeftAngle="3.1"; ok(P.validate(o),"numeric string accepted")
  o.maxLeftAngle=0; ok(P.validate(o),"zero final limit accepted")
end

do
  local r=run {sameNameMode="matchRaw",options={adjustedPhotoAction="skip"},photos={
    {path="/a/a.ARW",fileFormat="RAW",angle=2},{path="/a/a.HIF",fileFormat="HEIF"}}}
  eq(r.helperCalls,1,"skip adjusted reference before grouping")
  eq(r.photos[1].savedAngle,2,"adjusted RAW kept")
  eq(r.photos[2].savedAngle,-3,"unadjusted HIF estimated independently")
  r=run {n=1,startAngle=40,options={maxLeftAngle=45,maxRightAngle=45,overLimitAction="review",skippedColorLabelAction="red"},helper=function() return {degrees=-10} end}
  eq(#r.setValues,0,"SDK out of range never applied")
  eq(r.reviews,nil,"unsupported SDK target not offered for override")
  eq(r.photos[1].colorNameForLabel,"red","unsupported SDK target marked excluded")
end

do
  local reset=false
  local edited=false
  local r=run {n=1,startAngle=2,options={adjustedPhotoAction="reset"},
    onReset=function(c) reset=true end,
    onGetDevelopSettings=function(p,c)
      if reset and not edited then
        edited=true
        p.settings.CropLeft=0.2
        p.settings.CropRight=0.8
      end
    end}
  eq(#r.setValues,0,"manual crop edit during reset readback must stop angle write")
end
-- Review-only probes: run product unmodified, extend the existing SDK mock.
do
  local r=run {n=2,startAngle=2,canceledAt=0,options={adjustedPhotoAction="skip",skippedColorLabelAction="red"}}
  eq(r.photos[1].colorNameForLabel,"none","canceled before preflight must not label first photo")
  eq(r.photos[2].colorNameForLabel,"none","canceled before preflight must not label second photo")
end
do
  local switched=false
  local r=run {n=2,startAngle=2,options={adjustedPhotoAction="skip",skippedColorLabelAction="red"},onGetDevelopSettings=function(p,c)
    if not switched then switched=true;c.setUser() end
  end}
  eq(r.photos[2].colorNameForLabel,"none","selection change during preflight must stop later photo marking")
end
do
  local reset=false
  local r=run {n=2,sameNameMode="matchRendered",options={adjustedPhotoAction="reset"},photos={
    {path="/a/a.HIF",fileFormat="HEIF",angle=0},{path="/a/a.ARW",fileFormat="RAW",angle=2}},
    helper=function() return {degrees=-3} end,
    onReset=function(c) reset=true end,
    onGetDevelopSettings=function(p,c)
      if reset and p.localIdentifier==2 then
        c.photos[1].angle,c.photos[1].savedAngle=8,8
      end
    end}
  eq(#r.setValues,1,"reference edit during follower reset must stop stale follower write")
end
do
  local r=run {n=1,options={maxRightAngle=3,maxLeftAngle=3},helper=function() return {degrees=-3} end,
    onSetValue=function(k,v,c) c.photos[1].angle=3.01 end}
  eq(r.summary.applied,0,"final saved angle above upper bound cannot be unqualified success")
end
do
  local r=run {n=3,startAngle=2,options={adjustedPhotoAction="skip",skippedColorLabelAction="red"},onGetDevelopSettings=function(p,c)
    if p.localIdentifier==2 then c.cancel() end
  end}
  eq(r.summary.unprocessed,2,"mid-preflight cancel keeps remaining photos unprocessed")
  eq(r.photos[1].colorNameForLabel,"red","completed preflight skip retains its mark on cancellation")
  for i=2,3 do eq(r.photos[i].colorNameForLabel,"none","unfinished preflight photos remain unmarked") end
  eq(#r.setValues,0,"mid-preflight cancel no angle writes")
end
for _,sign in ipairs({-1,1}) do
  local r=run {n=2,sameNameMode="matchRendered",options={maxLeftAngle=3,maxRightAngle=3},photos={
    {path="/a/a.HIF",fileFormat="HEIF"},{path="/a/a.ARW",fileFormat="RAW"}},
    helper=function() return {degrees=-sign*3} end,
    onSetValue=function(k,v,c) c.photos[1].angle=sign*3.01 end}
  eq(r.summary.applied,0,"rounded out-of-bounds reference not successful")
  eq(r.summary.fail,1,"rounded out-of-bounds counted failure")
  eq(r.summary.unprocessed,1,"rounded out-of-bounds stops follower")
  eq(r.photos[2].savedAngle,0,"rounded out-of-bounds never shared")
  ok(r.summary.details:find("saved_angle_outside_limits",1,true),"rounded overflow report retains exact cause")
end
do
  local r=run {n=1,startAngle=2,options={adjustedPhotoAction="reset"},onReset=function(c) c.cancel() end}
  eq(#r.setValues,1,"cancel during reset finishes the current photo's short save")
  eq(r.summary.applied,1,"cancel during reset confirms current photo")
  eq(r.summary.fail,0,"verified cancellation is not a failed save")
  r=run {n=1,startAngle=2,options={adjustedPhotoAction="reset"},onReset=function(c) c.photos[1].settings.Exposure2012=1 end}
  eq(#r.setValues,0,"non-crop develop edit during reset stops angle write")
  r=run {n=1,options={maxLeftAngle=3,maxRightAngle=3,overLimitAction="review"},helper=function() return {degrees=-4} end,
    onSetValue=function(k,v,c) c.photos[1].angle=4.01 end}
  eq(r.reviews,1,"explicit limit override asks once")
  eq(r.summary.applied,1,"explicit approved override still accepts SDK rounding tolerance")
end


-- One approval applies only to its own same-name group, in either priority mode.
for _,sameNameMode in ipairs({"matchRaw","matchRendered"}) do
  for _,action in ipairs({"apply","skip","stop","close"}) do
    local r=run {sameNameMode=sameNameMode,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},reviewAction=action,photos={
      {path="/a/a.ARW",fileFormat="RAW"},{path="/a/a.JPG",fileFormat="JPEG"},
      {path="/a/b.ARW",fileFormat="RAW"},{path="/a/b.JPG",fileFormat="JPEG"}}}
    eq(r.reviews,(action=="stop" or action=="close") and 1 or 2,"one review per same-name group "..sameNameMode..action)
    eq(#r.setValues,action=="apply" and 4 or 0,"group action controls both photos "..sameNameMode..action)
    eq(r.reviewInfo.actionVerb,"スキップ","Return defaults to safe group skip")
    eq(r.reviewInfo.accessoryView[5].title,"角度を適用","group apply requires the explicit custom button")
  end
end
-- Preview is read-only and guarded across asynchronous rendering.
do
  local r=run {n=1,startAngle=2,options={maxLeftAngle=0.5,maxRightAngle=0.5,overLimitAction="review"},reviewAction="skip"}
  eq(r.previewDegrees,-3,"preview rotates residual rather than reapplying final angle")
  eq(#r.setValues,0,"preview does not write angle")
  eq(r.resets,nil,"preview does not reset crop")
  ok(r.reviewInfo.contents[2]._type=="picture" and r.reviewInfo.contents[2].value:match("crop%-preview%.png$"),"generated overlay passed to review")
  r=run {n=1,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},onPreview=function(c) c.setUser() end}
  eq(r.reviews,nil,"selection change during preview prevents stale review")
  eq(#r.setValues,0,"selection change during preview prevents write")
  r=run {n=1,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},previewOk=false,reviewAction="skip"}
  ok(r.reviewInfo.contents[2]._type=="catalog_photo" and r.reviewInfo.contents[4].title:find("補正後のプレビューを作成できませんでした",1,true),"failed overlay uses catalog photo with visible warning")
end
-- Primary report has columns and Japanese explanations without diagnostic tabs.
do
  local r=run {n=1,helper=function() return {kind="none"} end}
  local main=r.resultInfo.contents
  local labels={}; collectText(main,labels); local text=table.concat(labels,"\n")
  ok(text:find("角度",1,true) and text:find("詳細",1,true) and text:find("方式",1,true),"report has angle and method columns")
  ok(text:find("傾きを推定できませんでした",1,true),"report explains skipped photo")
  ok(not text:find("no_horizon",1,true),"main report hides internal reason codes")
  ok(not viewHasType(main,"tab_view"),"report removes diagnostic tabs")
  local start={}; collectText(r.startInfo.contents,start); local form=table.concat(start,"\n")
  ok(not form:find("RAW形式",1,true) and not form:find("その他の静止画",1,true),"start dialog removes format controls")
end

-- Synced photos identify their actual reference format and keep names in the
-- Photo column separate from the reference filename in Details.
for _,language in ipairs({"ja","en"}) do
  for _,case in ipairs({
    {mode="matchRaw",name="a.ARW",format="RAW",follower="a.HIF",followerFormat="HEIF"},
    {mode="matchRaw",name="a.DNG",format="DNG",follower="a.JPG",followerFormat="JPEG"},
    {mode="matchRendered",name="a.JPG",format="JPEG",follower="a.ARW",followerFormat="RAW"},
    {mode="matchRendered",name="a.HIF",format="HEIF",follower="a.ARW",followerFormat="RAW"},
    {mode="matchRaw",name="a.JPG",format="JPEG",follower="a.HIF",followerFormat="HEIF"},
  }) do
    local r=run {language=language,sameNameMode=case.mode,photos={
      {path="/a/"..case.name,fileFormat=case.format},
      {path="/a/"..case.follower,fileFormat=case.followerFormat}}}
    local dialog=loadChunk(plugin .. "/ResultDialog.lua",r.env)()
    local reference=dialog.rowValues(r.report.rows[1])
    local follower=dialog.rowValues(r.report.rows[2])
    eq(reference[1],case.name,"reference photo column is filename only")
    eq(reference[4],language=="ja" and "画像解析" or "Image analysis","reference retains estimation method")
    eq(follower[1],case.follower,"follower photo column is filename only")
    eq(follower[4],language=="ja" and case.format.."の設定に同期" or "Synced to "..case.format.." settings","method identifies actual reference format")
    eq(follower[5],(language=="ja" and "基準：" or "Reference: ")..case.name,"details identify reference filename")
  end
end

-- Removing diagnostics must retain actionable precision in a failed save row.
do
  local r=run {n=1,options={maxLeftAngle=3.1,maxRightAngle=3.1,photoDisplayMode="openEachPhoto"},helper=function() return {degrees=-3.099} end,
    onSetValue=function(k,v,c) c.photos[1].angle=3.101 end}
  local labels={}; collectText(r.resultInfo.contents,labels); local text=table.concat(labels,"\n")
  ok(text:find("保存 3.101°",1,true),"failed save shows persisted angle")
  ok(text:find("目標 3.099°",1,true),"failed save preserves target precision")
  ok(text:find("保存された角度が上限を超えています",1,true),"failed save explains the saved angle exceeds the limit")
end

do
  local r = run({ n = 1 })
  eq(r.progressInfo.cannotCancel, false, "modal progress remains cancelable")
  ok(r.progressInfo.functionContext ~= nil, "modal progress is context owned")
  local v = dofile(plugin .. "/Info.lua").VERSION
  eq(v.display, string.format("%d.%d.%d", v.major, v.minor, v.revision), "SemVer display")
  eq(v.build, nil, "no fourth version field")
end

-- Independent processed/skipped marks and verified quick-collection membership.
do
  local r=run {n=2,options={processedFlagAction="pick",processedColorLabelAction="green",processedQuickCollectionAction="add",
    skippedFlagAction="reject",skippedColorLabelAction="red",skippedQuickCollectionAction="remove"},quickMembers={2},
    helper=function(i) return i=="p1" and {degrees=3} or {kind="none"} end}
  eq(r.photos[1].pickStatus,1,"processed flag")
  eq(r.photos[1].colorNameForLabel,"green","processed color")
  eq(r.quickMembers[r.photos[1]],true,"processed quick add")
  eq(r.photos[2].pickStatus,-1,"skipped independent flag")
  eq(r.photos[2].colorNameForLabel,"red","skipped independent color")
  eq(r.quickMembers[r.photos[2]],nil,"skipped quick remove")
  ok(r.captions[1]:find("0/2",1,true),"initial progress fraction")
  ok(r.captions[#r.captions]:find("2/2",1,true),"final progress counts both dispositions")
  r=run {n=1,options={processedFlagAction="pick"},helper=function() return {degrees=0} end}
  eq(r.photos[1].pickStatus,1,"no change needed counts as processed")
  r=run {n=1,options={processedFlagAction="pick",processedQuickCollectionAction="add"},helper=function() return {ok=false} end}
  eq(r.photos[1].pickStatus,0,"failed analysis not marked processed")
  eq(r.quickMembers[r.photos[1]],nil,"failed analysis not collected")
  r=run {n=1,options={processedQuickCollectionAction="add"},quickName="some other collection"}
  eq(r.quickMembers[r.photos[1]],nil,"unrecognized collection never mutated")
  ok(r.summary.details:find("目印設定失敗",1,true),"collection lookup failure visible")
  r=run {n=1,options={processedQuickCollectionAction="add"},quickWriteFails=true}
  ok(r.summary.details:find("目印の保存を確認できず",1,true),"collection persistence checked")
  local reads=0
  r=run {n=1,options={processedQuickCollectionAction="add",processedFlagAction="pick"},onQuickRead=function(m,ps)
    reads=reads+1;if reads==2 then m[ps[1]]=true end
  end}
  eq(r.photos[1].pickStatus,0,"concurrent membership change preserves other marks")
  ok(r.summary.details:find("目印は変更競合",1,true),"collection conflict reported")
  r=run {n=2,canceledAt=1,options={processedFlagAction="pick",processedQuickCollectionAction="add"}}
  eq(r.photos[1].pickStatus,1,"cancel retains completed photo flag")
  eq(r.quickMembers[r.photos[1]],true,"cancel retains completed photo collection membership")
end

do
  local native=function(s) return s:match("^[^=]*=(.*)$"):gsub("%^n","\n") end
  for _,language in ipairs({"ja","en","fr"}) do
    local tr=loadChunk(plugin .. "/Localization.lua",setmetatable({_PLUGIN={path=plugin},LOC=native,
      import=function() return {currentLanguage=function()return language end} end},{__index=_G}))()
    eq(tr("$$$/BatchAutoStraighten/Text001=Batch Auto Straighten"),"Batch Auto Straighten","locale "..language)
    eq(select("#",tr("$$$/BatchAutoStraighten/Text001=Batch Auto Straighten")),1,"translation returns one value "..language)
  end
  local r=run {n=1,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},reviewAction="stop"}
  eq(r.reviewInfo.cancelVerb,"< exclude >","custom stop avoids unsafe native button reordering")
  eq(r.reviewInfo.actionVerb,"スキップ","Return skips only this photo")
  eq(r.reviewInfo.accessoryView[1].title,"処理を中止","Stop is first in the custom action row")
  eq(r.reviewInfo.accessoryView[5].title,"角度を適用","Apply is next to the default Skip action")
  eq(r.summary.unprocessed,1,"review stop leaves photo unprocessed")
end

do
  local r=run {n=1,language="en",options={processedFlagAction="pick"}}
  eq(r.startInfo.title,"Batch Auto Straighten","English start title")
  eq(r.resultInfo.title,"Batch Auto Straighten Results","English results title")
  local enLabels={}; collectText(r.resultInfo.contents,enLabels)
  ok(table.concat(enLabels,"\n"):find("Method",1,true) and table.concat(enLabels,"\n"):find("Image analysis",1,true),"English method column")
  eq(r.photos[1].pickStatus,1,"English mark verification preserves behavior")
  ok(r.report.body:find("Applied 1",1,true),"English processing summary")
  r=run {n=1,language="en",options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},reviewAction="stop"}
  eq(r.reviewInfo.cancelVerb,"< exclude >","English custom stop avoids unsafe native button reordering")
  eq(r.reviewInfo.actionVerb,"Skip","English Return safely skips")
  eq(r.reviewInfo.accessoryView[1].title,"Stop Batch","English Stop is first")
  eq(r.reviewInfo.accessoryView[2].title,"Apply All Remaining","English apply-all label")
  eq(r.reviewInfo.accessoryView[3].title,"Skip All Remaining","English skip-all label")
  eq(r.reviewInfo.accessoryView[5].title,"Apply Angle","English Apply is explicit")
  eq(#r.setValues,0,"English stop applies nothing")
end

-- A failed native confirmation must never approve a photo or marks.
do
  local r=run {n=2,options={maxLeftAngle=1,maxRightAngle=1,overLimitAction="review",processedFlagAction="pick"},
    reviewFail=true}
  eq(#r.setValues,0,"failed review cannot apply")
  eq(r.summary.unprocessed,2,"failed review stops remaining batch")
  eq(r.photos[1].pickStatus,0,"failed review does not mark")
  ok(r.report.rows[1].reason=="review_failed","failed review reports review failure")
end

do
  local r=run {n=1,startAngle=0,options={tiltSource="inCameraData",adjustedPhotoAction="skip"},
    helper=function() return {roll_only=true,roll_degrees=2.5,make="Canon"} end}
  eq(r.setValues[1].value,2.5,"canon roll becomes UI target")
  eq(r.lastOriginal,"/fake.jpg","camera tiltSource passes original path")
  local labels={}; collectText(r.resultInfo.contents,labels); local cameraText=table.concat(labels,"\n")
  ok(cameraText:find("方式",1,true),"camera result has method column")
  ok(cameraText:find("撮影時の水準器情報",1,true),"result names camera level")

  r=run {n=1,startAngle=0,imageAngleIsResidual=true,options={tiltSource="imageAnalysis",adjustedPhotoAction="skip"},
    helper=function() return {roll_degrees=2.5,make="Canon",degrees=3} end}
  eq(r.setValues[1].value,-3,"image analysis tiltSource ignores roll")
  eq(r.lastOriginal,nil,"image analysis tiltSource does not pass original")
  labels={}; collectText(r.resultInfo.contents,labels)
  ok(table.concat(labels,"\n"):find("画像解析",1,true),"image analysis result names preview method")

  r=run {n=1,startAngle=0,options={tiltSource="inCameraData",adjustedPhotoAction="skip"},
    helper=function() return {roll_degrees=0,make="FUJIFILM",degrees=3} end}
  eq(r.setValues[1].value,-3,"fuji zero uses image analysis")

  r=run {n=1,startAngle=0,options={tiltSource="inCameraData",adjustedPhotoAction="skip"},
    helper=function() return {roll_only=true,roll_degrees=2.5,make="NIKON CORPORATION"} end}
  eq(r.setValues[1].value,-2.5,"nikon roll sign")

  r=run {n=1,startAngle=0,options={tiltSource="inCameraData",adjustedPhotoAction="skip"},
    helper=function() return {roll_only=true,roll_degrees=92.3,make="Canon"} end}
  ok(math.abs(r.setValues[1].value-2.3)<1e-9,"portrait roll wraps into UI range")

  r=run {sameNameMode="matchRaw",options={tiltSource="inCameraData",adjustedPhotoAction="skip"},photos={
    {path="/a/a.ARW",fileFormat="RAW"},{path="/a/a.JPG",fileFormat="JPEG"}},
    helper=function() return {roll_only=true,roll_degrees=2.5,make="Canon"} end}
  eq(r.helperCalls,1,"group estimates reference only")
  eq(r.setValues[1].value,2.5,"reference uses camera roll")
  eq(r.setValues[2].value,2.5,"follower shares final UI not its own roll")
  labels={}; collectText(r.resultInfo.contents,labels)
  ok(table.concat(labels,"\n"):find("RAWの設定に同期",1,true),"follower names synchronization regardless of reference estimation method")

  r=run {n=1,startAngle=0,options={tiltSource="inCameraData",adjustedPhotoAction="skip"},
    helper=function() return {roll_only=true,roll_degrees=0.11103270596310168,make="Apple"} end}
  eq(#r.setValues,1,"camera applies residual below image analysis deadband")
  ok(math.abs(r.setValues[1].value-0.11103270596310168)<1e-12,"camera keeps fine roll value")

  r=run {n=1,startAngle=0,imageAngleIsResidual=true,options={tiltSource="imageAnalysis",adjustedPhotoAction="skip"},
    helper=function() return {kind="horizon",degrees=0.049} end}
  eq(#r.setValues,0,"image analysis ignores residual below 0.05 degrees")
  eq(r.summary.noop,1,"image analysis sub-threshold residual remains noop")

  r=run {n=1,startAngle=0,imageAngleIsResidual=true,options={tiltSource="imageAnalysis",adjustedPhotoAction="skip"},
    helper=function() return {kind="horizon",degrees=0.1} end}
  eq(#r.setValues,1,"image analysis applies tenth-degree residual")
  eq(r.setValues[1].value,-0.1,"image analysis tenth-degree target")
end

do
  for _, angle in ipairs({1.25,-1.75,0.05,-0.05}) do
    local r=run {n=1,startAngle=0,dropFirstSetValue=math.abs(angle)<.1,options={tiltSource="imageAnalysis",adjustedPhotoAction="skip"},
      helper=function() return {degrees=angle} end}
    eq(r.lastTiltSource,"imageAnalysis","image analysis routed independently")
    eq(r.lastOriginal,nil,"image analysis does not receive metadata original")
    eq(r.setValues[1].value,angle,"image analysis UI sign")
    eq(r.helperCalls,1,"image analysis exactly one helper")
    if math.abs(angle)<.1 then eq(#r.setValues,2,"small correction retries a dropped write instead of accepting the unchanged angle") end
    local labels={};collectText(r.resultInfo.contents,labels)
    ok(table.concat(labels,"\n"):find("画像解析",1,true),"image-analysis result identifies method")
  end
  for _, spec in ipairs({{kind="none"},{kind="error"},{ok=false},{wrongSource=true,degrees=2},{degrees=0.049}}) do
    local r=run {n=1,startAngle=0,options={tiltSource="imageAnalysis",adjustedPhotoAction="skip"},helper=function() return spec end}
    eq(#r.setValues,0,"image-analysis abstention/error/wrong source/deadband leaves image unchanged")
    eq(r.helperCalls,1,"image analysis never falls back")
  end
end

-- Direct SDK writes must preserve selection and the same safety contract.
do
 local r=run{n=3,module="library",direct=true,options={adjustedPhotoAction="skip"}}
 eq(r.summary.applied,3,"direct batch applies every photo")
 eq(#r.setValues,0,"direct batch never uses Develop controller")
 eq(#r.setSelectedEvents,0,"direct batch never changes selection")
 eq(#r.switchEvents,0,"direct batch never changes module")
 for _,p in ipairs(r.photos) do eq(p.savedAngle,-3,"direct saved angle");eq(p.settings.Exposure2012,0,"direct preserves exposure")end
 eq(r.report.rows[1].application,"direct","direct application recorded")
 r=run{n=2,module="library",direct=true,directIgnores=true,options={adjustedPhotoAction="skip"}}
 eq(r.summary.fail,1,"ignored direct write fails readback")
 eq(r.summary.unprocessed,1,"unconfirmed direct write stops batch")
 r=run{n=2,module="library",direct=true,directFails=true,options={adjustedPhotoAction="skip"}}
 eq(r.summary.fail,1,"direct SDK error reported")
 eq(r.summary.unprocessed,1,"direct SDK error stops batch")
 r=run{n=2,module="library",direct=true,options={adjustedPhotoAction="skip",maxLeftAngle=1,maxRightAngle=1}}
 eq(r.summary.skip,2,"direct angle limits enforced")
 eq(r.photos[1].directWrites,nil,"direct limit never writes")
 r=run{n=2,module="library",direct=true,options={adjustedPhotoAction="skip",maxLeftAngle=1,maxRightAngle=1,overLimitAction="review"},reviewAction="stop"}
 eq(r.summary.unprocessed,2,"direct review stop leaves photos unprocessed")
 eq(r.photos[1].directWrites,nil,"direct review stop never writes")
 r=run{n=1,module="library",direct=true,options={adjustedPhotoAction="skip"},helper=function()return {degrees=.049}end}
 eq(r.summary.noop,1,"direct deadband no-op")
 eq(r.photos[1].directWrites,nil,"direct no-op never writes")
 r=run{sameNameMode="matchRaw",module="library",direct=true,options={adjustedPhotoAction="skip"},photos={{path="/a/a.ARW",fileFormat="RAW"},{path="/a/a.HIF",fileFormat="HEIF"}}}
 eq(r.summary.applied,2,"direct group applies reference and follower")
 eq(r.helperCalls,1,"direct group analyzes once")
 eq(r.photos[2].savedAngle,r.photos[1].savedAngle,"direct follower shares saved angle")
 r=run{n=1,module="library",direct=true,options={tiltSource="inCameraData",adjustedPhotoAction="skip"}}
 eq(r.helperCalls,2,"camera-data absence invokes image analysis once")
 eq(r.summary.applied,1,"camera-data absence falls back successfully")
 r=run{n=1,module="library",direct=true,options={adjustedPhotoAction="skip"},onHelper=function(_,c)c.cancel()end}
 eq(r.photos[1].directWrites,nil,"direct canceled helper never writes")
end

do
 local seenSecond=false
 local r=run{n=2,module="library",direct=true,options={adjustedPhotoAction="skip"},
  onGetDevelopSettings=function(p)if p.localIdentifier==2 then seenSecond=true end end,
  helper=function(id)if id=="p1" then ok(not seenSecond,"individual starts first analysis before reading second settings")end;return {degrees=3}end}
 eq(r.summary.applied,2,"streamed individual batch completes")
 r=run{module="library",direct=true,options={adjustedPhotoAction="skip"},photos={{},{settings={PerspectiveVertical=1,Exposure2012=0}},{}}}
 eq(r.summary.applied,3,"mixed direct and native batch completes")
 eq(r.photos[1].directWrites,1,"mixed first uses direct")
 eq(r.photos[2].directWrites,nil,"transformed photo uses native")
 eq(r.photos[3].directWrites,1,"direct resumes after native photo")
 eq(#r.setValues,1,"only transformed photo requires native write")
 local Crop=dofile(plugin.."/DirectCrop.lua")
 local context=Crop.context(r.photos[1],r.photos[1]:getDevelopSettings(),true)
 ok(context~=nil,"reset permits recomputing centered crop")
 local unlocked=r.photos[1]:getDevelopSettings();unlocked.CropConstrainAspectRatio=false
 eq(Crop.context(r.photos[1],unlocked,true),nil,"unlocked aspect uses native crop path")
 local rotated=r.photos[1]:getDevelopSettings();rotated.orientation="BC"
 eq(Crop.context(r.photos[1],rotated,true),nil,"rotation uses native crop path")
 rotated.orientation="AB";rotated.PerspectiveUpright=1
 eq(Crop.context(r.photos[1],rotated,true),nil,"Upright uses native crop path")
 eq(Crop.frame({width=6000,height=4000},46),nil,"direct frame rejects out-of-range angle")
end

-- Explicit photo-display choice must control the real application path.
do
 local r=run{n=2,module="library",direct=true,options={adjustedPhotoAction="skip",photoDisplayMode="openEachPhoto"}}
 eq(r.summary.applied,2,"open-each mode completes eligible photos")
 eq(#r.setValues,2,"open-each mode uses native angle controller")
 for _,p in ipairs(r.photos)do eq(p.directWrites,nil,"open-each mode never writes direct crop")end
 ok(#r.setSelectedEvents>0,"open-each mode selects individual photos")
 eq(r.prefs.runOptions.photoDisplayMode,"openEachPhoto","photo display choice persists")
 local P=dofile(plugin.."/RunPolicy.lua")
 eq(P.defaults({}).photoDisplayMode,"minimizeSwitching","fresh defaults minimize switching")
 eq(P.defaults({runOptions={photoDisplayMode="openEachPhoto"}}).photoDisplayMode,"openEachPhoto","saved open-each choice restored")
 local bad=P.defaults({});bad.photoDisplayMode="unknown"
 eq(P.validate(bad),nil,"invalid display mode is rejected")
 r=run{n=1,confirm="cancel"}
 local radios,tiltSourceOrder,tiltSourcePopups,overLimitPopup={}, {},0,nil
 local function inspect(node)
  if type(node)~="table" then return end
  local key=type(node.value)=="table" and node.value.bind or nil
  if node._type=="radio_button" then
   radios[key]=(radios[key] or 0)+1
   if key=="tiltSource" then tiltSourceOrder[#tiltSourceOrder+1]=node.checked_value end
  end
  if node._type=="popup_menu" and key=="tiltSource" then tiltSourcePopups=tiltSourcePopups+1 end
  if node._type=="popup_menu" and key=="overLimitAction" then overLimitPopup=node end
  for _,child in ipairs(node)do inspect(child)end
 end
 inspect(r.startInfo.contents)
 eq(radios.tiltSource,2,"tilt source presents two radio buttons")
 eq(tiltSourceOrder[1],"imageAnalysis","image analysis is the first tilt-source choice")
 eq(tiltSourceOrder[2],"inCameraData","recorded camera level is the second tilt-source choice")
 eq(radios.photoDisplayMode,2,"photo display presents two radio buttons")
 eq(tiltSourcePopups,0,"tilt source uses radio buttons")
 eq(overLimitPopup.items[1].value,"review","over-limit menu places review first")
 eq(overLimitPopup.items[2].value,"skip","over-limit menu places skip second")
 r=run{n=1,options={overLimitAction="review"}}
 eq(r.prefs.runOptions.overLimitAction,"review","menu reordering retains chosen review behavior")
end

-- Stop headings must cover cancellation between photos and during analysis.
do
  for _,opts in ipairs({{n=2,canceledAt=1},{n=2,module="library",direct=true,options={adjustedPhotoAction="skip"},onHelper=function(_,c) c.cancel() end}}) do
    local r=run(opts)
    local text={};collectText(r.resultInfo.contents,text)
    eq(r.report.rows[#r.report.rows].reason,"canceled","remaining row retains cancellation reason")
    ok(not text[1]:find("完了",1,true),"stopped batch never has a complete heading")
    ok(text[1]:find("中止",1,true) or text[1]:find("停止",1,true),"stopped batch has stop heading")
  end
  local r=run{n=1}
  local labels={};collectText(r.startInfo.contents,labels);collectText(r.resultInfo.contents,labels)
  ok(not table.concat(labels,"\n"):find("Enter",1,true),"dialogs omit keyboard hints")
  for _,caption in ipairs(r.captions) do ok(not caption:find("秒",1,true),"progress omits elapsed seconds") end
  local main=r.resultInfo.contents
  eq(main[1].title,"処理が完了しました","normal completion remains complete")
  local row=main[#main][1][1]
  eq(row[5].title,"","successful row omits repeated applied reason")
end

-- Calculation/review never opens a save checkpoint. Cancellation is a latch
-- until the current verified save finishes, then no next photo can start.
do
  for _,direct in ipairs({false,true}) do
    local base={n=2,module="library",direct=direct,options={adjustedPhotoAction="skip"}}
    local function scenario(extra)
      local opts={};for k,v in pairs(base) do opts[k]=v end;for k,v in pairs(extra)do opts[k]=v end;return run(opts)
    end
    local r=scenario{onHelper=function(_,c)c.cancel()end}
    eq(r.checkpointBegins,nil,"analysis cancellation creates no checkpoint")
    eq(r.summary.unprocessed,2,"analysis cancellation leaves both untouched")
    eq(#r.setValues,0,"analysis cancellation never uses Develop save")
    eq(r.photos[1].directWrites,nil,"analysis cancellation never uses direct save")
    r=scenario{checkpointBeginFails=true}
    eq(r.summary.fail,1,"checkpoint failure stops before write")
    eq(r.summary.unprocessed,1,"checkpoint failure leaves following photo unprocessed")
    eq(#r.setValues,0,"checkpoint failure never writes angle")
    eq(r.photos[1].directWrites,nil,"checkpoint failure never directly writes")
    r=scenario{onCheckpoint=function(c)c.cancel()end}
    eq(r.summary.unprocessed,2,"last-moment cancel leaves both untouched")
    eq(r.summary.fail,0,"last-moment cancel is normal stop")
    eq(r.checkpoint.record.state,"clear","unused checkpoint cleared")
    r=scenario{onDirectWrite=function(p,frame,c)c.cancel()end,onSetValue=function(k,v,c)c.cancel()end}
    eq(r.summary.applied,1,"save cancellation confirms only current photo")
    eq(r.summary.unprocessed,1,"save cancellation never starts second photo")
    eq(r.summary.fail,0,"confirmed save during cancellation is successful")
    eq(r.checkpointCompletes,1,"current save is journaled")
    local all=table.concat(r.captions,"\n")
    ok(all:find("現在の写真の保存を確認",1,true),"cancellation communicates current save confirmation")
    r=scenario{checkpointCompleteFails=true}
    eq(r.summary.applied,1,"completion journal failure does not hide applied photo")
    eq(r.summary.unprocessed,1,"completion journal failure stops later writes")
    eq(r.checkpoint.record.state,"pending","completion failure retains recovery record")
  end
  local late
  local r=run{n=2,thumbnail=function(p,w,h,callback)late=callback end,onSleep=function(s,c)if late then c.cancel()end end}
  eq(r.helperCalls,0,"cancel pending preview never analyzes")
  eq(r.summary.unprocessed,2,"cancel pending preview leaves photos untouched")
  if late then late("late jpeg") end
  eq(#r.setValues,0,"late thumbnail cannot edit a photo")
  r=run{n=2,startAngle=2,options={adjustedPhotoAction="reset"},onReset=function(c)c.cancel()end}
  eq(r.resets,1,"reset/save cancellation touches one photo")
  eq(#r.setValues,1,"reset/save cancellation completes one angle")
  eq(r.summary.applied,1,"reset/save current photo confirmed")
  eq(r.summary.unprocessed,1,"reset/save next photo untouched")
  r=run{n=2,recoveryAllowed=false}
  eq(r.confirms,0,"unresolved recovery does not open start options")
  eq(#r.setValues,0,"unresolved recovery cannot edit")
end

-- Develop may add only an empty AILook when opening a shared JPEG.
for _,case in ipairs({"empty_ai", "active_ai", "other_empty"}) do
  local r=run {
    sameNameMode="matchRaw", module="library", options={photoDisplayMode="openEachPhoto"},
    photos={
      {path="/dir/A.ARW",fileFormat="RAW"}, {path="/dir/A.JPG",fileFormat="JPEG"},
      {path="/dir/B.ARW",fileFormat="RAW"}, {path="/dir/B.JPG",fileFormat="JPEG"},
    },
    helper=function() return {kind="horizon",degrees=-.34} end,
    onGetDevelopSettings=function(p,c)
      if p.localIdentifier==2 and c.moduleName()=="develop" and c.activePhoto()==p then
        if case=="empty_ai" then p.settings.AILook={}
        elseif case=="active_ai" then p.settings.AILook={Amount=1}
        else p.settings.Look={} end
      end
    end,
  }
  if case=="empty_ai" then
    eq(r.summary.applied,4,"empty AILook initialization completes both pairs")
    eq(r.summary.unprocessed,0,"empty AILook does not abort remaining pairs")
    eq(type(r.photos[2].settings.AILook),"table","normalization does not modify photo settings")
  else
    eq(#r.setValues,1,case.." edit stops before writing the follower")
    ok(r.summary.body:find("settings_changed",1,true)~=nil,case.." still reports a settings conflict")
  end
end

-- Later RAWs initialize the profile's writer metadata on first Develop open.
-- Real profile edits must still stop before the second reference is written.
for _,case in ipairs({"writer_metadata", "profile", "amount", "curve", "process", "nested_ai"}) do
  local function settings()
    return {Look={Name="Adobe Color",UUID="profile-a",Amount=1,Parameters={
      Version="18.1",ProcessVersion="15.4",CameraProfile="Adobe Standard",
      ToneCurvePV2012={0,0,255,255}}}}
  end
  local r=run {
    sameNameMode="matchRaw",module="library",options={photoDisplayMode="openEachPhoto"},
    photos={
      {path="/dir/A.ARW",fileFormat="RAW",settings=settings()},
      {path="/dir/A.JPG",fileFormat="JPEG"},
      {path="/dir/B.ARW",fileFormat="RAW",settings=settings()},
      {path="/dir/B.JPG",fileFormat="JPEG"},
    },
    helper=function()return {kind="horizon",degrees=-.34}end,
    onGetDevelopSettings=function(p,c)
      if p.localIdentifier==3 and c.moduleName()=="develop" and c.activePhoto()==p then
        p.settings.AILook={}
        local look=p.settings.Look;local params=look.Parameters
        params.Version="18.5.1";params.AILook={}
        if case=="profile" then look.UUID="profile-b"
        elseif case=="amount" then look.Amount=.5
        elseif case=="curve" then params.ToneCurvePV2012={0,0,128,100,255,255}
        elseif case=="process" then params.ProcessVersion="16.0"
        elseif case=="nested_ai" then params.AILook={Amount=1} end
      end
    end,
  }
  if case=="writer_metadata" then
    eq(r.summary.applied,4,"writer metadata initialization completes both pairs")
    eq(r.summary.unprocessed,0,"writer metadata does not stop remaining photos")
    eq(r.photos[3].settings.Look.Parameters.Version,"18.5.1","normalization preserves actual writer metadata")
  else
    eq(#r.setValues,2,case.." stops before writing second reference")
    eq(r.summary.unprocessed,2,case.." leaves second pair unprocessed")
    ok(r.summary.body:find("settings_changed",1,true)~=nil,case.." remains a settings conflict")
  end
end

-- Self-induced visibility changes must not look like a user selection change.
for _,direct in ipairs({false,true}) do
  for _,kind in ipairs({"color","flag","quick"}) do
    local marked=0
    local r=run{n=3,module="library",direct=direct,quickMembers={1,2,3},
      options={adjustedPhotoAction="skip",processedColorLabelAction=kind=="color" and "green" or "keep",
        processedFlagAction=kind=="flag" and "pick" or "keep",processedQuickCollectionAction=kind=="quick" and "remove" or "keep"},
      onMark=function(p,key,value,c)
        marked=marked+1
        if marked<3 then ok(c.activePhoto()~=p,"handoff precedes filter-triggering mark") end
        c.hide(p)
      end,
      onQuickRemove=function(p,c)
        marked=marked+1
        if marked<3 then ok(c.activePhoto()~=p,"handoff precedes Quick Collection removal") end
        c.hide(p)
      end}
    eq(r.summary.applied,3,kind.." filter permits all photos")
    eq(r.summary.unprocessed,0,kind.." filter does not stop batch")
    eq(marked,3,kind.." marks each photo exactly once")
    for _,p in ipairs(r.photos)do
      if kind=="color" then eq(p.colorNameForLabel,"green","color persisted")
      elseif kind=="flag" then eq(p.pickStatus,1,"flag persisted")
      else eq(r.quickMembers[p],nil,"membership removed") end
    end
  end
end
-- Preflight-only skips must also be marked individually under a live filter.
do
 local r=run{n=3,sameNameMode="matchRaw",module="library",startAngle=2,options={adjustedPhotoAction="skip",skippedColorLabelAction="red"},
   onMark=function(p,k,v,c)c.hide(p)end}
 eq(r.summary.skip,3,"filtered preflight skips all complete")
 for _,p in ipairs(r.photos)do eq(p.colorNameForLabel,"red","preflight mark persists")end
end
-- A stop after one saved mark preserves that result and leaves the rest alone.
do
 local r=run{n=3,options={processedFlagAction="pick",processedColorLabelAction="green"},
   onMark=function(p,k,v,c)if p.localIdentifier==1 then c.cancel()end end}
 eq(r.summary.applied,1,"cancel after first mark stops new photo work")
 eq(r.photos[1].pickStatus,1,"cancel keeps completed flag")
 eq(r.photos[1].colorNameForLabel,"green","cancel completes current photo's marks")
 for i=2,3 do eq(r.photos[i].pickStatus,0,"unprocessed photo remains unmarked")end
end
-- A real user selection change during marks must not be overwritten by handoff.
do
 local r=run{n=3,options={processedFlagAction="pick"},onMark=function(p,k,v,c)c.setUser()end}
 eq(r.summary.applied,1,"user selection stops following photo processing")
 eq(r.overwritten,0,"marking never overwrites user selection")
 eq(r.photos[2].pickStatus,0,"next photo remains unmarked after selection change")
end

-- Preflight handoff failures must also report photos already queued for later work.
do
 local r=run{sameNameMode="matchRaw",module="library",photos={{angle=0},{angle=2},{angle=0}},
   options={adjustedPhotoAction="skip",skippedColorLabelAction="red"},onMark=function(p,k,v,c)c.setUser()end}
 eq(r.summary.skip,1,"completed preflight skip remains reported")
 eq(r.summary.unprocessed,2,"preflight stop includes earlier queued and later photos")
 eq(#r.setValues,0,"preflight stop never processes queued photos")
 eq(r.overwritten,0,"preflight stop preserves user selection")
end

-- Review F1: unchanged values cannot confirm tiny camera corrections.
for _,magnitude in ipairs({.01,.02,.049,.05,.051}) do
 for _,sign in ipairs({-1,1}) do
  for _,failure in ipairs({"first","all","delayed"}) do
   local angle=magnitude*sign
   local r=run{n=1,startAngle=0,options={tiltSource="inCameraData",adjustedPhotoAction="skip",processedFlagAction="pick"},
    helper=function()return {roll_only=true,roll_degrees=angle,make="Apple"}end,
    dropSetValue=function(attempt)return failure=="all" or (failure=="first" and attempt==1)end,
    deferPersistence=failure=="delayed",
    onSleep=function(_,c) if failure=="delayed" then
      local p=c.photos[1];if p.pendingAngle then p.savedAngle=p.angle;p.pendingAngle=nil end
    end end}
   local saved=failure~="all"
   eq(r.summary.applied,saved and 1 or 0,"tiny camera applied "..angle..failure)
   eq(r.summary.fail,saved and 0 or 1,"tiny camera failure "..angle..failure)
   eq(r.summary.noop,0,"tiny correction is not noop")
   ok(math.abs(r.photos[1].savedAngle-(saved and angle or 0))<1e-9,"tiny camera persisted")
   eq(r.photos[1].pickStatus,saved and 1 or 0,"tiny camera completion mark")
   eq(r.checkpoint.record.state,saved and "clear" or "pending","tiny camera checkpoint")
   eq(#r.setValues,failure=="delayed" and 1 or 2,"tiny camera bounded retry")
  end
 end
end

-- Tiny camera saves also govern group publication after Direct fallback.
for _,dropAll in ipairs({false,true}) do
 local r=run{sameNameMode="matchRaw",module="library",direct=true,
  options={tiltSource="inCameraData",adjustedPhotoAction="skip",processedFlagAction="pick"},
  photos={{path="/a/a.ARW",fileFormat="RAW",settings={CropConstrainAspectRatio=false}},
    {path="/a/a.JPG",fileFormat="JPEG",settings={CropConstrainAspectRatio=false}}},
  helper=function()return {roll_only=true,roll_degrees=.02,make="Apple"}end,
  dropSetValue=function(attempt)return dropAll or attempt==1 end}
 eq(r.summary.applied,dropAll and 0 or 2,"tiny group confirmed count")
 eq(r.photos[2].savedAngle,dropAll and 0 or .02,"tiny group confirmed reference only")
 eq(r.photos[2].pickStatus,dropAll and 0 or 1,"tiny group follower mark")
 if dropAll then eq(r.summary.unprocessed,1,"failed reference leaves follower unprocessed") end
end

-- Review F2: the final follower must not retry after source/target changes.
for _,change in ipairs({"reference_angle","reference_exposure","crop","selection","cancel"}) do
 local r=run{sameNameMode="matchRaw",options={adjustedPhotoAction="skip",processedFlagAction="pick"},
  photos={{path="/a/a.ARW",fileFormat="RAW",settings={Exposure2012=0}},
    {path="/a/a.JPG",fileFormat="JPEG",settings={Exposure2012=0}}},
  helper=function()return {degrees=2}end,
  dropSetValue=function(attempt,c)
   if attempt~=2 then return false end
   if change=="reference_angle" then c.photos[1].savedAngle=4 end
   if change=="reference_exposure" then c.photos[1].settings.Exposure2012=1 end
   if change=="crop" then c.photos[2].settings.CropLeft=.2 end
   if change=="selection" then c.setUser() end
   if change=="cancel" then c.cancel() end
   return true
  end}
 eq(#r.setValues,2,"no follower retry after "..change)
 eq(r.photos[2].savedAngle,0,"no stale reference applied "..change)
 eq(r.photos[2].pickStatus,0,"unconfirmed follower unmarked "..change)
 eq(r.checkpoint.record.state,"pending","follower recovery preserved "..change)
end

-- Review F3: display mode cannot reset a zero-angle manual crop.
for _,direct in ipairs({false,true}) do
 for _,angle in ipairs({0,2}) do
  local r=run{n=1,module="library",direct=direct,options={adjustedPhotoAction="reset"},
   photos={{angle=angle,settings={CropLeft=.2,CropTop=.2,CropRight=.8,CropBottom=.8,
     CropConstrainAspectRatio=true}}},helper=function()return {degrees=1}end}
  eq(r.summary.applied,1,"manual crop correction completes")
  if angle==0 then
   eq(r.photos[1].directWrites,nil,"zero angle manual crop uses Develop")
   eq(r.resets or 0,0,"zero angle manual crop not reset")
   eq(r.photos[1].settings.CropLeft,.2,"manual left retained")
   eq(r.photos[1].settings.CropRight,.8,"manual right retained")
  elseif not direct then eq(r.resets,1,"adjusted crop resets in Develop")
  else ok(r.photos[1].directWrites~=nil,"adjusted crop resets directly") end
 end
end

-- Oracle: Direct eligibility and estimation must share one immutable baseline.
do
 local reads=0
 local r=run{n=1,module="library",direct=true,options={adjustedPhotoAction="reset"},
  onGetDevelopSettings=function(p)
   reads=reads+1
   if reads==2 then p.settings.CropLeft=.2;p.settings.CropRight=.8 end
  end,helper=function()return {degrees=2}end}
 eq(r.photos[1].directWrites,nil,"changed manual crop never directly overwritten")
 eq(r.photos[1].settings.CropLeft,.2,"concurrent manual crop survives")
 eq(r.summary.applied,0,"concurrent crop is not marked applied")
end
for _,key in ipairs({'PerspectiveRotate','PerspectiveUpright','PerspectiveVertical','LensManualDistortionAmount'}) do
 local r=run{n=1,module="library",direct=true,options={tiltSource="inCameraData",adjustedPhotoAction="skip"},
  photos={{settings={[key]=5}}},helper=function()return {degrees=-2,roll_degrees=7,make="Apple"}end}
 eq(r.lastTiltSource,"imageAnalysis",key.." uses rendered preview")
 eq(r.lastOriginal,nil,key.." does not send camera original")
 eq(r.helperCalls,1,key.." does not first invoke camera helper")
 eq(r.photos[1].savedAngle,2,key.." saves image tiltSource instead of roll")
end


-- Raw wire input must not be normalized by the mock before protocol checks.
for _,variant in ipairs({"error","unknown","trailing","source","missing","range","huge"}) do
  local r=run{n=1,options={tiltSource="inCameraData",processedFlagAction="pick"},rawHelper=function(id)
    local base='{"schema":"batch-auto-straighten.horizon.v2","id":"'..id..'",'
    if variant=="source" then return base..'"source":"image_analysis","kind":"horizon","model_id":"m","correction_degrees":2.5}' end
    if variant=="huge" then return string.rep(" ",65537) end
    local kind=variant=="error" and "error" or variant=="unknown" and "unknown" or "horizon"
    local roll=variant=="missing" and "" or ',"roll_degrees":'..(variant=="range" and "181" or "2.5")
    return base..'"source":"camera_roll","kind":"'..kind..'","make":"Canon"'..roll..'}'..(variant=="trailing" and "garbage" or "")
  end}
  eq(#r.setValues,0,"raw "..variant.." no angle")
  eq(r.checkpointBegins or 0,0,"raw "..variant.." no save")
  eq(r.photos[1].pickStatus,0,"raw "..variant.." no marks")
  eq(r.summary.fail,1,"raw "..variant.." failure")
end
for _,direct in ipairs({false,true}) do
  local r=run{n=2,direct=direct,options={photoDisplayMode=direct and "minimizeSwitching" or "openEachPhoto",processedFlagAction="pick"},
    onGetDevelopSettings=function(photo) if photo.savedAngle~=0 then error("unique_readback_failure") end end}
  eq(r.photos[1].directWrites or 0,direct and 1 or 0,"readback exception covers intended write path")
  eq(r.report.rows[1].reason,"apply_unconfirmed","readback exception is unconfirmed")
  eq(r.report.rows[1].target,-3,"readback exception retains target")
  eq(r.checkpoint.record.state,"pending","readback exception retains pending")
  eq(r.summary.unprocessed,1,"readback exception stops later photo")
  eq(r.photos[1].pickStatus,0,"readback exception no success mark")
  local texts={};collectText(r.resultInfo.contents,texts)
  ok(table.concat(texts,"\n"):find("unique_readback_failure",1,true),"readback cause reaches actual UI")
end
for _,throws in ipairs({false,true}) do
  local r=run{n=3,tempThrows=throws,tempMissing=not throws}
  eq(#r.report.rows,3,"mkdir failure retains all photos")
  eq(r.summary.unprocessed,3,"mkdir failure all unprocessed")
  eq(#r.setValues,0,"mkdir failure no writes")
  eq(r.helperCalls,0,"mkdir failure no helper")
end
do
  local attempted=false
  local r=run{n=1,onGetDevelopSettings=function()error("preflight failure")end,
    onCleanup=function(ctx) if not attempted then attempted=true;ctx.reenter() end end}
  eq(r.confirms,1,"cleanup reentry cannot start dialog")
  eq(r.alreadyRunning,1,"cleanup retains lock")
  eq(r.running,false,"cleanup eventually releases lock")
end

-- Results nest inside the live progress modal; opening them after the scope
-- exits races Lightroom's asynchronous teardown and can strand the window.
do
  local r=run{n=2,helper=function() return {ok=true,kind="horizon",degrees=3} end}
  eq(r.resultDialogs,1,"results shown once")
  eq(r.resultNested,true,"results nest inside progress scope")
  eq(r.progressDone,true,"progress done after results")
  eq(r.running,false,"nested results release lock")
  local codec=realDofile(plugin .. "/dkjson.lua")
  local diagnostic=assert(codec.decode(r.diagnostics))
  eq(diagnostic.resultDialog,"ok","diagnostics record result dialog outcome")
end
do
  local r=run{n=1,resultDialogError=true,helper=function() return {ok=true,kind="horizon",degrees=3} end}
  eq(r.resultDialogs,1,"failed results dialog is not reopened")
  eq(r.running,false,"failed results dialog releases lock")
  ok(#r.messages==1 and r.messages[1].body:find("test result dialog failure",1,true),"failed results dialog reports its error")
end

do
  -- A second invocation during the error path's teardown wait is rejected.
  local reentered=false
  local r=run{n=1,resultDialogError=true,helper=function() return {ok=true,kind="horizon",degrees=3} end,
    onSleep=function(s,c) if (s or 0)>=0.5 and not reentered then reentered=true;c.reenter() end end}
  eq(reentered,true,"error path waits for teardown")
  eq(r.confirms,1,"reentry during error teardown opens no second start dialog")
  eq(r.alreadyRunning,1,"reentry during error teardown is rejected")
  eq(r.running,false,"error path releases lock afterwards")
end

-- finish() failures must not lose the report of adjusted photos.
do
  local r=run{n=2,restoreSelectionError=true,options={photoDisplayMode="openEachPhoto"},
    helper=function() return {ok=true,kind="horizon",degrees=3} end}
  eq(r.resultDialogs,1,"restore failure still shows results")
  eq(r.summary.applied,2,"restore failure keeps applied rows")
  eq(r.running,false,"restore failure releases lock")
  local codec=realDofile(plugin .. "/dkjson.lua")
  ok(assert(codec.decode(r.diagnostics)).finishError:find("restore selection failed",1,true),"restore failure is diagnosed")
end

-- Only a selection that is still the plug-in's own, in the expected module
-- and without Cancel, may be replaced by the user's initial selection.
do
  local glitched=false
  local r=run{n=2,options={photoDisplayMode="openEachPhoto"},
    helper=function() return {ok=true,kind="horizon",degrees=3} end,
    onHelper=function() glitched=true end,
    onGetTargetPhotos=function() if glitched then glitched=false;return {} end end}
  eq(r.summary.applied,0,"transitional selection read stops before applying")
  local last=r.setSelectedEvents[#r.setSelectedEvents]
  eq(last.count,2,"plug-in isolation is replaced by the initial selection")
end
do
  local r=run{n=2,options={photoDisplayMode="openEachPhoto"},
    helper=function() return {ok=true,kind="horizon",degrees=3} end,
    onSelectionSet=function(_,ps,c) if ps and #ps==1 then c.setModule("develop") end end}
  local last=r.setSelectedEvents[#r.setSelectedEvents]
  eq(last.count,1,"unexpected module keeps the current selection")
end

-- Cancel closes the progress modal immediately: results wait for teardown.
do
  local r=run{n=3,canceledAt=1,helper=function() return {ok=true,kind="horizon",degrees=3} end}
  eq(r.resultDialogs,1,"canceled run shows results once")
  eq(r.resultNested,nil,"canceled run does not nest results in a closed modal")
  eq(r.teardownWaited,true,"canceled run waits for progress teardown")
  eq(r.running,false,"canceled run releases lock")
end

-- A finishing failure is visible and does not skip checkpoint cleanup.
do
  local r=run{n=2,restoreSelectionError=true,options={photoDisplayMode="openEachPhoto"},
    helper=function() return {ok=true,kind="horizon",degrees=3} end}
  ok(r.report.title and (r.report.title:find("後処理",1,true) or r.report.title:find("finalized",1,true)),"finishing failure is shown in results")
  eq(r.checkpoint.record==nil or r.checkpoint.record.state~="complete",true,"finishing failure still clears completed checkpoint")
end

print(string.format("passed=%d failed=%d", passed, failed))
if failed > 0 then
  os.exit(1)
end
