-- Clear locks on player drop
AddEventHandler('feather:character:logout', function(src)
	ClearBankerBusy(src)
	ClearAccountLocks(src)
end)

AddEventHandler('playerDropped', function()
	local src = source
	ClearBankerBusy(src)
	ClearAccountLocks(src)
end)

-- Use the same permission for suggestion visibility as the bank admin menu.
-- Chat owns the registry, so register again after it restarts.
local chatProvider = 'bcc-banks.admin'
local registering, providerRegistered, suggestionRegistered = false, false, false

local function registerBankAdminSuggestion()
	if registering or suggestionRegistered then return end
	registering = true
	local called, result = pcall(function()
		local ready = exports['feather-chat']:AwaitReady(30000)
		if type(ready) ~= 'table' or not ready.ok then return ready end

		if not providerRegistered then
			local provider = exports['feather-chat']:RegisterChannelAccessProvider(chatProvider, {
				CanView = function(request)
					local actor = type(request) == 'table' and request.actor
					local src = type(actor) == 'table' and tonumber(actor.source)
					return { ok = true, value = { allowed = src ~= nil and src > 0 and IsBankAdmin(src) == true } }
				end
			})
			if type(provider) ~= 'table' or not provider.ok then return provider end
			providerRegistered = true
		end

		local adminCmd = (Config and Config.Admin and Config.Admin.command) or 'bankadmin'
		return exports['feather-chat']:RegisterSuggestion({
			key = 'bcc-banks.bankadmin',
			trigger = '/' .. adminCmd,
			description = 'Open the bank admin menu',
			accessProvider = chatProvider
		})
	end)
	registering = false
	suggestionRegistered = called and type(result) == 'table' and result.ok == true
	if not suggestionRegistered then
		print(('[bcc-banks] Chat suggestion registration failed: %s'):format(
			called and type(result) == 'table' and tostring(result.code) or tostring(result)))
	end
end

CreateThread(registerBankAdminSuggestion)

AddEventHandler('onResourceStart', function(resource)
	if resource == 'feather-chat' then
		CreateThread(registerBankAdminSuggestion)
	end
end)

AddEventHandler('onResourceStop', function(resource)
	if resource == 'feather-chat' then
		providerRegistered, suggestionRegistered = false, false
	end
end)
