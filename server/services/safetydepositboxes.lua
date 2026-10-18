local function getSDBBankId(sdbId)
    local row = DB.one('SELECT `bank_id` FROM `bcc_safety_deposit_boxes` WHERE `id` = ? LIMIT 1', sdbId)
    return row and row.bank_id or nil
end

-- Defined below; declared here so GetSDBs can pre-register the listed boxes.
local ensureSDBInventoryRegistered

exports['feather-core']:RegisterRPC('bcc-banks:GetSDBs', function(params, cb, src)
    -- Only the character id is needed: the in-memory Core session has it, while
    -- the banking context also loads both wallets from Economy.
    local session = exports['feather-core']:GetSessionContext(tonumber(src))
    if type(session) ~= 'table' or session.ok ~= true or type(session.value) ~= 'table' then
        devPrint('GetSDBs: no character session for src', src)
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_character_or_bank'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = session.value.characterId
    local bankId = NormalizeId(params and params.bank)

    if not characterId or not bankId then
        devPrint("GetSDBs: invalid inputs", "characterId=", characterId, "bankId=", bankId)
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_character_or_bank'), 'error', 4000)
        cb(false)
        return
    end

    if not IsPlayerNearBank(src, bankId) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local ok, rows = pcall(function()
        return GetUserSDBData(characterId, bankId)
    end)

    if not ok then
        devPrint("GetSDBs: DB error while fetching SDBs for", characterId, "bank", bankId)
        NotifyClient(src, Feather.Locale.translateUpper('error_db'), 'error', 4000)
        cb(false)
        return
    end

    cb(true, rows or {})

    -- Register the listed boxes with Feather Inventory while the player is still
    -- choosing, so the first Open Box does not pay for it.
    CreateThread(function()
        for _, box in ipairs(rows or {}) do
            local registered, failure = pcall(ensureSDBInventoryRegistered, box.id, box.inventory_id, box.name, box.size)
            if not registered then devPrint('GetSDBs: pre-registration failed for', box.id, failure) end
        end
    end)
end)

exports['feather-core']:RegisterRPC('bcc-banks:CreateSDB', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000) return cb(false) end
    local char = user
    if not char then NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000) return cb(false) end

    -- inputs
    local characterId = char.characterId          -- adjust if your framework uses a different name
    local name        = params and params.name
    local bank        = NormalizeId(params and params.bank)
    local sizeKey     = params and params.size
    local payWith     = (params and params.payWith) or "cash"  -- "cash" | "gold"

    if not characterId or not bank or not name or name == "" or not sizeKey then
        devPrint("CreateSDB invalid inputs", characterId, bank, name, sizeKey)
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000)
        return cb(false)
    end
    if not IsPlayerNearBank(src, bank) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        return cb(false)
    end
    name = tostring(name):sub(1, 64)

    if not AcquirePlayerFinancialLock(src) then
        NotifyClient(src, Feather.Locale.translateUpper('error_financial_operation_busy'), 'error', 4000)
        return cb(false)
    end
    local purchased = BankOps.PurchaseSDB(char, bank, name, sizeKey, payWith)
    if not purchased.ok then
        ReleasePlayerFinancialLock(src)
        devPrint("CreateSDB failed:", purchased.key)
        NotifyClient(src, Feather.Locale.translateUpper(purchased.key, tostring(purchased.balance or 0)), 'error', 4000)
        return cb(false)
    end
    local box, price = purchased.box, purchased.price

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

