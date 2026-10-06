-- One-time move of bcc-banks money from the retired temporary economy tables
-- (bcc_banks_temp_economy_*) into the Feather Economy ledger.
--
--   BccBanksEconomyMigrationReport      read-only: shows the plan and the current state
--   BccBanksEconomyMigrate confirm      writes: issues the balances and relinks accounts
--
-- Both are server-console commands. The migration is idempotent and resumable:
-- every balance is issued under a fixed key derived from the temporary account, so
-- a repeat returns the original transaction and never issues twice. The temporary
-- tables are never modified or dropped by this tool; they stay as the record.

BanksEconomyMigration = {}

local TEMP = 'bcc_banks_temp_economy_accounts'
local MIGRATION_TABLE = 'bcc_banks_economy_migration'
local REASON = 'bank.migration.import'

local function tableExists(name)
    local row = DB.one('SELECT COUNT(*) AS n FROM information_schema.TABLES '
        .. 'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', name)
    return row and tonumber(row.n) == 1
end

-- Pure planning step. Inputs are plain rows, so it can be tested without a database.
--   temp:     { accountId, ownerType, ownerId, accountType, currency, status, amount }
--   bcc:      { id, dollarsAccountId, goldAccountId }
--   migrated: { [tempAccountId] = { status = 'migrated', realAccountId, transactionId, bccAccountId } }
function BanksEconomyMigration.BuildPlan(temp, bcc, migrated)
    local items, warnings, ownerByTemp = {}, {}, {}
    local supply = 0
    for _, account in ipairs(bcc) do
        if account.dollarsAccountId then ownerByTemp[account.dollarsAccountId] = account.id end
        if account.goldAccountId then ownerByTemp[account.goldAccountId] = account.id end
    end
    for _, account in ipairs(temp) do
        supply = supply + account.amount
        if account.ownerType == 'character' and (account.accountType == 'bank' or account.accountType == 'wallet') then
            local done = migrated and migrated[account.accountId]
            local item = {
                tempAccountId = account.accountId, kind = account.accountType, currency = account.currency,
                ownerCharacterId = account.ownerId, amount = account.amount, status = account.status,
                -- A finished item keeps the link recorded when it was migrated, because
                -- bcc_accounts no longer points at the temporary account afterwards.
                bccAccountId = account.accountType == 'bank'
                    and (ownerByTemp[account.accountId] or (done and done.bccAccountId)) or nil
            }
            item.state = done and done.status or 'pending'
            item.realAccountId = done and done.realAccountId or nil
            if item.state == 'migrated' then
                items[#items + 1] = item
            elseif account.status ~= 'open' and account.amount ~= 0 then
                warnings[#warnings + 1] = ('closed temp account %s still holds %d'):format(account.accountId, account.amount)
                item.blocked = true
                items[#items + 1] = item
            else
                if account.accountType == 'bank' and not item.bccAccountId then
                    warnings[#warnings + 1] = ('temp bank account %s is not linked to any bcc_accounts row (amount %d)')
                        :format(account.accountId, account.amount)
                    if account.amount ~= 0 then item.blocked = true end
                end
                if account.amount < 0 then
                    warnings[#warnings + 1] = ('temp account %s has a negative balance %d'):format(account.accountId, account.amount)
                    item.blocked = true
                end
                items[#items + 1] = item
            end
        end
    end
    table.sort(items, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        if a.currency ~= b.currency then return a.currency < b.currency end
        return a.tempAccountId < b.tempAccountId
    end)
    local totals = {}
    for _, item in ipairs(items) do
        local key = item.currency
        totals[key] = totals[key] or { planned = 0, migrated = 0 }
        totals[key].planned = totals[key].planned + item.amount
        if item.state == 'migrated' then totals[key].migrated = totals[key].migrated + item.amount end
    end
    return { items = items, warnings = warnings, totals = totals, supplyBalanced = supply == 0 }
end

local function loadInputs()
    if not tableExists(TEMP) then return nil end
    local rows = DB.query([[SELECT a.account_id, a.owner_type, a.owner_id, a.account_type,
            a.currency_code, a.status, b.posted_amount
        FROM bcc_banks_temp_economy_accounts a
        JOIN bcc_banks_temp_economy_balances b ON b.account_id = a.account_id]]) or {}
    local temp = {}
    for _, row in ipairs(rows) do
        temp[#temp + 1] = { accountId = row.account_id, ownerType = row.owner_type, ownerId = row.owner_id,
            accountType = row.account_type, currency = row.currency_code, status = row.status,
            amount = tonumber(row.posted_amount) or 0 }
    end
    local bccRows = DB.query('SELECT id, dollars_account_id, gold_account_id FROM bcc_accounts') or {}
    local bcc = {}
    for _, row in ipairs(bccRows) do
        bcc[#bcc + 1] = { id = row.id, dollarsAccountId = row.dollars_account_id, goldAccountId = row.gold_account_id }
    end
    local migrated = {}
    if tableExists(MIGRATION_TABLE) then
        for _, row in ipairs(DB.query('SELECT temp_account_id, status, real_account_id, transaction_id, bcc_account_id FROM '
            .. MIGRATION_TABLE) or {}) do
            migrated[row.temp_account_id] = { status = row.status, realAccountId = row.real_account_id,
                transactionId = row.transaction_id, bccAccountId = row.bcc_account_id }
        end
    end
    return temp, bcc, migrated
end

local function money(units) return ('%.2f'):format((tonumber(units) or 0) / 100) end

local function printPlan(plan)
    for _, item in ipairs(plan.items) do
        print(('  [%s] %-6s %-7s %12s  owner=%s%s%s'):format(item.state, item.kind, item.currency,
            money(item.amount), item.ownerCharacterId, item.bccAccountId and ('  bccAccount=' .. item.bccAccountId) or '',
            item.blocked and '  BLOCKED' or ''))
    end
    for currency, total in pairs(plan.totals) do
        print(('  total %-7s planned=%s migrated=%s'):format(currency, money(total.planned), money(total.migrated)))
    end
    print(('  temporary supply balanced: %s'):format(tostring(plan.supplyBalanced)))
    for _, warning in ipairs(plan.warnings) do print('  WARNING: ' .. warning) end
end

function BanksEconomyMigration.Pending()
    local temp, bcc, migrated = loadInputs()
    if not temp then return 0 end
    local plan = BanksEconomyMigration.BuildPlan(temp, bcc, migrated)
    local pending = 0
    for _, item in ipairs(plan.items) do
        if item.state ~= 'migrated' and (item.amount ~= 0 or item.kind == 'bank') then pending = pending + 1 end
    end
    return pending
end

local function ensureMigrationTable()
    DB.exec([[CREATE TABLE IF NOT EXISTS bcc_banks_economy_migration (
        temp_account_id CHAR(36) NOT NULL,
        kind VARCHAR(16) NOT NULL,
        currency VARCHAR(32) NOT NULL,
        owner_character_id CHAR(36) NOT NULL,
        bcc_account_id VARCHAR(36) NULL,
        real_account_id CHAR(36) NULL,
        amount BIGINT NOT NULL,
        status VARCHAR(16) NOT NULL DEFAULT 'pending',
        transaction_id CHAR(36) NULL,
        migrated_at TIMESTAMP NULL,
        PRIMARY KEY (temp_account_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
end

-- Resolves (creating if needed) the Economy account an item moves into.
local function realAccountFor(item)
    if item.kind == 'bank' then
        local account = BanksEconomy.CreateAccount({ ownerType = 'character', ownerId = item.ownerCharacterId,
            accountType = 'bank', currency = item.currency, referenceId = item.bccAccountId })
        if not account.ok then return nil, account end
        return account.value
    end
    local wallets = BanksEconomy.EnsureCharacterWallets({ characterId = item.ownerCharacterId })
    if not wallets.ok then return nil, wallets end
    return wallets.value[item.currency]
end

local function migrateItem(item)
    local account, failure = realAccountFor(item)
    if not account then return false, failure and failure.code or 'account_unavailable' end
    local transactionId
    if item.amount > 0 then
        local issued = BanksEconomy.Issue({ toAccountId = account.accountId, currency = item.currency,
            amount = item.amount, reasonCode = REASON, referenceType = 'bcc_banks_temp_account',
            referenceId = item.tempAccountId, idempotencyKey = 'banks:migrate:' .. item.tempAccountId })
        if not issued.ok then return false, issued.code end
        transactionId = issued.value.transactionId
        local balance = BanksEconomy.GetBalance({ accountId = account.accountId })
        if not balance.ok or (balance.value.postedAmount or 0) < item.amount then
            return false, 'verification_failed'
        end
    end
    DB.exec([[INSERT INTO bcc_banks_economy_migration
        (temp_account_id, kind, currency, owner_character_id, bcc_account_id, real_account_id, amount,
         status, transaction_id, migrated_at)
        VALUES (?,?,?,?,?,?,?,'migrated',?,NOW())
        ON DUPLICATE KEY UPDATE real_account_id = VALUES(real_account_id), status = 'migrated',
            transaction_id = VALUES(transaction_id), migrated_at = NOW()]],
        item.tempAccountId, item.kind, item.currency, item.ownerCharacterId, item.bccAccountId,
          account.accountId, item.amount, transactionId)
    return true, account.accountId
end

-- Points a bcc_accounts row at its Economy accounts, only when it still points at
-- the temporary ones, so a repeat run never overwrites a finished link.
local function relink(bcc, plan)
    local linked = 0
    for _, account in ipairs(bcc) do
        local mapping = {}
        for _, item in ipairs(plan.items) do
            if item.kind == 'bank' and item.bccAccountId == account.id and item.realAccountId then
                mapping[item.currency] = item.realAccountId
            end
        end
        if mapping.dollars and mapping.gold
            and (account.dollarsAccountId ~= mapping.dollars or account.goldAccountId ~= mapping.gold) then
            local changed = DB.exec([[UPDATE bcc_accounts SET dollars_account_id = ?, gold_account_id = ?
                WHERE id = ? AND dollars_account_id <=> ? AND gold_account_id <=> ?]],
                mapping.dollars, mapping.gold, account.id, account.dollarsAccountId, account.goldAccountId)
            if tonumber(changed) == 1 then linked = linked + 1 end
        end
    end
    return linked
end

function BanksEconomyMigration.Run()
    local ready = BanksEconomy.AwaitReady(15000)
    if not ready.ok then return false, ready.code end
    local temp, bcc, migrated = loadInputs()
    if not temp then return true, 'nothing_to_migrate' end
    ensureMigrationTable()
    local plan = BanksEconomyMigration.BuildPlan(temp, bcc, migrated)
    for _, item in ipairs(plan.items) do
        if item.blocked then return false, 'plan_blocked' end
    end
    if not plan.supplyBalanced then return false, 'temporary_supply_unbalanced' end
    for _, item in ipairs(plan.items) do
        if item.state ~= 'migrated' and (item.amount ~= 0 or item.kind == 'bank') then
            local done, detail = migrateItem(item)
            if not done then return false, ('%s (%s)'):format(tostring(detail), item.tempAccountId) end
            item.state, item.realAccountId = 'migrated', detail
        end
    end
    -- Re-read so relinking sees the recorded real account ids.
    local _, _, after = loadInputs()
    local final = BanksEconomyMigration.BuildPlan(temp, bcc, after)
    return true, relink(bcc, final)
end

RegisterCommand('BccBanksEconomyMigrationReport', function(source)
    if source ~= 0 then return end
    local temp, bcc, migrated = loadInputs()
    if not temp then
        print('[bcc-banks] no temporary economy tables found: nothing to migrate')
        return
    end
    local plan = BanksEconomyMigration.BuildPlan(temp, bcc, migrated)
    print('[bcc-banks] Economy migration report (read-only)')
    printPlan(plan)
    local ready = BanksEconomy.GetHealth()
    print(('  feather-economy ready with bank accounts: %s'):format(tostring(ready.ok)))
    print('  run "BccBanksEconomyMigrate confirm" from the server console to apply')
end, true)

RegisterCommand('BccBanksEconomyMigrate', function(source, args)
    if source ~= 0 then return end
    if args[1] ~= 'confirm' then
        print('[bcc-banks] usage: BccBanksEconomyMigrate confirm   (run BccBanksEconomyMigrationReport first)')
        return
    end
    local done, detail = BanksEconomyMigration.Run()
    if done then
        print(('[bcc-banks] Economy migration finished (%s). Re-run BccBanksEconomyMigrationReport to verify.'):format(tostring(detail)))
    else
        print(('[bcc-banks] Economy migration stopped: %s. Nothing was issued twice; fix the cause and run it again.'):format(tostring(detail)))
    end
end, true)

CreateThread(function()
    DB.awaitReady()
    local pending = BanksEconomyMigration.Pending()
    if pending > 0 then
        print(('[bcc-banks] WARNING: %d temporary-economy account(s) are not yet in Feather Economy. '
            .. 'Accounts show no balance until you run BccBanksEconomyMigrationReport, then BccBanksEconomyMigrate confirm.'):format(pending))
    end
end)
