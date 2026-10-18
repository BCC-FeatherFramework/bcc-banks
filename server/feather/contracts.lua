-- bcc-banks' boundary to feather-contracts. An approved loan's total (amount +
-- interest) is owed in equal installments, one Contracts obligation each: the
-- borrower (character) owes the branch's organization. Settling pays the
-- borrower's wallet into the branch reserve, which is that organization's treasury.
-- Contracts owns each debt, its due date, its default and the settlement through
-- feather-economy; bcc-banks keeps one row per installment in bcc_loans_payments
-- (seq, obligation_id, status) and the loan's own status in bcc_loans.
--
-- Every request ID is derived from the loan and the installment number, so an
-- approval repeated after a restart or a timeout never opens a second debt.

BankLoanContracts = { ready = false }

local RESOURCE = 'feather-contracts'
local TYPE_KEY = 'bank_loan_installment'
local REASON = 'banks.loan.installment'
local MAX_DUE_SECONDS = 31536000

local function err(code, message) return { ok = false, code = code, message = message } end

local function call(operation, request, context)
    if GetResourceState(RESOURCE) ~= 'started' then
        return err('dependency_unavailable', RESOURCE .. ' is not started.')
    end
    local called, result = pcall(function()
        local provider = exports[RESOURCE]
        return provider[operation](provider, request, context)
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return err('dependency_unavailable', ('%s %s failed.'):format(RESOURCE, operation))
    end
    return result
end

local function describe(result)
    return ('%s %s'):format(tostring(result.code), tostring(result.message or ''))
end

local function loanSettings()
    local settings = Config.LoanContracts or {}
    return math.max(60, tonumber(settings.SecondsPerMonth) or 86400),
        math.max(0, tonumber(settings.DefaultAfterSeconds) or 86400)
end

local function requestId(loanId, seq, step)
    return ('bcc-banks:loan:%s:%d:%s'):format(loanId, seq, step)
end

function BankLoanContracts.Installments(loanId)
    return DB.query([[SELECT `id`, `seq`, `amount`, `date_due`, `obligation_id`, `status`, `paid_at`
        FROM `bcc_loans_payments` WHERE `loan_id` = ? ORDER BY `seq`]], loanId) or {}
end

-- Opens the installments of an approved loan: drafts and issues one obligation
-- per loan month. Safe to repeat. Returns { ok, count } or an error.
function BankLoanContracts.OpenInstallments(loan, totalDue)
    if not BankLoanContracts.ready then
        return err('dependency_unavailable', 'Contracts loan type is not registered yet.')
    end
    local organizationId = BankOrganizations.GetReserve(loan.bank_id)
    organizationId = organizationId and organizationId.organizationId
    if not organizationId then return err('reserve_unavailable', 'The branch has no organization reserve.') end

    local secondsPerMonth = loanSettings()
    local count = math.max(1, math.floor(tonumber(loan.duration) or 1))
    local total = math.floor((tonumber(totalDue) or 0) * 100 + 0.5)
    if total < count then return err('invalid_input', 'Loan total is too small to split.') end
    local each = math.floor(total / count)
    local characterId = tostring(loan.character_id):lower()

    for seq = 1, count do
        local amount = seq < count and each or (total - each * (count - 1))
        local dueIn = math.min(seq * secondsPerMonth, MAX_DUE_SECONDS)
        local draft = call('CreateDraft', {
            requestId = requestId(loan.id, seq, 'draft'),
            obligationType = TYPE_KEY,
            issuer = { type = 'system' },
            debtor = { type = 'character', id = characterId },
            creditor = { type = 'organization', id = organizationId },
            amount = amount,
            currency = 'dollars',
            dueInSeconds = dueIn,
            referenceType = 'bcc_loan',
            referenceId = tostring(loan.id),
            memo = ('Loan %s, installment %d of %d'):format(tostring(loan.id), seq, count),
            reasonCode = REASON
        })
        if not draft.ok then return draft end
        local obligationId = draft.value.obligationId
        DB.exec([[INSERT INTO `bcc_loans_payments` (`id`, `loan_id`, `seq`, `amount`, `date_due`, `obligation_id`, `status`)
            VALUES (UUID(), ?, ?, ?, NOW() + INTERVAL ? SECOND, ?, 'open')
            ON DUPLICATE KEY UPDATE `obligation_id` = VALUES(`obligation_id`)]],
            loan.id, seq, amount / 100, dueIn, obligationId)
        local issued = call('IssueObligation', {
            requestId = requestId(loan.id, seq, 'issue'),
            obligationId = obligationId,
            reasonCode = REASON
        })
        if not issued.ok then return issued end
    end
    return { ok = true, value = { count = count } }
end

-- Cancels a loan's unpaid installments (a disbursement that failed after opening them).
function BankLoanContracts.CancelInstallments(loanId, reasonCode)
    for _, row in ipairs(BankLoanContracts.Installments(loanId)) do
        if row.obligation_id and row.status ~= 'paid' then
            local cancelled = call('CancelObligation', {
                requestId = requestId(loanId, row.seq, 'cancel'),
                obligationId = row.obligation_id,
                reasonCode = reasonCode or 'banks.loan.cancelled'
            })
            if not cancelled.ok and cancelled.code ~= 'invalid_state' then
                print(('[bcc-banks] contracts: cancel %s failed: %s'):format(row.obligation_id, describe(cancelled)))
            end
        end
    end
    DB.exec([[DELETE FROM `bcc_loans_payments` WHERE `loan_id` = ? AND `status` <> 'paid']], loanId)
end

local function nextOpen(loanId)
    for _, row in ipairs(BankLoanContracts.Installments(loanId)) do
        if row.status ~= 'paid' then return row end
    end
end

-- Recomputes the loan's status from its installments: all paid -> paid (accounts
-- unfrozen when the borrower has no other defaulted loan); any defaulted -> defaulted
-- and the borrower's accounts frozen. Returns the loan status.
local function settleLoanStatus(loanId)
    local loan = GetLoan(loanId)
    if not loan then return nil end
    local rows = BankLoanContracts.Installments(loanId)
    if #rows == 0 then return loan.status end
    local allPaid, anyDefaulted = true, false
    for _, row in ipairs(rows) do
        if row.status ~= 'paid' then allPaid = false end
        if row.status == 'defaulted' then anyDefaulted = true end
    end
    if allPaid and loan.status ~= 'paid' then
        DB.exec('UPDATE `bcc_loans` SET `status` = "paid", `is_defaulted` = 0 WHERE `id` = ?', loanId)
        local remaining = DB.value([[SELECT COUNT(*) FROM `bcc_loans` WHERE `character_id` = ?
            AND (`status` = 'defaulted' OR `is_defaulted` = 1)]], loan.character_id)
        if (tonumber(remaining) or 0) == 0 then SetOwnerAccountsFrozen(loan.character_id, false) end
        return 'paid'
    end
    if anyDefaulted and loan.status ~= 'defaulted' and not allPaid then
        DB.exec('UPDATE `bcc_loans` SET `status` = "defaulted", `is_defaulted` = 1 WHERE `id` = ?', loanId)
        SetOwnerAccountsFrozen(loan.character_id, true)
        return 'defaulted'
    end
    return loan.status
