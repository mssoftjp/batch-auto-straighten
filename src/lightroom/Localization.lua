-- Read the plug-in dictionary directly as well as using native LOC. Lightroom
-- may retain its old dictionary cache when a development plug-in is reloaded.
if type(import) ~= "function" then return LOC end -- standalone Lua tests
local native = LOC
local language = (import "LrLocalization").currentLanguage()
local dictionary = {}
if type(language)=="string" and language:match("^[%a_]+$") then
  local file=io.open(_PLUGIN.path.."/TranslatedStrings_"..language..".txt","r")
  if file then
    for line in file:lines() do
      local key,value=line:match('"(%$%$%$/[^=]+)=(.*)"')
      if key then dictionary[key]=value end
    end
    file:close()
  end
end
return function(value)
  local key=value:match("^([^=]+)=")
  local translated=dictionary[key]
  if translated then
    local text=translated:gsub("%^n","\n"):gsub("%^r","\r")
    return text
  end
  local text=native(value)
  return text
end
