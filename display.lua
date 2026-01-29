--[[
    Display Module for Stats
    Handles all display output - chat messages and on-screen overlay
]]--

local display = {}

local texts = require('texts')

-- Overlay text object
local overlay = nil
local overlay_settings = {
    pos = { x = 100, y = 100 },
    bg = { alpha = 180, red = 0, green = 0, blue = 0 },
    text = { font = 'Consolas', size = 10, alpha = 255, red = 255, green = 255, blue = 255 },
    flags = { draggable = true, bold = true },
    padding = 5
}

local settings_ref = nil

-------------------------------------------
-- Initialization
-------------------------------------------

function display.init(settings)
    settings_ref = settings

    overlay = texts.new('', overlay_settings)

    if settings.overlay_position then
        overlay:pos(settings.overlay_position.x, settings.overlay_position.y)
    end

    if settings.overlay_enabled then
        overlay:show()
    else
        overlay:hide()
    end
end

-------------------------------------------
-- Overlay Functions
-------------------------------------------

function display.update(fight)
    if not overlay then return end
    if not settings_ref or not settings_ref.overlay_enabled then
        overlay:hide()
        return
    end

    if not fight then
        overlay:text('Stats: No current fight')
        overlay:show()
        return
    end

    local lines = {}

    -- Header with total damage
    table.insert(lines, '=== ' .. fight.enemy_name .. ' ===')
    table.insert(lines, string.format('Total Damage: %d', fight.total_damage or 0))

    -- Melee accuracy
    if fight.total_swings > 0 then
        local acc = math.floor((fight.total_hits / fight.total_swings) * 100)
        local crit_rate = fight.total_hits > 0 and
            math.floor((fight.total_crits / fight.total_hits) * 100) or 0

        table.insert(lines, string.format('Melee: %d%% (%d/%d)',
            acc, fight.total_hits, fight.total_swings))

        if fight.melee_min and fight.melee_max > 0 then
            table.insert(lines, string.format('  Dmg: %d-%d | Crit: %d%%',
                fight.melee_min or 0, fight.melee_max, crit_rate))
        end
    end

    -- Ranged accuracy
    if fight.ranged_shots > 0 then
        local acc = math.floor((fight.ranged_hits / fight.ranged_shots) * 100)
        table.insert(lines, string.format('Ranged: %d%% (%d/%d)',
            acc, fight.ranged_hits, fight.ranged_shots))
    end

    -- Weapon skills (show top 3 by usage)
    local ws_list = {}
    for ws_name, ws_data in pairs(fight.weaponskills) do
        table.insert(ws_list, { name = ws_name, data = ws_data })
    end
    table.sort(ws_list, function(a, b) return a.data.uses > b.data.uses end)

    if #ws_list > 0 then
        table.insert(lines, '--- Weapon Skills ---')
        for i = 1, math.min(3, #ws_list) do
            local ws = ws_list[i]
            local avg = ws.data.hits > 0 and math.floor(ws.data.total_damage / ws.data.hits) or 0
            table.insert(lines, string.format('%s: %d-%d (x%d)',
                ws.name:sub(1, 12), ws.data.min_damage or 0, ws.data.max_damage, ws.data.uses))
        end
    end

    -- Spells (show top 3 by usage)
    local spell_list = {}
    for spell_name, spell_data in pairs(fight.spells) do
        table.insert(spell_list, { name = spell_name, data = spell_data })
    end
    table.sort(spell_list, function(a, b) return a.data.casts > b.data.casts end)

    if #spell_list > 0 then
        table.insert(lines, '--- Spells ---')
        for i = 1, math.min(3, #spell_list) do
            local spell = spell_list[i]
            local acc = math.floor((spell.data.landed / spell.data.casts) * 100)
            if spell.data.total_damage > 0 then
                table.insert(lines, string.format('%s: %d%% %d-%d',
                    spell.name:sub(1, 12), acc, spell.data.min_damage or 0, spell.data.max_damage))
            else
                table.insert(lines, string.format('%s: %d%% (%d/%d)',
                    spell.name:sub(1, 12), acc, spell.data.landed, spell.data.casts))
            end
        end
    end

    overlay:text(table.concat(lines, '\n'))
    overlay:show()
end

function display.toggle_overlay(enabled)
    if overlay then
        if enabled then
            overlay:show()
        else
            overlay:hide()
        end
    end
end

function display.hide()
    if overlay then
        overlay:hide()
    end
end

-------------------------------------------
-- Chat Display Functions
-------------------------------------------

function display.show_summary(fight)
    if not fight then
        log('No fight data available.')
        return
    end

    log('=== ' .. fight.enemy_name .. ' ===')
    log(string.format('Total Damage: %d', fight.total_damage or 0))

    -- Melee
    if fight.total_swings > 0 then
        local acc = math.floor((fight.total_hits / fight.total_swings) * 100)
        log(string.format('Melee Accuracy: %d%% (%d/%d)',
            acc, fight.total_hits, fight.total_swings))
        log(string.format('Melee Damage: %d (Min: %d / Max: %d)',
            fight.melee_damage, fight.melee_min or 0, fight.melee_max))
    end

    -- Ranged
    if fight.ranged_shots > 0 then
        local acc = math.floor((fight.ranged_hits / fight.ranged_shots) * 100)
        log(string.format('Ranged Accuracy: %d%% (%d/%d)',
            acc, fight.ranged_hits, fight.ranged_shots))
    end

    -- WS count
    local ws_count = 0
    for _ in pairs(fight.weaponskills) do ws_count = ws_count + 1 end
    if ws_count > 0 then
        log(string.format('Weapon Skills Used: %d types', ws_count))
    end

    -- Spell count
    local spell_count = 0
    for _ in pairs(fight.spells) do spell_count = spell_count + 1 end
    if spell_count > 0 then
        log(string.format('Spells Cast: %d types', spell_count))
    end
end

function display.show_detailed(fight)
    if not fight then
        log('No fight data available.')
        return
    end

    log('========== Detailed Report: ' .. fight.enemy_name .. ' ==========')

    -- Fight duration and total damage
    local duration = (fight.end_time or os.time()) - fight.start_time
    log(string.format('Duration: %d:%02d', math.floor(duration / 60), duration % 60))
    log(string.format('Total Damage: %d', fight.total_damage or 0))
    if duration > 0 then
        local dps = math.floor((fight.total_damage or 0) / duration)
        log(string.format('Average DPS: %d', dps))
    end
    if fight.result then
        log('Result: ' .. fight.result)
    end

    -- Melee stats
    log('--- Melee ---')
    if fight.total_swings > 0 then
        local acc = math.floor((fight.total_hits / fight.total_swings) * 100)
        local crit_rate = fight.total_hits > 0 and
            math.floor((fight.total_crits / fight.total_hits) * 100) or 0
        local avg = fight.total_hits > 0 and math.floor(fight.melee_damage / fight.total_hits) or 0

        log(string.format('  Accuracy: %d%% (%d hits / %d swings)',
            acc, fight.total_hits, fight.total_swings))
        log(string.format('  Crit Rate: %d%% (%d crits)',
            crit_rate, fight.total_crits))
        log(string.format('  Damage: %d total (Avg: %d)',
            fight.melee_damage, avg))
        log(string.format('  Normal: Min %d / Max %d',
            fight.melee_min or 0, fight.melee_max))
        if fight.total_crits > 0 then
            log(string.format('  Critical: Min %d / Max %d',
                fight.melee_crit_min or 0, fight.melee_crit_max))
        end
    else
        log('  No melee attacks')
    end

    -- Ranged stats
    if fight.ranged_shots > 0 then
        log('--- Ranged ---')
        local acc = math.floor((fight.ranged_hits / fight.ranged_shots) * 100)
        local crit_rate = fight.ranged_hits > 0 and
            math.floor((fight.ranged_crits / fight.ranged_hits) * 100) or 0

        log(string.format('  Accuracy: %d%% (%d hits / %d shots)',
            acc, fight.ranged_hits, fight.ranged_shots))
        log(string.format('  Crit Rate: %d%%', crit_rate))
        log(string.format('  Damage: %d total (Min: %d / Max: %d)',
            fight.ranged_damage, fight.ranged_min or 0, fight.ranged_max))
    end

    -- Weapon skill stats
    local has_ws = false
    for _ in pairs(fight.weaponskills) do has_ws = true break end

    if has_ws then
        log('--- Weapon Skills ---')
        for ws_name, ws_data in pairs(fight.weaponskills) do
            local acc = ws_data.uses > 0 and
                math.floor((ws_data.hits / ws_data.uses) * 100) or 0
            local avg = ws_data.hits > 0 and
                math.floor(ws_data.total_damage / ws_data.hits) or 0

            log(string.format('  %s:', ws_name))
            log(string.format('    Uses: %d (Hit: %d%%) | Damage: %d',
                ws_data.uses, acc, ws_data.total_damage))
            log(string.format('    Min: %d / Max: %d / Avg: %d',
                ws_data.min_damage or 0, ws_data.max_damage, avg))
        end
    end

    -- Spell stats
    local has_spells = false
    for _ in pairs(fight.spells) do has_spells = true break end

    if has_spells then
        log('--- Spells ---')
        for spell_name, spell_data in pairs(fight.spells) do
            local acc = spell_data.casts > 0 and
                math.floor((spell_data.landed / spell_data.casts) * 100) or 0

            log(string.format('  %s:', spell_name))
            log(string.format('    Casts: %d | Landed: %d (%d%%) | Resisted: %d',
                spell_data.casts, spell_data.landed, acc, spell_data.resisted))

            if spell_data.total_damage > 0 then
                local avg = spell_data.landed > 0 and
                    math.floor(spell_data.total_damage / spell_data.landed) or 0
                log(string.format('    Damage: %d (Min: %d / Max: %d / Avg: %d)',
                    spell_data.total_damage, spell_data.min_damage or 0,
                    spell_data.max_damage, avg))
            end
        end
    end

    -- Ability stats
    local has_abilities = false
    for _ in pairs(fight.abilities) do has_abilities = true break end

    if has_abilities then
        log('--- Job Abilities ---')
        for ability_name, ability_data in pairs(fight.abilities) do
            local avg = ability_data.uses > 0 and
                math.floor(ability_data.total_damage / ability_data.uses) or 0

            log(string.format('  %s: %d uses, %d total damage (Min: %d / Max: %d)',
                ability_name, ability_data.uses, ability_data.total_damage,
                ability_data.min_damage or 0, ability_data.max_damage))
        end
    end
end

function display.show_spell_stats(session, spell_name)
    local found = false

    log('=== Spell Stats: ' .. spell_name .. ' ===')

    for name, data in pairs(session.spells) do
        if name:lower():find(spell_name:lower()) then
            found = true
            local acc = data.casts > 0 and
                math.floor((data.landed / data.casts) * 100) or 0

            log(string.format('%s:', name))
            log(string.format('  Casts: %d | Landed: %d (%d%%) | Resisted: %d',
                data.casts, data.landed, acc, data.resisted))

            if data.total_damage > 0 then
                local avg = data.landed > 0 and
                    math.floor(data.total_damage / data.landed) or 0
                log(string.format('  Damage: %d total (Min: %d / Max: %d / Avg: %d)',
                    data.total_damage, data.min_damage or 0, data.max_damage, avg))
            end
        end
    end

    if not found then
        log('No data found for spell: ' .. spell_name)
    end
end

function display.show_ws_stats(session, ws_name)
    local found = false

    log('=== Weapon Skill Stats: ' .. ws_name .. ' ===')

    for name, data in pairs(session.weaponskills) do
        if name:lower():find(ws_name:lower()) then
            found = true
            local acc = data.uses > 0 and
                math.floor((data.hits / data.uses) * 100) or 0
            local avg = data.hits > 0 and
                math.floor(data.total_damage / data.hits) or 0

            log(string.format('%s:', name))
            log(string.format('  Uses: %d | Hits: %d (%d%%)',
                data.uses, data.hits, acc))
            log(string.format('  Damage: %d total', data.total_damage))
            log(string.format('  Min: %d / Max: %d / Avg: %d',
                data.min_damage or 0, data.max_damage, avg))
        end
    end

    if not found then
        log('No data found for weapon skill: ' .. ws_name)
    end
end

function display.show_session(session)
    -- Melee
    log('--- Melee ---')
    if session.melee.swings > 0 then
        local acc = math.floor((session.melee.hits / session.melee.swings) * 100)
        local crit_rate = session.melee.hits > 0 and
            math.floor((session.melee.crits / session.melee.hits) * 100) or 0

        log(string.format('  Swings: %d | Hits: %d | Accuracy: %d%%',
            session.melee.swings, session.melee.hits, acc))
        log(string.format('  Crits: %d (%d%%) | Total Damage: %d',
            session.melee.crits, crit_rate, session.melee.total_damage))
    else
        log('  No melee data')
    end

    -- Ranged
    if session.ranged.shots > 0 then
        log('--- Ranged ---')
        local acc = math.floor((session.ranged.hits / session.ranged.shots) * 100)
        log(string.format('  Shots: %d | Hits: %d | Accuracy: %d%%',
            session.ranged.shots, session.ranged.hits, acc))
        log(string.format('  Total Damage: %d', session.ranged.total_damage))
    end

    -- Weapon skills summary
    local ws_count = 0
    local ws_total_uses = 0
    local ws_total_damage = 0
    for _, data in pairs(session.weaponskills) do
        ws_count = ws_count + 1
        ws_total_uses = ws_total_uses + data.uses
        ws_total_damage = ws_total_damage + data.total_damage
    end

    if ws_count > 0 then
        log('--- Weapon Skills ---')
        log(string.format('  Types: %d | Total Uses: %d | Total Damage: %d',
            ws_count, ws_total_uses, ws_total_damage))

        -- Top 5 WS by damage
        local ws_list = {}
        for name, data in pairs(session.weaponskills) do
            table.insert(ws_list, { name = name, data = data })
        end
        table.sort(ws_list, function(a, b)
            return a.data.total_damage > b.data.total_damage
        end)

        log('  Top Weapon Skills:')
        for i = 1, math.min(5, #ws_list) do
            local ws = ws_list[i]
            log(string.format('    %s: %d damage (%d uses)',
                ws.name, ws.data.total_damage, ws.data.uses))
        end
    end

    -- Spells summary
    local spell_count = 0
    local spell_total_casts = 0
    for _, data in pairs(session.spells) do
        spell_count = spell_count + 1
        spell_total_casts = spell_total_casts + data.casts
    end

    if spell_count > 0 then
        log('--- Spells ---')
        log(string.format('  Types: %d | Total Casts: %d', spell_count, spell_total_casts))

        -- Show enfeebling spells accuracy
        local enfeebs = {}
        for name, data in pairs(session.spells) do
            if data.total_damage == 0 and data.casts >= 3 then
                local acc = math.floor((data.landed / data.casts) * 100)
                table.insert(enfeebs, { name = name, acc = acc, casts = data.casts })
            end
        end

        if #enfeebs > 0 then
            table.sort(enfeebs, function(a, b) return a.casts > b.casts end)
            log('  Enfeebling Accuracy:')
            for i = 1, math.min(5, #enfeebs) do
                log(string.format('    %s: %d%% (%d casts)',
                    enfeebs[i].name, enfeebs[i].acc, enfeebs[i].casts))
            end
        end
    end
end

return display