AddEventHandler('bcc-banks:DatabaseReady', function()
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

-- Boxes already registered with Feather Inventory during this run, keyed by box id.
-- Registration is idempotent but costs about nine sequential queries, so each box
-- registers once (again if its name or size differs) instead of on every open.
local registeredSDBInventories = {}

AddEventHandler('onResourceStart', function(resource)
    if resource == 'feather-inventory' then registeredSDBInventories = {} end
end)

local function forgetSDBInventory(boxId)
    registeredSDBInventories[tostring(boxId)] = nil
end

function ensureSDBInventoryRegistered(boxId, inventoryId, displayName, sizeKey)
    local invName = (displayName and displayName ~= '') and tostring(displayName) or 'Safety Deposit Box'
    local cached = registeredSDBInventories[tostring(boxId)]
    if cached and cached.invName == invName and cached.sizeKey == tostring(sizeKey) then
        return cached.uuid, cached.id, cached.invName, cached.sizeCfg
    end
    local sizeCfg = resolveSDBSizeConfig(sizeKey)
    local ignoreStacks = sizeCfg and sizeCfg.IgnoreItemLimit == true
    local blacklist = (sizeCfg and sizeCfg.BlacklistItems and #sizeCfg.BlacklistItems > 0) and sizeCfg.BlacklistItems or nil
    local limit = tonumber(sizeCfg and sizeCfg.MaxWeight) or 100

    local owner = DB.value('SELECT `owner_id` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1', boxId)
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
    registeredSDBInventories[tostring(boxId)] = {
        uuid = registered.value.uuid, id = registered.value.id,
        invName = invName, sizeKey = tostring(sizeKey), sizeCfg = sizeCfg
    }
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

-- Deletes box `sdbId` (its row from bcc_safety_deposit_boxes) when its Feather
-- Inventory container is empty, with its access rows. The caller checks permission
-- and proximity. Returns { ok, invId } or { ok = false, reason }.
function DeleteEmptySDB(sdbId, row)
    local _, invId = ensureSDBInventoryRegistered(sdbId, row.inventory_id, row.name, row.size)
    local deleted = exports['feather-inventory'].initiate().Inventory.DeleteContainerIfEmpty(
        invId, 'bcc_safety_deposit_boxes', 'safety deposit box deleted')
    if type(deleted) ~= 'table' or deleted.ok ~= true then
        local reason = type(deleted) == 'table' and (deleted.message or deleted.code
            or (deleted.error and deleted.error.code)) or 'invalid result'
        devPrint('DeleteSDB: Feather Inventory refused deletion:', tostring(reason))
        return { ok = false, reason = reason }
    end
    forgetSDBInventory(sdbId)
    DB.exec('DELETE FROM `bcc_safety_deposit_boxes_access` WHERE `safety_deposit_box_id`=?', sdbId)
    local affected = DB.exec('DELETE FROM `bcc_safety_deposit_boxes` WHERE `id`=?', sdbId)
    if not affected or affected < 1 then return { ok = false, reason = 'row_not_deleted' } end
    return { ok = true, invId = invId }
end

exports['feather-core']:RegisterRPC('bcc-banks:OpenSDB', function(params, cb, src)
    -- Opening a box needs only the character id. The in-memory Core session
    -- has it; the banking context (wallets) and the profile each cost queries.
    local session = exports['feather-core']:GetSessionContext(tonumber(src))
    if type(session) ~= 'table' or session.ok ~= true or type(session.value) ~= 'table' then
        devPrint('OpenSDB: no character session for src', src)
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = session.value.characterId
    local sdbId = NormalizeId(params and params.sdb_id)

    if not characterId or not sdbId then
        devPrint("OpenSDB: invalid inputs", "characterId=", characterId, "sdbId=", sdbId)
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end

    -- Box, this character's access and the branch in one query: each separate
    -- query waits for its own server tick.
    local row = DB.query([[
        SELECT s.`inventory_id`, s.`name`, s.`size`, s.`bank_id`,
               a.`safety_deposit_box_id` AS `access_box_id`,
               b.`id` AS `branch_id`, b.`x`, b.`y`, b.`z`,
               b.`hours_active`, b.`open_hour`, b.`close_hour`
        FROM `bcc_safety_deposit_boxes` s
        LEFT JOIN `bcc_safety_deposit_boxes_access` a
            ON a.`safety_deposit_box_id` = s.`id` AND a.`character_id` = ?
        LEFT JOIN `bcc_banks` b ON b.`id` = s.`bank_id`
        WHERE s.`id` = ? LIMIT 1;
    ]], characterId, sdbId)[1]
    if not row or row.access_box_id == nil then
        devPrint("OpenSDB: no access", "charId=", characterId, "sdbId=", sdbId)
        NotifyClient(src, Feather.Locale.translateUpper('error_insufficient_access'), 'error', 4000)
        cb(false)
        return
    end
    local branch = row.branch_id and {
        id = row.branch_id, x = row.x, y = row.y, z = row.z,
        hours_active = row.hours_active, open_hour = row.open_hour, close_hour = row.close_hour
    } or nil
    if not IsPlayerNearBankRow(src, branch) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local invUuid, invId = ensureSDBInventoryRegistered(sdbId, row.inventory_id, row.name, row.size)
    if not row.inventory_id or row.inventory_id ~= invUuid then
        DB.exec('UPDATE `bcc_safety_deposit_boxes` SET `inventory_id`=? WHERE `id`=?', invUuid, sdbId)
        row.inventory_id = invUuid
    end

    devPrint('OpenSDB: attempting Feather Inventory open for', invUuid, 'src=', src)
    local temporary = exports['feather-inventory'].initiate().Inventory.GrantTemporaryAccess(src, invId, 60)
    if type(temporary) ~= 'table' or temporary.ok ~= true then
        devPrint('OpenSDB: Feather Inventory access failed:',
            tostring(type(temporary) == 'table' and (temporary.message or temporary.code) or 'invalid result'))
        NotifyClient(src, Feather.Locale.translateUpper('error_unable_open_sdb') or 'Unable to open SDB right now.', 'error', 3500)
        return cb(false)
    end
    local opened = exports['feather-inventory'].initiate().Inventory.OpenInventory(src, invUuid, 'safety_deposit_box')
    if type(opened) ~= 'table' or opened.ok ~= true then
        devPrint('OpenSDB: Feather Inventory error:',
            tostring(type(opened) == 'table' and (opened.message or opened.code) or 'invalid result'))
        NotifyClient(src, Feather.Locale.translateUpper('error_unable_open_sdb') or 'Unable to open SDB right now.', 'error', 3500)
        cb(false)
        return
    end
    cb(true)
end)

exports['feather-core']:RegisterRPC('bcc-banks:Admin:OpenSDB', function(params, cb, src)
    if not IsBankAdmin or not IsBankAdmin(src) then
        NotifyClient(src, Feather.Locale.translateUpper('admin_no_permission') or 'No permission', 'error', 3500)
        cb(false)
        return
    end

    local sdbId = NormalizeId(params and params.sdb_id)
    if not sdbId then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_sdb_id') or 'Invalid SDB id', 'error', 3500)
        cb(false)
        return
    end

    local row = DB.query(
        'SELECT `inventory_id`,`name`,`size` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1;',
        sdbId
    )
    row = row and row[1] or nil
    if not row then
        NotifyClient(src, Feather.Locale.translateUpper('error_sdb_not_found') or 'SDB not found', 'error', 3500)
        cb(false)
        return
    end

    local invUuid, invId = ensureSDBInventoryRegistered(sdbId, row.inventory_id, row.name, row.size)
    if not row.inventory_id or row.inventory_id ~= invUuid then
        DB.exec('UPDATE `bcc_safety_deposit_boxes` SET `inventory_id`=? WHERE `id`=?', invUuid, sdbId)
    end
    local temporary = exports['feather-inventory'].initiate().Inventory.GrantTemporaryAccess(src, invId, 60)
    if type(temporary) ~= 'table' or temporary.ok ~= true then return cb(false) end
    local opened = exports['feather-inventory'].initiate().Inventory.OpenInventory(src, invUuid, 'safety_deposit_box_admin')
    if type(opened) ~= 'table' or opened.ok ~= true then return cb(false) end
    -- Privileged inspection of a customer's box.
    BankAuditStaff(src, 'Safety Deposit Box Opened By Staff', { { 'SDB ID', sdbId }, { 'SDB Name', row.name } })
    cb(true)
end)

exports['feather-core']:RegisterRPC('bcc-banks:GetSDBDeleteInfo', function(params, cb, src)
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

    local row = DB.one(
        'SELECT `id`,`name`,`bank_id`,`size`,`inventory_id` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1;',
        sdbId
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

exports['feather-core']:RegisterRPC('bcc-banks:DeleteSDB', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end

    local characterId = char.characterId
    local sdbId = NormalizeId(params and params.sdb_id)
    if not characterId or not sdbId then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data'), 'error', 4000)
        cb(false)
        return
    end

    local row = DB.one(
        'SELECT `id`,`name`,`bank_id`,`size`,`inventory_id` FROM `bcc_safety_deposit_boxes` WHERE `id`=? LIMIT 1;',
        sdbId
    )
    if not row then
        NotifyClient(src, Feather.Locale.translateUpper('error_sdb_not_found'), 'error', 4000)
        cb(false)
        return
    end

    if not (IsSDBOwner(sdbId, characterId) or IsSDBAdmin(sdbId, characterId)) then
        NotifyClient(src, Feather.Locale.translateUpper('error_no_permission'), 'error', 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, row.bank_id) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    exports['feather-inventory'].initiate().Inventory.CloseInventory(src)
    local deleted = DeleteEmptySDB(sdbId, row)
    if not deleted.ok then
        NotifyClient(src, Feather.Locale.translateUpper('failed_delete_sdb'), 'error', 4000)
        return cb(false)
    end
    local invId = deleted.invId

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
    NotifyClient(src, Feather.Locale.translateUpper('sdb_deleted_notify'), 'success', 4000)
    cb(true)
end)

exports['feather-core']:RegisterRPC('bcc-banks:GetSDBAccessList', function(params, cb, src)
    local sdbId = NormalizeId(params and params.sdb_id)
    if not sdbId then
        devPrint("GetSDBAccessList: invalid sdbId", params and params.sdb_id)
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_sdb_id'), 'error', 4000)
        cb(false)
        return
    end

    local user = GetBankingContext(src)
    local char = user
    local requesterId = char and char.characterId
    if not requesterId or not (IsSDBOwner(sdbId, requesterId) or IsSDBAdmin(sdbId, requesterId)) then
        NotifyClient(src, Feather.Locale.translateUpper('error_no_permission'), 'error', 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, getSDBBankId(sdbId)) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
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

exports['feather-core']:RegisterRPC('bcc-banks:AddSDBAccess', function(params, cb, src)
    devPrint("AddSDBAccess RPC called. src=", src, "params=", params)

    local user          = GetBankingContext(src)
    local requesterId
    do
        if not user then
            devPrint("AddSDBAccess: requester user not found")
            NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data_provided'), "error", 4000)
            cb(false)
            return
        end
        local ch = user
        if not ch then
            devPrint("AddSDBAccess: requester character not found")
            NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data_provided'), "error", 4000)
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
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_data_provided'), "error", 4000)
        cb(false)
        return
    end

    -- Resolve name to character ID when an old-style character ID was not provided.
    if not otherCharId then
        otherCharId = GetCharacterByName(firstName, lastName)
        if not otherCharId then
            devPrint("AddSDBAccess: character not found for name:", firstName, lastName)
            NotifyClient(src, Feather.Locale.translateUpper('error_target_character_not_found'), 'error', 4000)
            cb(false)
            return
        end
    else
        local found = exports['feather-core']:GetProvider('character-profile', nil, 1)
        local provider = found and found.ok == true and found.value and found.value.implementation or nil
        local profile = provider and provider.GetProfile and provider.GetProfile(tostring(otherCharId)) or nil
        if not profile or profile.ok ~= true then
            devPrint("AddSDBAccess: Feather character not found ->", otherCharId)
            NotifyClient(src, Feather.Locale.translateUpper('error_target_character_not_found'), "error", 4000)
            cb(false)
            return
        end
    end

    -- Permission check
    if not (IsSDBAdmin(sdbId, requesterId) or IsSDBOwner(sdbId, requesterId)) then
        devPrint("AddSDBAccess: Source", requesterId, "is not admin or owner of SDB", sdbId)
        NotifyClient(src, Feather.Locale.translateUpper('error_no_permission'), "error", 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, getSDBBankId(sdbId)) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    -- Prevent giving access to self
    if requesterId == otherCharId then
        devPrint("AddSDBAccess: Attempted to give access to self.")
        NotifyClient(src, Feather.Locale.translateUpper('warn_you_already_have_access_box'), "warning", 4000)
        cb(false)
        return
    end

    -- Check if they already have access
    local already = DB.query([[
        SELECT 1 FROM bcc_safety_deposit_boxes_access
        WHERE safety_deposit_box_id = ? AND character_id = ? LIMIT 1
    ]], sdbId, otherCharId)

    if already and already[1] then
        devPrint("AddSDBAccess: Target already has access. sdbId=", sdbId, "charId=", otherCharId)
        NotifyClient(src, Feather.Locale.translateUpper('warn_already_has_access_box'), "warning", 4000)
        cb(false)
        return
    end

    -- Insert access row
    local success = DB.exec([[
        INSERT INTO bcc_safety_deposit_boxes_access (safety_deposit_box_id, character_id, level)
        VALUES (?, ?, ?)
    ]], sdbId, otherCharId, level)

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
    NotifyClient(src, Feather.Locale.translateUpper('success_access_granted'), "success", 4000)
    cb(true)
end)

exports['feather-core']:RegisterRPC('bcc-banks:RemoveSDBAccess', function(params, cb, src)
    devPrint("RemoveSDBAccess RPC called. src=", src, "params=", params)

    local user = GetBankingContext(src)
    if not user then
        devPrint("RemoveSDBAccess: requester not found")
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_input'), "error", 4000)
        cb(false)
        return
    end
    local requesterId = user.characterId

    local sdbId = NormalizeId(params and params.sdb_id)
    local targetCharId = NormalizeId(params and params.character)

    devPrint("Parsed inputs → sdbId:", sdbId, "target:", targetCharId, "requesterId:", requesterId)

    -- Validate input
    if not requesterId or not sdbId or not targetCharId then
        devPrint("RemoveSDBAccess: Invalid input data.")
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_input'), "error", 4000)
        cb(false)
        return
    end

    -- Permission check
    if not (IsSDBAdmin(sdbId, requesterId) or IsSDBOwner(sdbId, requesterId)) then
        devPrint("RemoveSDBAccess: Character", requesterId, "is not admin or owner of SDB", sdbId)
        NotifyClient(src, Feather.Locale.translateUpper('error_no_permission'), "error", 4000)
        cb(false)
        return
    end
    if not IsPlayerNearBank(src, getSDBBankId(sdbId)) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local result = RemoveSDBAccess(sdbId, targetCharId)

    if not result or result.status == false then
        devPrint("RemoveSDBAccess: Failed to remove access.")
        NotifyClient(src, Feather.Locale.translateUpper('error_failed_remove_access'), "error", 4000)
        cb(false)
        return
    end

    NotifyClient(src, Feather.Locale.translateUpper('success_access_removed'), "success", 4000)
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
