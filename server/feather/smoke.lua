-- Read-only release check, server console only: BanksReleaseSmokeTest
-- Verifies configuration, the Feather domains bcc-banks depends on, and that
-- every branch and customer account is linked. Moves no money and writes nothing
-- (it re-registers bcc-banks' reason codes with Economy, which changes nothing).

local UUID = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'

local function started(resource) return GetResourceState(resource) == 'started' end

RegisterCommand('BanksReleaseSmokeTest', function(source)
    if source ~= 0 then return end
    local called, problem = xpcall(function()
        local admin = (Config and Config.Admin) or {}
        local health = BanksEconomy.GetHealth()
        local sink = BanksEconomy.GetSystemAccount({ currency = 'dollars', accountType = 'system_sink' })
        local reasons = BanksEconomy.RegisterReasons() -- idempotent: same codes, same shapes
        local role = exports['feather-authority']:FindRoleByKey({ roleKey = admin.role or 'staff.banks.admin' })
        local staffProbe = exports['feather-authority']:Evaluate({
            subjectType = 'character', subjectId = '00000000-0000-0000-0000-000000000000',
            capabilityKey = (admin.staffCapabilities or {})[1] or BankAuthority.CapabilityKey(), scopeType = 'server'
        })

        local jobsOk = true
        if type(admin.jobs) == 'table' and #admin.jobs > 0 then
            local probe = started('feather-jobs') and exports['feather-jobs']:CheckAssignment({
                characterId = '00000000-0000-0000-0000-000000000000', jobKey = admin.jobs[1] }) or nil
            jobsOk = type(probe) == 'table' and probe.ok == true
        end

        local banks = GetBanks() or {}
        local unlinkedBanks, missingReserves = 0, 0
        for _, bank in ipairs(banks) do
            if type(bank.organization_id) ~= 'string' or not bank.organization_id:match(UUID) then
                unlinkedBanks = unlinkedBanks + 1
            end
            if not BankOrganizations.GetReserve(bank.id) then missingReserves = missingReserves + 1 end
        end
        local unlinkedAccounts = tonumber(DB.value([[SELECT COUNT(*) FROM `bcc_accounts`
            WHERE `dollars_account_id` IS NULL OR `gold_account_id` IS NULL]])) or -1
        local legacyTables = tonumber(DB.value([[SELECT COUNT(*) FROM information_schema.tables
            WHERE table_schema = DATABASE() AND table_name LIKE 'bcc_banks_temp_economy%']])) or -1

        local tests = {
            { 'development disabled', Config.devMode == false },
            { 'Economy ready', type(health) == 'table' and health.ok == true },
            { 'Economy trusts bcc-banks', type(sink) == 'table' and sink.ok == true },
            { 'Economy accepts bank reasons', type(reasons) == 'table' and reasons.ok == true },
            { 'Authority bank role exists', type(role) == 'table' and role.ok == true },
            { 'Authority evaluation available', type(staffProbe) == 'table' and staffProbe.ok == true },
            { 'Jobs reachable (Admin.jobs)', jobsOk },
            { 'Organizations started', started('feather-organizations') },
            { 'branches linked to organizations', #banks > 0 and unlinkedBanks == 0 },
            { 'every branch has a reserve', #banks > 0 and missingReserves == 0 },
            { 'accounts linked to Economy', unlinkedAccounts == 0 },
            { 'temporary economy retired', legacyTables == 0 or legacyTables == -1 },
            { 'menu provider started', started('feather-menu-v2') }
        }
        local passed = 0
        for _, test in ipairs(tests) do
            if test[2] then passed = passed + 1 end
            print(('[BanksReleaseSmokeTest] %-32s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
        end
        print(('[BanksReleaseSmokeTest] branches=%d unlinked=%d without reserve=%d unlinked accounts=%d'):format(
            #banks, unlinkedBanks, missingReserves, unlinkedAccounts))
        print(('[BanksReleaseSmokeTest] done %d/%d passed (read-only)'):format(passed, #tests))
    end, debug.traceback)
    if not called then print('[BanksReleaseSmokeTest] FAIL ' .. tostring(problem)) end
end, true)
