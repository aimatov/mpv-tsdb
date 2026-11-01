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
