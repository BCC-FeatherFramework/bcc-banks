-- Mail is handled by sendMailToCharacter in admin.lua via BccBanksInternal
local function getMailboxApi()
    local ok, api = pcall(function()
        return exports['bcc-mailbox']:getMailboxAPI()
    end)
    return ok and api or nil
end

local function formatCurrency(amount)
    local num = tonumber(amount) or 0
    return string.format('%.2f', num)
end

local function safeFormat(fmt, ...)
    if type(fmt) ~= 'string' then return '' end
    local ok, result = pcall(string.format, fmt, ...)
    if ok then return result end
    return fmt
end

local function formatTimestamp(value)
    if value == nil then return nil end
    local num = tonumber(value)
    if num then
        if num > 1e12 then
            num = num / 1000
        end
        return os.date('%Y-%m-%d %H:%M:%S', math.floor(num))
    end
    local str = tostring(value)
    if str == '' then return nil end
    return str
end

BccBanksInternal = BccBanksInternal or {}
BccBanksInternal.getMailboxApi = getMailboxApi
BccBanksInternal.formatCurrency = formatCurrency
BccBanksInternal.safeFormat = safeFormat
BccBanksInternal.formatTimestamp = formatTimestamp

local ActiveLoanRepayments = {}

local function getReminderConfig()
    local timing = Config.LoanTiming or {}
    local reminders = timing.DailyReminders or {}
    return timing, reminders
end

local function getSourceForCharacter(characterId)
    if not characterId then return nil end
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        local session = exports['feather-core']:GetSessionContext(src)
        if type(session) == 'table' and session.ok and type(session.value) == 'table'
            and IdsEqual(session.value.characterId, characterId) then
            return src
        end
    end
    return nil
end

local function canViewLoan(src, loan)
    if not loan then return false end
    if IsBankAdmin and IsBankAdmin(src) then return true end
    local user = GetBankingContext(src)
    local char = user
    local characterId = char and char.characterId
    if not characterId then return false end
    if IdsEqual(loan.character_id, characterId) then return true end
    return loan.account_id and (HasAccountAccess(loan.account_id, characterId) or IsAccountOwner(loan.account_id, characterId)) or false
end

