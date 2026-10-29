-- mpv-TSDB v0.1.0-alpha.1 - primera version alfa para compartir.
-- Misma logica e interfaz validadas en la version interna TSDB 0.3.18.
-- Basado en TSDB 0.2, sin modificar SubDL, uosc ni Hikari.
-- Resolver de titulos: catalogos publicos de Cinemeta (Stremio).
-- Subtitulos y descargas: The Subtitle Database.
-- Al abrir: Ctrl+Shift+T. Solo se busca cuando el usuario escribe y pulsa Enter.
-- No instala nada en Windows. Requiere curl.exe y PowerShell existentes.
-- Mantener la v0.2 fuera de scripts para poder volver atras.
local mp = require('mp')
local utils = require('mp.utils')
local opts = require('mp.options')
local logger = require('mp.msg')

local opt = {
    language = '',             -- Vacio = no filtrar idioma; 'es' = solo espanol.
    max_results = 100,         -- Por título candidato y petición (TSDB limita la API).
    max_titles = 24,           -- Titulos candidatos (de Cinemeta) por busqueda de texto.
    concurrent_requests = 3,
    search_timeout = 45,  -- Maximo por intento.
    transient_retries = 1, -- Solo se reintentan errores transitorios de TSDB.
    download_timeout = 35,
    auto_search_video = false,  -- Desactivado: ya no se utiliza identificacion automatica.
}
opts.read_options(opt, 'tsdb_desarrollo')

local BASE = 'https://api.thesubtitledb.org'
local CINEMETA = 'https://v3-cinemeta.strem.io'
local MENU_TYPE, MENU_ID = 'tsdb-external', 'tsdb-main'
local SCRIPT = (type(mp.get_script_name)=='function' and mp.get_script_name()) or 'tsdb_desarrollo_0_3_13'
local subtitle_dir = mp.command_native({'expand-path', '~~/tsdb-subtitles'})
local rows, by_id, status, last_query = {}, {}, nil, nil
local search_serial, download_serial, media_serial = 0, 0, 0
local search_busy, download_busy, request_count = false, false, 0
local query_media = nil
local last_error = nil
local selected_languages = {} -- Filtro POSTERIOR: solo controla la vista.
local search_language = ''  -- Preferencia ANTES de buscar: vacio = busqueda libre.
local last_selected_subtitle_id = nil -- Para volver al ultimo subtitulo elegido.
local inline_selector = nil -- menu compacto superpuesto: 'search' o 'filter'; sin submenus laterales.
local inline_page = 1
local inline_page_size = 6
local scroll_reset_on_next_render = false -- Una busqueda nueva o panel nuevo comienza arriba.

-- Diagnostico LOCAL, no aparece en los menus ni cambia las peticiones.
-- Se conserva un historial corto de busquedas consecutivas para poder comparar
-- dos intentos del mismo titulo. Nunca registra el contenido de subtitulos.
local diagnostic_path = mp.command_native({'expand-path','~~/tsdb-diagnostico.txt'})
local diagnostic_available = type(diagnostic_path)=='string' and diagnostic_path~=''
local diagnostic_search_number = 0
local function diagnostic_write(message)
    if not diagnostic_available then return end
    local f=io.open(diagnostic_path,'ab')
    if not f then
        diagnostic_available=false
        logger.error('[TSDB] No se pudo escribir el diagnóstico: '..tostring(diagnostic_path))
        return
    end
    f:write(tostring(message),'\r\n')
    f:close()
end
local function diagnostic_begin(query,language,serial)
    if not diagnostic_available then return end
    -- Impide que crezca ilimitadamente. Un archivo nuevo sustituye el antiguo
    -- solo cuando alcanza 512 KiB; de otro modo conserva búsquedas repetidas.
    local info=utils.file_info(diagnostic_path)
    if info and tonumber(info.size) and info.size>512*1024 then
        local f=io.open(diagnostic_path,'wb')
        if f then f:write('Diagnostico reiniciado al superar 512 KiB.\r\n'); f:close() end
    end
    diagnostic_search_number=diagnostic_search_number+1
    diagnostic_write(('=== INICIO BUSQUEDA %d | %s | serial=%d ==='):
        format(diagnostic_search_number,os.date('%Y-%m-%d %H:%M:%S'),serial))
    diagnostic_write('Consulta: '..tostring(query))
    diagnostic_write('Modalidad: '..(language=='' and 'libre (espanol y todos)' or ('seleccionado: '..language)))
end
local function diagnostic_http(err)
    local code=tostring(err or ''):match('[Ee]rror:%s*(%d%d%d)')
    return code or 'no informado'
end
local function diagnostic_cause(err,code)
    local n=tonumber(code)
    if n==28 then return 'TIEMPO_AGOTADO' end
    if n==22 then return 'HTTP_'..diagnostic_http(err) end
    if n==18 then return 'TRANSFERENCIA_INCOMPLETA' end
    if n==52 then return 'RESPUESTA_VACIA' end
    if n==56 then return 'CONEXION_CORTADA' end
    if n==7 then return 'CONEXION_RECHAZADA' end
    if n==6 then return 'DNS' end
    if n==60 then return 'CERTIFICADO' end
    return 'OTRO_ERROR_CURL'
end
local function diagnostic_context(url,details)
    if type(details)=='table' then
        local domain=details.service or (url:find('/v1/by-imdb/',1,true) and 'TSDB' or 'Cinemeta')
        return ('%s | fase=%s | IMDb=%s | titulo=%s'):
            format(domain,tostring(details.phase or '?'),tostring(details.tt or '-'),
                   tostring(details.title or '-'):gsub('[\r\n|]',' '))
    end
    return (url:find('/v1/by-imdb/',1,true) and 'TSDB' or 'Cinemeta')..' | fase=no indicada'
end

local function clean(s, n)
    s = tostring(s or ''):gsub('%c',' '):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
    if n and #s > n then
        local cut = n
        while cut > 0 do
            local b = s:byte(cut+1)
            if not b or b < 128 or b >= 192 then break end
            cut = cut - 1
        end
        s=s:sub(1,cut)..'…'
    end
    return s
end
local function notify(s,secs)
    logger.info('[TSDB] '..tostring(s))
    mp.osd_message('[TSDB] '..tostring(s),secs or 3)
