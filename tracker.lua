--[[
    Tracker Module for Stats
    Handles all combat statistics tracking and data structures
]]--

local tracker = {}

-------------------------------------------
-- Data Structure Creators
-------------------------------------------

-- Create a new fight statistics object
function tracker.create_fight_stats(enemy_name, enemy_id)
    return {
        enemy_name = enemy_name,
        enemy_id = enemy_id,
        start_time = os.time(),
        end_time = nil,
        result = nil,  -- 'Victory', 'Defeat', 'Zoned', etc.

        -- Melee stats
        total_swings = 0,
        total_hits = 0,
        total_misses = 0,
        total_crits = 0,
        melee_damage = 0,
        melee_min = nil,
        melee_max = 0,
        melee_crit_damage = 0,
        melee_crit_min = nil,
        melee_crit_max = 0,

        -- Ranged stats
        ranged_shots = 0,
        ranged_hits = 0,
        ranged_misses = 0,
        ranged_crits = 0,
        ranged_damage = 0,
        ranged_min = nil,
        ranged_max = 0,

        -- Weapon skill stats
        weaponskills = {},  -- [ws_name] = { uses, hits, misses, total_damage, min, max }

        -- Spell stats
        spells = {},  -- [spell_name] = { casts, landed, resisted, total_damage, min, max }

        -- Job ability stats
        abilities = {},  -- [ability_name] = { uses, total_damage, min, max }

        -- DPS tracking
        damage_samples = {},  -- For calculating DPS over time
    }
end

-- Create session-wide statistics
function tracker.create_session_stats()
    return {
        melee = {
            swings = 0,
            hits = 0,
            misses = 0,
            crits = 0,
            total_damage = 0,
            crit_damage = 0
        },
        ranged = {
            shots = 0,
            hits = 0,
            misses = 0,
            crits = 0,
            total_damage = 0
        },
        weaponskills = {},  -- [ws_name] = { uses, hits, misses, total_damage, min, max, avg }
        spells = {},        -- [spell_name] = { casts, landed, resisted, total_damage, min, max }
        abilities = {},     -- [ability_name] = { uses, total_damage, min, max }
        enemies = {}        -- [enemy_name] = { fights, total_damage, ... }
    }
end

-------------------------------------------
-- Recording Functions
-------------------------------------------

function tracker.record_melee(fight, session, data)
    if not fight then return end

    fight.total_swings = fight.total_swings + 1
    session.melee.swings = session.melee.swings + 1

    if data.hit then
        fight.total_hits = fight.total_hits + 1
        fight.melee_damage = fight.melee_damage + data.damage
        session.melee.hits = session.melee.hits + 1
        session.melee.total_damage = session.melee.total_damage + data.damage

        -- Track min/max (only for hits with damage)
        if data.damage > 0 then
            if data.critical then
                fight.total_crits = fight.total_crits + 1
                fight.melee_crit_damage = fight.melee_crit_damage + data.damage
                session.melee.crits = session.melee.crits + 1
                session.melee.crit_damage = session.melee.crit_damage + data.damage

                if not fight.melee_crit_min or data.damage < fight.melee_crit_min then
                    fight.melee_crit_min = data.damage
                end
                if data.damage > fight.melee_crit_max then
                    fight.melee_crit_max = data.damage
                end
            else
                -- Non-crit tracking
                if not fight.melee_min or data.damage < fight.melee_min then
                    fight.melee_min = data.damage
                end
                if data.damage > fight.melee_max then
                    fight.melee_max = data.damage
                end
            end
        end

        -- DPS sample
        table.insert(fight.damage_samples, {
            time = os.clock(),
            damage = data.damage,
            type = 'melee'
        })
    else
        fight.total_misses = fight.total_misses + 1
        session.melee.misses = session.melee.misses + 1
    end
end

