function CreateLoan(account_id, character_id, amount, interest, duration, bank_id)
    if (not account_id and not bank_id) or not character_id or not amount or amount <= 0 then
        return { status = false, message = 'Invalid loan data.' }
    end

    -- Duration is in months from UI; compute due in game days (30 days per month) unless overridden
    local months = tonumber(duration) or 0
    local due_game_days = months * 30
    local timingCfg = Config.LoanTiming or {}
    local overrideDays = tonumber(timingCfg.DaysUntilDefault or 0)
    if overrideDays and overrideDays > 0 then
        due_game_days = overrideDays
    end
    if due_game_days < 1 then
        due_game_days = 1
    end

    -- Seed last_game_day from weathersync so we can track days passed
    local day = 0
    if exports and exports.weathersync and exports.weathersync.getTime then
        local t = exports.weathersync:getTime() or {}
        day = tonumber(t.day) or 0
    end

    local loanId = DB.value('SELECT UUID()')
    local loanRows = DB.query(
        'INSERT INTO `bcc_loans` (id, account_id, bank_id, character_id, amount, interest, duration, status, last_game_day, game_days_elapsed, due_game_days) VALUES (?, ?, ?, ?, ?, ?, ?, \'pending\', ?, 0, ?) RETURNING *;',
        loanId, account_id, bank_id, character_id, amount, interest or 0, months, day, due_game_days
    )

    local loan = loanRows and loanRows[1]
    if not loan then
        return { status = false, message = 'Failed to create loan.' }
    end

    return { status = true, loan = loan }
end

function GetLoan(loan_id)
    local row = DB.query('SELECT * FROM `bcc_loans` WHERE `id` = ? LIMIT 1;', loan_id)
    return row and row[1]
end

function GetLoansForAccount(account_id)
    local rows = DB.query('SELECT * FROM `bcc_loans` WHERE `account_id` = ? ORDER BY `created_at` DESC;', account_id)
    return rows or {}
end

-- New: list loans by character and bank (no account)
function GetLoansForCharacterBank(character_id, bank_id)
    local rows = DB.query('SELECT * FROM `bcc_loans` WHERE `character_id` = ? AND `bank_id` = ? ORDER BY `created_at` DESC;', character_id, bank_id)
    return rows or {}
end

local function roundCurrency(value)
    value = tonumber(value) or 0
    return math.floor(value * 100 + 0.5) / 100
end

function ComputeLoanOutstanding(loan_id)
    local loan = GetLoan(loan_id)
    if not loan then return nil end
    local baseAmount = tonumber(loan.amount) or 0
    local interestPercent = tonumber(loan.interest) or 0
    local totalDue = roundCurrency(baseAmount * (1 + (interestPercent / 100)))
    -- Once approved, the loan is owed as Contracts installments (server/feather/contracts.lua).
    local installments = BankLoanContracts and BankLoanContracts.Summary(loan_id) or nil
    local repaid = roundCurrency(installments and installments.paidAmount or SumLoanRepayments(loan_id))
    local outstanding = totalDue - repaid
    if math.abs(outstanding) < 0.005 then outstanding = 0 end
    if outstanding < 0 then outstanding = 0 end
    outstanding = roundCurrency(outstanding)
    return {
        total_due = totalDue,
        repaid = repaid,
        outstanding = outstanding,
        installments = installments,
        loan = loan
    }
end

local function loanTotalDue(loan)
    local baseAmount = tonumber(loan.amount) or 0
    return roundCurrency(baseAmount * (1 + ((tonumber(loan.interest) or 0) / 100)))
end

-- Opens the loan's installments, then pays the principal from the branch reserve
-- into `accountId`. A failed payout cancels the installments again, so a loan is
-- never disbursed without its debt or owed without its money.
local function disburseWithInstallments(loan, accountId)
    local opened = BankLoanContracts.OpenInstallments(loan, loanTotalDue(loan))
    if not opened.ok then
        print(('[bcc-banks] loan %s: installments not opened: %s %s'):format(tostring(loan.id),
            tostring(opened.code), tostring(opened.message or '')))
        BankLoanContracts.CancelInstallments(loan.id, 'banks.loan.open_failed')
        return false
    end
    if not DepositCash(accountId, tonumber(loan.amount) or 0, 'bank.loan.disbursement', loan.bank_id) then
        BankLoanContracts.CancelInstallments(loan.id, 'banks.loan.disbursement_failed')
        return false
    end
    return true
end

