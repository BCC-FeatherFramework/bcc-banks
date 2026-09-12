local function profileProvider()
    local result = exports['feather-core']:GetProvider('character-profile', nil, 1)
    if type(result) ~= 'table' or result.ok ~= true or type(result.value) ~= 'table'
        or type(result.value.implementation) ~= 'table' then
        return nil
    end
    return result.value.implementation
end

function GetFeatherCharacter(source)
    local session = exports['feather-core']:GetSessionContext(tonumber(source))
    if type(session) ~= 'table' or session.ok ~= true or type(session.value) ~= 'table' then
        return nil
    end
    local provider = profileProvider()
    if not provider or not provider.GetProfile then return nil end
    local profile = provider.GetProfile(session.value.characterId)
    if type(profile) ~= 'table' or profile.ok ~= true or type(profile.value) ~= 'table' then
        return nil
    end
    return {
        source = tonumber(source), accountId = session.value.accountId,
        sessionId = session.value.sessionId, characterId = session.value.characterId,
        profile = profile.value
    }
end

local function walletBalance(wallets, currency)
    local account = wallets and wallets[currency]
    if not account then return 0 end
    local balance = BanksEconomy.GetBalance({ accountId = account.accountId })
    return balance.ok and balance.value.postedAmount or 0
end

function GetBankingContext(source)
    local identity = GetFeatherCharacter(source)
    if not identity then return nil end
    local wallets = BanksEconomy.EnsureCharacterWallets({
        characterId = identity.characterId,
        correlationId = ('banks:session:%s'):format(identity.sessionId)
    })
    if not wallets.ok then return nil end

    local profile = identity.profile
    local character = {
        source = identity.source,
        accountId = identity.accountId,
        sessionId = identity.sessionId,
        characterId = identity.characterId,
        profile = profile,
        wallets = wallets.value,
        firstName = profile.firstName,
        lastName = profile.lastName,
        money = walletBalance(wallets.value, 'dollars') / 100,
        gold = walletBalance(wallets.value, 'gold') / 100
    }

    local function currencyName(currencyId)
        return tonumber(currencyId) == 1 and 'gold' or 'dollars'
    end
    function character.CreditWallet(currencyId, amount)
        local currency = currencyName(currencyId)
        local units = math.floor((tonumber(amount) or 0) * 100 + 0.5)
        local result = BanksEconomy.Issue({
            toAccountId = wallets.value[currency].accountId,
            currency = currency,
            amount = units,
            reasonCode = 'banks.wallet.credit',
            referenceType = 'bcc_bank_wallet',
            referenceId = identity.characterId,
            idempotencyKey = ('banks:credit:%s'):format(MySQL.scalar.await('SELECT UUID()'))
        })
        if not result.ok then error(result.code or 'economy_credit_failed') end
        return true
    end
    function character.DebitWallet(currencyId, amount)
        local currency = currencyName(currencyId)
        local units = math.floor((tonumber(amount) or 0) * 100 + 0.5)
        local result = BanksEconomy.Destroy({
            fromAccountId = wallets.value[currency].accountId,
            currency = currency,
            amount = units,
            reasonCode = 'banks.wallet.debit',
            referenceType = 'bcc_bank_wallet',
            referenceId = identity.characterId,
            idempotencyKey = ('banks:debit:%s'):format(MySQL.scalar.await('SELECT UUID()'))
        })
        if not result.ok then error(result.code or 'economy_debit_failed') end
        return true
    end
    return character
end

-- Shared temporary wallets for the Feather shops port.
exports('GetBankingContext', GetBankingContext)

MySQL.ready(function()
    local initialized = BanksEconomy.Initialize()
    if type(initialized) ~= 'table' or initialized.ok ~= true then
        error(('[bcc-banks] temporary Economy initialization failed: %s'):format(
            tostring(type(initialized) == 'table' and initialized.code or 'invalid_result')))
    end
end)
