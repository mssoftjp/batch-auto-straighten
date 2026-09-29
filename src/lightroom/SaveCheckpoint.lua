-- One photo, two small alternating files per catalog. A torn write leaves the
-- previous valid record intact. No image data, batch database or background job.
local Files = import 'LrFileUtils'
local Paths = import 'LrPathUtils'
local MD5 = import 'LrMD5'
local json = dofile(_PLUGIN.path .. '/dkjson.lua')
local Math = dofile(_PLUGIN.path .. '/HorizonMath.lua')
local M = {}
local LIMIT = 65536
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function digest(s)
  return (MD5.digest(s):gsub('.',function(c)return string.format('%02x',string.byte(c))end))
end
local function canonical(value, seen)
  if type(value)~='table' then
    if type(value)=='number' then assert(finite(value),'invalid settings');return string.format('%.17g',value) end
    assert(type(value)=='string' or type(value)=='boolean' or value==nil,'unsupported settings')
    return assert(json.encode(value))
  end
  seen=seen or {};assert(not seen[value],'cyclic settings');seen[value]=true
  local entries={}
  for k,v in pairs(value) do entries[#entries+1]=canonical(k,seen)..':'..canonical(v,seen) end
  table.sort(entries);seen[value]=nil;return '{'..table.concat(entries,',')..'}'
end
function M.crop(settings)
  local out={}
  for k,v in pairs(settings) do
    if type(k)=='string' and k:match('^Crop') then
      assert(type(v)=='boolean' or type(v)=='string' or finite(v),'invalid crop')
      out[k]=v
    end
  end
  return out
end
function M.fingerprint(settings)
  local out={}
  for k,v in pairs(Math.normalizeDevelopSettings(settings)) do if type(k)~='string' or not k:match('^Crop') then out[k]=v end end
  return digest(canonical(out))
end
local function same(a,b)
  if type(a)~='table' or type(b)~='table' then return false end
  for k,v in pairs(a) do
    if finite(v) then if not finite(b[k]) or math.abs(v-b[k])>2e-6 then return false end
    elseif b[k]~=v then return false end
  end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function decode(raw, schema)
  if not raw or #raw>LIMIT then return nil end
  local envelope,pos,err=json.decode(raw)
  if err or type(envelope)~='table' or raw:sub(pos):find('%S')
    or type(envelope.payload)~='string' or envelope.checksum~=digest(envelope.payload) then return nil end
  local record,p,e=json.decode(envelope.payload)
  if e or type(record)~='table' or envelope.payload:sub(p):find('%S')
    or record.schema~=(schema or 'batch-auto-straighten.checkpoint.v1') or not finite(record.sequence)
    or record.sequence<1 or record.sequence%1~=0 or record.sequence>1e12
    or type(record.catalog)~='string' then return nil end
  if record.state=='clear' then return record end
  if record.state~='pending' and record.state~='complete' then return nil end
  if type(record.uuid)~='string' or record.uuid=='' or type(record.filename)~='string'
    or type(record.before)~='table' or not finite(record.target) or math.abs(record.target)>45
    or type(record.fingerprint)~='string' then return nil end
  for _,key in ipairs({'frame','after','reset'}) do
    if record[key]~=nil and type(record[key])~='table' then return nil end
  end
  for _,crop in ipairs({record.before,record.frame or {},record.after or {},record.reset or {}}) do
    for k,v in pairs(crop) do
      if type(k)~='string' or not k:match('^Crop') or
        not (finite(v) or type(v)=='boolean' or type(v)=='string') then return nil end
    end
  end
  return record
end
function M.open(catalog)
  local catalogPath=assert(catalog:getPath(),'catalog path unavailable')
  local root=Paths.child(assert(Paths.getStandardFilePath('appData')),'BatchAutoStraighten')
  local base=Paths.child(root,digest(catalogPath))
  local self={catalog=catalogPath,root=root,base=base,sequence=0,record=nil}
  local found=false
  local damaged=false
  local function readPair(readBase, schema)
    for i=0,1 do
      local path=readBase..'-'..i..'.json'
      local f=io.open(path,'rb')
      if f then
        found=true;local raw=f:read(LIMIT+1);f:close();local r=decode(raw,schema)
        if not r or r.catalog~=catalogPath then damaged=true end
        if r and r.catalog==catalogPath and r.sequence>self.sequence then self.record=r;self.sequence=r.sequence end
      elseif Files.exists(path) then found=true;damaged=true end
    end
  end
  readPair(base)
  self.unreadable=damaged or (found and not self.record)
  -- A relocated or copied catalog requires explicit association. Never apply
  -- an old record merely because its photo UUID exists in this catalog.
  if not found and not self.record and Files.files and catalog.findPhotoByUuid then
    local candidates={}
    for _,dir in ipairs({root}) do
      if Files.exists(dir) then
        local groups={}
        for path in Files.files(dir) do
          local pair=path:match('^(.*)%-[01]%.json$')
          if pair then
            local group=groups[pair] or {};groups[pair]=group
            local f=io.open(path,'rb')
            local raw=f and f:read(LIMIT+1);if f then f:close() end
            local r=decode(raw)
            if not r then group.damaged=true
            elseif not group.record or r.sequence>group.record.sequence then group.record=r end
          end
        end
        for _,group in pairs(groups) do
          local r=group.record
          if r and r.catalog~=catalogPath and r.state~='clear' and catalog:findPhotoByUuid(r.uuid) then
            candidates[#candidates+1]={record=r,damaged=group.damaged}
          end
        end
      end
    end
    if #candidates==1 then
      self.record=candidates[1].record
      self.relocated=true
      self.unreadable=candidates[1].damaged or false
    elseif #candidates>1 then
      self.unreadable=true
    end
  end

  function self:write(record)
    record.schema='batch-auto-straighten.checkpoint.v1';record.catalog=self.catalog
    record.sequence=self.sequence+1
    local payload=assert(json.encode(record));local raw=assert(json.encode({payload=payload,checksum=digest(payload)}))
    assert(#raw<=LIMIT,'checkpoint too large')
    Files.createAllDirectories(self.root)
    local path=self.base..'-'..(record.sequence%2)..'.json'
    local f=assert(io.open(path,'wb'),'checkpoint unavailable')
    local ok,err=f:write(raw);local closed,closeErr=f:close()
    assert(ok and closed,err or closeErr or 'checkpoint write failed')
    local check=assert(io.open(path,'rb'));local actual=check:read(LIMIT+1);check:close()
    assert(actual==raw and decode(actual),'checkpoint verification failed')
    self.sequence=record.sequence;self.record=record;self.unreadable=false
  end
  function self:begin(photo, filename, before, target, frame, reset)
    assert(not self.unreadable,'unreadable checkpoint')
    assert(not self.relocated,'catalog association requires acknowledgement')
    assert(not self.record or self.record.state~='pending','unresolved photo')
    self:write{state='pending',uuid=assert(photo:getRawMetadata('uuid')),filename=filename,
      before=M.crop(before),target=target,frame=frame,reset=reset,fingerprint=M.fingerprint(before)}
  end
  function self:complete(settings)
    assert(self.record and self.record.state=='pending','no pending photo')
    local r={};for k,v in pairs(self.record) do r[k]=v end
    r.state='complete';r.after=M.crop(settings);r.afterFingerprint=M.fingerprint(settings);self:write(r)
  end
  function self:clear()
    -- Explicit acknowledgement replaces both generations, so a damaged peer
    -- cannot keep blocking every subsequent invocation.
    self:write{state='clear'}
    self:write{state='clear'}
    self.relocated=false
  end
  function self:classify(settings)
    local r=self.record
    if not r or r.state=='clear' then return 'clear' end
    local crop=M.crop(settings);local fingerprint=M.fingerprint(settings)
    if fingerprint==r.fingerprint and same(crop,r.before) then return 'unchanged' end
    if r.state=='complete' and fingerprint==r.afterFingerprint and same(crop,r.after) then return 'applied' end
    if fingerprint~=r.fingerprint then return 'changed' end
    if r.frame then
      local expected={};for k,v in pairs(r.before) do expected[k]=v end
      for k,v in pairs(r.frame) do expected[k]=v end
      if same(crop,expected) then return 'applied' end
    end
    if r.reset then
      local expected={};for k,v in pairs(r.reset) do expected[k]=v end
      -- Native resetCrop can remove this optional flag while preserving the
      -- known zero-angle, full-frame reset geometry.
      expected.CropConstrainAspectRatio=crop.CropConstrainAspectRatio
      if same(crop,expected) then return 'reset' end
    end
    return 'unknown'
  end
  function self:restoreValues()
    local r=self.record;local out={}
    for _,k in ipairs({'CropAngle','CropLeft','CropRight','CropTop','CropBottom'}) do
      local v=r.before[k];if not finite(v) then return nil end;out[k]=v
    end
    if type(r.before.CropConstrainAspectRatio)~='boolean' then return nil end
    out.CropConstrainAspectRatio=r.before.CropConstrainAspectRatio
    return out
  end
  return self
end
return M