function tracker.record_ranged(fight, session, data)
    if not fight then return end

    fight.ranged_shots = fight.ranged_shots + 1
    session.ranged.shots = session.ranged.shots + 1

    if data.hit then
        fight.ranged_hits = fight.ranged_hits + 1
        fight.ranged_damage = fight.ranged_damage + data.damage
        session.ranged.hits = session.ranged.hits + 1
        session.ranged.total_damage = session.ranged.total_damage + data.damage

        if data.critical then
            fight.ranged_crits = fight.ranged_crits + 1
            session.ranged.crits = session.ranged.crits + 1
        end

        if data.damage > 0 then
            if not fight.ranged_min or data.damage < fight.ranged_min then
                fight.ranged_min = data.damage
            end
            if data.damage > fight.ranged_max then
                fight.ranged_max = data.damage
            end
        end

        table.insert(fight.damage_samples, {
            time = os.clock(),
            damage = data.damage,
            type = 'ranged'
        })
    else
        fight.ranged_misses = fight.ranged_misses + 1
        session.ranged.misses = session.ranged.misses + 1
    end
end

function tracker.record_weaponskill(fight, session, data)
    if not fight then return end

    local ws_name = data.name

    -- Initialize fight WS tracking
    if not fight.weaponskills[ws_name] then
        fight.weaponskills[ws_name] = {
            uses = 0,
            hits = 0,
            misses = 0,
            total_damage = 0,
            min_damage = nil,
            max_damage = 0
        }
    end

    -- Initialize session WS tracking
    if not session.weaponskills[ws_name] then
        session.weaponskills[ws_name] = {
            uses = 0,
            hits = 0,
            misses = 0,
            total_damage = 0,
            min_damage = nil,
            max_damage = 0
        }
    end

    local fight_ws = fight.weaponskills[ws_name]
    local session_ws = session.weaponskills[ws_name]

    fight_ws.uses = fight_ws.uses + 1
    session_ws.uses = session_ws.uses + 1

    if data.hit then
        fight_ws.hits = fight_ws.hits + 1
        fight_ws.total_damage = fight_ws.total_damage + data.damage
        session_ws.hits = session_ws.hits + 1
        session_ws.total_damage = session_ws.total_damage + data.damage

        if data.damage > 0 then
            if not fight_ws.min_damage or data.damage < fight_ws.min_damage then
                fight_ws.min_damage = data.damage
            end
            if data.damage > fight_ws.max_damage then
                fight_ws.max_damage = data.damage
            end

            if not session_ws.min_damage or data.damage < session_ws.min_damage then
                session_ws.min_damage = data.damage
            end
            if data.damage > session_ws.max_damage then
                session_ws.max_damage = data.damage
            end
        end

        table.insert(fight.damage_samples, {
            time = os.clock(),
            damage = data.damage,
            type = 'ws',
            name = ws_name
        })
    else
        fight_ws.misses = fight_ws.misses + 1
        session_ws.misses = session_ws.misses + 1
    end
end

function tracker.record_spell(fight, session, data)
    if not fight then return end

    local spell_name = data.name

    -- Initialize fight spell tracking
    if not fight.spells[spell_name] then
        fight.spells[spell_name] = {
            casts = 0,
            landed = 0,
            resisted = 0,
            total_damage = 0,
            min_damage = nil,
            max_damage = 0
        }
    end

    -- Initialize session spell tracking
    if not session.spells[spell_name] then
        session.spells[spell_name] = {
            casts = 0,
            landed = 0,
            resisted = 0,
            total_damage = 0,
            min_damage = nil,
            max_damage = 0,
            type = data.type
        }
    end

    local fight_spell = fight.spells[spell_name]
    local session_spell = session.spells[spell_name]

    fight_spell.casts = fight_spell.casts + 1
    session_spell.casts = session_spell.casts + 1

    if data.landed then
        fight_spell.landed = fight_spell.landed + 1
        session_spell.landed = session_spell.landed + 1
    end

    if data.resisted then
        fight_spell.resisted = fight_spell.resisted + 1
        session_spell.resisted = session_spell.resisted + 1
    end

    if data.damage > 0 then
        fight_spell.total_damage = fight_spell.total_damage + data.damage
        session_spell.total_damage = session_spell.total_damage + data.damage

        if not fight_spell.min_damage or data.damage < fight_spell.min_damage then
            fight_spell.min_damage = data.damage
        end
        if data.damage > fight_spell.max_damage then
            fight_spell.max_damage = data.damage
        end

        if not session_spell.min_damage or data.damage < session_spell.min_damage then
            session_spell.min_damage = data.damage
        end
        if data.damage > session_spell.max_damage then
            session_spell.max_damage = data.damage
        end

        table.insert(fight.damage_samples, {
            time = os.clock(),
            damage = data.damage,
            type = 'spell',
            name = spell_name
        })
    end
