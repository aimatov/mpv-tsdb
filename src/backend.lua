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
