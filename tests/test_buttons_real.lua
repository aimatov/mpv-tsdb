local mp=require 'mp'
local function read(path)local f=assert(io.open(path,'rb'));local data=f:read('*a');f:close();return data end
local source=read(os.getenv('TSDB_TEST_SOURCE') or 'outputs/TSDB-ventana-preview/tsdb.lua')
assert((loadstring or load)(source..[[
    test_buttons={window=window,ui=ui,cmd=cmd_to}
    window.render=function() end
]],'tsdb-buttons-real'))()
local api=test_buttons
api.window:command(api.cmd('ui-step','season',1))
mp.add_timeout(0.1,function()
    local ok,err=pcall(function()
        assert(api.ui.season==2,'Season + did not reach the script-message handler')
        api.window:command(api.cmd('ui-step','season',-1))
        api.window:command(api.cmd('ui-step','episode',1))
    end)
    if not ok then mp.msg.error(tostring(err));mp.commandv('quit',1);return end
    mp.add_timeout(0.1,function()
        local passed,why=pcall(function()
            assert(api.ui.season==1 and api.ui.episode==2,'Season - or Episode + failed')
            api.window:command(api.cmd('ui-step','episode',-1))
        end)
        if not passed then mp.msg.error(tostring(why));mp.commandv('quit',1);return end
        mp.add_timeout(0.1,function()
            if api.ui.episode~=1 then mp.msg.error('Episode - failed');mp.commandv('quit',1);return end
            mp.msg.info('PASS: real mpv script-message dispatch updates Season +/- and Episode +/-')
            mp.commandv('quit',0)
        end)
    end)
end)
