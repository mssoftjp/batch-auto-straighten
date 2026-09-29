local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
local Binding = import "LrBinding"
local Context = import "LrFunctionContext"
local Dialogs = import "LrDialogs"
local View = import "LrView"
local P = dofile(_PLUGIN.path .. "/RunPolicy.lua")
return function(n, prefs)
  local chosen
  Context.callWithContext("BatchAutoStraightenStart", function(context)
    local f, bind = View.osFactory(), View.bind
    local props = Binding.makePropertyTable(context)
    for k, v in pairs(P.defaults(prefs)) do props[k] = v end
    local lastEdited = "maxLeftAngle"
    local function updateLinkTip()
      local value = P.normalizeAngleLimit(props[lastEdited])
      props.angleLinkTip = props.angleLimitsLinked
        and LOC("$$$/BatchAutoStraighten/UnlinkAngleLimitsTip=Adjust the left and right limits separately.")
        or (value and string.format(LOC("$$$/BatchAutoStraighten/LinkAngleLimitsTip=Set both limits to %.1f° and link them."),value)
          or LOC("$$$/BatchAutoStraighten/Text009=Enter a number from 0 to 45 for each angle limit."))
    end
    local function angleChanged(_, key, value)
      local normalized = P.normalizeAngleLimit(value)
      if normalized == nil then return end
      if P.normalizeAngleLimit(props[key]) ~= normalized then return end
      if props.angleLimitsLinked then
        local other = key == "maxLeftAngle" and "maxRightAngle" or "maxLeftAngle"
        -- Mirrored notifications can arrive later; they must not become edits.
        if P.normalizeAngleLimit(props[other]) == normalized then return end
        props[other] = normalized
      end
      lastEdited = key
      updateLinkTip()
    end
    props:addObserver("maxLeftAngle", angleChanged)
    props:addObserver("maxRightAngle", angleChanged)
    updateLinkTip()
    local function toggleAngleLink()
      if props.angleLimitsLinked then
        props.angleLimitsLinked = false
      else
        local value = P.normalizeAngleLimit(props[lastEdited])
        if value == nil or P.normalizeAngleLimit(props.maxLeftAngle) == nil
          or P.normalizeAngleLimit(props.maxRightAngle) == nil then
          Dialogs.message(LOC("$$$/BatchAutoStraighten/Text095=Check Settings"),
            LOC("$$$/BatchAutoStraighten/Text009=Enter a number from 0 to 45 for each angle limit."),"warning")
          return
        end
        props.maxLeftAngle, props.maxRightAngle = value, value
        props.angleLimitsLinked = true
      end
      updateLinkTip()
    end
    local function text(title,width) return f:static_text {title=title,width=width} end
    local function item(title,value) return {title=title,value=value} end
    local function popup(key,items,width,tooltip) return f:popup_menu {value=bind(key),items=items,width=width or 300,tooltip=tooltip} end
    local function angleInput(key)
      return f:edit_field {
        value=bind(key),width=55,min=0,max=45,precision=1,immediate=true,
        tooltip=LOC("$$$/BatchAutoStraighten/AngleLimitTip=Limits apply to the final angle in Crop & Straighten. Left is negative; right is positive."),
        validate=function(_,value)
          local normalized=P.normalizeAngleLimit(value)
          if normalized then return true,normalized end
          return false,value,LOC("$$$/BatchAutoStraighten/Text009=Enter a number from 0 to 45 for each angle limit.")
        end,
      }
    end
    local function marks(title,collectionAction,flag,colorLabel)
      local function column(caption,key,items,width,tooltip)
        return f:column {spacing=5,text(caption),popup(key,items,width,tooltip or LOC("$$$/BatchAutoStraighten/Text076=The selected flag and color label replace the current values. Choose No Change to keep them."))}
      end
      return f:group_box {title=title,spacing=7,fill_horizontal=1,
        f:row {spacing=12,
          column(LOC("$$$/BatchAutoStraighten/Text061=Quick Collection"),collectionAction,{item(LOC("$$$/BatchAutoStraighten/Text062=No Change"),"keep"),item(LOC("$$$/BatchAutoStraighten/Text063=Add"),"add"),item(LOC("$$$/BatchAutoStraighten/Text064=Remove"),"remove")},180,
            LOC("$$$/BatchAutoStraighten/QuickCollectionTip=Add photos to Quick Collection or remove them from it. Removing them keeps the photos in the catalog and on disk.")),
          column(LOC("$$$/BatchAutoStraighten/Text065=Flag"),flag,{item(LOC("$$$/BatchAutoStraighten/Text062=No Change"),"keep"),item(LOC("$$$/BatchAutoStraighten/Text066=Pick"),"pick"),item(LOC("$$$/BatchAutoStraighten/Text067=Reject"),"reject"),item(LOC("$$$/BatchAutoStraighten/Text068=Clear Flag"),"clear")},150),
          column(LOC("$$$/BatchAutoStraighten/Text069=Color label"),colorLabel,{item(LOC("$$$/BatchAutoStraighten/Text062=No Change"),"keep"),item(LOC("$$$/BatchAutoStraighten/Text070=Red"),"red"),item(LOC("$$$/BatchAutoStraighten/Text071=Yellow"),"yellow"),item(LOC("$$$/BatchAutoStraighten/Text072=Green"),"green"),item(LOC("$$$/BatchAutoStraighten/Text073=Blue"),"blue"),item(LOC("$$$/BatchAutoStraighten/Text074=Purple"),"purple"),item(LOC("$$$/BatchAutoStraighten/Text075=Clear Color Label"),"none")},150),
        },
      }
    end
    local contents=f:column {
      bind_to_object=props,spacing=12,width=540,
      f:static_text {title=string.format(LOC("$$$/BatchAutoStraighten/Text077=Selected photos: %d"),n),font="<system/bold>"},
      f:group_box {title=LOC("$$$/BatchAutoStraighten/Text078=Photos with the Same Name"),spacing=7,fill_horizontal=1,
        f:row {spacing=16,
          f:radio_button {title=LOC("$$$/BatchAutoStraighten/Text079=Straighten each photo"),value=bind("sameNameMode"),checked_value="individual",
            tooltip=LOC("$$$/BatchAutoStraighten/IndividualTip=Straighten each selected photo independently, even when filenames match.")},
          f:radio_button {title=LOC("$$$/BatchAutoStraighten/Text080=Match to RAW/DNG"),value=bind("sameNameMode"),checked_value="matchRaw",
            tooltip=LOC("$$$/BatchAutoStraighten/SameNameTip=Match crop angles for selected photos in the same folder with the same base filename. Use the chosen format as the reference when available.")},
          f:radio_button {title=LOC("$$$/BatchAutoStraighten/Text081=Match to JPEG/HEIF"),value=bind("sameNameMode"),checked_value="matchRendered",
            tooltip=LOC("$$$/BatchAutoStraighten/SameNameTip=Match crop angles for selected photos in the same folder with the same base filename. Use the chosen format as the reference when available.")},
        },
      },
      f:group_box {title=LOC("$$$/BatchAutoStraighten/Text082=Straightening"),spacing=9,fill_horizontal=1,
        f:row {spacing=16,text(LOC("$$$/BatchAutoStraighten/Text155=Tilt estimation"),128),
          f:column {spacing=5,
            f:radio_button {title=LOC("$$$/BatchAutoStraighten/ImageAnalysisFirst=Image analysis only"),value=bind("tiltSource"),checked_value="imageAnalysis",
              tooltip=LOC("$$$/BatchAutoStraighten/ImageAnalysisOnly=Estimate tilt from the current preview without using recorded camera-level data.")},
            f:radio_button {title=LOC("$$$/BatchAutoStraighten/Text156=Prefer camera level (experimental)"),value=bind("tiltSource"),checked_value="inCameraData",
              tooltip=LOC("$$$/BatchAutoStraighten/CameraFallback=Use recorded camera-level data when it is available and works with the current edits. Otherwise, use image analysis.")},
          },
        },
        f:row {spacing=8,text(LOC("$$$/BatchAutoStraighten/Text083=Angle limits"),128),text(LOC("$$$/BatchAutoStraighten/Text084=Left")),angleInput("maxLeftAngle"),text("°"),
          f:push_button {width=32,height=24,title="",
            image_name=bind {key="angleLimitsLinked",transform=function(linked)
              return _PLUGIN:resourceId("Resources/" .. (linked and "AngleLimitsLinked.pdf" or "AngleLimitsSeparate.pdf"))
            end},
            tooltip=bind("angleLinkTip"),action=toggleAngleLink},
          text(LOC("$$$/BatchAutoStraighten/Text085=Right")),angleInput("maxRightAngle"),text("°")},
        f:row {spacing=8,f:spacer {width=128},f:static_text {width=350,
          title=bind {key="angleLimitsLinked",transform=function(linked)
            return linked and LOC("$$$/BatchAutoStraighten/AngleLimitsLinked=Left and right linked")
              or LOC("$$$/BatchAutoStraighten/AngleLimitsSeparate=Adjust left and right separately")
          end}}},
        f:row {spacing=8,text(LOC("$$$/BatchAutoStraighten/Text086=Over the limit"),128),popup("overLimitAction",{item(LOC("$$$/BatchAutoStraighten/Text087=Review First"),"review"),item(LOC("$$$/BatchAutoStraighten/Text005=Skip"),"skip")},300,
          LOC("$$$/BatchAutoStraighten/OverLimitTip=Review or skip a correction when its final angle exceeds either limit."))},
        f:row {spacing=8,text(LOC("$$$/BatchAutoStraighten/Text088=Adjusted photos"),128),popup("adjustedPhotoAction",{item(LOC("$$$/BatchAutoStraighten/Text089=Reset and Straighten"),"reset"),item(LOC("$$$/BatchAutoStraighten/Text005=Skip"),"skip")},300,
          LOC("$$$/BatchAutoStraighten/ExistingAngleTip=Applies to photos with a nonzero Crop & Straighten angle. Other edits, including a crop with a zero angle, do not cause a photo to be skipped."))},
        f:static_text {width=500,height_in_lines=2,title=bind {key="adjustedPhotoAction",transform=function(value) return value=="reset" and LOC("$$$/BatchAutoStraighten/Text090=Applying a new angle also resets the crop.") or "" end}},
      },
      f:group_box {title=LOC("$$$/BatchAutoStraighten/ProcessingDisplay=Photo Display"),spacing=7,fill_horizontal=1,
        f:row {spacing=16,
          f:radio_button {title=LOC("$$$/BatchAutoStraighten/MinimizeSwitching=Minimize view changes"),value=bind("photoDisplayMode"),checked_value="minimizeSwitching",
            tooltip=LOC("$$$/BatchAutoStraighten/DisplayNote=Keep view changes to a minimum. Lightroom may open Library or Develop when needed.")},
          f:radio_button {title=LOC("$$$/BatchAutoStraighten/OpenEachPhoto=Show each photo"),value=bind("photoDisplayMode"),checked_value="openEachPhoto",
            tooltip=LOC("$$$/BatchAutoStraighten/OpenEachPhotoTip=Show each photo in the Develop module while processing it.")},
        },
      },
      marks(LOC("$$$/BatchAutoStraighten/Text091=Processed Photos"),"processedQuickCollectionAction","processedFlagAction","processedColorLabelAction"),
      marks(LOC("$$$/BatchAutoStraighten/Text092=Skipped Photos"),"skippedQuickCollectionAction","skippedFlagAction","skippedColorLabelAction"),
    }
    while true do
      local result=Dialogs.presentModalDialog {title=LOC("$$$/BatchAutoStraighten/Text043=Batch Auto Straighten"),actionVerb=LOC("$$$/BatchAutoStraighten/Text093=Straighten Photos"),cancelVerb=LOC("$$$/BatchAutoStraighten/Text094=Cancel"),contents=contents}
      if result~="ok" then break end
      local o={}
      for k in pairs(P.defaults({})) do o[k]=props[k] end
      local valid,err=P.validate(o)
      if valid then
        prefs.runOptions=valid
        chosen=valid
        break
      end
      Dialogs.message(LOC("$$$/BatchAutoStraighten/Text095=Check Settings"),err,"warning")
    end
  end)
  return chosen
end
