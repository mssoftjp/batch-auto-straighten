local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
local View = import "LrView"
local Dialogs = import "LrDialogs"
local RunReport = dofile(_PLUGIN.path .. "/RunReport.lua")
local M = {}
local statusNames = {applied=LOC("$$$/BatchAutoStraighten/Text097=Applied"),noop=LOC("$$$/BatchAutoStraighten/Text023=Unchanged"),skip=LOC("$$$/BatchAutoStraighten/Text098=Skipped"),fail=LOC("$$$/BatchAutoStraighten/Text099=Needs review"),unprocessed=LOC("$$$/BatchAutoStraighten/Text033=Unprocessed")}
local reasons = {
  applied=LOC("$$$/BatchAutoStraighten/Text097=Applied"),below_deadband=LOC("$$$/BatchAutoStraighten/Text100=No correction needed"),aligned=LOC("$$$/BatchAutoStraighten/Text101=Already matches the reference"),
  existing_angle=LOC("$$$/BatchAutoStraighten/Text102=Crop angle is already set"),angle_limit=LOC("$$$/BatchAutoStraighten/Text103=Exceeds the angle limit"),review_skipped=LOC("$$$/BatchAutoStraighten/Text104=Skipped during review"),
  no_horizon=LOC("$$$/BatchAutoStraighten/Text105=Could not estimate tilt"),reference_no_horizon=LOC("$$$/BatchAutoStraighten/Text106=Could not estimate tilt for the reference photo"),
  reference_excluded=LOC("$$$/BatchAutoStraighten/Text107=Reference skipped"),reference_failed=LOC("$$$/BatchAutoStraighten/Text108=Check the reference photo"),
  angle_outside_sdk=LOC("$$$/BatchAutoStraighten/Text031=Outside Lightroom's angle range"),not_still=LOC("$$$/BatchAutoStraighten/Text111=Videos are not supported"),
  missing_original=LOC("$$$/BatchAutoStraighten/Text112=Original file not found"),no_preview=LOC("$$$/BatchAutoStraighten/Text113=Could not create a preview"),
  helper_failed=LOC("$$$/BatchAutoStraighten/Text114=Could not run tilt analysis"),
  helper_blocked=LOC("$$$/BatchAutoStraighten/HelperBlocked=A bundled tool could not run. macOS may have blocked it. Connect to the internet and retry with the latest signed, notarized release. If it still fails, check System Settings → Privacy & Security."),
  helper_protocol=LOC("$$$/BatchAutoStraighten/Text115=Could not read analysis results"),
  helper_error=LOC("$$$/BatchAutoStraighten/Text116=Tilt analysis failed"),not_ready=LOC("$$$/BatchAutoStraighten/Text117=Develop module was not ready"),
  checkpoint_failed=LOC("$$$/BatchAutoStraighten/CheckpointFailed=Stopped because the processing record could not be saved."),
  apply_failed=LOC("$$$/BatchAutoStraighten/Text118=Could not complete the adjustment"),apply_unconfirmed=LOC("$$$/BatchAutoStraighten/Text119=Could not verify the saved crop and angle"),
  review_failed=LOC("$$$/BatchAutoStraighten/ReviewFailed=The review dialog could not complete. Processing stopped."),
  canceled=LOC("$$$/BatchAutoStraighten/Text120=Not processed: stopped"),selection_changed=LOC("$$$/BatchAutoStraighten/Text121=Stopped: selection changed"),
  module_changed=LOC("$$$/BatchAutoStraighten/Text122=Stopped: module changed"),settings_changed=LOC("$$$/BatchAutoStraighten/Text123=Stopped: Develop settings changed"),
  reference_settings_changed=LOC("$$$/BatchAutoStraighten/Text124=Stopped: reference settings changed"),unprocessed=LOC("$$$/BatchAutoStraighten/Text125=Not processed"),
  temp_dir_failed=LOC("$$$/BatchAutoStraighten/Text126=Could not create temporary files"),exception=LOC("$$$/BatchAutoStraighten/Text127=Could not complete processing"),
}
local function angle(n)
  if type(n)~="number" or n~=n or math.abs(n)==math.huge then return "—" end
  return string.format("%.2f°", math.abs(n)<0.005 and 0 or n)
end
local function preciseAngle(n)
  if type(n)~="number" or n~=n or math.abs(n)==math.huge then return "—" end
  return string.format("%.4f",math.abs(n)<0.00005 and 0 or n):gsub("0+$", ""):gsub("%.$", "") .. "°"
end
function M.methodLabel(r)
  if r.source == "image_analysis" then
    return LOC("$$$/BatchAutoStraighten/ImageAnalysis=Image analysis")
  end
  if r.source == "camera_roll" then
    return LOC("$$$/BatchAutoStraighten/Text162=Recorded camera level")
  end
  if r.source == "reference" then
    if r.referenceFormat and r.referenceFormat ~= "" then
      return string.format(LOC("$$$/BatchAutoStraighten/SyncedToFormat=Synced to %s settings"),r.referenceFormat)
    end
    return LOC("$$$/BatchAutoStraighten/Text164=Synced to reference settings")
  end
  return "—"
