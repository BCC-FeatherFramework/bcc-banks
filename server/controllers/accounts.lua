local LockedAccounts = {}

if not _G.__bcc_accounts_rng_seeded then
    local seed = (os.time() % 100000)
    local ptr = tonumber(string.sub(tostring({}), 8)) or 0
    seed = seed + ptr
    math.randomseed(seed)
    -- warm-up calls to avoid low-quality initial outputs on some Lua implementations
    math.random(); math.random(); math.random()
    _G.__bcc_accounts_rng_seeded = true
end

function GetAccountCount(owner, bank)
    local result = DB.query(
        'SELECT COUNT(*) AS cnt FROM `bcc_accounts` WHERE `owner_id` = ? AND `bank_id` = ?',
        owner, bank
    )
    local row = result and result[1]
    return tonumber(row and (row.cnt or row["COUNT(*)"])) or 0
end

local function ToUnits(amount)
    return math.floor((tonumber(amount) or 0) * 100 + 0.5)
end

local function FromUnits(amount)
    return (tonumber(amount) or 0) / 100
end

local function EnsureEconomyAccounts(account)
    if not account then return nil end
    local changed = false
    for _, definition in ipairs({
        { column = 'dollars_account_id', currency = 'dollars' },
        { column = 'gold_account_id', currency = 'gold' }
    }) do
        if not account[definition.column] then
            local created = BanksEconomy.CreateAccount({
                ownerType = 'character', ownerId = tostring(account.owner_id),
                accountType = 'bank', currency = definition.currency,
                label = tostring(account.name), reasonCode = 'banks.account.create',
                referenceType = 'bcc_bank_account', referenceId = tostring(account.id),
                idempotencyKey = ('banks:account:%s:%s'):format(account.id, definition.currency)
            })
            if not created.ok then return nil, created end
            account[definition.column] = created.value.accountId
            changed = true
        end
    end
    if changed then
        DB.exec([[UPDATE bcc_accounts SET dollars_account_id = ?, gold_account_id = ?
            WHERE id = ?]], account.dollars_account_id, account.gold_account_id, account.id)
    end

    -- Import each legacy balance once. Idempotency makes this restart-safe.
    for _, definition in ipairs({
        { column = 'dollars_account_id', currency = 'dollars', legacy = 'cash' },
        { column = 'gold_account_id', currency = 'gold', legacy = 'gold' }
    }) do
        local units = ToUnits(account[definition.legacy])
        if units > 0 then
            local imported = BanksEconomy.Issue({
                toAccountId = account[definition.column], currency = definition.currency,
                amount = units, reasonCode = 'bank.migration.import',
                referenceType = 'bcc_bank_account', referenceId = tostring(account.id),
                idempotencyKey = ('banks:legacy:%s:%s'):format(account.id, definition.currency)
            })
            if not imported.ok then return nil, imported end
        end
    end
    local dollars = BanksEconomy.GetBalance({ accountId = account.dollars_account_id })
    local gold = BanksEconomy.GetBalance({ accountId = account.gold_account_id })
    if not dollars.ok or not gold.ok then return nil, dollars.ok and gold or dollars end
    account.cash = FromUnits(dollars.value.postedAmount)
    account.gold = FromUnits(gold.value.postedAmount)
    return account
end

function CreateAccount(name, owner, bank)
    devPrint("CreateAccount called with:", name, owner, bank)

    if not owner or not bank then
        devPrint("Error: owner or bank is nil.")
        return { status = false, message = "Owner or bank is invalid." }
    end

    local currentAccounts = GetAccountCount(owner, bank)
    if Config.Accounts.MaxAccounts ~= 0 and currentAccounts >= Config.Accounts.MaxAccounts then
        return { status = false, message = "Maximum accounts reached: " .. Config.Accounts.MaxAccounts }
    end

    -- Generate unique 8-digit account number
    local function generate8()
        -- range 10,000,000..99,999,999 (no leading zero)
        return tostring(math.random(10000000, 99999999))
    end
    local function nextUniqueAccountNumber()
        for i = 1, 20 do
            local candidate = generate8()
            local exists = DB.query('SELECT 1 FROM `bcc_accounts` WHERE `account_number` = ? LIMIT 1;', candidate)
            if not exists or not exists[1] then
                return candidate
            end
        end
        -- Fallback: extremely unlikely to hit here; append a random 2-digit suffix and try again
        for i = 1, 80 do
            local candidate = tostring(math.random(10, 99)) .. tostring(math.random(1000000, 9999999))
            local exists = DB.query('SELECT 1 FROM `bcc_accounts` WHERE `account_number` = ? LIMIT 1;', candidate)
            if not exists or not exists[1] then
                return candidate
            end
        end
        return generate8()
    end

    local acctNum = nextUniqueAccountNumber()

    local accountId = DB.value('SELECT UUID()')
    local result = DB.query(
        'INSERT INTO `bcc_accounts` (id, account_number, name, bank_id, owner_id) VALUES (?, ?, ?, ?, ?) RETURNING *;',
        accountId, acctNum, name, bank, owner
    )
    local account = result and result[1]
    account = account and EnsureEconomyAccounts(account) or nil

    if account then
        DB.exec(
            'INSERT INTO `bcc_accounts_access` (`account_id`, `character_id`, `level`) VALUES (?, ?, ?)',
            account.id, owner, Config.AccessLevels.Admin
        )
    end

    return GetAccounts(owner, bank)
