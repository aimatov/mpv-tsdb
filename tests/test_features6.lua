local real_mp=require 'mp'
local utils=require 'mp.utils'
local function read(p)local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
local function write(p,s)local f=assert(io.open(p,'wb'));f:write(s);f:close()end
local callbacks,requests,timers,loads={},{},{},{}
local props={path='Another-video.mkv',filename='Another-video.mkv',['track-list']={}}
local root=assert(os.getenv('TSDB_TEST_ROOT'))
local mock={get_script_name=function()return 'tsdb'end,get_time=function()return 0 end,
    get_property=function(k)return props[k]end,get_property_native=function(k)return props[k]end,
    set_property=function(k,v)props[k]=v end,set_property_native=function(k,v)props[k]=v end,
    get_osd_size=function()return 1920,1080 end,get_mouse_pos=function()return props.mx or -1,props.my or -1 end,
    create_osd_overlay=function()return {update=function()end,remove=function()end}end,
    add_forced_key_binding=function()end,remove_key_binding=function()end,add_key_binding=function()end,
    register_script_message=function(k,fn)callbacks[k]=fn end,register_event=function()end,observe_property=function()end,
    osd_message=function()end,add_timeout=function(s,fn)timers[#timers+1]={s=s,fn=fn};return {kill=function()end}end,
    commandv=function(cmd,...)if cmd=='sub-add'then loads[#loads+1]={...}end;return true end}
mock.command_native=function(c)
    if c[1]=='expand-path'then return root end
    if c.name=='subprocess'then return real_mp.command_native(c)end
    if c[1]=='script-message-to'then callbacks[c[3]](unpack(c,4))end
end
mock.command_native_async=function(c,cb)requests[#requests+1]={cmd=c,cb=cb}end
package.loaded.mp=mock;package.loaded['mp.utils']=utils
package.loaded['mp.options']={read_options=function(o)o.api_key='fixture_only_no_key';o.max_results=100;o.pages_per_batch=3 end}
local source=read(assert(os.getenv('TSDB_TEST_SOURCE')))
local hook='\ntest={w=window,ui=ui,download=download,valid=file_valid,retry=retry_delay,parts=response_parts,busy=function()return busy end,status=function()return result_status end,defaults=opt,numbering=numbering,regroup=regroup,reset_index=function()download_index=nil end}'
local function url()local c=assert(requests[1]).cmd;return c.args[#c.args]end
local function response(data,code,headers)
    local r=assert(table.remove(requests,1))
    local text='HTTP/2 '..(code or 200)..'\r\n'..(headers or '')..'\r\n'..(data and utils.format_json(data)or '')
    r.cb(true,{status=code and code>=400 and 22 or 0,stdout=text,stderr=code and ('curl: (22) error: '..code)or ''})
    return r
end
local function fixture(name)return assert(utils.parse_json(read('tests/fixtures/'..name..'.json')))end
local function empty(offset)return {title={},subtitles={offset=offset or 0,total=0,items={}}}end
local function press(w,id)for _,t in ipairs(w.targets)do if t.id==id then t.fn();return end end;error('Missing '..id)end
local function ids(rows)local out={};for _,r in ipairs(rows)do out[r.item.id]=r end;return out end
local function sub(id,name,lang)return {id=tostring(id),format='srt',release_name=name,language=lang or 'en',download_url='https://api.thesubtitledb.org/get/'..id}end
local function assert_no_requests()assert(#requests==0,'Unexpected network operation')end
local function run()
 assert((loadstring or load)(source..hook,'features-six'))()
 local w=test.w;callbacks.open();w:set_type('series');w.query='The Office'
 assert(w:effective_languages()=='es,sp,ea,en')
 press(w,'languages');assert(w.languages_open)
 press(w,'language:es');assert(w:effective_languages()=='es,sp,ea')
 press(w,'language:ru');assert(w:effective_languages()=='es,sp,ea,ru');assert_no_requests()
 press(w,'language:es');press(w,'language:ru');assert(w:effective_languages()=='es,sp,ea,en');assert_no_requests()
 for _,t in ipairs(w.targets)do assert(t.id~='language:default','Reset button must be absent')end
 w.languages_open=false;w:submit();assert(url():find('lang=es%2Csp%2Cea%2Cen',1,true))
 response({total=1,offset=0,results={{imdb='tt0290978',name='The Office',year=2001,media_type='tv'}}})
 w:select_card(1);response(fixture('office-uk-episode'))
 assert(url():find('/season/1?',1,true))
 response(fixture('office-uk-season'));assert(not url():find('/season/',1,true))
 response(fixture('office-uk-series'));assert_no_requests()
 assert(not test.busy() and #w.rows==16 and #w.other_rows==39)
 assert(w.rows[1].item.language=='es','Spanish must precede English')
 assert(ids(w.rows)['7963798'],'[1.01] already confirmed by API must remain normal')
 assert(w:result_items()[#w.rows+1].tsdb_navigation=='others')
 press(w,'languages');local back
 for _,t in ipairs(w.targets)do if t.id=='titles'then back=t end end
 assert(back and w.language_popup.x+w.language_popup.w<=back.x,'Menu must leave Back unobstructed')
 local ass=([=[
[Script Info]
ScriptType: v4.00+
PlayResX: %d
PlayResY: %d
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Segoe UI,20,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
]=]):format(w.overlay.res_x,w.overlay.res_y)
 for line in w.overlay.data:gmatch('[^\n]+') do ass=ass..'Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,'..line..'\n' end
 write(root..'/ui-menu.ass',ass)
 w.languages_open=false;w:toggle_others();assert(w.result_mode=='others' and #w:result_items()==39)
 w:toggle_others();assert(w.result_mode=='subtitles');assert_no_requests()
 -- Reuse all three scoped responses, including the broad inspection.
 w:submit();assert_no_requests();assert(#w.rows==16 and #w.other_rows==39)
 -- A changed language gets different URLs/cache; empty selection restores the exact default cache.
 w:toggle_language('ru');w:submit();assert(url():find('lang=ru',1,true))
 response(empty());response(empty());response(empty());assert(#w.rows==0 and #w.other_rows==0)
 w:toggle_language('ru');w:submit();assert_no_requests();assert(#w.rows==16)
 -- A filename alone cannot override the explicit episode node, except verified special numbering.
 test.ui.season=3;w:submit();response(fixture('office-uk-t3e1'));response(empty());assert_no_requests()
 assert(ids(w.rows)['11577871'] and ids(w.rows)['1701723904'],'Verified special S00E01 must remain in T3E1')
 assert(ids(w.rows)['11577871'].tsdb_full_title:find('alternativa',1,true))
 -- Other-episode IDs, dotted names, metadata and absent classification.
 local s,e=test.numbering('Title - 1.3 - The Quiz');assert(s==1 and e==3)
 s,e=test.numbering('Title [1.01] Pilot');assert(s==1 and e==1)
 assert(not test.numbering('Title H.264 v1.1 1080p'),'Never infer episodes from codec/version numbers')
 local grouped=test.regroup({{item={language='en'}},{item={language='ru'}},{item={language='ea'}},{item={language='sp'}},{item={language='en'}},{item={language='es'}}})
 assert(grouped[1].item.language=='ea' and grouped[3].item.language=='es' and grouped[4].item.language=='en' and grouped[6].item.language=='ru')
 -- Explicit T/E on broad items can add confirmed matches, but never another episode.
 test.ui.season=1;w:search_selected(true)
 response({title={},subtitles={total=1,items={sub(800,'The Office S01E01')}}})
 response({title={},subtitles={total=3,items={sub(801,'The Office [1.01]'),sub(802,'The Office S01E09'),sub(803,'The Office - 101')}}})
 response({title={},subtitles={total=0,items={}},seasons={{season=1,episodes={{episode=9,subtitles={items={{id=803}}}}}}}})
 assert(ids(w.rows)['800'] and ids(w.rows)['801'] and not ids(w.rows)['802'])
 assert(#w.other_rows==0,'Broad candidate assigned to another episode must be removed')
 -- Lupin has no unassigned season/series bucket: do not invent an Others section.
 w:show_titles();w.query='Lupin';w:submit()
 response({offset=0,total=1,results={{imdb='tt2531336',name='Lupin',year=2021,media_type='tv'}}})
 w:select_card(1);response(fixture('lupin-episode'));response(fixture('lupin-season'));response(fixture('lupin-series'))
 assert(#w.other_rows==0 and #w:result_items()==#w.rows,'Lupin must not have an empty Others entry')
 -- Equal names retain distinct IDs; original filename lives inside a per-contribution folder.
 w:set_type('movie');w.query='Akira';w:submit()
 response({offset=0,total=1,results={{imdb='tt0094625',name='Akira',year=1988,media_type='movie'}}})
 w:select_card(1)
 response({title={},subtitles={total=2,items={sub(900,'Akira original.srt','es'),sub(901,'Akira original.srt','es')}}})
 assert(#w.rows==2)
 test.download(900);local dl=table.remove(requests,1);local part
 for i,v in ipairs(dl.cmd.args)do if v=='-o'then part=dl.cmd.args[i+1]end end
 assert(part:find('[TSDB-900]',1,true) and part:find('Akira original.srt.',1,true) and not part:find('original [900]',1,true))
 write(part,'1\n00:00:01,000 --> 00:00:02,000\nHola\n')
 dl.cb(true,{status=0});assert(test.status()=='Activado' and #loads==1)
 test.reset_index();w.rows[1].context.ref.title='Renamed title';w.rows[1].title='Renamed release.srt'
 test.download(900);assert_no_requests();assert(#loads==2,'Persistent ID index must reuse despite changed labels')
 test.download(901);assert(#requests==1,'Different IDs with equal names must remain separate')
 local second=table.remove(requests,1);local next_part
 for i,v in ipairs(second.cmd.args)do if v=='-o'then next_part=second.cmd.args[i+1]end end
 assert(next_part:find('[TSDB-901]',1,true) and next_part~=part)
 write(next_part,'1\n00:00:01,000 --> 00:00:02,000\nOtra traduccion\n');second.cb(true,{status=0})
 -- Both earlier disk layouts remain reusable without a new request.
 local ctx=w.rows[1].context;ctx.ref.title='Akira'
 w.rows[3]={title='LegacyName.srt',item=sub(905,'LegacyName.srt'),context=ctx}
 write(utils.join_path(root,'TSDB-905.srt'),'1\n00:00:01,000 --> 00:00:02,000\nViejo\n')
 test.download(905);assert_no_requests()
 local oldfolder=utils.join_path(root,'Akira (1988) [TSDB-tt0094625]')
 real_mp.command_native({name='subprocess',args={'powershell.exe','-NoProfile','-Command',"[IO.Directory]::CreateDirectory('"..oldfolder:gsub("'","''").."')|Out-Null"},playback_only=false,capture_stdout=true})
 write(utils.join_path(oldfolder,'LegacyName [906].srt'),'1\n00:00:01,000 --> 00:00:02,000\nAnterior\n')
 w.rows[4]={title='LegacyName.srt',item=sub(906,'LegacyName.srt'),context=ctx}
 test.download(906);assert_no_requests();assert(#loads==5)
 real_mp.msg.info('PASS preview6: language menu/default/multiselect/Back; real API fixtures at episode/season/series; conditional Others; confirmed specials; conservative numbering; grouped Spanish first; cache isolation; original filenames; distinct IDs; disk index across reload/renaming.')
end
local ok,err=xpcall(run,debug.traceback);if not ok then real_mp.msg.error(tostring(err))end
real_mp.commandv('quit',ok and 0 or 1)
