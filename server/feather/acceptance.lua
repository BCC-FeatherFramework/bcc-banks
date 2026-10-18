-- Live acceptance, server console only. Runs with nobody connected: characters
-- are named by UUID and act through the same BankOps and controllers as the menus.
--
--   BanksAcceptanceTest <character A> <character B> [bank id]
--   BanksAcceptanceTest box <character A> <box id>      (after a server restart)
--
-- A needs the cheapest box price plus about $55 in the wallet: the box is bought
-- and refunded by the second command. B gains $1.00 (a transfer and a cashed
-- check); A pays that, a cross-branch fee and the spread on 0.15 gold bought and
-- sold. Test accounts are closed again; 1.00 dollar of reserve funding stays.

local UUID = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'
local TAG = '[BanksAcceptanceTest]'
local BOX_KVP = 'bcc-banks:acceptance:box:'

local passed, failed, skipped

local function check(name, condition, detail)
    if condition then passed = passed + 1 else failed = failed + 1 end
    print(('%s %-48s %s%s'):format(TAG, name, condition and 'PASS' or 'FAIL',
        detail and ('  (' .. tostring(detail) .. ')') or ''))
    return condition
end

local function skip(name, why)
    skipped = skipped + 1
    print(('%s %-48s SKIP  (%s)'):format(TAG, name, why))
end

local function near(a, b) return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 0.005 end
local function money(n) return ('%.2f'):format(tonumber(n) or 0) end

local function wallet(characterId)
    local context = GetBankingContextForCharacter(characterId)
    return context, tonumber(context and context.money) or 0, tonumber(context and context.gold) or 0
end

local function account(accountId)
    local row = GetAccount(accountId)
    return row, tonumber(row and row.cash) or 0, tonumber(row and row.gold) or 0
end

local function reserve(bankId, currency)
    local found = BankOrganizations.GetReserve(bankId)
    local balance = found and found[currency] and BanksEconomy.GetBalance({ accountId = found[currency].accountId })
    return balance and balance.ok and (tonumber(balance.value.postedAmount) or 0) / 100 or nil
end

local function fundReserve(bankId, currency, amount)
    local accountId = BankOrganizations.GetReserveAccountId(bankId, currency)
    if not accountId then return false end
    return BanksEconomy.Issue({
        toAccountId = accountId, currency = currency, amount = math.floor(amount * 100 + 0.5),
        reasonCode = 'bank.reserve.funding', referenceType = 'bcc_bank', referenceId = bankId,
        idempotencyKey = ('banks:acceptance-fund:%s'):format(DB.value('SELECT UUID()'))
    }).ok
end

local function cheapestBox(context)
    local best
    for key, size in pairs(Config.SafetyDepositBoxes.Sizes or {}) do
        for _, option in ipairs({
            { payWith = 'cash', price = tonumber(size.CashPrice), have = context.money },
            { payWith = 'gold', price = tonumber(size.GoldPrice), have = context.gold },
        }) do
            if option.price and option.price > 0 and option.have >= option.price
                and (not best or (option.payWith == 'gold' and option.price * 100 or option.price)
                    < (best.payWith == 'gold' and best.price * 100 or best.price)) then
                best = { size = key, payWith = option.payWith, price = option.price }
            end
        end
    end
    return best
end

-- A plain stackable item (not a weapon or ammunition) the box size accepts.
local function storableItem(sizeKey)
    local blocked = {}
    local size = (Config.SafetyDepositBoxes.Sizes or {})[sizeKey] or {}
    for _, name in ipairs(size.BlacklistItems or {}) do blocked[name] = true end
    for _, row in ipairs(DB.query([[SELECT `name` FROM `items` WHERE `type` = 'item_item'
        AND `instance_mode` = 'stack' AND `archived_at` IS NULL ORDER BY `id` LIMIT 25]]) or {}) do
        if not blocked[row.name] then return row.name end
    end
end

