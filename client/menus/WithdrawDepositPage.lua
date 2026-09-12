function OpenWithdrawDepositPage(account, actionType, parentPage)
    local pageName = actionType .. ":cash_gold:" .. account.id
    local WithdrawDepositPage = FeatherBankMenu:RegisterPage(pageName)

    local titles = {
        deposit  = Feather.Locale.translateUpper("deposit_title"),
        withdraw = Feather.Locale.translateUpper("withdraw_title")
    }

    local headerTitle = titles[actionType] or Feather.Locale.translateUpper("transaction_title")

    WithdrawDepositPage:RegisterElement("header", {
        value = headerTitle .. " " .. Feather.Locale.translateUpper("cash_gold_header"),
        slot  = "header"
    })

    local cashValue = ''
    WithdrawDepositPage:RegisterElement("input", {
        label       = Feather.Locale.translateUpper("cash_amount_label"),
        placeholder = Feather.Locale.translateUpper("cash_amount_placeholder"),
        style       = {}
    }, function(data)
        cashValue = data.value
    end)

    WithdrawDepositPage:RegisterElement("button", {
        label = headerTitle .. " " .. Feather.Locale.translateUpper("cash_button"),
        style = {}
    }, function()
        local cashAmt = tonumber(cashValue)
        if not cashAmt or cashAmt <= 0 then
            Notify(Feather.Locale.translateUpper("invalid_cash_amount"), 4000)
            return
        end

        if actionType == "deposit" then
            exports['feather-core']:CallRPCAsync("bcc-banks:DepositCash", {
                account     = account.id,
                amount      = cashAmt,
                description = Feather.Locale.translateUpper("deposit_cash_description")
            })
        else
            exports['feather-core']:CallRPCAsync("bcc-banks:WithdrawCash", {
                account     = account.id,
                amount      = cashAmt,
                description = Feather.Locale.translateUpper("withdraw_cash_description")
            })
        end

        FeatherBankMenu:Close()
        OpenWithdrawDepositPage(account, actionType, parentPage)
    end)

    -- Separator under header, consistent with other menus
    WithdrawDepositPage:RegisterElement("line", {
        slot  = "header",
        style = {}
    })

    local goldValue = ''
    WithdrawDepositPage:RegisterElement("input", {
        label       = Feather.Locale.translateUpper("gold_amount_label"),
        placeholder = Feather.Locale.translateUpper("gold_amount_placeholder"),
        style       = {}
    }, function(data)
        goldValue = data.value
    end)

    WithdrawDepositPage:RegisterElement("button", {
        label = headerTitle .. " " .. Feather.Locale.translateUpper("gold_button"),
        style = {}
    }, function()
        local goldAmt = tonumber(goldValue)
        if not goldAmt or goldAmt <= 0 then
            Notify(Feather.Locale.translateUpper("invalid_gold_amount"), 4000)
            return
        end

        if actionType == "deposit" then
            exports['feather-core']:CallRPCAsync("bcc-banks:DepositGold", {
                account     = account.id,
                amount      = goldAmt,
                description = Feather.Locale.translateUpper("deposit_gold_description")
            })
        else
            exports['feather-core']:CallRPCAsync("bcc-banks:WithdrawGold", {
                account     = account.id,
                amount      = goldAmt,
                description = Feather.Locale.translateUpper("withdraw_gold_description")
            })
        end

        FeatherBankMenu:Close()
        OpenWithdrawDepositPage(account, actionType, parentPage)
    end)

    WithdrawDepositPage:RegisterElement("line", {
        slot  = "footer",
        style = {}
    })

    WithdrawDepositPage:RegisterElement("button", {
        label = Feather.Locale.translateUpper("back_button"),
        slot  = "footer",
        style = {}
    }, function()
        parentPage:RouteTo()
    end)

    WithdrawDepositPage:RegisterElement("bottomline", {
        slot  = "footer",
        style = {}
    })

    FeatherBankMenu:Open({ startupPage = WithdrawDepositPage })
end