end

-- Create an account and return the created row (used for auto-loan accounts)
function CreateAccountReturn(name, owner, bank)
    if not owner or not bank then
        return { status = false, message = "Owner or bank is invalid." }
    end

    local currentAccounts = GetAccountCount(owner, bank)
    if Config.Accounts.MaxAccounts ~= 0 and currentAccounts >= Config.Accounts.MaxAccounts then
        return { status = false, message = "Maximum accounts reached: " .. Config.Accounts.MaxAccounts }
    end

    local function generate8()
        return tostring(math.random(10000000, 99999999))
    end
    local function nextUniqueAccountNumber()
        for i = 1, 20 do
            local candidate = generate8()
            local exists = DB.query('SELECT 1 FROM `bcc_accounts` WHERE `account_number` = ? LIMIT 1;', candidate)
            if not exists or not exists[1] then
                return candidate
            end
        end
        for i = 1, 80 do
            local candidate = tostring(math.random(10, 99)) .. tostring(math.random(1000000, 9999999))
            local exists = DB.query('SELECT 1 FROM `bcc_accounts` WHERE `account_number` = ? LIMIT 1;', candidate)
            if not exists or not exists[1] then
                return candidate
            end
        end
        return generate8()
    end

    local acctNum = nextUniqueAccountNumber()

    local accountId = DB.value('SELECT UUID()')
    local result = DB.query(
        'INSERT INTO `bcc_accounts` (id, account_number, name, bank_id, owner_id) VALUES (?, ?, ?, ?, ?) RETURNING *;',
        accountId, acctNum, name, bank, owner
    )
    local account = result and result[1]
    account = account and EnsureEconomyAccounts(account) or nil

    if not account then
        return { status = false, message = 'Failed to create account.' }
    end

    DB.exec(
        'INSERT INTO `bcc_accounts_access` (`account_id`, `character_id`, `level`) VALUES (?, ?, ?)',
        account.id, owner, Config.AccessLevels.Admin
    )

    return { status = true, account = account }
end

function CloseAccount(bank, account, character)
    local accountDetails = GetAccount(account)
    if not accountDetails then
        return { status = false, message = "Can't find account." }
    end

    if accountDetails.gold > 0 or accountDetails.cash > 0 then
        return { status = false, message = "Unable to close. Withdraw funds first." }
    end

    if not IsAccountAdmin(account, character) then
        return { status = false, message = "Insufficient Access." }
    end

    DB.exec('DELETE FROM `bcc_accounts` WHERE `id` = ?', account)
    return { status = true, accounts = GetAccounts(character, bank) }
end

function GetAccounts(characterId, bankId)
    local accounts = DB.query(
        'SELECT ' ..
        'a.id, ' ..
        'a.name AS account_name, ' ..
        'a.owner_id, ' ..
        'COALESCE(aa.level, 1) AS level ' ..
        'FROM bcc_accounts AS a ' ..
        'LEFT JOIN bcc_accounts_access AS aa ' ..
        '  ON a.id = aa.account_id ' ..
        ' AND aa.character_id = ? ' ..
        'INNER JOIN bcc_banks AS b ' ..
        '  ON b.id = a.bank_id ' ..
        'WHERE (a.owner_id = ? OR aa.character_id = ?) ' ..
        '  AND b.id = ?;',
        characterId, characterId, characterId, bankId
    )

    return accounts or {}
end

function GetAccount(account)
    local result = DB.query('SELECT * FROM `bcc_accounts` WHERE `id` = ?', account)
    local row = result and result[1] or nil
    return row and EnsureEconomyAccounts(row) or nil
end

-- Find account by external account_number (UUID-like)
function GetAccountByNumber(accountNumber)
    if not accountNumber or accountNumber == '' then return nil end
    local row = DB.query('SELECT * FROM `bcc_accounts` WHERE `account_number` = ? LIMIT 1;', accountNumber)
    local account = row and row[1] or nil
    return account and EnsureEconomyAccounts(account) or nil
end

