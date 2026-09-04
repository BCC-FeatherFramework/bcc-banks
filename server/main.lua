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

