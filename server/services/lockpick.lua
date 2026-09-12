local function hasLockpickItem(src)
  if not Config.LockPicking or not Config.LockPicking.RequireItem then
    return true
  end
  local item = Config.LockPicking.ItemName or 'lockpick'
  local result = exports['feather-inventory'].initiate().Items.GetItemCount(item, src)
  return type(result) == 'table' and result.ok == true and (tonumber(result.value) or 0) > 0
end

local authorizedAttempts = {}

exports['feather-core']:RegisterRPC('bcc-banks:lockpick:canStart', function(params, cb, src)
  local doorHash = tonumber(params and params.doorHash)
  local can = doorHash ~= nil
      and Config.LockPicking and Config.LockPicking.Enabled == true
      and Config.Doors[doorHash] ~= nil
      and IsPlayerNearBank(src, nil, 25.0, false)
      and hasLockpickItem(src)
  if can then
    authorizedAttempts[src] = {
      door = doorHash,
      earliest = GetGameTimer() + 1000,
      expires = GetGameTimer() + 120000,
    }
  else
    authorizedAttempts[src] = nil
  end
  cb(true, can)
end)

exports['feather-core']:RegisterRPC('bcc-banks:lockpick:onSuccess', function(params, cb, src)
  local doorHash = tonumber(params and params.doorHash)
  local attempt = authorizedAttempts[src]
  authorizedAttempts[src] = nil
  local now = GetGameTimer()
  if not attempt or attempt.door ~= doorHash or now < attempt.earliest or now > attempt.expires then
    cb(true)
    return
  end
  if Config.Doors[doorHash] == nil or not IsPlayerNearBank(src, nil, 25.0, false) then
    cb(true)
    return
  end
  if not hasLockpickItem(src) then
    cb(true)
    return
  end

  TriggerClientEvent('bcc-banks:lockpick:setDoorState', -1, doorHash, 0, src, 'lockpick')
  local relock = tonumber(Config.LockPicking.RelockSeconds or 0) or 0
  if relock > 0 then
    SetTimeout(relock * 1000, function()
      TriggerClientEvent('bcc-banks:lockpick:setDoorState', -1, doorHash, 1, 0, 'relock')
    end)
  end
  cb(true)
end)

exports['feather-core']:RegisterRPC('bcc-banks:lockpick:bypassSetDoorState', function(params, cb, src)
  local doorHash = tonumber(params and params.doorHash)
  local state = tonumber(params and params.state)
  if not doorHash or (state ~= 0 and state ~= 1) then
    cb(true)
    return
  end
  if not Config.LockPicking or Config.LockPicking.Enabled ~= true or Config.LockPicking.AdminBypass == false then
    cb(true)
    return
  end
  if Config.Doors[doorHash] == nil or not IsPlayerNearBank(src, nil, 25.0, false) then
    cb(true)
    return
  end
  if not IsBankAdmin(src) then
    cb(true)
    return
  end

  TriggerClientEvent('bcc-banks:lockpick:setDoorState', -1, doorHash, state, src, 'bypass')
  cb(true)
end)

AddEventHandler('playerDropped', function()
  authorizedAttempts[source] = nil
end)

-- Reduce lockpick durability or destroy on failure (mirrors MMS style)
exports['feather-core']:RegisterRPC('bcc-banks:lockpick:onFail', function(_, cb, src)
  local cfg = Config.LockPicking or {}
  local itemName = (cfg and cfg.ItemName) or 'lockpick'
  local dur = (cfg and cfg.Durability) or {}

  if dur.Enabled then
    local damage = tonumber(dur.DamageOnFail or 10) or 10
    local inventory = exports['feather-inventory'].initiate()
    local session = exports['feather-core']:GetSessionContext(src)
    if type(session) ~= 'table' or session.ok ~= true or not session.value.characterId then
      cb(true)
      return
    end
    local characterInventory = inventory.Inventory.GetCharacterInventory(session.value.characterId)
    if type(characterInventory) ~= 'table' or characterInventory.ok ~= true then
      cb(true)
      return
    end
    local items = inventory.Inventory.GetInventoryItems(characterInventory.value.id)
    if type(items) ~= 'table' or items.ok ~= true then
      cb(true)
      return
    end
    local instance
    for _, candidate in ipairs(items.value or {}) do
      if candidate.name == itemName then instance = candidate break end
    end
    if not instance or not instance.id then
      cb(true)
      return
    end
    local adjusted = inventory.Items.AdjustCondition(instance.id, -damage)
    local remainingCondition = type(adjusted) == 'table' and adjusted.ok == true
      and tonumber(adjusted.value and adjusted.value.condition) or nil
    if remainingCondition and remainingCondition <= 0 then
      inventory.Items.RemoveItemById(instance.id)
    end
  elseif (dur.DestroyOnFailIfDisabled == true) then
    exports['feather-inventory'].initiate().Items.RemoveItemByName(itemName, 1, src)
  end
  cb(true)
end)
