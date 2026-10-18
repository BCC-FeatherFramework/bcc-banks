-- Server-side RPCs for Gold Exchange (buy/sell). The money moves live in BankOps.

-- The branch the player is exchanging at; its reserve pays and receives.
local function goldExchangeBank(src)
    if not (Config.GoldExchange and Config.GoldExchange.Enabled == true) then return nil end
    return GetNearbyBankId(src)
end

local function roundTo(value, decimals)
    local power = 10 ^ (decimals or 2)
    return math.floor((value * power) + 0.5) / power
end

exports['feather-core']:RegisterRPC('bcc-banks:GetGoldRates', function(params, cb, src)
    if not goldExchangeBank(src) then cb(false) return end
    local buy, sell = BankOps.GoldRates()
    cb(true, { buy = buy, sell = sell })
end)

-- params: { gold = number } OR { cash = number }
-- If gold provided: buy that much gold.
-- If cash provided: convert all cash to gold at buy rate.
exports['feather-core']:RegisterRPC('bcc-banks:BuyGold', function(params, cb, src)
    devPrint('BuyGold RPC called. src=', src, 'params=', params)

    local bankId = goldExchangeBank(src)
    if not bankId then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local user = GetBankingContext(src)
    if not user then
        devPrint('BuyGold: invalid player/char')
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_character_data'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        devPrint('BuyGold: invalid player/char')
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_character_data'), 'error', 4000)
        cb(false)
        return
    end

    if not AcquirePlayerFinancialLock(src) then
        NotifyClient(src, Feather.Locale.translateUpper('error_financial_operation_busy'), 'error', 4000)
        cb(false)
        return
    end
    local bought = BankOps.BuyGold(char, bankId, params)
    ReleasePlayerFinancialLock(src)
    if not bought.ok then
        if bought.key ~= 'error_unable_exchange_gold' then
            NotifyClient(src, Feather.Locale.translateUpper(bought.key), 'error', 4000)
        end
        cb(false)
        return
    end
    local gold, cost, buyRate = bought.gold, bought.cost, bought.rate

    local lines = {
        '**Action:** `Buy Gold`',
        '**Gold Received:** `' .. tostring(gold) .. '`',
        '**Cash Spent:** `$' .. tostring(cost) .. '`',
        '**Rate:** `$' .. tostring(buyRate) .. ' / gold`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Gold Exchange Purchase', lines, 15844367)
    AddCharacterTransaction(char.characterId, cost, 'gold exchange - buy', 'Bought ' .. tostring(gold) .. ' gold for $' .. tostring(cost))
    NotifyClient(src, Feather.Locale.translateUpper('success_purchased_gold_for_cash', tostring(gold), tostring(cost)), 'success', 4000)
    cb(true, { gold = gold, cost = cost })
end)

-- params: { gold = number } OR { cash = number }
-- If gold provided: sell that much gold.
-- If cash provided: sell enough gold to receive that much cash.
exports['feather-core']:RegisterRPC('bcc-banks:SellGold', function(params, cb, src)
    devPrint('SellGold RPC called. src=', src, 'params=', params)

    local bankId = goldExchangeBank(src)
    if not bankId then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local user = GetBankingContext(src)
    if not user then
        devPrint('SellGold: invalid player/char')
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_character_data'), 'error', 4000)
        cb(false)
        return
    end
    local char = user
    if not char then
        devPrint('SellGold: invalid player/char')
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_character_data'), 'error', 4000)
        cb(false)
        return
    end

    if not AcquirePlayerFinancialLock(src) then
        NotifyClient(src, Feather.Locale.translateUpper('error_financial_operation_busy'), 'error', 4000)
        cb(false)
        return
    end
    local sold = BankOps.SellGold(char, bankId, params)
    ReleasePlayerFinancialLock(src)
    if not sold.ok then
        if sold.key ~= 'error_unable_exchange_gold' then
            NotifyClient(src, Feather.Locale.translateUpper(sold.key), 'error', 4000)
        end
        cb(false)
        return
    end
    local gold, proceeds, sellRate = sold.gold, sold.cash, sold.rate

    local lines = {
        '**Action:** `Sell Gold`',
        '**Gold Sold:** `' .. tostring(gold) .. '`',
        '**Cash Received:** `$' .. tostring(proceeds) .. '`',
        '**Rate:** `$' .. tostring(sellRate) .. ' / gold`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Gold Exchange Sale', lines, 15105570)
    AddCharacterTransaction(char.characterId, proceeds, 'gold exchange - sell', 'Sold ' .. tostring(gold) .. ' gold for $' .. tostring(proceeds))
    NotifyClient(src, Feather.Locale.translateUpper('success_sold_gold_for_cash', tostring(gold), tostring(proceeds)), 'success', 4000)
    cb(true, { gold = gold, cash = proceeds })
end)

