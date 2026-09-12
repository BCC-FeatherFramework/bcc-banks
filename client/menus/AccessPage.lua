function OpenAccessMenu(account, ParentPage)
    local AccessMenuPage = FeatherBankMenu:RegisterPage("account:page:access:" .. tostring(account.id))

    AccessMenuPage:RegisterElement("header", {
        value = Feather.Locale.translateUpper("account_access_header"),
        slot  = "header"
    })

    AccessMenuPage:RegisterElement("subheader", {
        value = Feather.Locale.translateUpper("account_access_subheader"),
        slot  = "header"
    })

    AccessMenuPage:RegisterElement("line", {
        slot  = "header",
        style = {}
    })

    AccessMenuPage:RegisterElement("button", {
        label = Feather.Locale.translateUpper("give_access_button"),
        style = {}
    }, function()
        OpenGiveAccessPage(account, ParentPage)
    end)

    AccessMenuPage:RegisterElement("button", {
        label = Feather.Locale.translateUpper("remove_access_button"),
        style = {}
    }, function()
        OpenRemoveAccessPage(account, ParentPage)
    end)

    AccessMenuPage:RegisterElement("line", {
        slot  = "footer",
        style = {}
    })

    AccessMenuPage:RegisterElement("button", {
        label = Feather.Locale.translateUpper("back_button"),
        slot  = "footer",
        style = {}
    }, function()
        OpenAccountDetails(account, ParentPage)
    end)

    AccessMenuPage:RegisterElement("bottomline", {
        slot  = "footer",
        style = {}
    })

    FeatherBankMenu:Open({ startupPage = AccessMenuPage })
end

function OpenGiveAccessPage(account, ParentPage)
    local GiveAccessPage = FeatherBankMenu:RegisterPage("account:page:access:give:" .. tostring(account.id))

    GiveAccessPage:RegisterElement("header", {
        value = Feather.Locale.translateUpper("give_access_header"),
        slot  = "header"
    })

    GiveAccessPage:RegisterElement("line", {
        slot  = "header",
        style = {}
    })

    local firstName = ''
    local lastName  = ''
    local level     = nil

    GiveAccessPage:RegisterElement("input", {
        label       = Feather.Locale.translateUpper("check_recipient_label"),
        placeholder = Feather.Locale.translateUpper("check_recipient_placeholder"),
        style       = {}
    }, function(data)
        firstName = data.value or ''
    end)

    GiveAccessPage:RegisterElement("input", {
        label       = Feather.Locale.translateUpper("check_recipient_last_label"),
        placeholder = Feather.Locale.translateUpper("check_recipient_last_placeholder"),
        style       = {}
    }, function(data)
        lastName = data.value or ''
    end)

    GiveAccessPage:RegisterElement("input", {
        label       = Feather.Locale.translateUpper("access_level_label"),
        placeholder = Feather.Locale.translateUpper("access_level_placeholder"),
        style       = {}
    }, function(data)
        level = tonumber(data.value)
    end)

    GiveAccessPage:RegisterElement("textdisplay", {
        value = Feather.Locale.translateUpper("access_levels_description"),
        slot  = "content"
    })

    GiveAccessPage:RegisterElement("line", {
        slot  = "footer",
        style = {}
    })

    GiveAccessPage:RegisterElement("button", {
        label = Feather.Locale.translateUpper("grant_access_button"),
        slot  = "footer",
        style = {}
    }, function()
        local fn = firstName:match('^%s*(.-)%s*$')
        local ln = lastName:match('^%s*(.-)%s*$')

        if fn == '' or ln == '' then
            Notify(Feather.Locale.translateUpper("invalid_character_id"), 4000)
            return
        end

        if not level or level < 1 or level > 4 then
            Notify(Feather.Locale.translateUpper("invalid_access_level"), 4000)
            return
        end

        local ok, result = exports['feather-core']:CallRPCAsync("bcc-banks:GiveAccountAccess", {
            account    = account.id,
            first_name = fn,
            last_name  = ln,
            level      = level
        })

        if not ok then
            devPrint("Failed to give access:", result)
            return
        end
        OpenAccessMenu(account, ParentPage)
    end)
    
    GiveAccessPage:RegisterElement("button", {
        label = Feather.Locale.translateUpper("back_button"),
        slot  = "footer",
        style = {}
    }, function()
        OpenAccessMenu(account, ParentPage)
    end)

    GiveAccessPage:RegisterElement("bottomline", {
        slot  = "footer",
        style = {}
    })

    FeatherBankMenu:Open({ startupPage = GiveAccessPage })
