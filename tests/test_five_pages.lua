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
package.loaded['mp.options']={read_options=function(o)o.api_key='fixture_only_no_key';o.max_results=1 end}
local source=read(assert(os.getenv('TSDB_TEST_SOURCE')))
local hook='\ntest={w=window,ui=ui,download=download,valid=file_valid,retry=retry_delay,parts=response_parts,busy=function()return busy end,status=function()return result_status end,defaults=opt,numbering=numbering,regroup=regroup,reset_index=function()download_index=nil end}'
local function url()local c=assert(requests[1]).cmd;return c.args[#c.args]end
local function response(data,code,headers)
    local r=assert(table.remove(requests,1))
    local text='HTTP/2 '..(code or 200)..'\r\n'..(headers or '')..'\r\n'..(data and utils.format_json(data)or '')
    r.cb(true,{status=code and code>=400 and 22 or 0,stdout=text,stderr=code and ('curl: (22) error: '..code)or ''})
    return r
end

local function run()
 assert((loadstring or load)(source..hook,'five-pages'))()
 assert(test.defaults.pages_per_batch==5,'Default batch must be five')
 local w=test.w;callbacks.open();w:set_type('movie');w.query='Akira';w:submit()
 response({offset=0,total=1,results={{imdb='tt0094625',name='Akira',year=1988,media_type='movie'}}})
 w:select_card(1)
 for i=1,5 do
  assert(#requests==1 and url():find('offset='..(i-1),1,true))
  response({title={},subtitles={offset=i-1,total=7,items={{id=1000+i,format='srt',language='es',release_name='Akira '..i}}}})
 end
 assert(#requests==0 and #w.rows==5 and w.review_pending==2 and not test.busy())
 w.review_more()
 for i=6,7 do response({title={},subtitles={offset=i-1,total=7,items={{id=1000+i,format='srt',language='es',release_name='Akira '..i}}}})end
 assert(#w.rows==7 and w.review_pending==nil and #requests==0)
 w:show_titles();w:select_card(1)
 assert(#requests==0 and #w.rows==5 and w.review_pending==2)
 w.review_more();assert(#requests==0 and #w.rows==7 and not test.busy())
 real_mp.msg.info('PASS: five sequential pages per batch, correct continuation at offset 5, final completion, all seven cached pages reused without requests.')
end
local ok,err=xpcall(run,debug.traceback);if not ok then real_mp.msg.error(tostring(err))end
real_mp.commandv('quit',ok and 0 or 1)
