-- Run from the resources directory with Lua 5.4: lua [bcc]/bcc-banks/tests/audit_event_spec.lua
-- Builds bcc-banks audit events and validates them with feather-audit's own
-- contract validator and the registered bank.action.recorded schema.
local audit = '[feather]/feather-audit/'
for _, file in ipairs({ 'shared/constants.lua', 'shared/results.lua', 'shared/contract/canonical.lua',
    'shared/contract/registry.lua', 'shared/contract/validator.lua', 'schemas/banks/action_recorded_v1.lua' }) do
    dofile(audit .. file)
end
Config = { Audit = { sourceInstance = 'default' } }
CreateThread, RegisterCommand = function() end, function() end
GetPlayerName = function() return 'Player' end
DB = { value = function() return '0b8e7a1c-0000-4000-8000-000000000001' end }
BccBanksInternal = {}
dofile('[bcc]/bcc-banks/server/helpers/audit.lua')

local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function validate(event)
    return FeatherAuditValidator.Validate(event, { nowEpoch = os.time(), sourceResource = 'bcc-banks', sourceInstance = 'default' })
end

local lines = { '**Action:** `Loan Repaid`', '**Amount Paid:** `$5`', '**Note:** `see https://example.com/x`' }
lines.actor = { characterId = '18477168-bfe5-11f1-8fad-020133902301', accountId = 'acc-1', name = 'Ion Smecheru' }
local event = BankAudit.BuildEvent('uuid-1', 'Loan Repayment', lines)
local result = validate(event)
check(result.ok, 'character event validates: ' .. tostring(result.code or result.path))
check(event.eventType == 'bank.action.recorded' and event.context.action == 'loan_repayment', 'action key')
check(not event.context.details:find('https?://'), 'URLs are removed from details')
check(event.actor.type == 'character' and event.actor.id == lines.actor.characterId, 'structured actor')

local console = BankAudit.BuildEvent('uuid-2', 'Bank Created', { '**Name:** `Valentine`' })
check(validate(console).ok and console.actor.type == 'system', 'system event validates')

local long = {}
for index = 1, 80 do long[index] = ('**Line %d:** `%s`'):format(index, string.rep('x', 20)) end
check(validate(BankAudit.BuildEvent('uuid-3', 'Big', long)).ok, 'long details are bounded')

local bad = BankAudit.BuildEvent('uuid-4', 'Loan Repayment', lines)
bad.context.unknown = 'x'
check(not validate(bad).ok, 'unregistered context keys are rejected')
print(('Bank audit events: %d checks passed'):format(checks))
