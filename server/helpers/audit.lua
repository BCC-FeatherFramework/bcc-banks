BccBanksInternal = BccBanksInternal or {}

local function getCharacterRecord(characterId)
    local id = characterId and tostring(characterId) or nil
    if not id then return nil end
    local found = exports['feather-core']:GetProvider('character-profile', nil, 1)
    local provider = found and found.ok == true and found.value and found.value.implementation or nil
    local result = provider and provider.GetProfile and provider.GetProfile(id) or nil
    local profile = result and result.ok == true and result.value or nil
    return profile and { firstname = profile.firstName, lastname = profile.lastName } or nil
end

local function getPlayerLogContext(src)
    local ctx = {
        src = src,
        playerName = GetPlayerName(src) or ('src ' .. tostring(src)),
        charId = nil,
        firstName = 'Unknown',
        lastName = '',
    }

    if not GetBankingContext or not src then
        return ctx
    end

    local user = GetBankingContext(src)
    local char = user or nil
    if not char then
        return ctx
    end

    ctx.charId = tonumber(char.characterId) or char.characterId
    ctx.firstName = char.firstName or ctx.firstName
    ctx.lastName = char.lastName or ctx.lastName

    if (ctx.firstName == 'Unknown' or ctx.firstName == nil) and ctx.charId then
        local row = getCharacterRecord(ctx.charId)
        if row then
            ctx.firstName = row.firstname or ctx.firstName
            ctx.lastName = row.lastname or ctx.lastName
        end
    end

    return ctx
end

local function getCharacterNameById(characterId)
    local row = getCharacterRecord(characterId)
    if not row then
        return 'Unknown'
    end
    local fullName = ((row.firstname or '') .. ' ' .. (row.lastname or '')):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if fullName == '' then
        return 'Unknown'
    end
    return fullName
end

local function getBankName(bankId)
    if bankId == nil or bankId == '' then return 'Unknown' end
    local rows = DB.query('SELECT `name` FROM `bcc_banks` WHERE `id` = ? LIMIT 1', tostring(bankId))
    local row = rows and rows[1] or nil
    return (row and row.name) or tostring(bankId)
end

local function getAccountSummary(accountId)
    if accountId == nil or accountId == '' then return nil end
    local rows = DB.query(
        'SELECT `id`, `name`, `account_number`, `bank_id`, `owner_id`, `cash`, `gold` FROM `bcc_accounts` WHERE `id` = ? LIMIT 1',
        tostring(accountId)
    )
    return rows and rows[1] or nil
end

local function getSDBSummary(sdbId)
    if sdbId == nil or sdbId == '' then return nil end
    local rows = DB.query(
        'SELECT `id`, `name`, `bank_id`, `owner_id`, `size` FROM `bcc_safety_deposit_boxes` WHERE `id` = ? LIMIT 1',
        tostring(sdbId)
    )
    return rows and rows[1] or nil
end

local function appendActorLines(lines, src)
    local ctx = getPlayerLogContext(src)
    lines[#lines + 1] = '**Player:** `' .. tostring(ctx.playerName or 'Unknown') .. '`'
    lines[#lines + 1] = '**Character:** `' .. tostring(((ctx.firstName or 'Unknown') .. ' ' .. (ctx.lastName or '')):gsub('%s+', ' '):gsub('%s+$', '')) .. '`'
    lines[#lines + 1] = '**Char ID:** `' .. tostring(ctx.charId or 'Unknown') .. '`'
    lines[#lines + 1] = '**Source:** `' .. tostring(src or 'Unknown') .. '`'
end

function QueueBankAuditLog(title, lines, color)
    -- The temporary economy owns its durable outbox. General bank event schemas
    -- will be connected when the shared feather-audit producer contract ships.
    return false
end

BccBanksInternal.getPlayerLogContext = getPlayerLogContext
BccBanksInternal.getCharacterNameById = getCharacterNameById
BccBanksInternal.getBankName = getBankName
BccBanksInternal.getAccountSummary = getAccountSummary
BccBanksInternal.getSDBSummary = getSDBSummary
BccBanksInternal.appendActorLines = appendActorLines
