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

-- Advertises the bank admin command as a bcc-chat suggestion, staff-gated
-- with the same access-provider name bcc-chat registers for its own /staff
-- channel. Suggestions live in bcc-chat's in-memory registry, which is
-- wiped on bcc-chat's OWN restart (not just when bcc-banks stops) -- so
-- this re-registers whenever bcc-chat (re)starts, not only once at boot.
local function registerBankAdminSuggestion()
	local ready = exports['bcc-chat']:AwaitReady(30000)
	if type(ready) ~= 'table' or not ready.ok then return end

	local adminCmd = (Config and Config.Admin and Config.Admin.command) or 'bankadmin'
	exports['bcc-chat']:RegisterSuggestion({
		key = 'bcc-banks.bankadmin',
		trigger = '/' .. adminCmd,
		description = 'Open the bank admin menu',
		accessProvider = 'bcc-chat.roles.staff'
	})
end

CreateThread(registerBankAdminSuggestion)

AddEventHandler('onResourceStart', function(resource)
	if resource == 'bcc-chat' then
		CreateThread(registerBankAdminSuggestion)
	end
end)

