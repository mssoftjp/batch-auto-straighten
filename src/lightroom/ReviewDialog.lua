local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
local Dialogs = import "LrDialogs"
local Tasks = import "LrTasks"
local View = import "LrView"

-- Keep review inside Lightroom. Return defaults to Skip so a held key can never
-- approve the next photo. The accessory view owns every non-default decision so
-- the button order can stay meaningful without turning Escape into Apply.
-- Lightroom makes Escape inert when its native Cancel button is excluded.
return function(filename, photo, previewPath, target, limit, options)
  local decision, diagnostic = "stop", nil
  local ok, err = Tasks.pcall(function()
    assert(options and options.isCanceled, "review context missing")
    if options.isCanceled() then return end

    local f = View.osFactory()
    local image
    if previewPath then
      image = f:picture {
        value = previewPath,
        frame_width = 1,
      }
    else
      image = f:catalog_photo {
        photo = photo,
        width = 640,
        height = 400,
        frame_width = 1,
      }
    end

    local function choose(button, value)
      decision = value
      Dialogs.stopModalWithResult(button, "other")
    end

    local actions = f:row {
      fill_horizontal = 1,
      spacing = f:control_spacing(),
      f:push_button {
        title = LOC("$$$/BatchAutoStraighten/Text006=Stop Batch"),
        tooltip = LOC("$$$/BatchAutoStraighten/ReviewStopTip=Stop this batch and keep completed adjustments."),
        action = function(button) choose(button, "stop") end,
      },
      f:push_button {
        title = LOC("$$$/BatchAutoStraighten/ReviewApplyRemaining=Apply All Remaining"),
        tooltip = LOC("$$$/BatchAutoStraighten/ReviewApplyRemainingTip=Apply this correction and all remaining over-limit corrections in this run without asking again. Corrections within the limits continue normally."),
        action = function(button) choose(button, "apply_all_remaining") end,
      },
      f:push_button {
        title = LOC("$$$/BatchAutoStraighten/ReviewSkipRemaining=Skip All Remaining"),
        tooltip = LOC("$$$/BatchAutoStraighten/ReviewSkipRemainingTip=Skip this correction and all remaining over-limit corrections in this run without asking again. Corrections within the limits continue normally."),
        action = function(button) choose(button, "skip_all_remaining") end,
      },
      f:spacer { fill_horizontal = 1 },
      f:push_button {
        title = LOC("$$$/BatchAutoStraighten/Text004=Apply Angle"),
        tooltip = LOC("$$$/BatchAutoStraighten/ReviewApplyTip=Apply this angle despite the limit. Matching photos in the same group can also use this reference angle."),
        action = function(button) choose(button, "apply") end,
      },
    }

    local result = Dialogs.presentModalDialog {
      title = LOC("$$$/BatchAutoStraighten/Text003=Angle Exceeds Limit"),
      resizable = true,
      contents = f:column {
        spacing = f:control_spacing(),
        f:static_text {
          title = filename,
          font = "<system/bold>",
        },
        image,
        f:static_text {
          title = string.format(
              LOC("$$$/BatchAutoStraighten/Text008=Proposed angle: %+.2f° · Limit: %+.2f°"),
              target,
              limit
            ),
        },
        f:static_text {
          width = 640,
          height_in_lines = 2,
          title = previewPath and LOC("$$$/BatchAutoStraighten/ReviewPreviewNote=The white frame shows the approximate crop after correction.")
            or LOC("$$$/BatchAutoStraighten/ReviewNoPreviewNote=The correction preview is unavailable. This is the current photo."),
        },
        f:static_text {
          width = 640,
          height_in_lines = 2,
          title = LOC("$$$/BatchAutoStraighten/ReviewRemainingNote=All Remaining includes this correction and later corrections over the limit. Photos within the limits continue normally."),
        },
      },
      accessoryView = actions,
      actionVerb = LOC("$$$/BatchAutoStraighten/Text005=Skip"),
      cancelVerb = "< exclude >",
    }

    if result == "ok" then
      decision = "skip"
    elseif result ~= "other" and result ~= "cancel" and result ~= nil then
      error("unknown review dialog result: " .. tostring(result))
    end
  end)
  if not ok then diagnostic = tostring(err) end
  return decision, diagnostic
end