end
local function command_to(action,arg)
    local cmd={'script-message-to',SCRIPT,action}
    if arg~=nil then cmd[#cmd+1]=tostring(arg) end
    return cmd
end
local function section(s)
    return {title=clean(s,130),selectable=false,muted=true,value='ignore'}
end
local function label_language(s)
    s=tostring(s or 'und'):lower()
    if s=='es' or s=='spa' or s=='ea' or s:match('^es[-_]') then return 'Español','es' end
    if s=='en' or s=='eng' then return 'Inglés','en' end
    return s,s
end
-- Etiquetas del filtro: nunca se modifican los codigos originales de TSDB.
-- TSDB codifica el español de Latinoamérica como 'ea' (es-419).
-- Alias ISO-639 y variantes regionales. Cualquier codigo no reconocido
-- permanece en "Otros"; no se adivina el idioma a partir del nombre del archivo.
local LANGUAGE_NAMES = {
    es='Español', en='Inglés', fr='Francés', ar='Árabe', pt='Portugués',
    de='Alemán', it='Italiano', ja='Japonés', ko='Coreano', zh='Chino',
    ru='Ruso', id='Indonesio', nl='Neerlandés', hi='Hindi', tr='Turco',
    pl='Polaco', uk='Ucraniano', sv='Sueco', da='Danés', no='Noruego',
    fi='Finés', el='Griego', he='Hebreo', fa='Persa', th='Tailandés',
    vi='Vietnamita', ms='Malayo', tl='Filipino', ro='Rumano', hu='Húngaro',
    cs='Checo', sk='Eslovaco', bg='Búlgaro', hr='Croata', sr='Serbio',
    sl='Esloveno', sq='Albanés', mk='Macedonio', bs='Bosnio', ca='Catalán',
    eu='Euskera', gl='Gallego', et='Estonio', lv='Letón', lt='Lituano',
    is='Islandés', ga='Irlandés', cy='Galés', bn='Bengalí', ta='Tamil',
    te='Telugu', ur='Urdu', pa='Punyabí', sw='Suajili', af='Afrikáans',
    az='Azerí', be='Bielorruso', ka='Georgiano', hy='Armenio',
    my='Birmano', km='Jemer', lo='Lao', ne='Nepalí', si='Cingalés',
    mn='Mongol', uz='Uzbeko', kk='Kazajo', ml='Malayalam', kn='Canarés',
    mr='Maratí', gu='Guyaratí', am='Amárico', so='Somalí', ps='Pastún',
    ku='Kurdo', mt='Maltés', eo='Esperanto', la='Latín', lb='Luxemburgués',
    other='Otros (idioma no identificado)',
}
local LANGUAGE_ALIASES = {
    ea='es', spa='es', esp='es', spanish='es', ['español']='es', castellano='es',
    eng='en', english='en', ing='en',
    fre='fr', fra='fr', french='fr',
    ara='ar', arabic='ar',
    por='pt', pob='pt', pb='pt', portuguese='pt', ['português']='pt',
    ger='de', deu='de', deutsch='de', german='de',
    ita='it', italian='it',
    jpn='ja', jp='ja', japanese='ja',
    kor='ko', kr='ko', korean='ko',
    chi='zh', zho='zh', cn='zh', chinese='zh',
    rus='ru', russian='ru',
    ind='id', ['in']='id', indonesian='id',
    dut='nl', nld='nl', dutch='nl',
    hin='hi', tur='tr', pol='pl', ukr='uk', swe='sv', dan='da',
    nor='no', fin='fi', gre='el', ell='el', heb='he', per='fa', fas='fa',
    tha='th', vie='vi', may='ms', msa='ms', fil='tl', tgl='tl',
    rum='ro', ron='ro', hun='hu', cze='cs', ces='cs', slo='sk', slk='sk',
    bul='bg', hrv='hr', scc='sr', srp='sr', slv='sl', alb='sq', sqi='sq',
    mac='mk', mkd='mk', bos='bs', cat='ca', baq='eu', eus='eu', glg='gl',
    est='et', lav='lv', lit='lt', ice='is', isl='is', gle='ga', wel='cy',
    cym='cy', ben='bn', tam='ta', tel='te', urd='ur', pan='pa', swa='sw',
    afr='af', aze='az', bel='be', geo='ka', kat='ka', arm='hy', hye='hy',
    bur='my', mya='my', khm='km', lao='lo', nep='ne', sin='si', mon='mn',
    uzb='uz', kaz='kk', mal='ml', kan='kn', mar='mr', guj='gu', amh='am',
    som='so', pus='ps', kur='ku', mlt='mt', epo='eo', lat='la', ltz='lb',
}
local function language_bucket(raw)
    if type(raw)~='string' then return 'other' end
    local value=raw:lower():gsub('^%s+',''):gsub('%s+$','')
    -- es-ES / es-419 / es_LA se agrupan en Español; pt-BR en Portugués.
    value=value:match('^([^_%-]+)') or value
    local code=LANGUAGE_ALIASES[value] or value
    if LANGUAGE_NAMES[code] then return code end
    return 'other'
end
-- El selector previo usa los idiomas reconocidos por el propio filtro, sin 'Otros':
-- el API de TSDB no ofrece una consulta fiable para 'idioma desconocido'.
local function presearch_language_codes()
    local list={}
    for code in pairs(LANGUAGE_NAMES) do
        if code~='other' then list[#list+1]=code end
    end
    table.sort(list,function(a,b)
        if a=='es' then return true end
        if b=='es' then return false end
        return LANGUAGE_NAMES[a]<LANGUAGE_NAMES[b]
    end)
    return list
end
-- Compatible con una preferencia guardada en tsdb_desarrollo.conf.
if opt.language~='' then
    local initial=language_bucket(opt.language)
    if initial~='other' then search_language=initial end
end

local function language_counts()
    local counts={}
    for _,row in ipairs(rows) do
        local lang=row._language_bucket or language_bucket(row.language)
        counts[lang]=(counts[lang] or 0)+1
    end
    local ids={}
    for code in pairs(counts) do ids[#ids+1]=code end
    table.sort(ids,function(a,b)
        if a=='other' then return false end
        if b=='other' then return true end
        return LANGUAGE_NAMES[a]<LANGUAGE_NAMES[b]
    end)
    return ids,counts
end
local function show_language(row)
    if next(selected_languages)==nil then return true end
    return selected_languages[row._language_bucket or language_bucket(row.language)]==true
end
local function visible_count()
    local count=0
    for _,row in ipairs(rows) do
        if show_language(row) then count=count+1 end
    end
    return count
end
local function selected_count()
    local n=0
    for _ in pairs(selected_languages) do n=n+1 end
    return n
end
local function key(s)
    s=tostring(s or ''):lower()
    local accents={['á']='a',['é']='e',['í']='i',['ó']='o',['ú']='u',
       ['ü']='u',['ñ']='n',['à']='a',['è']='e',['ì']='i',['ò']='o',['ù']='u'}
    for a,b in pairs(accents) do s=s:gsub(a,b) end
    return (s:gsub('[^%w]',''))
end
local function words(s)
    local out={}
    for word in tostring(s or ''):lower():gmatch('[%w]+') do
        if #word>1 then out[word]=true end
    end
    return out
end
local function parse_id(text)
    local s=tostring(text or ''):lower():gsub('%s+','')
    local tt,season,episode=s:match('^(tt%d+):(%d+):(%d+)$')
    if tt and #tt<=12 and tonumber(season)>0 and tonumber(episode)>0 then
        return tt,tonumber(season),tonumber(episode)
    end
    if s:match('^tt%d+$') and #s<=12 then return s end
end
local function extract_year(text)
    text=tostring(text or '')
    return tonumber(text:match('19%d%d') or text:match('20%d%d'))
end
local function split_query(text)
    local q=clean(text)
    local sn,ep=q:match('[Ss](%d%d?)[Ee](%d%d?)')
    if not sn then sn,ep=q:match('(%d%d?)[Xx](%d%d?)') end
    if sn then
        q=q:gsub('[Ss]%d%d?[Ee]%d%d?',' '):gsub('%d%d?[Xx]%d%d?',' ')
    end
    local title,year=q:match('^(.-)%s*%((%d%d%d%d)%)%s*$')
    if not title then title,year=q:match('^(.-)%s+(%d%d%d%d)%s*$') end
    if title and clean(title)~='' then q=title end
    return clean(q),tonumber(year),tonumber(sn),tonumber(ep)
end
local function encode(s)
    return tostring(s):gsub('([^%w%-%._~])',function(c)
        return ('%%%02X'):format(c:byte())
    end)
end
local function video_reference()
    local filename=mp.get_property('filename','')
    local path=mp.get_property('path','')
    if filename=='' and path=='' then return nil end
    local media_title=mp.get_property('media-title','')
    local origin=filename
    if origin=='' or origin:find('://',1,true) then origin=media_title end
    if origin=='' then return nil end
    local tt=origin:lower():match('tt%d+') or media_title:lower():match('tt%d+')
    local season,episode=origin:match('[Ss](%d%d?)[Ee](%d%d?)')
    if not season then season,episode=origin:match('(%d%d?)[Xx](%d%d?)') end
    local year=extract_year(origin)
    local raw=origin:gsub('%.%w%w%w?%w?$',''):gsub('[._]',' ')
    local first_year=raw:find('19%d%d') or raw:find('20%d%d')
    if first_year then raw=raw:sub(1,first_year-1) end
    local tech=raw:find('%s+[Ss]%d%d?[Ee]%d%d?') or raw:find('%s+%d%d%d%d[pP]')
    if tech then raw=raw:sub(1,tech-1) end
    raw=clean(raw:gsub('%b[]',' '):gsub('%b()',' '))
    if raw=='' then return nil end
    local names={raw}
    local a,b=raw:match('^(.-)%s+[Aa][Kk][Aa]%s+(.+)$')
    if a and b then names={clean(b),clean(a),raw} end
    return {names=names,year=year,tt=tt,season=tonumber(season),
       episode=tonumber(episode),filename=origin,path=path}
end
local function is_current(entry,media)
    if not media then return false end
    if entry.tt and media.tt and entry.tt==media.tt then
        if media.season and entry.season and media.season~=entry.season then return false end
        if media.episode and entry.episode and media.episode~=entry.episode then return false end
        return true
    end
    local title=key(entry.name)
    if #title<5 then return false end
    if media.year and entry.year and math.abs(media.year-entry.year)>0 then return false end
    for _,alias in ipairs(media.names) do
        local ref=key(alias)
        if #ref>=5 and (ref:find(title,1,true) or title:find(ref,1,true)) then
            return true
        end
    end
    return false
end
local function release_score(row,media)
    if not media then return 0 end
    local release=tostring(row.release_name or ''):lower()
    local base=tostring(media.filename or ''):lower():gsub('%.%w%w%w?%w?$','')
    if key(release)~='' and key(release)==key(base) then return 10000 end
    local a,b=words(release),words(base)
    local weight={remux=35,bluray=20,blu=14,web=10,webrip=16,webdl=16,
       netflix=12,nf=12,amzn=12,['2160p']=18,['1080p']=18,['720p']=18,
       x264=10,x265=10,h264=10,h265=10,avc=10,hevc=10,
       fgt=30,succ=30,yify=30,yts=30}
    local score,total=0,0
    for w in pairs(a) do
        local v=weight[w] or (#w>3 and 3 or 1)
        total=total+v
        if b[w] then score=score+v end
    end
    if total>0 then score=score+30*score/total end
    for _,token in ipairs({'2160p','1080p','720p','remux','bluray','webdl','webrip'}) do
        if a[token] and not b[token] then score=score-2 end
    end
    local fps=tonumber(row.fps)
    local video_fps=mp.get_property_number('container-fps')
    if fps and video_fps and video_fps>0 then
        if math.abs(fps-video_fps)<0.05 then score=score+8 end
    end
    return score
end
local function row_label(row)
    local release=clean(row.release_name or '')
    if release=='' then release='Versión sin especificar' end
    if row._show_title then
        return clean(row._work or 'Ficha')..' · '..release
    end
    return release
end
local function row_hint(row)
    local language=label_language(row.language or (opt.language~='' and opt.language or 'und'))
    local fields={language,tostring(row.format or '?'):upper()}
    local fps=tonumber(row.fps)
    if fps then fields[#fields+1]=('%.3f fps'):format(fps) end
    if row.hearing_impaired==true then fields[#fields+1]='SDH' end
    return table.concat(fields,' · ')
end
-- Una sola lista continua, sin encabezados: espanol primero y luego los
-- otros idiomas consecutivos. No comparar resultados con el video abierto.
local function resort()
    table.sort(rows,function(a,b)
        local al=a._language_bucket or language_bucket(a.language)
        local bl=b._language_bucket or language_bucket(b.language)
        if al~=bl then
            if al=='es' then return true end
            if bl=='es' then return false end
            if al=='other' then return false end
            if bl=='other' then return true end
            return (LANGUAGE_NAMES[al] or al)<(LANGUAGE_NAMES[bl] or bl)
        end
        return a._order<b._order
    end)
end
local function render(update)
    local shown=visible_count()
    local filter_active=next(selected_languages)~=nil
    local summary=filter_active and (shown..' de '..#rows..' subtítulos visibles')
        or (#rows..' subtítulos')
    local finished=status and status:match('^Finalizado:%s*(.*)$')
    if finished then
        summary=clean(finished,145)..' · Finalizado'
        if filter_active then summary=shown..' visibles · '..summary end
    elseif status then
        summary=summary..' · '..clean(status,110)
    end

    -- Tres posiciones fijas, sin submenus laterales de uosc.
    local items={{title=clean(summary,170),icon=search_busy and 'spinner' or nil,
        muted=true,selectable=false,value='ignore'}}
    local pre=search_language=='' and 'Todos los idiomas'
        or LANGUAGE_NAMES[search_language] or search_language
    local post=filter_active and (selected_count()..' seleccionados') or 'Todos los idiomas'
    items[2]={title='Idioma de búsqueda',hint=pre,icon='language',
        value=command_to('toggle-inline-selector','search'),keep_open=true}
    items[3]={title='Filtrar resultados',
        hint=search_busy and 'Disponible al finalizar' or post,
        icon='filter_list',selectable=not search_busy,
        value=search_busy and 'ignore' or command_to('toggle-inline-selector','filter'),
        keep_open=true}

    -- El panel de resultados queda siempre intacto. El selector de idiomas es
    -- un desplegable compacto dentro de la ventana TSDB, no otra lista gigante.
    local dropdown=nil
    if inline_selector then
        local choices={}
        if inline_selector=='search' then
            choices[#choices+1]={title='Todos los idiomas',
                hint='Búsqueda libre',selected=search_language=='',
                value=command_to('set-search-language','all')}
            for _,code in ipairs(presearch_language_codes()) do
                choices[#choices+1]={title=LANGUAGE_NAMES[code],selected=search_language==code,
                    value=command_to('set-search-language',code)}
            end
        else
            choices[#choices+1]={title='Todos los idiomas',hint=#rows..' subtítulos',
                selected=not filter_active,value=command_to('all-languages')}
            local ids,counts=language_counts()
            for _,code in ipairs(ids) do
                choices[#choices+1]={title=LANGUAGE_NAMES[code],hint=counts[code]..' subtítulos',
                    selected=selected_languages[code]==true,
                    value=command_to('toggle-language',code)}
            end
        end
        -- Pass all choices to uosc; the picker itself provides a five-row
        -- scrollable viewport. No page switching or extra header panel.
        dropdown={kind=inline_selector,items=choices,
            close=command_to('close-inline-selector')}
    end
    if last_error then
        items[#items+1]={title='Error: '..clean(last_error,116),icon='warning',
            muted=true,selectable=false,value='ignore',tsdb_option=true}
    end
    local remembered_index=nil
    for _,row in ipairs(rows) do
        if row.id and show_language(row) then
            items[#items+1]={title=row_label(row),hint=row_hint(row),
                value=command_to('download',row.id),keep_open=true}
            if last_selected_subtitle_id and tostring(row.id)==last_selected_subtitle_id then
                remembered_index=#items
            end
        end
    end
    if #rows==0 and not status then
        items[#items+1]={title='Escribe un título o IMDb para buscar.',
            selectable=false,value='ignore',tsdb_option=true}
    elseif shown==0 and filter_active and #rows>0 then
        items[#items+1]={title='No hay subtítulos con estos filtros.',
            selectable=false,value='ignore',tsdb_option=true}
    end
    local menu={id=MENU_ID,type=MENU_TYPE,keep_open=true,
        title='Buscar película, serie o IMDb…',items=items,
        search_style='palette',search_debounce='submit',search_suggestion='',
        on_search=command_to('submit-search'),
        tsdb_view='results',tsdb_dropdown=dropdown,
        tsdb_reset_scroll=scroll_reset_on_next_render,
        footnote='Escribe el título o IMDb y pulsa Enter.'}
    scroll_reset_on_next_render=false
    mp.commandv('script-message-to','uosc',update and 'update-menu' or 'open-menu',utils.format_json(menu))
end

-- En la versión 0.2 probamos que esta actualización directa corrige el falso retraso.
local function render_if_visible() render(true) end
local function toggle_inline_selector(which)
    if which~='search' and which~='filter' then return end
    if which=='filter' and search_busy then return end
    inline_selector=(inline_selector==which) and nil or which
    inline_page=1
    render_if_visible()
end
local function close_inline_selector()
    inline_selector=nil
    inline_page=1
    -- El renderizador conserva el scroll que habia en los resultados.
    render_if_visible()
end
local function inline_page_move(direction)
    if not inline_selector then return end
    if direction=='previous' then inline_page=math.max(1,inline_page-1)
    elseif direction=='next' then inline_page=inline_page+1
    else return end
    render_if_visible()
end
local function toggle_language(code)
    if search_busy or #rows==0 or type(code)~='string' then return end
    local ids,counts=language_counts()
    if not counts[code] then return end
    if selected_languages[code] then
        selected_languages[code]=nil
    else
        selected_languages[code]=true
    end
    -- Cuando se desmarca la última casilla, se vuelve a "Todos los idiomas".
    render_if_visible()
end
local function all_languages()
    if search_busy or #rows==0 then return end
    selected_languages={}
    render_if_visible()
end
local function set_search_language(code)
    if search_busy then
        notify('La busqueda esta en curso; cambia el idioma al terminar.',2)
        return
    end
    if code=='all' or code=='' then
        search_language=''
    elseif type(code)=='string' and LANGUAGE_NAMES[code] and code~='other' then
        search_language=code
    else
        return
    end
    -- Los resultados anteriores NO se filtran ni se vuelven a consultar.
    -- La preferencia se empleara cuando el usuario pulse Enter de nuevo.
    inline_selector=nil
    inline_page=1
    render_if_visible()
end
local function report(s)
    status=s
    render_if_visible()
end
local function curl_async(args,capture,callback)
    local command={name='subprocess',args=args,playback_only=false,
       capture_stdout=capture,capture_stderr=true,capture_size=16*1024*1024}
    mp.command_native_async(command,function(ok,result,err)
        if not ok or type(result)~='table' or result.status~=0 then
            local detail=clean(result and result.stderr or err or 'Fallo del proceso',250)
            local code=type(result)=='table' and result.status or '?'
            logger.error('[TSDB] curl estado '..tostring(code)..': '..detail)
            callback(nil,detail,code,result)
        else callback(result,nil,0,result) end
    end)
end
-- Curl comprimido: los JSON de series pueden incluir un arbol de temporadas.
-- Se usa un proceso curl NUEVO para cada intento. Importante: NO usar
-- --retry de curl con salida capturada por stdout; si la primera descarga
-- recibio datos parciales, stdout puede juntar fragmentos de dos intentos
-- y convertir un JSON correcto en contenido invalido.
-- Codigo 28 = timeout; otros codigos recuperables indican corte de conexion.
-- HTTP 400/404 nunca se reintentan. TSDB solamente; Cinemeta no se altera.
local function transient_error(err,code)
    local number=tonumber(code)
    if number==28 or number==18 or number==52 or number==56 or number==7 then
        return true
    end
    if number==22 then
        local http=tonumber(tostring(err or ''):match('error:%s*(%d%d%d)'))
        return http==408 or http==429 or http==500 or http==502
           or http==503 or http==504 or http==522 or http==524
    end
    return false
end
local function request_json(url,callback,_legacy_retry_exact,diag)
    local diagnosis=diagnostic_context(url,diag)
    local max_retries=0
    if url:sub(1,#BASE+1)==BASE..'/' then
        max_retries=math.max(0,math.min(2,math.floor(tonumber(opt.transient_retries) or 1)))
    end
    local request_serial=search_serial
    local attempts=0
    local function attempt()
        if request_serial~=search_serial then return end
        attempts=attempts+1
        local started_at=type(mp.get_time)=='function' and mp.get_time() or os.time()
        diagnostic_write(('PETICION | %s | intento=%d | inicio'):format(diagnosis,attempts))
        logger.info('[TSDB] GET '..url..(attempts>1 and ' (reintento '..(attempts-1)..')' or ''))
        local secs=math.max(10,math.min(120,tonumber(opt.search_timeout) or 45))
        curl_async({'curl.exe','-fLsS','--compressed','--proto','=https',
           '--proto-redir','=https','--connect-timeout','6',
           '--max-time',tostring(secs),'-H','Accept: application/json',url},
           true,function(res,err,code,raw_result)
            if request_serial~=search_serial then return end
            local ended_at=type(mp.get_time)=='function' and mp.get_time() or os.time()
            local elapsed=math.max(0,math.floor((ended_at-started_at)*1000+0.5))
            if not res then
                local bytes=raw_result and type(raw_result.stdout)=='string'
                    and #raw_result.stdout or 0
                diagnostic_write(('PETICION | %s | intento=%d | FALLO | motivo=%s | curl=%s | HTTP=%s | bytes_parciales=%d | tiempo_ms=%d | detalle=%s'):
                    format(diagnosis,attempts,diagnostic_cause(err,code),tostring(code),
                           diagnostic_http(err),bytes,elapsed,clean(err,180)))
                if attempts<=max_retries and transient_error(err,code) then
                    local delay=tonumber(code)==22 and 3 or 1
                    diagnostic_write(('REINTENTO | %s | tras_intento=%d | espera=%ds'):
                        format(diagnosis,attempts,delay))
                    logger.warn('[TSDB] Error temporal; reintentando solo esta consulta en '..delay..' s: '..clean(url,140))
                    if type(mp.add_timeout)=='function' then
                        mp.add_timeout(delay,attempt)
                    else
                        attempt() -- Compatible con pruebas sin temporizadores MPV.
                    end
                    return
                end
                diagnostic_write(('PETICION | %s | FINAL FALLIDA | intentos=%d'):
                    format(diagnosis,attempts))
                callback(nil,err)
                return
            end
            local bytes=#(res.stdout or '')
            local data=utils.parse_json(res.stdout or '')
            if type(data)~='table' then
                diagnostic_write(('PETICION | %s | FINAL FALLIDA | motivo=JSON_INVALIDO | intentos=%d | bytes=%d | tiempo_ms=%d'):
                    format(diagnosis,attempts,bytes,elapsed))
                logger.error('[TSDB] JSON inesperado de '..url..': '..clean((res.stdout or ''):sub(1,350)))
                callback(nil,'Respuesta no es JSON válido')
                return
            end
            local subtitles=type(data.subtitles)=='table' and data.subtitles or nil
            local item_count=subtitles and type(subtitles.items)=='table' and #subtitles.items or -1
            local seasons=type(data.seasons)=='table' and #data.seasons or 0
            diagnostic_write(('PETICION | %s | OK | intentos=%d | bytes=%d | tiempo_ms=%d | items=%d | temporadas=%d'):
                format(diagnosis,attempts,bytes,elapsed,item_count,seasons))
            callback(data,nil)
        end)
    end
    attempt()
end
-- Cinemeta puede omitir el titulo exacto en una consulta compuesta aun
-- devolviendo otras obras de la misma franquicia. Si falta la coincidencia
-- exacta y hay un subtitulo distintivo tras ':' o entre corchetes, se realiza
-- una busqueda alternativa SOLO en Cinemeta. No altera la busqueda de TSDB.
local function title_candidates(text,year,callback,serial)
    local found,seen,errors={}, {},0
    local received_by_kind={movie={},series={}}
    local first_error=nil
    local function collect(kind,data,err)
        if err then
            errors=errors+1
            first_error=first_error or (kind..': '..tostring(err))
            logger.error('[TSDB] Cinemeta '..kind..': '..tostring(err))
        end
        if data and type(data.metas)=='table' then
            local bucket=received_by_kind[kind]
            for _,m in ipairs(data.metas) do
                if type(m)=='table' and type(m.id)=='string' and m.id:match('^tt%d+$') then
                    local y=tonumber(m.year or m.releaseInfo) or extract_year(m.releaseInfo)
                    bucket[#bucket+1]={tt=m.id,name=clean(m.name or m.id),year=y,kind=kind}
                end
            end
        end
    end
    local function finish()
        if serial~=search_serial then return end
        -- La llegada de movie/series es asíncrona. Consolidar siempre en orden
        -- fijo evita que un mismo IMDb adopte un tipo diferente según la red.
        found,seen={},{}
        for _,kind in ipairs({'movie','series'}) do
            for _,c in ipairs(received_by_kind[kind]) do
                if not seen[c.tt] then
                    seen[c.tt]=true
                    found[#found+1]=c
                end
            end
        end
        local want=key(text)
        for _,c in ipairs(found) do
            local n=key(c.name)
            c.rank=(n==want and 100 or (n:find(want,1,true) and 60 or 0))
               +(year and c.year==year and 35 or 0)
        end
        -- Conservamos la puntuación y el máximo de 24. Entre empates
        -- usamos nombre, año, tipo e IMDb como desempate estable, no el
        -- orden de llegada ni el orden accidental del catálogo.
        table.sort(found,function(a,b)
            if a.rank~=b.rank then return a.rank>b.rank end
            local an,bn=key(a.name),key(b.name)
            if an~=bn then return an<bn end
            local ay,by=a.year or 0,b.year or 0
            if ay~=by then return ay<by end
            if a.kind~=b.kind then return a.kind<b.kind end
            return a.tt<b.tt
        end)
        logger.info(('[TSDB] Cinemeta: %d titulos candidatos, %d consultas fallidas.'):
            format(#found,errors))
        diagnostic_write(('CINEMETA | candidatos_distintos=%d | peticiones_fallidas=%d'):
            format(#found,errors))
        for i=1,math.min(#found,24) do
            local c=found[i]
            logger.info(('[TSDB] Candidato %d: %s (%s) · %s · %s'):
                format(i,c.name,tostring(c.year or '?'),c.tt,c.kind))
        end
        callback(found,errors,first_error)
    end
    local function query_catalogs(term,done)
        local remaining=2
        local function received(kind,data,err)
            if serial~=search_serial then return end
            collect(kind,data,err)
            remaining=remaining-1
            if remaining==0 then done() end
        end
        for _,kind in ipairs({'movie','series'}) do
            local url=CINEMETA..'/catalog/'..kind..'/top/search='..encode(term)..'.json'
            request_json(url,function(data,err) received(kind,data,err) end,
                nil,{service='Cinemeta',phase='catalogo '..kind,title=term})
        end
    end
    query_catalogs(text,function()
        if serial~=search_serial then return end
        local want=key(text)
        local exact=false
        for _,c in ipairs(found) do
            if key(c.name)==want and (not year or not c.year or c.year==year) then
                exact=true
                break
            end
        end
        -- Una variante de nombre entre corchetes puede equivaler al titulo
        -- original. 'Unlimited Blade Works' es distintivo; 'Chapter 2' no.
        local alternative=text:match(':%s*(.+)$') or text:match('%[([^%]]+)%]')
        alternative=alternative and clean(alternative) or nil
        if not exact and alternative and #alternative>=14 and alternative:find('%s') then
            logger.info('[TSDB] Cinemeta sin titulo exacto; consulta adicional: '..alternative)
            query_catalogs(alternative,finish)
        else
            finish()
        end
    end)
end
local function start_search(raw)
    local query=clean(raw,220)
    if query=='' then report('Escribe un título o un código IMDb.');return end
    search_serial=search_serial+1
    local serial=search_serial
    inline_selector=nil
    inline_page=1
    scroll_reset_on_next_render=true
    mp.set_property_native('user-data/tsdb-result-scroll',0)
    rows,by_id={},{}
    last_selected_subtitle_id=nil
    selected_languages={} -- cada nueva busqueda empieza en Todos los idiomas.
    request_count=0
    search_busy=true
    last_error=nil
    last_query=query
    diagnostic_begin(query,search_language,serial)
    logger.info('[TSDB] Buscando: '..query)
    local imdb,season,episode=parse_id(query)
    local label,year,qs,qe=split_query(query)
    local candidates
    local failures=0 -- Solo errores técnicos, no respuestas HTTP 404.
    local unavailable_by_imdb={} -- Cada IMDb se cuenta una sola vez.
    local successful_imdb={} -- Un 200 en cualquier pasada descarta falso 404 parcial.
    local first_failure=nil
    local diagnosis_finished=false
    local function unavailable_count()
        local n=0
        for _ in pairs(unavailable_by_imdb) do n=n+1 end
        return n
    end
    local function final_suffix()
        local missing=unavailable_count()
        return (missing>0 and (' · '..missing..' fichas no disponibles en TSDB') or '')
             ..(failures>0 and (' · '..failures..' consultas fallidas') or '')
    end
    local n_active,n_done,n_total=0,0,0
    local next_index=1
    local matching_titles=0
    local max_titles=math.max(1,math.min(60,tonumber(opt.max_titles) or 24))
    local concurrency=math.max(1,math.min(5,tonumber(opt.concurrent_requests) or 3))
    local limit=math.max(1,math.min(100,tonumber(opt.max_results) or 100))
    local desired=search_language -- No cambiar el idioma de una busqueda en curso.

    -- En busqueda libre hay dos PASADAS para garantizar que ninguna consulta
    -- general se adelante a la exploración española de los 24 títulos.
    local phase=(desired=='' and 'spanish' or 'selected')
    local function progress()
        if serial~=search_serial then return end
        if n_done>=n_total and n_active==0 and phase~='spanish' then
            search_busy=false
            if desired~='' then
                status=('Finalizado: %d subtítulos de %d títulos con %s (%d revisados)%s'):
                    format(#rows,matching_titles,LANGUAGE_NAMES[desired] or desired,n_total,
                    final_suffix())
            else
                status=('Finalizado: %d subtítulos de %d títulos%s'):format(#rows,n_total,
                    final_suffix())
            end
            if not diagnosis_finished then
                diagnosis_finished=true
                diagnostic_write(('=== FIN BUSQUEDA %d | resultados=%d | candidatos=%d | fichas_no_encontradas=%d | errores_tecnicos=%d ==='):
                    format(diagnostic_search_number,#rows,n_total,unavailable_count(),failures))
                diagnostic_write('')
            end
            if #rows==0 then
                if first_failure then last_error=first_failure end
                notify(status..(last_error and (' · '..clean(last_error,110)) or ''),6)
            end
        else
            local label=phase=='spanish' and 'Buscando primero español' or
                        phase=='general' and 'Buscando todos los idiomas' or
                        ('Buscando '..(LANGUAGE_NAMES[desired] or desired))
            status=('%s: %d/%d títulos · %d subtítulos'):format(label,n_done,n_total,#rows)
        end
        render_if_visible()
    end

    -- Inserta solamente filas validas; nunca elimina por idioma en la busqueda
    -- libre. Evita duplicados entre las dos consultas de una misma obra.
    -- En una serie, los archivos de capitulos estan en data.seasons[].episodes[].
    -- El antiguo Lua solo leía data.subtitles.items (películas/paquetes de serie).
    -- Para no inundar el menú, mantenemos hasta max_results archivos POR
    -- RESPUESTA. En búsqueda libre pueden sumarse las dos pasadas sin duplicados. El filtro de idioma se aplica tambien al arbol de episodios, pues
    -- TSDB indica que lang= no filtra la seccion seasons del JSON.
    local function absorb(data,c,required_lang)
        if type(data)~='table' or type(data.subtitles)~='table' or
           type(data.subtitles.items)~='table' then return 0 end
        if type(data.title)=='table' and data.title.name then
            c.name=clean(data.title.name)
            c.year=tonumber(data.title.year) or c.year
        end
        local newly=0
        local added_here=0
        local function add_page(items,season,episode)
            if type(items)~='table' then return end
            for _,r in ipairs(items) do
                if added_here>=limit then return end
                local id=type(r)=='table' and tonumber(r.id)
                if id and id>0 and id==math.floor(id) and not by_id[tostring(id)]
                   and (not required_lang or language_bucket(r.language)==required_lang) then
                    r.id=tostring(math.floor(id))
                    r._language_bucket=language_bucket(r.language)
                    local work=c.name..(c.year and (' ('..c.year..')') or '')
                    if season and episode then
                        work=work..(' · S%02dE%02d'):format(season,episode)
                    end
                    r._work=work
                    r._show_title=not imdb and n_total>1
                    r._order=request_count+1
                    request_count=request_count+1
                    rows[#rows+1]=r
                    by_id[r.id]=r
                    newly=newly+1
                    added_here=added_here+1
                end
            end
        end
        add_page(data.subtitles.items)
        -- Solo al buscar una serie en general: si se indicó episodio, la ruta API
        -- ya lo devuelve en data.subtitles.items y no se recorre otra temporada.
        if not c.episode and type(data.seasons)=='table' and added_here<limit then
            for _,s in ipairs(data.seasons) do
                if added_here>=limit then break end
                if type(s)=='table' then
                    if type(s.subtitles)=='table' then add_page(s.subtitles.items) end
                    if type(s.episodes)=='table' then
                        for _,e in ipairs(s.episodes) do
                            if added_here>=limit then break end
                            if type(e)=='table' and type(e.subtitles)=='table' then
                                add_page(e.subtitles.items,tonumber(s.season),tonumber(e.episode))
                            end
                        end
                    end
                end
            end
        end
        if newly>0 then resort();render_if_visible() end
        return newly
    end

    local launch_more
    launch_more=function()
        if serial~=search_serial then return end
        while n_active<concurrency and next_index<=n_total do
            local c=candidates[next_index]
            next_index=next_index+1
            n_active=n_active+1
            local path='/v1/by-imdb/'..c.tt
            if c.season and c.episode then
                path=path..'/season/'..c.season..'/episode/'..c.episode
            end
            local url=BASE..path..'?limit='..limit..'&client=mpv-tsdb-desarrollo'
            local function record_failure(err)
                local detail=tostring(err or 'Respuesta inesperada')
                if detail:match('[Ee]rror:%s*404') then
                    -- HTTP 404 indica que TSDB no localizó esta ruta,
                    -- no una caída de conexión ni un problema de curl.
                    if not successful_imdb[c.tt] then unavailable_by_imdb[c.tt]=true end
                    diagnostic_write(('FICHA_NO_ENCONTRADA | fase=%s | IMDb=%s | titulo=%s | HTTP=404'):
                        format(phase,c.tt,tostring(c.name):gsub('[\r\n|]',' ')))
                    return
                end
                diagnostic_write(('FALLO_TECNICO | fase=%s | IMDb=%s | titulo=%s | causa=%s'):
                    format(phase,c.tt,tostring(c.name):gsub('[\r\n|]',' '),
                           detail:gsub('[\r\n|]',' '):sub(1,170)))
                failures=failures+1
                first_failure=first_failure or ('TSDB '..c.tt..': '..detail)
                logger.error('[TSDB] Título '..c.tt..': '..detail)
            end
            local function record_success()
                successful_imdb[c.tt]=true
                unavailable_by_imdb[c.tt]=nil
            end
            local function complete_candidate()
                if serial~=search_serial then return end
                n_active=n_active-1
                n_done=n_done+1
                if phase=='spanish' and n_done>=n_total and n_active==0 then
                    -- Todos los títulos ya fueron comprobados en español.
                    -- Solo AHORA comienza el barrido multilingüe.
                    phase='general'
                    next_index=1
                    n_done=0
                    progress()
                    launch_more()
                    return
                end
                progress()
                launch_more()
            end
            if phase=='selected' then
                -- Idioma marcado: consultar únicamente ese idioma en los
                -- títulos candidatos habituales, sin buscar títulos nuevos.
                request_json(url..'&lang='..encode(desired=='es' and 'es,es-419' or desired),function(data,err)
                    if serial~=search_serial then return end
                    if not data or type(data.subtitles)~='table' or
                        type(data.subtitles.items)~='table' then
                        record_failure(err or 'JSON sin subtitles.items')
                    else
                        record_success()
                        if absorb(data,c,desired)>0 then
                            matching_titles=matching_titles+1
                        end
                    end
                    complete_candidate()
                end,imdb and serial or nil,
                {service='TSDB',phase='idioma '..desired,tt=c.tt,title=c.name})
            elseif phase=='spanish' then
                request_json(url..'&lang=es,es-419',function(data,err)
                    if serial~=search_serial then return end
                    if not data or type(data.subtitles)~='table' or
                        type(data.subtitles.items)~='table' then
                        record_failure(err or 'Consulta española inesperada')
                    else
                        record_success()
                        absorb(data,c,'es')
                    end
                    complete_candidate()
                end,imdb and serial or nil,
                {service='TSDB',phase='espanol primero',tt=c.tt,title=c.name})
            else
                -- Barrido general de TODOS los idiomas, mismos títulos.
                request_json(url,function(data,err)
                    if serial~=search_serial then return end
                    if not data or type(data.subtitles)~='table' or
                        type(data.subtitles.items)~='table' then
                        record_failure(err or 'Consulta general inesperada')
                    else
                        record_success()
                        absorb(data,c)
                    end
                    complete_candidate()
                end,imdb and serial or nil,
                {service='TSDB',phase='todos los idiomas',tt=c.tt,title=c.name})
            end
        end
    end

    local function accept_candidates(list,errors,catalog_err)
        if serial~=search_serial then return end
        failures=errors or 0
        if catalog_err then first_failure=catalog_err end
        candidates={}
        for i=1,math.min(#list,max_titles) do
            local c=list[i]
            -- Una pelicula con /season/N/episode/M devuelve error HTTP 400.
            if not imdb and c.kind=='series' then c.season=qs; c.episode=qe end
            candidates[#candidates+1]=c
        end
        n_total=#candidates
        diagnostic_write(('CANDIDATOS ELEGIDOS | cantidad=%d | maximo=%d'):
            format(n_total,max_titles))
        for i,c in ipairs(candidates) do
            diagnostic_write(('CANDIDATO %d | IMDb=%s | titulo=%s | tipo=%s | temporada=%s | episodio=%s'):
                format(i,c.tt,tostring(c.name):gsub('[\r\n|]',' '),
                    tostring(c.kind),tostring(c.season or '-'),tostring(c.episode or '-')))
        end
        if n_total==0 then
            search_busy=false
            status=failures>0 and 'No se pudieron consultar los catálogos.' or
                'No se encontraron títulos para '..clean(query,65)
            if catalog_err then last_error=catalog_err end
            notify(status..(catalog_err and (' · '..clean(catalog_err,110)) or ''),6)
            diagnostic_write('=== FIN BUSQUEDA SIN CANDIDATOS ===')
            diagnostic_write('')
            render_if_visible()
            return
        end
        progress()
        launch_more()
    end
    if imdb then
        report('Consultando IMDb '..imdb..'…')
        accept_candidates({{tt=imdb,name=imdb,kind='movie',season=season,episode=episode}},0)
    else
        report('Resolviendo títulos de «'..clean(query,70)..'»…')
        title_candidates(label,year,accept_candidates,serial)
    end
end
-- Mismo mecanismo de envio directo comprobado en TSDB v0.2.
-- uosc entrega la consulta como argumento al pulsar Ctrl + Enter.
local function submit_search(text)
    local q=clean(text,220)
    if q=='' then
        report('Introduce un título o un código IMDb para buscar.')
        return
    end
    logger.info('[TSDB] Consulta recibida desde uosc: '..q)
    notify('Buscando «'..clean(q,65)..'»…',2)
    mp.commandv('script-message-to','uosc','menu-action','search-cancel',MENU_ID)
    start_search(q)
end
local function path_equal(a,b)
    local function norm(s)
        return tostring(s or ''):gsub('\\','/'):gsub('^file:///',''):gsub('/+','/'):lower()
    end
    a,b=norm(a),norm(b)
    if a=='' or b=='' then return false end
    if a==b then return true end
    if not a:find('/',1,true) then return a==b:match('[^/]+$') end
    return false
end
local function existing_track(path)
    local tracks=mp.get_property_native('track-list',{})
    if type(tracks)~='table' then return nil end
    local ids={}
    for _,t in ipairs(tracks) do
        if t.type=='sub' and (t.external==true or t.external=='yes')
          and path_equal(t['external-filename'] or t.external_filename,path) then
            ids[#ids+1]=t.id
        end
    end
    if #ids==0 then return nil end
    for i=#ids,2,-1 do pcall(mp.commandv,'sub-remove',tostring(ids[i])) end
    mp.set_property('sid',tostring(ids[1]))
    mp.set_property('sub-visibility','yes')
    return true
end
local function valid_subtitle(path)
    local fi=utils.file_info(path)
    if not fi or not fi.size or fi.size<12 or fi.size>10*1024*1024 then return false end
    local f=io.open(path,'rb')
    if not f then return false end
    local first=f:read(8192) or ''
    f:close()
    return first:find('%-%->')~=nil or first:find('WEBVTT',1,true)~=nil
       or first:find('[Script Info]',1,true)~=nil
end
local function ensure_folder()
    local info=utils.file_info(subtitle_dir)
    if info and info.is_dir then return true end
    local escaped=subtitle_dir:gsub("'","''")
    local cmd="[System.IO.Directory]::CreateDirectory('"..escaped.."') | Out-Null"
    local res=mp.command_native({name='subprocess',playback_only=false,
        args={'powershell.exe','-NoProfile','-NonInteractive','-Command',cmd},
        capture_stdout=true,capture_stderr=true})
    return type(res)=='table' and res.status==0
end
local function activate(path,row,origin)
    if existing_track(path) then notify('Subtítulo ya cargado: activado.',2);return end
    local language,code=label_language(row.language or (opt.language~='' and opt.language or 'und'))
    local nombre=clean(row.release_name or '')
    if nombre=='' then nombre=language end
    local ok,err=pcall(mp.commandv,'sub-add',path,'select',nombre..' [TSDB]',code)
    if not ok then report('No se pudo cargar el subtítulo en MPV: '..tostring(err));return end
    mp.set_property('sub-visibility','yes')
    if origin=='cache' then
        notify('Subtítulo reutilizado de caché y cargado.',3)
    elseif origin=='download' then
        notify('Subtítulo descargado y cargado.',3)
    else
        notify('Subtítulo cargado en MPV.',3)
    end
end
local function download(id)
    if download_busy then notify('Hay una descarga en curso.',2);return end
    local row=by_id[tostring(id)]
    if not row then report('Ese resultado ya no está disponible. Busca otra vez.');return end
    last_selected_subtitle_id=tostring(id) -- Restauración visual al volver a abrir.
    local n=tonumber(row.id)
    if not n or n<1 or n~=math.floor(n) then report('ID inválido.');return end
    local fmt=tostring(row.format or 'srt'):lower()
    if fmt~='srt' and fmt~='ass' and fmt~='ssa' and fmt~='vtt' then
        report('TSDB devuelve '..clean(fmt,15)..', formato aún no compatible con este script.');return
    end
    if mp.get_property('path','')=='' then
        report('Abre un video antes de cargar un subtítulo.');return
    end
    if not ensure_folder() then report('No se pudo crear la carpeta de subtítulos.');return end
    local output=utils.join_path(subtitle_dir,'TSDB-'..math.floor(n)..'.'..fmt)
    if valid_subtitle(output) then activate(output,row,'cache');return end
    os.remove(output)
    local part=output..'.part'
    os.remove(part)
    local url=BASE..'/get/'..math.floor(n)..'?client=mpv-tsdb-desarrollo'
    download_busy=true
    download_serial=download_serial+1
    local serial,media,video=download_serial,media_serial,mp.get_property('path','')
    report('Descargando subtítulo '..math.floor(n)..'…')
    curl_async({'curl.exe','-fLsS','--proto','=https','--proto-redir','=https',
       '--connect-timeout','6','--max-time',tostring(opt.download_timeout),
       '--max-filesize','10485760','--output',part,url},false,function(res,err)
        if serial~=download_serial or media~=media_serial then os.remove(part);return end
        download_busy=false
        if not res then os.remove(part);report('Error al descargar: '..tostring(err));return end
        if not valid_subtitle(part) then
            os.remove(part);report('La descarga no contiene un subtítulo válido.');return
        end
        if not os.rename(part,output) then
            os.remove(part);report('No se pudo guardar el archivo.');return
        end
        if mp.get_property('path','')~=video then
            report('Descargado; cambió el video y no se cargó.');return
        end
        status='Descarga completada'
        render_if_visible()
        activate(output,row,'download')
    end)
end
local function open_menu()
    -- Abrir el menu nunca inicia una búsqueda: el usuario escribe y pulsa Enter.
    inline_selector=nil
    render(false)
end
mp.register_script_message('open',open_menu)
mp.register_script_message('submit-search',submit_search)
mp.register_script_message('download',download)
mp.register_script_message('toggle-language',toggle_language)
mp.register_script_message('all-languages',all_languages)
mp.register_script_message('set-search-language',set_search_language)
mp.register_script_message('toggle-inline-selector',toggle_inline_selector)
mp.register_script_message('close-inline-selector',close_inline_selector)
mp.register_script_message('inline-page',inline_page_move)
mp.register_event('file-loaded',function()
    media_serial=media_serial+1
    search_serial=search_serial+1
    download_serial=download_serial+1
    search_busy,download_busy=false,false
    status,last_query=nil,nil
    rows,by_id={},{}
    selected_languages={}
    last_selected_subtitle_id=nil
    inline_selector=nil
    inline_page=1
    scroll_reset_on_next_render=true
    mp.set_property_native('user-data/tsdb-result-scroll',0)
    -- Evita borrar subtítulos ya guardados en disco; solo reinicia los resultados.
    render_if_visible()
end)
mp.add_key_binding('Ctrl+Shift+t','tsdb-desarrollo',open_menu)
logger.info('[TSDB] v0.3.13 cabecera constante; funciones de 0.3.11 intactas. Script: '..SCRIPT)