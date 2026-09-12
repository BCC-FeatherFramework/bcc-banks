-- ─────────────────────────────────────────────
--  WRITE A CHECK  (issuer, from account details)
-- ─────────────────────────────────────────────
function OpenWriteCheckPage(account, ParentPage)
    local WritePage = FeatherBankMenu:RegisterPage('bank:page:check:write:' .. tostring(account.id))

    WritePage:RegisterElement('header', {
        value = Feather.Locale.translateUpper('write_check_header'),
        slot  = 'header'
    })
    WritePage:RegisterElement('subheader', {
        value = Feather.Locale.translateUpper('write_check_subheader'),
        slot  = 'header'
    })
    WritePage:RegisterElement('line', { slot = 'header', style = {} })

    local firstName = ''
    local lastName  = ''
    local amount    = nil
    local memo      = ''

    WritePage:RegisterElement('input', {
        label       = Feather.Locale.translateUpper('check_recipient_label'),
        placeholder = Feather.Locale.translateUpper('check_recipient_placeholder'),
        style       = {}
    }, function(data)
        firstName = data.value or ''
    end)

    WritePage:RegisterElement('input', {
        label       = Feather.Locale.translateUpper('check_recipient_last_label'),
        placeholder = Feather.Locale.translateUpper('check_recipient_last_placeholder'),
        style       = {}
    }, function(data)
        lastName = data.value or ''
    end)

    WritePage:RegisterElement('input', {
        label       = Feather.Locale.translateUpper('check_amount_label'),
        placeholder = Feather.Locale.translateUpper('check_amount_placeholder'),
        style       = {}
    }, function(data)
        amount = tonumber(data.value)
    end)

    WritePage:RegisterElement('input', {
        label       = Feather.Locale.translateUpper('check_memo_label'),
        placeholder = Feather.Locale.translateUpper('check_memo_placeholder'),
        style       = {}
    }, function(data)
        memo = data.value or ''
    end)

    WritePage:RegisterElement('line', { slot = 'footer', style = {} })

    WritePage:RegisterElement('button', {
        label = Feather.Locale.translateUpper('write_check_button'),
        slot  = 'footer',
        style = {}
    }, function()
        local fn = firstName:match('^%s*(.-)%s*$')
        local ln = lastName:match('^%s*(.-)%s*$')

        if fn == '' or ln == '' then
            Notify(Feather.Locale.translateUpper('invalid_check_recipient'), 4000)
            return
        end
        if not amount or amount <= 0 then
            Notify(Feather.Locale.translateUpper('invalid_check_amount'), 4000)
            return
        end

        local ConfirmPage = FeatherBankMenu:RegisterPage('bank:page:check:write:confirm:' .. tostring(account.id))
        ConfirmPage:RegisterElement('header', {
            value = Feather.Locale.translateUpper('check_confirm_header'),
            slot  = 'header'
        })
        ConfirmPage:RegisterElement('textdisplay', {
            value = Feather.Locale.translateUpper('check_confirm_text', tostring(amount), fn, ln),
            style = { ['text-align'] = 'center' }
        })
        ConfirmPage:RegisterElement('button', {
            label = Feather.Locale.translateUpper('confirm_button'),
            style = {}
        }, function()
            local ok = exports['feather-core']:CallRPCAsync('bcc-banks:WriteCheck', {
                account    = account.id,
                first_name = fn,
                last_name  = ln,
                amount     = amount,
                memo       = memo
            })
            if ok then
                OpenAccountDetails(account, ParentPage)
            end
        end)
        ConfirmPage:RegisterElement('line', { slot = 'footer', style = {} })
        ConfirmPage:RegisterElement('button', {
            label = Feather.Locale.translateUpper('back_button'),
            slot  = 'footer',
            style = {}
        }, function()
            FeatherBankMenu:Open({ startupPage = WritePage })
        end)
        ConfirmPage:RegisterElement('bottomline', { slot = 'footer', style = {} })
        FeatherBankMenu:Open({ startupPage = ConfirmPage })
    end)

    WritePage:RegisterElement('button', {
        label = Feather.Locale.translateUpper('back_button'),
        slot  = 'footer',
        style = {}
    }, function()
        OpenAccountDetails(account, ParentPage)
    end)

    WritePage:RegisterElement('bottomline', { slot = 'footer', style = {} })
    FeatherBankMenu:Open({ startupPage = WritePage })
end

