local debug = false
last_results = false

last_combat = {}
last_combat_results = {}

function OnMsg.CombatStarting()
    last_combat = {}
    last_combat_results = {}
end

function OnMsg.CombatEnd()
    print(last_combat)
    print("RATDEV last_combat table ready")
end

function OnMsg.OnAttack(unit, action, target, results, attack_args)
    last_results = results

    local insert_results = table.copy(results)
    local target_pos = target and target:GetPos()
    if target then
        target_pos = IsValidZ(target_pos) and target_pos or target_pos:SetTerrainZ()
    end

    local att_pos = results.attack_pos
    local dist = target_pos and att_pos:Dist(target_pos)
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
        print("------------------------------")
    end
end

