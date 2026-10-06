function GetCharacterByName(firstName, lastName)
    if not firstName or not lastName or firstName == '' or lastName == '' then
        return nil
    end
    local found = exports['feather-core']:GetProvider('character-profile', nil, 1)
    local provider = found and found.ok == true and found.value and found.value.implementation or nil
    local result = provider and provider.SearchProfiles and provider.SearchProfiles(firstName .. ' ' .. lastName, 1, 20) or nil
    for _, profile in ipairs(result and result.ok == true and result.value.profiles or {}) do
        if tostring(profile.firstName):lower() == tostring(firstName):lower()
            and tostring(profile.lastName):lower() == tostring(lastName):lower() then return profile.characterId end
    end
end

function GetCharacterName(charId)
    if not charId then return nil, nil end
    local found = exports['feather-core']:GetProvider('character-profile', nil, 1)
    local provider = found and found.ok == true and found.value and found.value.implementation or nil
    local result = provider and provider.GetProfile and provider.GetProfile(tostring(charId)) or nil
    local profile = result and result.ok == true and result.value or nil
    return profile and profile.firstName or nil, profile and profile.lastName or nil
end

function CreateCheck(accountId, issuerCharId, recipientCharId, amount, memo)
    if not accountId or not issuerCharId or not recipientCharId or not IsFinitePositiveNumber(amount) then
        return { status = false, message = 'Invalid check data.' }
    end

    local maxAmount = Config.Checks and tonumber(Config.Checks.MaxAmount) or 0
    if maxAmount > 0 and amount > maxAmount then
        return { status = false, message = 'Check amount exceeds maximum.' }
    end

    -- Deduct from account now (no bounced checks)
    local ok = WithdrawCash(accountId, amount, 'bank.check.issue')
    if not ok then
        return { status = false, message = 'Insufficient funds.' }
    end

    local checkId = DB.value('SELECT UUID()')
    local inserted = DB.insert(
        'INSERT INTO `bcc_checks` (`id`, `account_id`, `issuer_character_id`, `recipient_character_id`, `amount`, `memo`, `status`) VALUES (?, ?, ?, ?, ?, ?, "pending")',
        checkId, accountId, issuerCharId, recipientCharId, amount, tostring(memo or ''):sub(1, 200)
    )
    if not inserted then
        DepositCash(accountId, amount, 'bank.compensation')
        return { status = false, message = 'Failed to create check.' }
    end

    AddAccountTransaction(
        accountId,
        issuerCharId,
        amount,
        'check - issued',
        'Check issued to character #' .. tostring(recipientCharId)
    )

    return { status = true, check_id = checkId }
end

function GetCheck(checkId)
    local row = DB.query('SELECT * FROM `bcc_checks` WHERE `id` = ? LIMIT 1', checkId)
    return row and row[1]
end

function GetPendingChecksForRecipient(characterId)
    local rows = DB.query(
        [[SELECT c.* FROM `bcc_checks` c
          WHERE c.recipient_character_id = ? AND c.status = "pending"
          ORDER BY c.created_at DESC]],
        characterId
    )
    for _, row in ipairs(rows or {}) do row.issuer_first, row.issuer_last = GetCharacterName(row.issuer_character_id) end
    return rows or {}
end

function GetPendingChecksFromAccount(accountId)
    local rows = DB.query(
        [[SELECT c.* FROM `bcc_checks` c
          WHERE c.account_id = ? AND c.status = "pending"
          ORDER BY c.created_at DESC]],
        accountId
    )
    for _, row in ipairs(rows or {}) do row.recipient_first, row.recipient_last = GetCharacterName(row.recipient_character_id) end
    return rows or {}
end

function CashCheck(checkId, characterId)
    local check = GetCheck(checkId)
    if not check then
        return { status = false, message = 'Check not found.' }
    end

    local status = tostring(check.status or '')

    if status == 'cashed' then
        return { status = false, message = 'already_cashed' }
    end
    if status == 'voided' then
        return { status = false, message = 'already_voided' }
    end
    if status ~= 'pending' then
        return { status = false, message = 'invalid_status' }
    end
    if not IdsEqual(check.recipient_character_id, characterId) then
        return { status = false, message = 'not_yours' }
    end

    local changed = DB.exec(
        'UPDATE `bcc_checks` SET `status` = "cashed", `cashed_at` = NOW() WHERE `id` = ? AND `status` = "pending" AND `recipient_character_id` = ?',
        checkId, characterId
    )
    if (tonumber(changed) or 0) ~= 1 then
        return { status = false, message = 'already_cashed' }
    end

    return { status = true, amount = tonumber(check.amount), account_id = check.account_id }
end

function VoidCheck(checkId, characterId)
    local check = GetCheck(checkId)
    if not check then
        return { status = false, message = 'Check not found.' }
    end

    if tostring(check.status) ~= 'pending' then
        return { status = false, message = 'Cannot void a check that is not pending.' }
    end

    local isIssuer = IdsEqual(check.issuer_character_id, characterId)
    local isAdmin  = IsAccountAdmin(check.account_id, characterId)
    if not isIssuer and not isAdmin then
        return { status = false, message = 'no_permission' }
    end

    local changed = DB.exec(
        'UPDATE `bcc_checks` SET `status` = "voided" WHERE `id` = ? AND `status` = "pending"',
        checkId
    )
    if (tonumber(changed) or 0) ~= 1 then
        return { status = false, message = 'Cannot void a check that is not pending.' }
    end

    if not DepositCash(check.account_id, tonumber(check.amount), 'bank.check.cash') then
        DB.exec('UPDATE `bcc_checks` SET `status` = "pending" WHERE `id` = ? AND `status` = "voided"', checkId)
        return { status = false, message = 'Unable to refund check.' }
    end
    AddAccountTransaction(
        check.account_id,
        characterId,
        tonumber(check.amount),
        'check - voided',
        'Check voided, funds returned'
    )

    return { status = true }
end
