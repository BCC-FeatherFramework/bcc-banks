-- Money operations shared by the player RPCs and the console acceptance test.
-- Each takes a banking context (GetBankingContext or GetBankingContextForCharacter)
-- and returns { ok = true, ... } or { ok = false, key = <locale key> }. Callers
-- hold the player's financial lock and send notifications and audit lines.

BankOps = {}

local function roundTo(value, decimals)
    local power = 10 ^ (decimals or 2)
    return math.floor((value * power) + 0.5) / power
end

function BankOps.GoldRates()
    local cfg = Config and Config.GoldExchange or {}
    local buy = tonumber(cfg.BuyPricePerGold) or 10.0 -- dollars per 1 gold
    local sell = tonumber(cfg.SellPricePerGold) or 9.0 -- dollars per 1 gold
    return buy, sell
end

-- params: { gold = number } OR { cash = number }; `rateIndex` 1 = buy, 2 = sell.
local function goldAmount(params, rate)
    local gold = tonumber(params and params.gold)
    local cash = tonumber(params and params.cash)
    if (not IsFinitePositiveNumber(gold)) and (not IsFinitePositiveNumber(cash)) then
        return nil, 'error_invalid_gold_or_cash_amount'
    end
    if not gold and cash then gold = cash / rate end
    gold = roundTo(gold or 0, 2)
    if gold <= 0 then return nil, 'error_amount_zero' end
    return gold
end

-- Wallet dollars -> wallet gold at the buy rate, through branch `bankId`'s reserve.
function BankOps.BuyGold(char, bankId, params)
    local rate = select(1, BankOps.GoldRates())
    local gold, problem = goldAmount(params, rate)
    if not gold then return { ok = false, key = problem } end
    local cost = roundTo(gold * rate, 2)
    if (tonumber(char.money) or 0) < cost then return { ok = false, key = 'error_not_enough_cash_purchase' } end
    local removed = pcall(function() char.DebitWallet(0, cost, 'bank.gold.exchange', bankId) end)
    local credited = removed and pcall(function() char.CreditWallet(1, gold, 'bank.gold.exchange', bankId) end)
    if not credited then
        if removed then pcall(function() char.CreditWallet(0, cost, 'bank.compensation', bankId) end) end
        return { ok = false, key = 'error_unable_exchange_gold' }
    end
    return { ok = true, gold = gold, cost = cost, rate = rate }
end

-- Wallet gold -> wallet dollars at the sell rate, through branch `bankId`'s reserve.
function BankOps.SellGold(char, bankId, params)
    local _, rate = BankOps.GoldRates()
    local gold, problem = goldAmount(params, rate)
    if not gold then return { ok = false, key = problem } end
    local proceeds = roundTo(gold * rate, 2)
    if (tonumber(char.gold) or 0) < gold then return { ok = false, key = 'error_not_enough_gold_to_sell' } end
    local removed = pcall(function() char.DebitWallet(1, gold, 'bank.gold.exchange', bankId) end)
    local credited = removed and pcall(function() char.CreditWallet(0, proceeds, 'bank.gold.exchange', bankId) end)
    if not credited then
        if removed then pcall(function() char.CreditWallet(1, gold, 'bank.compensation', bankId) end) end
        return { ok = false, key = 'error_unable_exchange_gold' }
    end
    return { ok = true, gold = gold, cash = proceeds, rate = rate }
end

-- A cross-bank transfer pays Config.Transfer.CrossBankFeePercent on top, to the
-- system sink. Returns the fee and the total debited from the source account.
function BankOps.TransferFee(fromAccount, toAccount, amount)
    local feePercent = 0.0
    if not IdsEqual(fromAccount.bank_id, toAccount.bank_id) then
        feePercent = tonumber(Config.Transfer.CrossBankFeePercent or 0.0) or 0.0
    end
    local function round2(n)
        return math.floor((n + 0.0000001) * 100 + 0.5) / 100
    end
    local fee = round2((amount * feePercent) / 100.0)
    return fee, round2(amount + fee), feePercent
end

local CHECK_ERRORS = {
    already_cashed = 'error_check_already_cashed',
    already_voided = 'error_check_voided',
    not_yours      = 'error_check_not_yours',
}