end

function OpenRemoveAccessPage(account, ParentPage)
    local RemoveAccessPage = FeatherBankMenu:RegisterPage("account:page:access:remove:" .. tostring(account.id))

    RemoveAccessPage:RegisterElement("header", {
        value = Feather.Locale.translateUpper("remove_access_header"),
        slot  = "header"
    })

    RemoveAccessPage:RegisterElement("line", {
        slot  = "header",
        style = {}
    })

    local accountId = NormalizeId(account.id)

    local ok, response = exports['feather-core']:CallRPCAsync("bcc-banks:GetAccountAccessList", {
        account = accountId
    })

    if not ok or not response or type(response) ~= "table" then return end

    local accessList = response.access or {}

    if #accessList == 0 then
        RemoveAccessPage:RegisterElement("textdisplay", {
            value = Feather.Locale.translateUpper("no_access_characters"),
            style = {
                ["text-align"] = "center",
                color           = "gray"
            }
        })
    else
        for _, access in ipairs(accessList) do
            local fullName = (access.first_name or Feather.Locale.translateUpper("unknown")) .. " " .. (access.last_name or "")
            local label    = "[" .. tostring(access.character_id) .. "] " .. fullName .. " (" .. Feather.Locale.translateUpper("level") .. " " .. tostring(access.level) .. ")"

            RemoveAccessPage:RegisterElement("button", {
                label = label,
                style = {}
            }, function()
                local ConfirmPage = FeatherBankMenu:RegisterPage("account:page:access:remove:confirm:" .. tostring(access.character_id))

                ConfirmPage:RegisterElement("header", {
                    value = Feather.Locale.translateUpper("confirm_removal_header"),
                    slot  = "header"
                })

                ConfirmPage:RegisterElement("textdisplay", {
                    value = Feather.Locale.translateUpper("confirm_removal_text") .. "\n" .. fullName .. " [" .. tostring(access.character_id) .. "]",
                    style = { ["text-align"] = "center" }
                })

                ConfirmPage:RegisterElement("button", {
                    label = Feather.Locale.translateUpper("confirm_removal_button"),
                    style = {}
                }, function()
                    local ok = exports['feather-core']:CallRPCAsync("bcc-banks:RemoveAccountAccess", {
                        account   = accountId,
                        character = access.character_id
                    })

                    if ok then devPrint(Feather.Locale.translateUpper("access_removed_log"), access.character_id)
                    else devPrint(Feather.Locale.translateUpper("failed_remove_access_log"), access.character_id) end
                    OpenRemoveAccessPage(account, ParentPage)
                end)

                ConfirmPage:RegisterElement("button", {
                    label = Feather.Locale.translateUpper("cancel_removal_button"),
                    style = {}
                }, function()
                    OpenRemoveAccessPage(account, ParentPage)
                end)

                FeatherBankMenu:Open({ startupPage = ConfirmPage })
            end)
        end
    end

    RemoveAccessPage:RegisterElement("button", {
        label = Feather.Locale.translateUpper("back_button"),
        slot  = "footer",
        style = {}
    }, function()
        ParentPage:RouteTo()
    end)

    FeatherBankMenu:Open({ startupPage = RemoveAccessPage })
end
