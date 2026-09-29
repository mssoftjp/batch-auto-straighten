--[[
  Group selected photos for independent or shared-angle processing.
  Groups are same parent folder + stem (last extension stripped).
  Selected photos only; no catalog search.
]]

local GroupPlan = {}

GroupPlan.MODE_INDIVIDUAL = "individual"
GroupPlan.MODE_MATCH_RENDERED = "matchRendered"
GroupPlan.MODE_MATCH_RAW = "matchRaw"

local RENDERED_EXT = {
  jpg = true,
  jpeg = true,
  heic = true,
  heif = true,
  hif = true,
}

function GroupPlan.validMode(sameNameMode)
  return sameNameMode == GroupPlan.MODE_INDIVIDUAL
    or sameNameMode == GroupPlan.MODE_MATCH_RENDERED
    or sameNameMode == GroupPlan.MODE_MATCH_RAW
end

function GroupPlan.isRenderedExt(ext)
  return RENDERED_EXT[string.lower(tostring(ext or ""))] == true
end

function GroupPlan.isRawFormat(fileFormat)
  local fmt = string.upper(tostring(fileFormat or ""))
  return fmt == "RAW" or fmt == "DNG"
end

function GroupPlan.splitPath(path)
  path = tostring(path or "")
  -- macOS only: '/' separates directories. Backslash is a legal filename character.
  local parent, leaf = string.match(path, "^(.*)/([^/]+)$")
  if leaf == nil then
    parent = ""
    leaf = path
  end
  local stem, ext = string.match(leaf, "^(.*)%.([^%.]+)$")
  if stem == nil then
    stem = leaf
    ext = ""
  end
  return parent, stem, ext, leaf
end

function GroupPlan.groupKey(path)
  local parent, stem, ext, leaf = GroupPlan.splitPath(path)
  return parent .. "\0" .. stem, parent, stem, ext, leaf
end

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

local function usableStill(entry)
  return entry and entry.isVideo ~= true and entry.missingOriginal ~= true
end

local function isPreferred(entry, sameNameMode)
  if not usableStill(entry) then
    return false
  end
  if sameNameMode == GroupPlan.MODE_MATCH_RENDERED then
    return GroupPlan.isRenderedExt(entry.ext)
  end
  if sameNameMode == GroupPlan.MODE_MATCH_RAW then
    return GroupPlan.isRawFormat(entry.fileFormat) or entry.isRaw == true
  end
  return false
end

local function pickReference(members, sameNameMode, activeId)
  local preferred = {}
  local usable = {}
  for i = 1, #members do
    local entry = members[i]
    if usableStill(entry) then
      usable[#usable + 1] = entry
      if isPreferred(entry, sameNameMode) then
        preferred[#preferred + 1] = entry
      end
    end
  end
  local pool = #preferred > 0 and preferred or usable
  if #pool == 0 then
    return nil
  end
  if activeId ~= nil then
    for i = 1, #pool do
      if pool[i].id == activeId then
        return pool[i]
      end
    end
  end
  pool = copySeq(pool)
  table.sort(pool, function(a, b)
    local pa, pb = tostring(a.path or ""), tostring(b.path or "")
    if pa ~= pb then
      return pa < pb
    end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  return pool[1]
end

local function singletonGroup(entry)
  return {
    shared = false,
    key = GroupPlan.groupKey(entry.path or ""),
    members = { entry },
    reference = entry,
    followers = {},
  }
end

function GroupPlan.plan(entries, sameNameMode, activeId)
  entries = entries or {}
  if not GroupPlan.validMode(sameNameMode) then
    sameNameMode = GroupPlan.MODE_INDIVIDUAL
  end
  if sameNameMode == GroupPlan.MODE_INDIVIDUAL then
    local groups = {}
    for i = 1, #entries do
      groups[i] = singletonGroup(entries[i])
    end
    return groups
  end

  local groups = {}
  local indexByKey = {}
  for i = 1, #entries do
    local entry = entries[i]
    if entry.ext == nil or entry.leaf == nil then
      local _, _, ext, leaf = GroupPlan.splitPath(entry.path)
      if entry.ext == nil then
        entry.ext = ext
      end
      if entry.leaf == nil then
        entry.leaf = leaf
      end
    end
    local key = GroupPlan.groupKey(entry.path)
    local group = indexByKey[key]
    if group == nil then
      group = { key = key, members = {} }
      indexByKey[key] = group
      groups[#groups + 1] = group
    end
    group.members[#group.members + 1] = entry
  end

  for i = 1, #groups do
    local group = groups[i]
    local stills = 0
    for m = 1, #group.members do
      if usableStill(group.members[m]) then
        stills = stills + 1
      end
    end
    local reference = pickReference(group.members, sameNameMode, activeId)
    if stills < 2 or reference == nil then
      group.shared = false
      group.reference = reference or group.members[1]
      group.followers = {}
    else
      group.shared = true
      group.reference = reference
      group.followers = {}
      for m = 1, #group.members do
        local entry = group.members[m]
        if entry ~= reference then
          group.followers[#group.followers + 1] = entry
        end
      end
    end
  end
  return groups
end

function GroupPlan.jobs(groups)
  local jobs = {}
  groups = groups or {}
  for i = 1, #groups do
    local group = groups[i]
    if group.shared and group.reference then
      jobs[#jobs + 1] = {
        role = "reference",
        entry = group.reference,
        photo = group.reference.photo,
        group = group,
      }
      for f = 1, #group.followers do
        local entry = group.followers[f]
        jobs[#jobs + 1] = {
          role = "follower",
          entry = entry,
          photo = entry.photo,
          group = group,
        }
      end
    else
      for m = 1, #group.members do
        local entry = group.members[m]
        jobs[#jobs + 1] = {
          role = "individual",
          entry = entry,
          photo = entry.photo,
          group = group,
        }
      end
    end
  end
  return jobs
end

return GroupPlan
