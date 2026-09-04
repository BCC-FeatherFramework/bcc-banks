-- Temporary Feather Economy boundary for the bcc-banks port.
--
-- This file is intentionally local to bcc-banks and may be deleted once the
-- real feather-economy Contract 1 resource is installed. It must not become an
-- authoritative money store and must never fall back to direct balance writes.

BanksEconomy = {}

local RESOURCE = 'feather-economy'
local CONTRACT = 1

local function ok(value, meta)
    return { ok = true, value = value, meta = meta }
end

local function err(code, message, details)
    return { ok = false, code = code, message = message, details = details }
end

local function isResult(value)
    if type(value) ~= 'table' or type(value.ok) ~= 'boolean' then return false end
    if value.ok then return value.code == nil and value.message == nil end
    return type(value.code) == 'string' and value.code ~= ''
        and type(value.message) == 'string' and value.message ~= ''
end

local function providerState()
    local state = GetResourceState(RESOURCE)
    if state ~= 'started' then
        return nil, err('economy_unavailable',
            'Feather Economy is not installed or started.', { resourceState = state })
    end

    local called, capabilities = pcall(function()
        return exports[RESOURCE]:GetCapabilities()
    end)
    if not called or not isResult(capabilities) or capabilities.ok ~= true
        or type(capabilities.value) ~= 'table' then
        return nil, err('economy_unavailable',
            'Feather Economy capability discovery failed.')
    end

    local value = capabilities.value
    local version = tonumber(value.contractVersion or value.version)
    if version == nil and type(value.contract) == 'number' then
        version = tonumber(value.contract)
    end
    if version ~= CONTRACT then
        return nil, err('unsupported_contract',
            'Feather Economy Contract 1 is required.', {
                required = CONTRACT,
                actual = version
            })
    end

    if value.state ~= 'ready' then
        return nil, err('economy_not_ready', 'Feather Economy is not ready.', {
            state = value.state
        })
    end

    return value
end

local function invoke(operation, request)
    local capabilities, failure = providerState()
    if not capabilities then return failure end

    local feature = capabilities.features and capabilities.features[operation]
    if feature ~= nil and tonumber(feature) < 1 then
        return err('unsupported_capability',
            ('Feather Economy does not provide %s.'):format(operation))
    end

    local called, result = pcall(function()
        return exports[RESOURCE][operation](request)
    end)
    if not called then
        return err('economy_unavailable',
            ('Feather Economy %s failed.'):format(operation))
    end
    if not isResult(result) then
        return err('invalid_provider_result',
            ('Feather Economy %s returned an invalid result.'):format(operation))
    end
    return result
end

function BanksEconomy.GetHealth()
    local capabilities, failure = providerState()
    if not capabilities then return failure end
    return ok({
        state = 'ready',
        resource = RESOURCE,
        contract = CONTRACT,
        capabilities = capabilities
    })
end

function BanksEconomy.AwaitReady(timeoutMs)
    timeoutMs = math.max(0, math.min(60000, tonumber(timeoutMs) or 10000))
    local deadline = GetGameTimer() + timeoutMs
    repeat
        local capabilities, failure = providerState()
        if capabilities then return ok(capabilities) end
        if failure and failure.code == 'unsupported_contract' then return failure end
        Wait(0)
    until GetGameTimer() >= deadline
    return err('timeout', 'Timed out waiting for Feather Economy readiness.')
end

function BanksEconomy.CreateAccount(request)
    return invoke('CreateAccount', request)
end

function BanksEconomy.GetAccount(request)
    return invoke('GetAccount', request)
end

function BanksEconomy.FindAccountsByOwner(request)
    return invoke('FindAccountsByOwner', request)
end

function BanksEconomy.GetBalance(request)
    return invoke('GetBalance', request)
end

function BanksEconomy.Transfer(request)
    return invoke('Transfer', request)
end

function BanksEconomy.GetTransaction(request)
    return invoke('GetTransaction', request)
end

