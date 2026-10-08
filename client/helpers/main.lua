if Config and Config.devMode then
    function devPrint(...)
        local args = { ... }
        for i = 1, #args do
            if type(args[i]) == "table" then
                args[i] = json.encode(args[i])
            elseif args[i] == nil then
                args[i] = "nil"
            else
                args[i] = tostring(args[i])
            end
        end
        -- One print per line, each ending with ^0 so the color never carries over.
        for line in (table.concat(args, " ") .. "\n"):gmatch("(.-)\n") do
            print("^1[DEV MODE] ^4" .. line .. "^0")
        end
    end
else
    function devPrint(...) end
end

function LoadModel(model)
  RequestModel(model)
  while not HasModelLoaded(model) do
    RequestModel(model)
    Wait(100)
  end
end

function Notify(message, typeOrDuration, maybeDuration)
    local notifyType = "info"
    local notifyDuration = 4000

    -- Detect which argument is which
    if type(typeOrDuration) == "string" then
        notifyType = typeOrDuration
        notifyDuration = tonumber(maybeDuration) or 4000
    elseif type(typeOrDuration) == "number" then
        notifyDuration = typeOrDuration
    end

    local result = exports['feather-notify']:ShowNotification({
        style = notifyType == 'error' and 'warning' or 'right',
        message = tostring(message),
        duration = notifyDuration
    })
    if type(result) ~= 'table' or result.ok ~= true then
        devPrint('[Notify] Feather Notify failed:',
            tostring(type(result) == 'table' and result.code or 'invalid_result'))
    end
end

exports['feather-core']:RegisterRPC("bcc-banks:NotifyClient", function(data)
    Notify(data.message, data.type, data.duration)
end)

function NormalizeId(value)
    if value == nil then return nil end
    if type(value) == 'number' then
        if value ~= value then return nil end
        if math.type and math.type(value) == 'integer' then
            return tostring(value)
        end
        local rounded
        if value >= 0 then
            rounded = math.floor(value + 0.5)
        else
            rounded = math.ceil(value - 0.5)
        end
        return tostring(rounded)
    end
    local str = tostring(value)
    str = str:match('^%s*(.-)%s*$') or str
    if str == '' then return nil end
    return str
end

function IdsEqual(left, right)
    local a = NormalizeId(left)
    local b = NormalizeId(right)
    if not a or not b then return false end
    return a == b
end