-- ─────────────────────────────────────────────
--  ISSUED CHECKS  (issuer, view & void)
-- ─────────────────────────────────────────────
function OpenIssuedChecksPage(account, ParentPage)
    local IssuedPage = FeatherBankMenu:RegisterPage('bank:page:check:issued:' .. tostring(account.id))

    IssuedPage:RegisterElement('header', {
        value = Feather.Locale.translateUpper('issued_checks_header'),
        slot  = 'header'
    })
    IssuedPage:RegisterElement('subheader', {
        value = Feather.Locale.translateUpper('issued_checks_subheader'),
        slot  = 'header'
    })
    IssuedPage:RegisterElement('line', { slot = 'header', style = {} })

    local ok, checks = exports['feather-core']:CallRPCAsync('bcc-banks:GetIssuedChecks', { account = account.id })
    checks = (ok and checks) or {}

    if #checks == 0 then
        IssuedPage:RegisterElement('textdisplay', {
            value = Feather.Locale.translateUpper('no_issued_checks_found'),
            style = { ['text-align'] = 'center', color = 'gray' }
        })
    else
        for _, check in ipairs(checks) do
            local rFirst = check.recipient_first or '?'
            local rLast  = check.recipient_last  or '?'
            local label  = Feather.Locale.translateUpper('issued_check_label', tostring(check.amount), rFirst, rLast)
            if check.memo and check.memo ~= '' then
                label = label .. ' — ' .. tostring(check.memo)
            end

            IssuedPage:RegisterElement('button', {
                label = label,
                style = {}
            }, function()
                local VoidConfirmPage = FeatherBankMenu:RegisterPage('bank:page:check:void:' .. tostring(check.id))
                VoidConfirmPage:RegisterElement('header', {
                    value = Feather.Locale.translateUpper('check_void_confirm_header'),
                    slot  = 'header'
                })
                VoidConfirmPage:RegisterElement('textdisplay', {
                    value = Feather.Locale.translateUpper('check_void_confirm_text', tostring(check.amount)),
                    style = { ['text-align'] = 'center' }
                })
                VoidConfirmPage:RegisterElement('button', {
                    label = Feather.Locale.translateUpper('void_check_button'),
                    style = {}
                }, function()
                    exports['feather-core']:CallRPCAsync('bcc-banks:VoidCheck', { check_id = check.id })
                    OpenIssuedChecksPage(account, ParentPage)
                end)
                VoidConfirmPage:RegisterElement('line', { slot = 'footer', style = {} })
                VoidConfirmPage:RegisterElement('button', {
                    label = Feather.Locale.translateUpper('back_button'),
                    slot  = 'footer',
                    style = {}
                }, function()
                    OpenIssuedChecksPage(account, ParentPage)
                end)
                VoidConfirmPage:RegisterElement('bottomline', { slot = 'footer', style = {} })
                FeatherBankMenu:Open({ startupPage = VoidConfirmPage })
            end)
        end
    end

    IssuedPage:RegisterElement('line', { slot = 'footer', style = {} })
    IssuedPage:RegisterElement('button', {
        label = Feather.Locale.translateUpper('back_button'),
        slot  = 'footer',
        style = {}
    }, function()
        OpenAccountDetails(account, ParentPage)
    end)
    IssuedPage:RegisterElement('bottomline', { slot = 'footer', style = {} })
    FeatherBankMenu:Open({ startupPage = IssuedPage })
end

-- ─────────────────────────────────────────────
--  CASH A CHECK  (recipient, from main bank menu)
-- ─────────────────────────────────────────────
function OpenCashCheckPage(bank, ParentPage)
    local CashPage = FeatherBankMenu:RegisterPage('bank:page:check:cash:' .. tostring(bank.id))

    CashPage:RegisterElement('header', {
        value = Feather.Locale.translateUpper('cash_check_header'),
        slot  = 'header'
    })
    CashPage:RegisterElement('subheader', {
        value = Feather.Locale.translateUpper('cash_check_subheader'),
        slot  = 'header'
    })
    CashPage:RegisterElement('line', { slot = 'header', style = {} })

    local ok, checks = exports['feather-core']:CallRPCAsync('bcc-banks:GetMyChecks', {})
    checks = (ok and checks) or {}

    if #checks == 0 then
        CashPage:RegisterElement('textdisplay', {
            value = Feather.Locale.translateUpper('no_checks_found'),
            style = { ['text-align'] = 'center', color = 'gray' }
        })
    else
        for _, check in ipairs(checks) do
            local iFirst = check.issuer_first or '?'
            local iLast  = check.issuer_last  or '?'
            local label  = Feather.Locale.translateUpper('check_label', tostring(check.amount), iFirst, iLast)
            if check.memo and check.memo ~= '' then
                label = label .. ' — ' .. tostring(check.memo)
            end

            CashPage:RegisterElement('button', {
                label = label,
                style = {}
            }, function()
                local ConfirmPage = FeatherBankMenu:RegisterPage('bank:page:check:cash:confirm:' .. tostring(check.id))
                ConfirmPage:RegisterElement('header', {
                    value = Feather.Locale.translateUpper('check_cash_confirm_header'),
                    slot  = 'header'
                })
                ConfirmPage:RegisterElement('textdisplay', {
                    value = Feather.Locale.translateUpper('check_cash_confirm_text', tostring(check.amount)),
                    style = { ['text-align'] = 'center' }
                })
                ConfirmPage:RegisterElement('button', {
                    label = Feather.Locale.translateUpper('checks_button'),
                    style = {}
                }, function()
                    exports['feather-core']:CallRPCAsync('bcc-banks:CashCheck', { check_id = check.id })
                    OpenCashCheckPage(bank, ParentPage)
                end)
                ConfirmPage:RegisterElement('line', { slot = 'footer', style = {} })
                ConfirmPage:RegisterElement('button', {
                    label = Feather.Locale.translateUpper('back_button'),
                    slot  = 'footer',
                    style = {}
                }, function()
                    FeatherBankMenu:Open({ startupPage = CashPage })
                end)
                ConfirmPage:RegisterElement('bottomline', { slot = 'footer', style = {} })
                FeatherBankMenu:Open({ startupPage = ConfirmPage })
            end)
        end
    end

    CashPage:RegisterElement('line', { slot = 'footer', style = {} })
    CashPage:RegisterElement('button', {
        label = Feather.Locale.translateUpper('back_button'),
        slot  = 'footer',
        style = {}
    }, function()
        ParentPage:RouteTo()
    end)
    CashPage:RegisterElement('bottomline', { slot = 'footer', style = {} })
    FeatherBankMenu:Open({ startupPage = CashPage })
end