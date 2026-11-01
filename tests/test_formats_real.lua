local mp=require 'mp'
local utils=require 'mp.utils'
local function read(p)local f=assert(io.open(p,'rb'));local s=f:read('*a');f:close();return s end
local source=read(assert(os.getenv('TSDB_TEST_SOURCE')))
assert((loadstring or load)(source..'\nformat_valid=file_valid','tsdb-formats-real'))()
local names={'microdvd.sub','mpl2.mpl','subviewer.sub','tmplayer.tmp','sami.smi','mpsub.txt','sami.sami','plain.srt'}
local completed=false
mp.register_event('file-loaded',function()
    local count=0
    local function next_format()
        count=count+1
        if count>#names then completed=true;mp.msg.info('PASS: eight subtitle fixtures validated, loaded and decoded at their expected time');mp.commandv('quit',0);return end
        local name=names[count]
        local ok,err=pcall(function()
            local path=utils.join_path(mp.get_property('working-directory'),'tests/fixtures/formats/'..name)
            local fmt=name:match('%.([^%.]+)$')
            assert(format_valid(path,fmt),'Validator rejected '..name)
            local accepted,why=mp.commandv('sub-add',path,'select')
            assert(accepted,'mpv refused '..name..': '..tostring(why))
            local found=false
            for _,track in ipairs(mp.get_property_native('track-list')or {})do
                if track.type=='sub'and tostring(track['external-filename']):gsub('\\','/'):sub(-#name)==name then found=true end
            end
            assert(found,'mpv did not create a track for '..name)
            mp.commandv('seek','1.2','absolute+exact')
        end)
        if not ok then completed=true;mp.msg.error(tostring(err));mp.commandv('quit',1);return end
        mp.add_timeout(0.15,function()
            local text=mp.get_property('sub-text')or ''
            if text==''or text:find('FORMAT=TIME',1,true)then
                completed=true;mp.msg.error('No correctly timed decoded text for '..name..': '..text);mp.commandv('quit',1);return
            end
            mp.msg.info('FORMAT PASS '..name..': '..text)
            next_format()
        end)
    end
    next_format()
end)
mp.add_timeout(5,function()if not completed then mp.msg.error('Timeout waiting for isolated video');mp.commandv('quit',1)end end)
mp.set_property_native('pause',true)
mp.commandv('loadfile','tests/fixtures/formats/media.y4m')
