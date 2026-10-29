-- Adaptacion de elements/Menu.lua de uosc para TSDB v0.1.0-alpha.1.
-- Derivado de uosc por tomasklaen y colaboradores, bajo LGPL-2.1.
-- Requiere la version de uosc usada para el desarrollo; consulte README.
local Element = require('elements/Element')

---@alias MenuAction {name: string; icon: string; label?: string; filter_hidden?: boolean;}

-- Menu data structure accepted by `Menu:open(menu)`.
---@alias MenuData {id?: string; type?: string; title?: string; hint?: string; footnote: string; search_style?: 'on_demand' | 'palette' | 'disabled';  item_actions?: MenuAction[]; item_actions_place?: 'inside' | 'outside'; callback?: string[]; keep_open?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'; items?: MenuDataChild[]; selected_index?: integer; on_search?: string|string[]; on_paste?: string|string[]; on_move?: string|string[]; on_close?: string|string[]; search_debounce?: number|string; search_submenus?: boolean; search_suggestion?: string; search_submit?: boolean; bind_keys?: string[]}
---@alias MenuDataChild MenuDataItem|MenuData
---@alias MenuDataItem {title?: string; hint?: string; icon?: string; value: any; actions?: MenuAction[]; actions_place?: 'inside' | 'outside'; active?: boolean; keep_open?: boolean; selectable?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'}
---@alias MenuOptions {mouse_nav?: boolean;}

-- Internal data structure created from `MenuData`.
---@alias MenuStack {id?: string; type?: string; title?: string; hint?: string; footnote: string; search_style?: 'on_demand' | 'palette' | 'disabled';  item_actions?: MenuAction[]; item_actions_place?: 'inside' | 'outside'; callback?: string[]; selected_index?: number; action_index?: number; keep_open?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'; items: MenuStackChild[]; on_search?: string|string[]; on_paste?: string|string[]; on_move?: string|string[]; on_close?: string|string[]; search_debounce?: number|string; search_submenus?: boolean; search_suggestion?: string; search_submit?: boolean; bind_keys?: string[]; parent_menu?: MenuStack; submenu_path: integer[]; active?: boolean; width: number; height: number; top: number; scroll_y: number; scroll_height: number; title_width: number; hint_width: number; max_width: number; is_root?: boolean; fling?: Fling, search?: Search, ass_safe_title?: string}
---@alias MenuStackChild MenuStackItem|MenuStack
---@alias MenuStackItem {title?: string; hint?: string; icon?: string; value: any; actions?: MenuAction[]; actions_place?: 'inside' | 'outside'; active?: boolean; keep_open?: boolean; selectable?: boolean; bold?: boolean; italic?: boolean; muted?: boolean; separator?: boolean; align?: 'left'|'center'|'right'; title_width: number; hint_width: number; ass_safe_hint?: string}
---@alias Fling {y: number, distance: number, time: number, easing: fun(x: number), duration: number, update_cursor?: boolean}
---@alias Search {query: string; cursor: number; timeout: unknown; min_top: number; max_width: number; source: {width: number; top: number; scroll_y: number; selected_index?: integer; items?: MenuStackChild[]}}

---@alias MenuEventActivate {type: 'activate'; index: number; value: any; action?: string; modifiers?: string; alt: boolean; ctrl: boolean; shift: boolean; is_pointer: boolean; keep_open?: boolean; menu_id: string;}
---@alias MenuEventMove {type: 'move'; from_index: number; to_index: number; menu_id: string;}
---@alias MenuEventSearch {type: 'search'; query: string; menu_id: string;}
---@alias MenuEventKey {type: 'key'; id: string; key: string; modifiers?: string; alt: boolean; ctrl: boolean; shift: boolean; menu_id: string; selected_item?: {index: number; value: any; action?: string;}}
---@alias MenuEventPaste {type: 'paste'; value: string; menu_id: string; selected_item?: {index: number; value: any; action?: string;}}
---@alias MenuEventBack {type: 'back';}
---@alias MenuEventClose {type: 'close';}
---@alias MenuEvent MenuEventActivate | MenuEventMove | MenuEventSearch | MenuEventKey | MenuEventPaste | MenuEventBack | MenuEventClose
---@alias MenuCallback fun(data: MenuEvent)

---@class Menu : Element
local Menu = class(Element)

---@param data MenuData
---@param callback MenuCallback
---@param opts? MenuOptions
function Menu:open(data, callback, opts)
	local open_menu = Menu:is_open()
	if open_menu then
		open_menu.is_being_replaced = true
		open_menu:close(true)
	end
	return Menu:new(data, callback, opts)
end

---@param menu_type? string
---@return Menu|nil
function Menu:is_open(menu_type)
	return Elements.menu and (not menu_type or Elements.menu.type == menu_type) and Elements.menu or nil
end

---@param immediate? boolean Close immediately without fadeout animation.
---@param callback? fun() Called after the animation (if any) ends and element is removed and destroyed.
---@overload fun(callback: fun())
function Menu:close(immediate, callback)
	if type(immediate) ~= 'boolean' then callback = immediate end

	local menu = self == Menu and Elements.menu or self

	if state.ime_active == false and mp.get_property_bool('input-ime') then
		mp.set_property_bool('input-ime', false)
	end

	if menu and not menu.destroyed then
		if menu.type == 'tsdb-external' and menu.root and menu.root.tsdb_view == 'results'
			and menu.current == menu.root then
			mp.set_property_native('user-data/tsdb-result-scroll', menu.root.scroll_y or 0)
		end
		if menu.is_closing then
			menu:tween_stop()
			return
		end

		local function close()
			local on_close = menu.root.on_close -- removed in menu:destroy()
			Elements:remove('menu') -- calls menu:destroy() under the hood
			Elements:update_proximities()
			cursor:queue_autohide()

			-- Call :close() callback
			if callback then callback() end

			-- Call callbacks/events defined on menu config
			local close_event = {type = 'close'}
			if not on_close or menu:command_or_event(on_close, {}, close_event) ~= 'event' then
				menu.callback(close_event)
			end

			request_render()
		end

		menu.is_closing = true

		if immediate then
			close()
		else
			menu:fadeout(close)
		end
	end
end

---@param data MenuData
---@param callback MenuCallback
---@param opts? MenuOptions
---@return Menu
function Menu:new(data, callback, opts) return Class.new(self, data, callback, opts) --[[@as Menu]] end
---@param data MenuData
---@param callback MenuCallback
---@param opts? MenuOptions
function Menu:init(data, callback, opts)
	Element.init(self, 'menu', {render_order = 1001})

	-----@type fun()
	self.callback = callback
	self.opts = opts or {}
	self.offset_x = 0 -- Used for submenu transition animation.
	self.mouse_nav = self.opts.mouse_nav -- Stops pre-selecting items
	self.mouse_hovered_index = nil -- Current menu's item being hovered by mouse, ignoring it's selectable or not.
	self.item_height = nil
	self.min_width = nil
	self.item_spacing = 1
	self.item_padding = nil
	self.separator_size = nil
	self.padding = nil
	self.gap = nil
	self.font_size = nil
	self.font_size_hint = nil
	self.scroll_step = nil -- Item height + item spacing.
	self.scroll_height = nil -- Items + spacings - container height.
	self.opacity = 0 -- Used to fade in/out.
	self.type = data.type
	---@type MenuStack Root MenuStack.
	self.root = nil
	---@type MenuStack Current MenuStack.
	self.current = nil
	---@type MenuStack[] All menus in a flat array.
	self.all = nil
	---@type table<string, MenuStack> Map of submenus by their ids, such as `'Tools > Aspect ratio'`.
	self.by_id = {}
	self.type_to_search = options.menu_type_to_search
	self.is_being_replaced = false
	self.is_closing = false
	self.drag_last_y = nil
	self.is_dragging = false
	self.tsdb_popup_rect = nil
	self.tsdb_dropdown_kind = nil
	self.tsdb_dropdown_scroll = 0
	self.tsdb_ignore_mouse_up = false
	-- TSDB: delayed full filename tooltip, only for visibly truncated rows.
	self.tsdb_hover_key = nil
	self.tsdb_hover_candidate = nil
	self.tsdb_hover_ready = false
	self.tsdb_hover_timer = nil

	if utils.shared_script_property_set then
		utils.shared_script_property_set('uosc-menu-type', self.type or 'undefined')
	end
	mp.set_property_native('user-data/uosc/menu/type', self.type or 'undefined')
	self:update(data)

	for _, menu in ipairs(self.all) do self:scroll_to_index(menu.selected_index, menu.id) end
	if self.type == 'tsdb-external' and data.tsdb_view == 'results' then
		if data.tsdb_reset_scroll then
			mp.set_property_native('user-data/tsdb-result-scroll', 0)
		else
			self:set_scroll_to(tonumber((mp.get_property_native('user-data/tsdb-result-scroll'))) or 0,
				self.root.id)
		end
	end
	if self.mouse_nav then self.current.selected_index = nil end

	self:tween_property('opacity', 0, 1)
	self:enable_key_bindings()
	if self.type ~= 'tsdb-external' then Elements:maybe('curtain', 'register', self.id) end -- TSDB-VISUAL-014

	if data.search_submit then
		-- We have to defer this so that menu callbacks don't fire before the menu
		-- instance we're constructing here is returned, as they might depend on it.
		mp.add_timeout(0.01, function()
			self:search_submit()
		end)
	end
end

function Menu:destroy()
	if self.tsdb_hover_timer then self.tsdb_hover_timer:kill(); self.tsdb_hover_timer = nil end
	Element.destroy(self)
	self.is_closing = false
	if self.type ~= 'tsdb-external' and not self.is_being_replaced then
		Elements:maybe('curtain', 'unregister', self.id)
	end
	if utils.shared_script_property_set then
		utils.shared_script_property_set('uosc-menu-type', nil)
	end
	mp.set_property_native('user-data/uosc/menu/type', nil)
end

---@param data MenuData
function Menu:update(data)
	local old_view = self.root and self.root.tsdb_view
	if self.type == 'tsdb-external' and self.root and self.current == self.root
		and old_view == 'results' and data.tsdb_view ~= 'results' then
		mp.set_property_native('user-data/tsdb-result-scroll', self.root.scroll_y or 0)
	end
	local new_root = {is_root = true, submenu_path = {}}
	local new_all = {}
	local new_menus = {} -- menus that didn't exist before this `update()`
	local new_by_id = {}
	local menus_to_serialize = {{new_root, data}}
	local old_current_id = self.current and self.current.id
	local menu_state_props = {'selected_index', 'action_index', 'scroll_y', 'fling', 'search'}
	local internal_props_set = create_set(itable_append({'is_root', 'submenu_path', 'id', 'items'}, menu_state_props))

	table_assign_exclude(new_root, data, internal_props_set)

	local i = 0
	while i < #menus_to_serialize do
		i = i + 1
		local menu, menu_data = menus_to_serialize[i][1], menus_to_serialize[i][2]
		local parent_id = menu.parent_menu and not menu.parent_menu.is_root and menu.parent_menu.id
		if menu_data.id then
			menu.id = menu_data.id
		elseif not menu.is_root then
			menu.id = (parent_id and parent_id .. ' > ' or '') .. (menu_data.title or i)
		else
			menu.id = '{root}'
		end
		menu.icon = 'chevron_right'

		-- Normalize `search_debounce`
		if type(menu_data.search_debounce) == 'number' then
			menu.search_debounce = math.max(0, menu_data.search_debounce --[[@as number]])
		elseif menu_data.search_debounce == 'submit' then
			menu.search_debounce = 'submit'
		else
			menu.search_debounce = menu.on_search and 300 or 0
		end

		-- Update items
		local first_active_index = nil
		menu.items = {
			{title = t('Empty'), value = 'ignore', italic = 'true', muted = 'true', selectable = false, align = 'center'},
		}

		for i, item_data in ipairs(menu_data.items or {}) do
			if item_data.active and not first_active_index then first_active_index = i end

			local item = {}
			table_assign_exclude(item, item_data, internal_props_set)
			if item.keep_open == nil then item.keep_open = menu.keep_open end

			-- Submenu
			if item_data.items then
				item.parent_menu = menu
				item.submenu_path = itable_join(menu.submenu_path, {i})
				menus_to_serialize[#menus_to_serialize + 1] = {item, item_data}
			end

			menu.items[i] = item
		end

		if menu.is_root then menu.selected_index = menu_data.selected_index or first_active_index end

		-- Retain old state
		local old_menu = self.by_id[menu.id]
		if old_menu then
			table_assign_props(menu, old_menu, menu_state_props)
		else
			new_menus[#new_menus + 1] = menu
		end

		new_all[#new_all + 1] = menu
		new_by_id[menu.id] = menu
	end

	self.root, self.all, self.by_id = new_root, new_all, new_by_id
	self.current = self.by_id[old_current_id] or self.root

	self:update_content_dimensions()
	self:reset_navigation()
	if self.type == 'tsdb-external' and data.tsdb_reset_scroll then
		self:set_scroll_to(0, self.root.id)
	elseif self.type == 'tsdb-external' and old_view and old_view ~= 'results'
		and data.tsdb_view == 'results' then
		self:set_scroll_to(tonumber((mp.get_property_native('user-data/tsdb-result-scroll'))) or 0,
			self.root.id)
	end

	-- Ensure palette menus have active searches, and clean empty searches from menus that lost the `palette` flag
	local update_dimensions_again = false
	for _, menu in ipairs(self.all) do
		local is_palette = menu.search_style == 'palette'
		if not menu.search and (is_palette or (menu.search_suggestion and itable_index_of(new_menus, menu))) then
			update_dimensions_again = true
			self:search_init(menu.id)
		elseif not is_palette and menu.search and menu.search.query == '' then
			update_dimensions_again = true
			menu.search = nil
		end
	end
	-- We update before _and_ after because search_inits need the initial un-searched
	-- menu's position and scroll state to save on the `search.source` table.
	if update_dimensions_again then
		self:update_content_dimensions()
		self:reset_navigation()
	end
	-- Apply search suggestions
	for _, menu in ipairs(new_menus) do
		if menu.search_suggestion then
			menu.search.query = menu.search_suggestion
			menu.search.cursor = #menu.search_suggestion
		end
	end
	for _, menu in ipairs(self.all) do
		if menu.search then
			-- the menu items are new objects and the search needs to contain those
			menu.search.source.items = not menu.on_search and menu.items or nil
			-- Only internal searches are immediately submitted
			if not menu.on_search then self:search_internal(menu.id, true) end
		end

		if menu.selected_index then self:select_by_offset(0, menu) end
	end

	self:search_ensure_key_bindings()
end

---@param items MenuDataChild[]
function Menu:update_items(items)
	local data = table_assign({}, self.root)
	data.items = items
	self:update(data)
end

function Menu:update_content_dimensions()
	self.item_height = round(options.menu_item_height * state.scale)
	self.min_width = round(options.menu_min_width * state.scale)
	self.separator_size = round(1 * state.scale)
	self.scrollbar_size = round((self.type == 'tsdb-external' and 10 or 2) * state.scale) -- TSDB-UI-STICKY-2
	self.padding = round(options.menu_padding * state.scale)
	self.gap = round(2 * state.scale)
	self.font_size = round(self.item_height * 0.48 * options.font_scale)
	self.font_size_hint = self.font_size - 1
	self.item_padding = round((self.item_height - self.font_size) * 0.6)
	self.scroll_step = self.item_height + self.item_spacing
	self.tsdb_result_step = round(self.item_height * 1.78) + self.item_spacing -- TSDB-VISUAL-014

	local title_opts = {size = self.font_size, italic = false, bold = false}
	local hint_opts = {size = self.font_size_hint}

	for _, menu in ipairs(self.all) do
		title_opts.bold, title_opts.italic = true, false
		local max_width = text_width(menu.title, title_opts) + 2 * self.item_padding

		-- Estimate width of a widest item
		for _, item in ipairs(menu.items) do
			local icon_width = item.icon and self.font_size or 0
			item.title_width = text_width(item.title, title_opts)
			item.hint_width = text_width(item.hint, hint_opts)
			local spacings_in_item = 1 + (item.title_width > 0 and 1 or 0)
				+ (item.hint_width > 0 and 1 or 0) + (icon_width > 0 and 1 or 0)
			local estimated_width = item.title_width + item.hint_width + icon_width
				+ (self.item_padding * spacings_in_item)
			if estimated_width > max_width then max_width = estimated_width end
		end

		menu.max_width = max_width
	end

	self:update_dimensions()
end

function Menu:update_dimensions()
	-- Coordinates and sizes are of the scrollable area. Title is rendered
	-- above it, so we need to account for that in max_height and ay position.
	-- This is a debt from an era where we had different cursor event handling,
	-- and dumb titles with no search inputs. It could use a refactor.
	local margin = round(self.item_height / 2)
	local external_buttons_reserve = display.width / self.item_height > 14 and self.scroll_step * 6 - margin * 2 or 0
	local width_available = display.width - margin * 2 - self.padding * 2 - external_buttons_reserve
	local height_available = display.height - margin * 2 - self.padding * 2
	local min_width = math.min(self.min_width, width_available)

	for _, menu in ipairs(self.all) do
		local width = math.max(menu.search and menu.search.max_width or 0, menu.max_width)
		if self.type == 'tsdb-external' and menu.is_root then
			-- The root dialog no longer expands to the longest subtitle release name.
			-- Results no longer fill almost the whole screen. The list uses scroll instead.
			width = #menu.items > 5 and math.min(width_available * 0.73, 1120 * state.scale)
				or math.min(width_available * 0.69, 1020 * state.scale)
		elseif self.type == 'tsdb-external' then
			width = math.min(width, display.width * 0.34)
		end
		menu.width = round(clamp(min_width, width, width_available))
		local title_height = (menu.is_root and menu.title or menu.search) and
			self.scroll_step + self.separator_size + 1 or 0
		local footnote_height = self.font_size * 1.5
		local max_height = height_available - title_height - footnote_height
		local content_height = self.scroll_step * #menu.items
		if self.type == 'tsdb-external' and menu.is_root then
			local results_count = math.max(0, #menu.items - 3)
			content_height = 3 * self.scroll_step + results_count * self.tsdb_result_step
			local desired_height = results_count > 0 and content_height or (4.25 * self.scroll_step)
			-- Leave a substantial empty zone above uosc's proximity-triggered bar.
            menu.height = round(math.min(desired_height, max_height, display.height * 0.55)) -- TSDB 0.3.18
		elseif self.type == 'tsdb-external' then
			-- A selected language stays in a small scrollable list, not a full-height column.
			menu.height = math.min(content_height - self.item_spacing, max_height, self.scroll_step * 11)
		else
			menu.height = math.min(content_height - self.item_spacing, max_height)
		end
		menu.top = clamp(
			title_height + margin + self.padding,
			menu.search and math.min(menu.search.min_top, menu.search.source.top) or height_available,
			round((height_available - menu.height + title_height) / 2)
		)
		if menu.search then
			menu.search.min_top = math.min(menu.search.min_top, menu.top)
			menu.search.max_width = math.max(menu.search.max_width, menu.width)
		end
		menu.scroll_height = math.max(content_height - menu.height - self.item_spacing, 0)
		self:set_scroll_to(menu.scroll_y, menu.id) -- clamps scroll_y to scroll limits
	end

	self:update_coordinates()
end

-- Updates element coordinates to match padding box of currently open (sub)menu.
function Menu:update_coordinates()
	local ax = round((display.width - self.current.width) / 2 - self.padding) + self.offset_x
	self:set_coordinates(
		ax, self.current.top - self.padding,
		ax + self.current.width + self.padding * 2, self.current.top + self.current.height + self.padding
	)
end

function Menu:reset_navigation()
	local menu = self.current

	-- Reset indexes and scroll
	self:set_scroll_to(menu.scroll_y) -- clamps scroll_y to scroll limits
	if menu.items and #menu.items > 0 then
		-- Normalize existing selected_index always, and force it only in keyboard navigation
		if not self.mouse_nav then
			self:select_by_offset(0)
		end
	else
		self:select_index(nil)
	end

	-- Walk up the parent menu chain and activate items that lead to current menu
	local parent = menu.parent_menu
	while parent do
		parent.selected_index = itable_index_of(parent.items, menu)
		menu, parent = parent, parent.parent_menu
	end

	request_render()
end

function Menu:set_offset_x(offset)
	local delta = offset - self.offset_x
	self.offset_x = offset
	self:set_coordinates(self.ax + delta, self.ay, self.bx + delta, self.by)
end

function Menu:fadeout(callback) self:tween_property('opacity', 1, 0, callback) end

-- If `menu_id` is provided, will return menu with that id or `nil`. If `menu_id` is `nil`, will return current menu.
---@param menu_id? string
---@return MenuStack | nil
function Menu:get_menu(menu_id) return menu_id == nil and self.current or self.by_id[menu_id] end

function Menu:get_first_active_index(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	for index, item in ipairs(menu.items) do
		if item.active then return index end
	end
end

---@param pos? number
---@param menu_id? string
function Menu:set_scroll_to(pos, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	menu.scroll_y = clamp(0, pos or 0, menu.scroll_height)
	request_render()
end

---@param delta? number
---@param menu_id? string
function Menu:set_scroll_by(delta, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	self:set_scroll_to(menu.scroll_y + delta, menu_id)
end

---@param pos? number
---@param menu_id? string
---@param fling_options? table
function Menu:scroll_to(pos, menu_id, fling_options)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	menu.fling = {
		y = menu.scroll_y,
		distance = clamp(-menu.scroll_y, pos - menu.scroll_y, menu.scroll_height - menu.scroll_y),
		time = mp.get_time(),
		duration = 0.1,
		easing = ease_out_sext,
	}
	if fling_options then table_assign(menu.fling, fling_options) end
	request_render()
end

---@param delta? number
---@param menu_id? string
---@param fling_options? Fling
function Menu:scroll_by(delta, menu_id, fling_options)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	self:scroll_to((menu.fling and (menu.fling.y + menu.fling.distance) or menu.scroll_y) + delta, menu_id, fling_options)
end

---@param index? integer
---@param menu_id? string
---@param immediate? boolean
function Menu:scroll_to_index(index, menu_id, immediate)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if (index and index >= 1 and index <= #menu.items) then
		local sticky_height = (self.type == 'tsdb-external' and menu.is_root) and self.scroll_step * math.min(3, #menu.items) or 0
		if sticky_height > 0 and index <= 3 then return end
		local position
		if self.type == 'tsdb-external' and menu.is_root then
			local scroll_visible = menu.height - 3 * self.scroll_step
			position = index <= 3 and 0 or round((index - 4) * self.tsdb_result_step -
				(scroll_visible - self.tsdb_result_step) / 2)
		else
			position = round((self.scroll_step * (index - 1)) - ((menu.height + sticky_height - self.scroll_step) / 2))
		end
		if immediate then
			self:set_scroll_to(position, menu_id)
		else
			self:scroll_to(position, menu_id)
		end
	end
end

---@param index? integer
---@param menu_id? string
function Menu:select_index(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	menu.selected_index = (index and index >= 1 and index <= #menu.items) and index or nil
	self:select_action(menu.action_index, menu_id) -- normalize selected action index
	request_render()
end

---@param index? integer
---@param menu_id? string
function Menu:select_action(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local actions = menu.items[menu.selected_index] and menu.items[menu.selected_index].actions or menu.item_actions
	if not index or not actions or type(actions) ~= 'table' or index < 1 or index > #actions then
		menu.action_index = nil
		return
	end
	menu.action_index = index
	request_render()
end

---@param delta? integer
---@param menu_id? string
function Menu:navigate_action(delta, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local actions = menu.items[menu.selected_index] and menu.items[menu.selected_index].actions or menu.item_actions
	if actions and delta ~= 0 then
		-- Circular navigation where zero gets converted to nil
		local index = (menu.action_index or (delta > 0 and 0 or #actions + 1)) + delta
		self:select_action(index <= #actions and index > 0 and (index - 1) % #actions + 1 or nil, menu_id)
	else
		self:select_action(nil, menu_id)
	end
	request_render()
end

function Menu:next_action() self:navigate_action(1) end
function Menu:prev_action() self:navigate_action(-1) end

---@param value? any
---@param menu_id? string
function Menu:select_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:select_index(index)
end

---@param menu_id? string
function Menu:deactivate_items(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	for _, item in ipairs(menu.items) do item.active = false end
	request_render()
end

---@param index? integer
---@param menu_id? string
function Menu:activate_index(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if index and index >= 1 and index <= #menu.items then menu.items[index].active = true end
	request_render()
end

---@param value? any
---@param menu_id? string
function Menu:activate_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:activate_index(index, menu_id)
end

---@param value? any
---@param menu_id? string
function Menu:activate_one_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:activate_index(index, menu_id)
end

---@param id string One of menus in `self.all`.
function Menu:activate_menu(id)
	local menu = self:get_menu(id)
	if menu then
		self.current = menu
		self:update_coordinates()
		self:reset_navigation()
		self:search_ensure_key_bindings()
		local parent = menu.parent_menu
		while parent do
			parent.selected_index = itable_index_of(parent.items, menu)
			self:scroll_to_index(parent.selected_index, parent)
			menu, parent = parent, parent.parent_menu
		end
		request_render()
	end
end

---@param index? integer
---@param menu_id? string
function Menu:delete_index(index, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if (index and index >= 1 and index <= #menu.items) then
		table.remove(menu.items, index)
		self:update_content_dimensions()
		self:scroll_to_index(menu.selected_index, menu_id)
	end
end

---@param value? any
---@param menu_id? string
function Menu:delete_value(value, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local index = itable_find(menu.items, function(item) return item.value == value end)
	self:delete_index(index)
end

---@param id string Menu id.
---@param x number `x` coordinate to slide from.
function Menu:slide_in_menu(id, x)
	local menu = self:get_menu(id)
	if not menu then return end
	self:activate_menu(id)
	self:tween(-(display.width / 2 - menu.width / 2 - x), 0, function(offset) self:set_offset_x(offset) end)
	self.opacity = 1 -- in case tween above canceled fade in animation
end

function Menu:back()
	if not self:is_alive() then return end

	local current = self.current
	local parent = current.parent_menu

	if parent then
		self:slide_in_menu(parent.id, display.width / 2 - current.width / 2 - parent.width / 2 + self.offset_x)
	else
		self.callback({type = 'back'})
	end
end

---@param shortcut? Shortcut
---@param is_pointer? boolean Whether this was called by a pointer.
function Menu:activate_selected_item(shortcut, is_pointer)
	local menu = self.current
	local item = menu.items[menu.selected_index]
	if item then
		-- Is submenu
		if item.items then
			if not self.mouse_nav then
				self:select_index(1, item.id)
			end
			self:activate_menu(item.id)
			self:tween(self.offset_x + menu.width / 2, 0, function(offset) self:set_offset_x(offset) end)
			self.opacity = 1 -- in case tween above canceled fade in animation
		else
			local actions = item.actions or menu.item_actions
			local action = actions and actions[menu.action_index]
			self.callback({
				type = 'activate',
				index = menu.selected_index,
				value = item.value,
				is_pointer = is_pointer == true,
				action = action and action.name,
				keep_open = item.keep_open or menu.keep_open,
				modifiers = shortcut and shortcut.modifiers or nil,
				alt = shortcut and shortcut.alt or false,
				ctrl = shortcut and shortcut.ctrl or false,
				shift = shortcut and shortcut.shift or false,
				menu_id = menu.id,
			})
		end
	end
end

---@param index integer
function Menu:move_selected_item_to(index)
	if self.current.search then return end -- Moving filtered items is an undefined behavior
	local callback = self.current.on_move
	local from, items_count = self.current.selected_index, self.current.items and #self.current.items or 0
	if callback and from and from ~= index and index >= 1 and index <= items_count then
		local event = {type = 'move', from_index = from, to_index = index, menu_id = self.current.id}
		self:command_or_event(callback, {from, index, self.current.id}, event)
		self:select_index(index, self.current.id)
		self:scroll_to_index(index, self.current.id, true)
	end
end

---@param delta number
function Menu:move_selected_item_by(delta)
	local current_index, items_count = self.current.selected_index, self.current.items and #self.current.items or 0
	if current_index and items_count > 1 then
		local new_index = clamp(1, current_index + delta, items_count)
		if current_index ~= new_index then
			self:move_selected_item_to(new_index)
		end
	end
end

function Menu:on_display() self:update_dimensions() end
function Menu:on_prop_fullormaxed() self:update_content_dimensions() end
function Menu:on_options() self:update_content_dimensions() end

function Menu:handle_cursor_down()
	if self.type == 'tsdb-external' and self.current.tsdb_dropdown then
		self.tsdb_ignore_mouse_up = true
		self.drag_last_y = nil
		self.is_dragging = false
		if not self.tsdb_popup_rect or
			get_point_to_rectangle_proximity(cursor, self.tsdb_popup_rect) > 0 then
			mp.command_native(self.current.tsdb_dropdown.close)
		end
		return
	end
	if self.proximity_raw <= 0 then
		self.drag_last_y = cursor.y
		self.current.fling = nil
	else
		self:close()
	end
end

---@param shortcut? Shortcut
function Menu:handle_cursor_up(shortcut)
	if self.tsdb_ignore_mouse_up then
		self.tsdb_ignore_mouse_up = false
		self.drag_last_y = nil
		self.is_dragging = false
		return
	end
	if self.tsdb_thumb_drag then
		self.tsdb_thumb_drag = nil
		self.drag_last_y = nil
		self.is_dragging = false
		request_render()
		return
	end
	if self.proximity_raw <= -self.padding and self.drag_last_y and not self.is_dragging
	and self.mouse_hovered_index == self.current.selected_index then
		self:activate_selected_item(shortcut, true)
	end
	if self.is_dragging then
		local distance = cursor:get_velocity().y / -3
		if math.abs(distance) > 50 then
			self.current.fling = {
				y = self.current.scroll_y,
				distance = distance,
				time = cursor.history:head().time,
				easing = ease_out_quart,
				duration = 0.5,
				update_cursor = true,
			}
			request_render()
		end
	end
	self.is_dragging = false
	self.drag_last_y = nil
end

function Menu:on_global_mouse_move()
	self.mouse_nav = true
	if self.current.tsdb_dropdown and self.tsdb_popup_rect and
		get_point_to_rectangle_proximity(cursor, self.tsdb_popup_rect) <= 0 then
		self.drag_last_y = nil
		request_render()
		return
	end
	if self.tsdb_thumb_drag then
		local drag = self.tsdb_thumb_drag
		self:set_scroll_to(drag.start_scroll + (cursor.y - drag.start_y) * drag.ratio, drag.menu_id)
		request_render()
		return
	end
	if self.drag_last_y then
		self.is_dragging = self.is_dragging or math.abs(cursor.y - self.drag_last_y) >= 10
		if self.is_dragging then
			local distance = self.drag_last_y - cursor.y
			if distance ~= 0 then self:set_scroll_by(distance) end
			self.drag_last_y = cursor.y
		end
	end
	request_render()
end

function Menu:handle_wheel_up()
	local dd = self.current.tsdb_dropdown
	if dd and self.tsdb_popup_rect and get_point_to_rectangle_proximity(cursor, self.tsdb_popup_rect) <= 0 then
		self.tsdb_dropdown_scroll = clamp(0, (self.tsdb_dropdown_scroll or 0) - 1,
			math.max(0, #(dd.items or {}) - 5))
		request_render()
		return
	end
	self:scroll_by(self.scroll_step * -3, nil, {update_cursor = true})
end
function Menu:handle_wheel_down()
	local dd = self.current.tsdb_dropdown
	if dd and self.tsdb_popup_rect and get_point_to_rectangle_proximity(cursor, self.tsdb_popup_rect) <= 0 then
		self.tsdb_dropdown_scroll = clamp(0, (self.tsdb_dropdown_scroll or 0) + 1,
			math.max(0, #(dd.items or {}) - 5))
		request_render()
		return
	end
	self:scroll_by(self.scroll_step * 3, nil, {update_cursor = true})
end

---@param offset integer
---@param menu? MenuStack
function Menu:select_by_offset(offset, menu)
	menu = menu or self.current

	-- Blur selected_index when navigating off bounds and submittable search is active.
	-- Blurred selected_index is an implied focused input, so enter can submit it.
	if menu.search and menu.search_debounce == 'submit' and (
			(menu.selected_index == 1 and offset < 0) or (menu.selected_index == #menu.items and offset > 0)
		) then
		self:select_index(nil, menu.id)
	else
		local index = clamp(1, (menu.selected_index or offset >= 0 and 0 or #menu.items + 1) + offset, #menu.items)
		local prev_index = itable_find(menu.items, function(item) return item.selectable ~= false end, index, 1)
		local next_index = itable_find(menu.items, function(item) return item.selectable ~= false end, index)
		if prev_index and next_index then
			if offset == 0 then
				self:select_index(index - prev_index <= next_index - index and prev_index or next_index, menu.id)
			elseif offset > 0 then
				self:select_index(next_index, menu.id)
			else
				self:select_index(prev_index, menu.id)
			end
		else
			self:select_index(prev_index or next_index or nil, menu.id)
		end
	end

	request_render()
end

---@param offset integer
---@param immediate? boolean
function Menu:navigate_by_items(offset, immediate)
	self:select_by_offset(offset)
	if self.current.selected_index then
		self:scroll_to_index(self.current.selected_index, self.current.id, immediate)
	end
end

---@param offset integer
---@param immediate? boolean
function Menu:navigate_by_page(offset, immediate)
	local items_per_page = round((self.current.height / self.scroll_step) * 0.4)
	self:navigate_by_items(items_per_page * offset, immediate)
end

function Menu:paste()
	local menu = self.current
	local payload = get_clipboard()
	if not payload then return end
	if menu.search then
		self:search_query_insert(payload)
	elseif menu.on_paste then
		local selected_item = menu.items and menu.selected_index and menu.items[menu.selected_index]
		local actions = selected_item and selected_item.actions or menu.item_actions
		local selected_action = actions and menu.action_index and actions[menu.action_index]
		self:command_or_event(menu.on_paste, {payload, menu.id}, {
			type = 'paste',
			value = payload,
			menu_id = menu.id,
			selected_item = selected_item and {
				index = menu.selected_index, value = selected_item.value, action = selected_action,
			},
		})
	elseif menu.search_style ~= 'disabled' then
		self:search_start(menu.id)
		self:search_query_replace(payload, menu.id)
	end
end

---@param menu_id string
---@param no_select_first? boolean
function Menu:search_internal(menu_id, no_select_first)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	local query = menu.search.query:lower()
	if query == '' then
		-- Reset menu state to what it was before search
		for key, value in pairs(menu.search.source) do menu[key] = value end
	else
		-- Inherit `search_submenus` from parent menus
		local search_submenus, parent_menu = menu.search_submenus, menu.parent_menu
		while not search_submenus and parent_menu do
			search_submenus, parent_menu = parent_menu.search_submenus, parent_menu.parent_menu
		end
		menu.items = search_items(menu.search.source.items, query, search_submenus)
		-- Select 1st item in search results
		if not no_select_first then
			menu.scroll_y = 0
			self:select_index(1, menu_id)
		end
	end
	self:update_content_dimensions()
end

---@param items MenuStackChild[]
---@param query string
---@param recursive? boolean
---@param prefix? string
---@return MenuStackChild[]
function search_items(items, query, recursive, prefix)
	local result = {}
	local haystacks = {}
	local flat_items = {}
	local concat = table.concat
	local romanization = need_romanization()

	for _, item in ipairs(items) do
		if item.selectable ~= false then
			local prefixed_title = prefix and prefix .. ' / ' .. (item.title or '') or item.title
			haystacks[#haystacks + 1] = item.title
			flat_items[#flat_items + 1] = item

			if item.items and recursive then
				itable_append(result, search_items(item.items, query, recursive, prefixed_title))
			end
		end
	end

	local seen = {}

	local fuzzy = fzy.filter(query, haystacks, false)
	for _, match in ipairs(fuzzy) do
		local idx, positions, score = match[1], match[2], match[3]
		local matched_title = haystacks[idx]
		local item = flat_items[idx]
		local prefixed_title = prefix and prefix .. ' / ' .. (item.title or '') or item.title

		if item.selectable ~= false and not (item.items and recursive) and not seen[item] then
			local bold = item.bold or options.font_bold
			local font_color = item.active and fgt or bgt
			local ass_safe_title = highlight_match(matched_title, positions, font_color, bold) or nil
			local new_item = table_assign({}, item)
			new_item.title = prefixed_title
			new_item.ass_safe_title = prefix and prefix .. ' / ' .. (ass_safe_title or '') or ass_safe_title
			new_item.score = score
			result[#result + 1] = new_item
			seen[item] = true
		end
	end

	for _, item in ipairs(items) do
		local title = item.title and item.title:lower()
		local hint = item.hint and item.hint:lower()
		local bold = item.bold or options.font_bold
		local font_color = item.active and fgt or bgt
		local ass_safe_title = nil
		local prefixed_title = prefix and prefix .. ' / ' .. (item.title or '') or item.title
		if item.selectable ~= false and not (item.items and recursive) and not seen[item] then
			local score = 0
			local match = false

			if title and romanization then
				local ligature_conv_title, ligature_roman = char_conv(title, true)
				local initials_arr_conv, initials_roman = char_conv(title, false)
				local initials_conv_title = concat(initials(initials_arr_conv))
				if ligature_conv_title:find(query, 1, true) then
					match = true
					score = 1000
					local pos = get_roman_match_positions(title, query, 'ligature', ligature_roman)
					if pos then
						ass_safe_title = highlight_match(item.title, pos, font_color, bold)
					end
				elseif initials_conv_title:find(query, 1, true) then
					match = true
					score = 900
					local pos = get_roman_match_positions(title, query, 'initial', initials_roman)
					if pos then
						ass_safe_title = highlight_match(item.title, pos, font_color, bold)
					end
				end
			end

			if hint and not match then
				if hint:find(query, 1, true) then
					match = true
					score = 100
				elseif concat(initials(hint)):find(query, 1, true) then
					match = true
					score = 90
				end
			end

			if match then
				local new_item = table_assign({}, item)
				new_item.title = prefixed_title
				new_item.ass_safe_title = prefix and prefix .. ' / ' .. (ass_safe_title or '') or ass_safe_title
				new_item.score = score
				result[#result + 1] = new_item
			end
		end
	end

	table.sort(result, function(a, b) return a.score > b.score end)

	return result
end

---@param menu_id? string
function Menu:search_submit(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	local callback, query = menu.on_search, menu.search.query
	if callback then
		self:command_or_event(callback, {query, menu.id}, {type = 'search', query = query, menu_id = menu.id})
	else
		self:search_internal(menu.id)
	end
end

-- Move search query cursor by an amount.
---@param amount number `<0` for left, `>0` for right.
---@param word_mode? boolean Move by words/segments. Overwrites amount, but respects its direction.
function Menu:search_cursor_move(amount, word_mode)
	local menu = self:get_menu()
	if not menu or not menu.search then return end
	local query, cursor = menu.search.query, menu.search.cursor
	if word_mode then
		menu.search.cursor = find_string_segment_bound(query, cursor, amount) + (amount < 0 and -1 or 0)
	else
		local move = amount > 0 and utf8_next or utf8_prev
		local step_count = 0
		local limit = math.abs(amount)

		while step_count < limit do
			local next_cursor = move(query, cursor)
			if next_cursor == cursor then break end
			cursor = next_cursor
			step_count = step_count + 1
		end

		menu.search.cursor = clamp(0, cursor, #query)
	end
	request_render()
end

---@param query string
---@param menu_id? string
---@param immediate? boolean
function Menu:search_query_replace(query, menu_id, immediate)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	menu.search.query = query
	menu.search.cursor = #query
	self:search_trigger(menu_id, immediate)
end

-- Insert string into search query at cursor.
---@param str string
---@param menu_id? string
function Menu:search_query_insert(str, menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	local query, cursor = menu.search.query, menu.search.cursor
	local head, tail = string.sub(query, 1, cursor), string.sub(query, cursor + 1)
	menu.search.query = head .. str .. tail
	menu.search.cursor = cursor + #str
	self:search_trigger(menu_id)
end

-- Trigger menu search callbacks, should be called after any query changes.
function Menu:search_trigger(menu_id, immediate)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search then return end
	if menu.search_debounce ~= 'submit' then
		if menu.search.timeout then menu.search.timeout:kill() end
		if menu.search.timeout and not immediate then
			menu.search.timeout:resume()
		else
			self:search_submit(menu_id)
		end
	else
		-- `search_debounce='submit'` behavior: We blur selected item when query
		-- changes to let [enter] key submit searches instead of activating items.
		self:select_index(nil, menu.id)
	end
	request_render()
end

---@param event? string
---@param word_mode? boolean Delete by words.
function Menu:search_query_backspace(event, word_mode)
	local search = self.current.search
	if not search then return end

	local cursor, old_query = search.cursor, search.query
	local head, tail = string.sub(old_query, 1, cursor), string.sub(old_query, cursor + 1)

	if word_mode then
		cursor = find_string_segment_bound(head, cursor, -1) - 1
	elseif cursor > 0 then
		-- The while loop is for skipping utf8 continuation bytes
		while cursor > 1 and old_query:byte(cursor) >= 0x80 and old_query:byte(cursor) <= 0xbf do
			cursor = cursor - 1
		end
		cursor = cursor - 1
	end

	local new_query = head:sub(1, cursor) .. tail
	if new_query ~= old_query then
		search.query = new_query
		search.cursor = math.max(0, cursor)
		self:search_trigger()
	end

	if #new_query == 0 then
		local is_palette = self.current.search_style == 'palette'
		if not is_palette and self.type_to_search then
			self:search_cancel()
		elseif is_palette and event ~= 'repeat' then
			self:back()
		end
	end
end

---@param event? string
---@param word_mode? boolean Delete by words.
function Menu:search_query_delete(event, word_mode)
	local search = self.current.search
	if not search then return end

	local cursor, old_query = search.cursor, search.query
	local head, tail = string.sub(old_query, 1, cursor), string.sub(old_query, cursor + 1)
	local tail_cursor = 1

	if word_mode then
		tail_cursor = find_string_segment_bound(tail, 0, 1) + 1
	else
		-- The while loop is for skipping utf8 continuation bytes
		while tail_cursor < #tail and tail:byte(tail_cursor) >= 0x80 and tail:byte(tail_cursor) <= 0xbf do
			tail_cursor = tail_cursor + 1
		end
		tail_cursor = tail_cursor + 1
	end

	local new_query = head .. tail:sub(tail_cursor)
	if new_query ~= old_query then
		search.query = new_query
		search.cursor = #head
		self:search_trigger()
	end

	if #new_query == 0 then
		local is_palette = self.current.search_style == 'palette'
		if not is_palette and self.type_to_search then
			self:search_cancel()
		elseif is_palette and event ~= 'repeat' then
			self:back()
		end
	end
end

function Menu:search_text_input(info)
	local menu = self.current
	if not menu.search and menu.search_style == 'disabled' then return end
	if info.event ~= 'up' then
		local key_text = info.key_text
		if not key_text then
			-- might be KP0 to KP9 or KP_DEC
			key_text = info.key_name:match('KP_?(.+)')
			if not key_text then return end
			if key_text == 'DEC' then key_text = '.' end
		end
		if not menu.search then self:search_start() end
		self:search_query_insert(key_text)
	end
end

---@param menu_id? string
function Menu:search_cancel(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or not menu.search or menu.search_style == 'palette' then
		self:search_query_replace('', menu_id)
		return
	end
	if state.ime_active == false then
		mp.set_property_bool('input-ime', false)
	end
	self:search_query_replace('', menu_id, true)
	menu.search = nil
	self:search_ensure_key_bindings()
	self:update_dimensions()
	self:reset_navigation()
end

---@param menu_id? string
function Menu:search_init(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if menu.search then return end
	if state.ime_active == false then
		mp.set_property_bool('input-ime', true)
	end
	local timeout
	if menu.search_debounce ~= 'submit' and menu.search_debounce > 0 then
		timeout = mp.add_timeout(menu.search_debounce / 1000, self:create_action(function()
			self:search_submit(menu.id)
		end))
		timeout:kill()
	end
	menu.search = {
		query = '',
		cursor = 0,
		timeout = timeout,
		min_top = menu.top,
		max_width = menu.width,
		source = {
			width = menu.width,
			top = menu.top,
			scroll_y = menu.scroll_y,
			selected_index = menu.selected_index,
			items = not menu.on_search and menu.items or nil,
		},
	}
end

---@param menu_id? string
function Menu:search_start(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu or menu.search_style == 'disabled' then return end
	self:search_init(menu_id)
	self:search_ensure_key_bindings()
	self:update_dimensions()
end

---@param menu_id? string
function Menu:search_clear_query(menu_id)
	local menu = self:get_menu(menu_id)
	if not menu then return end
	if not self.current.search_style == 'palette' and self.type_to_search then
		self:search_cancel(menu_id)
	else
		self:search_query_replace('', menu_id)
	end
end

function Menu:search_enable_key_bindings()
	if self:has_keybindings('search') then return end
	local flags = {repeatable = true, complex = true}
	self:add_key_binding('any_unicode', {self:create_key_handler('search_text_input'), flags}, 'search')
	-- KP0 to KP9 and KP_DEC are not included in any_unicode
	-- despite typically producing characters, they don't have a info.key_text
	self:add_key_binding('kp_dec', {self:create_key_handler('search_text_input'), flags}, 'search')
	for i = 0, 9 do
		self:add_key_binding('kp' .. i, {self:create_key_handler('search_text_input'), flags}, 'search')
	end
end

function Menu:search_ensure_key_bindings()
	if self.current.search or (self.type_to_search and self.current.search_style ~= 'disabled') then
		self:search_enable_key_bindings()
	else
		self:remove_key_bindings('search')
	end
end

function Menu:enable_key_bindings()
	local standalone_keys = {'/', 'kp_divide', 'mbtn_back', 'ctrl+f', 'ctrl+v', 'ctrl+c'}
	if type(self.root.bind_keys) == 'table' then itable_append(standalone_keys, self.root.bind_keys) end
	-- `+` at the end enables `repeatable` flag
	local modifiable_keys = {'up+', 'down+', 'left', 'right', 'enter', 'kp_enter', 'bs', 'tab', 'esc', 'pgup+',
		'pgdwn+', 'home', 'end', 'del'}
	local modifiers = {nil, 'alt', 'alt+ctrl', 'alt+shift', 'alt+ctrl+shift', 'ctrl', 'ctrl+shift', 'shift'}

	---@param shortcut Shortcut
	---@param flags table<string, boolean>
	local function bind(shortcut, flags)
		local handler = self:create_action(function(info) self:handle_shortcut(shortcut, info) end)
		self:add_key_binding(shortcut.id, {handler, flags})
	end

	for i, key in ipairs(standalone_keys) do
		bind(create_shortcut(key), {repeatable = false, complex = true})
	end

	for i, key in ipairs(modifiable_keys) do
		local flags = {repeatable = false, complex = true}

		if key:sub(-1) == '+' then
			key = key:sub(1, -2)
			flags.repeatable = true
		end

		for j = 1, #modifiers do
			bind(create_shortcut(key, modifiers[j]), flags)
		end
	end

	self:search_ensure_key_bindings()
end

-- Handles all key and mouse button shortcuts, except unicode inputs.
---@param shortcut Shortcut
---@param info ComplexBindingInfo
function Menu:handle_shortcut(shortcut, info)
	if not self:is_alive() then return end

	self.mouse_nav = info.is_mouse
	local menu, id, key, modifiers = self.current, shortcut.id, shortcut.key, shortcut.modifiers
	local selected_index = menu.selected_index
	local selected_item = menu and selected_index and menu.items[selected_index]
	local is_submenu = selected_item and selected_item.items ~= nil
	local actions = selected_item and selected_item.actions or menu.item_actions
	local selected_action = actions and menu.action_index and actions[menu.action_index]

	if info.event == 'up' then return end

	function trigger_shortcut(shortcut)
		self.callback(table_assign({}, shortcut, {
			type = 'key',
			menu_id = menu.id,
			selected_item = selected_item and {
				index = selected_index, value = selected_item.value, action = selected_action,
			},
		}))
	end

	if (key == 'enter' and selected_item) or (id == 'right' and is_submenu and not menu.search) then
		self:activate_selected_item(shortcut)
	elseif id == 'enter' and menu.search and menu.search_debounce == 'submit' then
		self:search_submit()
	elseif id == 'up' or id == 'down' then
		self:navigate_by_items(id == 'up' and -1 or 1, true)
	elseif id == 'pgup' or id == 'pgdwn' then
		self:navigate_by_page(id == 'pgup' and -1 or 1)
	elseif menu.search and (id == 'left' or id == 'ctrl+left') then
		self:search_cursor_move(-1, modifiers == 'ctrl')
	elseif menu.search and (id == 'right' or id == 'ctrl+right') then
		self:search_cursor_move(1, modifiers == 'ctrl')
	elseif menu.search and id == 'home' then
		self:search_cursor_move(-math.huge)
	elseif menu.search and id == 'end' then
		self:search_cursor_move(math.huge)
	elseif id == 'home' or id == 'end' then
		self:navigate_by_items(id == 'home' and -math.huge or math.huge)
	elseif id == 'shift+tab' then
		self:prev_action()
	elseif id == 'tab' then
		self:next_action()
	elseif id == 'ctrl+up' then
		self:move_selected_item_by(-1)
	elseif id == 'ctrl+down' then
		self:move_selected_item_by(1)
	elseif id == 'ctrl+pgup' then
		self:move_selected_item_by(-round((menu.height / self.scroll_step) * 0.4))
	elseif id == 'ctrl+pgdwn' then
		self:move_selected_item_by(round((menu.height / self.scroll_step) * 0.4))
	elseif id == 'ctrl+home' then
		self:move_selected_item_by(-math.huge)
	elseif id == 'ctrl+end' then
		self:move_selected_item_by(math.huge)
	elseif id == '/' or id == 'kp_divide' or id == 'ctrl+f' then
		self:search_start()
	elseif key == 'esc' then
		if menu.search and menu.search_style ~= 'palette' then
			self:search_cancel()
		else
			self:close()
		end
	elseif id == 'left' and menu.parent_menu then
		self:back()
	elseif key == 'bs' then
		if menu.search then
			if modifiers == 'shift' then
				self:search_clear_query()
			elseif not modifiers or modifiers == 'ctrl' then
				self:search_query_backspace(info.event, modifiers == 'ctrl')
			end
		elseif not modifiers and info.event ~= 'repeat' then
			self:back()
		end
	elseif menu.search and (id == 'del' or id == 'ctrl+del' or id == 'shift+del') then
		if id == 'shift+del' then
			-- During search `del` edits the string. We convert `shift+del` to
			-- `del` to have a way to trigger menu callbacks bound to `del`.
			trigger_shortcut(create_shortcut('del'))
		else
			self:search_query_delete(info.event, modifiers == 'ctrl')
		end
	elseif key == 'mbtn_back' then
		self:back()
	elseif id == 'ctrl+v' then
		self:paste()
	else
		trigger_shortcut(shortcut)
	end
end

-- Check if menu is not closed or closing.
function Menu:is_alive() return not self.is_closing and not self.destroyed end

---@param name string
function Menu:create_key_handler(name)
	return self:create_action(function(...)
		self.mouse_nav = false
		self:maybe(name, ...)
	end)
end

-- Sends command with params, or triggers a callback event if `command == 'callback'`.
-- Intended to handle `on_{event}: 'callback' | string | string[]` events.
-- Returns what happened.
---@param command string|number|string[]|number[]
---@param params string[]|number[]
---@param event MenuEvent
---@return 'event' | 'command' | nil
function Menu:command_or_event(command, params, event)
	if command == 'callback' then
		self.callback(event)
		return 'event'
	elseif type(command) == 'table' then
		---@diagnostic disable-next-line: deprecated
		mp.command_native(itable_join(command, params))
		return 'command'
	elseif type(command) == 'string' then
		mp.command(command .. ' ' .. table.concat(params, ' '))
		return 'command'
	end
	return nil
end

-- TSDB 0.3.17: measure text in the currently used font, not by character count.
-- UTF-8 boundaries avoid breaking accented letters when shortening a filename.
local function tsdb_utf8_endpoints(s)
	local offsets = {0}
	for i = 2, #s do
		local b = s:byte(i)
		if b < 128 or b >= 192 then offsets[#offsets + 1] = i - 1 end
	end
	if #s > 0 then offsets[#offsets + 1] = #s end
	return offsets
end

local function tsdb_fit_prefix(s, available, size)
	if available <= 0 then return '', s ~= '' end
	local opts = {size = size, bold = false, italic = false}
	if text_width(s, opts) <= available then return s, false end
	local dots = '…'
	local target = math.max(0, available - text_width(dots, opts) - 3)
	local offsets = tsdb_utf8_endpoints(s)
	local lo, hi, best = 1, #offsets, 0
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local n = offsets[mid]
		if text_width(s:sub(1, n), opts) <= target then
			best = n; lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return s:sub(1, best) .. dots, true
end

-- Retain the beginning AND ending of unusually long release names.
-- Both halves are cut only at UTF-8 boundaries; never return bare dots.
local function tsdb_fit_middle(s, available, size)
	local opts = {size = size, bold = false, italic = false}
	if text_width(s, opts) <= available then return s, false end
	local offsets = tsdb_utf8_endpoints(s)
	local count = #offsets - 1
	local best = '…'
	local lo, hi = 0, count
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local left_n = math.ceil(mid * 0.60)
		local right_n = mid - left_n
		local prefix = s:sub(1, offsets[left_n + 1])
		local suffix = right_n > 0 and s:sub(offsets[count - right_n + 1] + 1) or ''
		local candidate = prefix .. '…' .. suffix
		if text_width(candidate, opts) <= available then
			best = candidate
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return best, true
end

function Menu:render()
	for _, menu in ipairs(self.all) do
		if menu.fling then
			local time_delta = state.render_last_time - menu.fling.time
			local progress = menu.fling.easing(math.min(time_delta / menu.fling.duration, 1))
			self:set_scroll_to(round(menu.fling.y + menu.fling.distance * progress), menu.id)
			if progress < 1 then request_render() else menu.fling = nil end
		end
	end

	cursor:zone('primary_down', display, self:create_action(function() self:handle_cursor_down() end))
	cursor:zone('primary_up', display, self:create_action(function(shortcut) self:handle_cursor_up(shortcut) end))
	cursor:zone('wheel_down', self, function() self:handle_wheel_down() end)
	cursor:zone('wheel_up', self, function() self:handle_wheel_up() end)

	local ass = assdraw.ass_new()
	self.tsdb_popup_rect = nil
	local icon_size = self.font_size
	self.tsdb_hover_candidate = nil

	-- Display only metadata inferable from a subtitle release name. No invented dates.
	local function tsdb_release_metadata(title)
		local out, seen = {}, {}
		local function add(s)
			if s and not seen[s] then out[#out + 1] = s; seen[s] = true end
		end
		local year = title:match('[( ](20%d%d)[) .]') or title:match('[( ](19%d%d)[) .]')
		add(year)
		add(title:match('[^%d](2160[pP])') or title:match('[^%d](1080[pP])') or title:match('[^%d](720[pP])'))
		local upper = title:upper()
		for _, word in ipairs({'BLURAY','WEB-DL','WEBRIP','REMUX','HDR','HEVC','X265','X264'}) do
			if upper:find(word, 1, true) then add(word == 'BLURAY' and 'BluRay' or word) end
		end
		return table.concat(out, '  ·  ')
	end

	---@param menu MenuStack
	---@param x number
	---@param pos number Horizontal position index. 0 = current menu, <0 parent menus, >1 submenu.
	local function draw_menu(menu, x, pos)
		local is_current, is_parent, is_submenu = pos == 0, pos < 0, pos > 0
		local tsdb_root = self.type == 'tsdb-external' and menu.is_root
		local menu_opacity = (pos == 0 and 1 or config.opacity.submenu ^ math.abs(pos)) * self.opacity
		-- Scrollable content area coordinates
		local content_rect = {
			ax = x + self.padding,
			ay = menu.top,
			bx = x + self.padding + menu.width,
			by = menu.top + menu.height,
		}
		-- local ax, ay, bx, by = x + self.padding, menu.top, x + menu.width + self.padding, menu.top + menu.height
		local draw_title = menu.is_root and menu.title or menu.search
		local sticky_count = (self.type == 'tsdb-external' and menu.is_root) and math.min(3, #menu.items) or 0
		local sticky_height = sticky_count * self.scroll_step
		local list_top = math.min(content_rect.by, content_rect.ay + sticky_height)
		local scroll_clip = '\\clip(0,' .. content_rect.ay .. ',' .. display.width .. ',' .. content_rect.by .. ')'
		local start_index, end_index
		if tsdb_root then
			start_index = math.max(4, 4 + math.floor(menu.scroll_y / self.tsdb_result_step))
			end_index = math.min(#menu.items, 3 + math.ceil((menu.scroll_y + menu.height - sticky_height) / self.tsdb_result_step))
		else
			start_index = math.max(sticky_count + 1,
				math.floor((menu.scroll_y + sticky_height) / self.scroll_step) + 1)
			end_index = math.min(#menu.items, math.ceil((menu.scroll_y + menu.height) / self.scroll_step))
		end
		local bg_rect = {
			ax = x,
			ay = content_rect.ay - (draw_title and self.scroll_step or 0) - self.padding,
			bx = content_rect.bx + self.padding,
			by = content_rect.by + self.padding,
		}
		local blur_action_index = self.mouse_nav and menu.action_index ~= nil

		-- Background
		ass:rect(bg_rect.ax, bg_rect.ay, bg_rect.bx, bg_rect.by, {
			color = tsdb_root and '37261A' or bg,
			opacity = menu_opacity * (tsdb_root and 0.94 or config.opacity.menu),
			radius = tsdb_root and 14 * state.scale or
				(state.radius > 0 and math.min(state.radius + self.padding, state.radius * 3) or 0),
		})

		if is_parent then
			cursor:zone('primary_down', bg_rect, self:create_action(function() self:slide_in_menu(menu.id, x) end))
		end

		-- Scrollbar original: los demás menus de uosc permanecen intactos
		if menu.scroll_height > 0 and not (self.type == 'tsdb-external' and menu.is_root) then
			local groove_height = menu.height - 2
			local thumb_height = math.max((menu.height / (menu.scroll_height + menu.height)) * groove_height, 40)
			local thumb_y = content_rect.ay + 1 + ((menu.scroll_y / menu.scroll_height) * (groove_height - thumb_height))
			local sax = content_rect.bx - round(self.scrollbar_size / 2)
			local sbx = sax + self.scrollbar_size
			ass:rect(sax, thumb_y, sbx, thumb_y + thumb_height, {color = fg, opacity = menu_opacity * 0.8})
		end

		-- Draw submenu if selected
		local submenu_rect, current_item = nil, is_current and menu.selected_index and menu.items[menu.selected_index]
		local submenu_is_hovered = false
		if current_item and current_item.items then
			submenu_rect = draw_menu(current_item --[[@as MenuStack]], bg_rect.bx + self.gap, 1)
			cursor:zone('primary_down', submenu_rect, self:create_action(function(shortcut)
				self:activate_selected_item(shortcut, true)
			end))
		end

		---@type MenuAction|nil
		local selected_action
		local render_indices = {}
		for index = start_index, end_index do
			render_indices[#render_indices + 1] = index
		end
		for index = 1, sticky_count do
			render_indices[#render_indices + 1] = index
		end
		for _, index in ipairs(render_indices) do
			local item = menu.items[index]
			if index == 1 and sticky_count > 0 then
				-- La franja de filtros tapa los resultados y nunca se desplaza.
				ass:rect(content_rect.ax, content_rect.ay, content_rect.bx, list_top,
					{color = bg, opacity = menu_opacity * config.opacity.menu})
			end

			if not item then break end

			local is_sticky = index <= sticky_count
			local item_ay = is_sticky and (content_rect.ay + self.scroll_step * (index - 1))
				or (tsdb_root and (list_top - menu.scroll_y + self.tsdb_result_step * (index - 4))
					or (content_rect.ay - menu.scroll_y + self.scroll_step * (index - 1)))
			local min_item_y = is_sticky and content_rect.ay or list_top
			local item_by = item_ay + ((tsdb_root and not is_sticky) and (self.tsdb_result_step - self.item_spacing) or self.item_height)
			local item_center_y = item_ay + (self.item_height / 2)
			local item_clip = (sticky_count > 0 or item_ay < content_rect.ay or item_by > content_rect.by)
				and ('\\clip(0,' .. min_item_y .. ',' .. display.width .. ',' .. content_rect.by .. ')') or nil
			local content_ax, content_bx = content_rect.ax + self.item_padding,
				content_rect.bx - self.item_padding
			local is_selected = menu.selected_index == index
			local item_rect_hitbox = {
				ax = content_rect.ax,
				ay = math.max(item_ay, min_item_y),
				bx = bg_rect.bx + (item.items and self.gap or -self.padding), -- to bridge the submenu gap with cursor
				by = math.min(item_ay + ((tsdb_root and not is_sticky) and self.tsdb_result_step or self.scroll_step), bg_rect.by),
			}

			-- Select hovered item
			if is_current and self.mouse_nav and not self.tsdb_thumb_drag and not menu.tsdb_dropdown
				and item_rect_hitbox.ay < item_rect_hitbox.by
				and (submenu_is_hovered or get_point_to_rectangle_proximity(cursor, item_rect_hitbox) <= 0) then
				self.mouse_hovered_index = index
				-- Do not select items if cursor is moving towards a submenu
				if item.selectable ~= false and (not submenu_rect or not cursor:direction_to_rectangle_distance(submenu_rect)) then
					menu.selected_index = index
					if not is_selected then
						is_selected = true
						request_render()
					end
				end
			end

			if tsdb_root then
				-- Dedicated TSDB card: header controls and two-line result rows.
				local left = content_rect.ax + self.item_padding + 3 * state.scale
				local right = content_rect.bx - self.item_padding - self.scrollbar_size - 4 * state.scale
				local selected_color = '7F6346'
				if is_sticky then
					local top = item_ay + 2 * state.scale
					if index > 1 then
						ass:rect(content_rect.ax + 2 * state.scale, top,
							content_rect.bx - 2 * state.scale, item_by - 2 * state.scale,
							{color = is_selected and selected_color or '503926', radius = 6 * state.scale,
							 opacity = menu_opacity * (is_selected and 0.90 or 0.82)})
					end
					local label_x = left + (index > 1 and 1.45 * self.font_size or 0)
					if index > 1 then
						ass:icon(left + 0.55 * self.font_size, item_center_y, self.font_size * 1.12,
							index == 2 and 'language' or 'filter_list',
							{color = 'ECC496', opacity = menu_opacity, clip = item_clip})
						ass:icon(right - self.font_size * 0.40, item_center_y, self.font_size,
							'chevron_right', {color = 'DBC8B4', opacity = menu_opacity, clip = item_clip})
					end
					local hint_width = math.min(item.hint_width or 0, menu.width * 0.34)
					local title_right = right - hint_width - 2.6 * self.font_size
					local title_clip = ('\\clip(%d,%d,%d,%d)'):format(label_x,math.max(item_ay,min_item_y),math.max(label_x,title_right), math.min(item_by,content_rect.by))
					ass:txt(label_x, item_center_y, 4, ass_escape(item.title or ''), {
						size = index == 1 and self.font_size * 0.88 or self.font_size,
						color = index == 1 and 'CAB8A8' or 'FAF0E7', opacity = menu_opacity,
						clip = title_clip,
					})
					if item.hint then
						ass:txt(right - 1.25 * self.font_size, item_center_y, 6, ass_escape(item.hint), {
							size = self.font_size * 0.90, color = 'E0D2C6', opacity = menu_opacity,
							clip = item_clip,
						})
					end
					if is_selected then
						ass:rect(content_rect.ax + 1 * state.scale, top, content_rect.ax + 4 * state.scale,
							item_by - 2 * state.scale, {color = 'FCD780', opacity = menu_opacity, radius = 2 * state.scale})
					end
				else
					local top = item_ay + 1.5 * state.scale
					local bottom = item_by - 1.5 * state.scale
					local is_option = item.tsdb_option == true or item.selectable == false
					ass:rect(content_rect.ax + 2 * state.scale, top, content_rect.bx - self.scrollbar_size - 3 * state.scale,
						bottom, {color = is_selected and '715336' or '463120',
							radius = 5 * state.scale, opacity = menu_opacity * (is_selected and 0.92 or 0.79), clip = item_clip})
					if is_selected then
						ass:rect(content_rect.ax + 2 * state.scale, top, content_rect.ax + 5 * state.scale,
							bottom, {color = 'F7CC6C', opacity = menu_opacity, clip = item_clip})
					end
					local name_left = left + 1.65 * self.font_size
					local right_hint = right - 2.3 * self.font_size
					local top_y = item_ay + self.tsdb_result_step * 0.34
					local lower_y = item_ay + self.tsdb_result_step * 0.72
					ass:icon(left + 0.6 * self.font_size, item_ay + self.tsdb_result_step * 0.51,
						self.font_size * 1.30, is_option and 'language' or 'description',
						{color = 'FFCA84', opacity = menu_opacity, clip = item_clip})
					if not is_option then
					ass:icon(right - 0.65 * self.font_size, item_ay + self.tsdb_result_step * 0.51,
						self.font_size * 1.22, 'file_download',
						{color = 'FBECDC', opacity = menu_opacity, clip = item_clip})
					end
					local hint_raw = item.hint or ''
					local info, fps = hint_raw:match('^(.-)%s*·%s*([%d%.]+%s+fps)')
					info = info or hint_raw
					local meta = not is_option and tsdb_release_metadata(item.title or '') or ''
					local text_right = right_hint - math.max(self.font_size*3.0, math.min(item.hint_width or 0,menu.width*0.18))
					local main_clip = ('\\clip(%d,%d,%d,%d)'):format(name_left,math.max(item_ay,min_item_y),math.max(name_left,text_right),math.min(item_by,content_rect.by))
					local original_name = item.title or ''
					local name_room = math.max(0, text_right - name_left - 6 * state.scale)
					local shown_name, is_elided = tsdb_fit_middle(original_name, name_room, self.font_size)
					ass:txt(name_left, top_y, 4, ass_escape(shown_name), {
						size = self.font_size, color = 'FCF5EE', opacity = menu_opacity, clip = main_clip,
					})
					if is_current and is_elided and not is_option and not menu.tsdb_dropdown and not self.is_dragging and not self.tsdb_thumb_drag then
						local hover_rect = {
							ax = content_rect.ax + 2 * state.scale, ay = math.max(item_ay, min_item_y),
							bx = content_rect.bx - self.scrollbar_size - 3 * state.scale,
							by = math.min(item_by, content_rect.by),
						}
						if hover_rect.ay < hover_rect.by
							and get_point_to_rectangle_proximity(cursor, hover_rect) <= 0 then
							self.tsdb_hover_candidate = {
								key = tostring(index) .. ':' .. original_name,
								name = original_name, x = name_left,
								top = item_ay, bottom = item_by,
								panel_left = content_rect.ax, panel_right = content_rect.bx,
							}
						end
					end
					if meta ~= '' then
						ass:txt(name_left, lower_y, 4, ass_escape(meta), {
							size = self.font_size * 0.79, color = 'C9B6A6', opacity = menu_opacity, clip = main_clip,
						})
					end
					local info_clip = ('\\clip(%d,%d,%d,%d)'):format(text_right+5,math.max(item_ay,min_item_y),right_hint+4,math.min(item_by,content_rect.by))
					ass:txt(right_hint, top_y, 6, ass_escape(info), {
						size = self.font_size * 0.87, color = 'F2E4D5', opacity = menu_opacity, clip = info_clip,
					})
					if fps then
						ass:txt(right_hint, lower_y, 6, ass_escape(fps), {
							size = self.font_size * 0.78, color = 'C1AF9F', opacity = menu_opacity, clip = info_clip,
						})
					end
				end
			else
			local has_background = is_selected or item.active
			local next_item = menu.items[index + 1]
			local next_is_active = next_item and next_item.active
			local next_has_background = menu.selected_index == index + 1 or next_is_active
			local font_color = item.active and fgt or bgt
			local actions = is_selected and (item.actions or menu.item_actions) -- not nil = actions are visible
			local action = actions and actions[menu.action_index] -- not nil = action is selected

			if action then selected_action = action end

			-- Separator
			if item_by >= min_item_y and item_by < content_rect.by and ((not has_background and not next_has_background) or item.separator) then
				local ay, by = item_by, item_by + self.separator_size
				if has_background then
					ay, by = ay + self.separator_size, by + self.separator_size
				elseif next_has_background then
					ay, by = ay - self.separator_size, by - self.separator_size
				end
				ass:rect(
					content_rect.ax + self.item_padding, ay, content_rect.bx - self.item_padding, by,
					{color = fg, opacity = menu_opacity * (item.separator and 0.13 or 0.04)}
				)
			end

			-- Background
			local highlight_opacity = 0 + (item.active and 0.8 or 0) + (is_selected and 0.15 or 0)
			if highlight_opacity > 0 then
				ass:rect(content_rect.ax, item_ay, content_rect.bx, item_by, {
					radius = state.radius,
					color = fg,
					opacity = highlight_opacity * menu_opacity,
					clip = item_clip,
				})
			end

			local title_clip_bx = content_bx

			-- Actions
			local actions_rect
			if is_selected and actions and #actions > 0 and not item.items then
				local place = item.actions_place or menu.item_actions_place
				local margin = self.gap * 2
				local size = item_by - item_ay - margin * 2
				local rect_width = size * #actions + margin * (#actions - 1)

				-- Place actions outside of menu when requested and there's enough space for it
				actions_rect = {
					ay = item_ay + margin,
					by = item_by - margin,
					is_outside = place == 'outside' and display.width - bg_rect.bx + margin * 2 > rect_width,
				}
				actions_rect.bx = actions_rect.is_outside and bg_rect.bx + margin + rect_width or
					content_rect.bx - margin
				actions_rect.ax = actions_rect.bx

				for i = 1, #actions, 1 do
					local action_index = #actions - (i - 1)
					local action = actions[action_index]

					-- Hide when the action shouldn't be displayed when the item is a result of a search/filter
					if not (action.filter_hidden and menu.search) then
						local is_active = action_index == menu.action_index
						local bx = actions_rect.ax - (i == 1 and 0 or margin)
						local rect = {
							ay = actions_rect.ay,
							by = actions_rect.by,
							ax = bx - size,
							bx = bx,
						}
						actions_rect.ax = rect.ax

						ass:rect(rect.ax, rect.ay, rect.bx, rect.by, {
							radius = state.radius > 2 and state.radius - 1 or state.radius,
							color = is_active and fg or bg,
							border = is_active and self.gap or nil,
							border_color = bg,
							opacity = menu_opacity,
							clip = item_clip,
						})
						ass:icon(rect.ax + size / 2, rect.ay + size / 2, size * 0.66, action.icon, {
							color = is_active and bg or fg, opacity = menu_opacity, clip = item_clip,
						})

						-- Re-use rect as a hitbox by growing it so it bridges gaps to prevent flickering
						rect.ay, rect.by, rect.bx = item_ay, item_ay + self.scroll_step, rect.bx + margin

						-- Select action on cursor hover
						if self.mouse_nav and get_point_to_rectangle_proximity(cursor, rect) <= 0 then
							cursor:zone('primary_click', rect, self:create_action(function(shortcut)
								self:activate_selected_item(shortcut, true)
							end))
							blur_action_index = false
							if not is_active then
								menu.action_index = action_index
								selected_action = actions[action_index]
								request_render()
							end
						end
					end
				end

				title_clip_bx = actions_rect.ax - self.gap * 2
			end

			-- Selected item indicator line
			if is_selected and not selected_action then
				local size = round(2 * state.scale)
				local v_padding = math.min(state.radius, math.ceil(self.item_height / 3))
				ass:rect(
					content_rect.ax - size - 1, item_ay + v_padding,
					content_rect.ax - 1, item_by - v_padding,
					{radius = 1 * state.scale, color = fg, opacity = menu_opacity, clip = item_clip}
				)
			end

			-- Icon
			if item.icon then
				if not actions_rect or actions_rect.is_outside then
					local x = (not item.title and not item.hint and item.align == 'center')
						and bg_rect.ax + (bg_rect.bx - bg_rect.ax) / 2
						or content_bx - (icon_size / 2)
					if item.icon == 'spinner' then
						ass:spinner(x, item_center_y, icon_size * 1.5, {
							color = font_color, opacity = menu_opacity * 0.8, clip = item_clip,
						})
					else
						ass:icon(x, item_center_y, icon_size * 1.5, item.icon, {
							color = font_color, opacity = menu_opacity, clip = item_clip,
						})
					end
				end
				content_bx = content_bx - icon_size - self.item_padding
				title_clip_bx = math.min(content_bx, title_clip_bx)
			end

			local hint_clip_bx = title_clip_bx
			if item.hint_width > 0 then
				-- controls title & hint clipping proportional to the ratio of their widths
				-- both title and hint get at least 50% of the width, unless they are smaller then that
				local width = content_bx - content_ax - self.item_padding
				local title_min = math.min(item.title_width, width * 0.5)
				local hint_min = math.min(item.hint_width, width * 0.5)
				local title_ratio = item.title_width / (item.title_width + item.hint_width)
				title_clip_bx = math.min(
					title_clip_bx,
					round(content_ax + clamp(title_min, width * title_ratio, width - hint_min))
				)
			end

			-- Hint
			if item.hint then
				item.ass_safe_hint = item.ass_safe_hint or ass_escape(item.hint)
				local clip = '\\clip(' .. title_clip_bx + self.item_padding .. ','
					.. math.max(item_ay, min_item_y) .. ',' .. hint_clip_bx .. ','
					.. math.min(item_by, content_rect.by) .. ')'
				ass:txt(content_bx, item_center_y, 6, item.ass_safe_hint, {
					size = self.font_size_hint,
					color = font_color,
					wrap = 2,
					opacity = 0.5 * menu_opacity,
					clip = clip,
				})
			end

			-- Title
			if item.title then
				item.ass_safe_title = item.ass_safe_title or ass_escape(item.title)
				local clip = '\\clip(' .. content_rect.ax .. ',' .. math.max(item_ay, min_item_y) .. ','
					.. title_clip_bx .. ',' .. math.min(item_by, content_rect.by) .. ')'
				local title_x, align = content_ax, 4
				if item.align == 'right' then
					title_x, align = title_clip_bx, 6
				elseif item.align == 'center' then
					title_x, align = content_ax + (title_clip_bx - content_ax) / 2, 5
				end
				ass:txt(title_x, item_center_y, align, item.ass_safe_title, {
					size = self.font_size,
					color = font_color,
					italic = item.italic,
					bold = item.bold,
					wrap = 2,
					opacity = menu_opacity * (item.muted and 0.5 or 1),
					clip = clip,
				})
			end
			end -- TSDB-specific vs generic item render
		end

		-- Barra de resultados TSDB: pista y tirador arrastrable (solo menu principal).
		if is_current and self.type == 'tsdb-external' and menu.is_root and menu.scroll_height > 0 then
			local groove_height = math.max(1, menu.height - sticky_height - 2)
			local thumb_height = math.min(groove_height, math.max(36 * state.scale,
				(menu.height - sticky_height) / (menu.scroll_height + menu.height - sticky_height) * groove_height))
			local travel = math.max(0, groove_height - thumb_height)
			local thumb_y = list_top + 1 + (travel > 0 and (menu.scroll_y / menu.scroll_height) * travel or 0)
			local sax = content_rect.bx - self.scrollbar_size
			ass:rect(sax, list_top + 1, content_rect.bx, content_rect.by - 1,
				{color = '4F3B28', opacity = menu_opacity * 0.56})
			ass:rect(sax, thumb_y, content_rect.bx, thumb_y + thumb_height,
				{color = 'F6C97A', opacity = menu_opacity * 0.94, radius = state.radius})
			local hitbox = {ax = sax - 5 * state.scale, ay = list_top,
				bx = content_rect.bx + self.padding, by = content_rect.by}
			cursor:zone('primary_down', hitbox, self:create_action(function()
				menu.fling = nil
				if travel > 0 and (cursor.y < thumb_y or cursor.y > thumb_y + thumb_height) then
					local ratio = clamp(0, (cursor.y - list_top - 1 - thumb_height / 2) / travel, 1)
					self:set_scroll_to(ratio * menu.scroll_height, menu.id)
				end
				self.tsdb_thumb_drag = {
					menu_id = menu.id, start_scroll = menu.scroll_y, start_y = cursor.y,
					ratio = travel > 0 and menu.scroll_height / travel or 0,
				}
				self.drag_last_y = nil
				self.is_dragging = true
				request_render()
			end))
		end

		-- Footnote / Selected action label
		if is_current and not tsdb_root and (menu.footnote or selected_action) then
			local height_half = self.font_size
			local icon_x, icon_y = content_rect.ax + self.font_size / 2, bg_rect.by + height_half
			local is_icon_hovered = false
			local icon_hitbox = {
				ax = icon_x - height_half,
				ay = icon_y - height_half,
				bx = icon_x + height_half,
				by = icon_y + height_half,
			}
			is_icon_hovered = get_point_to_rectangle_proximity(cursor, icon_hitbox) <= 0
			local text = selected_action and selected_action.label or is_icon_hovered and menu.footnote
			local opacity = (is_icon_hovered and 1 or 0.5) * menu_opacity
			ass:icon(icon_x, icon_y, self.font_size, is_icon_hovered and 'help' or 'help_outline', {
				color = fg, border = state.scale, border_color = bg, opacity = opacity,
			})
			if text then
				ass:txt(icon_x + self.font_size * 0.75, icon_y - self.font_size * 0.5, 7, ass_escape(text), {
					size = self.font_size,
					color = fg,
					border = state.scale,
					border_color = bg,
					opacity = menu_opacity,
					italic = true,
				})
			end
		end

		-- Menu title
		if draw_title then
			local requires_submit = menu.search_debounce == 'submit'
			local rect = {
				ax = content_rect.ax,
				ay = content_rect.ay - self.scroll_step - self.separator_size - 1,
				bx = content_rect.bx,
				by = content_rect.ay - self.separator_size - 1,
			}
			-- Centers
			rect.cx, rect.cy = round(rect.ax + (rect.bx - rect.ax) / 2), round(rect.ay + (rect.by - rect.ay) / 2)
			if tsdb_root then
				ass:rect(rect.ax+2*state.scale, rect.ay+2*state.scale,
					rect.bx-2*state.scale, rect.by-2*state.scale,
					{color = '4F3925', opacity = menu_opacity * 0.96, radius=7*state.scale})
			end

			if menu.title and not menu.ass_safe_title then
				menu.ass_safe_title = ass_escape(menu.title)
			end

			-- Separator
			ass:rect(
				rect.ax, rect.by, rect.bx, rect.by + self.separator_size, {color = fg, opacity = menu_opacity * 0.2}
			)

			-- Blur selection (also activates search input) when user clicks title
			if is_current then
				cursor:zone('primary_down', rect, function()
					self:select_index(nil)
				end)
			end

			-- Title
			if menu.search then
				-- Icon
				local icon_size, icon_opacity = self.font_size * 1.3, menu_opacity * (requires_submit and 0.5 or 1)
				local icon_rect = {
					ax = rect.ax,
					ay = rect.ay,
					bx = content_rect.ax + icon_size + self.item_padding * 1.5,
					by = rect.by,
				}

				if is_current and requires_submit then
					cursor:zone('primary_down', icon_rect, function() self:search_submit() end)
					if get_point_to_rectangle_proximity(cursor, icon_rect) <= 0 then
						icon_opacity = menu_opacity
					end
				end

				ass:icon(rect.ax + icon_size / 2, rect.cy, icon_size, 'search', {
					color = fg,
					opacity = icon_opacity,
					clip = '\\clip(' ..
						icon_rect.ax .. ',' .. icon_rect.ay .. ',' .. icon_rect.bx .. ',' .. icon_rect.by .. ')',
				})

				-- Query/Placeholder
				local cursor_height_half, cursor_thickness = round(self.font_size * 0.6), round(self.font_size / 12)
				local cursor_ax = rect.bx + 1
				if menu.search.query ~= '' then
					local opts = {
						size = self.font_size,
						color = bgt,
						wrap = 2,
						opacity = menu_opacity,
						clip = '\\clip(' .. icon_rect.bx .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')',
					}
					local query, cursor = menu.search.query, menu.search.cursor
					-- Add a ZWNBSP suffix to prevent libass from trimming trailing spaces
					local head = ass_escape(string.sub(query, 1, cursor)) .. '\239\187\191'
					local tail_no_escape = string.sub(query, cursor + 1)
					local tail = ass_escape(tail_no_escape) .. '\239\187\191'
					if tsdb_root then
						local input_x = icon_rect.bx + self.item_padding
						ass:txt(input_x, rect.cy, 4, ass_escape(query), opts)
						cursor_ax = round(input_x + text_width(string.sub(query, 1, cursor), opts))
					else
						cursor_ax = math.max(round(cursor_ax - text_width(tail_no_escape, opts)), rect.cx)
						ass:txt(cursor_ax, rect.cy, 6, head, opts)
						ass:txt(cursor_ax, rect.cy, 4, tail, opts)
					end
				else
					local placeholder = (menu.search_style == 'palette' and menu.ass_safe_title)
						and menu.ass_safe_title
						or (requires_submit and t('type & ctrl+enter to search') or t('type to search'))
					ass:txt(tsdb_root and (icon_rect.bx + self.item_padding) or rect.bx,
						rect.cy, tsdb_root and 4 or 6, placeholder, {
						size = self.font_size,
						italic = not tsdb_root,
						color = tsdb_root and 'D3BFAC' or bgt,
						wrap = 2,
						opacity = menu_opacity * (tsdb_root and 0.85 or 0.4),
						clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')',
					})
				end

				-- Selected input indicator for submittable searches.
				-- (input is selected when `selected_index` is `nil`)
				if menu.search_debounce == 'submit' and not menu.selected_index then
					local size_half = round(1 * state.scale)
					ass:rect(
						content_rect.ax, rect.by - size_half, content_rect.bx, rect.by + size_half,
						{color = fg, opacity = menu_opacity}
					)
				end
				local input_is_blurred = menu.search_debounce == 'submit' and menu.selected_index

				-- Cursor
				local cursor_bx = cursor_ax + cursor_thickness
				ass:rect(cursor_ax, rect.cy - cursor_height_half, cursor_bx, rect.cy + cursor_height_half, {
					color = fg,
					opacity = menu_opacity * (input_is_blurred and 0.5 or 1),
					clip = '\\clip(' .. cursor_ax .. ',' .. rect.ay .. ',' .. cursor_bx .. ',' .. rect.by .. ')',
				})
			else
				ass:txt(rect.cx, rect.cy, 5, menu.ass_safe_title, {
					size = self.font_size,
					bold = true,
					color = bgt,
					wrap = 2,
					opacity = menu_opacity,
					clip = '\\clip(' .. rect.ax .. ',' .. rect.ay .. ',' .. rect.bx .. ',' .. rect.by .. ')',
				})
			end
		end

		if blur_action_index then
			menu.action_index = nil
			request_render()
		end

		return bg_rect
	end

	-- Active menu
	draw_menu(self.current, self.ax, 0)

	-- Parent menus
	local parent_menu = self.current.parent_menu
	local parent_offset_x, parent_horizontal_index = self.ax, -1

	while parent_menu do
		parent_offset_x = parent_offset_x - parent_menu.width - self.padding * 2 - self.gap
		draw_menu(parent_menu, parent_offset_x, parent_horizontal_index)
		parent_horizontal_index = parent_horizontal_index - 1
		parent_menu = parent_menu.parent_menu
	end

	-- TSDB 0.3.17: both pickers attach to THEIR OWN header row.
	-- Five items are visible; mouse wheel moves the list by one language.
	local root = self.current
	if self.type == 'tsdb-external' and root.is_root and root.tsdb_dropdown then
		local dd = root.tsdb_dropdown
		local items = dd.items or {}
		if self.tsdb_dropdown_kind ~= dd.kind then
			self.tsdb_dropdown_kind = dd.kind
			self.tsdb_dropdown_scroll = 0
		end
		local scale = state.scale
		local font = self.font_size
		local row_h = math.max(self.scroll_step * 1.06, 30 * scale)
		local pad = 6 * scale
		local visible = math.min(5, #items)
		local max_scroll = math.max(0, #items - visible)
		self.tsdb_dropdown_scroll = clamp(0, self.tsdb_dropdown_scroll or 0, max_scroll)
		local first = self.tsdb_dropdown_scroll
		local panel_w = math.min(root.width - 20 * scale,
			math.max(225 * scale, math.min(285 * scale, root.width * 0.28)))
		local panel_x = self.ax + self.padding + root.width - panel_w - 7 * scale
		local panel_h = visible * row_h + pad * 2
		-- Search header is item 2, filter header is item 3 (item 1 is the summary).
		local panel_y = root.top + (dd.kind == 'search' and 2 or 3) * self.scroll_step
		panel_y = math.min(panel_y, display.height - panel_h - 14 * scale)
		panel_y = math.max(8 * scale, panel_y)
		self.tsdb_popup_rect = {ax = panel_x, ay = panel_y,
			bx = panel_x + panel_w, by = panel_y + panel_h}
		ass:rect(panel_x, panel_y, panel_x + panel_w, panel_y + panel_h, {
			color = '332417', opacity = self.opacity * 0.99, radius = 8 * scale,
		})
		for i = 1, visible do
			local option = items[first + i]
			local y = panel_y + pad + (i - 1) * row_h
			local hit = {ax = panel_x + 5 * scale, ay = y,
				bx = panel_x + panel_w - 10 * scale, by = y + row_h}
			local hovered = get_point_to_rectangle_proximity(cursor, hit) <= 0
			if hovered or option.selected then
				ass:rect(hit.ax, y + 2 * scale, hit.bx, y + row_h - 2 * scale, {
					color = hovered and '6D4B30' or '493827',
					opacity = self.opacity * (hovered and 0.98 or 0.82), radius = 5 * scale,
				})
			end
			ass:icon(hit.ax + 14 * scale, y + row_h / 2, font * 1.08,
				option.selected and 'check_box' or 'check_box_outline_blank', {
					color = option.selected and 'FFC98C' or 'C6B4A0', opacity = self.opacity,
				})
			ass:txt(hit.ax + 32 * scale, y + row_h / 2, 4, ass_escape(option.title or ''), {
				size = font * 0.90, color = 'FFFFFF', opacity = self.opacity,
				clip = ('\\clip(%d,%d,%d,%d)'):format(hit.ax + 32 * scale, y,
					hit.bx - 6 * scale, y + row_h),
			})
			if option.value then
				cursor:zone('primary_down', hit, self:create_action(function()
					self.tsdb_ignore_mouse_up = true
					mp.command_native(option.value)
				end))
			end
		end
		if #items > visible and visible > 0 then
			local track_y = panel_y + pad
			local track_h = visible * row_h
			local thumb_h = track_h * visible / #items
			local thumb_y = track_y + (self.tsdb_dropdown_scroll / max_scroll) * (track_h - thumb_h)
			ass:rect(panel_x + panel_w - 6 * scale, track_y,
				panel_x + panel_w - 3 * scale, track_y + track_h, {
					color = '594633', opacity = self.opacity * 0.8, radius = 2 * scale,
				})
			ass:rect(panel_x + panel_w - 6 * scale, thumb_y,
				panel_x + panel_w - 3 * scale, thumb_y + thumb_h, {
					color = 'B6A5A0', opacity = self.opacity, radius = 2 * scale,
				})
		end
	else
		self.tsdb_dropdown_kind = nil
		self.tsdb_dropdown_scroll = 0
	end

	-- Tooltip is rendered AFTER the menu so it floats above the selected row.
	local hover = self.tsdb_hover_candidate
	local hover_key = hover and hover.key or nil
	if hover_key ~= self.tsdb_hover_key then
		if self.tsdb_hover_timer then self.tsdb_hover_timer:kill(); self.tsdb_hover_timer = nil end
		self.tsdb_hover_key = hover_key
		self.tsdb_hover_ready = false
		if hover_key then
			self.tsdb_hover_timer = mp.add_timeout(0.4, function()
				self.tsdb_hover_timer = nil
				if self:is_alive() and self.tsdb_hover_key == hover_key then
					self.tsdb_hover_ready = true
					request_render()
				end
			end)
		end
	end
	if hover and self.tsdb_hover_ready then
		local scale = state.scale
		local pad_x = round(11 * scale)
		local pad_y = round(6 * scale) -- compact top and bottom, without touching glyphs
		local font_size = self.font_size * 0.90
		local text_opts = {size = font_size, bold = false, italic = false}
		local max_width = math.max(120 * scale, display.width - 32 * scale)
		local bubble_width = math.min(max_width, text_width(hover.name, text_opts) + 2 * pad_x + 3 * scale)
		local shown_name = tsdb_fit_middle(hover.name, bubble_width - 2 * pad_x - 2 * scale, font_size)
		local bubble_height = round(font_size * 1.23 + 2 * pad_y)
		local bubble_x = clamp(12 * scale, hover.x,
			math.max(12 * scale, display.width - bubble_width - 12 * scale))
		local gap = 2 * scale
		local bubble_y = hover.bottom + gap
		-- If close to uosc's activation region, place the bubble just above its row.
		if bubble_y + bubble_height > display.height - 140 * scale then
			bubble_y = hover.top - bubble_height - gap
		end
		bubble_y = clamp(8 * scale, bubble_y,
			math.max(8 * scale, display.height - bubble_height - 140 * scale))
		-- Bright fine outline, dark opaque interior and compact vertical padding.
		ass:rect(bubble_x, bubble_y, bubble_x + bubble_width, bubble_y + bubble_height, {
			color = '795E44', radius = 7 * scale, opacity = self.opacity * 0.98,
		})
		ass:rect(bubble_x + scale, bubble_y + scale,
			bubble_x + bubble_width - scale, bubble_y + bubble_height - scale, {
			color = '281D13', radius = 6 * scale, opacity = self.opacity * 0.99,
		})
		ass:txt(bubble_x + pad_x, bubble_y + bubble_height / 2, 4, ass_escape(shown_name), {
			size = font_size, color = 'FFFFFF', opacity = self.opacity,
			clip = ('\\clip(%d,%d,%d,%d)'):format(bubble_x + pad_x, bubble_y,
				bubble_x + bubble_width - pad_x, bubble_y + bubble_height),
		})
	end

	return ass
end

return Menu