end

-- Pays whole installments, oldest first, while `amount` (dollars) covers the next
-- one. `context` is { actorSource = src } for a player paying; without it the bank
-- collects as issuer (console, tests). Returns { ok, paid, amount } or an error;
-- `below_installment` carries the next installment's amount in `next`.
function BankLoanContracts.Pay(loan, amount, context)
    if not BankLoanContracts.ready then
        return err('dependency_unavailable', 'Contracts loan type is not registered yet.')
    end
    local remaining = math.floor((tonumber(amount) or 0) * 100 + 0.5)
    local paid, paidMinor = 0, 0
    local attempt = DB.value('SELECT UUID()')
    while true do
        local row = nextOpen(loan.id)
        if not row then break end
        local due = math.floor((tonumber(row.amount) or 0) * 100 + 0.5)
        if due > remaining then
            if paid == 0 then
                local result = err('below_installment', 'The amount does not cover the next installment.')
                result.next = due / 100
                return result
            end
            break
        end
        local settled = call('SettleObligation', {
            requestId = requestId(loan.id, row.seq, 'settle:' .. attempt),
            obligationId = row.obligation_id
        }, context)
        if not settled.ok or settled.value.status ~= 'settled' then
            if settled.ok or settled.code == 'settlement_pending' then
                DB.exec([[UPDATE `bcc_loans_payments` SET `status` = 'pending' WHERE `id` = ?]], row.id)
            end
            if paid == 0 then return settled.ok and err('settlement_pending', 'Payment is being confirmed.') or settled end
            break
        end
        DB.exec([[UPDATE `bcc_loans_payments` SET `status` = 'paid', `paid_at` = NOW() WHERE `id` = ?]], row.id)
        AddLoanTransaction(loan.id, loan.character_id, due / 100, 'loan - repayment',
            ('Installment %d paid'):format(row.seq))
        paid, paidMinor, remaining = paid + 1, paidMinor + due, remaining - due
    end
    return { ok = true, paid = paid, amount = paidMinor / 100, status = settleLoanStatus(loan.id) }
end

