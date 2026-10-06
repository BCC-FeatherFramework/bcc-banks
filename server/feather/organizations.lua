-- Each bank branch is a Feather Organization (type business). Its Economy
-- treasuries are the branch reserve: loans, checks, box fees and gold exchange
-- move money between customers and that reserve instead of creating or
-- destroying currency. Economy only lets bcc-banks use treasuries it bound with
-- EnsureBankReserve, so no other organization's treasury can be touched.
BankOrganizations = {}

local REASON_CODE = 'banks.bootstrap'
local reserves = {} -- bank id -> { organizationId, dollars = account, gold = account }

local function failure(code, message)
    return { ok = false, code = code, message = message }
end

local function organizations(operation, request)
    local called, result = pcall(function()
        local provider = exports['feather-organizations']
        return provider[operation](provider, request)
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return failure('organizations_unavailable', 'Feather Organizations ' .. operation .. ' failed.')
    end
    return result
end

local function organizationKey(bankId)
    return 'bcc_bank_' .. (tostring(bankId):lower():gsub('[^a-z0-9]', ''))
end

-- Finds or creates the branch organization and makes sure it is active.
local function resolveOrganization(bank)
    local current
    if type(bank.organization_id) == 'string' and bank.organization_id ~= '' then
        current = organizations('GetOrganization', { organizationId = bank.organization_id })
    else
        current = organizations('FindOrganizationByKey', { organizationKey = organizationKey(bank.id) })
        if not current.ok and current.code == 'organization_not_found' then
            local name = tostring(bank.name or 'Bank'):sub(1, 100)
            local created = organizations('CreateOrganization', {
                requestId = 'bcc-banks:organization:' .. bank.id,
                organizationType = 'business',
                organizationKey = organizationKey(bank.id),
                legalName = name,
                displayName = name,
                reasonCode = REASON_CODE
            })
            if not created.ok then return created end
            current = organizations('GetOrganization', { organizationId = created.value.organizationId })
        end
    end
    if not current.ok then return current end

    if current.value.status == 'pending' then
        local activated = organizations('ChangeOrganizationStatus', {
            organizationId = current.value.organizationId,
            expectedRevision = current.value.revision,
            status = 'active',
            requestId = ('bcc-banks:organization-activate:%s:r%d'):format(bank.id, current.value.revision),
            reasonCode = REASON_CODE
        })
        if not activated.ok then return activated end
        current = organizations('GetOrganization', { organizationId = current.value.organizationId })
        if not current.ok then return current end
    end
    if current.value.status ~= 'active' then
        return failure('organization_inactive', ('Bank organization is %s.'):format(current.value.status))
    end
    return current
end

-- Links one branch to its organization and binds the organization's treasuries
-- as the branch reserve. Safe to repeat.
function BankOrganizations.Ensure(bank)
    if type(bank) ~= 'table' or not bank.id then return failure('invalid_input', 'Bank row required.') end
    local organization = resolveOrganization(bank)
    if not organization.ok then return organization end
    local organizationId = organization.value.organizationId

    DB.exec('UPDATE `bcc_banks` SET `organization_id` = ? WHERE `id` = ? AND `organization_id` IS NULL',
        organizationId, bank.id)
    local linked = DB.value('SELECT `organization_id` FROM `bcc_banks` WHERE `id` = ?', bank.id)
    if not IdsEqual(linked, organizationId) then
        return failure('organization_link_conflict', 'Bank is already linked to another organization.')
    end

    local reserve = BanksEconomy.EnsureBankReserve({ organizationId = organizationId })
    if not reserve.ok then return reserve end
    reserves[NormalizeId(bank.id)] = {
        organizationId = organizationId,
        dollars = reserve.value.dollars,
        gold = reserve.value.gold
    }
    return { ok = true, value = reserves[NormalizeId(bank.id)] }
end

-- Returns the reserve treasury account id for a branch and currency
-- ('dollars' or 'gold'), provisioning the branch on first use.
function BankOrganizations.GetReserveAccountId(bankId, currency)
    local key = NormalizeId(bankId)
    if not key then return nil, 'invalid_bank' end
    if not reserves[key] then
        local bank = DB.query('SELECT * FROM `bcc_banks` WHERE `id` = ? LIMIT 1', key)
        if not bank or not bank[1] then return nil, 'bank_not_found' end
        local ensured = BankOrganizations.Ensure(bank[1])
        if not ensured.ok then return nil, ensured.code end
    end
    local account = reserves[key][currency]
    return account and account.accountId, account and nil or 'reserve_not_found'
end

function BankOrganizations.GetReserve(bankId)
    return reserves[NormalizeId(bankId) or '']
end

local function provisionAll()
    local deadline = GetGameTimer() + 60000
    while not BccBanksDatabaseReady and GetGameTimer() < deadline do Wait(250) end
    local ready = organizations('AwaitReady', 30000)
    if not ready.ok then
        return print('[bcc-banks] organizations: Feather Organizations is not ready: ' .. tostring(ready.code))
    end
    reserves = {}
    local linked, failed = 0, 0
    for _, bank in ipairs(GetBanks() or {}) do
        local result = BankOrganizations.Ensure(bank)
        if result.ok then
            linked = linked + 1
        else
            failed = failed + 1
            print(('[bcc-banks] organizations: bank %s (%s) has no reserve: %s %s'):format(
                tostring(bank.id), tostring(bank.name), tostring(result.code), tostring(result.message or '')))
        end
    end
    print(('[bcc-banks] organizations: %d branch reserve(s) ready, %d failed'):format(linked, failed))
end

CreateThread(provisionAll)

AddEventHandler('onResourceStart', function(resource)
    if resource == 'feather-organizations' or resource == 'feather-economy' then
        CreateThread(provisionAll)
    end
end)

-- Console: BccBanksReserveStatus
RegisterCommand('BccBanksReserveStatus', function(source)
    if source ~= 0 then return end
    for _, bank in ipairs(GetBanks() or {}) do
        local reserve = BankOrganizations.GetReserve(bank.id)
        if not reserve then
            print(('[bcc-banks] %s (%s): no reserve'):format(tostring(bank.name), tostring(bank.id)))
        else
            local balances = {}
            for _, currency in ipairs({ 'dollars', 'gold' }) do
                local balance = BanksEconomy.GetBalance({ accountId = reserve[currency].accountId })
                balances[#balances + 1] = ('%s=%s'):format(currency,
                    balance.ok and ('%.2f'):format((tonumber(balance.value.postedAmount) or 0) / 100) or 'unavailable')
            end
            print(('[bcc-banks] %s (%s): organization=%s %s'):format(tostring(bank.name), tostring(bank.id),
                reserve.organizationId, table.concat(balances, ' ')))
        end
    end
end, true)

-- Console: BccBanksReserveFund <bank id> <dollars|gold> <amount>
-- Operator funding creates currency into a branch reserve; use it to capitalize
-- a branch so it can pay out loans, checks and gold.
RegisterCommand('BccBanksReserveFund', function(source, args)
    if source ~= 0 then return end
    local bankId, currency, amount = NormalizeId(args[1]), args[2], tonumber(args[3])
    if not bankId or (currency ~= 'dollars' and currency ~= 'gold') or not amount or amount <= 0 then
        return print('[bcc-banks] Usage: BccBanksReserveFund <bank id> <dollars|gold> <amount>')
    end
    local accountId, reason = BankOrganizations.GetReserveAccountId(bankId, currency)
    if not accountId then return print('[bcc-banks] Reserve unavailable: ' .. tostring(reason)) end
    local issued = BanksEconomy.Issue({
        toAccountId = accountId, currency = currency, amount = math.floor(amount * 100 + 0.5),
        reasonCode = 'bank.reserve.funding', referenceType = 'bcc_bank', referenceId = bankId,
        idempotencyKey = ('banks:reserve-fund:%s'):format(DB.value('SELECT UUID()'))
    })
    print(issued.ok and ('[bcc-banks] Funded %s reserve with %.2f %s'):format(bankId, amount, currency)
        or ('[bcc-banks] Reserve funding failed: %s %s'):format(tostring(issued.code), tostring(issued.message)))
end, true)