-- Marks a pending check cashed by its recipient and pays it into the recipient's
-- wallet from the reserve of the branch that holds the writer's account.
function BankOps.CashCheckToWallet(char, checkId)
    local result = CashCheck(checkId, NormalizeId(char.characterId))
    if not result.status then
        return { ok = false, key = CHECK_ERRORS[result.message] or 'error_invalid_check' }
    end
    local issuingAccount = GetAccount(result.account_id)
    local credited = pcall(function() char.CreditWallet(0, result.amount, 'bank.check.cash',
        issuingAccount and issuingAccount.bank_id) end)
    if not credited then
        DB.exec('UPDATE `bcc_checks` SET `status` = "pending", `cashed_at` = NULL WHERE `id` = ? AND `status` = "cashed"', checkId)
        return { ok = false } -- payout failed; the check is pending again
    end
    return { ok = true, amount = result.amount, account_id = result.account_id }
end

local function resolveSDBSize(sizeKey)
    local want = tostring(sizeKey):lower()
    for key, size in pairs(Config.SafetyDepositBoxes.Sizes or {}) do
        if tostring(key):lower() == want then return key, size end
    end
end

-- Buys a safety-deposit box at branch `bankId`: charges the wallet, creates the
-- box, registers its Feather Inventory container and grants the buyer admin access.
-- Every later failure rolls back and refunds.
function BankOps.PurchaseSDB(char, bankId, name, sizeKey, payWith)
    local characterId = char.characterId
    if not characterId or not bankId or not name or name == '' or not sizeKey then
        return { ok = false, key = 'error_invalid_data' }
    end
    name = tostring(name):sub(1, 64)
    local resolvedKey, size = resolveSDBSize(sizeKey)
    if not size then return { ok = false, key = 'error_invalid_data' } end

    local currencyId = payWith == 'gold' and 1 or 0
    local price = currencyId == 1 and (size.GoldPrice or 0) or (size.CashPrice or 0)
    if not IsFinitePositiveNumber(price) then return { ok = false, key = 'error_invalid_data' } end
    local balance = currencyId == 0 and tonumber(char.money) or tonumber(char.gold)
    if not balance or balance < price then
        return { ok = false, key = currencyId == 0 and 'error_not_enough_cash' or 'error_not_enough_gold_to_sell',
            balance = balance or 0 }
    end

    local charged = pcall(function() char.DebitWallet(currencyId, price, 'bank.box.fee', bankId) end)
    if not charged then return { ok = false, key = 'error_unable_create_sdb' } end
    local function refund()
        pcall(function() char.CreditWallet(currencyId, price, 'bank.box.refund', bankId) end)
    end

    local created, box, sizeFromController = pcall(CreateSDB, name, characterId, bankId, resolvedKey)
    if not created or box == false then
        refund()
        return { ok = false, key = 'error_unable_create_sdb' }
    end
    size = sizeFromController or size

    local registered = pcall(function()
        local inventory = exports['feather-inventory'].initiate()
        local foreignKey = inventory.Inventory.RegisterForeignKey(
            'bcc_safety_deposit_boxes',
            'VARCHAR(36) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci', 'id')
        if type(foreignKey) ~= 'table' or foreignKey.ok ~= true then
            local failure = type(foreignKey) == 'table' and foreignKey.error or nil
            error(failure and (failure.message or failure.code) or 'Feather Inventory foreign-key registration failed')
        end
        local restricted = (size.BlacklistItems and #size.BlacklistItems or 0) > 0 and size.BlacklistItems or nil
        local container = inventory.Inventory.RegisterInventory(
            'bcc_safety_deposit_boxes', box.id, name, size.IgnoreItemLimit == true,
            tonumber(size.MaxWeight) or 100, restricted, tostring(characterId), false, tonumber(size.MaxSlots))
        if type(container) ~= 'table' or container.ok ~= true then
            local failure = type(container) == 'table' and container.error or nil
            error(failure and (failure.message or failure.code) or 'Feather Inventory container registration failed')
        end
        DB.exec('UPDATE `bcc_safety_deposit_boxes` SET `inventory_id`=? WHERE `id`=?', container.value.uuid, box.id)
        DB.exec('INSERT INTO `bcc_safety_deposit_boxes_access` (`safety_deposit_box_id`, `character_id`, `level`) VALUES (?,?,?)',
            box.id, characterId, Config.AccessLevels.Admin)
    end)
    if not registered then
        pcall(function()
            DB.exec('DELETE FROM `bcc_safety_deposit_boxes_access` WHERE `safety_deposit_box_id`=?', box.id)
            DB.exec('DELETE FROM `bcc_safety_deposit_boxes` WHERE `id`=?', box.id)
        end)
        refund()
        return { ok = false, key = 'error_unable_create_sdb' }
    end
    return { ok = true, box = box, price = price, size = resolvedKey }
end
