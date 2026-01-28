--[[
    Stats - FFXI Windower Addon
    Tracks combat statistics including accuracy, damage, and magic accuracy

    Commands:
        //stats                     - Show current fight stats
        //stats report              - Show detailed report
        //stats reset               - Reset current fight stats
        //stats history             - Show fight history
        //stats enemy [name]        - Show stats for specific enemy type
        //stats spell [name]        - Show stats for specific spell
        //stats ws [name]           - Show stats for specific weapon skill
        //stats session             - Show session totals
        //stats export              - Export stats to file
        //stats parse [on/off]      - Toggle chat parsing display
        //stats overlay [on/off]    - Toggle on-screen overlay
        //stats clear               - Clear all history
        //stats help                - Show help
]]--

_addon.name = 'Stats'
_addon.author = 'Garyfromwork'
_addon.version = '1.0.0'
_addon.commands = {'stats', 'st'}

require('tables')
require('strings')
require('logger')
local config = require('config')
local texts = require('texts')
local res = require('resources')

-- Load sub-modules
local tracker = require('tracker')
local display = require('display')

-- Default settings
local defaults = {
    parse_to_chat = false,
    overlay_enabled = true,
    overlay_position = { x = 100, y = 100 },
    track_party = false,  -- Only track self by default
    auto_reset_on_new_fight = true,
    history_limit = 50
}

local settings = config.load(defaults)

-- Initialize display
display.init(settings)

-- State
local state = {
    current_fight = nil,
    fight_history = {},
    session_stats = tracker.create_session_stats(),
    player_id = nil,
    player_name = nil
}

-------------------------------------------
-- Utility Functions
-------------------------------------------

local function get_player_info()
    local player = windower.ffxi.get_player()
    if player then
        state.player_id = player.id
        state.player_name = player.name
    end
end

local function get_mob_name(mob_id)
    local mob = windower.ffxi.get_mob_by_id(mob_id)
    if mob then
        return mob.name
    end
    return 'Unknown'
end

local function is_player_action(actor_id)
    return actor_id == state.player_id
end

local function start_new_fight(enemy_name, enemy_id)
    -- Save current fight to history if it has data
    if state.current_fight and state.current_fight.total_swings > 0 then
        table.insert(state.fight_history, 1, state.current_fight)

        -- Limit history size
        while #state.fight_history > settings.history_limit do
            table.remove(state.fight_history)
        end
    end

    state.current_fight = tracker.create_fight_stats(enemy_name, enemy_id)

    if settings.parse_to_chat then
        log('New fight started: ' .. enemy_name)
    end
end

local function ensure_fight_exists(enemy_name, enemy_id)
    if not state.current_fight then
        start_new_fight(enemy_name, enemy_id)
    elseif settings.auto_reset_on_new_fight and state.current_fight.enemy_id ~= enemy_id then
        start_new_fight(enemy_name, enemy_id)
    end
end

-------------------------------------------
-- Action Processing
-------------------------------------------

-- Message ID references for determining hit/miss/etc
local hit_messages = {
    [1] = true,    -- Melee hit
    [15] = true,   -- Melee hit (additional effect)
    [63] = true,   -- Critical hit
    [352] = true,  -- Ranged hit
    [353] = true,  -- Ranged critical
    [576] = true,  -- Ranged hit (squarely)
    [577] = true,  -- Ranged critical (squarely)
}

local miss_messages = {
    [15] = false,  -- Miss
    [0] = true,    -- Miss (some contexts)
    [354] = true,  -- Ranged miss
    [324] = true,  -- Anticipated (shadow absorbed for reference)
}

local ws_messages = {
    [185] = true,  -- WS damage
    [186] = true,  -- WS damage (MB)
    [187] = true,  -- WS damage
    [188] = true,  -- WS no damage
    [189] = true,  -- WS miss
    [317] = true,  -- WS damage (additional)
}

local spell_land_messages = {
    [2] = true,    -- Spell damage
    [227] = true,  -- Enfeeble lands
    [236] = true,  -- Spell resisted (partial)
    [237] = true,  -- No effect (full resist)
    [252] = true,  -- Enfeeble lands (alt)
    [253] = true,  -- Enfeeble resisted
    [266] = true,  -- Enfeeble wears (for reference)
    [270] = true,  -- Spell lands
    [271] = true,  -- Spell has no effect
    [277] = true,  -- Spell lands (alt)
}

local spell_resist_messages = {
    [85] = true,   -- Resisted
    [236] = true,  -- Partial resist
    [237] = true,  -- Full resist / no effect
    [253] = true,  -- Enfeeble resisted
    [284] = true,  -- Resisted
    [655] = true,  -- Resisted
}