local function closeTestAccount(accountId, ownerId, bankId)
    local row, cash, gold = account(accountId)
    if not row then return true end
    local owner = GetBankingContextForCharacter(ownerId)
    if cash > 0 then WithdrawToWallet(owner, accountId, 'dollars', cash) end
    if gold > 0 then WithdrawToWallet(owner, accountId, 'gold', gold) end
    DB.exec('DELETE FROM `bcc_accounts_access` WHERE `account_id` = ? AND `character_id` <> ?', accountId, ownerId)
    local closed = CloseAccount(bankId, accountId, ownerId)
    return closed and closed.status == true
end

local function run(characterA, characterB, bankArg)
    local banks = GetBanks() or {}
    local bank, other = nil, nil
    for _, row in ipairs(banks) do
        if bankArg and IdsEqual(row.id, bankArg) or (not bankArg and not bank) then bank = row end
    end
    for _, row in ipairs(banks) do
        if bank and not IdsEqual(row.id, bank.id) then other = row break end
    end
    if not check('setup: branch found', bank ~= nil, bankArg or 'first branch') then return end
    local contextA, dollarsA, goldA = wallet(characterA)
    local contextB, dollarsB = wallet(characterB)
    if not check('setup: both characters resolve', contextA and contextB and characterA ~= characterB) then return end
    if not check('setup: A has at least $5.00', dollarsA >= 5, 'A has $' .. money(dollarsA)) then return end
    print(('%s branch %s (%s); second branch %s; A $%s %s gold, B $%s'):format(TAG, tostring(bank.name),
        bank.id, other and tostring(other.name) or 'none', money(dollarsA), money(goldA), money(dollarsB)))

    -- 2. Branch reserve: funding and status.
    local before = reserve(bank.id, 'dollars')
    check('2 reserve: readable', before ~= nil, before and ('$' .. money(before)))
    check('2 reserve: funding arrives', fundReserve(bank.id, 'dollars', 1) and near(reserve(bank.id, 'dollars'), (before or 0) + 1))
    if (reserve(bank.id, 'gold') or 0) < 0.10 then fundReserve(bank.id, 'gold', 1) end

    -- 8. Gold exchange through the branch reserve, both ways.
    if Config.GoldExchange and Config.GoldExchange.Enabled == true then
        local buyRate, sellRate = BankOps.GoldRates()
        local _, d0, g0 = wallet(characterA)
        local bought = BankOps.BuyGold(wallet(characterA), bank.id, { gold = 0.15 })
        local _, d1, g1 = wallet(characterA)
        check('8 gold: buy 0.15', bought.ok and near(d0 - d1, 0.15 * buyRate) and near(g1 - g0, 0.15),
            bought.ok and ('paid $' .. money(d0 - d1)) or bought.key)
        local sold = BankOps.SellGold(wallet(characterA), bank.id, { gold = 0.10 })
        local _, d2, g2 = wallet(characterA)
        check('8 gold: sell 0.10', sold.ok and near(d2 - d1, 0.10 * sellRate) and near(g1 - g2, 0.10),
            sold.ok and ('received $' .. money(d2 - d1)) or sold.key)
        check('8 gold: refuses more gold than held', not BankOps.SellGold(wallet(characterA), bank.id, { gold = g2 + 1 }).ok)
    else
        skip('8 gold exchange', 'Config.GoldExchange.Enabled is false')
    end

    -- 3. Accounts: open, deposit, withdraw, freeze, transfer.
    local createdA = CreateAccountReturn('Acceptance A', characterA, bank.id)
    local accountA = createdA and createdA.status ~= false and createdA.account and createdA.account.id
    if not check('3 accounts: open account for A', accountA ~= nil, createdA and createdA.message) then return end
    local _, w0 = wallet(characterA)
    local deposited = DepositFromWallet(wallet(characterA), accountA, 'dollars', 3)
    local _, w1 = wallet(characterA)
    local _, cash1 = account(accountA)
    check('3 accounts: deposit $3.00', deposited and near(w0 - w1, 3) and near(cash1, 3))
    local withdrawn = WithdrawToWallet(wallet(characterA), accountA, 'dollars', 1)
    local _, cash2 = account(accountA)
    check('3 accounts: withdraw $1.00', withdrawn and near(cash2, 2))
    check('3 accounts: refuses more than the balance', not WithdrawToWallet(wallet(characterA), accountA, 'dollars', 50))
    DB.exec('UPDATE `bcc_accounts` SET `is_frozen` = 1 WHERE `id` = ?', accountA)
    check('3 accounts: frozen account cannot withdraw', not WithdrawToWallet(wallet(characterA), accountA, 'dollars', 0.5))
    DB.exec('UPDATE `bcc_accounts` SET `is_frozen` = 0 WHERE `id` = ?', accountA)
    local _, _, goldNow = wallet(characterA)
    if goldNow >= 0.05 then
        local inGold = DepositFromWallet(wallet(characterA), accountA, 'gold', 0.05)
        local outGold = inGold and WithdrawToWallet(wallet(characterA), accountA, 'gold', 0.05)
        check('3 accounts: gold deposit and withdraw', inGold and outGold and near(select(3, account(accountA)), 0))
    else
        skip('3 accounts: gold deposit and withdraw', 'A holds under 0.05 gold')
    end

    local targetBank = other or bank
    local createdB = CreateAccountReturn('Acceptance B', characterB, targetBank.id)
    local accountB = createdB and createdB.status ~= false and createdB.account and createdB.account.id
    if check('3 accounts: open account for B', accountB ~= nil, createdB and createdB.message) then
        local fee, total = BankOps.TransferFee(GetAccount(accountA), GetAccount(accountB), 0.5)
        local _, a0 = account(accountA)
        local moved = TransferAccountCash(accountA, accountB, total, 0.5)
        local _, a1 = account(accountA)
        local _, b1 = account(accountB)
        check(other and '3 accounts: cross-branch transfer with fee' or '3 accounts: transfer',
            moved and near(a0 - a1, total) and near(b1, 0.5), 'fee $' .. money(fee))
        check('3 accounts: transfer to itself refused', not TransferAccountCash(accountA, accountA, 0.5, 0.5))
    end

    -- 4. Sharing at every access level.
    local levelsOk = true
    for name, level in pairs(Config.AccessLevels or {}) do
        local given = GiveAccountAccess(accountA, characterB, level)
        local seen = GetAccountAccess(accountA, characterB)
        RemoveAccountAccess(accountA, characterB)
        if not (given.status and seen == level and GetAccountAccess(accountA, characterB) == 0) then
            levelsOk = false
            print(('%s   level %s (%s) failed'):format(TAG, name, tostring(level)))
        end
    end
    check('4 sharing: grant and remove every level', levelsOk)
    GiveAccountAccess(accountA, characterB, Config.AccessLevels.ReadOnly)
    check('4 sharing: a second grant is refused', GiveAccountAccess(accountA, characterB, Config.AccessLevels.Admin).status == false)
    RemoveAccountAccess(accountA, characterB)

    -- 6. Checks: write, cash by the recipient, void.
    if Config.Checks and Config.Checks.Enabled == true then
        local _, a0 = account(accountA)
        local written = CreateCheck(accountA, characterA, characterB, 0.5, 'acceptance')
        local _, a1 = account(accountA)
        check('6 checks: write $0.50', written.status and near(a0 - a1, 0.5))
        if written.status then
            check('6 checks: writer cannot cash it', BankOps.CashCheckToWallet(wallet(characterA), written.check_id).key == 'error_check_not_yours')
            local _, b0 = wallet(characterB)
            local cashed = BankOps.CashCheckToWallet(wallet(characterB), written.check_id)
            local _, b1 = wallet(characterB)
            check('6 checks: recipient cashes it', cashed.ok and near(b1 - b0, 0.5))
            check('6 checks: cannot cash twice', BankOps.CashCheckToWallet(wallet(characterB), written.check_id).key == 'error_check_already_cashed')
        end
        local second = CreateCheck(accountA, characterA, characterB, 0.5, 'acceptance void')
        if second.status then
            check('6 checks: recipient cannot void', VoidCheck(second.check_id, characterB).message == 'no_permission')
            local _, v0 = account(accountA)
            local voided = VoidCheck(second.check_id, characterA)
            local _, v1 = account(accountA)
            check('6 checks: writer voids, money returns', voided.status and near(v1 - v0, 0.5))
        else
            check('6 checks: write a second check', false, second.message)
        end
    else
        skip('6 checks', 'Config.Checks.Enabled is false')
    end

    -- 5. Loans: apply, approve (paid from the reserve), installments in feather-contracts, repay.
    if BankLoanContracts.ready then
        local reserve0 = reserve(bank.id, 'dollars') or 0
        local interest = GetCharacterLoanInterest(characterA, bank.id)
        local created = CreateLoan(accountA, characterA, 2, interest, 2, bank.id)
        local loanId = created.status and created.loan and created.loan.id
        if check('5 loans: apply for $2.00 over 2 months', loanId ~= nil, created.message) then
            local _, before = account(accountA)
            local approved = ApproveLoan(loanId, characterB)
            local _, after = account(accountA)
            check('5 loans: approval pays $2.00 from the reserve', approved.status and near(after - before, 2)
                and near(reserve(bank.id, 'dollars'), reserve0 - 2), approved.message)
            local rows = BankLoanContracts.Installments(loanId)
            local owed = 0
            for _, row in ipairs(rows) do owed = owed + (tonumber(row.amount) or 0) end
            check('5 loans: two installments issued in Contracts', #rows == 2 and rows[1].obligation_id ~= nil
                and near(owed, 2 * (1 + interest / 100)), ('$%s at %s%%'):format(money(owed), tostring(interest)))
            check('5 loans: open loan keeps its account', CloseAccount(bank.id, accountA, characterA).status == false)
            local low = BankLoanContracts.Pay(GetLoan(loanId), 0.01)
            check('5 loans: less than an installment is refused', not low.ok and low.code == 'below_installment')
            if rows[1] then
                local _, w0 = wallet(characterA)
                local first = BankLoanContracts.Pay(GetLoan(loanId), tonumber(rows[1].amount))
                local _, w1 = wallet(characterA)
                check('5 loans: first installment paid from the wallet', first.ok and first.paid == 1
                    and near(w0 - w1, rows[1].amount), first.code)
                local rest = BankLoanContracts.Pay(GetLoan(loanId), 100)
                check('5 loans: last installment closes the loan', rest.ok and rest.paid == 1
                    and GetLoan(loanId).status == 'paid', rest.code)
                check('5 loans: reserve repaid with interest', near(reserve(bank.id, 'dollars'), reserve0 - 2 + owed))
            end
        end
    else
        skip('5 loans', 'feather-contracts loan type is not registered')
    end

    -- 7. Safety-deposit box: buy, store an item, refuse deletion while full.
    local option = cheapestBox(wallet(characterA))
    if option then
        local bought = BankOps.PurchaseSDB(wallet(characterA), bank.id, 'Acceptance Box', option.size, option.payWith)
        if check('7 box: buy ' .. option.size .. ' with ' .. option.payWith, bought.ok, bought.key) then
            local row = DB.one('SELECT `id`,`name`,`size`,`inventory_id` FROM `bcc_safety_deposit_boxes` WHERE `id` = ?', bought.box.id)
            local itemName = storableItem(option.size)
            local inventory = exports['feather-inventory'].initiate()
            local added = itemName and row and row.inventory_id and inventory.Items.AddItem(itemName, 1, nil, row.inventory_id)
            check('7 box: store one ' .. tostring(itemName), type(added) == 'table' and added.ok == true,
                type(added) == 'table' and added.error and added.error.code)
            check('7 box: full box cannot be deleted', row and not DeleteEmptySDB(row.id, row).ok)
            SetResourceKvp(BOX_KVP .. bought.box.id, json.encode({
                owner = characterA, item = itemName, price = option.price, payWith = option.payWith, bank = bank.id }))
            print(('%s restart the server, then run: BanksAcceptanceTest box %s %s'):format(TAG, characterA, bought.box.id))
        end
    else
        skip('7 box', 'A cannot afford any box size (needs $100 or 1 gold)')
    end

    -- Branch reserve management (/bankadmin): status, staff deposit and withdrawal.
    local status = BankReserve.Status(bank.id, 5)
    check('C reserve: balance and history readable', status.ok and status.dollars ~= nil and #status.entries > 0,
        status.ok and ('$' .. money(status.dollars) .. ', ' .. #status.entries .. ' entries') or status.key)
    local r0 = reserve(bank.id, 'dollars')
    local _, w0 = wallet(characterA)
    local put = BankReserve.Move(wallet(characterA), bank.id, 'dollars', 1, 'deposit')
    local _, w1 = wallet(characterA)
    check('C reserve: staff deposit from wallet', put.ok and near(w0 - w1, 1) and near(reserve(bank.id, 'dollars'), r0 + 1), put.key)
    local took = BankReserve.Move(wallet(characterA), bank.id, 'dollars', 1, 'withdraw')
    check('C reserve: staff withdrawal to wallet', took.ok and near(select(2, wallet(characterA)), w0)
        and near(reserve(bank.id, 'dollars'), r0), took.key)
    check('C reserve: cannot withdraw more than the reserve',
        BankReserve.Move(wallet(characterA), bank.id, 'dollars', (r0 or 0) + 1000, 'withdraw').key == 'admin_reserve_short')

    -- 10. Bank administration by role (job holders are reported, not changed).
    local wasAllowed, wasReason = BankAuthority.IsAllowedForCharacter(characterB)
    if wasAllowed then
        skip('10 admin: role grant changes access', 'B is already allowed: ' .. tostring(wasReason))
    else
        check('C reserve: B without a role cannot manage it', not BankAuthority.CanManageReserve(characterB, bank.id))
        local granted, grantDetail = BankAuthority.ReplaceAssignment(characterB, true)
        local allowed = granted and BankAuthority.IsAllowedForCharacter(characterB)
        local manages = granted and BankAuthority.CanManageReserve(characterB, bank.id)
        local revoked = BankAuthority.ReplaceAssignment(characterB, false)
        check('10 admin: granted role allows B', granted and allowed, not granted and grantDetail or nil)
        check('C reserve: the bank role manages any branch reserve', manages)
        check('10 admin: revoked role denies B again', revoked and not BankAuthority.IsAllowedForCharacter(characterB))
    end
    local job = BankAuthority.MatchingJob(characterB)
    print(('%s 10 admin: banker job for B: %s'):format(TAG, job or 'none (assign one in feather-jobs to try it)'))

    -- D. Audit: an event goes through the outbox into feather-audit, and a replay is a duplicate.
    if GetResourceState('feather-audit') == 'started' then
        local lines = { '**Action:** `Acceptance Fixture`', '**Bank:** `' .. tostring(bank.name) .. '`' }
        lines.actor = { characterId = characterA, name = 'Acceptance' }
        local eventId = QueueBankAuditLog('Acceptance Audit Fixture', lines)
        local queued = eventId and DB.one('SELECT `state`, `payload` FROM `bcc_banks_audit_outbox` WHERE `event_id` = ?', eventId)
        check('D audit: event written to the outbox', queued ~= nil and queued.state == 'pending', eventId)
        local delivered
        for _ = 1, 5 do
            BankAudit.PublishOnce()
            delivered = eventId and DB.one([[SELECT `state`, `audit_event_id`, `last_code` FROM `bcc_banks_audit_outbox`
                WHERE `event_id` = ?]], eventId)
            if delivered and delivered.state ~= 'pending' and delivered.state ~= 'leased' then break end
            Wait(500)
        end
        check('D audit: delivered to feather-audit', delivered and delivered.state == 'delivered'
            and delivered.audit_event_id ~= nil, delivered and (delivered.state .. ' ' .. tostring(delivered.last_code)))
        local replay = queued and exports['feather-audit']:Ingest(json.decode(queued.payload))
        check('D audit: a replay is a duplicate, not a second record', type(replay) == 'table'
            and replay.result == 'duplicate' and replay.auditEventId == (delivered and delivered.audit_event_id),
            type(replay) == 'table' and replay.result or nil)
    else
        skip('D audit', 'feather-audit is not started')
    end

    -- Clean up: sell back the gold kept for the account test, close the test accounts.
    local _, _, leftover = wallet(characterA)
    if leftover > goldA + 0.004 then BankOps.SellGold(wallet(characterA), bank.id, { gold = leftover - goldA }) end
    check('cleanup: test accounts closed', closeTestAccount(accountA, characterA, bank.id)
        and (not accountB or closeTestAccount(accountB, characterB, targetBank.id)))
    local _, endA = wallet(characterA)
    local _, endB = wallet(characterB)
    print(('%s wallets: A $%s (was $%s), B $%s (was $%s)'):format(TAG, money(endA), money(dollarsA),
        money(endB), money(dollarsB)))
end

-- After a restart: the stored item is still in the box; then empty it, delete it
-- and refund the test price. Rerunnable: the refund is paid once, after deletion.
local function runBox(characterA, boxId)
    local raw = GetResourceKvpString(BOX_KVP .. boxId)
    local saved = raw and json.decode(raw) or nil
    local row = DB.one('SELECT `id`,`name`,`size`,`inventory_id` FROM `bcc_safety_deposit_boxes` WHERE `id` = ?', boxId)
    if not check('7 box: box exists and A owns it', row ~= nil and IsSDBOwner(boxId, characterA)) then return end
    local inventoryId = tonumber(DB.value('SELECT `id` FROM `inventory` WHERE `uuid` = ?', row.inventory_id))
    local inventory = exports['feather-inventory'].initiate()
    local listed = inventoryId and inventory.Inventory.GetInventoryItems(inventoryId)
    local items = type(listed) == 'table' and listed.ok == true and listed.value or {}
    local names = {}
    for _, item in pairs(items) do names[#names + 1] = tostring(item.name) end
    if saved then
        local survived = false
        for _, name in ipairs(names) do survived = survived or name == saved.item end
        check('7 box: item survived the restart', survived, table.concat(names, ', '))
    end
    local removedAll = true
    for _, item in pairs(items) do
        local removed = inventory.Items.RemoveItemById(item.id)
        if type(removed) ~= 'table' or removed.ok ~= true then
            removedAll = false
            print(('%s   could not remove %s #%s: %s'):format(TAG, tostring(item.name), tostring(item.id),
                tostring(type(removed) == 'table' and removed.error and removed.error.code or removed)))
        end
    end
    check('7 box: emptied', removedAll, #names .. ' item(s)')
    local deleted = DeleteEmptySDB(boxId, row)
    if not check('7 box: empty box deleted', deleted.ok, deleted.reason) then return end
    if saved then
        local refunded = pcall(function()
            GetBankingContextForCharacter(characterA).CreditWallet(saved.payWith == 'gold' and 1 or 0, saved.price, 'bank.box.refund', saved.bank)
        end)
        check('7 box: test price refunded', refunded, (saved.payWith == 'gold' and '' or '$') .. money(saved.price) .. ' ' .. saved.payWith)
        DeleteResourceKvp(BOX_KVP .. boxId)
    else
        print(TAG .. ' 7 box: no refund recorded for this box (already refunded)')
    end
end

RegisterCommand('BanksAcceptanceTest', function(source, args)
    if source ~= 0 then return end
    CreateThread(function()
        passed, failed, skipped = 0, 0, 0
        local box = args[1] == 'box'
        local first, second = box and args[2] or args[1], box and args[3] or args[2]
        if not first or not first:match(UUID) or (not box and (not second or not second:match(UUID))) then
            return print(TAG .. ' Usage: BanksAcceptanceTest <character A> <character B> [bank id] | box <character A> <box id>')
        end
        local called, problem = xpcall(function()
            if box then runBox(first:lower(), second) else run(first:lower(), second:lower(), NormalizeId(args[3])) end
        end, debug.traceback)
        if not called then check('no script error', false, problem) end
        print(('%s done %d passed, %d failed, %d skipped'):format(TAG, passed, failed, skipped))
    end)
end, true)
