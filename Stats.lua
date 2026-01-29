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
-- Reference: https://github.com/Windower/Resources/blob/master/resources_data/action_messages.lua
local hit_messages = {
    [1] = true,    -- Melee hit: "${actor} hits ${target} for ${number} points of damage."
    [67] = true,   -- Critical hit: "${actor} scores a critical hit!${lb}${target} takes ${number} points of damage."
    [352] = true,  -- Ranged hit: "${actor}'s ranged attack hits ${target} for ${number} points of damage."
    [353] = true,  -- Ranged critical: "${actor}'s ranged attack scores a critical hit!"
    [576] = true,  -- Ranged hit (squarely): "${actor}'s ranged attack hits ${target} squarely"
    [577] = true,  -- Ranged strike true: "${actor}'s ranged attack strikes true, pummeling ${target}"
}

local crit_messages = {
    [67] = true,   -- Melee critical hit
    [353] = true,  -- Ranged critical hit
}

local miss_messages = {
    [15] = true,   -- Miss: "${actor} misses ${target}."
    [63] = true,   -- Miss (alternate): "${actor} misses ${target}."
    [30] = true,   -- Anticipated: "${target} anticipates the attack."
    [32] = true,   -- Dodged: "${target} dodges the attack."
    [69] = true,   -- Blocked: "${target} blocks ${actor}'s attack with his shield."
    [70] = true,   -- Parried: "${target} parries ${actor}'s attack with his weapon."
    [354] = true,  -- Ranged miss: "${actor}'s ranged attack misses."
    [355] = true,  -- Ranged no effect: "${actor}'s ranged attack has no effect on ${target}."
}

local ws_hit_messages = {
    [185] = true,  -- WS damage: "${actor} uses ${weapon_skill}.${lb}${target} takes ${number} points of damage."
    [186] = true,  -- WS status effect: "${actor} uses ${weapon_skill}.${lb}${target} gains the effect of ${status}."
    [187] = true,  -- WS HP drain: "${actor} uses ${weapon_skill}.${lb}${number} HP drained from ${target}."
    [194] = true,  -- WS status effect (alt): "${actor} uses ${weapon_skill}.${lb}${target} gains the effect of ${status}."
    [224] = true,  -- WS MP recovery: "${actor} uses ${weapon_skill}.${lb}${target} recovers ${number} MP."
    [225] = true,  -- WS MP drain: "${actor} uses ${weapon_skill}.${lb}${number} MP drained from ${target}."
    [226] = true,  -- WS TP drain: "${actor} uses ${weapon_skill}.${lb}${number} TP drained from ${target}."
    [238] = true,  -- WS HP recovery: "${actor} uses ${weapon_skill}.${lb}${target} recovers ${number} HP."
    [242] = true,  -- WS status: "${actor} uses ${weapon_skill}.${lb}${target} is ${status}."
}

local ws_miss_messages = {
    [188] = true,  -- WS miss: "${actor} uses ${weapon_skill}, but misses ${target}."
    [189] = true,  -- WS no effect: "${actor} uses ${weapon_skill}.${lb}No effect on ${target}."
}

local spell_damage_messages = {
    [2] = true,    -- Spell damage: "${actor} casts ${spell}.${lb}${target} takes ${number} points of damage."
    [252] = true,  -- Magic Burst damage: "${actor} casts ${spell}.${lb}Magic Burst! ${target} takes ${number} points of damage."
    [265] = true,  -- Magic Burst (alt): "Magic Burst! ${target} takes ${number} points of damage."
    [274] = true,  -- Magic Burst HP drain: "${actor} casts ${spell}.${lb}Magic Burst! ${number} HP drained from ${target}."
    [275] = true,  -- Magic Burst MP drain: "${actor} casts ${spell}.${lb}Magic Burst! ${number} MP drained from ${target}."
}

local spell_land_messages = {
    [2] = true,    -- Spell damage
    [7] = true,    -- HP recovery: "${actor} casts ${spell}.${lb}${target} recovers ${number} HP."
    [82] = true,   -- Status applied: "${actor} casts ${spell}.${lb}${target} is ${status}!"
    [227] = true,  -- HP drain: "${actor} casts ${spell}.${lb}${number} HP drained from ${target}."
    [228] = true,  -- MP drain: "${actor} casts ${spell}.${lb}${number} MP drained from ${target}."
    [230] = true,  -- Status gained: "${actor} casts ${spell}.${lb}${target} gains the effect of ${status}."
    [236] = true,  -- Status applied (alt): "${actor} casts ${spell}.${lb}${target} is ${status}."
    [237] = true,  -- Status received: "${actor} casts ${spell}.${lb}${target} receives the effect of ${status}."
    [252] = true,  -- Magic Burst damage
    [268] = true,  -- Magic Burst status: "${actor} casts ${spell}.${lb}Magic Burst! ${target} receives the effect of ${status}."
    [271] = true,  -- Magic Burst status: "${actor} casts ${spell}.${lb}Magic Burst! ${target} is ${status}."
}

