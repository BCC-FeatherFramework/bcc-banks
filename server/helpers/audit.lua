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
    -- Session and profile only: the banking context would also load both wallets.
    local identity = src and GetFeatherCharacter and GetFeatherCharacter(src) or nil
    if not identity then return ctx end
    ctx.charId = identity.characterId
    ctx.accountId = identity.accountId
    ctx.firstName = identity.profile and identity.profile.firstName or ctx.firstName
    ctx.lastName = identity.profile and identity.profile.lastName or ctx.lastName
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
    -- Structured actor for the feather-audit event built by QueueBankAuditLog.
    lines.actor = {
        characterId = ctx.charId, accountId = ctx.accountId,
        name = ((ctx.firstName or '') .. ' ' .. (ctx.lastName or '')):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    }
    lines[#lines + 1] = '**Player:** `' .. tostring(ctx.playerName or 'Unknown') .. '`'
    lines[#lines + 1] = '**Character:** `' .. tostring(((ctx.firstName or 'Unknown') .. ' ' .. (ctx.lastName or '')):gsub('%s+', ' '):gsub('%s+$', '')) .. '`'
    lines[#lines + 1] = '**Char ID:** `' .. tostring(ctx.charId or 'Unknown') .. '`'
    lines[#lines + 1] = '**Source:** `' .. tostring(src or 'Unknown') .. '`'
end

-- feather-audit producer: every QueueBankAuditLog call becomes one
-- bank.action.recorded event (schema in feather-audit schemas/banks), written to
-- bcc_banks_audit_outbox and delivered by the publisher below. Same pattern as
-- feather-admin's producer. The event is written right after the bank action,
-- not in the same database transaction (most bank actions are feather-economy
-- transfers, which bcc-banks cannot join), so a crash between the two loses it.

BankAudit = {}
local publishing = false

local function safe(value, maximum)
    if value == nil then return nil end
    local text = tostring(value):gsub('[%c]', ' ')
    text = text:gsub('https?://[^%s]+', '[URL removed]')
    return text:sub(1, maximum)
end

-- 'Loan Repayment' -> 'loan_repayment'
local function actionKey(title)
    local key = tostring(title or 'bank action'):lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    return key ~= '' and key:sub(1, 100) or 'bank_action'
end

-- '**Amount:** `$5`' lines -> 'Amount: $5; ...', actor lines left out (they are structured).
local function detailsOf(lines)
    local parts = {}
    for _, line in ipairs(lines or {}) do
        local text = tostring(line):gsub('%*%*', ''):gsub('`', '')
        if not text:match('^Player:') and not text:match('^Character:') and not text:match('^Char ID:')
            and not text:match('^Source:') then
            parts[#parts + 1] = text
        end
    end
    return table.concat(parts, '; ')
end

function BankAudit.BuildEvent(eventId, title, lines)
    local actor = type(lines) == 'table' and lines.actor or {}
    local who = actor.characterId and { type = 'character', id = actor.characterId,
        characterId = actor.characterId, accountId = actor.accountId }
        or { type = 'system', id = 'bcc-banks', resource = 'bcc-banks' }
    local action = actionKey(title)
    return { contractVersion = 1, eventId = 'bank:' .. eventId,
        eventType = 'bank.action.recorded', eventVersion = 1,
        occurredAt = os.date('!%Y-%m-%dT%H:%M:%SZ'), sourceResource = 'bcc-banks',
        sourceInstance = (Config.Audit and Config.Audit.sourceInstance) or 'default',
        actor = who, targets = { { type = 'resource', id = 'bcc-banks', role = 'subject' } }, references = {},
        correlationId = 'bank:' .. eventId, result = 'success', reasonCode = 'bank_' .. action,
        summary = safe(title, 128) or 'Bank action', sensitivityClass = 'internal', retentionClass = 'financial',
        context = { action = action, details = safe(detailsOf(lines), 500) ~= '' and safe(detailsOf(lines), 500) or 'none',
            actor_name = safe(actor.name, 128), actor_character_id = actor.characterId } }
end

-- Writes the event to the outbox. Returns its event id, or nil when no durable
-- record could be made (printed for operators).
function QueueBankAuditLog(title, lines, color)
    if not BccBanksDatabaseReady then return nil end
    local called, eventId = pcall(function()
        local event = BankAudit.BuildEvent(DB.value('SELECT UUID()'), title, lines)
        DB.insert([[INSERT INTO `bcc_banks_audit_outbox` (`event_id`, `payload`, `state`, `next_attempt`)
            VALUES (?, ?, 'pending', 0)]], event.eventId, json.encode(event))
        return event.eventId
    end)
    if not called then
        print('[bcc-banks] AUDIT QUEUE FAILED action=' .. actionKey(title) .. ': ' .. tostring(eventId))
        return nil
    end
    return eventId
end

-- Leases a batch, ingests each event and records the outcome (feather-admin's rules:
-- accepted/duplicate delivered, quarantined kept, anything else retried with backoff).
function BankAudit.PublishOnce()
    if publishing or not BccBanksDatabaseReady or GetResourceState('feather-audit') ~= 'started' then return end
    publishing = true
    local settings = Config.Audit or {}
    local called, problem = pcall(function()
        local owner, now = DB.value('SELECT UUID()'), os.time()
        local rows
        local committed = DB.transaction(function(tx)
            rows = tx.query([[SELECT `event_id` AS eventId, `payload`, `attempt_count` AS attemptCount
                FROM `bcc_banks_audit_outbox`
                WHERE (`state` = 'pending' AND `next_attempt` <= ?) OR (`state` = 'leased' AND `lease_until` <= ?)
                ORDER BY `created_at`, `event_id` LIMIT ? FOR UPDATE]], now, now, settings.batchSize or 25) or {}
            for _, row in ipairs(rows) do
                tx.exec([[UPDATE `bcc_banks_audit_outbox` SET `state` = 'leased', `lease_owner` = ?, `lease_until` = ?,
                    `attempt_count` = `attempt_count` + 1 WHERE `event_id` = ?]], owner, now + 60, row.eventId)
            end
            return true
        end)
        if committed ~= true then error('outbox lease rejected') end
        for _, row in ipairs(rows) do
            local decoded, event = pcall(json.decode, row.payload)
            local transported, response = false, nil
            if decoded and type(event) == 'table' then
                transported, response = pcall(function() return exports['feather-audit']:Ingest(event) end)
            end
            if transported and type(response) == 'table' and type(response.auditEventId) == 'string'
                and (response.result == 'accepted' or response.result == 'duplicate') then
                DB.exec([[UPDATE `bcc_banks_audit_outbox` SET `state` = 'delivered', `audit_event_id` = ?,
                    `lease_owner` = NULL, `lease_until` = NULL, `last_code` = ?, `delivered_at` = NOW()
                    WHERE `event_id` = ? AND `state` = 'leased' AND `lease_owner` = ?]],
                    response.auditEventId, response.result, row.eventId, owner)
            elseif not decoded or type(event) ~= 'table'
                or (transported and type(response) == 'table' and response.result == 'quarantined') then
                DB.exec([[UPDATE `bcc_banks_audit_outbox` SET `state` = 'quarantined', `last_code` = ?,
                    `lease_owner` = NULL, `lease_until` = NULL WHERE `event_id` = ? AND `state` = 'leased' AND `lease_owner` = ?]],
                    (not decoded or type(event) ~= 'table') and 'invalid_payload' or response.code, row.eventId, owner)
                print('[bcc-banks] audit outbox quarantined eventId=' .. row.eventId)
            else
                local delay = math.min(300, 2 ^ math.min(8, tonumber(row.attemptCount) or 0))
                DB.exec([[UPDATE `bcc_banks_audit_outbox` SET `state` = 'pending', `next_attempt` = ?, `last_code` = ?,
                    `lease_owner` = NULL, `lease_until` = NULL WHERE `event_id` = ? AND `state` = 'leased' AND `lease_owner` = ?]],
                    now + delay, transported and type(response) == 'table' and response.code or 'transport_failure',
                    row.eventId, owner)
            end
        end
    end)
    publishing = false
    if not called then print('[bcc-banks] audit publisher failed; leases are retried after expiry: ' .. tostring(problem)) end
    return called
end

CreateThread(function()
    while true do
        Wait((Config.Audit and Config.Audit.pollMilliseconds) or 5000)
        BankAudit.PublishOnce()
    end
end)

-- Console: BanksAuditOutboxStatus
RegisterCommand('BanksAuditOutboxStatus', function(source)
    if source ~= 0 then return end
    for _, row in ipairs(DB.query('SELECT `state`, COUNT(*) AS total FROM `bcc_banks_audit_outbox` GROUP BY `state`') or {}) do
        print(('[BanksAuditOutboxStatus] state=%s count=%s'):format(row.state, row.total))
    end
end, true)

BccBanksInternal.getPlayerLogContext = getPlayerLogContext
BccBanksInternal.getCharacterNameById = getCharacterNameById
BccBanksInternal.getBankName = getBankName
BccBanksInternal.getAccountSummary = getAccountSummary
BccBanksInternal.getSDBSummary = getSDBSummary
BccBanksInternal.appendActorLines = appendActorLines