-- Called by server/feather/contracts.lua when an installment falls due (a
-- reminder) or defaults (the borrower's accounts are frozen by then).
function BccBanksInternal.loanInstallmentNotice(loanRow, installment, status)
    local _, reminders = getReminderConfig()
    if reminders.Enabled ~= true then return end
    local info = ComputeLoanOutstanding(loanRow.id)
    local outstanding = tonumber(info and info.outstanding or 0) or 0
    if outstanding <= 0 then return end
    local summary = info and info.installments or {}
    local fromName = reminders.MailFrom or 'Bank Postmaster'
    local subject, body, notice
    if status == 'defaulted' then
        subject = 'Loan Default Notice'
        body = ('Installment %d of your loan #%s is overdue. $%s remains outstanding and your accounts are frozen until it is paid.')
            :format(tonumber(installment.seq) or 0, loanRow.id, formatCurrency(outstanding))
        notice = reminders.NotifyMessage or 'Your bank loan is still outstanding. Visit a bank today to make a payment.'
    else
        local subjectFmt = reminders.MailSubject or 'Loan Payment Reminder'
        local bodyFmt = reminders.MailBody or 'Installment %d of %d for your loan #%s is due. Outstanding balance: $%s. Please visit the bank to avoid default.'
        subject = safeFormat(subjectFmt, tonumber(installment.seq) or 0, summary.total or 0, loanRow.id, formatCurrency(outstanding))
        body = safeFormat(bodyFmt, tonumber(installment.seq) or 0, summary.total or 0, loanRow.id, formatCurrency(outstanding))
        notice = reminders.NotifyMessage or 'Your bank loan is still outstanding. Visit a bank today to make a payment.'
    end
    if reminders.SendMailbox and BccBanksInternal.sendMailToCharacter then
        BccBanksInternal.sendMailToCharacter(loanRow.character_id, fromName, subject, body)
    end
    if reminders.NotifyOnline then
        local src = getSourceForCharacter(loanRow.character_id)
        if src then NotifyClient(src, notice, 'warning', 6000) end
    end
end

exports['feather-core']:RegisterRPC('bcc-banks:GetLoans', function(params, cb, src)
    devPrint('GetLoans RPC called. src=', src, 'params=', params)

    local account_id = NormalizeId(params and params.account)
    local bank_id    = NormalizeId(params and params.bank)

    local user = GetBankingContext(src)
    if not user then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = char.characterId
    if not characterId then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end

    local list
    if account_id then
        if not (HasAccountAccess(account_id, characterId) or IsAccountOwner(account_id, characterId)) then
            NotifyClient(src, Feather.Locale.translateUpper('error_insufficient_access'), 'error', 4000)
            cb(false)
            return
        end
        list = GetLoansForAccount(account_id)
    elseif bank_id then
        list = GetLoansForCharacterBank(characterId, bank_id)
    else
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_bank') or 'Invalid bank.', 'error', 4000)
        cb(false)
        return
    end
    local targetBankId = bank_id or GetBankIdForAccount(account_id)
    if not targetBankId or not IsPlayerNearBank(src, targetBankId) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end
    list = list or {}
    for _, loan in ipairs(list) do
        loan.created_at_display = (BccBanksInternal and BccBanksInternal.formatTimestamp and BccBanksInternal.formatTimestamp(loan.created_at)) or formatTimestamp(loan.created_at)
        loan.amount_formatted = formatCurrency(loan.amount)
    end
    cb(true, list)
end)

exports['feather-core']:RegisterRPC('bcc-banks:GetLoan', function(params, cb, src)
    local loan_id = NormalizeId(params and params.loan)
    if not loan_id then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_loan_id'), 'error', 4000)
        cb(false)
        return
    end
    local loan = GetLoan(loan_id)
    if not canViewLoan(src, loan) then
        NotifyClient(src, Feather.Locale.translateUpper('error_no_permission'), 'error', 4000)
        cb(false)
        return
    end
    if not IsBankAdmin(src) and not IsPlayerNearBank(src, loan.bank_id) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end
    local info = ComputeLoanOutstanding(loan_id)
    if not info then
        NotifyClient(src, Feather.Locale.translateUpper('error_loan_not_found'), 'error', 4000)
        cb(false)
        return
    end
    cb(true, info)
end)

exports['feather-core']:RegisterRPC('bcc-banks:GetLoanTransactions', function(params, cb, src)
    local loan_id = NormalizeId(params and params.loan)
    if not loan_id then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_loan_id'), 'error', 4000)
        cb(false)
        return
    end

    local loan = GetLoan(loan_id)
    if not loan then
        NotifyClient(src, Feather.Locale.translateUpper('error_loan_not_found'), 'error', 4000)
        cb(false)
        return
    end

    if not canViewLoan(src, loan) then
        NotifyClient(src, Feather.Locale.translateUpper('error_no_permission'), 'error', 4000)
        cb(false)
        return
    end
    if not IsBankAdmin(src) and not IsPlayerNearBank(src, loan.bank_id) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local transactions = GetLoanTransactions(loan_id)
    for _, tx in ipairs(transactions or {}) do
        tx.amount_formatted = formatCurrency(tx.amount)
        tx.created_at_display = BccBanksInternal and BccBanksInternal.formatTimestamp and BccBanksInternal.formatTimestamp(tx.created_at) or formatTimestamp(tx.created_at)
    end

    cb(true, transactions or {})
end)

exports['feather-core']:RegisterRPC('bcc-banks:ClaimLoanDisbursement', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char or not char.characterId then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = char.characterId

    local loan_id    = NormalizeId(params and params.loan)
    local account_id = NormalizeId(params and params.account)
    if not loan_id or not account_id then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_input'), 'error', 4000)
        cb(false)
        return
    end

    local claimLoan = GetLoan(loan_id)
    if not claimLoan or not IsPlayerNearBank(src, claimLoan.bank_id) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local res = ClaimLoanToAccount(loan_id, account_id, characterId)
    if not res or res.status == false then
        NotifyClient(src, (res and res.message) or Feather.Locale.translateUpper('error_unable_create_loan'), 'error', 4000)
        cb(false)
        return
    end
    NotifyClient(src, Feather.Locale.translateUpper('success_loan_disbursed') or 'Loan funds transferred to account.', 'success', 4000)
    local loan = res.loan or {}
    local lines = {
        '**Action:** `Loan Disbursement Claimed`',
        '**Loan ID:** `' .. tostring(loan.id or loan_id) .. '`',
        '**Account ID:** `' .. tostring(account_id) .. '`',
        '**Amount:** `$' .. tostring(loan.amount or 'Unknown') .. '`',
        '**Bank:** `' .. tostring(BccBanksInternal.getBankName(loan.bank_id or GetBankIdForAccount(account_id))) .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Loan Disbursement Claimed', lines, 5763719)
    cb(true, res.loan)
end)

exports['feather-core']:RegisterRPC('bcc-banks:CreateLoan', function(params, cb, src)
    devPrint('CreateLoan RPC called. src=', src, 'params=', params)

    local user = GetBankingContext(src)
    if not user then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = char.characterId
    if not characterId then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end

    local account_id = NormalizeId(params and params.account)
    local bankId     = NormalizeId(params and params.bank)
    local amount     = tonumber(params and params.amount)
    local duration   = tonumber(params and params.duration) or 0

    if (not account_id and not bankId) or not IsFinitePositiveNumber(amount)
        or not IsFinitePositiveNumber(duration) or duration % 1 ~= 0 or duration > 120 then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_input'), 'error', 4000)
        cb(false)
        return
    end

    -- Derive bank from account if provided; otherwise require bankId
    if account_id then
        bankId = bankId or GetBankIdForAccount(account_id)
        if not (IsAccountOwner(account_id, characterId) or IsAccountAdmin(account_id, characterId)) then
            NotifyClient(src, Feather.Locale.translateUpper('error_insufficient_access'), 'error', 4000)
            cb(false)
            return
        end
    elseif not bankId then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_bank') or 'Invalid bank.', 'error', 4000)
        cb(false)
        return
    end

    if not IsPlayerNearBank(src, bankId) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    -- Applications started from the bank-level loan menu do not provide an
    -- account. Create the dedicated account promised by the UI before saving
    -- the loan, then roll it back if the loan insert fails.
    local autoCreatedAccountId
    if not account_id then
        local accountResult = CreateAccountReturn(Feather.Locale.translateUpper('loan_account_default_name') or 'Loan Account', characterId, bankId)
        if not accountResult or accountResult.status == false or not accountResult.account then
            NotifyClient(src, (accountResult and accountResult.message) or Feather.Locale.translateUpper('error_unable_create_loan'), 'error', 4000)
            cb(false)
            return
        end
        account_id = NormalizeId(accountResult.account.id)
        autoCreatedAccountId = account_id
    end

    -- Compute interest server-side for this character (and bank)
    local interest = GetCharacterLoanInterest(characterId, bankId)
    local res = CreateLoan(account_id, characterId, amount, interest, duration, bankId)
    if not res or res.status == false then
        if autoCreatedAccountId then
            DB.exec('DELETE FROM `bcc_accounts_access` WHERE `account_id` = ?', autoCreatedAccountId)
            DB.exec('DELETE FROM `bcc_accounts` WHERE `id` = ? AND `cash` = 0 AND `gold` = 0', autoCreatedAccountId)
        end
        NotifyClient(src, res and res.message or Feather.Locale.translateUpper('error_unable_create_loan'), 'error', 4000)
        cb(false)
        return
    end

    -- Inform user that the loan application is pending approval
    NotifyClient(src, Feather.Locale.translateUpper('success_loan_created') or 'Loan application submitted for approval.', 'success', 4000)
    local loan = res.loan or {}
    local lines = {
        '**Action:** `Loan Created`',
        '**Loan ID:** `' .. tostring(loan.id or 'Pending') .. '`',
        '**Account ID:** `' .. tostring(account_id or 'None') .. '`',
        '**Bank:** `' .. tostring(BccBanksInternal.getBankName(bankId)) .. '`',
        '**Amount:** `$' .. tostring(amount) .. '`',
        '**Interest:** `' .. tostring(interest) .. '%`',
        '**Duration:** `' .. tostring(duration) .. ' days`',
        '**Status:** `' .. tostring(loan.status or 'pending') .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Loan Application Created', lines, 3447003)
    AddLoanTransaction(loan.id, characterId, amount, 'loan - application', 'Loan application submitted')
    cb(true, res.loan)
end)

exports['feather-core']:RegisterRPC('bcc-banks:GetLoanRate', function(params, cb, src)
    local user = GetBankingContext(src)
    if not user then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = char.characterId
    if not characterId then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local account_id = NormalizeId(params and params.account)
    if account_id and not (HasAccountAccess(account_id, characterId) or IsAccountOwner(account_id, characterId)) then
        NotifyClient(src, Feather.Locale.translateUpper('error_insufficient_access'), 'error', 4000)
        cb(false)
        return
    end
    local bankId = account_id and GetBankIdForAccount(account_id) or NormalizeId(params and params.bank)
    if not bankId or not IsPlayerNearBank(src, bankId) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end
    local rate = GetCharacterLoanInterest(characterId, bankId)
    cb(true, rate)
end)

-- Due dates, defaults and account freezes come from feather-contracts
-- (server/feather/contracts.lua); there is no in-game day counter any more.

exports['feather-core']:RegisterRPC('bcc-banks:RepayLoan', function(params, cb, src)
    devPrint('RepayLoan RPC called. src=', src, 'params=', params)

    local user = GetBankingContext(src)
    if not user then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end
    local characterId = char.characterId
    if not characterId then
        NotifyClient(src, Feather.Locale.translateUpper('error_character_not_found'), 'error', 4000)
        cb(false)
        return
    end

    local loan_id   = NormalizeId(params and params.loan)
    local amount    = tonumber(params and params.amount)

    if not loan_id or not IsFinitePositiveNumber(amount) then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_input'), 'error', 4000)
        cb(false)
        return
    end

    -- Prevent repayment of loans that are not approved yet
    local loanRow = GetLoan(loan_id)
    if not loanRow then
        NotifyClient(src, Feather.Locale.translateUpper('error_loan_not_found'), 'error', 4000)
        cb(false)
        return
    end

    if not IsPlayerNearBank(src, loanRow.bank_id) then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end
    local status = tostring(loanRow.status)
    local isDefaulted = status == 'defaulted' or tonumber(loanRow.is_defaulted) == 1
    if status == 'paid' then
        NotifyClient(src, Feather.Locale.translateUpper('error_loan_already_paid') or 'Loan already fully repaid.', 'success', 4000)
        cb(false)
        return
    elseif status ~= 'approved' and not isDefaulted then
        NotifyClient(src, Feather.Locale.translateUpper('error_loan_not_approved') or 'Loan has not been approved yet.', 'error', 4000)
        cb(false)
        return
    end

    if not IdsEqual(loanRow.character_id, characterId) then
        NotifyClient(src, Feather.Locale.translateUpper('error_no_permission') or 'No permission.', 'error', 4000)
        cb(false)
        return
    end
    if ActiveLoanRepayments[loan_id] then
        NotifyClient(src, Feather.Locale.translateUpper('error_loan_operation_busy'), 'error', 4000)
        cb(false)
        return
    end
    ActiveLoanRepayments[loan_id] = true
    if not AcquirePlayerFinancialLock(src) then
        ActiveLoanRepayments[loan_id] = nil
        NotifyClient(src, Feather.Locale.translateUpper('error_financial_operation_busy'), 'error', 4000)
        cb(false)
        return
    end

    -- Whole installments, oldest first, paid from the wallet through feather-contracts.
    local paid = BankLoanContracts.Pay(loanRow, amount, { actorSource = src })
    if not paid.ok then
        ReleasePlayerFinancialLock(src)
        ActiveLoanRepayments[loan_id] = nil
        if paid.code == 'below_installment' then
            NotifyClient(src, Feather.Locale.translateUpper('error_repay_below_installment', ('%.2f'):format(paid.next or 0)), 'error', 4000)
        elseif paid.code == 'insufficient_funds' then
            NotifyClient(src, Feather.Locale.translateUpper('error_not_enough_cash', tostring(char.money or 0)), 'error', 4000)
        elseif paid.code == 'settlement_pending' then
            NotifyClient(src, Feather.Locale.translateUpper('loan_payment_pending'), 'warning', 5000)
        else
            NotifyClient(src, Feather.Locale.translateUpper('error_unable_repay_loan'), 'error', 4000)
        end
        cb(false)
        return
    end
    amount = paid.amount
    local after = ComputeLoanOutstanding(loan_id)

    NotifyClient(src, Feather.Locale.translateUpper('success_loan_repaid'), 'success', 4000)
    local remaining = after and after.outstanding or nil
    local lines = {
        '**Action:** `Loan Repaid`',
        '**Loan ID:** `' .. tostring(loan_id) .. '`',
        '**Amount Paid:** `$' .. tostring(amount) .. '`',
        '**Remaining Balance:** `$' .. tostring(remaining or 'Unknown') .. '`',
        '**Status:** `' .. tostring((remaining and remaining <= 0) and 'paid' or 'active') .. '`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Loan Repayment', lines, 3066993)
    ReleasePlayerFinancialLock(src)
    ActiveLoanRepayments[loan_id] = nil
    cb(true)
end)
