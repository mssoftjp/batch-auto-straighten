local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
-- Result ordering, counts and local diagnostic text for a completed batch.
local HorizonMath = dofile(_PLUGIN.path .. "/HorizonMath.lua")
local M = {}

local SAME_NAME_MODE_LABELS = {
  individual = LOC("$$$/BatchAutoStraighten/Text013=Straighten each photo"),
  matchRendered = LOC("$$$/BatchAutoStraighten/Text014=Match to JPEG/HEIF"),
  matchRaw = LOC("$$$/BatchAutoStraighten/Text015=Match to RAW/DNG"),
}

local function countBy(rows, key)
  local out = {}
  for _, row in ipairs(rows) do
    local k = row[key] or "?"
    out[k] = (out[k] or 0) + 1
  end
  return out
end

local function formatCounts(map)
  local keys = {}
  for k in pairs(map) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format("%s=%d", k, map[k])
  end
  return table.concat(parts, ", ")
end

local function formatAngle(value)
  if not HorizonMath.isFiniteNumber(value) then
    return "-"
  end
  return string.format("%.2f", math.abs(value)<0.005 and 0 or value)
end

local function formatRow(row)
  local parts = { tostring(row.filename or row.id or "?") }
  if row.referenceFilename then
    parts[#parts + 1] = LOC("$$$/BatchAutoStraighten/Text020=Reference=") .. tostring(row.referenceFilename)
  end
  parts[#parts + 1] = LOC("$$$/BatchAutoStraighten/Text021=Before=") .. formatAngle(row.before)
  parts[#parts + 1] = LOC("$$$/BatchAutoStraighten/Text022=After=") .. formatAngle(row.after)
  local labels = {applied=LOC("$$$/BatchAutoStraighten/Text097=Applied"),below_deadband=LOC("$$$/BatchAutoStraighten/Text023=Unchanged"),aligned=LOC("$$$/BatchAutoStraighten/Text024=Already matched"),
    existing_angle=LOC("$$$/BatchAutoStraighten/Text025=Already adjusted; skipped"),angle_limit=LOC("$$$/BatchAutoStraighten/Text026=Over limit"),review_skipped=LOC("$$$/BatchAutoStraighten/Text027=Skipped during review"),
    no_horizon=LOC("$$$/BatchAutoStraighten/Text029=Could not estimate tilt"),reference_no_horizon=LOC("$$$/BatchAutoStraighten/Text030=Could not estimate reference tilt"),
    angle_outside_sdk=LOC("$$$/BatchAutoStraighten/Text031=Outside Lightroom's angle range"),reference_excluded=LOC("$$$/BatchAutoStraighten/Text032=Reference excluded"),canceled=LOC("$$$/BatchAutoStraighten/Text120=Not processed: stopped"),unprocessed=LOC("$$$/BatchAutoStraighten/Text033=Unprocessed")}
  local reason = tostring(row.reason or row.status or "")
  parts[#parts + 1] = labels[reason] and (labels[reason] .. " (" .. reason .. ")") or reason
  if row.target and row.status == "skip" then parts[#parts+1] = LOC("$$$/BatchAutoStraighten/Text034=Candidate=") .. formatAngle(row.target) .. "°" end
  if row.reason == "apply_unconfirmed" then
    local function precise(value)
      return HorizonMath.isFiniteNumber(value) and string.format("%.4f", value) or "-"
    end
    parts[#parts + 1] = string.format(LOC("$$$/BatchAutoStraighten/Text035=%s  Target=%s  UI=%s  Saved=%s"),
      tostring(row.detail or "unknown"), precise(row.target), precise(row.uiAfter), precise(row.after))
  end
  if row.mark then parts[#parts+1] = row.mark end
  return table.concat(parts, "  ")
end

function M.counts(rows)
  local counts = {applied=0, noop=0, skip=0, fail=0, unprocessed=0}
  for _, row in ipairs(rows) do
    local status = counts[row.status] and row.status or "unprocessed"
    counts[status] = counts[status] + 1
  end
  return counts
end

function M.build(rows, options)
  local counts = M.counts(rows)
  local body = string.format(
    LOC("$$$/BatchAutoStraighten/Text055=Same-name mode: %s^nApplied %d / Unchanged %d / Skipped %d / Needs review %d / Unprocessed %d^nReasons: %s"),
    SAME_NAME_MODE_LABELS[options.sameNameMode] or tostring(options.sameNameMode),
    counts.applied,
    counts.noop,
    counts.skip,
    counts.fail,
    counts.unprocessed,
    formatCounts(countBy(rows, "reason"))
  )
  if options.hasMarks then
    body = body .. LOC("$$$/BatchAutoStraighten/Text056=^nMark-based filters may hide photos after their marks change.")
  end
  if options.maybeChanged then
    body = body .. LOC("$$$/BatchAutoStraighten/Text057=^nPhotos marked Needs review may have changed. Check their History panel in Lightroom.")
  end
  for _, row in ipairs(rows) do
    if row.reason == "no_preview" then
      body = body .. "\nno_preview: " .. tostring(row.detail or "unspecified")
      local err = row.callbackErr
      if type(err) == "string" and err ~= "" then
        body = body .. ": " .. err
      elseif err ~= nil then
        body = body .. ": " .. tostring(err)
      end
      break
    end
  end
  for _, row in ipairs(rows) do
    if row.reason == "apply_failed" then
      local err = row.applyErr
      if type(err) == "string" and err ~= "" then
        body = body .. "\napply_failed: " .. err
      elseif err ~= nil then
        body = body .. "\napply_failed: " .. tostring(err)
      else
        body = body .. "\napply_failed: unspecified"
      end
      break
    end
  end
  if options.stopTitle then
    body = options.stopTitle .. "\n" .. body
  end
  local ordered = {}
  for i = 1, #rows do
    ordered[i] = rows[i]
  end
  table.sort(ordered, function(a, b)
    local ia, ib = tonumber(a.origIndex) or 0, tonumber(b.origIndex) or 0
    if ia ~= ib then
      return ia < ib
    end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  local detailLines = {}
  for i = 1, #ordered do
    detailLines[#detailLines + 1] = formatRow(ordered[i])
  end
  local details = table.concat(detailLines, "\n")
  return ordered, body, details
end

return M
