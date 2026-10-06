-- bcc-banks boundary to feather-economy (Contract 1).
--
-- This file holds no balances and no money tables: every amount lives in the
-- Economy ledger and every movement is an Economy operation. It only translates
-- the shapes bcc-banks uses into Economy requests and validates what comes back.
-- Amounts are integer smallest units (1025 dollars means $10.25).

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
        return nil, err('economy_unavailable', 'Feather Economy capability discovery failed.')
    end

    local value = capabilities.value
    local version = tonumber(value.contract or value.contractVersion or value.version)
    if version ~= CONTRACT then
        return nil, err('unsupported_contract', 'Feather Economy Contract 1 is required.', {
            required = CONTRACT, actual = version
        })
    end
    if value.state ~= 'ready' then
        return nil, err('economy_not_ready', 'Feather Economy is not ready.', { state = value.state })
    end
    if type(value.features) ~= 'table' or tonumber(value.features.bankAccounts) ~= 1 then
        return nil, err('unsupported_capability',
            'Feather Economy with bank account support is required.')
    end
    return value
end

-- Calls an Economy export the way Cfx expects (provider object as the first
-- argument) so the invoking resource is identified as bcc-banks.
local function invoke(operation, request, context)
    local capabilities, failure = providerState()
    if not capabilities then return failure end

    local called, result = pcall(function()
        local provider = exports[RESOURCE]
        return provider[operation](provider, request, context)
    end)
    if not called then
        return err('economy_unavailable', ('Feather Economy %s failed.'):format(operation))
    end
    if not isResult(result) then
        return err('invalid_provider_result',
            ('Feather Economy %s returned an invalid result.'):format(operation))
    end
    return result
end

-- The identity fields Economy uses for authorization and its journal.
local function contextFrom(request)
    request = type(request) == 'table' and request or {}
    return {
        actorCharacterId = request.actorCharacterId,
        actorAccountId = request.actorAccountId,
        actorSource = request.actorSource,
        correlationId = request.correlationId
    }
end

local function without(request, ...)
    local copy = {}
    for key, value in pairs(request or {}) do copy[key] = value end
    for _, key in ipairs({ ... }) do copy[key] = nil end
    return copy
end

function BanksEconomy.Initialize()
    -- Nothing to create locally. Readiness is checked per call.
    return ok(true)
end

function BanksEconomy.GetHealth()
    local capabilities, failure = providerState()
    if not capabilities then return failure end
    return ok({ state = 'ready', resource = RESOURCE, contract = CONTRACT, capabilities = capabilities })
end

function BanksEconomy.AwaitReady(timeoutMs)
    timeoutMs = math.max(0, math.min(60000, tonumber(timeoutMs) or 10000))
    local deadline = GetGameTimer() + timeoutMs
    repeat
        local capabilities, failure = providerState()
        if capabilities then return ok(capabilities) end
        if failure and (failure.code == 'unsupported_contract' or failure.code == 'unsupported_capability') then
            return failure
        end
        Wait(100)
    until GetGameTimer() >= deadline
    return err('timeout', 'Timed out waiting for Feather Economy readiness.')
end

-- Wallet accounts as a table keyed by currency: { dollars = account, gold = account }.
function BanksEconomy.EnsureCharacterWallets(request)
    request = type(request) == 'table' and request or {}
    local result = invoke('EnsureCharacterWallets', { characterId = request.characterId }, contextFrom(request))
    if not result.ok then return result end
    local byCurrency = {}
    for _, account in ipairs(result.value) do
        if account.accountType == 'wallet' then byCurrency[account.currency] = account end
    end
    if not byCurrency.dollars or not byCurrency.gold then
        return err('invalid_provider_result', 'Economy did not return both character wallets.')
    end
    return ok(byCurrency)
end

function BanksEconomy.GetAccount(request)
    return invoke('GetAccount', { accountId = request and request.accountId }, contextFrom(request))
end

