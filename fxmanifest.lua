fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

game 'rdr3'
lua54 'yes'
version '1.6.0'
author 'BCC Scripts'

shared_scripts {
   'shared/helpers/*.lua',
   'shared/config.lua',
}

client_scripts {
   'client/feather/init.lua',
   'client/feather/menu_v2.lua',
   'languages/*.lua',
   'client/helpers/*.lua',
   'client/services/*.lua',
   'client/menus/*.lua',
   'client/main.lua',
}

server_scripts {
   '@feather-mysql/lib/MySQL.lua',
   'server/feather/init.lua',
   'server/feather/economy.lua',
   'server/feather/migration.lua',
   'languages/*.lua',
   'server/api-loader.lua',
   'server/helpers/*.lua',
   'server/controllers/*.lua',
   'server/services/*.lua',
   'server/main.lua',
}

dependencies {
   'feather-mysql',
   'feather-core',
   'feather-toolkit',
   'feather-notify',
   'feather-character',
   'feather-economy',
   'feather-roles',
   'feather-inventory',
   'feather-menu-v2',
   'bcc-chat',
}

files {
  'ui/*',
  'ui/images/*',
}
