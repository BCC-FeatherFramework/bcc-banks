Feather = Feather or {}
Feather.Locale = Feather.Locale or {}

function Feather.Locale.register(locale, translations)
    local result = exports['feather-core']:RegisterLocale(locale, translations)
    if type(result) ~= 'table' or result.ok ~= true then
        error(('[bcc-banks] locale registration failed for %s: %s'):format(
            tostring(locale), tostring(type(result) == 'table' and result.code or 'invalid_result')))
    end
    return result
end

local function resolve(key, ...)
    local result = exports['feather-core']:TranslateLocale(0, key, ...)
    if type(result) == 'table' and result.ok == true and type(result.value) == 'string' then
        return result.value
    end
    return tostring(key)
end

-- Existing menu/service code calls Feather.Locale.translate(Upper) directly
-- while Feather Core owns registration, locale selection, fallback, and formatting.
function Feather.Locale.translate(key, ...)
    return resolve(key, ...)
end

function Feather.Locale.translateUpper(key, ...)
    local translation = resolve(key, ...)
    return translation:sub(1, 1):upper() .. translation:sub(2)
end
