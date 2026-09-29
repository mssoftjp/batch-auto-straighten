-- Persistence and restart tests, independent of Lightroom and the main SDK mock.
local root='src/lightroom'
local passed=0
local function check(value,message) assert(value,message);passed=passed+1 end
local fs={}
local writes=0
local failWrite=false
local function hash(s)
  local n=1;for i=1,#s do n=(n*131+s:byte(i))%1000000007 end
  return tostring(n)
end
local api={
  LrMD5={digest=hash},
  LrPathUtils={child=function(a,b)return a..'/'..b end,getStandardFilePath=function(which)assert(which=='appData');return '/support' end},
  LrFileUtils={exists=function(p)return fs[p]~=nil end,createAllDirectories=function()end},
}
local env=setmetatable({_PLUGIN={path=root},import=function(name)return assert(api[name])end,io={open=function(path,mode)
  if mode=='wb' then
    writes=writes+1
    if failWrite then return nil,'disk full' end
    fs[path]=''
    return {write=function(_,s)fs[path]=s;return true end,close=function()return true end}
  end
  if not fs[path] then return nil end
  return {read=function(_,n)return fs[path]:sub(1,n)end,close=function()return true end}
end}},{__index=_G})
local fn=assert(loadfile(root..'/SaveCheckpoint.lua'));setfenv(fn,env);local M=fn()
local catalog={getPath=function()return '/catalog/main.lrcat' end}
local photo={getRawMetadata=function(_,k)assert(k=='uuid');return 'virtual-copy-uuid' end}
local before={CropAngle=0,CropLeft=0,CropTop=0,CropRight=1,CropBottom=1,CropConstrainAspectRatio=true,Exposure2012=1,
  Mask={z=2,a={2,3}}}
