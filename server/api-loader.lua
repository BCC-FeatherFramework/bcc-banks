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
    -- Wallet payments settle against the reserve of branch `bankId`. `reason` is
    -- one of the bank.* reserve codes Economy accepts (loan, check, box, gold).
    local function reserveTransfer(currencyId, amount, reason, bankId, toWallet)
        local currency = currencyName(currencyId)
        local reserveId, missing = BankOrganizations.GetReserveAccountId(bankId, currency)
        if not reserveId then error(missing or 'reserve_unavailable') end
        local walletId = wallets.value[currency].accountId
        local result = BanksEconomy.Transfer({
            fromAccountId = toWallet and reserveId or walletId,
            toAccountId = toWallet and walletId or reserveId,
            currency = currency,
            amount = math.floor((tonumber(amount) or 0) * 100 + 0.5),
            actorCharacterId = identity.characterId,
            reasonCode = reason,
            referenceType = 'bcc_bank',
            referenceId = tostring(bankId),
            idempotencyKey = ('banks:%s:%s'):format(toWallet and 'credit' or 'debit', DB.value('SELECT UUID()'))
        })
        if not result.ok then error(result.code or 'economy_transfer_failed') end
        return true
    end
    function character.CreditWallet(currencyId, amount, reason, bankId)
        return reserveTransfer(currencyId, amount, reason, bankId, true)
    end
    function character.DebitWallet(currencyId, amount, reason, bankId)
        return reserveTransfer(currencyId, amount, reason, bankId, false)
    end
    return character
end

-- Deliberately not exported: the returned CreditWallet/DebitWallet run inside
-- bcc-banks, so Economy would authorize them as bank reserve transfers for any
-- resource that obtained the context.

CreateThread(function()
    DB.awaitReady()
    local initialized = BanksEconomy.Initialize()
    if type(initialized) ~= 'table' or initialized.ok ~= true then
        error(('[bcc-banks] Economy initialization failed: %s'):format(
            tostring(type(initialized) == 'table' and initialized.code or 'invalid_result')))
    end
end)