local function process_melee_action(act)
    if not is_player_action(act.actor_id) then return end

    for _, target in ipairs(act.targets) do
        local enemy_name = get_mob_name(target.id)
        ensure_fight_exists(enemy_name, target.id)

        for _, action in ipairs(target.actions) do
            local damage = action.param or 0
            local message = action.message

            -- Determine if hit or miss
            local is_hit = false
            local is_crit = false

            if message == 1 or message == 15 then
                is_hit = true
            elseif message == 63 then
                is_hit = true
                is_crit = true
            elseif message == 0 or message == 354 then
                -- Miss
                is_hit = false
            else
                -- Default: if damage > 0, it's a hit
                is_hit = damage > 0
            end

            tracker.record_melee(state.current_fight, state.session_stats, {
                hit = is_hit,
                critical = is_crit,
                damage = damage
            })

            if settings.parse_to_chat and damage > 0 then
                log(string.format('Melee: %d damage%s', damage, is_crit and ' (CRIT)' or ''))
            end
        end
    end

    display.update(state.current_fight)
end

local function process_ranged_action(act)
    if not is_player_action(act.actor_id) then return end

    for _, target in ipairs(act.targets) do
        local enemy_name = get_mob_name(target.id)
        ensure_fight_exists(enemy_name, target.id)

        for _, action in ipairs(target.actions) do
            local damage = action.param or 0
            local message = action.message

            local is_hit = (message == 352 or message == 353 or message == 576 or message == 577)
            local is_crit = (message == 353 or message == 577)

            if not is_hit and damage > 0 then
                is_hit = true
            end

            tracker.record_ranged(state.current_fight, state.session_stats, {
                hit = is_hit,
                critical = is_crit,
                damage = damage
            })

            if settings.parse_to_chat and damage > 0 then
                log(string.format('Ranged: %d damage%s', damage, is_crit and ' (CRIT)' or ''))
            end
        end
    end

    display.update(state.current_fight)
end

local function process_weaponskill_action(act)
    if not is_player_action(act.actor_id) then return end

    local ws = res.weapon_skills[act.param]
    local ws_name = ws and ws.en or ('WS#' .. act.param)

    for _, target in ipairs(act.targets) do
        local enemy_name = get_mob_name(target.id)
        ensure_fight_exists(enemy_name, target.id)

        local total_damage = 0
        local hit_count = 0
        local miss = false

        for _, action in ipairs(target.actions) do
            local damage = action.param or 0
            total_damage = total_damage + damage

            if action.message == 188 or action.message == 189 then
                miss = true
            else
                hit_count = hit_count + 1
            end
        end

        tracker.record_weaponskill(state.current_fight, state.session_stats, {
            name = ws_name,
            damage = total_damage,
            hit = not miss and total_damage > 0,
            hits = hit_count
        })

        if settings.parse_to_chat then
            if miss then
                log(string.format('WS: %s - MISS', ws_name))
            else
                log(string.format('WS: %s - %d damage', ws_name, total_damage))
            end
        end
    end

    display.update(state.current_fight)
end

local function process_spell_action(act)
    if not is_player_action(act.actor_id) then return end

    local spell = res.spells[act.param]
    local spell_name = spell and spell.en or ('Spell#' .. act.param)
    local spell_type = spell and spell.type or 'Unknown'

    for _, target in ipairs(act.targets) do
        local enemy_name = get_mob_name(target.id)
        ensure_fight_exists(enemy_name, target.id)

        for _, action in ipairs(target.actions) do
            local damage = action.param or 0
            local message = action.message

            -- Determine if spell landed or resisted
            local landed = true
            local resisted = false

            if spell_resist_messages[message] then
                resisted = true
                landed = (message == 236)  -- Partial resist still "lands"
            end

            -- For enfeebling/status spells
            if message == 237 or message == 271 then
                landed = false  -- No effect
            end

            tracker.record_spell(state.current_fight, state.session_stats, {
                name = spell_name,
                type = spell_type,
                damage = damage,
                landed = landed,
                resisted = resisted
            })

            if settings.parse_to_chat then
                if damage > 0 then
                    log(string.format('Spell: %s - %d damage%s', spell_name, damage, resisted and ' (resisted)' or ''))
                else
                    log(string.format('Spell: %s - %s', spell_name, landed and 'Landed' or 'Resisted'))
                end
            end
        end
    end

    display.update(state.current_fight)
end

