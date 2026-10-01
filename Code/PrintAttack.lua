local debug = true
last_results = false

last_combat = {}
last_combat_results = {}

function OnMsg.CombatStarting()
    last_combat = {}
    last_combat_results = {}
end

function OnMsg.CombatEnd()
    print(last_combat)
    print("RATO DEV -- last_combat table ready")
    print("RATO DEV -- last_combat_results table ready")
end

function OnMsg.OnAttack(unit, action, target, results, attack_args)
    last_results = results

    local weapon = attack_args and attack_args.weapon
    if weapon then
        if not IsKindOf(weapon, "Firearm") and not IsKindOf(weapon, "MeleeWeapon") then
            return
        end
    end
    local insert_results = table.copy(results)
    local target_pos = target and target:GetPos()
    if target then
        target_pos = IsValidZ(target_pos) and target_pos or target_pos:SetTerrainZ()
    end

    local att_pos = results.attack_pos
    local dist = target_pos and att_pos:Dist(target_pos)
    if not dist then
        return
    end
    dist = dist / const.SlabSizeX
    insert_results.distance = dist
    insert_results.target_id = target.sesion_id
    insert_results.time = GameTime()

    if not last_combat_results[unit.session_id] then
        last_combat_results[unit.session_id] = {insert_results}
    else
        table.insert(last_combat_results[unit.session_id], insert_results)
    end

    if not last_combat[unit.session_id] then
        last_combat[unit.session_id] = {
            {['aim'] = insert_results.aim, ["dist"] = dist, ["wep"] = insert_results.weapon}
        }
    else
        table.insert(last_combat[unit.session_id], {
            ['aim'] = insert_results.aim,
            ["dist"] = dist,
            ["wep"] = insert_results.weapon
        })
    end

    local info = {
        ['Attacker'] = unit.session_id,
        ['Target'] = target.session_id,
        ["Distance"] = dist,
        ['Weapon'] = results.weapon.class,
        ['AP'] = unit.ActionPoints,
        ["Aim Level"] = results.aim,
        ['Action ID'] = action.id,
        ['Chance to Hit'] = results.chance_to_hit,
        ['Critical Chance'] = results.crit_chance
    }

    -- shot lists: one per weapon (DualShot has several); melee has no shots, the results are the single "shot"
    local shot_lists
    if results.attacks then
        shot_lists = {}
        for ai, attack in ipairs(results.attacks) do
            shot_lists[ai] = attack.shots or empty_table
        end
    elseif results.shots then
        shot_lists = {results.shots}
    elseif results.hits then
        shot_lists = {{results}}
    else
        shot_lists = {}
    end

    -- "a | b | c", or "w1: a | b   w2: c" for multi-weapon attacks
    local function per_shot(fn)
        local parts = {}
        for ai, shots in ipairs(shot_lists) do
            local t = {}
            for i, shot in ipairs(shots) do
                t[i] = fn(shot)
            end
            if #t > 0 then
                local s = table.concat(t, " | ")
                parts[#parts + 1] = #shot_lists > 1 and ("w" .. ai .. ": " .. s) or s
            end
        end
        return #parts > 0 and table.concat(parts, "   ") or nil
    end

    local function target_hit(shot)
        if shot.miss then
            return
        end
        for _, hit in ipairs(shot.hits or empty_table) do
            if hit.obj == target then
                return hit
            end
        end
    end

    -- hit.effects may be an array of ids or a set keyed by id
    local function effect_ids(effects, into)
        into = into or {}
        if type(effects) == "string" then
            if effects ~= "" then
                table.insert_unique(into, effects)
            end
        elseif type(effects) == "table" then
            for k, v in pairs(effects) do
                local id = type(k) == "number" and v or k
                if type(id) == "string" and id ~= "" then
                    table.insert_unique(into, id)
                end
            end
        end
        return into
    end

    -- CtH de cada tiro em ataques multishot
    local cth_per_shot = per_shot(function(shot)
        return tostring(shot.cth or shot.chance_to_hit or "?")
    end)
    if cth_per_shot and (results.shots or results.attacks) then
        info['Chance to Hit per shot'] = cth_per_shot
        info['Chance to Hit per shot loss'] = results.GBO_debug_cth_loss_per_shot--attack_args and attack_args.cth_loss_per_shot
        info['Chance to Hit recoil cone ratio mul'] = results.GBO_debug_recoil_cone_ratios
    end

    -- aCTH fires a real trajectory: the part hit is not the part aimed at. off-part = soft stray
    local part_per_shot = per_shot(function(shot)
        if shot.miss then
            return "miss"
        end
        local hit = target_hit(shot)
        return (hit and hit.spot_group or "?") .. (hit and hit.rat_offpart and " (off-part)" or "")
    end)
    if part_per_shot then
        info['Aimed part'] = attack_args and attack_args.target_spot_group or "Torso (default)"
        info['Hit part per shot'] = part_per_shot
    end

    -- outcome on the target: damage, crit/graze and status of each shot
    local shots_total, hits_on_target, dmg_on_target, crits = 0, 0, 0, 0
    local statuses = {}
    local dmg_per_shot = per_shot(function(shot)
        shots_total = shots_total + 1
        local hit = target_hit(shot)
        if not hit then
            return shot.miss and "miss" or "no target hit"
        end
        hits_on_target = hits_on_target + 1
        dmg_on_target = dmg_on_target + (hit.damage or 0)
        local s = tostring(hit.damage or "?")
        if hit.critical then
            crits = crits + 1
            s = s .. " crit"
        end
        if hit.grazing then
            s = s .. " graze" .. (hit.grazing_reason and ("(" .. tostring(hit.grazing_reason) .. ")") or "")
        end
        if (hit.armor_prevented or 0) > 0 then
            s = s .. " armor-" .. hit.armor_prevented
        end
        local fx = effect_ids(hit.effects)
        if #fx > 0 then
            s = s .. " [" .. table.concat(fx, ",") .. "]"
            effect_ids(fx, statuses)
        end
        return s
    end)
    -- statuses that don't ride on a hit (Suppressed, DualShot extras...)
    for _, packet in ipairs(results.extra_packets or empty_table) do
        if packet.target == target then
            effect_ids(packet.effects, statuses)
        end
    end

    if dmg_per_shot then
        info['Damage per shot'] = dmg_per_shot
    end
    info['Hits on target'] = hits_on_target .. " / " .. shots_total .. (crits > 0 and (" (" .. crits .. " crit)") or "")
    info['Damage to target'] = dmg_on_target
    info['Damage total (all objs)'] = results.total_damage
    info['Status inflicted'] = #statuses > 0 and table.concat(statuses, ", ") or "none"
    local killed = {}
    for _, u in ipairs(results.killed_units or empty_table) do
        killed[#killed + 1] = tostring(u.session_id or u.class)
    end
    if #killed > 0 then
        info['Killed'] = table.concat(killed, ", ")
    end

    for i, mod in ipairs(results.chance_to_hit_modifiers) do
        local id = mod.id or "Stat"
        if id == "HipshotPenalty" then
            id = mod.name and mod.name[2] or id .. "error_no_modname"-- "SnapshotPenalty"
        end

        info['CTH_' .. id] = mod.value
    end

    -- Sort keys to ensure _Attacker is first and CTH_mod_* is last
    local sorted_keys = {}
    for k in pairs(info) do
        table.insert(sorted_keys, k)
    end

    table.sort(sorted_keys, function(a, b)
        if a == 'Attacker' then
            return true
        end
        if b == 'Attacker' then
            return false
        end
        if a:find("^CTH_") and not b:find("^CTH_") then
            return false
        end
        if b:find("^CTH_") and not a:find("^CTH_") then
            return true
        end
        return a < b
    end)

    if debug then
        -- Print the sorted info
        print("------------------------------ Attack (RatoDev)")
        for _, k in ipairs(sorted_keys) do
            print("--", k, " = ", info[k])
        end
        print("------------------------------ last_results table can be inspected")
    end
end

