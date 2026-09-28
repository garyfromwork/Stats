--[[
    Stats - FFXI Windower Addon (SQLite Searchable Version)
    Tracks combat statistics into a local database broken down by Job/Subjob
    Permanently archives fights to a local SQLite database for the whole party.

    Commands:
        //stats                     - Show current fight stats
        //stats active              - List enemies currently being tracked
        //stats focus [enemy ID]    - Choose the enemy shown on the overlay
        //stats reset               - Save and reset all active fights
        //stats export [character]  - Export a character's saved fights to CSV
        //stats autolog [on|off]    - Control automatic per-character CSV logging
        //stats review              - Lists the last 10 fights from SQLite
        //stats review [name]       - Search history by monster name or player name
        //stats review [id]         - View deep breakdown of a specific past fight ID
        //stats purge               - Clear history safely with confirmation
]]--

_addon.name = 'Stats'
_addon.author = 'Garyfromwork'
_addon.version = '1.5.0'
_addon.commands = {'stats', 'st'}

require('tables')
require('strings')
require('logger')
local config = require('config')
local res = require('resources')
local sqlite3 = require('sqlite3')

-- Load sub-modules
local tracker = require('tracker')
local display = require('display')

-- Default settings
local defaults = {
    parse_to_chat = false,
    overlay_enabled = true,
    overlay_position = { x = 100, y = 100 },
    track_party = true,
    track_trusts = true,
    track_pets = true,
    auto_log = true
}

local settings = config.load(defaults)
display.init(settings)
local default_overlay_position = {x = defaults.overlay_position.x, y = defaults.overlay_position.y}

-- State
local state = {
    current_fight = nil,
    active_fights = {}, -- [enemy_id] = fight
    action_sequence = 0,
    pending_fights = {},
    session_stats = tracker.create_session_stats(),
    player_id = nil,
    player_name = nil,
    party_members = {} -- Dynamically mapped cache: [id] = data table
}

-- Database Setup
local db_path = windower.addon_path .. 'data/combat_history.db'
if not windower.dir_exists(windower.addon_path .. 'data') then
    windower.create_dir(windower.addon_path .. 'data')
end
local db = sqlite3.open(db_path)
db:exec('PRAGMA busy_timeout = 5000;')
db:exec('PRAGMA journal_mode = WAL;')

-- Initialize Database Tables (Permanent Storage with Defense metrics)
db:exec([[
    CREATE TABLE IF NOT EXISTS fights (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        player_name TEXT,
        main_job TEXT,
        sub_job TEXT,
        enemy_name TEXT,
        timestamp INTEGER,
        duration INTEGER,
        result TEXT
    );
    CREATE TABLE IF NOT EXISTS damage_logs (
        fight_id INTEGER,
        source TEXT,
        action_type TEXT,
        total_damage INTEGER,
        hits INTEGER,
        swings INTEGER,
        evaded_swings INTEGER DEFAULT 0,
        parried_swings INTEGER DEFAULT 0,
        blocked_swings INTEGER DEFAULT 0,
        countered_swings INTEGER DEFAULT 0,
        shadow_swings INTEGER DEFAULT 0,
        total_attacks_received INTEGER DEFAULT 0
    );
]])

-- Existing databases may predate defensive tracking. CREATE TABLE IF NOT EXISTS
-- leaves their original six-column damage_logs table unchanged.
local defense_columns = {
    'evaded_swings',
    'parried_swings',
    'blocked_swings',
    'countered_swings',
    'shadow_swings',
    'total_attacks_received'
}
local damage_columns = {}
for row in db:nrows('PRAGMA table_info(damage_logs)') do
    damage_columns[row.name] = true
end
for _, column in ipairs(defense_columns) do
    if not damage_columns[column] then
        local result = db:exec('ALTER TABLE damage_logs ADD COLUMN ' .. column .. ' INTEGER DEFAULT 0')
        if result ~= sqlite3.OK then
            local upgraded = false
            for row in db:nrows('PRAGMA table_info(damage_logs)') do
                if row.name == column then upgraded = true end
            end
            if not upgraded then
                error('Stats: Could not upgrade damage_logs: ' .. (db:errmsg() or 'unknown SQLite error'))
            end
        end
    end
end
db:exec([[
    CREATE INDEX IF NOT EXISTS stats_fights_character_time
        ON fights(player_name COLLATE NOCASE, timestamp);
    CREATE INDEX IF NOT EXISTS stats_damage_logs_fight
        ON damage_logs(fight_id);
]])

-------------------------------------------
-- Database Logging Functions
-------------------------------------------
local function fight_has_data(fight)
    return fight and (fight.total_swings > 0 or fight.ranged_shots > 0
        or next(fight.weaponskills) or next(fight.spells) or next(fight.abilities)
        or next(fight.trusts) or next(fight.pets)
        or (fight.defense and next(fight.defense)))