function BanksEconomy.ListTransactions(request)
    return invoke('ListTransactions', request)
end

function BanksEconomy.CloseAccount(request)
    return invoke('CloseAccount', request)
end

-- Issue and Destroy are exposed only for future privileged server workflows.
-- bcc-banks gameplay must prefer Transfer between existing accounts.
function BanksEconomy.Issue(request)
    return invoke('Issue', request)
end

function BanksEconomy.Destroy(request)
    return invoke('Destroy', request)
end

function BanksEconomy.GetTemporaryCapabilities()
    return ok({
        resource = GetCurrentResourceName(),
        contract = 'bcc-banks.economy-adapter',
        version = 1,
        state = 'development',
        features = {
            providerDiscovery = 1,
            resultValidation = 1,
            localBalanceStorage = 0,
            directSqlFallback = 0,
            auditOutbox = 0,
            auditDelivery = 0
        }
    })
end

-- Temporary local backend -------------------------------------------------
-- These definitions intentionally override the provider-only methods above.
-- Values are integer smallest units: 1025 dollars means $10.25.

local tempReady = false
local tempCurrencies = { dollars = true, gold = true }
local function uuid() return MySQL.scalar.await('SELECT UUID()') end
local function positiveInteger(value)
    value = tonumber(value)
    return value and value > 0 and value % 1 == 0 and value <= 9000000000000000 and value or nil
end
local function caller()
    local value = GetInvokingResource and GetInvokingResource() or nil
    return type(value) == 'string' and value ~= '' and value or GetCurrentResourceName()
end
local function storedOperation(scope, key, fingerprint)
    local row = MySQL.single.await([[SELECT fingerprint, result_json
        FROM bcc_banks_temp_economy_operations WHERE source_resource = ?
        AND idempotency_key = ? LIMIT 1]], { scope, key })
    if not row then return nil end
    if row.fingerprint ~= fingerprint then
        return err('idempotency_conflict', 'The idempotency key belongs to another request.')
    end
    local decodedOk, value = pcall(json.decode, row.result_json)
    if not decodedOk then return err('persistence_failed', 'Stored operation result is invalid.') end
    value.idempotent = true
    return ok(value)
end
local function accountRow(accountId)
    return MySQL.single.await([[SELECT a.*, b.posted_amount, b.held_amount, b.revision AS balance_revision
        FROM bcc_banks_temp_economy_accounts a JOIN bcc_banks_temp_economy_balances b
        ON b.account_id = a.account_id WHERE a.account_id = ? LIMIT 1]], { accountId })
end
local function snapshot(row)
    return { accountId = row.account_id, ownerType = row.owner_type, ownerId = row.owner_id,
        accountType = row.account_type, currency = row.currency_code, status = row.status,
        label = row.label, revision = tonumber(row.revision),
        postedAmount = tonumber(row.posted_amount), heldAmount = tonumber(row.held_amount),
        availableAmount = tonumber(row.posted_amount) - tonumber(row.held_amount) }
end
local function systemAccount(currency)
    return MySQL.scalar.await([[SELECT account_id FROM bcc_banks_temp_economy_accounts
        WHERE owner_type = 'system' AND account_type = 'system' AND currency_code = ? LIMIT 1]],
        { currency })
end