local spell_resist_messages = {
    [75] = true,   -- No effect: "${actor}'s ${spell} has no effect on ${target}."
    [85] = true,   -- Resisted: "${actor} casts ${spell}.${lb}${target} resists the spell."
    [284] = true,  -- Resisted: "${target} resists the effects of the spell!"
    [655] = true,  -- Completely resisted: "${actor} casts ${spell}.${lb}${target} completely resists the spell."
    [656] = true,  -- Completely resisted (alt): "${target} completely resists the spell."
}

local spell_no_effect_messages = {
    [75] = true,   -- No effect
    [283] = true,  -- No effect: "No effect on ${target}."
}

local function process_melee_action(act)
    if not is_player_action(act.actor_id) then return end

    for _, target in ipairs(act.targets) do
        local enemy_name = get_mob_name(target.id)
        ensure_fight_exists(enemy_name, target.id)

        for _, action in ipairs(target.actions) do
            local damage = action.param or 0
            local message = action.message

            -- Determine if hit or miss using correct message IDs
            local is_hit = false
            local is_crit = false

            if hit_messages[message] then
                is_hit = true
                is_crit = crit_messages[message] or false
            elseif miss_messages[message] then
                -- Explicit miss messages (15, 63, 30, 32, 69, 70)
                is_hit = false
            else
                -- Fallback: if damage > 0, it's a hit
                is_hit = damage > 0
            end

            tracker.record_melee(state.current_fight, state.session_stats, {
                hit = is_hit,
                critical = is_crit,
                damage = damage
            })

            if settings.parse_to_chat then
                if is_hit and damage > 0 then
                    log(string.format('Melee: %d damage%s', damage, is_crit and ' (CRIT)' or ''))
                elseif not is_hit then
                    log('Melee: MISS')
                end
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

            -- Use lookup tables for ranged hit detection
            local is_hit = hit_messages[message] or false
            local is_crit = crit_messages[message] or false

            -- Check for explicit ranged miss
            if miss_messages[message] then
                is_hit = false
            elseif not is_hit and damage > 0 then
                -- Fallback: if damage > 0, it's a hit
                is_hit = true
            end

            tracker.record_ranged(state.current_fight, state.session_stats, {
                hit = is_hit,
                critical = is_crit,
                damage = damage
            })

            if settings.parse_to_chat then
                if is_hit and damage > 0 then
                    log(string.format('Ranged: %d damage%s', damage, is_crit and ' (CRIT)' or ''))
                elseif not is_hit then
                    log('Ranged: MISS')
                end
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
            local message = action.message
            total_damage = total_damage + damage

            -- Use correct WS miss messages (188 = miss, 189 = no effect)
            if ws_miss_messages[message] then
                miss = true
            elseif ws_hit_messages[message] or damage > 0 then
                hit_count = hit_count + 1
            end
        end

        tracker.record_weaponskill(state.current_fight, state.session_stats, {
            name = ws_name,
            damage = total_damage,
            hit = not miss and (hit_count > 0 or total_damage > 0),
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

            -- Determine if spell landed or resisted using correct message IDs
            local landed = false
            local resisted = false
            local is_magic_burst = false

            -- Check for resist messages first (75, 85, 284, 655, 656)
            if spell_resist_messages[message] then
                resisted = true
                landed = false
            -- Check for no effect messages
            elseif spell_no_effect_messages[message] then
                landed = false
                resisted = true
            -- Check for landed messages (damage, status effects, drains, etc.)
            elseif spell_land_messages[message] then
                landed = true
                -- Check if it was a Magic Burst (252, 265, 268, 271, 274, 275)
                if message == 252 or message == 265 or message == 268 or
                   message == 271 or message == 274 or message == 275 then
                    is_magic_burst = true
                end
            -- Fallback: if damage > 0, it landed
            elseif damage > 0 then
                landed = true
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
                    local mb_str = is_magic_burst and ' (MB!)' or ''
                    log(string.format('Spell: %s - %d damage%s', spell_name, damage, mb_str))
                elseif resisted then
                    log(string.format('Spell: %s - RESISTED', spell_name))
                elseif landed then
                    log(string.format('Spell: %s - Landed', spell_name))
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
                local total_dmg = fight.total_damage or 0
                log(string.format('%d. %s - Dmg: %d | Acc: %d%% - %s',
                    i, fight.enemy_name, total_dmg, acc,
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
