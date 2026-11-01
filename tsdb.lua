-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 aimatov. Ventana derivada del trabajo de SubDL (MIT).
-- TSDB para mpv - v0.4.0; buscador nativo, formatos y espera del servidor.
-- Adaptador independiente: búsqueda TSDB con clave; Cinemeta como alternativa sin clave.
-- Requiere curl.exe 8.3 o posterior. No usa la API ni la clave de SubDL.
local mp=require 'mp'
local utils=require 'mp.utils'
local options=require 'mp.options'
local opt={api_key='',languages='es,sp,ea,en',search_timeout=25,download_timeout=45,max_results=100,pages_per_batch=5}
options.read_options(opt,'tsdb')
local SCRIPT=mp.get_script_name()
local API='https://api.thesubtitledb.org'
local SITE_API='https://thesubtitledb.org/api'
local CATALOG='https://v3-cinemeta.strem.io'
local ui={season=1,episode=1}
local busy,result_status_running=false,false
local result_status='Revisa el nombre y pulsa Buscar.'
local current_context
local window={visible=false,suppressed=false,query='',caret=0,focus='input',
    result_offset=0,targets={},bindings={},rows={},form_type='movie',visible_rows=7,scale=1}
local function clean(value) return tostring(value or ''):gsub('%c',' '):match('^%s*(.-)%s*$') end
local function encode(value) return tostring(value):gsub('([^%w%-_%.~])',function(c)return ('%%%02X'):format(c:byte())end) end
local function is_stream_path(path) return path:find('://',1,true)~=nil end
local function reference_label(ref) return ref.title..(ref.year and (' ('..ref.year..')') or '') end
local function cmd_to(action,...)
    local command={'script-message-to',SCRIPT,tostring(action)}
    for i=1,select('#',...) do command[#command+1]=tostring(select(i,...)) end
    return command
end
local function msg(text)
    result_status=text
    mp.osd_message('[TSDB] '..text,3)
    window:render()
end

function window:command(command)
    if command then mp.command_native(command) end
end

function window:escape(value)
    return tostring(value or ''):gsub('%c',' '):gsub('\\','\\\239\187\191')
        :gsub('{','\\{'):gsub('}','\\}')
end

function window:short(value,n)
    local chars={}
    for c in tostring(value or ''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars+1]=c end
    if #chars<=n then return table.concat(chars) end
    local left=math.max(1,math.floor((n-1)*0.65))
    return table.concat(chars,'',1,left)..'…'..table.concat(chars,'',#chars-(n-1-left)+1)
end

function window:previous(text,at)
    at=math.max(0,at-1)
    while at>0 and (text:byte(at+1) or 0)>=128 and (text:byte(at+1) or 0)<192 do at=at-1 end
    return at
end

function window:next(text,at)
    if at>=#text then return #text end
    at=at+1
    while at<#text and text:byte(at+1)>=128 and text:byte(at+1)<192 do at=at+1 end
    return at
end

function window:selection()
    if self.selected_all then return 0,#self.query end
    local anchor=self.selection_anchor or self.caret
    return math.min(anchor,self.caret),math.max(anchor,self.caret)
end

function window:clear_selection()
    self.selected_all=false; self.selection_anchor=nil
end

function window:delete_selection()
    local first,last=self:selection()
    if first==last then self:clear_selection(); return false end
    self.query=self.query:sub(1,first)..self.query:sub(last+1)
    self.caret=first; self:clear_selection(); return true
end

function window:input_position(x)
    local layout=self.input_layout
    if not layout then return #self.query end
    local first=layout.first
    if x<layout.x then return self:previous(self.query,first) end
    local at=first
    while at<#self.query do
        local following=self:next(self.query,at)
        local left=self:measure_text(self.query:sub(first+1,at),24)
        local right=self:measure_text(self.query:sub(first+1,following),24)
        if x-layout.x<(left+right)/2 then return at end
        at=following
        if right>layout.width then return at end
    end
    return #self.query
end

function window:insert(text)
    -- Only the edit buffer changes; submission passes its original bytes to submit_search.
    if self.focus~='input' then self.focus='input'; self.caret=#self.query end
    text=tostring(text or ''):gsub('[\r\n]',' ')
    self:delete_selection()
    self.query=self.query:sub(1,self.caret)..text..self.query:sub(self.caret+1)
    self.caret=self.caret+#text
    self:render()
end

function window:submit(refresh)
    self.force_search=refresh==true
    self.result_offset,self.catalog_offset=0,0
    self:form_search()
end

function window:initial_query()
    local filename=mp.get_property('filename') or ''
    local path=mp.get_property('path') or ''
    if filename=='' and path=='' then return '' end
    if is_stream_path(path) then
        local label=mp.get_property('media-title') or ''
        if label~='' and not label:find('://',1,true) then return label end
    end
    return filename~='' and filename or (mp.get_property('media-title') or '')
end

function window:reference_type(ref)
    local kind=tostring(ref and ref.type or ''):lower():gsub('[%s_%-]','')
    if kind=='tv' or kind=='series' or kind=='serie' or kind=='tvseries' then return 'series' end
    if kind=='movie' or kind=='film' or kind=='pelicula' then return 'movie' end
end

function window:close()
    self.languages_open=false;self.language_drag=nil
    self.input_drag=nil
    self.visible,self.suppressed=false,true
    for _,name in ipairs(self.bindings) do mp.remove_key_binding(name) end
    self.bindings={}
    self:hover_name(nil)
    for property,value in pairs(self.drag_options or {}) do mp.set_property_native(property,value) end
    self.drag_options=nil
    if self.overlay then self.overlay:remove() end
    mp.set_property_native('user-data/tsdb/window-open',false)
end

function window:bind(key,fn,flags)
    local name='tsdb-window-'..tostring(#self.bindings+1)
    self.bindings[#self.bindings+1]=name
    mp.add_forced_key_binding(key,name,fn,flags)
end

function window:move_result(delta)
    local items=self:result_items()
    if #items==0 then return end
    local index=tonumber(self.focus:match('^result:(%d+)$')) or (delta>0 and 0 or #items+1)
    index=math.max(1,math.min(#items,index+delta))
    self.focus='result:'..index
    if index<=self.result_offset then self.result_offset=index-1 end
    if index>self.result_offset+self.visible_rows then self.result_offset=index-self.visible_rows end
    self:render()
end

function window:activate()
    if self.focus=='input' then self:submit(); return end
    if self.focus=='scrollbar' then return end
    for _,target in ipairs(self.targets) do
        if target.id==self.focus and target.fn then target.fn(); return end
    end
end

function window:tab(delta)
    local index=0
    for i,target in ipairs(self.targets) do if target.id==self.focus then index=i; break end end
    if #self.targets>0 then self.focus=self.targets[(index+delta-1)%#self.targets+1].id end
    self:render()
end

function window:install_bindings()
    self:bind('MBTN_LEFT_DBL',function()
        local x,y=self:mouse()
        for _,t in ipairs(self.targets) do
            if t.id=='input' and self:inside(t,x,y) then
                self.focus='input'; self.selected_all=true; self.selection_anchor=0; self.input_drag=nil; self.caret=#self.query; self:render(); return
            end
        end
    end)
    self:bind('Ctrl+MBTN_LEFT',function(event)
        if event.event=='up' then self.drag=nil; return end
        if event.event~='down' and event.event~='press' then return end
        local x,y=self:mouse()
        for _,t in ipairs(self.targets) do
            if self:inside(t,x,y) then
                self.focus=t.id
                if t.id=='submit' then self:submit(true)
                elseif t.fn then t.fn() end
                self:render(); return
            end
        end
    end,{complex=true})
    self:bind('ESC',function() if self.languages_open then self.languages_open=false;self:render() else self:close() end end)
    self:bind('ENTER',function() self:activate() end)
    self:bind('KP_ENTER',function() self:activate() end)
    self:bind('TAB',function() self:tab(1) end)
    self:bind('Shift+TAB',function() self:tab(-1) end)
    self:bind('UP',function() self:move_result(-1) end,{repeatable=true})
    self:bind('DOWN',function() self:move_result(1) end,{repeatable=true})
    self:bind('PGUP',function() self:move_result(-self.visible_rows) end,{repeatable=true})
    self:bind('PGDWN',function() self:move_result(self.visible_rows) end,{repeatable=true})
    self:bind('LEFT',function()
        if self.focus=='input' then
            local a,b=self:selection()
            self.caret=a~=b and a or self:previous(self.query,self.caret)
            self:clear_selection(); self:render()
        end
    end,{repeatable=true})
    self:bind('RIGHT',function()
        if self.focus=='input' then
            local a,b=self:selection()
            self.caret=a~=b and b or self:next(self.query,self.caret)
            self:clear_selection(); self:render()
        end
    end,{repeatable=true})
    self:bind('HOME',function() if self.focus=='input' then self.caret=0; self:clear_selection(); self:render() end end)
    self:bind('END',function() if self.focus=='input' then self.caret=#self.query; self:clear_selection(); self:render() end end)
    self:bind('BS',function()
        if self.focus=='input' and self:delete_selection() then self:render(); return end
        if self.focus=='input' and self.caret>0 then
            local previous=self:previous(self.query,self.caret)
            self.query=self.query:sub(1,previous)..self.query:sub(self.caret+1)
            self.caret=previous; self:render()
        end
    end,{repeatable=true})
    self:bind('DEL',function()
        if self.focus=='input' then
            if self:delete_selection() then self:render(); return end
            self.query=self.query:sub(1,self.caret)..self.query:sub(self:next(self.query,self.caret)+1)
            self:render()
        end
    end,{repeatable=true})
    self:bind('Ctrl+a',function() self.focus='input'; self.selection_anchor=0; self.caret=#self.query; self.selected_all=true; self:render() end)
    self:bind('Ctrl+v',function()
        self:insert(mp.get_property('clipboard/text') or '')
    end)
    self:bind('any_unicode',function(event)
        if event.event=='press' or event.event=='down' or event.event=='repeat' then self:insert(event.key_text) end
    end,{complex=true,repeatable=true})
    for digit=0,9 do
        local value=tostring(digit)
        self:bind('KP'..value,function() self:insert(value) end,{repeatable=true})
    end
    self:bind('KP_DEC',function() self:insert('.') end,{repeatable=true})
    self:bind('MBTN_LEFT',function(event)
        if event.event=='up' then self.drag=nil; self.language_drag=nil; self.input_drag=nil; return end
        if event.event~='down' and event.event~='press' then return end
        local mx,my=self:mouse()
        if not self:inside(self.panel,mx,my) then self:close(); return end
        if self.languages_open and not self:inside(self.language_popup,mx,my) then
            local on_button=false
            for _,t in ipairs(self.targets) do if t.id=='languages' and self:inside(t,mx,my) then on_button=true end end
            if not on_button then self.languages_open=false end
        end
        for i=#self.targets,1,-1 do
            local target=self.targets[i]
            if self:inside(target,mx,my) then
                self.focus=target.id
                if target.id=='input' then
                    self:clear_selection(); self.caret=self:input_position(mx)
                    self.selection_anchor=self.caret; self.input_drag=true
                elseif target.fn then target.fn() end
                self:render(); return
            end
        end
    end,{complex=true})
    self:bind('mouse_move',function()
        if self.language_drag and self.languages_open and self.language_popup then
            local _,y=self:mouse()
            self.language_offset=math.floor(math.max(0,math.min(1,(y-self.language_popup.y-31-17.5)/180))*(#self.language_options-8)+0.5)
            self:render();return
        end
        if self.input_drag then
            local x=self:mouse(); self.caret=self:input_position(x)
            self:render(); return
        end
        local items=self:result_items()
        if self.drag and #items>self.visible_rows then
            local _,my=self:mouse()
            local track=self.track
            local grab=type(self.drag)=='table' and self.drag.grab or track.thumb/2
            self.result_offset=math.floor(math.max(0,math.min(1,(my-track.y-grab)
                /math.max(1,track.h-track.thumb)))*(#items-self.visible_rows)+0.5)
        end
        self:render()
    end)
    for _,entry in ipairs({{'WHEEL_UP',-1},{'WHEEL_DOWN',1}}) do
        local direction=entry[2]
        self:bind(entry[1],function()
            local mx,my=self:mouse()
            if not self:inside(self.panel,mx,my) then return end
            if self.languages_open and self:inside(self.language_popup,mx,my) then
                self.language_offset=math.max(0,math.min(#self.language_options-8,(self.language_offset or 0)+direction))
                self:render();return
            end
            local items=self:result_items()
            self.result_offset=math.max(0,math.min(math.max(0,#items-self.visible_rows),self.result_offset+direction))
            self:render()
        end,{repeatable=true})
    end
end

function window:mouse()
    local x,y=mp.get_mouse_pos()
    return (x or -100)/self.scale,(y or -100)/self.scale
end

function window:inside(rect,x,y)
    return rect and x>=rect.x and x<=rect.x+rect.w and y>=rect.y and y<=rect.y+rect.h
end

function window:render()
    if not self.visible then return end
    local width,height=mp.get_osd_size()
    if not width or width<1 or not height or height<1 then return end
    self.scale=math.min(1.12,width/920,height/690)
    local vw,vh=width/self.scale,height/self.scale
    local series=self.form_type=='series'
    local titles=self.result_mode=='titles'
    local items=self:result_items()
    local list_height=self.visible_rows*38
    local pw,ph=math.min(820,vw-32),(series and 248 or 180)+list_height+26
    local anchor_height=series and 490 or 422
    local px=(vw-pw)/2
    local py=math.max(12,math.min((vh-anchor_height)/2,vh-ph-12))
    self.panel={x=px,y=py,w=pw,h=ph}
    self.view_width,self.view_height=vw,vh
    self.targets={}
    local drawing={}
    local function rect(x,y,w,h,color,alpha)
        drawing[#drawing+1]=('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}m %.2f %.2f l %.2f %.2f %.2f %.2f %.2f %.2f{\\p0}')
            :format(color,alpha or '00',x,y,x+w,y,x+w,y+h,x,y+h)
    end
    local function text(x,y,value,size,color,maxw,bold)
        size=size*1.5
        local clip=maxw and ('\\clip(%.2f,%.2f,%.2f,%.2f)'):format(x,y-1,x+maxw,y+size*1.6) or ''
        drawing[#drawing+1]=('{\\an7\\pos(%.2f,%.2f)\\fnSegoe UI\\fs%.2f\\bord0\\shad0\\b%d\\1c&H%s&%s}%s')
            :format(x,y,size,bold and 1 or 0,color or 'F2EEEA',clip,self:escape(value))
    end
    local mx,my=self:mouse()
    local function target(id,x,y,w,h,fn)
        local item={id=id,x=x,y=y,w=w,h=h,fn=fn}
        self.targets[#self.targets+1]=item
        return self:inside(item,mx,my) or self.focus==id
    end
    local function button(id,x,y,w,h,label,fn,accent)
        local active=target(id,x,y,w,h,fn)
        rect(x,y,w,h,active and '695C4B' or (accent and '534A3B' or '494039'))
        text(x+10,y+7,label,14,'F2EEEA',w-16)
    end
    rect(0,0,vw,vh,'181818','85')
    rect(px+3,py+4,pw,ph,'000000','90')
    rect(px,py,pw,ph,'39322C')
    text(px+18,py+13,'TSDB',21,'F2EEEA',120,true)
    button('close',px+pw-45,py+9,28,28,'×',function() self:close() end)

    local input_x,input_y,input_w=px+18,py+49,pw-164
    local input_active=target('input',input_x,input_y,input_w,36,function()
        local x=self:mouse(); self:clear_selection(); self.caret=self:input_position(x)
    end)
    rect(input_x,input_y,input_w,36,'2D2722')
    rect(input_x,input_y+35,input_w,1,input_active and 'C7C398' or '5D5146')
    local text_x,available=input_x+10,input_w-20
    local first=math.min(self.input_first or 0,#self.query)
    if self.focus=='input' then
        first=math.min(first,self.caret)
        while first<self.caret and self:measure_text(self.query:sub(first+1,self.caret),24)>available-3 do
            first=self:next(self.query,first)
        end
    end
    if self:measure_text(self.query,24)<=available-3 then first=0 end
    self.input_first=first
    self.input_layout={x=text_x,first=first,width=available}
    local last=first
    while last<#self.query do
        local following=self:next(self.query,last)
        if self:measure_text(self.query:sub(first+1,following),24)>available then break end
        last=following
    end
    local a,b=self:selection()
    self.selection_rect=nil
    if self.focus=='input' and a~=b then
        local left=math.max(a,first); local right=math.min(b,last)
        if right>left then
            local x=text_x+self:measure_text(self.query:sub(first+1,left),24)
            local width=self:measure_text(self.query:sub(left+1,right),24)
            self.selection_rect={x=x,y=input_y+6,w=width,h=25}
            rect(x,input_y+6,width,25,'695C4B')
        end
    end
    local value=self.query=='' and 'Escribe un título o código IMDb…' or self.query:sub(first+1,last)
    text(text_x,input_y+8,value,16,self.query~='' and 'F2EEEA' or 'B7AFA6',available)
    if self.focus=='input' and a==b then
        local caret_x=text_x+self:measure_text(self.query:sub(first+1,self.caret),24)
        rect(math.min(text_x+available-1,caret_x),input_y+7,1,24,'F2EEEA')
    end
    button('submit',px+pw-134,input_y,116,36,
        busy and result_status_running and 'Buscando…' or 'Buscar',function() self:submit() end,true)
    button('type:movie',px+18,py+101,122,34,'Película',function() self:set_type('movie') end,not series)
    button('type:series',px+150,py+101,110,34,'Serie',function() self:set_type('series') end,series)
    rect(px+(series and 150 or 18),py+133,series and 110 or 122,2,'C7C398')
    local selected_count=0
    for _,on in pairs(self.selected_languages or {}) do if on then selected_count=selected_count+1 end end
    button('languages',px+pw-134,py+101,116,34,selected_count>0 and ('Idiomas '..selected_count..' ▾') or 'Idiomas ▾',function()
        self.languages_open=not self.languages_open;self:render()
    end,self.languages_open)
    if self.result_mode~='members' and (self.review_pending or 0)>0 then
        button('review-more',px+494,py+101,160,34,'Revisar más',function()
            if self.review_more then self.review_more() end
        end)
    end
    if series then
        local cy=py+148
        local function control(field,label,x)
            text(x,cy,label,12,'B7AFA6',100)
            button(field..'-',x,cy+20,28,28,'−',function() self:command(cmd_to('ui-step',field,-1)) end)
            text(x+43,cy+23,tostring(ui[field]),16,'F2EEEA',45,true)
            button(field..'+',x+88,cy+20,28,28,'+',function() self:command(cmd_to('ui-step',field,1)) end)
        end
        control('season','Temporada',px+18)
        control('episode','Episodio',px+190)
        local changed=self.applied_scope and (self.applied_scope.season~=ui.season or self.applied_scope.episode~=ui.episode or self.applied_scope.languages~=self:effective_languages())
        if changed then text(px+355,cy+25,'Cambios sin aplicar',12,'C7C398',pw-385) end
    end

    local heading_y=py+(series and 218 or 150)
    local heading='Resultados'
    if not titles and self.applied_scope then
        local scope=self.applied_scope
        heading=scope.title..(scope.type=='tv' and (' · T'..scope.season..' E'..scope.episode) or '')
    end
    if self.result_mode=='others' then heading='Otros archivos · Numeración sin confirmar' end
    if self.result_mode=='members' then heading='Elegir archivo del ZIP' end
    text(px+18,heading_y,self:fit_name(heading,pw-348,21,true),14,'F2EEEA',pw-348,true)
    local count=self.result_mode=='subtitles' and #self.rows or #items
    local unit=titles and (count==1 and ' título' or ' títulos')
        or (count==1 and ' subtítulo' or ' subtítulos')
    text(px+pw-310,heading_y+2,tostring(count)..unit,12,'B7AFA6',150)
    if not titles and self.applied_scope then
        button('titles',px+pw-147,heading_y-5,129,28,'← Volver',function()
            if self.result_mode=='members' then self:leave_members()
            elseif self.result_mode=='others' then self:toggle_others()
            else self:show_titles() end
        end)
    end
    local list_y=heading_y+30
    self.list_y=list_y
    local tooltip
    for slot=1,self.visible_rows do
        local index=self.result_offset+slot
        local row=items[index]
        local y=list_y+(slot-1)*38
        rect(px+18,y,pw-36,37,slot%2==0 and '352E29' or '332C26')
        if row then
            local active=target('result:'..index,px+18,y,pw-54,37,function()
                if titles then self:select_card(index)
                elseif row.tsdb_navigation=='others' then self:toggle_others()
                else self:command(row.value) end
            end)
            if active then rect(px+18,y,pw-54,37,'51483C') end
            local name=titles and reference_label(row) or (row.tsdb_full_title or row.title)
            local hint=titles and (self:reference_type(row)=='series' and 'Serie' or 'Película')
                or tostring(row.hint or ''):gsub('Idioma no indicado','Sin idioma'):gsub(' · coincidencia.*$','')
            if self.result_mode=='others' then hint=hint:gsub(' · Numeración sin confirmar','') end
            local namew=pw-226
            local shown,elided=self:fit_name(name,namew,21)
            text(px+28,y+9,shown,14,'F2EEEA',namew)
            text(px+pw-188,y+11,self:fit_name(hint,140,18),12,'B7AFA6',140)
            if not titles and not row.tsdb_navigation and not self.drag and self:inside(self.targets[#self.targets],mx,my) then
                tooltip={key=tostring(index)..':'..name..':'..self.result_offset,name=name,x=px+28,top=y,bottom=y+37}
            end
        end
    end
    if #items==0 then
        local empty=busy and result_status_running and 'Búsqueda en curso…'
            or (not titles and 'No hay subtítulos para esta selección.' or nil)
        if not busy and self.result_mode=='subtitles' and #(self.other_rows or {})>0 then
            empty='Sin coincidencias confirmadas. Revisa Otros archivos.'
        end
        if empty then text(px+32,list_y+53,empty,15,'B7AFA6',pw-64) end
    end
    if #items>self.visible_rows then
        local track_x,track_h=px+pw-30,list_height-2
        local thumb=math.max(28,track_h*self.visible_rows/#items)
        local thumb_y=list_y+self.result_offset/(#items-self.visible_rows)*(track_h-thumb)
        self.track={x=track_x,y=list_y,h=track_h,thumb=thumb,thumb_y=thumb_y}
        rect(track_x,list_y,10,track_h,'51483C')
        rect(track_x,thumb_y,10,thumb,'C7C398')
        target('scrollbar',track_x-5,list_y,20,track_h,function()
            local _,pointer_y=self:mouse()
            local grab=(pointer_y>=thumb_y and pointer_y<=thumb_y+thumb) and (pointer_y-thumb_y) or thumb/2
            self.drag={grab=grab}
            self.result_offset=math.floor(math.max(0,math.min(1,(pointer_y-list_y-grab)/(track_h-thumb)))*(#items-self.visible_rows)+0.5)
        end)
    end
    local status=result_status or (titles and 'Elige uno de los títulos encontrados.' or 'Elige un subtítulo para descargarlo y cargarlo.')
    local lower=status:lower()
    local important=lower:find('error',1,true) or lower:find('fall',1,true) or lower:find('falta',1,true)
        or lower:find('no se',1,true) or lower:find('sin ',1,true) or lower:find('al menos',1,true)
        or lower:find('activ',1,true) or lower:find('descarg',1,true) or lower:find('zip',1,true) or lower:find('extray',1,true) or lower:find('guardado',1,true) or lower:find('incompleta',1,true) or lower:find('omitidos',1,true) or lower:find('origen:',1,true) or lower:find('detenida',1,true) or lower:find('páginas',1,true) or lower:find('otros archivos',1,true) or status:find('Subtítulos:',1,true) or status:find('Búsqueda:',1,true)
    local applied_label=self.applied_scope and self.applied_scope.title
    if applied_label and status:sub(1,#applied_label)==applied_label then important=false end
    if result_status_running or important then
        text(px+18,list_y+list_height+5,self:fit_name(status,pw-36,16.5),11,'B7AFA6',pw-36)
    end
    if not result_status_running and not important and current_context and (current_context.cache_hits or 0)>0 then
        local notice=(current_context.network_requests or 0)==0 and 'Resultados guardados' or 'Incluye resultados guardados'
        text(px+18,list_y+list_height+5,notice..' · Ctrl + clic en Buscar para actualizar',11,'B7AFA6',pw-36)
    end
    if self.languages_open then tooltip=nil end
    local hover=self:hover_name(tooltip)
    if hover then
        local max_width=math.min(vw-32,pw-36)
        local lines=self:wrap_name(hover.name,max_width-24,18.75)
        local tw=120
        for _,line in ipairs(lines) do tw=math.max(tw,self:measure_text(line,18.75)+24) end
        tw=math.min(max_width,tw)
        -- Keep the existing font; tighten only line spacing and vertical padding.
        local line_height,padding_y=20,2
        local th=#lines*line_height+padding_y*2
        local tx=math.max(16,math.min(hover.x,vw-tw-16))
        local ty=hover.bottom+4
        if ty+th>vh-16 then ty=hover.top-th-4 end
        ty=math.max(16,math.min(ty,vh-th-16))
        rect(tx,ty,tw,th,'786C57')
        rect(tx+1,ty+1,tw-2,th-2,'201C18')
        for index,line in ipairs(lines) do text(tx+12,ty+padding_y+(index-1)*line_height,line,12.5,'F2EEEA',tw-24) end
    end
    self.language_popup=nil
    if self.languages_open then
        -- Se abre hacia la izquierda del selector: Volver queda libre a la derecha.
        local lx,ly,lw=px+pw-455,py+139,300
        local lh=282
        self.language_popup={x=lx,y=ly,w=lw,h=lh}
        rect(lx+2,ly+3,lw,lh,'000000','60')
        rect(lx,ly,lw,lh,'786C57');rect(lx+1,ly+1,lw-2,lh-2,'2D2722')
        text(lx+10,ly+7,'Selecciona uno o varios idiomas',12,'F2EEEA',lw-20)
        local first=math.max(0,math.min(#self.language_options-8,self.language_offset or 0))
        self.language_offset=first
        for slot=1,8 do
            local entry=self.language_options[first+slot]
            if entry then
                local chosen=self.selected_languages[entry[1]]
                button('language:'..entry[1],lx+6,ly+31+(slot-1)*27,lw-22,26,(chosen and '[x] ' or '[ ] ')..entry[2],function()self:toggle_language(entry[1])end,chosen)
            end
        end
        rect(lx+lw-10,ly+31,4,215,'51483C')
        rect(lx+lw-10,ly+31+first/math.max(1,#self.language_options-8)*180,4,35,'C7C398')
        target('language-scrollbar',lx+lw-16,ly+31,16,215,function()
            local _,y=self:mouse();self.language_drag=true
            self.language_offset=math.floor(math.max(0,math.min(1,(y-ly-31-17.5)/180))*(#self.language_options-8)+0.5)
            self:render()
        end)
        text(lx+10,ly+255,'Sin selección: Español e Inglés',11,'B7AFA6',lw-20)
    end
    if not self.overlay then self.overlay=mp.create_osd_overlay('ass-events'); self.overlay.z=2000 end
    self.overlay.res_x,self.overlay.res_y=math.ceil(vw),math.ceil(vh)
    self.overlay.data=table.concat(drawing,'\n')
    self.overlay:update()
end

function window:characters(value)
    local chars={}
    for char in tostring(value or ''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars+1]=char end
    return chars
end

function window:measure_text(value,size,bold)
    value=tostring(value or '')
    local key=tostring(size)..':'..tostring(bold)..':'..value
    self.width_cache=self.width_cache or {}
    if self.width_cache[key] then return self.width_cache[key] end
    local width
    if self.view_width and self.view_height then
        if not self.measure_overlay then
            self.measure_overlay=mp.create_osd_overlay('ass-events')
            self.measure_overlay.compute_bounds,self.measure_overlay.hidden=true,true
        end
        local overlay=self.measure_overlay
        overlay.res_x,overlay.res_y=math.ceil(self.view_width),math.ceil(self.view_height)
        local sample=size
        for attempt=1,6 do
            overlay.data=('{\\an7\\pos(0,0)\\fnSegoe UI\\fs%.4f\\b%d\\bord0\\shad0\\q2}%s')
                :format(sample,bold and 1 or 0,self:escape(value))
            local ok,bounds=pcall(overlay.update,overlay)
            if ok and type(bounds)=='table' and bounds.x1 and bounds.x0 and bounds.x1<overlay.res_x-4 then
                width=(bounds.x1-bounds.x0)*size/sample
                break
            end
            sample=sample/2
        end
    end
    if not width then
        -- Fallback for render-only/headless contexts where mpv cannot measure glyphs.
        width=0
        for _,char in ipairs(self:characters(value)) do
            local factor=(char=='W' or char=='M' or char=='@') and 0.95
                or (char:match('^[ilI1%.%,:%s]$') and 0.32 or (#char>2 and 1 or 0.60))
            width=width+size*factor
        end
    end
    if not self.width_cache_count or self.width_cache_count>512 then self.width_cache={}; self.width_cache_count=0 end
    self.width_cache[key]=width
    self.width_cache_count=self.width_cache_count+1
    return width
end

function window:fit_name(value,available,size,bold)
    if self:measure_text(value,size,bold)<=available-3 then return value,false end
    local chars=self:characters(value)
    local lo,hi,best=0,math.max(0,#chars-1),'...'
    while lo<=hi do
        local count=math.floor((lo+hi)/2)
        local left=math.ceil(count*0.60)
        local right=count-left
        local shown=table.concat(chars,'',1,left)..'...'
            ..(right>0 and table.concat(chars,'',#chars-right+1) or '')
        if self:measure_text(shown,size,bold)<=available-3 then best=shown; lo=count+1
        else hi=count-1 end
    end
    return best,true
end

function window:wrap_name(value,available,size)
    local chars=self:characters(value)
    local lines,offset={},1
    while offset<=#chars do
        local lo,hi,best=offset,#chars,offset
        while lo<=hi do
            local stop=math.floor((lo+hi)/2)
            if self:measure_text(table.concat(chars,'',offset,stop),size)<=available-3 then
                best=stop; lo=stop+1
            else hi=stop-1 end
        end
        if best<#chars then
            local minimum=offset+math.floor((best-offset)*0.65)
            for stop=best,minimum,-1 do
                local char=chars[stop]
                if char==' ' or char=='.' or char=='_' or char=='-' then best=stop; break end
            end
        end
        lines[#lines+1]=table.concat(chars,'',offset,best)
        offset=best+1
    end
    return lines
end

function window:hover_name(candidate)
    local key=candidate and candidate.key or nil
    self.hover_candidate=candidate
    if self.hover_key~=key then
        if self.hover_timer then self.hover_timer:kill(); self.hover_timer=nil end
        self.hover_key,self.hover_ready=key,false
        if key then
            self.hover_timer=mp.add_timeout(0.4,function()
                self.hover_timer=nil
                if self.visible and self.hover_key==key then self.hover_ready=true; self:render() end
            end)
        end
    end
    return self.hover_ready and self.hover_candidate or nil
end
-- El estado de una búsqueda es independiente del formulario que se edita.
local generation,download_generation=0,0
local cache,cache_bytes,clock_tick={},0,0
local subtitle_dir=mp.command_native({'expand-path','~~/tsdb-subtitles'})
local function media() return mp.get_property('path') or mp.get_property('filename') or '' end
local function now() return mp.get_time() end
local function cache_drop(key)
    if cache[key] then cache_bytes=cache_bytes-#cache[key].raw;cache[key]=nil end
end
local function cache_get(key)
    local item=cache[key]
    if not item then return end
    if now()>=item.expires then cache_drop(key);return end
    clock_tick=clock_tick+1;item.used=clock_tick
    return utils.parse_json(item.raw)
end
local function cache_put(key,raw,empty)
    cache_drop(key)
    if #raw>10*1024*1024 then return end
    clock_tick=clock_tick+1
    cache[key]={raw=raw,expires=now()+(empty and 300 or 1800),used=clock_tick}
    cache_bytes=cache_bytes+#raw
    while true do
        local count,oldest,used=0,nil,math.huge
        for k,v in pairs(cache) do
            if now()>=v.expires then cache_drop(k)
            else count=count+1;if v.used<used then oldest,used=k,v.used end end
        end
        if count<=50 and cache_bytes<=10*1024*1024 then break end
        cache_drop(oldest)
    end
end
local function http_code(err) return tonumber(tostring(err):match('[Ee]rror:%s*(%d%d%d)')) end
local function tsdb_host(url)
    local host=tostring(url):match('^https://([^/]+)/')
    return host=='api.thesubtitledb.org' or host=='thesubtitledb.org' or host=='www.thesubtitledb.org' or host=='files.thesubtitledb.org'
end
local function configured_key()
    local key=clean(opt.api_key)
    if key=='' or key:match('^TU_') or key:match('^PON_') then return nil end
    if not key:match('^[%w_%.~%-]+$') then return nil end
    return key
end
local function auth_environment(url)
    local key=configured_key()
    if key and tsdb_host(url) then
        -- stdin_data no funciona en mpv Win32. curl importa la clave del entorno.
        local env={}
        for _,entry in ipairs(utils.get_env_list()) do
            if not entry:match('^MPV_TSDB_KEY=') then env[#env+1]=entry end
        end
        env[#env+1]='MPV_TSDB_KEY='..key
        return env
    end
end
local function response_parts(raw)
    local body,headers,status=tostring(raw or ''),{},nil
    while body:match('^HTTP/[%d%.]+%s+%d%d%d') do
        local first,last=body:find('\r\n\r\n',1,true)
        if not first then first,last=body:find('\n\n',1,true) end
        if not first then break end
        local block=body:sub(1,first-1)
        status=tonumber(block:match('^HTTP/[%d%.]+%s+(%d%d%d)'))
        headers={}
        for name,value in block:gmatch('[\r\n]+([^:\r\n]+):%s*([^\r\n]*)') do headers[name:lower()]=clean(value) end
        body=body:sub(last+1)
    end
    return body,headers,status
end
local function retry_delay(headers)
    local value=headers and headers['retry-after']
    if not value then return 1 end
    local seconds=tonumber(value)
    if seconds and seconds>=0 then return seconds end
    local day,mon,year,hour,min,sec=value:match('%a+,%s*(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+GMT')
    local months={Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
    if day and months[mon] then
        local epoch=os.time()
        local utc=os.date('!*t',epoch);utc.isdst=false
        local offset=os.difftime(epoch,os.time(utc))
        local target=os.time({year=tonumber(year),month=months[mon],day=tonumber(day),hour=tonumber(hour),min=tonumber(min),sec=tonumber(sec),isdst=false})
        if target then return math.max(0,target+offset-epoch) end
    end
    return 1
end
local function request(url,ctx,callback)
    if ctx.serial~=generation then return end
    if not ctx.refresh then
        local data=cache_get(url)
        if data then ctx.cache_hits=ctx.cache_hits+1;callback(data);return end
    else cache_drop(url) end
    local function perform(address,attempt)
        if ctx.serial~=generation then return end
        ctx.network_requests=ctx.network_requests+1
        local args={'curl.exe','-fLsS','--compressed','--proto','=https','--proto-redir','=https',
            '--connect-timeout','6','--max-time',tostring(math.max(5,math.min(120,tonumber(opt.search_timeout) or 25))),
            '-D','-','-H','Accept: application/json'}
        local auth=auth_environment(address)
        if auth then
            args[#args+1]='--variable';args[#args+1]='%MPV_TSDB_KEY'
            args[#args+1]='--expand-header';args[#args+1]='Authorization: Bearer {{MPV_TSDB_KEY}}'
        end
        args[#args+1]=address
        mp.command_native_async({name='subprocess',args=args,playback_only=false,
            env=auth,capture_stdout=true,capture_stderr=true,capture_size=12*1024*1024},function(ok,result,err)
            if ctx.serial~=generation then return end
            local body,headers,http=response_parts(result and result.stdout)
            if not ok or type(result)~='table' or result.status~=0 then
                local detail=tostring(result and result.stderr or err or 'Error de red')
                http=http or http_code(detail)
                -- Ruta alternativa publicada por el SDK oficial; no cambiar de servicio.
                if http==530 and address:sub(1,#API)==API then
                    return perform(SITE_API..address:sub(#API+1),attempt)
                end
                local transient=(http and (http==408 or http==429 or http==500 or http==502 or http==503 or http==504))
                    or (result and (result.status==28 or result.status==7 or result.status==18 or result.status==56))
                if attempt<2 and transient then
                    local wait=retry_delay(headers)
                    if wait<=120 then
                        result_status='Servicio ocupado; reintento en '..math.ceil(wait)..' s.';window:render()
                        mp.add_timeout(wait,function() perform(address,attempt+1) end);return
                    end
                    callback(nil,'Servicio ocupado; vuelve a intentar en '..math.ceil(wait)..' s.',http);return
                end
                local why=http==401 and 'Error: clave TSDB inválida o ausente.'
                    or http==403 and 'Error: TSDB no permite esta operación con la clave configurada.'
                    or (http and ('Error HTTP '..http..' del servicio') or 'Error de conexión o tiempo agotado')
                callback(nil,why,http)
                return
            end
            local raw=body
            local data=utils.parse_json(raw)
            if type(data)~='table' then callback(nil,'Respuesta JSON inválida');return end
            if data.error then callback(nil,'Error del servicio: '..clean(data.message or data.error));return end
            local catalog=address:sub(1,#CATALOG)==CATALOG
            local search=address:find('/v1/by-search?',1,true)~=nil
            if (catalog and type(data.metas)~='table') or (search and type(data.results)~='table') or (not catalog and not search and
                (type(data.title)~='table' or type(data.subtitles)~='table' or type(data.subtitles.items)~='table')) then
                callback(nil,'Error: respuesta con formato inesperado.');return
            end
            local empty=(type(data.metas)=='table' and #data.metas==0)
                or (type(data.results)=='table' and #data.results==0)
                or (type(data.subtitles)=='table' and type(data.subtitles.items)=='table' and #data.subtitles.items==0)
            cache_put(url,raw,empty)
            callback(data)
        end)
    end
    perform(url,1)
end
local function present()
    if not window.visible then
        window.visible,window.suppressed=true,false
        window.drag_options={}
        for _,property in ipairs({'window-dragging','input-builtin-dragging'}) do
            local value=mp.get_property_native(property)
            if value~=nil then window.drag_options[property]=value;mp.set_property_native(property,false) end
        end
        window:install_bindings()
        mp.set_property_native('user-data/tsdb/window-open',true)
    end
    window:render()
end
local function finish(ctx,message)
    if ctx.serial~=generation then return end
    busy,result_status_running=false,false
    result_status=message
    window:render()
end
local function begin(refresh)
    generation=generation+1
    local ctx={serial=generation,refresh=refresh==true,cache_hits=0,network_requests=0,media=media()}
    current_context=ctx
    busy,result_status_running=true,true
    result_status='Buscando…'
    return ctx
end
function window:take_search_control()
    if busy and not result_status_running then msg('Hay una descarga en curso. Espera a que termine.');return false end
    if busy then generation=generation+1;busy,result_status_running=false,false end
    return true
end
function window:manual_open()
    if not self.manual_initialized then
        local value=self:initial_query()
        self.query,self.caret=value,#value
        local s,e=value:match('[Ss](%d+)[Ee](%d+)')
        if not s then s,e=value:match('(%d+)[xX](%d+)') end
        ui.season,ui.episode=tonumber(s) or 1,tonumber(e) or 1
        self.form_type=e and 'series' or 'movie'
        self.result_mode='titles';self.form_catalog={};self.rows={}
        self.manual_initialized=true
    end
    self.focus='input';present()
end
function window:catalog() return self.form_catalog or {} end
function window:set_type(kind)
    if not self:take_search_control() then return end
    if kind~=self.form_type then
        self.form_type=kind;self.form_catalog={};self.rows={};self.other_rows={};self.result_mode='titles'
        ui.reference=nil;self.applied_scope=nil;self.review_pending=nil;self.review_more=nil
        self.selected_query=nil;self.result_offset=0
        self.title_paging=nil
    end
    self:render()
end
function window:show_titles()
    if not self:take_search_control() then return end
    self.result_mode='titles';self.applied_scope=nil
    self.review_pending=self.title_paging and self.title_paging.pending
    self.review_more=self.title_paging and self.title_paging.more
    self.result_offset=self.title_return_offset or 0;self.selected_query=nil;ui.reference=nil
    result_status='Selecciona una ficha.';self:render()
end
local function title_from(data,kind)
    local title=type(data.title)=='table' and data.title or nil
    if not title then return end
    local imdb=tostring(title.imdb or '')
    if not imdb:match('^tt%d+$') then return end
    local source_type=title.media_type or title.kind
    local actual=(source_type=='tv' or source_type=='series' or source_type=='episode') and 'series'
        or (source_type=='movie' and 'movie' or nil)
    if actual and actual~=kind then return nil,'El IMDb corresponde al otro tipo de contenido.' end
    return {id=imdb,title=clean(title.name)~='' and clean(title.name) or imdb,year=tonumber(title.year),type=actual or kind}
end
function window:form_search()
    if not self:take_search_control() then return end
    local query=clean(self.query)
    if #query<2 then msg('Escribe un título o IMDb de al menos dos caracteres.');return end
    if ui.reference and self.selected_query==self.query and (self.result_mode=='subtitles' or self.result_mode=='others') then
        return self:search_selected(self.force_search)
    end
    self.selected_query=nil;ui.reference=nil;self.applied_scope=nil
    self.result_mode='titles';self.rows={};self.other_rows={};self.form_catalog={};self.review_pending=nil;self.review_more=nil
    self.languages_open=false
    self.title_paging=nil
    local ctx=begin(self.force_search);self.force_search=false
    local kind=self.form_type
    local search_languages=self:effective_languages()
    local imdb=query:match('^(tt%d+)$')
    if imdb then
        request(API..'/v1/by-imdb/'..imdb..'?limit=1&response_class=minimal&client=mpv-tsdb',ctx,function(data,err)
            if not data then finish(ctx,err);return end
            local ref,why=title_from(data,kind)
            if ref then self.form_catalog={ref} end
            finish(ctx,why or (ref and 'Selecciona una ficha.' or 'No se pudo identificar la ficha IMDb.'))
        end)
    elseif configured_key() then
        -- El catálogo TSDB filtra idiomas y tipo antes de entregar las fichas.
        local limit=math.max(1,math.min(100,math.floor(tonumber(opt.max_results) or 100)))
        local offset,refs,seen=0,{},{}
        local page
        page=function()
            local url=API..'/v1/by-search?q='..encode(query)..'&type='..(kind=='series' and 'episode' or 'movie')
                ..'&limit='..limit..'&offset='..offset..'&client=mpv-tsdb'
            url=url..'&lang='..encode(search_languages)
            request(url,ctx,function(data,err)
                if not data then finish(ctx,err);return end
                local returned=tonumber(data.offset) or offset
                if returned~=offset then finish(ctx,'Error: TSDB devolvió otra página de fichas.');return end
                local added=0
                for _,row in ipairs(data.results) do
                    local ref=type(row)=='table' and title_from({title=row},kind)
                    if ref and not seen[ref.id] then
                        seen[ref.id]=true;refs[#refs+1]=ref;added=added+1
                    end
                end
                self.form_catalog=refs
                local next_offset=offset+#data.results
                local remaining=math.max(0,(tonumber(data.total) or next_offset)-next_offset)
                self.title_paging=nil;self.review_pending=nil;self.review_more=nil
                if remaining>0 and #data.results>0 and next_offset<=10000 then
                    if added==0 then finish(ctx,'Error: página de fichas repetida; revisión detenida.');return end
                    offset=next_offset
                    local function more()
                        if not self:take_search_control() then return end
                        ctx=begin(false);self.review_pending=nil;page()
                    end
                    self.title_paging={pending=remaining,more=more}
                    self.review_pending,self.review_more=remaining,more
                end
                finish(ctx,#refs>0 and (remaining>0 and 'Fichas TSDB. Quedan páginas por revisar.' or 'Selecciona una ficha de TSDB.')
                    or 'Sin fichas TSDB con los filtros elegidos.')
            end)
        end
        page()
    else
        -- Una sola categoría y ninguna consulta TSDB hasta elegir la ficha.
        request(CATALOG..'/catalog/'..kind..'/top/search='..encode(query)..'.json',ctx,function(data,err)
            if not data then finish(ctx,err);return end
            if type(data.metas)~='table' then finish(ctx,'Error: catálogo con formato inesperado.');return end
            local refs,seen={},{}
            for _,m in ipairs(data.metas) do
                local declared=m.type or kind
                if type(m.id)=='string' and m.id:match('^tt%d+$') and declared==kind and not seen[m.id] then
                    seen[m.id]=true
                    refs[#refs+1]={id=m.id,title=clean(m.name or m.id),year=tonumber(tostring(m.year or m.releaseInfo or ''):match('%d%d%d%d')),type=kind}
                    if #refs>=60 then break end
                end
            end
            self.form_catalog=refs
            finish(ctx,#refs>0 and 'Selecciona una ficha. Catálogo Cinemeta: falta configurar la clave TSDB.' or 'No se encontraron títulos. Corrige el nombre y vuelve a buscar.')
        end)
    end
    self:render()
end
function window:select_card(index)
    local ref=self:catalog()[index]
    if not ref or not self:take_search_control() then return end
    self.title_return_offset=self.result_offset
    ui.reference=ref;self.selected_query=self.query
    self:search_selected(false)
end
-- Un idioma visible puede representar varios códigos oficiales del servicio.
local language_options={
    {'es','Español','es,sp,ea'},{'en','Inglés','en'},{'ru','Ruso','ru'},{'zh','Chino','zh,zt'},
    {'ja','Japonés','ja'},{'fr','Francés','fr'},{'de','Alemán','de'},{'it','Italiano','it'},
    {'pt','Portugués','pt,pb'},{'ko','Coreano','ko'},{'ar','Árabe','ar'},{'uk','Ucraniano','uk'},
    {'nl','Neerlandés','nl'},{'pl','Polaco','pl'},{'sv','Sueco','sv'},{'no','Noruego','no'},
    {'da','Danés','da'},{'fi','Finés','fi'},{'cs','Checo','cs'},{'sk','Eslovaco','sk'},
    {'el','Griego','el'},{'tr','Turco','tr'},{'he','Hebreo','he'},{'hi','Hindi','hi'},
    {'hu','Húngaro','hu'},{'ro','Rumano','ro'},{'bg','Búlgaro','bg'},{'hr','Croata','hr'},
    {'sr','Serbio','sr'},{'sl','Esloveno','sl'},{'bs','Bosnio','bs'},{'fa','Persa','fa'},
    {'id','Indonesio','id'},{'ms','Malayo','ms'},{'vi','Vietnamita','vi'},{'th','Tailandés','th'},
    {'bn','Bengalí','bn'},{'ta','Tamil','ta'},{'te','Telugu','te'},{'ur','Urdu','ur'},
    {'et','Estonio','et'},{'lv','Letón','lv'},{'lt','Lituano','lt'},{'sq','Albanés','sq'},
    {'mk','Macedonio','mk'},{'is','Islandés','is'},{'ca','Catalán','ca'},{'eu','Euskera','eu'},
    {'gl','Gallego','gl'},{'tl','Filipino','tl'},{'sw','Suajili','sw'}
}
window.language_options=language_options
window.selected_languages={}
-- Conserva selecciones explícitas de configuración; el valor predeterminado no marca casillas.
if clean(opt.languages)~='' and clean(opt.languages):lower()~='es,sp,ea,en' then
    local configured={};for code in clean(opt.languages):lower():gmatch('[^,%s]+') do configured[code]=true end
    for _,entry in ipairs(language_options) do
        for code in entry[3]:gmatch('[^,]+') do if configured[code] then window.selected_languages[entry[1]]=true end end
    end
end
function window:effective_languages()
    local codes={}
    for _,entry in ipairs(language_options) do
        if self.selected_languages[entry[1]] then codes[#codes+1]=entry[3] end
    end
    return #codes>0 and table.concat(codes,',') or 'es,sp,ea,en'
end
function window:toggle_language(code)
    self.selected_languages[code]=not self.selected_languages[code]
    self:render()
end
local language_names={}
for _,entry in ipairs(language_options) do
    for code in entry[3]:gmatch('[^,]+') do language_names[code]=entry[2] end
end
language_names.sp='Español de España';language_names.ea='Español latino';language_names.pb='Portugués brasileño'
language_names.zt='Chino tradicional';language_names.und='Sin idioma'
local function language(value) local code=clean(value):lower();return language_names[code] or code end
local function row_view(item,ctx)
    local name=clean(item.release_name)
    local fmt=clean(item.format):lower()
    if name=='' then name='TSDB-'..item.id end
    if not name:lower():match('%.'..fmt..'$') then name=name..'.'..fmt end
    local hint=language(item.language)..' · '..fmt:upper()..(item.hearing_impaired==true and ' · HI/SDH' or '')
    if name:lower():find('forced',1,true) then hint=hint..' · Forced' end
    return {title=name,tsdb_full_title=name,hint=hint,value=cmd_to('download',item.id),item=item,context=ctx}
end
local function regroup(rows)
    local groups,order={},{}
    for _,r in ipairs(rows) do
        local key=clean(r.item.language):lower()
        if key=='sp' or key=='ea' then key='es' end
        if not groups[key] then groups[key]={};order[#order+1]=key end
        groups[key][#groups[key]+1]=r
    end
    table.sort(order,function(a,b)
        local rank={es=1,en=2};local ar,br=rank[a] or 3,rank[b] or 3
        if ar~=br then return ar<br end
        return a<b
    end)
    local out={};for _,key in ipairs(order) do for _,r in ipairs(groups[key]) do out[#out+1]=r end end
    return out
end
local function numbering(name)
    local s,e=name:match('%f[%a][Ss](%d+)[%s%._%-]*[Ee](%d+)%f[%D]')
    if not s then s,e=name:match('%f[%d](%d+)[xX](%d+)%f[%D]') end
    if not s then s,e=name:match('%[(%d%d?)%.(%d%d?)%]') end
    -- Solo la forma delimitada verificada; no interpreta H.264, versiones ni decimales sueltos.
    if not s then s,e=name:match('%-%s+(%d%d?)%.(%d%d?)%s+%-') end
    return tonumber(s),tonumber(e)
end
function window:result_items()
    if self.result_mode=='titles' then return self:catalog() end
    if self.result_mode=='others' then return self.other_rows or {} end
    local items={};for _,row in ipairs(self.rows) do items[#items+1]=row end
    if #(self.other_rows or {})>0 then
        items[#items+1]={title='Otros archivos ('..#self.other_rows..')',hint='Entrar →',tsdb_navigation='others'}
    end
    return items
end
function window:toggle_others()
    if busy then msg('Espera a que termine la operación en curso.');return end
    if self.result_mode=='others' then
        self.result_mode='subtitles';self.result_offset=self.subtitle_return_offset or 0
    elseif #(self.other_rows or {})>0 then
        self.subtitle_return_offset=self.result_offset;self.result_mode='others';self.result_offset=0
    end
    self.focus='input';self:render()
end
function window:search_selected(refresh)
    if not ui.reference or not self:take_search_control() then return end
    self.languages_open=false
    local ctx=begin(refresh)
    ctx.ref=ui.reference;ctx.kind=self.form_type;ctx.season=ui.season;ctx.episode=ui.episode
    ctx.languages=self:effective_languages()
    local base=API..'/v1/by-imdb/'..ctx.ref.id
    local suffix=ctx.kind=='series' and ('/season/'..ctx.season..'/episode/'..ctx.episode) or ''
    local scopes={{url=base..suffix,kind='exact'}}
    if ctx.kind=='series' then
        scopes[#scopes+1]={url=base..'/season/'..ctx.season,kind='season'}
        scopes[#scopes+1]={url=base,kind='series'}
    end
    local limit=math.max(1,math.min(100,math.floor(tonumber(opt.max_results) or 100)))
    local pages=math.max(1,math.min(5,math.floor(tonumber(opt.pages_per_batch) or 5)))
    local candidates,order,known={}, {},{}
    local index,offset=1,0
    self.rows={};self.other_rows={};self.result_mode='subtitles';self.result_offset=0;self.review_pending=nil;self.review_more=nil
    self.applied_scope={title=reference_label(ctx.ref),type=ctx.kind=='series' and 'tv' or 'movie',season=ctx.season,episode=ctx.episode,languages=ctx.languages}
    local function remember_tree(data)
        -- Los filtros lang/offset no se aplican a este árbol: solo leemos identidad T/E.
        for _,season in ipairs(data.seasons or {}) do
            for _,episode in ipairs(season.episodes or {}) do
                for _,item in ipairs((episode.subtitles or {}).items or {}) do
                    if item.id then known[tostring(item.id)]={season=tonumber(episode.season or season.season),episode=tonumber(episode.episode),name=clean(episode.name):lower()} end
                end
            end
        end
    end
    local allowed={};for code in ctx.languages:gmatch('[^,]+') do allowed[code]=true end
    local function classify(c)
        local item=c.item
        if not allowed[clean(item.language):lower()] then return end
        if ctx.kind~='series' then return 'normal' end
        local s,e=numbering(tostring(item.release_name or ''))
        local meta_s,meta_e=tonumber(item.season),tonumber(item.episode)
        if meta_s and meta_s~=ctx.season or meta_e and meta_e~=ctx.episode then return end
        local node=known[item.id]
        if node then
            if node.season~=ctx.season or node.episode~=ctx.episode then return end
            if s and (s~=ctx.season or e~=ctx.episode) then
                local special=node.name:find('special',1,true) or node.name:find('christmas',1,true)
                if not (s==0 and e==ctx.episode and special) then return end
                c.alternative=true
            end
            return 'normal'
        end
        if s then return s==ctx.season and e==ctx.episode and 'normal' or nil end
        return c.exact and 'normal' or 'other'
    end
    local function rebuild()
        local normal,other={},{}
        for _,id in ipairs(order) do
            local c=candidates[id];local group=classify(c)
            if group then
                local row=row_view(c.item,ctx)
                if c.alternative then row.tsdb_full_title=row.title..' · Numeración alternativa confirmada por TSDB' end
                if group=='normal' then normal[#normal+1]=row else other[#other+1]=row end
            end
        end
        self.rows,self.other_rows=regroup(normal),regroup(other)
    end
    local page
    local function complete(budget,remaining)
        rebuild()
        if index>#scopes then
            self.review_pending=nil;self.review_more=nil
            finish(ctx,#self.rows>0 and 'Selecciona un subtítulo para activarlo.' or (#self.other_rows>0 and 'Sin coincidencias confirmadas. Revisa Otros archivos.' or 'Sin subtítulos para esta selección.'))
        elseif budget>1 then page(budget-1)
        else
            self.review_pending=math.max(1,(remaining or 0)+#scopes-index)
            self.review_more=function()
                if not self:take_search_control() or ctx.serial~=generation then return end
                busy,result_status_running=true,true;self.review_pending=nil;result_status='Revisando más archivos…';page(pages)
            end
            finish(ctx,'Quedan páginas o niveles por revisar. Pulsa Revisar más.')
        end
    end
    page=function(budget)
        local scope=scopes[index]
        local url=scope.url..'?limit='..limit..'&offset='..offset..'&sort=lang&client=mpv-tsdb&lang='..encode(ctx.languages)
        request(url,ctx,function(data,err,http)
            if not data then
                if http==404 and ctx.kind=='series' then index=index+1;offset=0;complete(budget,0);return end
                rebuild();finish(ctx,http==404 and 'TSDB no encontró esta ficha o episodio.' or err or 'Error al revisar los resultados.');return
            end
            local bucket=data.subtitles
            local returned=tonumber(bucket.offset) or offset
            if returned~=offset then finish(ctx,'Error: el servicio devolvió otra página.');return end
            remember_tree(data)
            local added=0
            for _,item in ipairs(bucket.items) do
                local id=type(item)=='table' and tonumber(item.id)
                if id and id>0 and id==math.floor(id) then
                    item.id=string.format('%.0f',id)
                    local existing=candidates[item.id]
                    if not existing then order[#order+1]=item.id end
                    scope.seen=scope.seen or {}
                    if not scope.seen[item.id] then added=added+1;scope.seen[item.id]=true end
                    candidates[item.id]={item=item,exact=scope.kind=='exact' or existing and existing.exact}
                end
            end
            local next_offset=offset+#bucket.items
            local remaining=math.max(0,(tonumber(bucket.total) or next_offset)-next_offset)
            if #bucket.items>0 and remaining>0 then
                if added==0 or next_offset>10000 then rebuild();finish(ctx,'Revisión detenida: página repetida o límite del servicio.');return end
                offset=next_offset
            else index=index+1;offset=0 end
            complete(budget,remaining)
        end)
    end
    page(pages);self:render()
end

local supported_formats={srt=true,ass=true,ssa=true,vtt=true,sub=true,txt=true,mpl=true,tmp=true,smi=true,sami=true}
local function file_valid(path,format)
    local info=utils.file_info(path)
    if not info or not info.size or info.size<12 or info.size>10*1024*1024 then return false end
    local file=io.open(path,'rb');if not file then return false end
    local text=file:read(8192) or '';file:close()
    local lower=text:lower():gsub('^\239\187\191',''):match('^%s*(.*)')
    if lower:find('<!doctype html',1,true)==1 or lower:find('<html',1,true)==1 then return false end
    if text:sub(1,4)=='\0\0\1\186' then return false,'SUB binario: necesita su archivo IDX; no es un SUB de texto.' end
    if text:find('%-%->') or text:find('WEBVTT',1,true) or text:find('[Script Info]',1,true) then return true end
    if format=='sub' or format=='txt' or format=='mpl' or format=='tmp' or format=='smi' or format=='sami' then
        -- MicroDVD, MPL2, SubViewer, TMPlayer, SAMI y MPsub: comprobar tiempos,
        -- no aceptar cualquier texto solo por la extensión.
        if text:match('{%d+}{%d+}.+') or text:match('%[%d+%]%[%d+%].+') then return true end
        if text:match('%d%d:%d%d:%d%d[%.:,]%d+%s*,%s*%d%d:%d%d:%d%d') then return true end
        if text:match('%d%d:%d%d:%d%d[:=].+') then return true end
        if lower:find('<sami',1,true) and lower:match('<sync%s+[^>]*start%s*=%s*["\']?%d+') then return true end
        if text:match('FORMAT=TIME') and text:match('\n%s*[%d%.]+%s+[%d%.]+%s*\n') then return true end
    end
    return false,'El archivo no tiene una estructura de subtítulos reconocida.'
end
-- Índice de archivos: solo nombres relativos al directorio de subtítulos, nunca credenciales.
local download_index
local function index_file() return utils.join_path(subtitle_dir,'download-index.json') end
local function load_index()
    if download_index then return download_index end
    download_index={}
    local info=utils.file_info(index_file())
    if info and info.size and info.size<=1024*1024 then
        local f=io.open(index_file(),'rb')
        if f then local raw=f:read('*a');f:close();local data=utils.parse_json(raw)
            if type(data)=='table' and data.version==1 and type(data.files)=='table' then download_index=data.files end
        end
    end
    return download_index
end
local function safe_component(value)
    return type(value)=='string' and value~='' and value~='.' and value~='..' and not value:find('[<>:"/\\\\|?*%c]')
end
local function indexed_path(id,fmt)
    local entry=load_index()[id]
    if type(entry)=='table' and entry.format==fmt and safe_component(entry.folder) and safe_component(entry.name) then
        local path=utils.join_path(utils.join_path(subtitle_dir,entry.folder),entry.name)
        if file_valid(path,fmt) then return path end
    end
end
local function remember_download(id,fmt,folder,name)
    local entries=load_index();entries[id]={format=fmt,folder=folder,name=name}
    local f=io.open(index_file()..'.tmp','wb')
    if f then
        f:write(utils.format_json({version=1,files=entries}));f:close()
        os.remove(index_file());os.rename(index_file()..'.tmp',index_file())
    end
end
local function activate(path,row)
    for _,track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.type=='sub' and tostring(track['external-filename']):gsub('\\','/'):lower()==path:gsub('\\','/'):lower() then
            mp.set_property('sid',tostring(track.id));mp.set_property('sub-visibility','yes');msg('Activado');return
        end
    end
    local ok,loaded=pcall(mp.commandv,'sub-add',path,'select',row.title..' [TSDB]',clean(row.item.language))
    if ok and loaded then mp.set_property('sub-visibility','yes');msg('Activado') else msg('Error: no se pudo cargar el subtítulo.') end
end
local function download(id)
    if busy then msg('Ya hay una operación en curso.');return end
    local row
    for _,list in ipairs({window.rows,window.other_rows or {}}) do
        for _,r in ipairs(list) do if r.item.id==tostring(id) then row=r;break end end
        if row then break end
    end
    if not row then msg('Resultado ya no disponible.');return end
    if row.context.media~=media() then msg('El video cambió; vuelve a buscar.');return end
    if media()=='' then msg('Abre un video antes de cargar un subtítulo.');return end
    local fmt=clean(row.item.format):lower()
    if not supported_formats[fmt] then msg('Formato aún no compatible: '..fmt);return end
    local indexed=indexed_path(row.item.id,fmt)
    if indexed then activate(indexed,row);return end
    local old=utils.join_path(subtitle_dir,'TSDB-'..row.item.id..'.'..fmt)
    if file_valid(old,fmt) then activate(old,row);return end
    local title=reference_label(row.context.ref):gsub('[<>:"/\\|?*%c]','_'):gsub('[%. ]+$','')
    local function limited(value,bytes)
        if #value<=bytes then return value end
        local edge=bytes
        while edge>0 and (value:byte(edge+1) or 0)>=128 and (value:byte(edge+1) or 0)<192 do edge=edge-1 end
        return value:sub(1,edge)
    end
    title=limited(title,90)
    local legacy_folder=utils.join_path(subtitle_dir,title..' [TSDB-'..row.context.ref.id..']')
    local safe_name=row.title:gsub('[<>:"/\\|?*%c]','_'):gsub('[%. ]+$','')
    local legacy_name=limited(safe_name,120):gsub('%.'..fmt..'$','')..' ['..row.item.id..'].'..fmt
    local legacy_output=utils.join_path(legacy_folder,legacy_name)
    if file_valid(legacy_output,fmt) then activate(legacy_output,row);return end
    -- El identificador distingue el aporte; el archivo conserva su nombre legible.
    local folder_name=title..' [TSDB-'..row.item.id..']'
    local folder=utils.join_path(subtitle_dir,folder_name)
    local extension=safe_name:sub(-#fmt-1)
    local name=limited(safe_name:sub(1,-#fmt-2),235)..extension
    if name:match('^[Cc][Oo][Nn]%.') or name:match('^[Pp][Rr][Nn]%.') or name:match('^[Aa][Uu][Xx]%.') or name:match('^[Nn][Uu][Ll]%.') or name:lower():match('^com[1-9]%.') or name:lower():match('^lpt[1-9]%.') then name='_'..name end
    local output=utils.join_path(folder,name)
    if file_valid(output,fmt) then remember_download(row.item.id,fmt,folder_name,name);activate(output,row);return end
    local url=clean(row.item.download_url)
    if not tsdb_host(url) then
        msg('Error: TSDB no devolvió una URL oficial de descarga.');return
    end
    local escaped=folder:gsub("'","''")
    local created=mp.command_native({name='subprocess',args={'powershell.exe','-NoProfile','-NonInteractive','-Command',
        "[IO.Directory]::CreateDirectory('"..escaped.."') | Out-Null"},playback_only=false,capture_stdout=true,capture_stderr=true})
    if not created or created.status~=0 then msg('Error: no se pudo crear la carpeta.');return end
    download_generation=download_generation+1
    local serial=download_generation;local video=media()
    local part=output..'.'..serial..'.part';os.remove(part)
    busy=true;result_status_running=false;msg('Descargando subtítulo…')
    url=url..(url:find('?',1,true) and '&' or '?')..'client=mpv-tsdb'
    local function attempt(number)
        if serial~=download_generation or media()~=video then
            os.remove(part)
            if serial==download_generation then busy=false;msg('El video cambió; descarga detenida.') end
            return
        end
        os.remove(part)
        local args={'curl.exe','-fLsS','--proto','=https','--proto-redir','=https',
            '--connect-timeout','6','--max-time',tostring(math.max(5,math.min(120,tonumber(opt.download_timeout) or 45))),
            '--max-filesize','10485760','-D','-','-o',part}
        local auth=auth_environment(url)
        if auth then
            args[#args+1]='--variable';args[#args+1]='%MPV_TSDB_KEY'
            args[#args+1]='--expand-header';args[#args+1]='Authorization: Bearer {{MPV_TSDB_KEY}}'
        end
        args[#args+1]=url
        mp.command_native_async({name='subprocess',args=args,env=auth,playback_only=false,capture_stdout=true,capture_stderr=true},function(ok,res)
            if serial~=download_generation then os.remove(part);return end
            local _,headers,http=response_parts(res and res.stdout)
            if not ok or not res or res.status~=0 then
                os.remove(part)
                http=http or http_code(res and res.stderr)
                if number<2 and (http==503 or http==429) then
                    local wait=retry_delay(headers)
                    if wait<=120 then
                        msg('Servicio ocupado; reintento de descarga en '..math.ceil(wait)..' s.')
                        mp.add_timeout(wait,function()attempt(number+1)end);return
                    end
                    busy=false;msg('Servicio ocupado; vuelve a descargar en '..math.ceil(wait)..' s.');return
                end
                busy=false;msg(http and ('Error HTTP '..http..' al descargar.') or 'Error al descargar el subtítulo.');return
            end
            busy=false
            local valid,why=file_valid(part,fmt)
            if not valid then os.remove(part);msg('Error: '..(why or 'la descarga no contiene un subtítulo válido.'));return end
            if not os.rename(part,output) then os.remove(part);msg('Error al guardar el subtítulo.');return end
            if media()~=video then msg('Descargado; cambió el video y no se activó.');return end
            remember_download(row.item.id,fmt,folder_name,name)
            activate(output,row)
        end)
    end
    attempt(1)
end
mp.register_script_message('open',function() window:manual_open() end)
mp.register_script_message('submit-search',function(text)window:manual_open();window.query=tostring(text or '');window.caret=#window.query;window:submit()end)
mp.register_script_message('download',download)
mp.register_script_message('ui-step',function(field,delta)
    if field~='season' and field~='episode' then return end
    ui[field]=math.max(field=='season' and 0 or 1,math.min(999,ui[field]+(tonumber(delta) or 0)));window:render()
end)
mp.add_key_binding('Ctrl+Shift+t','tsdb-open',function()window:manual_open()end)
mp.observe_property('osd-dimensions','native',function()if window.visible then window:render()end end)
mp.register_event('start-file',function()
    generation=generation+1;download_generation=download_generation+1
    busy,result_status_running=false,false
    window:close();window.manual_initialized=false;window.query='';window.caret=0
    window:clear_selection();window.input_first=0;window.rows={};window.form_catalog={}
    window.applied_scope=nil;window.other_rows={};window.languages_open=false;ui.reference=nil
end)
mp.register_event('shutdown',function()window:close()end)
