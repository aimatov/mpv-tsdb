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
    get_osd_size=function()return 1920,1080 end,get_mouse_pos=function()return -1,-1 end,
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
package.loaded['mp.options']={read_options=function(o)o.api_key='fixture_only_no_key';o.max_results=2;o.pages_per_batch=1 end}
local source=read(assert(os.getenv('TSDB_TEST_SOURCE')))
local hook='\ntest={w=window,ui=ui,download=download,valid=file_valid,retry=retry_delay,parts=response_parts,busy=function()return busy end,status=function()return result_status end,defaults=opt}'
local function url()local c=assert(requests[1]).cmd;return c.args[#c.args]end
local function response(data,code,headers)
    local r=assert(table.remove(requests,1))
    local text='HTTP/2 '..(code or 200)..'\r\n'..(headers or '')..'\r\n'..(data and utils.format_json(data)or '')
    r.cb(true,{status=code and code>=400 and 22 or 0,stdout=text,stderr=code and ('curl: (22) error: '..code)or ''})
    return r
end
local function run()
    assert((loadstring or load)(source..hook,'native-api-test'))()
    local w=test.w
    callbacks.open();w:set_type('series');w.query='The Office';w:submit()
    assert(url():find('/v1/by-search?',1,true) and url():find('type=episode',1,true))
    assert(url():find('lang=es%2Csp%2Cea%2Cen',1,true))
    assert(not table.concat(requests[1].cmd.args,' '):find(test.defaults.api_key,1,true))
    assert(table.concat(requests[1].cmd.env,'\n'):find('MPV_TSDB_KEY='..test.defaults.api_key,1,true))
    assert(requests[1].cmd.stdin_data==nil)
    local function title(id,year)return {imdb=id,name='The Office',year=year,kind='episode',media_type='tv'}end
    response({offset=0,total=3,results={title('tt0386676',2005),title('tt0290978',2001)}})
    assert(#w:catalog()==2 and w.review_pending==1 and not test.busy())
    local button=false;for _,t in ipairs(w.targets)do if t.id=='review-more'then button=true end end;assert(button,'Native title pagination button missing')
    w:select_card(2);assert(url():find('/by-imdb/tt0290978/season/1/episode/1',1,true))
    response({title={},subtitles={offset=0,total=0,items={}}})
    w:show_titles();assert(w.review_pending==1)
    w.review_more();assert(url():find('offset=2',1,true));response({offset=2,total=3,results={title('tt3300697',2024)}})
    assert(#w:catalog()==3 and not test.busy())
    w.query='Other';w:submit();response(nil,503,'Retry-After: 7\r\n')
    assert(#requests==0 and #timers==1 and timers[1].s==7 and test.busy())
    table.remove(timers,1).fn();assert(#requests==1);response({offset=0,total=0,results={}})
    assert(not test.busy())
    w.query='BadKey';w:submit();response(nil,401)
    assert(#requests==0 and #timers==0 and not test.busy() and test.status():find('clave',1,true))
    w.query='Busy';w:submit();response(nil,503,'Retry-After: 300\r\n')
    assert(#timers==0 and not test.busy() and test.status():find('300',1,true))
    local raw,headers,status=test.parts('HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 302 Found\r\nLocation: /x\r\n\r\nHTTP/2 503\r\nretry-after: 9\r\n\r\n{}')
    assert(status==503 and headers['retry-after']=='9' and raw=='{}')
    assert(test.retry({['retry-after']='0'})==0)
    assert(test.retry({['retry-after']=os.date('!%a, %d %b %Y %H:%M:%S GMT',os.time()+30)})>=28)
    w:set_type('movie');w.query='Akira';w:submit()
    assert(url():find('type=movie',1,true) and not url():find('/catalog/',1,true))
    response({offset=0,total=1,results={{imdb='tt0094625',name='Akira',year=1988,media_type='movie',kind='movie'}}})
    w:select_card(1)
    response({title={},subtitles={offset=0,total=1,items={{id=12345,format='sub',language='sp',release_name='Akira.sub',download_url='https://api.thesubtitledb.org/get/12345'}}}})
    assert(w.rows[1].hint:find('Español de España',1,true))
    test.download(12345);response(nil,503,'Retry-After: 6\r\n')
    assert(#requests==0 and #timers==1 and timers[1].s==6 and test.busy())
    table.remove(timers,1).fn()
    local r=assert(table.remove(requests,1));local part
    for i,v in ipairs(r.cmd.args)do if v=='-o'then part=r.cmd.args[i+1]end end
    write(part,'{1}{1}25.0\n{25}{50}Hola desde MicroDVD\n')
    r.cb(true,{status=0,stdout='HTTP/2 200\r\nContent-Type: application/octet-stream\r\n\r\n'})
    assert(#loads==1 and not test.busy())
    test.download(12345);assert(#requests==0 and #loads==2,'SUB must reuse its valid local copy')
    mock.commandv=function()return nil,'loading failed' end
    test.download(12345);assert(test.status():find('no se pudo cargar',1,true),'mpv load failure must not report Activated')
    local wrong=root..'/wrong.sub';write(wrong,'\0\0\1\186'..string.rep('\0',20));assert(not test.valid(wrong,'sub'))
    real_mp.msg.info('PASS: keyed native catalog/type/languages/pagination/back; key only via process environment; HTTP headers/redirects; Retry-After seconds/date/long wait; bounded errors; SUB download/validation/reuse and Spain label.')
end
local ok,err=pcall(run);if not ok then real_mp.msg.error(tostring(err))end
real_mp.commandv('quit',ok and 0 or 1)