end

local export_columns = {
    'fight_id', 'character', 'main_job', 'sub_job', 'enemy', 'started_at',
    'duration_seconds', 'result', 'player_total_damage', 'source', 'action_type', 'damage', 'hits',
    'attempts', 'dodged', 'parried', 'blocked', 'countered', 'shadows'
}

local export_query = [[
    SELECT f.id AS fight_id, f.player_name AS character, f.main_job, f.sub_job,
           f.enemy_name AS enemy, f.timestamp AS started_at,
           f.duration AS duration_seconds, f.result,
           (SELECT COALESCE(SUM(x.total_damage), 0) FROM damage_logs x
            WHERE x.fight_id = f.id AND x.source = 'Player'
              AND x.action_type <> 'Defense') AS player_total_damage,
           d.source, d.action_type, d.total_damage AS damage, d.hits,
           d.swings AS attempts, d.evaded_swings AS dodged,
           d.parried_swings AS parried, d.blocked_swings AS blocked,
           d.countered_swings AS countered, d.shadow_swings AS shadows
    FROM fights f LEFT JOIN damage_logs d ON d.fight_id = f.id
]]

local function csv_value(value)
    if value == nil then return '' end
    return '"' .. tostring(value):gsub('"', '""') .. '"'
end

local function safe_character_name(name)
    return (name or 'Unknown'):gsub('[^%w_-]', '_')
end

local function file_exists(path)
    local file = io.open(path, 'r')
    if not file then return false end
    file:close()
    return true
end