local function copy(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
local frame={CropAngle=-2,CropLeft=.02,CropTop=.04,CropRight=.98,CropBottom=.96,CropConstrainAspectRatio=true}
local after=copy(before);for k,v in pairs(frame)do after[k]=v end
local s=M.open(catalog)
check(not s.record and writes==0,'opening an empty checkpoint performs no writes')
s:begin(photo,'photo',before,2,frame)
check(s.record.state=='pending','pending record precedes write')
check(s.record.before.Mask==nil and s.record.Mask==nil,'no image or full develop payload persisted')
local restart=M.open(catalog)
check(restart.record.uuid=='virtual-copy-uuid','restart retains virtual-copy identity')
check(restart:classify(before)=='unchanged','crash before photo write')
check(restart:classify(after)=='applied','direct write without completion record reconciles')
local edit=copy(after);edit.Exposure2012=2
check(restart:classify(edit)=='changed','later noncrop edit never reconciles or restores')
edit=copy(after);edit.CropLeft=.3
check(restart:classify(edit)=='unknown','partial or later crop edit needs review')
check(not pcall(function()restart:begin(photo,'photo',before,2,frame)end),'unresolved record cannot be overwritten')
restart:complete(after)
check(M.open(catalog):classify(after)=='applied','restart after confirmed write')
check(M.open(catalog):restoreValues().CropLeft==0,'restoration contains original crop')
check(M.open(catalog):restoreValues().Exposure2012==nil,'restoration cannot overwrite exposure or masks')
restart:clear()
check(M.open(catalog):classify(after)=='clear','acknowledgement survives restart')
local reset=copy(frame);reset.CropAngle=0;reset.CropLeft=0;reset.CropRight=1;reset.CropTop=0;reset.CropBottom=1
local old=copy(before);old.CropAngle=-3;old.CropLeft=.1;old.CropRight=.9
restart:begin(photo,'reset photo',old,2,nil,reset)
check(M.open(catalog):classify(before)=='reset','reset-only state offers guarded restoration')
check(M.open(catalog):classify(after)=='unknown','previous target angle alone is not proof of saved crop')
local keys=0;for _ in pairs(fs)do keys=keys+1 end
check(keys==2,'storage stays at two small files')
for _,v in pairs(fs)do check(#v<4096,'checkpoint stays small')end
local seq=restart.sequence
local older=restart.base..'-'..((seq+1)%2)..'.json'
fs[older]='{"payload":'
check(M.open(catalog).record.sequence==seq,'torn completion keeps original pending record')
failWrite=true
check(not pcall(function()restart:complete(after)end),'disk-full failure propagates')
check(M.open(catalog).record.state=='pending','disk-full keeps pending record')
failWrite=false
restart:complete(after)
local newest=restart.base..'-'..(restart.sequence%2)..'.json'
fs[newest]=fs[newest]:gsub('photo','xhoto')
check(M.open(catalog).record.state=='pending','checksum rejects corrupted newer record')
fs[restart.base..'-0.json']='broken';fs[restart.base..'-1.json']=string.rep('x',65537)
check(M.open(catalog).unreadable,'unreadable files require acknowledgement')
local broken=M.open(catalog)
check(not pcall(function()broken:begin(photo,'photo',before,2,frame)end),'unreadable record blocks saving')
broken:clear()
check(not broken.unreadable,'acknowledgement resets unreadable state')
check(M.open(catalog).record.state=='clear','explicit keep current resolves unreadable record')
local second=M.open{getPath=function()return '/catalog/other.lrcat' end}
check(not second.record,'catalog checkpoints are isolated')
check(M.fingerprint(before)==M.fingerprint(after),'crop changes do not affect noncrop signature')
local reordered=copy(before);reordered.Mask={a={2,3},z=2}
check(M.fingerprint(before)==M.fingerprint(reordered),'table key order does not change signature')
local noFlag=copy(before);noFlag.CropConstrainAspectRatio=nil
local resetStore=M.open(catalog);resetStore:begin(photo,'photo',old,2,nil,reset)
check(resetStore:classify(noFlag)=='reset','native reset can remove optional aspect flag')
local invalid=copy(before);invalid.CropAngle=0/0
check(not pcall(function()M.crop(invalid)end),'nonfinite settings cannot be persisted')

check(M.fingerprint({Exposure2012=1})==M.fingerprint({Exposure2012=1,AILook={}}),"empty AILook matches an absent default")
check(M.fingerprint({Exposure2012=1})~=M.fingerprint({Exposure2012=1,AILook={Amount=1}}),"nonempty AILook remains guarded")
check(M.fingerprint({Exposure2012=1})~=M.fingerprint({Exposure2012=1,Look={}}),"other empty fields remain guarded")
local profile={Look={UUID='profile-a',Amount=1,Parameters={Version='18.1',ProcessVersion='15.4',ToneCurvePV2012={0,0,255,255}}}}
local expanded={Look={UUID='profile-a',Amount=1,Parameters={Version='18.5.1',AILook={},ProcessVersion='15.4',ToneCurvePV2012={0,0,255,255}}},AILook={}}
check(M.fingerprint(profile)==M.fingerprint(expanded),'profile writer metadata does not change the checkpoint identity')
check(profile.Look.Parameters.Version=='18.1' and expanded.Look.Parameters.Version=='18.5.1','fingerprinting does not mutate profiles')
for _,case in ipairs({'UUID','Amount','ProcessVersion','ToneCurvePV2012','AILook'}) do
  local changed={Look=copy(expanded.Look)};changed.Look.Parameters=copy(expanded.Look.Parameters)
  if case=='UUID' then changed.Look.UUID='profile-b'
  elseif case=='Amount' then changed.Look.Amount=.5
  elseif case=='ProcessVersion' then changed.Look.Parameters.ProcessVersion='16.0'
  elseif case=='ToneCurvePV2012' then changed.Look.Parameters.ToneCurvePV2012={0,0,128,100,255,255}
  else changed.Look.Parameters.AILook={Amount=1} end
  check(M.fingerprint(profile)~=M.fingerprint(changed),case..' remains part of the checkpoint identity')
end
check(M.fingerprint({Mask={Version='18.1'}})~=M.fingerprint({Mask={Version='18.5.1'}}),'unrelated nested Version fields remain guarded')
-- Oracle: a corrupt next-photo pending cannot reconcile the previous photo.
fs={};writes=0
local a=M.open(catalog);a:begin(photo,'A',before,2,frame);a:complete(after)
local otherPhoto={getRawMetadata=function()return 'photo-B' end}
a:begin(otherPhoto,'B',before,2,frame)
fs[a.base..'-'..(a.sequence%2)..'.json']='broken'
local damaged=M.open(catalog)
check(damaged.unreadable,'corrupt next-photo pending is fail-closed')
check(damaged.record.uuid=='virtual-copy-uuid','older evidence remains available')
check(not pcall(function()damaged:begin(photo,'C',before,2,frame)end),'older valid evidence never permits a new batch')
damaged:clear()
check(not M.open(catalog).unreadable,'explicit acknowledgement repairs both slots')

-- Discover a moved/copy catalog without automatically associating or writing it.
fs={};writes=0
local a=M.open(catalog);a:begin(photo,'A',before,2,frame)
api.LrFileUtils.files=function(dir)
 local paths={};for path in pairs(fs)do if path:sub(1,#dir+1)==dir..'/' then paths[#paths+1]=path end end
 local i=0;return function()i=i+1;return paths[i]end
end
api.LrFileUtils.exists=function(path)
 if fs[path] then return true end
 for key in pairs(fs)do if key:sub(1,#path+1)==path..'/' then return 'directory' end end
 return false
end
local moved={getPath=function()return '/catalog/renamed.lrcat' end,findPhotoByUuid=function(_,id)if id=='virtual-copy-uuid' then return photo end end}
local countWrites=writes
local candidate=M.open(moved)
check(candidate.relocated and candidate.record.uuid=='virtual-copy-uuid','moved catalog surfaces matching unresolved evidence')
check(writes==countWrites,'discovery is read-only')
candidate:clear()
check(not M.open(moved).relocated,'explicit acknowledgement applies only to the new catalog')
check(M.open(catalog).record.state=='pending','old catalog record preserved')

print('save_checkpoint passed='..passed)