-- Approve a loan: disburse funds and set status/approver metadata
function ApproveLoan(loan_id, approver_char_id)
    local loan = GetLoan(loan_id)
    if not loan then return { status = false, message = 'Loan not found.' } end
    if loan.status == 'approved' then
        if loan.account_id and not loan.disbursed_account_id then
            return { status = false, message = 'Loan approval is already being processed.' }
        end
        return { status = true, loan = loan }
    end
    if loan.status == 'rejected' or loan.is_defaulted == 1 then
        return { status = false, message = 'Cannot approve rejected/defaulted loan.' }
    end

    -- Atomically transition pending -> approved before disbursing. Concurrent admin
    -- requests cannot both pass this reservation.
    local day = loan.last_game_day or 0
    if exports and exports.weathersync and exports.weathersync.getTime then
        local t = exports.weathersync:getTime() or {}
        day = tonumber(t.day) or day or 0
    end
    local reserved = DB.exec(
        'UPDATE `bcc_loans` SET `status` = \'approved\', `approved_by` = ?, `approved_at` = NOW(), `last_game_day` = ? WHERE `id` = ? AND `status` = \'pending\'',
        approver_char_id, day, loan_id
    )
    if (tonumber(reserved) or 0) ~= 1 then
        return { status = false, message = 'Loan is no longer pending.' }
    end

    -- Disbursement: if account linked, deposit now; otherwise leave funds claimable.
    local amt = tonumber(loan.amount) or 0
    if loan.account_id then
        local ok = disburseWithInstallments(loan, loan.account_id)
        if not ok then
            DB.exec(
                'UPDATE `bcc_loans` SET `status` = \'pending\', `approved_by` = NULL, `approved_at` = NULL WHERE `id` = ? AND `disbursed_account_id` IS NULL',
                loan_id
            )
            return { status = false, message = 'Failed to disburse funds to account.' }
        end
        local disburseDesc = _U and Feather.Locale.translateUpper('loan_disbursement_desc') or 'Loan disbursed to account'
        AddLoanTransaction(loan.id, loan.character_id, amt, 'loan - disbursement', disburseDesc)
        DB.exec('UPDATE `bcc_loans` SET `disbursed_account_id` = ?, `disbursed_at` = NOW() WHERE `id` = ?', loan.account_id, loan.id)
    else
        -- No immediate disbursement; player can claim to their chosen account later
    end

    local updated = GetLoan(loan_id)
    return { status = true, loan = updated }
end

-- Claim approved loan funds into a selected account
function ClaimLoanToAccount(loan_id, account_id, character_id)
    local loan = GetLoan(loan_id)
    if not loan then return { status = false, message = 'Loan not found.' } end
    if tostring(loan.status) ~= 'approved' then
        return { status = false, message = 'Loan is not approved.' }
    end
    if loan.disbursed_account_id then
        return { status = false, message = 'Loan funds already disbursed.' }
    end
    if not IdsEqual(loan.character_id, character_id) then
        return { status = false, message = 'No permission.' }
    end
    local acc = GetAccount(account_id)
    if not acc then
        return { status = false, message = 'Invalid account.' }
    end
    if loan.bank_id and acc.bank_id and not IdsEqual(loan.bank_id, acc.bank_id) then
        return { status = false, message = 'Account is not at the same bank.' }
    end
    if not (IsAccountOwner(account_id, character_id) or IsAccountAdmin(account_id, character_id)) then
        return { status = false, message = 'Insufficient Access.' }
    end
    -- Reserve the one-time claim before crediting the account. Only one concurrent
    -- request can change a NULL disbursement marker.
    local reserved = DB.exec(
        'UPDATE `bcc_loans` SET `disbursed_account_id` = ?, `disbursed_at` = NOW() WHERE `id` = ? AND `status` = \'approved\' AND `disbursed_account_id` IS NULL',
        account_id, loan.id
    )
    if (tonumber(reserved) or 0) ~= 1 then
        return { status = false, message = 'Loan funds already disbursed.' }
    end

    local amt = tonumber(loan.amount) or 0
    local ok = disburseWithInstallments(loan, account_id)
    if not ok then
        DB.exec(
            'UPDATE `bcc_loans` SET `disbursed_account_id` = NULL, `disbursed_at` = NULL WHERE `id` = ? AND `disbursed_account_id` = ?',
            loan.id, account_id
        )
        return { status = false, message = 'Unable to deposit into the selected account.' }
    end
        local claimDesc = _U and Feather.Locale.translateUpper('loan_claim_transaction_desc') or 'Loan disbursed to account (claimed)'
        AddLoanTransaction(loan.id, loan.character_id, amt, 'loan - disbursement', claimDesc)
    local updated = GetLoan(loan_id)
    return { status = true, loan = updated }
end

function RejectLoan(loan_id, approver_char_id)
    local loan = GetLoan(loan_id)
    if not loan then return { status = false, message = 'Loan not found.' } end
    if loan.status == 'approved' then
        return { status = false, message = 'Loan already approved.' }
    end
    DB.exec('UPDATE `bcc_loans` SET `status` = \'rejected\', `approved_by` = ?, `approved_at` = NOW() WHERE `id` = ?', approver_char_id, loan_id)
    local updated = GetLoan(loan_id)
    return { status = true, loan = updated }
end


-- Determine interest rate for a character (optionally by bank)
function GetCharacterLoanInterest(character_id, bank_id)
    if not character_id then return 10.0 end
    local function queryRate(sql, params)
        local ok, rows = pcall(DB.query, sql, table.unpack(params))
        if not ok then
            devPrint('Loan interest lookup failed:', tostring(rows))
            return nil
        end
        local rate = rows and rows[1] and tonumber(rows[1].interest) or nil
        if not rate or rate ~= rate or rate < 0 or rate > 100 then return nil end
        return rate
    end

    -- 1) character + bank specific override
    if bank_id then
        local rate = queryRate('SELECT `interest` FROM `bcc_loan_interest_rates` WHERE `character_id` = ? AND `bank_id` = ? LIMIT 1;', { character_id, bank_id })
        if rate then return rate end

        -- 2) bank default rate
        rate = queryRate('SELECT `interest` FROM `bcc_bank_interest_rates` WHERE `bank_id` = ? LIMIT 1;', { bank_id })
        if rate then return rate end
    end

    -- 3) character global default
    local rate = queryRate('SELECT `interest` FROM `bcc_loan_interest_rates` WHERE `character_id` = ? AND `bank_id` = ? LIMIT 1;', { character_id, '0' })
    if rate then return rate end

    -- 4) fallback
    return 10.0
end

-- Helper to fetch bank_id from account
function GetBankIdForAccount(account_id)
    local acc = GetAccount(account_id)
    return acc and acc.bank_id or nil
end