end

function tracker.record_ability(fight, session, data)
    if not fight then return end

    local ability_name = data.name

    -- Initialize fight ability tracking
    if not fight.abilities[ability_name] then
        fight.abilities[ability_name] = {
            uses = 0,
            total_damage = 0,
            min_damage = nil,
            max_damage = 0
        }
    end

    -- Initialize session ability tracking
    if not session.abilities[ability_name] then
        session.abilities[ability_name] = {
            uses = 0,
            total_damage = 0,
            min_damage = nil,
            max_damage = 0
        }
    end

    local fight_ability = fight.abilities[ability_name]
    local session_ability = session.abilities[ability_name]

    fight_ability.uses = fight_ability.uses + 1
    fight_ability.total_damage = fight_ability.total_damage + data.damage
    session_ability.uses = session_ability.uses + 1
    session_ability.total_damage = session_ability.total_damage + data.damage

    if data.damage > 0 then
        if not fight_ability.min_damage or data.damage < fight_ability.min_damage then
            fight_ability.min_damage = data.damage
        end
        if data.damage > fight_ability.max_damage then
            fight_ability.max_damage = data.damage
        end

        if not session_ability.min_damage or data.damage < session_ability.min_damage then
            session_ability.min_damage = data.damage
        end
        if data.damage > session_ability.max_damage then
            session_ability.max_damage = data.damage
        end

        table.insert(fight.damage_samples, {
            time = os.clock(),
            damage = data.damage,
            type = 'ability',
            name = ability_name
        })
    end
end

-------------------------------------------
-- Utility Functions
-------------------------------------------