end
function M.rowValues(r)
  local note = reasons[r.reason] or LOC("$$$/BatchAutoStraighten/Text128=Check the diagnostic information")
  if r.detail == "saved_angle_outside_limits" then note=LOC("$$$/BatchAutoStraighten/Text129=Saved angle exceeds the limit") end
  if r.detail == "settings_changed_during_save" then note=LOC("$$$/BatchAutoStraighten/Text130=Develop settings changed while saving") end
  if r.status=="skip" and r.target then note=note .. LOC("$$$/BatchAutoStraighten/Text131= (proposed angle: ") .. angle(r.target) .. LOC("$$$/BatchAutoStraighten/CandidateClose=)") end
  if r.status=="applied" and r.reason=="applied" then note="" end
  if r.mark then note=note .. (note~="" and " / " or "") .. r.mark end
  if r.status=="fail" then
    local detail={tostring(r.reason or "")}
    for _,key in ipairs({"detail","error","applyErr"}) do
      if type(r[key])=="string" and r[key]~="" then detail[#detail+1]=r[key]:sub(1,1024) end
    end
    note=note .. "\n" .. table.concat(detail,": ")
  end
  local name=r.filename or r.id or "—"
  if r.referenceFilename then
    note=note .. (note~="" and "\n" or "") .. LOC("$$$/BatchAutoStraighten/Text132=Reference: ") .. r.referenceFilename
  end
  local change="—"
  if r.status=="applied" then change=angle(r.before) .. " → " .. angle(r.after)
  elseif r.status=="noop" then change=angle(r.after)
  elseif r.reason=="existing_angle" then change=angle(r.before) .. LOC("$$$/BatchAutoStraighten/Text133= (kept)") end
  if r.status=="fail" and r.reason=="apply_unconfirmed" then
    change=LOC("$$$/BatchAutoStraighten/Text134=Saved ") .. preciseAngle(r.after) .. LOC("$$$/BatchAutoStraighten/Text135=^nTarget ") .. preciseAngle(r.target)
  end
  return {name,statusNames[r.status] or LOC("$$$/BatchAutoStraighten/Text033=Unprocessed"),change,M.methodLabel(r),note}
end
function M.show(rows, stopTitle, maybeChanged)
  local f=View.osFactory()
  local counts = RunReport.counts(rows)
  local parts={string.format(LOC("$$$/BatchAutoStraighten/Text136=Applied: %d"),counts.applied)}
  for _,k in ipairs({"noop","skip","fail","unprocessed"}) do
    if counts[k]>0 then parts[#parts+1]=string.format(LOC("$$$/BatchAutoStraighten/Text137=%s: %d"),statusNames[k],counts[k]) end
  end
  local summary=table.concat(parts," · ")
  local heading=stopTitle or (counts.unprocessed>0 and LOC("$$$/BatchAutoStraighten/Text058=Processing stopped."))
    or (counts.fail>0 and LOC("$$$/BatchAutoStraighten/Text138=Some Photos Need Review") or LOC("$$$/BatchAutoStraighten/Text139=Batch Complete"))
  local widths={218,92,118,120,172}
  local function tableRow(values,header)
    local cells={spacing=10}
    for i,value in ipairs(values) do
      cells[#cells+1]=f:static_text {title=value,width=widths[i],height_in_lines=header and 1 or 2,
        font=header and "<system/bold>" or "<system>",selectable=not header,tooltip=not header and value or nil}
    end
    return f:row(cells)
  end
  local body={spacing=3}
  for _,r in ipairs(rows) do
    body[#body+1]=tableRow(M.rowValues(r),false)
    body[#body+1]=f:separator {fill_horizontal=1}
  end
  local listHeight=math.max(100,math.min(350,#rows*40))
  local main={spacing=10,
    f:static_text {title=heading,font="<system/bold>",width=780},
    f:static_text {title=summary,width=780},
  }
  if maybeChanged then main[#main+1]=f:static_text {title=LOC("$$$/BatchAutoStraighten/Text145=Photos marked Needs review may have changed. Check their History panel in Lightroom."),width=780} end
  main[#main+1]=tableRow({LOC("$$$/BatchAutoStraighten/Text146=Photo"),LOC("$$$/BatchAutoStraighten/Text147=Result"),LOC("$$$/BatchAutoStraighten/Text148=Angle"),LOC("$$$/BatchAutoStraighten/Text161=Method"),LOC("$$$/BatchAutoStraighten/Text149=Details")},true)
  main[#main+1]=f:scrolled_view {width=790,height=listHeight,horizontal_scroller=false,vertical_scroller=true,f:column(body)}
  return Dialogs.presentModalDialog {title=LOC("$$$/BatchAutoStraighten/Text150=Batch Auto Straighten Results"),actionVerb=LOC("$$$/BatchAutoStraighten/ResultDone=Done"),cancelVerb="< exclude >",resizable=true,contents=f:column(main)}
end
return M