-- Public listing: list all accounts under a bank (minimal fields)
function GetAccountsByBankPublic(bankId)
    local rows = DB.query(
        'SELECT id, name, account_number FROM `bcc_accounts` WHERE `bank_id` = ? ORDER BY `name` ASC, `id` ASC;',
        bankId
    )
    return rows or {}
end

function AddAccountAccess(account, character, level)
    DB.exec(
        'INSERT INTO `bcc_accounts_access` (`account_id`, `character_id`, `level`) VALUES (?, ?, ?);',
        account, character, level
    )
    return true
end

function IsAccountOwner(account, character)
    local result = DB.query(
        'SELECT `owner_id` FROM `bcc_accounts` WHERE `id` = ? LIMIT 1;',
        account
    )
    local owner = result and result[1] and result[1].owner_id
    return owner == character
end

function IsAccountAdmin(account, character)
    local result = DB.query(
        'SELECT `level` FROM `bcc_accounts_access` WHERE `account_id` = ? AND `character_id` = ? LIMIT 1;',
        account, character
    )
    local record = result and result[1]
    return record and tonumber(record.level) == Config.AccessLevels.Admin
end

function HasAccountAccess(account, character)
    local result = DB.query(
        'SELECT 1 FROM `bcc_accounts_access` WHERE `account_id` = ? AND `character_id` = ? LIMIT 1;',
        account, character
    )
    return result and result[1] ~= nil
end

function GetAccountAccess(account, character)
    local result = DB.query(
        'SELECT `level` FROM `bcc_accounts_access` WHERE `account_id` = ? AND `character_id` = ? LIMIT 1;',
        account, character
    )
    return result and result[1] and tonumber(result[1].level) or 0
end

-- Moves money between a bank account and a branch reserve (loan disbursement and
-- repayment, checks, rollbacks). The reserve is the account's own branch unless
-- `reserveBankId` names another one. `reason` is one of the bank.* reserve codes
-- Economy accepts; wallet <-> account movements use DepositFromWallet / WithdrawToWallet.
local function reserveTransfer(account, currency, amount, reason, reserveBankId, toAccount)
    amount = tonumber(amount)
    if not account or not IsFinitePositiveNumber(amount) then return false end
    local row = GetAccount(account)
    if not row then return false end
    if not toAccount and (row.is_frozen == 1 or row.is_frozen == true) then return false end
    local reserveId = BankOrganizations.GetReserveAccountId(reserveBankId or row.bank_id, currency)
    if not reserveId then return false end
    local accountId = currency == 'gold' and row.gold_account_id or row.dollars_account_id
    return BanksEconomy.Transfer({
        fromAccountId = toAccount and reserveId or accountId,
        toAccountId = toAccount and accountId or reserveId,
        currency = currency, amount = ToUnits(amount), reasonCode = reason or 'bank.compensation',
        referenceType = 'bcc_bank_account', referenceId = tostring(account),
        idempotencyKey = ('banks:%s:%s'):format(toAccount and 'deposit' or 'withdraw', DB.value('SELECT UUID()'))
    }).ok
end

function DepositCash(account, amount, reason, reserveBankId)
    return reserveTransfer(account, 'dollars', amount, reason, reserveBankId, true)
end

function DepositGold(account, amount, reason, reserveBankId)
    return reserveTransfer(account, 'gold', amount, reason, reserveBankId, true)
end

function WithdrawCash(account, amount, reason, reserveBankId)
    return reserveTransfer(account, 'dollars', amount, reason, reserveBankId, false)
end

function WithdrawGold(account, amount, reason, reserveBankId)
    return reserveTransfer(account, 'gold', amount, reason, reserveBankId, false)
end

-- Moves funds from the acting character's wallet into a bank account in one
-- Economy transfer, so the wallet debit and the account credit either both
-- happen or neither does. Access to the account is checked by the caller.
function DepositFromWallet(char, account, currency, amount)
    amount = tonumber(amount)
    if not char or not char.wallets or not char.wallets[currency]
        or not account or not IsFinitePositiveNumber(amount) then return false end
    local row = GetAccount(account)
    local target = row and row[currency .. '_account_id']
    if not target then return false end
    return BanksEconomy.Transfer({ fromAccountId = char.wallets[currency].accountId,
        toAccountId = target, currency = currency, amount = ToUnits(amount),
        reasonCode = 'bank.deposit', referenceType = 'bcc_bank_account', referenceId = tostring(account),
        idempotencyKey = ('banks:deposit:%s'):format(DB.value('SELECT UUID()')),
        actorCharacterId = char.characterId, actorAccountId = char.accountId }).ok
end

