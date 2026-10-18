-- Branch reserve in /bankadmin: balance, recent activity, and staff moving money
-- between the reserve and their own wallet (bank.reserve.deposit / .withdraw).
-- Who may: BankAuthority.CanManageReserve (administrators: every branch; banker
-- job holders: the branch whose organization employs them).

BankReserve = {}

local CURRENCIES = { dollars = 0, gold = 1 }

local function units(value) return (tonumber(value) or 0) / 100 end

-- Balances and the newest `limit` entries of both currencies, newest first.
function BankReserve.Status(bankId, limit)
    local reserve = BankOrganizations.GetReserve(bankId)
    if not reserve then return { ok = false, key = 'admin_reserve_unavailable' } end
    local status = { ok = true, organizationId = reserve.organizationId, entries = {} }
    for currency in pairs(CURRENCIES) do
        local accountId = reserve[currency] and reserve[currency].accountId
        local balance = accountId and BanksEconomy.GetBalance({ accountId = accountId })
        status[currency] = balance and balance.ok and units(balance.value.postedAmount) or nil
        local listed = accountId and BanksEconomy.ListEntries({ accountId = accountId, limit = limit or 10 })
        for _, entry in ipairs(listed and listed.ok and listed.value or {}) do
            status.entries[#status.entries + 1] = {
                currency = currency, amount = units(entry.amount), reason = entry.reasonCode,
                postedAt = entry.postedAt, sequence = tonumber(entry.sequence) or 0
            }
        end
    end
    table.sort(status.entries, function(a, b) return tostring(a.postedAt) > tostring(b.postedAt) end)
    while #status.entries > (limit or 10) do table.remove(status.entries) end
    return status
end

-- `direction` 'withdraw' (reserve -> the staff member's wallet) or 'deposit'
-- (wallet -> reserve). `char` is a banking context; permission is the caller's check.
function BankReserve.Move(char, bankId, currency, amount, direction)
    amount = tonumber(amount)
    if CURRENCIES[currency] == nil or not IsFinitePositiveNumber(amount)
        or (direction ~= 'withdraw' and direction ~= 'deposit') then
        return { ok = false, key = 'error_invalid_input' }
    end
    amount = math.floor(amount * 100 + 0.5) / 100
    if direction == 'deposit' then
        local held = currency == 'gold' and tonumber(char.gold) or tonumber(char.money)
        if (held or 0) < amount then return { ok = false, key = 'admin_reserve_wallet_short' } end
    else
        local status = BankReserve.Status(bankId, 1)
        if not status.ok then return status end
        if (status[currency] or 0) < amount then return { ok = false, key = 'admin_reserve_short' } end
    end
    local moved = pcall(function()
        if direction == 'withdraw' then
            char.CreditWallet(CURRENCIES[currency], amount, 'bank.reserve.withdraw', bankId)
        else
            char.DebitWallet(CURRENCIES[currency], amount, 'bank.reserve.deposit', bankId)
        end
    end)
    if not moved then return { ok = false, key = 'admin_action_failed' } end
    return { ok = true, amount = amount }
end

local function allowed(src, bankId)
    local session = exports['feather-core']:GetSessionContext(tonumber(src))
    local characterId = type(session) == 'table' and session.ok and type(session.value) == 'table'
        and session.value.characterId or nil
    if not characterId or not bankId then return false end
    return BankAuthority.CanManageReserve(characterId, bankId)
end

exports['feather-core']:RegisterRPC('bcc-banks:Admin:GetReserve', function(params, cb, src)
    local bankId = NormalizeId(params and params.bank)
    if not allowed(src, bankId) then
        NotifyClient(src, Feather.Locale.translateUpper('admin_reserve_not_allowed'), 'error', 4000)
        return cb(false)
    end
    local status = BankReserve.Status(bankId, 10)
    if not status.ok then
        NotifyClient(src, Feather.Locale.translateUpper(status.key), 'error', 4000)
        return cb(false)
    end
    cb(true, status)
end)

exports['feather-core']:RegisterRPC('bcc-banks:Admin:MoveReserve', function(params, cb, src)
    local bankId = NormalizeId(params and params.bank)
    if not allowed(src, bankId) then
        NotifyClient(src, Feather.Locale.translateUpper('admin_reserve_not_allowed'), 'error', 4000)
        return cb(false)
    end
    local note = tostring(params and params.note or ''):gsub('[%c]', ' '):sub(1, 120)
    if note:match('^%s*$') then
        NotifyClient(src, Feather.Locale.translateUpper('admin_reserve_note_required'), 'error', 4000)
        return cb(false)
    end
    local char = GetBankingContext(src)
    if not char then return cb(false) end
    if not AcquirePlayerFinancialLock(src) then
        NotifyClient(src, Feather.Locale.translateUpper('error_financial_operation_busy'), 'error', 4000)
        return cb(false)
    end
    local currency, direction = params and params.currency, params and params.direction
    local result = BankReserve.Move(char, bankId, currency, params and params.amount, direction)
    ReleasePlayerFinancialLock(src)
    if not result.ok then
        NotifyClient(src, Feather.Locale.translateUpper(result.key), 'error', 4000)
        return cb(false)
    end
    local lines = {
        '**Action:** `Reserve ' .. (direction == 'withdraw' and 'Withdrawal' or 'Deposit') .. '`',
        '**Bank:** `' .. tostring(BccBanksInternal.getBankName(bankId)) .. '`',
        '**Amount:** `' .. tostring(result.amount) .. ' ' .. tostring(currency) .. '`',
        '**Reason:** `' .. note .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Branch Reserve ' .. (direction == 'withdraw' and 'Withdrawal' or 'Deposit'), lines, 15105570)
    AddCharacterTransaction(char.characterId, result.amount, 'reserve - ' .. direction,
        ('%s %s %s (%s)'):format(direction == 'withdraw' and 'Withdrew' or 'Deposited', tostring(result.amount),
            tostring(currency), note))
    NotifyClient(src, Feather.Locale.translateUpper('admin_reserve_moved'), 'success', 4000)
    cb(true, result)
end)