-- Exchange inventory gold bar items into gold currency
-- params: { count = number }
exports['feather-core']:RegisterRPC('bcc-banks:ExchangeGoldBars', function(params, cb, src)
    devPrint('ExchangeGoldBars RPC called. src=', src, 'params=', params)

    local bankId = goldExchangeBank(src)
    if not bankId then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_at_bank'), 'error', 4000)
        cb(false)
        return
    end

    local user = GetBankingContext(src)
    if not user then
        devPrint('ExchangeGoldBars: invalid user/char')
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_character_data'), 'error', 4000)
        cb(false)
        return
    end
    local char = user

    local count = tonumber(params and params.count) or 0
    if not IsFinitePositiveNumber(count) or count % 1 ~= 0 then
        NotifyClient(src, Feather.Locale.translateUpper('error_invalid_goldbar_count'), 'error', 4000)
        cb(false)
        return
    end

    local itemName = (Config.GoldExchange and Config.GoldExchange.GoldBarItemName) or 'goldbar'
    local perBarGold = (Config.GoldExchange and Config.GoldExchange.GoldBarToGold) or 1.0
    local feePercent = (Config.GoldExchange and Config.GoldExchange.GoldBarFeePercent) or 0

    local inventory = exports['feather-inventory'].initiate()
    local countResult = inventory.Items.GetItemCount(itemName, src)
    local had = type(countResult) == 'table' and countResult.ok == true and tonumber(countResult.value) or 0
    if had < count then
        NotifyClient(src, Feather.Locale.translateUpper('error_not_enough_goldbars'), 'error', 4000)
        cb(false)
        return
    end

    if not AcquirePlayerFinancialLock(src) then
        NotifyClient(src, Feather.Locale.translateUpper('error_financial_operation_busy'), 'error', 4000)
        cb(false)
        return
    end
    local removed = inventory.Items.RemoveItemByName(itemName, count, src)
    if type(removed) ~= 'table' or removed.ok ~= true then
        ReleasePlayerFinancialLock(src)
        cb(false)
        return
    end
    local grossGold = perBarGold * count
    local netGold = roundTo(grossGold * (1 - (feePercent / 100)), 2)
    if netGold < 0 then netGold = 0 end
    local credited = pcall(function() char.CreditWallet(1, netGold, 'bank.gold.exchange', bankId) end)
    if not credited then
        inventory.Items.AddItem(itemName, count, nil, src)
        ReleasePlayerFinancialLock(src)
        cb(false)
        return
    end
    ReleasePlayerFinancialLock(src)

    local function toFixed(n, decimals)
        n = tonumber(n) or 0
        local mult = 10 ^ (decimals or 0)
        local v = math.floor(n * mult + 0.5) / mult
        local s = tostring(v)
        if decimals and decimals > 0 then
            local dot = string.find(s, '.', 1, true)
            if not dot then
                s = s .. '.' .. string.rep('0', decimals)
            else
                local places = #s - dot
                if places < decimals then
                    s = s .. string.rep('0', decimals - places)
                end
            end
        end
        return s
    end
    NotifyClient(src, Feather.Locale.translateUpper('success_exchanged_goldbars', tostring(count), toFixed(netGold, 2)), 'success', 4000)
    local lines = {
        '**Action:** `Exchange Gold Bars`',
        '**Item:** `' .. tostring(itemName) .. '`',
        '**Count:** `' .. tostring(count) .. '`',
        '**Gold Received:** `' .. tostring(toFixed(netGold, 2)) .. '`',
        '**Fee Percent:** `' .. tostring(feePercent) .. '%`',
    }
    BccBanksInternal.appendActorLines(lines, src)
    QueueBankAuditLog('Gold Bar Exchange', lines, 15844367)
    AddCharacterTransaction(char.characterId, netGold, 'gold exchange - bars', 'Exchanged ' .. tostring(count) .. ' ' .. tostring(itemName) .. ' for ' .. tostring(toFixed(netGold, 2)) .. ' gold')
    cb(true, { gold = netGold, fee = feePercent })
end)