-- Combine two fight stats into the destination
function tracker.combine_stats(dest, source)
    dest.total_swings = dest.total_swings + source.total_swings
    dest.total_hits = dest.total_hits + source.total_hits
    dest.total_misses = dest.total_misses + source.total_misses
    dest.total_crits = dest.total_crits + source.total_crits
    dest.melee_damage = dest.melee_damage + source.melee_damage
    dest.melee_crit_damage = dest.melee_crit_damage + source.melee_crit_damage

    -- Min/max
    if source.melee_min then
        if not dest.melee_min or source.melee_min < dest.melee_min then
            dest.melee_min = source.melee_min
        end
    end
    if source.melee_max > dest.melee_max then
        dest.melee_max = source.melee_max
    end

    -- Ranged
    dest.ranged_shots = dest.ranged_shots + source.ranged_shots
    dest.ranged_hits = dest.ranged_hits + source.ranged_hits
    dest.ranged_misses = dest.ranged_misses + source.ranged_misses
    dest.ranged_crits = dest.ranged_crits + source.ranged_crits
    dest.ranged_damage = dest.ranged_damage + source.ranged_damage

    -- Weapon skills
    for ws_name, ws_data in pairs(source.weaponskills) do
        if not dest.weaponskills[ws_name] then
            dest.weaponskills[ws_name] = {
                uses = 0, hits = 0, misses = 0,
                total_damage = 0, min_damage = nil, max_damage = 0
            }
        end
        local dest_ws = dest.weaponskills[ws_name]
        dest_ws.uses = dest_ws.uses + ws_data.uses
        dest_ws.hits = dest_ws.hits + ws_data.hits
        dest_ws.misses = dest_ws.misses + ws_data.misses
        dest_ws.total_damage = dest_ws.total_damage + ws_data.total_damage

        if ws_data.min_damage then
            if not dest_ws.min_damage or ws_data.min_damage < dest_ws.min_damage then
                dest_ws.min_damage = ws_data.min_damage
            end
        end
        if ws_data.max_damage > dest_ws.max_damage then
            dest_ws.max_damage = ws_data.max_damage
        end
    end

    -- Spells
    for spell_name, spell_data in pairs(source.spells) do
        if not dest.spells[spell_name] then
            dest.spells[spell_name] = {
                casts = 0, landed = 0, resisted = 0,
                total_damage = 0, min_damage = nil, max_damage = 0
            }
        end
        local dest_spell = dest.spells[spell_name]
        dest_spell.casts = dest_spell.casts + spell_data.casts
        dest_spell.landed = dest_spell.landed + spell_data.landed
        dest_spell.resisted = dest_spell.resisted + spell_data.resisted
        dest_spell.total_damage = dest_spell.total_damage + spell_data.total_damage

        if spell_data.min_damage then
            if not dest_spell.min_damage or spell_data.min_damage < dest_spell.min_damage then
                dest_spell.min_damage = spell_data.min_damage
            end
        end
        if spell_data.max_damage > dest_spell.max_damage then
            dest_spell.max_damage = spell_data.max_damage
        end
    end

    -- Abilities
    for ability_name, ability_data in pairs(source.abilities) do
        if not dest.abilities[ability_name] then
            dest.abilities[ability_name] = {
                uses = 0, total_damage = 0, min_damage = nil, max_damage = 0
            }
        end
        local dest_ability = dest.abilities[ability_name]
        dest_ability.uses = dest_ability.uses + ability_data.uses
        dest_ability.total_damage = dest_ability.total_damage + ability_data.total_damage

        if ability_data.min_damage then
            if not dest_ability.min_damage or ability_data.min_damage < dest_ability.min_damage then
                dest_ability.min_damage = ability_data.min_damage
            end
        end
        if ability_data.max_damage > dest_ability.max_damage then
            dest_ability.max_damage = ability_data.max_damage
        end
    end
end

-- Calculate DPS from damage samples
function tracker.calculate_dps(fight, window_seconds)
    if not fight or #fight.damage_samples == 0 then
        return 0
    end

    window_seconds = window_seconds or 60
    local now = os.clock()
    local cutoff = now - window_seconds
    local total_damage = 0
    local first_sample_time = nil
    local last_sample_time = nil

    for _, sample in ipairs(fight.damage_samples) do
        if sample.time >= cutoff then
            total_damage = total_damage + sample.damage
            if not first_sample_time or sample.time < first_sample_time then
                first_sample_time = sample.time
            end
            if not last_sample_time or sample.time > last_sample_time then
                last_sample_time = sample.time
            end
        end
    end

    if first_sample_time and last_sample_time and last_sample_time > first_sample_time then
        local duration = last_sample_time - first_sample_time
        return math.floor(total_damage / duration)
    elseif total_damage > 0 then
        return total_damage  -- Only one sample
    end

    return 0
end

-- Get total damage for a fight
function tracker.get_total_damage(fight)
    if not fight then return 0 end

    local total = fight.melee_damage + fight.ranged_damage

    for _, ws_data in pairs(fight.weaponskills) do
        total = total + ws_data.total_damage
    end

    for _, spell_data in pairs(fight.spells) do
        total = total + spell_data.total_damage
    end

    for _, ability_data in pairs(fight.abilities) do
        total = total + ability_data.total_damage
    end

    return total
end

return tracker
