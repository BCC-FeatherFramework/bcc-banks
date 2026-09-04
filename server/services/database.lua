BccBanksDatabaseReady = false

CreateThread(function()
    local function ensureColumn(tableName, columnName, definition)
        local rows = MySQL.query.await([[
            SELECT COUNT(*) AS cnt
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME = ?
              AND COLUMN_NAME = ?
        ]], { tableName, columnName })
        local exists = rows and rows[1] and tonumber(rows[1].cnt or 0) > 0
        if not exists then
            MySQL.query.await(('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(tableName, columnName, definition))
        end
    end

    local function ensureColumnDefinition(tableName, columnName, definition)
        local rows = MySQL.query.await([[
            SELECT COUNT(*) AS cnt
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME = ?
              AND COLUMN_NAME = ?
        ]], { tableName, columnName })
        local exists = rows and rows[1] and tonumber(rows[1].cnt or 0) > 0
        if exists then
            MySQL.query.await(('ALTER TABLE `%s` MODIFY COLUMN `%s` %s'):format(tableName, columnName, definition))
        else
            MySQL.query.await(('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(tableName, columnName, definition))
        end
    end

    -- bcc_banks
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_banks` (
            `id` VARCHAR(36) NOT NULL,
            `name` VARCHAR(255) NOT NULL UNIQUE,
            `x` DECIMAL(15,2) NOT NULL,
            `y` DECIMAL(15,2) NOT NULL,
            `z` DECIMAL(15,2) NOT NULL,
            `h` DECIMAL(15,2) NOT NULL,
            `blip` BIGINT DEFAULT -2128054417,
            `hours_active` BOOLEAN NOT NULL DEFAULT FALSE,
            `open_hour` INT UNSIGNED NULL,
            `close_hour` INT UNSIGNED NULL,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])

    -- Ensure column exists for existing installations (add if missing)
    local col = MySQL.query.await([[
        SELECT COUNT(*) AS cnt
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'bcc_banks'
          AND COLUMN_NAME = 'hours_active'
    ]])
    local hasCol = col and col[1] and tonumber(col[1].cnt or 0) or 0
    if hasCol == 0 then
        -- Add missing column with default false
        MySQL.query.await([[ALTER TABLE `bcc_banks` ADD COLUMN `hours_active` BOOLEAN NOT NULL DEFAULT FALSE AFTER `blip`]])
    end

    -- bcc_accounts (no FK to characters)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_accounts` (
            `id` VARCHAR(36) NOT NULL,
            `account_number` CHAR(36) NOT NULL,
            `name` VARCHAR(255) NOT NULL,
            `bank_id` VARCHAR(36) NOT NULL,
            `owner_id` CHAR(36) NOT NULL,
            `dollars_account_id` CHAR(36) NULL,
            `gold_account_id` CHAR(36) NULL,
            `cash` DOUBLE(15,2) DEFAULT 0.0,
            `gold` DOUBLE(15,2) DEFAULT 0.0,
            `is_frozen` BOOLEAN NOT NULL DEFAULT FALSE,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uq_account_number` (`account_number`),
            KEY `idx_accounts_bank` (`bank_id`),
            KEY `idx_accounts_owner` (`owner_id`),
            FOREIGN KEY (`bank_id`) REFERENCES `bcc_banks` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    ensureColumnDefinition('bcc_accounts', 'owner_id', 'CHAR(36) NOT NULL')
    ensureColumn('bcc_accounts', 'dollars_account_id', 'CHAR(36) NULL')
    ensureColumn('bcc_accounts', 'gold_account_id', 'CHAR(36) NULL')

    -- bcc_accounts_access
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_accounts_access` (
            `account_id` VARCHAR(36) NOT NULL,
            `character_id` CHAR(36) NOT NULL,
            `level` INT UNSIGNED DEFAULT 2,
            PRIMARY KEY (`account_id`, `character_id`),
            KEY `idx_baa_account` (`account_id`),
            KEY `idx_baa_character` (`character_id`),
            FOREIGN KEY (`account_id`) REFERENCES `bcc_accounts` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    ensureColumnDefinition('bcc_accounts_access', 'character_id', 'CHAR(36) NOT NULL')

    -- bcc_loans (no FK to characters)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_loans` (
            `id` VARCHAR(36) NOT NULL,
            `account_id` VARCHAR(36) NULL,
            `bank_id` VARCHAR(36) NULL,
            `character_id` CHAR(36) NOT NULL,
            `amount` DOUBLE(15,2) NOT NULL,
            `interest` DOUBLE(15,2) NOT NULL,
            `duration` INT UNSIGNED NOT NULL,
            `status` VARCHAR(20) NOT NULL DEFAULT 'pending',
            `approved_by` CHAR(36) NULL,
            `approved_at` DATETIME NULL,
            `disbursed_account_id` VARCHAR(36) NULL,
            `disbursed_at` DATETIME NULL,
            `last_game_day` INT NULL,
            `game_days_elapsed` INT UNSIGNED NOT NULL DEFAULT 0,
            `due_game_days` INT UNSIGNED NULL,
            `is_defaulted` BOOLEAN NOT NULL DEFAULT FALSE,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_loans_account` (`account_id`),
            KEY `idx_loans_bank` (`bank_id`),
            FOREIGN KEY (`account_id`) REFERENCES `bcc_accounts` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE,
            FOREIGN KEY (`bank_id`) REFERENCES `bcc_banks` (`id`)
              ON DELETE SET NULL ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])

    -- CREATE TABLE IF NOT EXISTS does not upgrade existing installations.
    -- Keep every field used by the application, approval, claim, repayment and
    -- default flows available when updating from an older release.
    ensureColumn('bcc_loans', 'bank_id', 'VARCHAR(36) NULL')
    ensureColumn('bcc_loans', 'interest', 'DOUBLE(15,2) NOT NULL DEFAULT 10.0')
    ensureColumn('bcc_loans', 'approved_by', 'CHAR(36) NULL')
    ensureColumnDefinition('bcc_loans', 'character_id', 'CHAR(36) NOT NULL')
    ensureColumnDefinition('bcc_loans', 'approved_by', 'CHAR(36) NULL')
    ensureColumn('bcc_loans', 'approved_at', 'DATETIME NULL')
    ensureColumn('bcc_loans', 'disbursed_account_id', 'VARCHAR(36) NULL')
    ensureColumn('bcc_loans', 'disbursed_at', 'DATETIME NULL')
    ensureColumn('bcc_loans', 'last_game_day', 'INT NULL')
    ensureColumn('bcc_loans', 'game_days_elapsed', 'INT UNSIGNED NOT NULL DEFAULT 0')
    ensureColumn('bcc_loans', 'due_game_days', 'INT UNSIGNED NULL')
    ensureColumn('bcc_loans', 'is_defaulted', 'BOOLEAN NOT NULL DEFAULT FALSE')
    ensureColumn('bcc_loans', 'created_at', 'DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP')
    ensureColumn('bcc_loans', 'updated_at', 'DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP')

    -- bcc_loans_payments
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_loans_payments` (
            `id` VARCHAR(36) NOT NULL,
            `loan_id` VARCHAR(36) NOT NULL,
            `amount` DOUBLE(15,2) NOT NULL,
            `date_due` DATETIME NOT NULL,
            `is_paid` BOOLEAN NOT NULL DEFAULT FALSE,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_lp_loan` (`loan_id`),
            FOREIGN KEY (`loan_id`) REFERENCES `bcc_loans` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])

    -- bcc_loan_interest_rates (no FKs)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_loan_interest_rates` (
            `character_id` CHAR(36) NOT NULL,
            `bank_id` VARCHAR(36) NOT NULL,
            `interest` DOUBLE(15,2) NOT NULL,
            PRIMARY KEY (`character_id`, `bank_id`),
            KEY `idx_lir_bank` (`bank_id`),
            KEY `idx_lir_character` (`character_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    ensureColumnDefinition('bcc_loan_interest_rates', 'character_id', 'CHAR(36) NOT NULL')

    -- bcc_bank_interest_rates (per-bank base rate used by admin UI)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_bank_interest_rates` (
            `bank_id` VARCHAR(36) NOT NULL,
            `interest` DOUBLE(15,2) NOT NULL,
            PRIMARY KEY (`bank_id`),
            KEY `idx_bir_bank` (`bank_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])

    -- bcc_transactions (no FK to characters)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_transactions` (
            `id` VARCHAR(36) NOT NULL,
            `account_id` VARCHAR(36),
            `loan_id` VARCHAR(36),
            `character_id` CHAR(36) NOT NULL,
            `amount` DOUBLE(15,2) NOT NULL,
            `type` VARCHAR(255) NOT NULL,
            `description` VARCHAR(255) NOT NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_t_account` (`account_id`),
            KEY `idx_t_loan` (`loan_id`),
            FOREIGN KEY (`account_id`) REFERENCES `bcc_accounts` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    ensureColumnDefinition('bcc_transactions', 'character_id', 'CHAR(36) NOT NULL')

    -- bcc_safety_deposit_boxes (no FK to characters)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_safety_deposit_boxes` (
            `id` VARCHAR(36) NOT NULL,
            `name` VARCHAR(255) NOT NULL,
            `bank_id` VARCHAR(36) NOT NULL,
            `owner_id` CHAR(36) NOT NULL,
            `size` VARCHAR(255) NOT NULL,
            `inventory_id` CHAR(40) NULL,
            PRIMARY KEY (`id`),
            KEY `idx_sdb_bank` (`bank_id`),
            KEY `idx_sdb_owner` (`owner_id`),
            FOREIGN KEY (`bank_id`) REFERENCES `bcc_banks` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    ensureColumnDefinition('bcc_safety_deposit_boxes', 'owner_id', 'CHAR(36) NOT NULL')
    ensureColumnDefinition('bcc_safety_deposit_boxes', 'inventory_id', 'CHAR(40) NULL')

    -- bcc_safety_deposit_boxes_access
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_safety_deposit_boxes_access` (
            `safety_deposit_box_id` VARCHAR(36) NOT NULL,
            `character_id` CHAR(36) NOT NULL,
            `level` INT UNSIGNED DEFAULT 2,
            PRIMARY KEY (`safety_deposit_box_id`, `character_id`),
            KEY `idx_sdba_sdb` (`safety_deposit_box_id`),
            KEY `idx_sdba_character` (`character_id`),
            FOREIGN KEY (`safety_deposit_box_id`)
              REFERENCES `bcc_safety_deposit_boxes` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    ensureColumnDefinition('bcc_safety_deposit_boxes_access', 'character_id', 'CHAR(36) NOT NULL')

    -- bcc_checks
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `bcc_checks` (
            `id` VARCHAR(36) NOT NULL,
            `account_id` VARCHAR(36) NOT NULL,
            `issuer_character_id` CHAR(36) NOT NULL,
            `recipient_character_id` CHAR(36) NOT NULL,
            `amount` DOUBLE(15,2) NOT NULL,
            `memo` VARCHAR(255) NOT NULL DEFAULT '',
            `status` VARCHAR(20) NOT NULL DEFAULT 'pending',
            `cashed_at` DATETIME NULL,
            `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `idx_checks_account` (`account_id`),
            KEY `idx_checks_recipient` (`recipient_character_id`),
            KEY `idx_checks_issuer` (`issuer_character_id`),
            FOREIGN KEY (`account_id`) REFERENCES `bcc_accounts` (`id`)
              ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ]])
    ensureColumnDefinition('bcc_checks', 'issuer_character_id', 'CHAR(36) NOT NULL')
    ensureColumnDefinition('bcc_checks', 'recipient_character_id', 'CHAR(36) NOT NULL')

    -- Optional seed
    MySQL.query.await([[
        INSERT IGNORE INTO `bcc_banks` (`id`, `name`, `x`, `y`, `z`, `h`, `blip`, `hours_active`, `open_hour`, `close_hour`)
        VALUES 
        (UUID(), 'Valentine', -307.82, 773.96, 118.70, 2.88, -2128054417, 0, 7, 21),
        (UUID(), 'BlackWater', -810.51, -1275.37, 43.64, 189.16, -2128054417, 0, 7, 21),
        (UUID(), 'Rhodes', 1291.25, -1303.30, 77.04, 322.24, -2128054417, 0, 7, 21),
        (UUID(), 'SaintDenis', 2644.15, -1296.16, 52.25, 111.40, -2128054417, 0, 7, 21);
    ]])

    local checkItemReady = false
    if Config.Checks and Config.Checks.Enabled == true and Config.Checks.UseItem == true then
        local exists = exports['feather-inventory'].initiate().Items.ItemExists(
            Config.Checks.ItemName or 'bank_check')
        checkItemReady = type(exists) == 'table' and exists.ok == true and exists.value == true
        if not checkItemReady then
            print('[bcc-banks] Physical checks are disabled: bank-check item definition is unavailable.')
        end
    end

    BccBanksDatabaseReady = true
    devPrint("Database tables for *bcc-banks* created successfully.")
    TriggerEvent('Feather:Banks:DatabaseReady', checkItemReady)
end)
