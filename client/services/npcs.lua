local function deletePedEntity(ped)
	if not ped or ped == 0 or not DoesEntityExist(ped) then return end
	SetEntityAsMissionEntity(ped, true, true)
	DeletePed(ped)
	if DoesEntityExist(ped) then DeleteEntity(ped) end
end

local function clearOrphanedTellersAtBank(bank)
	local model = Config.NPCSettings.Model
	local modelHash = type(model) == 'number' and model or GetHashKey(model)
	local bankCoords = vector3(tonumber(bank.x), tonumber(bank.y), tonumber(bank.z))
	for _, ped in ipairs(GetGamePool('CPed') or {}) do
		if ped ~= PlayerPedId() and DoesEntityExist(ped) and GetEntityModel(ped) == modelHash then
			local coords = GetEntityCoords(ped)
			if #(coords - bankCoords) <= 2.0 then
				deletePedEntity(ped)
			end
		end
	end
end

function AddNPC(bank)
	-- A resource restart can leave the old locally-created wrapper entity behind.
	-- Remove matching tellers at this exact bank before creating its replacement.
	clearOrphanedTellersAtBank(bank)
	local created = exports['feather-toolkit']:CreatePed({
		model = Config.NPCSettings.Model, x = tonumber(bank.x), y = tonumber(bank.y),
		z = tonumber(bank.z), heading = tonumber(bank.h), networked = false, scriptHost = true
	})
	if type(created) ~= 'table' or created.ok ~= true then
		error(('[bcc-banks] teller creation failed: %s'):format(
			tostring(type(created) == 'table' and created.code or 'invalid_result')))
	end
	local npc = { id = created.value.id, ped = created.value.entity }
	local ped = npc.ped

	-- Teller NPCs are fixtures, not ambient pedestrians. Blocking ambient events and
	-- fleeing prevents gunshots from starting a flee task while the entity is frozen
	-- (the combination that makes the ped appear to run in place).
	ClearPedTasksImmediately(ped)
	SetBlockingOfNonTemporaryEvents(ped, true)
	SetPedFleeAttributes(ped, 0, false)
	SetPedCanRagdoll(ped, false)
	SetEntityInvincible(ped, true)
	SetEntityCanBeDamaged(ped, false)
	FreezeEntityPosition(ped, true)
	return npc
end

function RemoveNPC(bank)
	if not bank or not bank.npc then return end
	local npc = bank.npc
	deletePedEntity(npc.ped)
	if npc.id then exports['feather-toolkit']:RemoveEntity(npc.id) end
	bank.npc = nil
	bank.npcSpawning = false
end

function ClearNPCs()
	for _, v in pairs(Banks) do
		RemoveNPC(v)
		v.npcSpawning = false
	end
end