function BanksEconomy.Initialize()
    local succeeded, problem = pcall(function()
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS bcc_banks_temp_economy_accounts (
            account_id CHAR(36) NOT NULL, owner_type VARCHAR(24) NOT NULL,
            owner_id CHAR(36) NOT NULL, account_type VARCHAR(24) NOT NULL,
            currency_code VARCHAR(32) NOT NULL, status VARCHAR(20) NOT NULL DEFAULT 'open',
            label VARCHAR(120) NOT NULL, revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
            created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, closed_at TIMESTAMP NULL,
            PRIMARY KEY (account_id), INDEX idx_temp_economy_owner (owner_type, owner_id),
            INDEX idx_temp_economy_kind (account_type, currency_code, status)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS bcc_banks_temp_economy_balances (
            account_id CHAR(36) NOT NULL, posted_amount BIGINT NOT NULL DEFAULT 0,
            held_amount BIGINT UNSIGNED NOT NULL DEFAULT 0, revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (account_id), FOREIGN KEY (account_id)
            REFERENCES bcc_banks_temp_economy_accounts(account_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS bcc_banks_temp_economy_transactions (
            transaction_id CHAR(36) NOT NULL, operation_type VARCHAR(32) NOT NULL,
            currency_code VARCHAR(32) NOT NULL, amount BIGINT UNSIGNED NOT NULL,
            from_account_id CHAR(36) NOT NULL, to_account_id CHAR(36) NOT NULL,
            reason_code VARCHAR(100) NOT NULL, reference_type VARCHAR(64) NULL,
            reference_id VARCHAR(100) NULL, source_resource VARCHAR(100) NOT NULL,
            correlation_id VARCHAR(100) NOT NULL, posted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (transaction_id), INDEX idx_temp_economy_from (from_account_id, posted_at),
            INDEX idx_temp_economy_to (to_account_id, posted_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS bcc_banks_temp_economy_entries (
            entry_id CHAR(36) NOT NULL, transaction_id CHAR(36) NOT NULL,
            account_id CHAR(36) NOT NULL, amount BIGINT NOT NULL, resulting_balance BIGINT NOT NULL,
            PRIMARY KEY (entry_id), INDEX idx_temp_entries_account (account_id, transaction_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS bcc_banks_temp_economy_operations (
            operation_id CHAR(36) NOT NULL, source_resource VARCHAR(100) NOT NULL,
            idempotency_key VARCHAR(100) NOT NULL, fingerprint VARCHAR(255) NOT NULL,
            result_json LONGTEXT NOT NULL, created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (operation_id), UNIQUE KEY uq_temp_economy_idempotency
            (source_resource, idempotency_key)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        MySQL.query.await([[CREATE TABLE IF NOT EXISTS bcc_banks_temp_economy_outbox (
            outbox_id CHAR(36) NOT NULL, event_id CHAR(36) NOT NULL, event_type VARCHAR(120) NOT NULL,
            event_version INT UNSIGNED NOT NULL, payload_json LONGTEXT NOT NULL,
            state VARCHAR(20) NOT NULL DEFAULT 'pending', attempt_count INT UNSIGNED NOT NULL DEFAULT 0,
            next_attempt_at TIMESTAMP NULL, lease_owner VARCHAR(100) NULL, lease_expires_at TIMESTAMP NULL,
            created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, last_attempt_at TIMESTAMP NULL,
            delivered_at TIMESTAMP NULL, audit_event_id CHAR(36) NULL, last_result_code VARCHAR(100) NULL,
            PRIMARY KEY (outbox_id), UNIQUE KEY uq_temp_economy_event (event_id),
            INDEX idx_temp_economy_outbox (state, next_attempt_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
        for currency in pairs(tempCurrencies) do
            if not systemAccount(currency) then
                local accountId = uuid()
                assert(MySQL.transaction.await({
                    { query = [[INSERT INTO bcc_banks_temp_economy_accounts
                        (account_id, owner_type, owner_id, account_type, currency_code, label)
                        VALUES (?, 'system', '00000000-0000-0000-0000-000000000000',
                        'system', ?, ?)]], values = { accountId, currency, currency .. ' issuance' } },
                    { query = [[INSERT INTO bcc_banks_temp_economy_balances
                        (account_id, posted_amount, held_amount) VALUES (?, 0, 0)]], values = { accountId } }
                }) == true)
            end
        end
    end)
    if not succeeded then return err('migration_failed', 'Temporary Economy initialization failed.', { reason = tostring(problem) }) end
    tempReady = true
    return ok({ state = 'ready', temporary = true })
end

function BanksEconomy.GetCapabilities()
    return ok({ resource = GetCurrentResourceName(), contract = 'bcc-banks.temporary-economy',
        version = 1, state = tempReady and 'ready' or 'booting', temporary = true,
        features = { accounts = 1, balances = 1, transfers = 1, journal = 1,
            characterWallets = 1, legacyImport = 1, auditOutbox = 1, auditDelivery = 0 } })
end
function BanksEconomy.GetHealth()
    local pending = tempReady and tonumber(MySQL.scalar.await(
        "SELECT COUNT(*) FROM bcc_banks_temp_economy_outbox WHERE state = 'pending'")) or 0
    return ok({ state = tempReady and 'ready' or 'booting', temporary = true,
        audit = { delivery = 'disabled', pending = pending } })
end

function BanksEconomy.CreateAccount(request)
    if not tempReady then return err('not_ready', 'Temporary Economy is not ready.') end
    if type(request) ~= 'table' or type(request.ownerId) ~= 'string' or not request.ownerId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
        or not tempCurrencies[request.currency]
        or not ({ character = true, organization = true, system = true })[request.ownerType]
        or not ({ wallet = true, bank = true, business = true, treasury = true, system = true })[request.accountType]
        or type(request.label) ~= 'string' or request.label == ''
        or type(request.idempotencyKey) ~= 'string' or request.idempotencyKey == '' then
        return err('invalid_input', 'Account request is invalid.')
    end
    local scope = caller()
    local fingerprint = table.concat({ 'create', request.ownerType, request.ownerId,
        request.accountType, request.currency, request.label }, '|')
    local previous = storedOperation(scope, request.idempotencyKey, fingerprint)
    if previous then return previous end
    local accountId, operationId, outboxId = uuid(), uuid(), uuid()
    local value = { accountId = accountId, ownerType = request.ownerType, ownerId = request.ownerId,
        accountType = request.accountType, currency = request.currency, label = request.label,
        status = 'open', postedAmount = 0, availableAmount = 0, revision = 1 }
    local payload = json.encode({ eventType = 'economy.account.created', eventVersion = 1,
        sourceResource = GetCurrentResourceName(), targets = { accountId },
        reasonCode = request.reasonCode or 'economy.account.create',
        correlationId = request.correlationId or operationId,
        context = { ownerType = request.ownerType, ownerId = request.ownerId,
            accountType = request.accountType, currency = request.currency } })
    local committed = MySQL.transaction.await({
        { query = [[INSERT INTO bcc_banks_temp_economy_accounts
            (account_id, owner_type, owner_id, account_type, currency_code, label)
            VALUES (?, ?, ?, ?, ?, ?)]], values = { accountId, request.ownerType, request.ownerId,
                request.accountType, request.currency, request.label } },
        { query = [[INSERT INTO bcc_banks_temp_economy_balances
            (account_id, posted_amount, held_amount) VALUES (?, 0, 0)]], values = { accountId } },
        { query = [[INSERT INTO bcc_banks_temp_economy_operations
            (operation_id, source_resource, idempotency_key, fingerprint, result_json)
            VALUES (?, ?, ?, ?, ?)]], values = { operationId, scope, request.idempotencyKey,
                fingerprint, json.encode(value) } },
        { query = [[INSERT INTO bcc_banks_temp_economy_outbox
            (outbox_id, event_id, event_type, event_version, payload_json)
            VALUES (?, ?, 'economy.account.created', 1, ?)]], values = { outboxId, operationId, payload } }
    })
    return committed == true and ok(value) or err('persistence_failed', 'Account creation failed.')
end

function BanksEconomy.GetAccount(request)
    local accountId = type(request) == 'table' and request.accountId or request
    local row = type(accountId) == 'string' and accountId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
        and accountRow(accountId) or nil
    return row and ok(snapshot(row)) or err('account_not_found', 'Account was not found.')
end
function BanksEconomy.GetBalance(request)
    local result = BanksEconomy.GetAccount(request)
    if not result.ok then return result end
    return ok({ accountId = result.value.accountId, currency = result.value.currency,
        postedAmount = result.value.postedAmount, heldAmount = result.value.heldAmount,
        availableAmount = result.value.availableAmount, revision = result.value.revision })
end
function BanksEconomy.FindAccountsByOwner(request)
    if type(request) ~= 'table' or type(request.ownerId) ~= 'string' or not request.ownerId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') then
        return err('invalid_input', 'Owner UUID is required.')
    end
    local rows = MySQL.query.await([[SELECT a.*, b.posted_amount, b.held_amount,
        b.revision AS balance_revision FROM bcc_banks_temp_economy_accounts a
        JOIN bcc_banks_temp_economy_balances b ON b.account_id = a.account_id
        WHERE a.owner_type = ? AND a.owner_id = ? ORDER BY a.created_at LIMIT 100]],
        { request.ownerType, request.ownerId }) or {}
    for index, row in ipairs(rows) do rows[index] = snapshot(row) end
    return ok({ rows = rows, hasNext = false })
end

local function post(request, operationType, allowSystemNegative)
    if not tempReady then return err('not_ready', 'Temporary Economy is not ready.') end
    local amount = type(request) == 'table' and positiveInteger(request.amount) or nil
    local from = request and type(request.fromAccountId) == 'string' and request.fromAccountId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
        and accountRow(request.fromAccountId) or nil
    local to = request and type(request.toAccountId) == 'string' and request.toAccountId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
        and accountRow(request.toAccountId) or nil
    if not amount or not from or not to or from.account_id == to.account_id
        or type(request.idempotencyKey) ~= 'string' or request.idempotencyKey == ''
        or #request.idempotencyKey > 100 then
        return err('invalid_input', 'Valid source, destination, and integer amount are required.')
    end
    if from.status ~= 'open' or to.status ~= 'open' then return err('account_closed', 'Account is not open.') end
    if from.currency_code ~= to.currency_code then return err('currency_mismatch', 'Currencies do not match.') end
    local scope = caller()
    local fingerprint = table.concat({ operationType, from.account_id, to.account_id,
        tostring(amount), tostring(request.referenceType or ''), tostring(request.referenceId or '') }, '|')
    local previous = storedOperation(scope, request.idempotencyKey, fingerprint)
    if previous then return previous end
    local success, result = pcall(function()
        from, to = accountRow(from.account_id), accountRow(to.account_id)
        local fromAmount, toAmount = tonumber(from.posted_amount), tonumber(to.posted_amount)
        if fromAmount - tonumber(from.held_amount) < amount
            and not (allowSystemNegative and from.owner_type == 'system') then
            return err('insufficient_funds', 'Insufficient available balance.')
        end
        local afterFrom, afterTo = fromAmount - amount, toAmount + amount
        local transactionId, operationId, outboxId = uuid(), uuid(), uuid()
        local value = { transactionId = transactionId, operationType = operationType,
            currency = from.currency_code, amount = amount, fromAccountId = from.account_id,
            toAccountId = to.account_id, fromBalance = afterFrom, toBalance = afterTo,
            correlationId = request.correlationId or operationId, idempotent = false }
        local payload = json.encode({ eventType = 'economy.transaction.posted', eventVersion = 1,
            sourceResource = GetCurrentResourceName(), targets = { from.account_id, to.account_id },
            references = { transactionId = transactionId, referenceType = request.referenceType,
                referenceId = request.referenceId }, reasonCode = request.reasonCode,
            correlationId = value.correlationId,
            context = { operationType = operationType, currency = from.currency_code, amount = amount } })
        local committed = MySQL.transaction.await({
            { query = [[INSERT INTO bcc_banks_temp_economy_transactions
                (transaction_id, operation_type, currency_code, amount, from_account_id,
                 to_account_id, reason_code, reference_type, reference_id, source_resource, correlation_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], values = { transactionId, operationType,
                    from.currency_code, amount, from.account_id, to.account_id,
                    request.reasonCode or 'economy.transfer', request.referenceType,
                    request.referenceId, scope, value.correlationId } },
            { query = 'UPDATE bcc_banks_temp_economy_balances SET posted_amount = ?, revision = revision + 1 WHERE account_id = ?', values = { afterFrom, from.account_id } },
            { query = 'UPDATE bcc_banks_temp_economy_balances SET posted_amount = ?, revision = revision + 1 WHERE account_id = ?', values = { afterTo, to.account_id } },
            { query = [[INSERT INTO bcc_banks_temp_economy_entries
                (entry_id, transaction_id, account_id, amount, resulting_balance) VALUES (?, ?, ?, ?, ?)]],
                values = { uuid(), transactionId, from.account_id, -amount, afterFrom } },
            { query = [[INSERT INTO bcc_banks_temp_economy_entries
                (entry_id, transaction_id, account_id, amount, resulting_balance) VALUES (?, ?, ?, ?, ?)]],
                values = { uuid(), transactionId, to.account_id, amount, afterTo } },
            { query = [[INSERT INTO bcc_banks_temp_economy_operations
                (operation_id, source_resource, idempotency_key, fingerprint, result_json)
                VALUES (?, ?, ?, ?, ?)]], values = { operationId, scope, request.idempotencyKey,
                    fingerprint, json.encode(value) } },
            { query = [[INSERT INTO bcc_banks_temp_economy_outbox
                (outbox_id, event_id, event_type, event_version, payload_json)
                VALUES (?, ?, 'economy.transaction.posted', 1, ?)]], values = { outboxId, operationId, payload } }
        })
        return committed == true and ok(value) or err('persistence_failed', 'Transaction failed.')
    end)
    return success and result or err('internal_error', 'Temporary Economy transaction failed.')
end

function BanksEconomy.Transfer(request) return post(request, 'transfer', false) end
function BanksEconomy.Issue(request)
    if type(request) ~= 'table' or not tempCurrencies[request.currency] then return err('invalid_input', 'Currency is invalid.') end
    request.fromAccountId = systemAccount(request.currency)
    return post(request, 'issue', true)
end
function BanksEconomy.Destroy(request)
    if type(request) ~= 'table' or not tempCurrencies[request.currency] then return err('invalid_input', 'Currency is invalid.') end
    request.toAccountId = systemAccount(request.currency)
    return post(request, 'destroy', false)
end

function BanksEconomy.GetTransaction(request)
    local transactionId = type(request) == 'table' and request.transactionId or request
    if type(transactionId) ~= 'string' or not transactionId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') then
        return err('invalid_input', 'Transaction UUID is required.')
    end
    local row = MySQL.single.await([[SELECT transaction_id AS transactionId,
        operation_type AS operationType, currency_code AS currency, amount,
        from_account_id AS fromAccountId, to_account_id AS toAccountId,
        reason_code AS reasonCode, reference_type AS referenceType,
        reference_id AS referenceId, source_resource AS sourceResource,
        correlation_id AS correlationId, posted_at AS postedAt
        FROM bcc_banks_temp_economy_transactions WHERE transaction_id = ? LIMIT 1]],
        { transactionId })
    if not row then return err('transaction_not_found', 'Transaction was not found.') end
    row.entries = MySQL.query.await([[SELECT entry_id AS entryId, account_id AS accountId,
        amount, resulting_balance AS resultingBalance FROM bcc_banks_temp_economy_entries
        WHERE transaction_id = ? ORDER BY entry_id]], { transactionId }) or {}
    return ok(row)
end

function BanksEconomy.ListTransactions(request)
    if type(request) ~= 'table' or type(request.accountId) ~= 'string' or not request.accountId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') then
        return err('invalid_input', 'Account UUID is required.')
    end
    local limit = math.max(1, math.min(100, math.floor(tonumber(request.pageSize) or 20)))
    local rows = MySQL.query.await(([[SELECT t.transaction_id AS transactionId,
        t.operation_type AS operationType, t.currency_code AS currency,
        t.reason_code AS reasonCode, t.reference_type AS referenceType,
        t.reference_id AS referenceId, t.correlation_id AS correlationId,
        t.posted_at AS postedAt, e.amount, e.resulting_balance AS resultingBalance
        FROM bcc_banks_temp_economy_entries e JOIN bcc_banks_temp_economy_transactions t
        ON t.transaction_id = e.transaction_id WHERE e.account_id = ?
        ORDER BY t.posted_at DESC, t.transaction_id DESC LIMIT %d]]):format(limit + 1),
        { request.accountId }) or {}
    local hasNext = #rows > limit
    if hasNext then rows[#rows] = nil end
    return ok({ rows = rows, pageSize = limit, hasNext = hasNext })
end

function BanksEconomy.CloseAccount(request)
    if type(request) ~= 'table' or type(request.accountId) ~= 'string' or not request.accountId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') then
        return err('invalid_input', 'Account UUID is required.')
    end
    local balance = BanksEconomy.GetBalance(request)
    if not balance.ok then return balance end
    if balance.value.postedAmount ~= 0 or balance.value.heldAmount ~= 0 then
        return err('nonzero_balance', 'Empty the account before closing it.')
    end
    local changed = MySQL.update.await([[UPDATE bcc_banks_temp_economy_accounts
        SET status = 'closed', closed_at = NOW(), revision = revision + 1
        WHERE account_id = ? AND status = 'open']], { request.accountId })
    return tonumber(changed) == 1 and ok({ accountId = request.accountId, status = 'closed' })
        or err('account_closed', 'Account is not open.')
end

function BanksEconomy.EnsureCharacterWallets(request)
    if type(request) ~= 'table' or type(request.characterId) ~= 'string' or not request.characterId:match(
        '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') then
        return err('invalid_input', 'Character UUID is required.')
    end
    local found = BanksEconomy.FindAccountsByOwner({ ownerType = 'character', ownerId = request.characterId })
    if not found.ok then return found end
    local wallets = {}
    for _, account in ipairs(found.value.rows) do
        if account.accountType == 'wallet' then wallets[account.currency] = account end
    end
    for currency in pairs(tempCurrencies) do
        if not wallets[currency] then
            local created = BanksEconomy.CreateAccount({ ownerType = 'character', ownerId = request.characterId,
                accountType = 'wallet', currency = currency, label = currency .. ' wallet',
                reasonCode = 'character.wallet.provision',
                idempotencyKey = ('wallet:%s:%s'):format(request.characterId, currency),
                correlationId = request.correlationId })
            if not created.ok then return created end
            wallets[currency] = created.value
        end
    end
    return ok(wallets)
end

local function issueCharacterFunds(request, reason, prefix)
    if type(request) ~= 'table' or type(request.idempotencyKey) ~= 'string' then
        return err('invalid_input', 'An idempotency key is required.')
    end
    local wallets = BanksEconomy.EnsureCharacterWallets(request)
    if not wallets.ok then return wallets end
    local issued = {}
    for currency in pairs(tempCurrencies) do
        local amount = tonumber(request[currency]) or 0
        if amount < 0 or amount % 1 ~= 0 then return err('invalid_input', 'Funds must use non-negative integer units.') end
        if amount > 0 then
            local result = BanksEconomy.Issue({ toAccountId = wallets.value[currency].accountId,
                currency = currency, amount = amount, reasonCode = reason,
                referenceType = request.referenceType, referenceId = request.referenceId,
                correlationId = request.correlationId,
                idempotencyKey = ('%s:%s:%s'):format(prefix, request.idempotencyKey, currency) })
            if not result.ok then return result end
            issued[currency] = result.value
        end
    end
    return ok({ characterId = request.characterId, wallets = wallets.value, issued = issued })
end
function BanksEconomy.ImportLegacyBalances(request)
    return issueCharacterFunds(request, 'economy.migration.legacy_balance', 'legacy')
end
function BanksEconomy.IssueStartingFunds(request)
    return issueCharacterFunds(request, 'economy.onboarding.starting_funds', 'onboarding')
end