-- The reverse: bank account to the acting character's wallet, one transfer.
-- A frozen account cannot be withdrawn from.
function WithdrawToWallet(char, account, currency, amount)
    amount = tonumber(amount)
    if not char or not char.wallets or not char.wallets[currency]
        or not account or not IsFinitePositiveNumber(amount) then return false end
    local row = GetAccount(account)
    if not row or row.is_frozen == 1 or row.is_frozen == true then return false end
    local source = row[currency .. '_account_id']
    if not source then return false end
    return BanksEconomy.Transfer({ fromAccountId = source,
        toAccountId = char.wallets[currency].accountId, currency = currency, amount = ToUnits(amount),
        reasonCode = 'bank.withdraw', referenceType = 'bcc_bank_account', referenceId = tostring(account),
        idempotencyKey = ('banks:withdraw:%s'):format(DB.value('SELECT UUID()')),
        actorCharacterId = char.characterId, actorAccountId = char.accountId }).ok
end

function TransferAccountCash(fromAccount, toAccount, debitAmount, creditAmount)
    debitAmount = tonumber(debitAmount)
    creditAmount = tonumber(creditAmount)
    if not fromAccount or not toAccount or fromAccount == toAccount
        or not IsFinitePositiveNumber(debitAmount)
        or not IsFinitePositiveNumber(creditAmount) then
        return false
    end

    local source, destination = GetAccount(fromAccount), GetAccount(toAccount)
    if not source or not destination or source.is_frozen == 1 or source.is_frozen == true then return false end
    local moved = BanksEconomy.Transfer({ fromAccountId = source.dollars_account_id,
        toAccountId = destination.dollars_account_id, currency = 'dollars', amount = ToUnits(creditAmount),
        reasonCode = 'bank.transfer', referenceType = 'bcc_bank_account',
        referenceId = tostring(fromAccount),
        idempotencyKey = ('banks:transfer:%s'):format(DB.value('SELECT UUID()')) })
    if not moved.ok then return false end
    local fee = ToUnits(debitAmount - creditAmount)
    if fee > 0 then
        local sink = BanksEconomy.GetSystemAccount({ currency = 'dollars', accountType = 'system_sink' })
        local charged = sink.ok and BanksEconomy.Transfer({ fromAccountId = source.dollars_account_id,
            toAccountId = sink.value.accountId, currency = 'dollars', amount = fee,
            reasonCode = 'bank.fee', referenceType = 'economy_transaction',
            referenceId = moved.value.transactionId,
            idempotencyKey = ('banks:fee:%s'):format(moved.value.transactionId) }) or sink
        if not charged.ok then
            BanksEconomy.Transfer({ fromAccountId = destination.dollars_account_id,
                toAccountId = source.dollars_account_id, currency = 'dollars', amount = ToUnits(creditAmount),
                reasonCode = 'bank.transfer', referenceType = 'economy_transaction',
                referenceId = moved.value.transactionId,
                idempotencyKey = ('banks:compensate:%s'):format(moved.value.transactionId) })
            return false
        end
    end
    return true
end

function IsAccountLocked(account, src)
    return LockedAccounts[account] ~= nil
end

function GetAccountLockHolder(account)
    return LockedAccounts[account]
end

-- Freeze/unfreeze all accounts belonging to an owner character
function SetOwnerAccountsFrozen(ownerId, frozen)
    if not ownerId then return end
    DB.exec('UPDATE `bcc_accounts` SET `is_frozen` = ? WHERE `owner_id` = ?', frozen and 1 or 0, ownerId)
end

function IsActiveUser(account, src)
    return LockedAccounts[account] == src
end

function SetLockedAccount(account, src, state)
    if state then
        LockedAccounts[account] = src
    else
        LockedAccounts[account] = nil
    end
end

function ClearAccountLocks(src)
    for account, user in pairs(LockedAccounts) do
        if user == src then
            LockedAccounts[account] = nil
        end
    end
end

function GetAccountAccessList(account)
    local result = DB.query('SELECT character_id, level FROM `bcc_accounts_access` WHERE account_id = ?', account)

    return result or {}
end

function GiveAccountAccess(account, targetCharacter, level)
    local result = DB.query(
        'SELECT 1 FROM `bcc_accounts_access` WHERE `account_id` = ? AND `character_id` = ? LIMIT 1;',
        account, targetCharacter
    )

    if result and result[1] then
        return { status = false, message = "Character already has access." }
    end

    DB.exec(
        'INSERT INTO `bcc_accounts_access` (`account_id`, `character_id`, `level`) VALUES (?, ?, ?)',
        account, targetCharacter, level
    )

    return { status = true, message = "Access granted." }
end

function RemoveAccountAccess(account, targetCharacter)
    DB.exec(
        'DELETE FROM `bcc_accounts_access` WHERE `account_id` = ? AND `character_id` = ?',
        account, targetCharacter
    )
    return { status = true, message = "Access removed." }
end
