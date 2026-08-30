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

    -- CtH de cada tiro em ataques multishot
    do
        local function collect_shot_cth(shots)
            local t = {}
            for i, shot in ipairs(shots or empty_table) do
                t[i] = tostring(shot.cth or shot.chance_to_hit or "?")
            end
            return t
        end
        local per_shot
		local t 
        if results.attacks then -- multi-weapon (DualShot)
            local parts = {}
            for ai, attack in ipairs(results.attacks) do
                t = collect_shot_cth(attack.shots)
                if #t > 0 then
                    parts[#parts + 1] = "w" .. ai .. ": " .. table.concat(t, " | ")
                end
            end
            per_shot = #parts > 0 and table.concat(parts, "   ") or nil
        else
            t = collect_shot_cth(results.shots)
            per_shot = #t > 0 and table.concat(t, " | ") or nil
        end

        if per_shot then
            info['Chance to Hit per shot'] = per_shot
            info['Chance to Hit per shot loss'] = results.GBO_debug_cth_loss_per_shot--attack_args and attack_args.cth_loss_per_shot
			info['Chance to Hit recoil cone ratio mul'] = results.GBO_debug_recoil_cone_ratios
		end
    end

    for i, mod in ipairs(results.chance_to_hit_modifiers) do
        local id = mod.id or "Stat"
        if id == "HipshotPenalty" then
            id = mod.name[2] -- "SnapshotPenalty"
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

