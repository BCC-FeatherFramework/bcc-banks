local OpenGroup = GetRandomIntInRange(1, 0xffffff)
local OpenPrompt = nil
local ClosedGroup = GetRandomIntInRange(1, 0xffffff)
local ClosedPrompt = nil

function GetOpenPromptGroup()
  return OpenGroup
end

function GetOpenPrompt()
  return OpenPrompt
end

function GetClosedPromptGroup()
  return ClosedGroup
end

function BankOpen()
  if not OpenPrompt then
    local result = exports['feather-toolkit']:CreatePrompt({
      label = Feather.Locale.translateUpper('menu_prompt'), control = Config.PromptSettings.TellerKey, groupId = OpenGroup,
      enabled = true, visible = true, pulsing = false, mode = 'hold', holdMode = 'SHORT_TIMED_EVENT'
    })
    if not result or result.ok ~= true then
      error(('[bcc-banks] CreatePrompt failed: %s'):format(result and result.message or 'no result'))
    end
    OpenPrompt = result.value.id
  end
end

function BankClosed()
  if not ClosedPrompt then
    local result = exports['feather-toolkit']:CreatePrompt({
      label = Feather.Locale.translateUpper('menu_prompt'), control = Config.PromptSettings.TellerKey, groupId = ClosedGroup,
      enabled = false, visible = true, pulsing = false, mode = 'hold', holdMode = 'SHORT_TIMED_EVENT'
    })
    if not result or result.ok ~= true then
      error(('[bcc-banks] CreatePrompt failed: %s'):format(result and result.message or 'no result'))
    end
    ClosedPrompt = result.value.id
  end
end

function DeletePrompts()
  if ClosedPrompt then
    exports['feather-toolkit']:RemovePrompt(ClosedPrompt)
    ClosedPrompt = nil
  end

  if OpenPrompt then
    exports['feather-toolkit']:RemovePrompt(OpenPrompt)
    OpenPrompt = nil
  end
end
