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
