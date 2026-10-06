-- Run from the resources directory with Lua 5.4. No server or database required.
local providers, chatExports, threads = {}, {}, {}
local chatEvents, bankEvents = {}, {}
local failAuthority, refuseProvider = false, false
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function handler(events, name, callback)
    events[name] = events[name] or {}
    table.insert(events[name], callback)
end
local function emit(events, name, resource)
    for _, callback in ipairs(events[name] or {}) do callback(resource) end
end
local function drain()
    while #threads > 0 do table.remove(threads, 1)() end
end
local core = {
    RegisterProvider = function(_, _, name, implementation)
        if refuseProvider then return { ok=false, code='unavailable' } end
        if providers[name] then return { ok=false, code='conflict' } end
        providers[name] = implementation
        return { ok=true }
    end,
    GetProvider = function(_, _, name)
        return { ok=providers[name] ~= nil, value={ implementation=providers[name] } }
    end,
    UnregisterProvider = function(_, _, name)
        providers[name] = nil
        return { ok=true }
    end
}
local function loadChat()
    chatExports, chatEvents = {}, {}
    local env = setmetatable({
        GetCurrentResourceName=function() return 'feather-chat' end,
        GetInvokingResource=function() return 'bcc-banks' end,
        TriggerClientEvent=function() end,
        AddEventHandler=function(name, cb) handler(chatEvents, name, cb) end,
        exports=setmetatable({ ['feather-core']=core }, {
            __call=function(_, name, fn) chatExports[name] = fn end
        })
    }, { __index=_G })
    assert(loadfile('[feather]/feather-chat/shared/results.lua', 't', env))()
    assert(loadfile('[feather]/feather-chat/server/channels.lua', 't', env))()
    chatExports.AwaitReady = function() return { ok=true } end
    return env.ChatChannels
end
local channels = loadChat()
local bankEnv = setmetatable({
    Config={ Admin={ command='bankmanage' } },
    CreateThread=function(cb) table.insert(threads, cb) end,
    AddEventHandler=function(name, cb) handler(bankEvents, name, cb) end,
    IsBankAdmin=function(src)
        if failAuthority then error('Authority unavailable') end
        return src == 42
    end,
    exports={ ['feather-chat']=setmetatable({}, {
        __index=function(_, name)
            return function(_, ...) return chatExports[name](...) end
        end
    }) }
}, { __index=_G })
assert(loadfile('[bcc]/bcc-banks/server/main.lua', 't', bankEnv))()
drain()
local function suggestions(src)
    return channels.List({ source=src }).value.suggestions
end
check(#suggestions(42) == 1, 'authorized bank admin sees the suggestion')
check(suggestions(42)[1].trigger == '/bankmanage', 'configured command is retained')
check(#suggestions(7) == 0, 'ordinary player cannot see the suggestion')
check(#suggestions(0) == 0, 'console bypass cannot expose a player suggestion')
check(#suggestions(nil) == 0, 'missing source fails closed')
failAuthority = true
check(#suggestions(42) == 0, 'failed authorization hides the suggestion')
failAuthority = false
local saved = providers['bcc-banks.admin']
providers['bcc-banks.admin'] = nil
check(#suggestions(42) == 0, 'missing provider hides the suggestion')
providers['bcc-banks.admin'] = { CanView=function() return { ok=true, value='invalid' } end }
check(#suggestions(42) == 0, 'malformed provider result hides the suggestion')
providers['bcc-banks.admin'] = saved
emit(bankEvents, 'onResourceStart', 'feather-chat')
drain()
check(#suggestions(42) == 1, 'duplicate startup does not duplicate the suggestion')
check(not chatExports.RegisterSuggestion({ key='test.invalid', trigger='/invalid',
    description='Invalid provider', accessProvider=4 }).ok, 'invalid provider name rejected')
check(chatExports.RegisterSuggestion({ key='test.public', trigger='/public',
    description='Public command' }).ok, 'unrestricted suggestions still register')
check(#suggestions(7) == 1, 'unrestricted suggestions remain visible')
emit(bankEvents, 'onResourceStop', 'feather-chat')
providers = {}
channels = loadChat()
refuseProvider = true
emit(bankEvents, 'onResourceStart', 'feather-chat')
drain()
check(#suggestions(42) == 0, 'provider registration failure does not expose the command')
refuseProvider = false
emit(bankEvents, 'onResourceStart', 'feather-chat')
drain()
check(#suggestions(42) == 1, 'chat restart restores provider and suggestion')
check(#suggestions(7) == 0, 'restored suggestion remains restricted')
emit(chatEvents, 'onResourceStop', 'bcc-banks')
check(#suggestions(42) == 0 and providers['bcc-banks.admin'] == nil,
    'bank stop removes the suggestion and provider')
print(('Chat suggestion integration: %d checks passed'):format(checks))