local function write_csv(path, query, parameter, append)
    local exists = file_exists(path)
    local file, err = io.open(path, append and 'a' or 'w')
    if not file then return false, err end

    if not append or not exists then
        file:write(table.concat(export_columns, ',') .. '\n')
    end
    local stmt = db:prepare(query)
    if not stmt then
        file:close()
        return false, db:errmsg()
    end
    stmt:bind_values(parameter)
    for row in stmt:nrows() do
        local fields = {}
        for _, column in ipairs(export_columns) do
            fields[#fields + 1] = csv_value(row[column])
        end
        local ok, write_err = file:write(table.concat(fields, ',') .. '\n')
        if not ok then
            stmt:finalize()
            file:close()
            return false, write_err
        end
    end
    stmt:finalize()
    file:close()
    return true
end

local function auto_log_fight(fight_id, character)
    if not settings.auto_log then return end
    local path = windower.addon_path .. 'data/' .. safe_character_name(character) .. '_stats_log.csv'
    local ok, err = write_csv(path, export_query .. ' WHERE f.id = ? ORDER BY d.rowid', fight_id, true)
    if not ok then log('Stats: Auto log failed: ' .. tostring(err)) end
end

local function export_character(requested_name)
    local lookup = db:prepare('SELECT player_name FROM fights WHERE player_name = ? COLLATE NOCASE ORDER BY id DESC LIMIT 1')
    if not lookup then
        log('Stats export failed: ' .. (db:errmsg() or 'database query failed'))
        return
    end
    lookup:bind_values(requested_name)
    local character = nil
    for row in lookup:nrows() do
        character = row.player_name
        break
    end
    lookup:finalize()
    if not character then
        log('No saved fights found for character: ' .. requested_name)
        return
    end

    local base = safe_character_name(character) .. '_stats_' .. os.date('%Y%m%d_%H%M%S')
    local filename = base .. '.csv'
    local suffix = 2
    while file_exists(windower.addon_path .. 'data/' .. filename) do
        filename = base .. '_' .. suffix .. '.csv'
        suffix = suffix + 1
    end
    local path = windower.addon_path .. 'data/' .. filename
    local ok, err = write_csv(path,
        export_query .. ' WHERE f.player_name = ? COLLATE NOCASE ORDER BY f.id, d.rowid',
        character, false)
    if ok then
        log('Stats exported to: ' .. path)
    else
        log('Stats export failed: ' .. tostring(err))
    end
end

local function write_recovery_fight(fight)
    local path = windower.addon_path .. 'data/' .. safe_character_name(fight.player_name) .. '_stats_recovery.txt'
    local file, err = io.open(path, 'a')
    if not file then
        log('Stats: Could not write recovery file: ' .. tostring(err))
        return
    end
    file:write(string.format('\nCharacter: %s (%s/%s)\nEnemy: %s (#%d)\nStarted: %s\nResult: %s\n',
        fight.player_name, fight.main_job, fight.sub_job, fight.enemy_name,
        fight.enemy_id, os.date('%Y-%m-%d %H:%M:%S', fight.start_time), fight.result or 'Ended'))
    file:write(string.format('Player damage: %d | Melee: %d (%d/%d) | Ranged: %d (%d/%d)\n',
        fight.total_damage, fight.melee_damage, fight.total_hits, fight.total_swings,
        fight.ranged_damage, fight.ranged_hits, fight.ranged_shots))
    for name, data in pairs(fight.weaponskills) do
        file:write(string.format('Weapon Skill: %s | %d damage | %d/%d\n',
            name, data.total_damage, data.hits, data.uses))
    end
    for name, data in pairs(fight.spells) do
        file:write(string.format('Spell: %s | %d damage | %d/%d\n',
            name, data.total_damage, data.landed, data.casts))
    end
    for name, data in pairs(fight.abilities) do
        file:write(string.format('Ability: %s | %d damage | %d uses\n', name, data.total_damage, data.uses))
    end
    for name, data in pairs(fight.trusts) do
        file:write(string.format('Party/Trust: %s | %d damage\n', name, data.total_damage))
    end
    for name, data in pairs(fight.pets) do
        file:write(string.format('Pet: %s | %d damage\n', name, data.total_damage))
    end
    for name, data in pairs(fight.defense or {}) do
        file:write(string.format('Defense: %s | %d attacks | %d hits | %d dodge | %d parry | %d block | %d counter | %d shadow\n',
            name, data.swings, data.hits, data.dodge, data.parry, data.block, data.counter, data.shadow))
    end
    file:close()
    log('Stats: Unsaved fight written to ' .. path)
end

local function save_fight_to_db(fight)
    if not fight_has_data(fight) or fight.saved then return true end

    local duration = fight.end_time and (fight.end_time - fight.start_time) or (os.time() - fight.start_time)
    local result = fight.result or 'Ended'
    local function fail(stage, detail)
        local message = detail or db:errmsg() or 'unknown SQLite error'
        db:exec('ROLLBACK')
        log('Stats: Could not save fight (' .. stage .. '): ' .. message)
        return false
    end

    if db:exec('BEGIN IMMEDIATE') ~= sqlite3.OK then
        log('Stats: Could not start fight save: ' .. (db:errmsg() or 'database busy'))
        return false
    end

    local stmt = db:prepare([[
        INSERT INTO fights (player_name, main_job, sub_job, enemy_name, timestamp, duration, result)
        VALUES (?, ?, ?, ?, ?, ?, ?);
    ]])
    if not stmt then return fail('fight metadata') end
    stmt:bind_values(fight.player_name, fight.main_job, fight.sub_job,
        fight.enemy_name, fight.start_time, duration, result)
    local result_code = stmt:step()
    local master_error = result_code ~= sqlite3.DONE and db:errmsg() or nil
    stmt:finalize()
    if result_code ~= sqlite3.DONE then return fail('fight metadata', master_error) end

    local fight_id = db:last_insert_rowid()

    local dmg_stmt = db:prepare([[
        INSERT INTO damage_logs (fight_id, source, action_type, total_damage, hits, swings)
        VALUES (?, ?, ?, ?, ?, ?);
    ]])
    if not dmg_stmt then return fail('offensive statement') end
    local damage_ok = true
    local damage_error = nil
    local function insert_damage(source, action_type, damage, hits, attempts)
        if not damage_ok then return end
        dmg_stmt:bind_values(fight_id, source, action_type, damage, hits, attempts)
        damage_ok = dmg_stmt:step() == sqlite3.DONE
        if not damage_ok then damage_error = db:errmsg() end
        dmg_stmt:reset()
    end
    if fight.total_swings > 0 then
        insert_damage('Player', 'Melee', fight.melee_damage, fight.total_hits, fight.total_swings)
    end
    if fight.ranged_shots > 0 then
        insert_damage('Player', 'Ranged', fight.ranged_damage, fight.ranged_hits, fight.ranged_shots)
    end
    for name, data in pairs(fight.weaponskills) do
        insert_damage('Player', 'Weapon Skill: ' .. name, data.total_damage, data.hits, data.uses)
    end
    for name, data in pairs(fight.spells) do
        insert_damage('Player', 'Spell: ' .. name, data.total_damage, data.landed, data.casts)
    end
    for name, data in pairs(fight.abilities) do
        insert_damage('Player', 'Ability: ' .. name, data.total_damage, data.uses, data.uses)
    end
    for name, data in pairs(fight.trusts) do
        insert_damage(name, 'Trust', data.total_damage, data.melee_hits, data.melee_swings)
    end
    for name, data in pairs(fight.pets) do
        insert_damage(name, 'Pet', data.total_damage, data.melee_hits, data.melee_swings)
    end
    dmg_stmt:finalize()
    if not damage_ok then return fail('offensive rows', damage_error) end

    if fight.defense and next(fight.defense) then
        local def_stmt = db:prepare([[
            INSERT INTO damage_logs (
                fight_id, source, action_type, total_damage, hits, swings,
                evaded_swings, parried_swings, blocked_swings, countered_swings, shadow_swings, total_attacks_received
            )
            VALUES (?, ?, 'Defense', 0, ?, ?, ?, ?, ?, ?, ?, ?);
        ]])
        if not def_stmt then return fail('defensive statement') end
        local defense_ok = true
        local defense_error = nil
        for name, d in pairs(fight.defense) do
            def_stmt:bind_values(fight_id, name, d.hits, d.swings, d.dodge,
                d.parry, d.block, d.counter, d.shadow, d.swings)
            if def_stmt:step() ~= sqlite3.DONE then
                defense_ok = false
                defense_error = db:errmsg()
            end
            def_stmt:reset()
            if not defense_ok then break end
        end
        def_stmt:finalize()
        if not defense_ok then return fail('defensive rows', defense_error) end
    end

    if db:exec('COMMIT') ~= sqlite3.OK then return fail('commit') end
    fight.saved = true
    auto_log_fight(fight_id, fight.player_name)
    return true
end

-------------------------------------------
-- Utility Functions
-------------------------------------------
local function get_mob_name(mob_id)
    local mob = windower.ffxi.get_mob_by_id(mob_id)
    return mob and mob.name or 'Unknown'
end

local function update_party_cache()
    state.party_members = {}
    local party = windower.ffxi.get_party()
    if not party then return end

    for i = 0, 5 do
        local member = party['p' .. i]
        if member and member.mob then
            local mid = member.mob.id
            local mname = member.mob.name
            local spawn_type = member.mob.spawn_type

            local is_trust = (spawn_type == 14)
            local is_player = (mid == state.player_id)

            state.party_members[mid] = {
                name = mname,
                is_player = is_player,
                is_trust = is_trust,
                is_other_player = (not is_player and not is_trust)
            }

            if settings.track_pets and member.mob.pet_index and member.mob.pet_index > 0 then
                local pet = windower.ffxi.get_mob_by_index(member.mob.pet_index)
                if pet then
                    state.party_members[pet.id] = {
                        name = pet.name,
                        is_player = false,
                        is_trust = false,
                        is_other_player = false,
                        is_pet = true,
                        owner_name = mname
                    }
                end
            end
        end
    end
end

local function get_action_actor(actor_id)
    if not state.party_members[actor_id] then
        update_party_cache()
    end
    return state.party_members[actor_id]
end

local function active_fight_count()
    local count = 0
    for _ in pairs(state.active_fights) do count = count + 1 end
    return count
end

local function most_recent_active_fight()
    local most_recent = nil
    for _, fight in pairs(state.active_fights) do
        if not most_recent or fight.action_sequence > most_recent.action_sequence then
            most_recent = fight
        end
    end
    return most_recent
end

local function update_overlay()
    display.update(state.current_fight, active_fight_count(), state.session_stats, state.player_name)
end

local function ensure_fight_exists(enemy_name, enemy_id, focus)
    local fight = state.active_fights[enemy_id]
    if not fight then
        fight = tracker.create_fight_stats(enemy_name, enemy_id)
        fight.defense = {}
        local player = windower.ffxi.get_player()
        local main_job = player and res.jobs[player.main_job_id]
        local sub_job = player and res.jobs[player.sub_job_id]
        fight.player_name = state.player_name or (player and player.name) or 'Unknown'
        fight.main_job = main_job and main_job.ens or 'Unknown'
        fight.sub_job = sub_job and sub_job.ens or 'NONE'
        state.active_fights[enemy_id] = fight
        if settings.parse_to_chat then log('New fight started: ' .. enemy_name) end
    elseif fight.enemy_name == 'Unknown' and enemy_name ~= 'Unknown' then
        fight.enemy_name = enemy_name
    end

    state.action_sequence = state.action_sequence + 1
    fight.action_sequence = state.action_sequence
    fight.last_action_time = os.time()
    if focus or not state.current_fight or state.current_fight.saved
        or state.active_fights[state.current_fight.enemy_id] ~= state.current_fight then
        state.current_fight = fight
    end
    return fight
end

local function finish_fight(enemy_id, result)
    local fight = state.active_fights[enemy_id]
    if not fight then return end

    fight.result = result
    fight.end_time = os.time()
    if not save_fight_to_db(fight) then
        state.pending_fights[#state.pending_fights + 1] = fight
    end
    state.active_fights[enemy_id] = nil
    if state.current_fight == fight then
        state.current_fight = most_recent_active_fight() or (fight_has_data(fight) and fight or nil)
    end
    update_overlay()
end

local function finish_all_fights(result)
    for enemy_id in pairs(state.active_fights) do
        finish_fight(enemy_id, result)
    end
end

local function retry_pending_fights()
    local remaining = {}
    for _, fight in ipairs(state.pending_fights) do
        if not save_fight_to_db(fight) then
            remaining[#remaining + 1] = fight
        end
    end
    state.pending_fights = remaining
end

local function sync_character(player)
    if not player or not player.id or not player.name then return false end
    local changed = state.player_id ~= player.id or state.player_name ~= player.name
    if state.player_id and changed then
        finish_all_fights('Character changed')
        retry_pending_fights()
        state.active_fights = {}
        state.current_fight = nil
        state.session_stats = tracker.create_session_stats()
        state.party_members = {}
        state.action_sequence = 0
    end
    state.player_id = player.id
    state.player_name = player.name
    if changed then update_overlay() end
    return true
end

local function expire_inactive_fights()
    local now = os.time()
    for enemy_id, fight in pairs(state.active_fights) do
        if now - fight.last_action_time > 120 then
            finish_fight(enemy_id, 'Timed out')
        end
    end
end

-------------------------------------------
-- Action Processing Messages
-------------------------------------------
local hit_messages = { [1] = true, [67] = true, [352] = true, [353] = true, [576] = true, [577] = true }
local crit_messages = { [67] = true, [353] = true }
local miss_messages = { [15] = true, [63] = true, [30] = true, [32] = true, [69] = true, [70] = true, [354] = true, [355] = true }
local ws_hit_messages = { [185] = true, [186] = true, [187] = true, [194] = true, [224] = true, [225] = true, [226] = true, [238] = true, [242] = true }
local ws_miss_messages = { [188] = true, [189] = true }
local spell_land_messages = { [2] = true, [7] = true, [82] = true, [227] = true, [228] = true, [230] = true, [236] = true, [237] = true, [252] = true, [268] = true, [271] = true }
local spell_resist_messages = { [75] = true, [85] = true, [284] = true, [655] = true, [656] = true }
local spell_no_effect_messages = { [75] = true, [283] = true }

-- Defensive Action Bit-Fields
local dodge_messages = { [15] = true, [32] = true }
local parry_messages = { [30] = true }
local block_messages = { [23] = true, [353] = true }
local counter_messages = { [33] = true }
local shadow_messages = { [31] = true, [536] = true }

local function process_melee_action(act)
    local actor = get_action_actor(act.actor_id)
    local focused_target = false

    for _, target in ipairs(act.targets) do
        local target_unit = get_action_actor(target.id)
        local track_actor = actor and (actor.is_player
            or (actor.is_trust and settings.track_trusts)
            or (actor.is_pet and settings.track_pets)
            or (actor.is_other_player and settings.track_party))
        local track_target = target_unit and (target_unit.is_player
            or (settings.track_party and (target_unit.is_other_player or target_unit.is_trust)))

        -------------------------------------------
        -- OFFENSIVE TRACKING (Party -> Monster)
        -------------------------------------------
        if track_actor and not target_unit then
            local enemy_name = get_mob_name(target.id)
            local fight = ensure_fight_exists(enemy_name, target.id, actor.is_player and not focused_target)
            focused_target = true

            for _, action in ipairs(target.actions) do
                local damage = action.param or 0
                local message = action.message
                local is_hit = hit_messages[message] or (not miss_messages[message] and damage > 0)
                local is_crit = crit_messages[message] or false

                if actor.is_player then
                    tracker.record_melee(fight, state.session_stats, { hit = is_hit, critical = is_crit, damage = damage })
                elseif actor.is_trust and settings.track_trusts then
                    tracker.record_trust_melee(fight, state.session_stats, actor.name, { hit = is_hit, critical = is_crit, damage = damage })
                elseif actor.is_pet and settings.track_pets then
                    tracker.record_pet_melee(fight, state.session_stats, actor.name, { hit = is_hit, critical = is_crit, damage = damage })
                elseif actor.is_other_player and settings.track_party then
                    tracker.record_trust_melee(fight, state.session_stats, actor.name, { hit = is_hit, critical = is_crit, damage = damage })
                end
            end

        -------------------------------------------
        -- DEFENSIVE TRACKING (Monster -> Party)
        -------------------------------------------
        elseif not actor and track_target then
            local enemy_name = get_mob_name(act.actor_id)
            local fight = ensure_fight_exists(enemy_name, act.actor_id, false)

            for _, action in ipairs(target.actions) do
                local message = action.message

                local defense_event = {
                    swing = true,
                    is_dodge = dodge_messages[message] or false,
                    is_parry = parry_messages[message] or false,
                    is_block = block_messages[message] or false,
                    is_counter = counter_messages[message] or false,
                    is_shadow = shadow_messages[message] or false,
                    is_hit = (action.param or 0) > 0 and not shadow_messages[message] and not miss_messages[message]
                }

                if target_unit.is_player then
                    tracker.record_defense(fight, state.session_stats, 'Player', defense_event)
                elseif settings.track_party and (target_unit.is_other_player or target_unit.is_trust) then
                    tracker.record_defense(fight, state.session_stats, target_unit.name, defense_event)
                end
            end
        end
    end
    update_overlay()
end

local function process_ranged_action(act)
    local actor = get_action_actor(act.actor_id)
    if not actor or not actor.is_player then return end
    local focused_target = false

    for _, target in ipairs(act.targets) do
        if not state.party_members[target.id] then
            local enemy_name = get_mob_name(target.id)
            local fight = ensure_fight_exists(enemy_name, target.id, not focused_target)
            focused_target = true

            for _, action in ipairs(target.actions) do
                local damage = action.param or 0
                local message = action.message
                local is_hit = hit_messages[message] or (not miss_messages[message] and damage > 0)

                tracker.record_ranged(fight, state.session_stats, { hit = is_hit, critical = false, damage = damage })
            end
        end
    end
    update_overlay()
end

local function process_weaponskill_action(act)
    local actor = get_action_actor(act.actor_id)
    if not actor or not actor.is_player then return end
    local ws = res.weapon_skills[act.param]
    local ws_name = ws and ws.en or ('WS#' .. act.param)
    local focused_target = false

    for _, target in ipairs(act.targets) do
        if not state.party_members[target.id] then
            local fight = ensure_fight_exists(get_mob_name(target.id), target.id, not focused_target)
            focused_target = true
            local total_damage = 0
            local hit_count = 0
            local miss = false

            for _, action in ipairs(target.actions) do
                local damage = action.param or 0
                total_damage = total_damage + damage
                if ws_miss_messages[action.message] then miss = true
                elseif ws_hit_messages[action.message] or damage > 0 then hit_count = hit_count + 1 end
            end

            tracker.record_weaponskill(fight, state.session_stats, { name = ws_name, damage = total_damage, hit = not miss, hits = hit_count })
        end
    end
    update_overlay()
end

local function process_spell_action(act)
    local actor = get_action_actor(act.actor_id)
    if not actor or not actor.is_player then return end
    local spell = res.spells[act.param]
    local spell_name = spell and spell.en or ('Spell#' .. act.param)
    local focused_target = false

    for _, target in ipairs(act.targets) do
        if not state.party_members[target.id] then
            local fight = ensure_fight_exists(get_mob_name(target.id), target.id, not focused_target)
            focused_target = true
            for _, action in ipairs(target.actions) do
                local damage = action.param or 0
                local message = action.message
                local landed = spell_land_messages[message] or damage > 0
                local resisted = spell_resist_messages[message] or spell_no_effect_messages[message]

                tracker.record_spell(fight, state.session_stats, { name = spell_name, type = spell and spell.type or 'Unknown', damage = damage, landed = landed, resisted = resisted })
            end
        end
    end
    update_overlay()
end

local function process_job_ability_action(act)
    local actor = get_action_actor(act.actor_id)
    if not actor or not actor.is_player then return end
    local ability = res.job_abilities[act.param]
    local ability_name = ability and ability.en or ('JA#' .. act.param)
    local focused_target = false

    for _, target in ipairs(act.targets) do
        if not state.party_members[target.id] then
            local fight = ensure_fight_exists(get_mob_name(target.id), target.id, not focused_target)
            focused_target = true
            for _, action in ipairs(target.actions) do
                local damage = action.param or 0
                if damage > 0 then
                    tracker.record_ability(fight, state.session_stats, { name = ability_name, damage = damage })
                end
            end
        end
    end
    update_overlay()
end

-------------------------------------------
-- Packets & Windower Events
-------------------------------------------
windower.register_event('action', function(act)
    local player = windower.ffxi.get_player()
    if not sync_character(player) then return end

    retry_pending_fights()
    update_party_cache()
    expire_inactive_fights()

    local category = act.category
    if category == 1 then process_melee_action(act)
    elseif category == 2 then process_ranged_action(act)
    elseif category == 3 then process_weaponskill_action(act)
    elseif category == 4 then process_spell_action(act)
    elseif category == 6 then process_job_ability_action(act)
    end
end)

windower.register_event('action message', function(actor_id, target_id, actor_index, target_index, message_id, param1, param2, param3)
    sync_character(windower.ffxi.get_player())
    if message_id == 6 then
        finish_fight(target_id, 'Victory')
    end
end)

windower.register_event('unload', function()
    finish_all_fights('Unloaded')
    retry_pending_fights()
    for _, fight in ipairs(state.pending_fights) do
        write_recovery_fight(fight)
    end
    settings:save()
    display.hide()
    db:close()
end)

windower.register_event('zone change', function()
    finish_all_fights('Zoned')
    retry_pending_fights()
    state.current_fight = nil
    update_overlay()
end)

windower.register_event('login', function()
    sync_character(windower.ffxi.get_player())
end)

windower.register_event('logout', function()
    finish_all_fights('Logout')
    retry_pending_fights()
    state.player_id = nil
    state.player_name = nil
    state.current_fight = nil
    state.session_stats = tracker.create_session_stats()
    state.party_members = {}
    update_overlay()
end)

-------------------------------------------
-- Command Handling (Includes Text Search, Defenses, & Purging)
-------------------------------------------
windower.register_event('addon command', function(...)
    local args = T{...}
    local cmd = args[1] and args[1]:lower() or 'show'
    sync_character(windower.ffxi.get_player())
    retry_pending_fights()

    if cmd == 'review' then
        local search_term = #args > 1 and table.concat(args, ' ', 2) or nil

        -- Show this character's history by default; 'all' includes every character.
        if not search_term or search_term:lower() == 'all' then
            local all_characters = search_term and search_term:lower() == 'all'
            if all_characters then
                log('=== Combat History (All Characters, Last 10 Fights) ===')
            else
                if not state.player_name then
                    log('Log in to review this character, or use //stats review all.')
                    return
                end
                log('=== Combat History: ' .. state.player_name .. ' (Last 10 Fights) ===')
            end
            local query = db:prepare('SELECT id, enemy_name, player_name, main_job, sub_job, result, duration '
                .. 'FROM fights WHERE (? = 1 OR LOWER(player_name) = LOWER(?)) ORDER BY id DESC LIMIT 10')
            query:bind_values(all_characters and 1 or 0, state.player_name or '')
            for row in query:nrows() do
                log(string.format("[ID: %-3d] %-15s [By: %s] (%s/%s) - %s (%ds)",
                    row.id, row.enemy_name or 'Unknown', row.player_name or 'Unknown',
                    row.main_job or '?', row.sub_job or '?', row.result or '?', row.duration or 0))
            end
            query:finalize()
            log("--------------------------------------------------------")
            log("Search: //stats review [name] | View ID: //stats review [ID] | All: //stats review all")
            return
        end

        -- Scenario 2: User typed an explicit Entry ID number (Outputs Offense + Defense summaries)
        local id = tonumber(search_term)
        if id and id > 0 and id == math.floor(id) then
            local f_row = nil
            local fight_query = db:prepare('SELECT * FROM fights WHERE id = ?')
            fight_query:bind_values(id)
            for row in fight_query:nrows() do f_row = row end
            fight_query:finalize()

            if not f_row then
                log(string.format("Fight ID %d not found in database.", id))
                return
            end

            log(string.format("=== Fight Report ID: %d ===", f_row.id))
            log(string.format("Enemy: %s | Player: %s (%s/%s)", f_row.enemy_name, f_row.player_name, f_row.main_job, f_row.sub_job))
            log(string.format("Result: %s | Length: %d seconds", f_row.result, f_row.duration))
            log("--------------------------------------------------")

            local damage_query = db:prepare('SELECT * FROM damage_logs WHERE fight_id = ?')
            damage_query:bind_values(id)
            for d_row in damage_query:nrows() do
                if d_row.action_type == 'Defense' then
                    -- Draw the dynamic defensive rate layout
                    local total = d_row.total_attacks_received > 0 and d_row.total_attacks_received or 1
                    local p_rate = math.floor((d_row.parried_swings / total) * 100)
                    local b_rate = math.floor((d_row.blocked_swings / total) * 100)
                    local d_rate = math.floor((d_row.evaded_swings / total) * 100)

                    log(string.format("[DEFENSE] %s - Attacks: %d | Dodge: %d%% | Parry: %d%% | Block: %d%%",
                        d_row.source, total, d_rate, p_rate, b_rate))
                else
                    -- Standard offensive tracking
                    local acc = d_row.swings > 0 and math.floor((d_row.hits / d_row.swings) * 100) or 0
                    log(string.format("[OFFENSE] %s %s: Dmg: %d | Acc: %d%% (%d/%d hits)",
                        d_row.source, d_row.action_type, d_row.total_damage, acc, d_row.hits, d_row.swings))
                end
            end
            damage_query:finalize()

        -- Scenario 3: Text Search matching Player or Monster Column Wildcards
        else
            log(string.format("=== Search Results for '%s' (Max 10) ===", search_term))
            local found_any = false

            local query = db:prepare([[
                SELECT id, enemy_name, player_name, main_job, sub_job, result, duration
                FROM fights
                WHERE instr(LOWER(enemy_name), LOWER(?)) > 0
                   OR instr(LOWER(player_name), LOWER(?)) > 0
                ORDER BY id DESC LIMIT 10
            ]])
            query:bind_values(search_term, search_term)

            for row in query:nrows() do
                found_any = true
                log(string.format("[ID: %-3d]  %-15s (%s/%s) [By: %s] - %s",
                    row.id, row.enemy_name or 'Unknown', row.main_job, row.sub_job, row.player_name, row.result))
            end
            query:finalize()

            if not found_any then
                log("No historical fights found matching that player or monster name.")
            else
                log("--------------------------------------------------------")
                log("Type //stats review [ID] to view deep stats for any fight.")
            end
        end

    elseif cmd == 'purge' then
        local confirm = args[2] and args[2]:lower() or nil

        if confirm == 'confirm' then
            log('Purging database history tables...')
            db:exec("DELETE FROM damage_logs;")
            db:exec("DELETE FROM fights;")
            db:exec("VACUUM;")
            log('Database successfully cleared and optimized.')
        else
            log('!!! WARNING: This will permanently delete ALL historical fight logs !!!')
            log('To proceed, type: //stats purge confirm')
        end

    elseif cmd == 'reset' then
        finish_all_fights('Reset')
        state.current_fight = nil
        log('Active fight stats reset.')
        update_overlay()
    elseif cmd == 'export' then
        if args[3] then
            log('Usage: //stats export [character]')
        else
            local character = args[2] or state.player_name
            if not character then
                log('Log in or specify a character: //stats export <character>')
            else
                export_character(character)
            end
        end
    elseif cmd == 'autolog' then
        local value = args[2] and args[2]:lower()
        if value == 'on' then
            settings.auto_log = true
        elseif value == 'off' then
            settings.auto_log = false
        elseif value ~= nil then
            log('Usage: //stats autolog [on|off]')
            return
        end
        settings:save()
        log('Automatic fight log: ' .. (settings.auto_log and 'ON' or 'OFF'))
    elseif cmd == 'active' then
        local fights = {}
        for _, fight in pairs(state.active_fights) do
            fights[#fights + 1] = fight
        end
        table.sort(fights, function(a, b) return a.enemy_id < b.enemy_id end)
        if #fights == 0 then
            log('No active enemies.')
        else
            log(string.format('Active enemies: %d', #fights))
            for _, fight in ipairs(fights) do
                log(string.format('[#%d] %s: %d your damage%s', fight.enemy_id,
                    fight.enemy_name, fight.total_damage,
                    state.current_fight == fight and ' (overlay)' or ''))
            end
        end
    elseif cmd == 'focus' then
        local enemy_id = tonumber(args[2])
        local fight = enemy_id and state.active_fights[enemy_id]
        if not fight then
            log('Usage: //stats focus <enemy ID> (see //stats active)')
            return
        end
        state.current_fight = fight
        update_overlay()
        log(string.format('Overlay focused on %s (#%d).', fight.enemy_name, enemy_id))
    elseif cmd == 'overlay' then
        local value = args[2] and args[2]:lower()
        if value == 'on' then
            settings.overlay_enabled = true
        elseif value == 'off' then
            settings.overlay_enabled = false
        elseif value == nil then
            settings.overlay_enabled = not settings.overlay_enabled
        else
            log('Usage: //stats overlay [on|off]')
            return
        end
        display.toggle_overlay(settings.overlay_enabled)
        settings:save()
        log('Overlay: ' .. (settings.overlay_enabled and 'ON' or 'OFF'))
    elseif cmd == 'position' then
        if args[2] and args[2]:lower() == 'reset' then
            display.reset_position(default_overlay_position.x, default_overlay_position.y)
            settings:save()
            log('Overlay position reset to 100, 100.')
        else
            log('Usage: //stats position reset')
        end
    elseif cmd == 'show' then
        display.show_summary(state.current_fight)
    elseif cmd == 'report' then
        display.show_detailed(state.current_fight)
    elseif cmd == 'help' then
        log('//stats [show|report|active|focus <enemy ID>|reset|review [all|name|id]|export [character]|autolog [on|off]|purge|overlay [on|off]|position reset]')
    else
        log('Unknown command: ' .. cmd .. '. Use //stats help.')
    end
end)

sync_character(windower.ffxi.get_player())