local function process_job_ability_action(act)
    if not is_player_action(act.actor_id) then return end

    -- Job abilities that deal damage (like Jump)
    local ability = res.job_abilities[act.param]
    local ability_name = ability and ability.en or ('JA#' .. act.param)

    for _, target in ipairs(act.targets) do
        local enemy_name = get_mob_name(target.id)
        ensure_fight_exists(enemy_name, target.id)

        for _, action in ipairs(target.actions) do
            local damage = action.param or 0

            if damage > 0 then
                tracker.record_ability(state.current_fight, state.session_stats, {
                    name = ability_name,
                    damage = damage
                })

                if settings.parse_to_chat then
                    log(string.format('JA: %s - %d damage', ability_name, damage))
                end
            end
        end
    end

    display.update(state.current_fight)
end

-------------------------------------------
-- Event Handlers
-------------------------------------------

windower.register_event('action', function(act)
    if not state.player_id then
        get_player_info()
    end

    local category = act.category

    -- Category 1: Melee attack
    if category == 1 then
        process_melee_action(act)

    -- Category 2: Ranged attack
    elseif category == 2 then
        process_ranged_action(act)

    -- Category 3: Weapon skill
    elseif category == 3 then
        process_weaponskill_action(act)

    -- Category 4: Spell finish
    elseif category == 4 then
        process_spell_action(act)

    -- Category 6: Job ability
    elseif category == 6 then
        process_job_ability_action(act)

    -- Category 11: NPC TP move (monster abilities)
    -- Category 13: Pet ability
    -- Category 14: Unblinkable job ability
    -- Category 15: Run ability (RUN)
    end
end)

-- Track when enemies die to finalize fights
windower.register_event('action message', function(actor_id, target_id, actor_index, target_index, message_id, param1, param2, param3)
    -- Message 6 = defeated
    if message_id == 6 and state.current_fight and state.current_fight.enemy_id == target_id then
        state.current_fight.result = 'Victory'
        state.current_fight.end_time = os.time()

        if settings.parse_to_chat then
            log('Enemy defeated! Fight ended.')
        end
    end
end)

-------------------------------------------
-- Command Handling
-------------------------------------------

