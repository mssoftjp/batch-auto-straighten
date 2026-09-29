local root='src/lightroom'
local count=0
local function test(choice,classification,fail,changed,uncertain)
 local module='develop';local writes,clears,messages=0,0,0;local state={CropAngle=0};local time=0
 local photo={getDevelopSettings=function()return state end,applyDevelopSettings=function(_,v)writes=writes+1;if fail=='apply' then error('write failed')end;state=v end}
 local checkpoint={record={uuid='copy',filename='photo',state='pending'},classify=function()return writes>0 and 'unchanged' or classification end,
 clear=function()if fail=='clear' then error('disk full')end;clears=clears+1 end,restoreValues=function()return {CropAngle=2}end}
 checkpoint.unreadable=uncertain=='damaged'
 checkpoint.relocated=uncertain=='relocated'
 local catalog={findPhotoByUuid=function()return photo end,setSelectedPhotos=function()end,getTargetPhoto=function()if fail~='selection' then return photo end end,withWriteAccessDo=function(_,_,fn)fn();return 'executed'end}
 local imports={LrTasks={pcall=pcall,sleep=function(n)time=time+n end},LrDate={currentTime=function()return time end},LrView={},
 LrApplicationView={getCurrentModuleName=function()return module end,switchToModule=function(m)module=m end},LrDialogs={message=function()messages=messages+1 end}}
 local env=setmetatable({_PLUGIN={path=root},import=function(k)return assert(imports[k])end,dofile=function(p)if p:match('Localization')then return function(s)return s:match('=(.*)')end end;return dofile(p)end},{__index=_G})
 local fn=assert(loadfile(root..'/RecoveryDialog.lua'));setfenv(fn,env);local R=fn()
 R.show=function(_,restore)assert(restore==(classification=='reset' and not uncertain));if changed then state={CropAngle=9}end;return choice end
 local result=R.check(catalog,checkpoint)
 count=count+1;return result,writes,clears,messages,module
end
local r,w,c,m,module=test('close','unknown');assert(not r and w==0 and c==0 and module=='develop')
r,w,c=test('keep','changed');assert(not r and w==0 and c==1)
r,w,c=test('keep','changed',nil,true);assert(not r and w==0 and c==0)
r,w,c=test('restore','reset');assert(not r and w==1 and c==1)
r,w,c,m,module=test('restore','reset','apply');assert(not r and w==1 and c==0 and m==1 and module=='develop')
r,w,c,m=test('restore','reset',nil,true);assert(not r and w==0 and c==0 and m==1)
r,w,c=test('review','unknown');assert(not r and w==0 and c==0)
r,w,c,m=test('review','unknown','selection');assert(not r and w==0 and c==0 and m==1)
r,w,c=test('close','unchanged');assert(r and w==0 and c==1)
r,w,c=test('close','applied');assert(r and w==0 and c==1)
r,w,c,m=test('close','applied','clear');assert(not r and w==0 and c==0 and m==1)
r,w,c=test('close','applied',nil,nil,'damaged');assert(not r and w==0 and c==0)
r,w,c=test('close','applied',nil,nil,'relocated');assert(not r and w==0 and c==0)
r,w,c=test('keep','applied',nil,nil,'relocated');assert(not r and w==0 and c==1)
print('recovery_dialog passed='..count)
