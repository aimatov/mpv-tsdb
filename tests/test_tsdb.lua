local real_mp=require 'mp'
local utils=require 'mp.utils'
local function read(path)local f=assert(io.open(path,'rb'));local value=f:read('*a');f:close();return value end
local function write(path,value)local f=assert(io.open(path,'wb'));f:write(value);f:close()end
local callbacks,events,bindings,requests,loads={},{},{},{},{}
local props={path='Unrelated-anime.mkv',filename='Unrelated.S01E02.mkv',['window-dragging']=true,['track-list']={}}
local root=assert(os.getenv('TSDB_TEST_ROOT'))
local time=0
local mock={get_script_name=function()return 'tsdb'end,get_time=function()return time end,
    get_property=function(k)return props[k]end,get_property_native=function(k)return props[k]end,
    set_property=function(k,v)props[k]=v end,set_property_native=function(k,v)props[k]=v end,
    get_osd_size=function()return 1920,1080 end,get_mouse_pos=function()return -100,-100 end,
    create_osd_overlay=function()return {update=function()end,remove=function()end}end,
    add_forced_key_binding=function(k,n,fn)bindings[k]=fn end,remove_key_binding=function()end,
    add_key_binding=function()end,register_script_message=function(k,f)callbacks[k]=f end,
    register_event=function(k,f)events[k]=f end,observe_property=function()end,
    osd_message=function()end,add_timeout=function(_,fn)fn();return {kill=function()end}end,
    commandv=function(cmd,...)if cmd=='sub-add'then loads[#loads+1]={...}end;return true end}
mock.command_native=function(cmd)
    if cmd[1]=='expand-path'then return root end
    if cmd.name=='subprocess'then return real_mp.command_native(cmd)end
    if cmd[1]=='script-message-to'then callbacks[cmd[3]](unpack(cmd,4))end
end
mock.command_native_async=function(cmd,cb)requests[#requests+1]={cmd=cmd,cb=cb};return #requests end
package.loaded['mp']=mock
package.loaded['mp.utils']=utils
package.loaded['mp.options']={read_options=function(opt)
    opt.max_results=2;opt.pages_per_batch=1
    if not os.getenv('TSDB_TEST_DEFAULTS')then opt.languages='es,en'end
end}
local source=read(os.getenv('TSDB_TEST_SOURCE') or 'outputs/TSDB-ventana-preview/tsdb.lua')
local hook='\ntest={w=window,ui=ui,download=download,cache=cache,put=cache_put,get=cache_get,get_busy=function()return busy end,status=function()return result_status end,ctx=function()return current_context end}'
local function respond(value,err)
    local request=table.remove(requests,1);assert(request,'Missing request')
    if err then request.cb(true,{status=22,stderr='curl: (22) The requested URL returned error: '..err})
    else request.cb(true,{status=0,stdout=utils.format_json(value)})end
    return request
end
local function complete_inspection()
    local w=test.w
    while w.review_pending do
        w.review_more()
        if #requests>0 then
            local address=requests[1].cmd.args[#requests[1].cmd.args]
            assert(not address:find('/episode/',1,true),'Test must not skip normal episode pages')
            respond({title={},subtitles={offset=0,total=0,items={}}})
        end
    end
end
local function run()
    assert((loadstring or load)(source..hook,'tsdb-test'))()
    local w=test.w
    callbacks.open();assert(#requests==0 and w.query=='Unrelated.S01E02.mkv' and w.form_type=='series')
    assert(props['window-dragging']==false)
    local function press(id)
        for _,t in ipairs(w.targets)do if t.id==id then t.fn();return end end
        error('Button missing: '..id)
    end
    press('season+');assert(test.ui.season==2)
    press('season-');assert(test.ui.season==1)
    press('episode+');assert(test.ui.episode==3)
    press('episode-');assert(test.ui.episode==2)
    assert(#requests==0,'Coordinates must not automatically query the API')
    w.query='Lupin';w.caret=#w.query;w:submit()
    assert(#requests==1 and requests[1].cmd.args[#requests[1].cmd.args]:find('/catalog/series/',1,true))
    respond({metas={{id='tt2531336',name='Lupin',type='series',releaseInfo='2021'},{id='tt9999',name='Movie',type='movie'}}})
    assert(#w:catalog()==1 and not test.get_busy() and #requests==0)
    test.ui.season,test.ui.episode=1,1;w:select_card(1)
    local address=requests[1].cmd.args[#requests[1].cmd.args]
    local wanted='lang=es%2Csp%2Cea%2Cen'
    assert(address:find('/v1/by-imdb/tt2531336/season/1/episode/1',1,true) and address:find(wanted,1,true))
    local function sub(id,lang)return {id=id,format='srt',language=lang,release_name='Lupin.S01E01.'..id,download_url='https://api.thesubtitledb.org/get/'..id}end
    respond({title={imdb='tt2531336'},subtitles={offset=0,total=3,items={sub(1,'en'),sub(2,'es')}}})
    assert(#w.rows==2 and w.review_pending>=1 and not test.get_busy())
    w.review_more();assert(#requests==1);respond({title={imdb='tt2531336'},subtitles={offset=2,total=3,items={sub(3,'en')}}});complete_inspection()
    assert(#w.rows==3 and w.rows[1].item.id=='2' and w.rows[2].item.id=='1' and w.rows[3].item.id=='3')
    assert(not test.get_busy() and w.review_pending==nil)
    w:show_titles();assert(#w:catalog()==1 and #requests==0)
    w:select_card(1);assert(#requests==0 and #w.rows==2 and test.ctx().cache_hits==1)
    w.review_more();complete_inspection();assert(#requests==0 and #w.rows==3)
    w:submit(true);assert(#requests==1);respond(nil,530)
    assert(#requests==1 and requests[1].cmd.args[#requests[1].cmd.args]:find('https://thesubtitledb.org/api/v1/',1,true)==1)
    respond(nil,530);assert(not test.get_busy() and test.status():find('530',1,true))
    w:submit();assert(#requests==1,'Failed refresh must not cache error');respond({title={},subtitles={offset=0,total=1,items={sub(1,'en')}}});complete_inspection()
    local r=w.rows[1];local folder=utils.join_path(root,'Lupin (2021) [TSDB-tt2531336]')
    real_mp.command_native({name='subprocess',args={'powershell.exe','-NoProfile','-Command',"[IO.Directory]::CreateDirectory('"..folder:gsub("'","''").."')|Out-Null"},playback_only=false,capture_stdout=true})
    test.download(1);assert(#requests==1 and test.get_busy())
    local pending=table.remove(requests,1);local output
    for i,v in ipairs(pending.cmd.args)do if v=='-o'then output=pending.cmd.args[i+1]end end
    write(output,'1\n00:00:01,000 --> 00:00:02,000\nLupin test\n')
    pending.cb(true,{status=0});assert(#loads==1 and loads[1][3]:find('[TSDB]',1,true) and not test.get_busy())
    test.download(1);assert(#requests==0 and #loads==2,'Local file should avoid a download')
    w:show_titles();w.query='Other';w:submit();assert(#requests==1)
    events['start-file']();respond({metas={{id='tt123',name='Old response',type='series'}}})
    assert(#w.rows==0 and not w.visible and not test.get_busy() and props['window-dragging']==true)
    callbacks.open();w:set_type('movie');w.query='Matrix';w:submit()
    assert(requests[1].cmd.args[#requests[1].cmd.args]:find('/catalog/movie/',1,true))
    respond({metas={{id='tt0133093',name='The Matrix',type='movie',year=1999}}});w:select_card(1)
    assert(not requests[1].cmd.args[#requests[1].cmd.args]:find('/season/',1,true))
    respond({title={},subtitles={offset=0,total=0,items={}}})
    time=301;w:submit();assert(#requests==1,'Empty responses expire after 5 minutes')
    respond(nil,404);assert(not test.get_busy() and test.status():find('no encontró',1,true))
    w:submit(true);respond(nil,503);assert(#requests==1,'Transient response should retry once')
    respond(nil,503);assert(#requests==0 and not test.get_busy(),'Retries must be bounded')
    w:submit();respond({title={},subtitles={offset=0,total=1,items={sub(5,'en')}}})
    w.rows[1].item.download_url='https://unrelated.invalid/get/5'
    test.download(5);assert(#requests==0 and test.status():find('URL oficial',1,true))
    w.rows[1].item.download_url='https://api.thesubtitledb.org/get/5'
    test.download(5)
    local html=table.remove(requests,1);local htmlpath
    for i,v in ipairs(html.cmd.args)do if v=='-o'then htmlpath=html.cmd.args[i+1]end end
    write(htmlpath,'<!DOCTYPE html><html>WEBVTT error --> portal</html>');html.cb(true,{status=0})
    assert(#loads==2 and not test.get_busy() and not utils.file_info(htmlpath),'HTML must not be activated or retained')
    for i=1,60 do test.put('fixture-'..i,'{"value":'..i..'}',false)end
    local count=0;for _ in pairs(test.cache)do count=count+1 end;assert(count<=50)
    assert(test.get('fixture-60').value==60 and test.get('fixture-1')==nil)
    time=time+1800;assert(test.get('fixture-60')==nil,'Nonempty response must expire after 30 minutes')
    w:close();assert(props['window-dragging']==true)
    real_mp.msg.info('PASS TSDB preview: inherited UI; no query on open; typed catalog; explicit card; exact T/E; language grouping; pagination; cache/refresh/TTL/LRU; HTTP530 fallback; bounded retries; download/reuse; HTML and external-host refusal; stale callbacks; movie without T/E; errors not cached.')
end
local ok,err=xpcall(run,debug.traceback)
if not ok then real_mp.msg.error(tostring(err))end
real_mp.commandv('quit',ok and 0 or 1)
