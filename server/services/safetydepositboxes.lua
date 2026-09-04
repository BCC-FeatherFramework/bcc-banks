local function getSDBBankId(sdbId)
    local row = MySQL.single.await('SELECT `bank_id` FROM `bcc_safety_deposit_boxes` WHERE `id` = ? LIMIT 1', { sdbId })
    return row and row.bank_id or nil
end

exports['feather-core']:RegisterRPC('Feather:Banks:GetSDBs', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then
        devPrint('GetSDBs: no user for src', src)
        NotifyClient(src, _U('error_invalid_character_or_bank'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        devPrint('GetSDBs: no character for src', src)
        NotifyClient(src, _U('error_invalid_character_or_bank'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = char.characterId
    local bankId = NormalizeId(params and params.bank)

    if not characterId or not bankId then
        devPrint("GetSDBs: invalid inputs", "characterId=", characterId, "bankId=", bankId)
        NotifyClient(src, _U('error_invalid_character_or_bank'), 'error', 4000)
        cb(false)
        return
    end

    if not IsPlayerNearBank(src, bankId) then
        NotifyClient(src, _U('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local ok, rows = pcall(function()
        return GetUserSDBData(characterId, bankId)
    end)

    if not ok then
        devPrint("GetSDBs: DB error while fetching SDBs for", characterId, "bank", bankId)
        NotifyClient(src, _U('error_db'), 'error', 4000)
        cb(false)
        return
    end

    cb(true, rows or {})
end)

exports['feather-core']:RegisterRPC('Feather:Banks:CreateSDB', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then NotifyClient(src, _U('error_invalid_data'), 'error', 4000) return cb(false) end
    local char = user
    if not char then NotifyClient(src, _U('error_invalid_data'), 'error', 4000) return cb(false) end

    -- inputs
    local characterId = char.characterId          -- adjust if your framework uses a different name
    local name        = params and params.name
    local bank        = NormalizeId(params and params.bank)
    local sizeKey     = params and params.size
    local payWith     = (params and params.payWith) or "cash"  -- "cash" | "gold"

    if not characterId or not bank or not name or name == "" or not sizeKey then
        devPrint("CreateSDB invalid inputs", characterId, bank, name, sizeKey)
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        return cb(false)
    end
    if not IsPlayerNearBank(src, bank) then
        NotifyClient(src, _U('error_not_at_bank'), 'error', 4000)
        return cb(false)
    end
    name = tostring(name):sub(1, 64)

    -- resolve size & price from config (case-insensitive)
    local sizes = Config.SafetyDepositBoxes.Sizes or {}
    local resolvedKey, sz
    do
        local want = tostring(sizeKey):lower()
        for k,v in pairs(sizes) do
            if tostring(k):lower() == want then resolvedKey = k; sz = v; break end
        end
    end
    if not sz then
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        return cb(false)
    end

    local CURRENCY = { cash = 0, gold = 1 }
    local currencyId = CURRENCY[(payWith == 'gold') and 'gold' or 'cash']
    local price = (payWith == 'gold') and (sz.GoldPrice or 0) or (sz.CashPrice or 0)
    if not IsFinitePositiveNumber(price) then
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        return cb(false)
    end

    -- check balance using Feather character profile
    local balance = (currencyId == 0) and tonumber(char.money) or tonumber(char.gold)
    if not balance or balance < price then
        if currencyId == 0 then
            NotifyClient(src, _U('error_not_enough_cash', tostring(balance or 0)), 'error', 4000)
        else
            NotifyClient(src, _U('error_not_enough_gold_to_sell'), 'error', 4000)
        end
        return cb(false)
    end
    if not AcquirePlayerFinancialLock(src) then
        NotifyClient(src, _U('error_financial_operation_busy'), 'error', 4000)
        return cb(false)
    end

    -- try to charge first so we don't create resources the player can't pay for
    local charged = false
    local chargeOk, chargeErr = pcall(function()
        char.DebitWallet(currencyId, price)
        charged = true
    end)
    if not chargeOk then
        ReleasePlayerFinancialLock(src)
        devPrint("CreateSDB charge failed:", tostring(chargeErr))
        NotifyClient(src, _U('error_unable_create_sdb'), 'error', 4000)
        return cb(false)
    end

    -- create DB row
    local ok, boxOrErr, szFromCtrl = pcall(CreateSDB, name, characterId, bank, resolvedKey)
    if not ok or boxOrErr == false then
        -- refund if DB failed
        if charged then pcall(function() if char.CreditWallet then char.CreditWallet(currencyId, price) end end) end
        devPrint("CreateSDB DB failed:", tostring(ok and (szFromCtrl or "unknown") or boxOrErr))
        NotifyClient(src, _U('error_unable_create_sdb'), 'error', 4000)
        ReleasePlayerFinancialLock(src)
        return cb(false)
    end
    local box = boxOrErr
    local szCfg = szFromCtrl or sz

    -- register inventory & grant access
    local invName = tostring(name)
    local restrictedItems  = (szCfg.BlacklistItems and #szCfg.BlacklistItems or 0) > 0 and szCfg.BlacklistItems or nil
    local ignoreItemLimits = (szCfg.IgnoreItemLimit == true)

    local invOk, invErr = pcall(function()
        local inventory = exports['feather-inventory'].initiate()
        local foreignKey = inventory.Inventory.RegisterForeignKey(
            'bcc_safety_deposit_boxes',
            'VARCHAR(36) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci', 'id')
        if type(foreignKey) ~= 'table' or foreignKey.ok ~= true then
            local failure = type(foreignKey) == 'table' and foreignKey.error or nil
            error(failure and (failure.message or failure.code) or 'Feather Inventory foreign-key registration failed')
        end
        local registered = inventory.Inventory.RegisterInventory(
            'bcc_safety_deposit_boxes', box.id, invName, ignoreItemLimits,
            tonumber(szCfg.MaxWeight) or 100, restrictedItems, tostring(characterId), false,
            tonumber(szCfg.MaxSlots)
        )
        if type(registered) ~= 'table' or registered.ok ~= true then
            local failure = type(registered) == 'table' and registered.error or nil
            error(failure and (failure.message or failure.code) or 'Feather Inventory container registration failed')
        end

        MySQL.update.await('UPDATE `bcc_safety_deposit_boxes` SET `inventory_id`=? WHERE `id`=?', { registered.value.uuid, box.id })
        MySQL.insert.await(
            'INSERT INTO `bcc_safety_deposit_boxes_access` (`safety_deposit_box_id`, `character_id`, `level`) VALUES (?,?,?)',
            { box.id, characterId, Config.AccessLevels.Admin }
        )
    end)

    if not invOk then
        -- rollback + refund
        pcall(function()
            MySQL.query.await('DELETE FROM `bcc_safety_deposit_boxes_access` WHERE `safety_deposit_box_id`=?', { box.id })
            MySQL.query.await('DELETE FROM `bcc_safety_deposit_boxes` WHERE `id`=?', { box.id })
            if charged and char.CreditWallet then char.CreditWallet(currencyId, price) end
        end)
        devPrint("CreateSDB: inventory registration failed:", tostring(invErr))
        NotifyClient(src, _U('error_unable_create_sdb'), 'error', 4000)
        ReleasePlayerFinancialLock(src)
        return cb(false)
    end

    -- success (client will show its own toast)
    ReleasePlayerFinancialLock(src)
    local lines = {
        '**Action:** `Safety Deposit Box Created`',
        '**SDB ID:** `' .. tostring(box.id) .. '`',
        '**Name:** `' .. tostring(name) .. '`',
        '**Bank:** `' .. tostring(BccBanksInternal.getBankName(bank)) .. '`',
        '**Size:** `' .. tostring(sizeKey) .. '`',
        '**Paid With:** `' .. tostring(payWith) .. '`',
        '**Price:** `' .. tostring(price) .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Safety Deposit Box Created', lines, 5763719)
    AddCharacterTransaction(characterId, price, 'sdb - created', 'Created SDB #' .. tostring(box.id) .. ' at ' .. tostring(BccBanksInternal.getBankName(bank)) .. ' paid with ' .. tostring(payWith))
    cb(true, box)
end)

AddEventHandler('Feather:Banks:DatabaseReady', function()
    local registered = exports['feather-inventory'].initiate().Inventory.RegisterForeignKey(
        'bcc_safety_deposit_boxes',
        'VARCHAR(36) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci', 'id')
    if type(registered) ~= 'table' or registered.ok ~= true then
        local failure = type(registered) == 'table' and registered.error or nil
        error(('[bcc-banks] Feather Inventory SDB registration failed: %s'):format(
            tostring(failure and (failure.message or failure.code) or 'invalid result')))
    end
end)

local function resolveSDBSizeConfig(sizeKey)
    if not sizeKey then return nil end
    local sizes = Config and Config.SafetyDepositBoxes and Config.SafetyDepositBoxes.Sizes or {}
    if not sizes then return nil end
    local want = tostring(sizeKey)
    local wantLower = want:lower()
    for key, cfg in pairs(sizes) do
        local keyStr = tostring(key)
        if keyStr == want or keyStr:lower() == wantLower then
            return cfg
        end
    end
    return nil
end

local function ensureSDBInventoryRegistered(boxId, inventoryId, displayName, sizeKey)
    local invName = (displayName and displayName ~= '') and tostring(displayName) or 'Safety Deposit Box'
    local sizeCfg = resolveSDBSizeConfig(sizeKey)
    local ignoreStacks = sizeCfg and sizeCfg.IgnoreItemLimit == true
    local blacklist = (sizeCfg and sizeCfg.BlacklistItems and #sizeCfg.BlacklistItems > 0) and sizeCfg.BlacklistItems or nil
    local limit = tonumber(sizeCfg and sizeCfg.MaxWeight) or 100

    local owner = MySQL.scalar.await('SELECT `owner_id` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1', { boxId })
    local inventory = exports['feather-inventory'].initiate()
    local foreignKey = inventory.Inventory.RegisterForeignKey(
        'bcc_safety_deposit_boxes',
        'VARCHAR(36) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci', 'id')
    if type(foreignKey) ~= 'table' or foreignKey.ok ~= true then
        local failure = type(foreignKey) == 'table' and foreignKey.error or nil
        error(failure and (failure.message or failure.code) or 'Feather Inventory foreign-key registration failed')
    end
    local registered = inventory.Inventory.RegisterInventory(
        'bcc_safety_deposit_boxes', boxId, invName, ignoreStacks, limit, blacklist,
        owner and tostring(owner) or nil, false, tonumber(sizeCfg and sizeCfg.MaxSlots)
    )
    if type(registered) ~= 'table' or registered.ok ~= true then
        local failure = type(registered) == 'table' and registered.error or nil
        error(failure and (failure.message or failure.code) or 'Feather Inventory container registration failed')
    end
    return registered.value.uuid, registered.value.id, invName, sizeCfg
end

local function countInventoryRows(rows)
    if type(rows) ~= 'table' then return 0 end
    local count = 0
    for _ in pairs(rows) do
        count = count + 1
    end
    return count
end

local function getSDBInventoryContentCounts(sdbId, inventoryId, displayName, sizeKey)
    local invUuid, invId = ensureSDBInventoryRegistered(sdbId, inventoryId, displayName, sizeKey)
    local itemCount = 0
    local weaponCount = 0

    local itemsOk, items = pcall(function()
        local result = exports['feather-inventory'].initiate().Inventory.GetInventoryItems(invId)
        return type(result) == 'table' and result.ok == true and result.value or {}
    end)
    if itemsOk then
        itemCount = countInventoryRows(items)
    end

    return invUuid, itemCount, weaponCount
end

exports['feather-core']:RegisterRPC('Feather:Banks:OpenSDB', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then
        devPrint('OpenSDB: no user for src', src)
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        devPrint('OpenSDB: no character for src', src)
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = char.characterId
    local sdbId = NormalizeId(params and params.sdb_id)

    if not characterId or not sdbId then
        devPrint("OpenSDB: invalid inputs", "characterId=", characterId, "sdbId=", sdbId)
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end

    if not HasSDBAccess(sdbId, characterId) then
        devPrint("OpenSDB: no access", "charId=", characterId, "sdbId=", sdbId)
        NotifyClient(src, _U('error_insufficient_access'), 'error', 4000)
        cb(false)
        return
    end

    -- Always query our table name directly
    local row = MySQL.query.await(
        'SELECT `inventory_id`,`name`,`size`,`bank_id` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1;',
        { sdbId }
    )[1]
    if not row then
        devPrint("OpenSDB: SDB row not found for id", sdbId)
        NotifyClient(src, _U('error_sdb_not_found'), 'error', 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, row.bank_id) then
        NotifyClient(src, _U('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local invUuid, invId = ensureSDBInventoryRegistered(sdbId, row.inventory_id, row.name, row.size)
    if not row.inventory_id or row.inventory_id ~= invUuid then
        MySQL.query.await('UPDATE `bcc_safety_deposit_boxes` SET `inventory_id`=? WHERE `id`=?', { invUuid, sdbId })
        row.inventory_id = invUuid
    end

    devPrint('OpenSDB: attempting Feather Inventory open for', invUuid, 'src=', src)
    local temporary = exports['feather-inventory'].initiate().Inventory.GrantTemporaryAccess(src, invId, 60)
    if type(temporary) ~= 'table' or temporary.ok ~= true then
        devPrint('OpenSDB: Feather Inventory access failed:',
            tostring(type(temporary) == 'table' and (temporary.message or temporary.code) or 'invalid result'))
        NotifyClient(src, _U('error_unable_open_sdb') or 'Unable to open SDB right now.', 'error', 3500)
        return cb(false)
    end
    local opened = exports['feather-inventory'].initiate().Inventory.OpenInventory(src, invUuid, 'safety_deposit_box')
    if type(opened) ~= 'table' or opened.ok ~= true then
        devPrint('OpenSDB: Feather Inventory error:',
            tostring(type(opened) == 'table' and (opened.message or opened.code) or 'invalid result'))
        NotifyClient(src, _U('error_unable_open_sdb') or 'Unable to open SDB right now.', 'error', 3500)
        cb(false)
        return
    end
    cb(true)
end)

exports['feather-core']:RegisterRPC('Feather:Banks:Admin:OpenSDB', function(params, cb, src)
    if not IsBankAdmin or not IsBankAdmin(src) then
        NotifyClient(src, _U('admin_no_permission') or 'No permission', 'error', 3500)
        cb(false)
        return
    end

    local sdbId = NormalizeId(params and params.sdb_id)
    if not sdbId then
        NotifyClient(src, _U('error_invalid_sdb_id') or 'Invalid SDB id', 'error', 3500)
        cb(false)
        return
    end

    local row = MySQL.query.await(
        'SELECT `inventory_id`,`name`,`size` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1;',
        { sdbId }
    )
    row = row and row[1] or nil
    if not row then
        NotifyClient(src, _U('error_sdb_not_found') or 'SDB not found', 'error', 3500)
        cb(false)
        return
    end

    local invUuid, invId = ensureSDBInventoryRegistered(sdbId, row.inventory_id, row.name, row.size)
    if not row.inventory_id or row.inventory_id ~= invUuid then
        MySQL.query.await('UPDATE `bcc_safety_deposit_boxes` SET `inventory_id`=? WHERE `id`=?', { invUuid, sdbId })
    end
    local temporary = exports['feather-inventory'].initiate().Inventory.GrantTemporaryAccess(src, invId, 60)
    if type(temporary) ~= 'table' or temporary.ok ~= true then return cb(false) end
    local opened = exports['feather-inventory'].initiate().Inventory.OpenInventory(src, invUuid, 'safety_deposit_box_admin')
    if type(opened) ~= 'table' or opened.ok ~= true then return cb(false) end
    cb(true)
end)

exports['feather-core']:RegisterRPC('Feather:Banks:GetSDBDeleteInfo', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then
        cb(false)
        return
    end
    local char = user
    if not char then
        cb(false)
        return
    end

    local characterId = char.characterId
    local sdbId = NormalizeId(params and params.sdb_id)
    if not characterId or not sdbId then
        cb(false)
        return
    end

    local row = MySQL.single.await(
        'SELECT `id`,`name`,`bank_id`,`size`,`inventory_id` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1;',
        { sdbId }
    )
    if not row then
        cb(false)
        return
    end

    if not (IsSDBOwner(sdbId, characterId) or IsSDBAdmin(sdbId, characterId)) then
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, row.bank_id) then
        cb(false)
        return
    end

    local invId, itemCount, weaponCount = getSDBInventoryContentCounts(sdbId, row.inventory_id, row.name, row.size)
    cb(true, {
        inventory_id = invId,
        item_count = itemCount,
        weapon_count = weaponCount,
        hasItems = (itemCount + weaponCount) > 0
    })
end)

exports['feather-core']:RegisterRPC('Feather:Banks:DeleteSDB', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end

    local characterId = char.characterId
    local sdbId = NormalizeId(params and params.sdb_id)
    if not characterId or not sdbId then
        NotifyClient(src, _U('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end

    local row = MySQL.single.await(
        'SELECT `id`,`name`,`bank_id`,`size`,`inventory_id` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1;',
        { sdbId }
    )
    if not row then
        NotifyClient(src, _U('error_sdb_not_found'), 'error', 4000)
        cb(false)
        return
    end

    if not (IsSDBOwner(sdbId, characterId) or IsSDBAdmin(sdbId, characterId)) then
        NotifyClient(src, _U('error_no_permission'), 'error', 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, row.bank_id) then
        NotifyClient(src, _U('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local invUuid, invId = ensureSDBInventoryRegistered(sdbId, row.inventory_id, row.name, row.size)
    exports['feather-inventory'].initiate().Inventory.CloseInventory(src)
    local deleted = exports['feather-inventory'].initiate().Inventory.DeleteContainerIfEmpty(
        invId, 'bcc_safety_deposit_boxes', 'safety deposit box deleted')
    if type(deleted) ~= 'table' or deleted.ok ~= true then
        devPrint('DeleteSDB: Feather Inventory refused deletion:',
            tostring(type(deleted) == 'table' and (deleted.message or deleted.code) or 'invalid result'))
        NotifyClient(src, _U('failed_delete_sdb'), 'error', 4000)
        return cb(false)
    end

    MySQL.query.await('DELETE FROM `bcc_safety_deposit_boxes_access` WHERE `safety_deposit_box_id`=?', { sdbId })
    local affected = MySQL.update.await('DELETE FROM `bcc_safety_deposit_boxes` WHERE `id`=?', { sdbId })
    if not affected or affected < 1 then
        NotifyClient(src, _U('failed_delete_sdb'), 'error', 4000)
        cb(false)
        return
    end

    local lines = {
        '**Action:** `Safety Deposit Box Deleted`',
        '**SDB ID:** `' .. tostring(sdbId) .. '`',
        '**SDB Name:** `' .. tostring(row.name or 'Unknown') .. '`',
        '**Bank:** `' .. tostring(BccBanksInternal.getBankName(row.bank_id)) .. '`',
        '**Inventory ID:** `' .. tostring(invId) .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Safety Deposit Box Deleted', lines, 15158332)
    AddCharacterTransaction(characterId, 0, 'sdb - deleted', 'Deleted SDB #' .. tostring(sdbId) .. ' at ' .. tostring(BccBanksInternal.getBankName(row.bank_id)))
    NotifyClient(src, _U('sdb_deleted_notify'), 'success', 4000)
    cb(true)
end)

exports['feather-core']:RegisterRPC('Feather:Banks:GetSDBAccessList', function(params, cb, src)
    local sdbId = NormalizeId(params and params.sdb_id)
    if not sdbId then
        devPrint("GetSDBAccessList: invalid sdbId", params and params.sdb_id)
        NotifyClient(src, _U('error_invalid_sdb_id'), 'error', 4000)
        cb(false)
        return
    end

    local user = GetBankingContext(src)
    local char = user
    local requesterId = char and char.characterId
    if not requesterId or not (IsSDBOwner(sdbId, requesterId) or IsSDBAdmin(sdbId, requesterId)) then
        NotifyClient(src, _U('error_no_permission'), 'error', 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, getSDBBankId(sdbId)) then
        NotifyClient(src, _U('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local rawAccessList = GetSDBAccessList(sdbId)
    local accessList = {}

    devPrint("Raw DB access rows:", json.encode(rawAccessList))

    for _, row in ipairs(rawAccessList) do
        local firstName, lastName = GetCharacterName(row.character_id)
        firstName = firstName or 'Unknown'
        lastName = lastName or ''

        table.insert(accessList, {
            character_id = row.character_id,
            level = row.level,
            first_name = firstName,
            last_name = lastName,
        })

        devPrint("Access entry:", "[ID:", row.character_id, "]", firstName, lastName, "(Level", row.level, ")")
    end

    cb(true, { access = accessList })
end)

exports['feather-core']:RegisterRPC('Feather:Banks:AddSDBAccess', function(params, cb, src)
    devPrint("AddSDBAccess RPC called. src=", src, "params=", params)

    local user          = GetBankingContext(src)
    local requesterId
    do
        if not user then
            devPrint("AddSDBAccess: requester user not found")
            NotifyClient(src, _U('error_invalid_data_provided'), "error", 4000)
            cb(false)
            return
        end
        local ch = user
        if not ch then
            devPrint("AddSDBAccess: requester character not found")
            NotifyClient(src, _U('error_invalid_data_provided'), "error", 4000)
            cb(false)
            return
        end
        requesterId = ch.characterId
    end
    local sdbId     = NormalizeId(params and params.sdb_id)
    local otherCharId = NormalizeId(params and (params.character or params.user_src))
    local firstName = tostring((params and params.first_name) or ''):match('^%s*(.-)%s*$')
    local lastName  = tostring((params and params.last_name)  or ''):match('^%s*(.-)%s*$')
    local level     = tonumber(params and params.level)

    devPrint("AddSDBAccess: sdbId:", sdbId, "target:", otherCharId, "name:", firstName, lastName, "level:", level, "requesterId:", requesterId)

    if not requesterId or not sdbId or not IsValidAccessLevel(level)
        or (not otherCharId and (firstName == '' or lastName == '')) then
        devPrint("AddSDBAccess: Invalid input data.")
        NotifyClient(src, _U('error_invalid_data_provided'), "error", 4000)
        cb(false)
        return
    end

    -- Resolve name to character ID when an old-style character ID was not provided.
    if not otherCharId then
        otherCharId = GetCharacterByName(firstName, lastName)
        if not otherCharId then
            devPrint("AddSDBAccess: character not found for name:", firstName, lastName)
            NotifyClient(src, _U('error_target_character_not_found'), 'error', 4000)
            cb(false)
            return
        end
    else
        local found = exports['feather-core']:GetProvider('character-profile', nil, 1)
        local provider = found and found.ok == true and found.value and found.value.implementation or nil
        local profile = provider and provider.GetProfile and provider.GetProfile(tostring(otherCharId)) or nil
        if not profile or profile.ok ~= true then
            devPrint("AddSDBAccess: Feather character not found ->", otherCharId)
            NotifyClient(src, _U('error_target_character_not_found'), "error", 4000)
            cb(false)
            return
        end
    end

    -- Permission check
    if not (IsSDBAdmin(sdbId, requesterId) or IsSDBOwner(sdbId, requesterId)) then
        devPrint("AddSDBAccess: Source", requesterId, "is not admin or owner of SDB", sdbId)
        NotifyClient(src, _U('error_no_permission'), "error", 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, getSDBBankId(sdbId)) then
        NotifyClient(src, _U('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    -- Prevent giving access to self
    if requesterId == otherCharId then
        devPrint("AddSDBAccess: Attempted to give access to self.")
        NotifyClient(src, _U('warn_you_already_have_access_box'), "warning", 4000)
        cb(false)
        return
    end

    -- Check if they already have access
    local already = MySQL.query.await([[
        SELECT 1 FROM bcc_safety_deposit_boxes_access
        WHERE safety_deposit_box_id = ? AND character_id = ? LIMIT 1
    ]], { sdbId, otherCharId })

    if already and already[1] then
        devPrint("AddSDBAccess: Target already has access. sdbId=", sdbId, "charId=", otherCharId)
        NotifyClient(src, _U('warn_already_has_access_box'), "warning", 4000)
        cb(false)
        return
    end

    -- Insert access row
    local success = MySQL.query.await([[
        INSERT INTO bcc_safety_deposit_boxes_access (safety_deposit_box_id, character_id, level)
        VALUES (?, ?, ?)
    ]], { sdbId, otherCharId, level })

    devPrint("AddSDBAccess: Access granted. sdbId=", sdbId, "charId=", otherCharId, "level=", level)
    AddCharacterTransaction(requesterId, 0, 'sdb access - granted', 'Granted SDB #' .. tostring(sdbId) .. ' access to character #' .. tostring(otherCharId) .. ' level ' .. tostring(level))
    local sdbRow = BccBanksInternal.getSDBSummary(sdbId)
    local lines = {
        '**Action:** `Safety Deposit Box Access Granted`',
        '**SDB ID:** `' .. tostring(sdbId) .. '`',
        '**SDB Name:** `' .. tostring(sdbRow and sdbRow.name or 'Unknown') .. '`',
        '**Bank:** `' .. tostring(BccBanksInternal.getBankName(sdbRow and sdbRow.bank_id)) .. '`',
        '**Target Character:** `' .. tostring(BccBanksInternal.getCharacterNameById(otherCharId)) .. '`',
        '**Target Char ID:** `' .. tostring(otherCharId) .. '`',
        '**Access Level:** `' .. tostring(level) .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Safety Deposit Box Access Granted', lines, 5763719)
    NotifyClient(src, _U('success_access_granted'), "success", 4000)
    cb(true)
end)

exports['feather-core']:RegisterRPC('Feather:Banks:RemoveSDBAccess', function(params, cb, src)
    devPrint("RemoveSDBAccess RPC called. src=", src, "params=", params)

    local user = GetBankingContext(src)
    if not user then
        devPrint("RemoveSDBAccess: requester not found")
        NotifyClient(src, _U('error_invalid_input'), "error", 4000)
        cb(false)
        return
    end
    local requesterId = user.characterId

    local sdbId = NormalizeId(params and params.sdb_id)
    local targetCharId = tonumber(params and params.character)

    devPrint("Parsed inputs → sdbId:", sdbId, "target:", targetCharId, "requesterId:", requesterId)

    -- Validate input
    if not requesterId or not sdbId or not targetCharId then
        devPrint("RemoveSDBAccess: Invalid input data.")
        NotifyClient(src, _U('error_invalid_input'), "error", 4000)
        cb(false)
        return
    end

    -- Permission check
    if not (IsSDBAdmin(sdbId, requesterId) or IsSDBOwner(sdbId, requesterId)) then
        devPrint("RemoveSDBAccess: Character", requesterId, "is not admin or owner of SDB", sdbId)
        NotifyClient(src, _U('error_no_permission'), "error", 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, getSDBBankId(sdbId)) then
        NotifyClient(src, _U('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local result = RemoveSDBAccess(sdbId, targetCharId)

    if not result or result.status == false then
        devPrint("RemoveSDBAccess: Failed to remove access.")
        NotifyClient(src, _U('error_failed_remove_access'), "error", 4000)
        cb(false)
        return
    end

    NotifyClient(src, _U('success_access_removed'), "success", 4000)
    AddCharacterTransaction(requesterId, 0, 'sdb access - removed', 'Removed SDB #' .. tostring(sdbId) .. ' access from character #' .. tostring(targetCharId))
    local sdbRow = BccBanksInternal.getSDBSummary(sdbId)
    local lines = {
        '**Action:** `Safety Deposit Box Access Removed`',
        '**SDB ID:** `' .. tostring(sdbId) .. '`',
        '**SDB Name:** `' .. tostring(sdbRow and sdbRow.name or 'Unknown') .. '`',
        '**Bank:** `' .. tostring(BccBanksInternal.getBankName(sdbRow and sdbRow.bank_id)) .. '`',
        '**Target Character:** `' .. tostring(BccBanksInternal.getCharacterNameById(targetCharId)) .. '`',
        '**Target Char ID:** `' .. tostring(targetCharId) .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Safety Deposit Box Access Removed', lines, 15158332)
    cb(true)
end)
