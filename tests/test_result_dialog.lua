-- Results retain five aligned columns for every photo in one scroll area.
-- No selected-photo panel may leave a different photo below the visible rows.
local plugin='src/lightroom'
local function test(count)
  local factory=setmetatable({},{__index=function(_,kind)
    return function(_,spec)spec.kind=kind;return spec end
  end})
  local rows={}
  for i=1,count do
    rows[i]={filename=string.format('photo-%04d.ARW',i),status=i<=2 and 'applied' or 'unprocessed',
      reason=i<=2 and 'applied' or 'settings_changed',before=0,after=.37,source='image_analysis'}
  end
  if count>2 then rows[count].referenceFilename='reference.ARW';rows[count].mark='Saved label' end
  local report,shown
  local imports={
    LrView={osFactory=function()return factory end},
    LrDialogs={presentModalDialog=function(info)
      shown=(shown or 0)+1
      assert(info.actionVerb=='Done')
      local main=info.contents
      local scroll,header
      for _,view in ipairs(main)do
        if view.kind=='scrolled_view' then assert(not scroll);scroll=view end
        if view.kind=='row' then assert(not header,'only column header is outside the table');header=view end
        assert(view.kind~='simple_list','do not flatten table columns into one list title')
        assert(view.kind~='push_button','no paging buttons')
      end
      assert(scroll and main[#main]==scroll,'no detached photo details below the table')
      assert(scroll.vertical_scroller and not scroll.horizontal_scroller)
      assert(header and #header==5,'fixed five-column header')
      for i,label in ipairs({'Photo','Result','Angle','Method','Details'})do
        assert(header[i].title==label,'column labels stay above the corresponding data')
      end
      assert(main[2].title:find('Applied: '..math.min(count,2),1,true))
      if count>2 then assert(main[2].title:find('Unprocessed: '..count-2,1,true))end
      local index=0
      for _,view in ipairs(scroll[1])do
        if view.kind=='row' then
          index=index+1
          assert(#view==5,'every photo has all five columns')
          local expected=report.rowValues(rows[index])
          for col,cell in ipairs(view)do
            assert(cell.title==expected[col],'all values remain on the correct photo row')
            assert(cell.width==header[col].width,'data cells align with the fixed header')
            assert(cell.tooltip==expected[col],'full text stays available when a cell wraps or truncates')
            assert(cell.height_in_lines==view[1].height_in_lines,'cells within each row share a height')
          end
          assert(view[1].title==rows[index].filename,'every photo appears once in order')
        end
      end
      assert(index==count,'all photos remain in the same scroll area')
      return 'ok'
    end},
  }
  local env=setmetatable({_PLUGIN={path=plugin},LOC=function(s)return (s:match('=(.*)$'):gsub('%^n','\n'))end,
    import=function(name)return assert(imports[name],name)end},{__index=_G})
  env.dofile=function(path)
    if path:match('Localization.lua$')then return env.LOC end
    local f=assert(loadfile(path));setfenv(f,env);return f()
  end
  report=env.dofile(plugin..'/ResultDialog.lua')
  assert(report.show(rows,'Stopped',false)=='ok')
  assert(shown==1,'one result modal')
end
for _,count in ipairs({0,1,50,51,120,3180})do test(count)end
print('PASS: 0, 1, 50, 51, 120 and 3180 results retain five aligned columns; no detached details or paging')