function BanksEconomy.FindAccountsByOwner(request)
    request = type(request) == 'table' and request or {}
    return invoke('FindAccountsByOwner', { ownerType = request.ownerType, ownerId = request.ownerId },
        contextFrom(request))
end

function BanksEconomy.GetBalance(request)
    local account = BanksEconomy.GetAccount(request)
    if not account.ok then return account end
    return ok({ accountId = account.value.accountId, currency = account.value.currency,
        postedAmount = account.value.balance, status = account.value.status })
end

-- Newest-first statement for one Economy account.
function BanksEconomy.ListEntries(request)
    request = type(request) == 'table' and request or {}
    return invoke('ListAccountEntries', { accountId = request.accountId, limit = request.limit,
        offset = request.offset }, contextFrom(request))
end

-- Provisions the Economy bank account of one currency for a BCC bank account.
-- The BCC account id is the stable reference, so a character can hold several
-- bank accounts and a retry always resolves to the same Economy account.
function BanksEconomy.CreateAccount(request)
    request = type(request) == 'table' and request or {}
    if request.ownerType ~= 'character' or request.accountType ~= 'bank'
        or type(request.ownerId) ~= 'string' or type(request.referenceId) ~= 'string'
        or type(request.currency) ~= 'string' then
        return err('invalid_input', 'A character bank account request is required.')
    end
    local result = invoke('EnsureCharacterBankAccounts',
        { characterId = request.ownerId, accountRef = request.referenceId }, contextFrom(request))
    if not result.ok then return result end
    for _, account in ipairs(result.value) do
        if account.currency == request.currency and account.accountType == 'bank' then
            return ok(account)
        end
    end
    return err('account_not_found', 'Economy did not return the requested bank account.')
end

-- Binds a branch organization's treasuries as that branch's reserve and returns
-- them as a table keyed by currency: { dollars = account, gold = account }.
function BanksEconomy.EnsureBankReserve(request)
    request = type(request) == 'table' and request or {}
    local result = invoke('EnsureBankReserve', { organizationId = request.organizationId }, contextFrom(request))
    if not result.ok then return result end
    local byCurrency = {}
    for _, account in ipairs(result.value) do
        if account.accountType == 'treasury' and account.status == 'open' then
            byCurrency[account.currency] = account
        end
    end
    if not byCurrency.dollars or not byCurrency.gold then
        return err('invalid_provider_result', 'Economy did not return both reserve treasuries.')
    end
    return ok(byCurrency)
end

function BanksEconomy.GetSystemAccount(request)
    request = type(request) == 'table' and request or {}
    return invoke('GetSystemAccount', { currency = request.currency, accountType = request.accountType },
        contextFrom(request))
end

-- Moves funds between two Economy accounts. The reason code must be one of the
-- bank.* codes Economy accepts (bank.deposit, bank.withdraw, bank.transfer, bank.fee).
function BanksEconomy.Transfer(request)
    request = type(request) == 'table' and request or {}
    return invoke('Transfer', without(request, 'actorCharacterId', 'actorAccountId', 'actorSource', 'correlationId'),
        contextFrom(request))
end

-- Interim supply operations, restricted by Economy to allow-listed bank.* reason
-- codes. Prefer Transfer wherever a counterparty account exists.
function BanksEconomy.Issue(request)
    request = type(request) == 'table' and request or {}
    local body = without(request, 'toAccountId', 'actorCharacterId', 'actorAccountId', 'actorSource', 'correlationId')
    body.accountId = request.toAccountId or request.accountId
    return invoke('Issue', body, contextFrom(request))
end

function BanksEconomy.Destroy(request)
    request = type(request) == 'table' and request or {}
    local body = without(request, 'fromAccountId', 'actorCharacterId', 'actorAccountId', 'actorSource', 'correlationId')
    body.accountId = request.fromAccountId or request.accountId
    return invoke('Destroy', body, contextFrom(request))
end