-- Reads every unpaid installment's obligation and updates the rows and the loan.
-- Returns the installments that changed, as { row, status }.
function BankLoanContracts.Sync(loanId)
    local changed = {}
    for _, row in ipairs(BankLoanContracts.Installments(loanId)) do
        if row.status ~= 'paid' and row.obligation_id then
            local current = call('GetObligation', { obligationId = row.obligation_id })
            if current.ok then
                local status = current.value.status
                local mapped = status == 'settled' and 'paid' or (status == 'defaulted' and 'defaulted')
                    or (status == 'due' and 'due') or (current.value.settlementState == 'pending' and 'pending') or 'open'
                if mapped ~= row.status then
                    DB.exec([[UPDATE `bcc_loans_payments` SET `status` = ?,
                        `paid_at` = IF(? = 'paid', NOW(), `paid_at`) WHERE `id` = ?]], mapped, mapped, row.id)
                    if mapped == 'paid' then
                        AddLoanTransaction(loanId, current.value.debtor and current.value.debtor.id, tonumber(row.amount),
                            'loan - repayment', ('Installment %d paid'):format(row.seq))
                    end
                    changed[#changed + 1] = { row = row, status = mapped }
                end
            end
        end
    end
    settleLoanStatus(loanId)
    return changed
end

-- Installment summary for a loan's details page.
function BankLoanContracts.Summary(loanId)
    local rows = BankLoanContracts.Installments(loanId)
    if #rows == 0 then return nil end
    local paidCount, paidAmount, nextRow = 0, 0, nil
    for _, row in ipairs(rows) do
        if row.status == 'paid' then
            paidCount = paidCount + 1
            paidAmount = paidAmount + (tonumber(row.amount) or 0)
        elseif not nextRow then
            nextRow = row
        end
    end
    return {
        total = #rows, paid = paidCount, paidAmount = paidAmount,
        nextAmount = nextRow and tonumber(nextRow.amount) or nil,
        nextDue = nextRow and tostring(nextRow.date_due) or nil,
        nextStatus = nextRow and nextRow.status or nil
    }
end

-- Events and periodic sync -------------------------------------------------------

local function loanForObligation(obligationId)
    return DB.value('SELECT `loan_id` FROM `bcc_loans_payments` WHERE `obligation_id` = ? LIMIT 1', obligationId)
end

local function notifyBorrower(loanId, changes)
    for _, change in ipairs(changes) do
        if change.status == 'due' or change.status == 'defaulted' then
            local loan = GetLoan(loanId)
            if loan and BccBanksInternal and BccBanksInternal.loanInstallmentNotice then
                BccBanksInternal.loanInstallmentNotice(loan, change.row, change.status)
            end
        end
    end
end

local function onObligationEvent(payload)
    if type(payload) ~= 'table' or payload.obligationType ~= TYPE_KEY then return end
    local loanId = loanForObligation(payload.obligationId)
    if loanId then notifyBorrower(loanId, BankLoanContracts.Sync(loanId)) end
end

local subscriptions = {}
local function subscribe()
    for _, token in ipairs(subscriptions) do pcall(function() exports['feather-core']:UnsubscribeEvent(token) end) end
    subscriptions = {}
    for _, name in ipairs({ 'contracts.obligation.due.v1', 'contracts.obligation.defaulted.v1', 'contracts.obligation.settled.v1' }) do
        local subscribed = exports['feather-core']:SubscribeEvent(name, function(payload)
            CreateThread(function() onObligationEvent(payload) end)
        end)
        if type(subscribed) == 'table' and subscribed.ok then
            subscriptions[#subscriptions + 1] = subscribed.value.token
        else
            print(('[bcc-banks] contracts: could not subscribe to %s: %s'):format(name,
                type(subscribed) == 'table' and describe(subscribed) or 'invalid result'))
        end
    end
end

local function register()
    BankLoanContracts.ready = false
    local ready = call('AwaitReady', 30000)
    if not ready.ok then
        return print('[bcc-banks] contracts: feather-contracts is not ready: ' .. describe(ready))
    end
    local _, defaultAfter = loanSettings()
    local registered = call('RegisterObligationType', {
        typeKey = TYPE_KEY,
        label = 'Bank loan installment',
        issuerTypes = { 'system' },
        creditorTypes = { 'organization' },
        debtorTypes = { 'character' },
        currencies = { 'dollars' },
        requiresAcceptance = false,
        debtorMaySettle = true,
        issuerMaySettle = true,
        debtorMayDispute = false,
        maximumDueSeconds = MAX_DUE_SECONDS,
        defaultAfterSeconds = defaultAfter > 0 and defaultAfter or nil
    })
    if not registered.ok then
        return print(('[bcc-banks] contracts: %s not registered: %s'):format(TYPE_KEY, describe(registered)))
    end
    subscribe()
    BankLoanContracts.ready = true
    print('[bcc-banks] contracts: loan installments ready')
end

CreateThread(function()
    while not BccBanksDatabaseReady do Wait(250) end
    register()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE or resource == 'feather-core' then CreateThread(register) end
end)

-- Catches anything an event missed (bcc-banks stopped while Contracts published).
CreateThread(function()
    while true do
        Wait(60000)
        if BankLoanContracts.ready then
            for _, loan in ipairs(DB.query([[SELECT DISTINCT p.`loan_id` FROM `bcc_loans_payments` p
                WHERE p.`status` <> 'paid' AND p.`obligation_id` IS NOT NULL]]) or {}) do
                notifyBorrower(loan.loan_id, BankLoanContracts.Sync(loan.loan_id))
            end
        end
    end
end)
