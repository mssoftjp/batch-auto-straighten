local LOC = (_PLUGIN and dofile(_PLUGIN.path .. "/Localization.lua")) or LOC
-- Lightroom exposes no named quick-collection getter. Its internal collection
-- is ID 2 in the verified Lightroom 15.5 catalog. Verify the internal name;
-- never create a same-named collection or fall back to the target collection.
local Q = {}
function Q.get(catalog)
  local collection = catalog:getCollectionByLocalIdentifier(2)
  if not collection or collection:getName() ~= "quick collection" then
    error(LOC("$$$/BatchAutoStraighten/Text002=Could not identify the Quick Collection"))
  end
  return collection
end
function Q.members(collection)
  local result = {}
  for _, photo in ipairs(collection:getPhotos()) do result[photo.localIdentifier] = true end
  return result
end
return Q