windower.register_event('addon command', function(...)
    local args = T{...}
    local cmd = args[1] and args[1]:lower() or 'show'

    if cmd == 'help' then
        log('Stats Commands:')
        log('  //stats              - Show current fight stats')
        log('  //stats report       - Show detailed report')
        log('  //stats reset        - Reset current fight')
        log('  //stats history      - Show fight history')
        log('  //stats enemy [name] - Stats for enemy type')
        log('  //stats spell [name] - Stats for spell')
        log('  //stats ws [name]    - Stats for weapon skill')
        log('  //stats session      - Session totals')
        log('  //stats export       - Export to file')
        log('  //stats parse [on/off] - Toggle chat output')
        log('  //stats overlay [on/off] - Toggle overlay')
        log('  //stats clear        - Clear all history')

    elseif cmd == 'show' or cmd == '' then
        if state.current_fight then
            display.show_summary(state.current_fight)
        else
            log('No current fight data.')
        end

    elseif cmd == 'report' then
        if state.current_fight then
            display.show_detailed(state.current_fight)
        else
            log('No current fight data.')
        end

    elseif cmd == 'reset' then
        if state.current_fight and state.current_fight.total_swings > 0 then
            table.insert(state.fight_history, 1, state.current_fight)
        end
        state.current_fight = nil
        log('Fight stats reset.')
        display.update(nil)

    elseif cmd == 'history' then
        if #state.fight_history == 0 then
            log('No fight history.')
        else
            log('=== Fight History ===')
            for i, fight in ipairs(state.fight_history) do
                if i > 10 then break end
                local acc = fight.total_swings > 0 and
                    math.floor((fight.total_hits / fight.total_swings) * 100) or 0
                local duration = fight.end_time and (fight.end_time - fight.start_time) or 0
                log(string.format('%d. %s - Acc: %d%% (%d/%d) - %s',
                    i, fight.enemy_name, acc, fight.total_hits, fight.total_swings,
                    fight.result or 'Ongoing'))
            end
        end

    elseif cmd == 'enemy' then
        local enemy_name = args[2]
        if not enemy_name then
            log('Usage: //stats enemy <name>')
            return
        end

        enemy_name = enemy_name:lower()
        local combined = tracker.create_fight_stats('Combined: ' .. enemy_name, 0)
        local count = 0

        -- Search history for matching enemies
        for _, fight in ipairs(state.fight_history) do
            if fight.enemy_name:lower():find(enemy_name) then
                tracker.combine_stats(combined, fight)
                count = count + 1
            end
        end

        if state.current_fight and state.current_fight.enemy_name:lower():find(enemy_name) then
            tracker.combine_stats(combined, state.current_fight)
            count = count + 1
        end

        if count > 0 then
            log(string.format('=== Stats for "%s" (%d fights) ===', enemy_name, count))
            display.show_detailed(combined)
        else
            log('No fights found against: ' .. enemy_name)
        end

    elseif cmd == 'spell' then
        local spell_name = args[2]
        if not spell_name then
            log('Usage: //stats spell <name>')
            return
        end

        spell_name = spell_name:lower()
        display.show_spell_stats(state.session_stats, spell_name)

    elseif cmd == 'ws' then
        local ws_name = args[2]
        if not ws_name then
            log('Usage: //stats ws <name>')
            return
        end

        ws_name = ws_name:lower()
        display.show_ws_stats(state.session_stats, ws_name)

    elseif cmd == 'session' then
        log('=== Session Statistics ===')
        display.show_session(state.session_stats)

    elseif cmd == 'export' then
        local filename = args[2] or ('stats_' .. os.date('%Y%m%d_%H%M%S') .. '.txt')
        local filepath = windower.addon_path .. 'data/' .. filename

        local file = io.open(filepath, 'w')
        if file then
            file:write('Stats Export - ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n')
            file:write('========================================\n\n')

            file:write('Session Statistics:\n')
            file:write(string.format('  Total Melee Swings: %d\n', state.session_stats.melee.swings))
            file:write(string.format('  Total Melee Hits: %d\n', state.session_stats.melee.hits))
            file:write(string.format('  Melee Accuracy: %.1f%%\n',
                state.session_stats.melee.swings > 0 and
                (state.session_stats.melee.hits / state.session_stats.melee.swings * 100) or 0))
            file:write(string.format('  Total Damage: %d\n', state.session_stats.melee.total_damage))
            file:write('\n')

            file:write('Weapon Skills:\n')
            for ws_name, ws_data in pairs(state.session_stats.weaponskills) do
                file:write(string.format('  %s: %d uses, %d-%d damage, Avg: %d\n',
                    ws_name, ws_data.uses, ws_data.min_damage, ws_data.max_damage,
                    ws_data.uses > 0 and math.floor(ws_data.total_damage / ws_data.uses) or 0))
            end
            file:write('\n')

            file:write('Spells:\n')
            for spell_name, spell_data in pairs(state.session_stats.spells) do
                local acc = spell_data.casts > 0 and (spell_data.landed / spell_data.casts * 100) or 0
                file:write(string.format('  %s: %d casts, %.1f%% accuracy\n',
                    spell_name, spell_data.casts, acc))
            end

            file:close()
            log('Stats exported to: ' .. filepath)
        else
            log('Failed to export stats.')
        end

    elseif cmd == 'parse' then
        if args[2] then
            settings.parse_to_chat = (args[2]:lower() == 'on')
        else
            settings.parse_to_chat = not settings.parse_to_chat
        end
        log('Chat parsing: ' .. (settings.parse_to_chat and 'ON' or 'OFF'))
        settings:save()

    elseif cmd == 'overlay' then
        if args[2] then
            settings.overlay_enabled = (args[2]:lower() == 'on')
        else
            settings.overlay_enabled = not settings.overlay_enabled
        end
        display.toggle_overlay(settings.overlay_enabled)
        log('Overlay: ' .. (settings.overlay_enabled and 'ON' or 'OFF'))
        settings:save()

    elseif cmd == 'clear' then
        state.fight_history = {}
        state.current_fight = nil
        state.session_stats = tracker.create_session_stats()
        log('All stats cleared.')
        display.update(nil)

    else
        log('Unknown command: ' .. cmd .. '. Use //stats help')
    end
end)

-------------------------------------------
-- Initialization
-------------------------------------------

windower.register_event('load', function()
    log('Stats loaded. Use //stats help for commands.')
    get_player_info()

    -- Create data directory if it doesn't exist
    windower.execute(windower.windower_path .. 'addons/Stats/data/', '', false)
end)

windower.register_event('login', function()
    get_player_info()
end)

windower.register_event('unload', function()
    settings:save()
    display.hide()
end)

windower.register_event('zone change', function()
    -- Optionally reset on zone
    if state.current_fight then
        state.current_fight.result = 'Zoned'
        state.current_fight.end_time = os.time()

        if state.current_fight.total_swings > 0 then
            table.insert(state.fight_history, 1, state.current_fight)
        end
        state.current_fight = nil
        display.update(nil)
    end
end)
