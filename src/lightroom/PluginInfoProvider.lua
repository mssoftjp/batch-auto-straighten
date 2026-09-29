local LOC = dofile(_PLUGIN.path .. "/Localization.lua")
local Http = import "LrHttp"
local Info = dofile(_PLUGIN.path .. "/Info.lua")

local REPOSITORY_URL = "https://github.com/mssoftjp/batch-auto-straighten"
local RELEASES_URL = REPOSITORY_URL .. "/releases"

return {
  sectionsForTopOfDialog = function(f, _)
    return {
      {
        title = "Batch Auto Straighten",
        synopsis = Info.VERSION.display,

        f:column {
          spacing = f:control_spacing(),
          fill_horizontal = 1,

          f:static_text {
            width = 520,
            height_in_lines = 2,
            title = LOC("$$$/BatchAutoStraighten/PluginInfoDescription=Automatically straighten selected photos in Lightroom Classic. Match angles across RAW and JPEG pairs."),
          },

          f:static_text {
            width = 520,
            title = LOC("$$$/BatchAutoStraighten/PluginInfoPlatform=Requires an Apple silicon Mac with macOS 26 or later."),
          },

          f:row {
            spacing = f:control_spacing(),

            f:push_button {
              title = LOC("$$$/BatchAutoStraighten/PluginInfoGitHub=View Guide"),
              tooltip = LOC("$$$/BatchAutoStraighten/PluginInfoGuideTip=Open the user guide on GitHub."),
              action = function()
                Http.openUrlInBrowser(REPOSITORY_URL)
              end,
            },

            f:push_button {
              title = LOC("$$$/BatchAutoStraighten/PluginInfoReleases=View Downloads"),
              tooltip = LOC("$$$/BatchAutoStraighten/PluginInfoDownloadsTip=Open GitHub Releases to choose a ZIP or DMG download."),
              action = function()
                Http.openUrlInBrowser(RELEASES_URL)
              end,
            },
          },
        },
      },
    }
  end,
}
