-- Native Lightroom review-dialog contract; no UI or real photo access.
local plugin = 'src/lightroom'

local function test(mode, withPreview)
  local shown
  local f = {}
  for _, kind in ipairs({ 'picture', 'catalog_photo', 'static_text', 'column', 'row', 'push_button', 'spacer' }) do
    local viewKind = kind
    f[kind] = function(_, args)
      args.kind = viewKind
      return args
    end
  end
  f.control_spacing = function() return 8 end

  local dialogs = {}
  function dialogs.stopModalWithResult(_, result)
    dialogs.result = result
  end
  function dialogs.presentModalDialog(args)
      shown = args
      if mode == 'error' then error('dialog failed') end
      if mode == 'unknown' then return 'unexpected' end
      if mode == 'skip' then return 'ok' end
      if mode == 'cancel_result' then return 'cancel' end
      if mode == 'close' then return nil end
      local buttonIndex = ({
        stop = 1,
        apply_all_remaining = 2,
        skip_all_remaining = 3,
        apply = 5,
      })[mode]
      if buttonIndex then
        args.accessoryView[buttonIndex].action(args.accessoryView[buttonIndex])
        return dialogs.result
      end
      return nil
  end
  local imports = {
    LrDialogs = dialogs,
    LrTasks = { pcall = pcall },
    LrView = { osFactory = function() return f end },
  }
  local env = setmetatable({
    _PLUGIN = { path = plugin },
    import = function(name) return assert(imports[name]) end,
    LOC = function(value) return value:match('=(.*)$') end,
  }, { __index = _G })
  env.dofile = function(path)
    if path:match('Localization.lua$') then return env.LOC end
    return dofile(path)
  end

  local chunk = assert(loadfile(plugin .. '/ReviewDialog.lua'))
  setfenv(chunk, env)
  local show = chunk()
  local photo = { id = 'photo' }
  local canceled = mode == 'early_cancel'
  local decision, err = show(
    'photo.jpg', photo, withPreview and '/preview.png' or nil, 5, 3,
    { isCanceled = function() return canceled end }
  )

  if mode == 'apply' or mode == 'skip' or mode == 'apply_all_remaining' or mode == 'skip_all_remaining' then
    assert(decision == mode and err == nil)
  elseif mode == 'error' then
    assert(decision == 'stop' and err:find('dialog failed', 1, true))
  elseif mode == 'unknown' then
    assert(decision == 'stop' and err:find('unknown review dialog result: unexpected', 1, true))
  else
    assert(decision == 'stop' and err == nil)
  end

  if mode == 'early_cancel' then
    assert(shown == nil)
    return
  end
  assert(shown.title == 'Angle Exceeds Limit')
  assert(shown.actionVerb == 'Skip')
  assert(shown.cancelVerb == '< exclude >')
  assert(shown.otherVerb == nil)
  assert(shown.accessoryView.kind == 'row')
  assert(shown.accessoryView[1].title == 'Stop Batch')
  assert(shown.accessoryView[2].title == 'Apply All Remaining')
  assert(shown.accessoryView[3].title == 'Skip All Remaining')
  assert(shown.accessoryView[4].kind == 'spacer' and shown.accessoryView[4].fill_horizontal == 1)
  assert(shown.accessoryView[5].title == 'Apply Angle')
  local image = shown.contents[2]
  if withPreview then
    assert(image.kind == 'picture' and image.value == '/preview.png')
  else
    assert(image.kind == 'catalog_photo' and image.photo == photo)
  end
end

for _, mode in ipairs({ 'apply', 'skip', 'stop', 'apply_all_remaining', 'skip_all_remaining', 'cancel_result', 'close', 'early_cancel', 'error', 'unknown' }) do
  test(mode, true)
end
test('apply', false)
print('PASS: native review dialog (11 scenarios)')
