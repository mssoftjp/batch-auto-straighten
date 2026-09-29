-- Exercise real settings callbacks; no Lightroom catalog or photos are used.
local root = debug.getinfo(1,"S").source:sub(2):match("^(.*)/tests/[^/]+$") or "."
local source = root .. "/src/lightroom/"
local passed = 0
local function equal(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
  passed = passed + 1
end
local function run(prefs, deferred, exercise, response)
  local values, observers, queue, props = {}, {}, {}, nil
  local function notify(key, value)
    if observers[key] then
      if deferred then queue[#queue+1] = {key,value}
      else observers[key](props,key,value) end
    end
  end
  props = setmetatable({}, {
    __index = function(_,key)
      if key == "addObserver" then return function(_,name,callback) observers[name]=callback end end
      return values[key]
    end,
    __newindex = function(_,key,value)
      if values[key] == value then return end
      values[key] = value; notify(key,value)
    end,
  })
  local function flush()
    local count = 0
    while #queue > 0 do
      count = count + 1; assert(count < 20, "observer feedback loop")
      local event = table.remove(queue,1)
      observers[event[1]](props,event[1],event[2])
    end
  end
  local controls = {}
  local f = setmetatable({}, {__index=function(_,kind) return function(_,spec)
    if type(spec) ~= "table" then return 8 end
    spec.kind = kind; controls[#controls+1]=spec; return spec
  end end})
  local warnings = 0
  local env = setmetatable({LOC=function(text) return text:match("^[^=]+=(.*)$") end}, {__index=_G})
  env.dofile = function(path)
    local chunk=assert(loadfile(path));setfenv(chunk,env);return chunk()
  end
  env._PLUGIN = {path=source:sub(1,-2)}
  env.import = function(name)
    if name == "LrLocalization" then return {currentLanguage=function() return "en" end} end
    if name == "LrBinding" then return {makePropertyTable=function() return props end} end
    if name == "LrFunctionContext" then return {callWithContext=function(_,fn) return fn({}) end} end
    if name == "LrView" then return {osFactory=function() return f end,bind=function(key) return type(key)=="table" and key or {key=key} end} end
    if name == "LrDialogs" then return {
      message=function() warnings=warnings+1 end,
      presentModalDialog=function()
        local button
        for _,control in ipairs(controls) do
          if control.kind == "push_button" and type(control.tooltip)=="table" and control.tooltip.key=="angleLinkTip" then button=control end
        end
        assert(button,"native link button exists")
        exercise(props,function() button.action(button);flush() end,flush,function() return warnings end,controls)
        return response or "ok"
      end,
    } end
    error(name)
  end
  local result = env.dofile(source .. "StartDialog.lua")(2,prefs)
  flush()
  return result
end

for _,deferred in ipairs({false,true}) do
  local prefs={}
  local result=run(prefs,deferred,function(p,toggle,flush,warnings,controls)
    equal(p.angleLimitsLinked,true);equal(p.maxLeftAngle,3);equal(p.maxRightAngle,3)
    p.maxLeftAngle=4.2;flush();equal(p.maxRightAngle,4.2)
    p.maxLeftAngle=6;p.maxLeftAngle=7;flush();equal(p.maxRightAngle,7)
    p.maxRightAngle=2.5;flush();equal(p.maxLeftAngle,2.5)
    toggle();equal(p.angleLimitsLinked,false);equal(p.maxLeftAngle,2.5);equal(p.maxRightAngle,2.5)
    p.maxLeftAngle=1.2;flush();equal(p.maxRightAngle,2.5)
    p.maxRightAngle=5.4;flush();equal(p.maxLeftAngle,1.2)
    assert(p.angleLinkTip:find("5.4",1,true));toggle()
    equal(p.angleLimitsLinked,true);equal(p.maxLeftAngle,5.4);equal(p.maxRightAngle,5.4)
    toggle();p.maxLeftAngle=0;flush();toggle();equal(p.maxRightAngle,0)
    p.maxRightAngle=45;flush();equal(p.maxLeftAngle,45)
    local field
    for _,control in ipairs(controls) do if control.kind=="edit_field" then field=control;break end end
    local valid,value=field.validate(nil,"3.14");equal(valid,true);equal(value,3.1)
    equal(field.validate(nil,"bad"),false);equal(field.validate(nil,46),false)
    toggle();p.maxLeftAngle="bad";flush();toggle();equal(p.angleLimitsLinked,false);equal(warnings(),1)
    p.maxLeftAngle=3.1;flush();toggle();equal(p.maxRightAngle,3.1)
  end)
  equal(result.angleLimitsLinked,true);equal(prefs.runOptions.maxRightAngle,3.1)
  run(prefs,deferred,function(p) equal(p.angleLimitsLinked,true);equal(p.maxLeftAngle,3.1) end,"cancel")

  local old={runOptions={maxLeftAngle=2,maxRightAngle=4}}
  result=run(old,deferred,function(p,toggle)
    equal(p.angleLimitsLinked,false);equal(p.maxLeftAngle,2);equal(p.maxRightAngle,4)
    assert(p.angleLinkTip:find("2.0",1,true));toggle();equal(p.maxRightAngle,2)
  end,"cancel")
  equal(result,nil);equal(old.runOptions.maxLeftAngle,2);equal(old.runOptions.maxRightAngle,4);equal(old.runOptions.angleLimitsLinked,nil)

  prefs={runOptions={maxLeftAngle=2,maxRightAngle=2,angleLimitsLinked=false}}
  result=run(prefs,deferred,function(p) equal(p.angleLimitsLinked,false) end)
  equal(result.angleLimitsLinked,false)
  run(prefs,deferred,function(p) equal(p.angleLimitsLinked,false) end,"cancel")
  run({runOptions={maxLeftAngle=2,maxRightAngle=4,angleLimitsLinked=true}},deferred,function(p)
    equal(p.angleLimitsLinked,false);equal(p.maxLeftAngle,2);equal(p.maxRightAngle,4)
  end,"cancel")
end
print("start_dialog passed=" .. passed)
