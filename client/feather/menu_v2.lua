-- Temporary Feather Menu v2 compatibility layer for the existing BCC menu layout.
FeatherMenuV2Compat = FeatherMenuV2Compat or {}

local menuExport = exports['feather-menu-v2']

local function result(operation, response)
    if response and response.ok then return response.value end
    print(('[bcc-banks] feather-menu-v2 %s failed: %s (%s)'):format(operation,
        response and response.message or 'no result', response and response.code or 'unknown'))
end

local function plainText(value)
    if type(value) == 'table' then value = table.concat(value, '\n') end
    value = tostring(value or '')
    value = value:gsub('<br%s*/?>', '\n'):gsub('</t[dh]%s*>', ' | '):gsub('</div%s*>', '\n'):gsub('</tr%s*>', '\n')
        :gsub('</p%s*>', '\n'):gsub('</?[^>]+>', ''):gsub('&nbsp;', ' '):gsub('&amp;', '&')
        :gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&#39;', "'"):gsub('&quot;', '"')
        :gsub('[ \t]+\n', '\n'):gsub('\n[ \t]+', '\n'):gsub('\n\n+', '\n')
    value = value:match('^%s*(.-)%s*$') or value
    return value:sub(1, 4096)
end

local function assetPath(value)
    if type(value) ~= 'string' then return value end
    local resource, path = value:match('^nui://([^/]+)/(.+)$')
    return resource and ('https://cfx-nui-%s/%s'):format(resource, path) or value
end

local function copyAllowed(source, names)
    local target = {}
    for _, name in ipairs(names) do if source[name] ~= nil then target[name] = source[name] end end
    return target
end

local function adaptElement(elementType, source, key)
    source = source or {}
    if elementType == 'html' then elementType = 'textdisplay' end
    local fields = {
        header = {'value'}, subheader = {'value'}, textdisplay = {'value'}, line = {}, bottomline = {},
        button = {'value', 'sound'}, input = {'value', 'placeholder', 'maxLength'},
        textarea = {'value', 'placeholder', 'maxLength', 'rows'}, number = {'value', 'min', 'max', 'step', 'placeholder'},
        slider = {'value', 'min', 'max', 'step'}, progress = {'value', 'min', 'max', 'step', 'text'},
        toggle = {'value', 'onLabel', 'offLabel', 'sound'}, checkbox = {'value', 'onLabel', 'offLabel', 'sound'},
        arrows = {'value', 'options', 'sound'}, dropdown = {'value', 'options', 'placeholder', 'emptyText', 'maxVisibleOptions', 'sound'},
        radio = {'value', 'options', 'sound'}, colorpicker = {'value', 'options', 'sound'},
        gridslider = {'value', 'maxx', 'maxy', 'step', 'stepx', 'stepy', 'sound'},
        pagearrows = {'current', 'total', 'sound'}, imagebox = {'value', 'image', 'img', 'alt', 'sound'},
        imageboxcontainer = {'items', 'sound'}, spacer = {'size'},
    }
    local spec = copyAllowed(source, fields[elementType] or {})
    spec.key, spec.slot, spec.label = key, source.slot, source.label
    spec.disabled, spec.persist = source.disabled, source.persist

    if elementType == 'textdisplay' and type(source.value) == 'table' then spec.value = plainText(source.value) end
    if (elementType == 'toggle' or elementType == 'checkbox') and spec.value == nil then spec.value = source.start == true end

    local legacyChoices
    if elementType == 'arrows' or elementType == 'dropdown' or elementType == 'radio' then
        legacyChoices = source.options
        if type(legacyChoices) == 'table' and #legacyChoices > 0 then
            spec.options = {}
            for index, option in ipairs(legacyChoices) do
                spec.options[index] = { value = index, label = type(option) == 'table' and
                    (option.label or option.display or option.text) or tostring(option) }
            end
            spec.value = tonumber(source.start) or 1
        end
    elseif elementType == 'imagebox' then
        spec.image, spec.img = assetPath(spec.image or spec.img), nil
    elseif elementType == 'imageboxcontainer' and type(source.items) == 'table' then
        legacyChoices, spec.items = source.items, {}
        for index, item in ipairs(source.items) do
            local data = item.data or item
            spec.items[index] = { key = 'item_' .. index, value = index, label = data.label,
                image = assetPath(data.image or data.img), alt = data.alt or data.tooltip,
                disabled = data.disabled == true }
        end
    end
    return elementType, spec, legacyChoices
end

local Page = {}; Page.__index = Page

function Page:RegisterElement(elementType, spec, callback)
    self.sequence = self.sequence + 1
    local v2Type, v2Spec, legacyChoices = adaptElement(elementType, spec, ('element_%d'):format(self.sequence))
    local wrapped = callback
    if callback and legacyChoices then
        wrapped = function(data)
            local index = tonumber(data and data.value)
            local legacy = index and legacyChoices[index]
            if v2Type == 'imageboxcontainer' then callback({ value = legacy, child = legacy })
            else callback({ value = legacy, index = index }) end
        end
    end
    local value = result('AddElement', menuExport:AddElement(self.menu.menuId, self.pageId, v2Type, v2Spec, wrapped))
    if value then self.elements[#self.elements + 1] = value.elementId end
    return value
end

function Page:RouteTo()
    return result('NavigateToPage', menuExport:NavigateToPage(self.menu.menuId, self.pageId))
end

local Menu = {}; Menu.__index = Menu

function Menu:RegisterPage(key)
    local page = self.pages[key]
    if page then
        for _, elementId in ipairs(page.elements) do
            result('RemoveElement', menuExport:RemoveElement(self.menuId, page.pageId, elementId))
        end
        page.elements, page.sequence = {}, 0
        return page
    end
    local value = result('CreatePage', menuExport:CreatePage(self.menuId, { key = key }))
    page = setmetatable({ menu = self, pageId = value and value.pageId or '', elements = {}, sequence = 0 }, Page)
    self.pages[key] = page
    return page
end

function Menu:Open(options)
    local page = options and options.startupPage
    result('AwaitReady', menuExport:AwaitReady(5000))
    return result('OpenMenu', menuExport:OpenMenu(self.menuId, { pageId = page and page.pageId or nil,
        keyboard = true, cursor = true, replace = true }))
end

function Menu:Close() return result('CloseMenu', menuExport:CloseMenu(self.menuId, {})) end

function FeatherMenuV2Compat:RegisterMenu(key, source, callbacks)
    source = source or {}
    local contentStyle = source.contentslot and source.contentslot.style or {}
    local value = result('CreateMenu', menuExport:CreateMenu({
        key = key, draggable = source.draggable ~= false, closable = source.canclose ~= false,
        persistPosition = false,
        position = { x = '13%', y = '50%' },
        size = { width = source['1080width'] or source.width or '500px',
            minHeight = contentStyle['min-height'] or '350px', height = contentStyle.height or 'auto',
            breakpoints = { ['720'] = source['720width'] or '400px', ['1080'] = source['1080width'] or '500px',
                ['1440'] = source['2kwidth'] or '600px', ['2160'] = source['4kwidth'] or '800px' } },
        focus = { keyboard = true, cursor = true },
    }))
    if not value then return nil end
    local menu = setmetatable({ menuId = value.menuId, pages = {} }, Menu)
    if callbacks then
        result('RegisterMenuLifecycle', menuExport:RegisterMenuLifecycle(menu.menuId, function(event)
            if event.event == 'opened' and callbacks.opened then callbacks.opened(event) end
            if event.event == 'closed' and callbacks.closed then callbacks.closed(event) end
        end))
    end
    return menu
end
