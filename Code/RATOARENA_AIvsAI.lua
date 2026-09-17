---------------------------------------------------------------------------------------------------
-- Rato Dev -- AI vs AI arena
--
-- RatoArena_Start hands every UI team to the AI for the current combat. Sides are untouched,
-- so Combat:ShouldEndCombat (needs a live player1/player2 team) still ends the match normally.
-- Each side may run its own archetype weights ("genome"): a flat {path = number} table per
-- archetype, applied through proxies so the shared presets are never written.
--
-- Driven from Rato's AI Overhaul: python tools/arena.py (DAP). Results also go to the game log
-- as [RATOARENA_RESULT] lines.
---------------------------------------------------------------------------------------------------

RATOARENA = {
    active = false,
    match = false,
    genomes = {}, ---- [side] = {[archetype_id] = {[path] = value}}
    variants = {}, ---- [side] = {[archetype_id] = archetype or proxy}
    applied = {}, ---- [side] = {[archetype_id] = {[path] = true}}
    results = {},
    out = {}, ---- [key] = string, paged out by RatoArena_Read (DAP caps a result at ~512 chars)
}

---- identity-compared against Archetypes.EmplacementGunner in CombatCamera.lua
local NEVER_PROXY = { EmplacementGunner = true }

---------------------------------------------------------------------------------------------------
-- output paging
---------------------------------------------------------------------------------------------------

function RatoArena_Put(key, str)
    RATOARENA.out[key] = str
    return #str
end

function RatoArena_Read(key, offset, len)
    local s = RATOARENA.out[key]
    return s and s:sub(offset + 1, offset + len) or ""
end

local function PutJSON(key, value)
    local err, json = LuaToJSON(value)
    if err or not json then
        return -1
    end
    return RatoArena_Put(key, tostring(json))
end

---------------------------------------------------------------------------------------------------
-- genome paths: "<list>/<key>#<n>/.../<prop>", e.g. Behaviors/StandardAI#1/EndTurnPolicies/AIPolicyDealDamage#2/Weight
---------------------------------------------------------------------------------------------------

local function ChildKey(obj, counts)
    local name = obj.class
    local bias = obj.BiasId
    if IsKindOf(obj, "AIBehavior") and type(bias) == "string" and bias ~= "" then
        name = bias
    end
    counts[name] = (counts[name] or 0) + 1
    return name .. "#" .. counts[name]
end

local function WalkSpace(obj, path, out, depth)
    for _, prop in ipairs(obj:GetProperties()) do
        local id, v = prop.id, obj[prop.id]
        if prop.editor == "number" and type(v) == "number" and not prop.read_only then
            out[#out + 1] = {
                p = path .. id,
                v = v,
                min = type(prop.min) == "number" and prop.min or nil,
                max = type(prop.max) == "number" and prop.max or nil,
            }
        elseif prop.editor == "nested_list" and type(v) == "table" and depth < 4 then
            local counts = {}
            for _, child in ipairs(v) do
                WalkSpace(child, path .. id .. "/" .. ChildKey(child, counts) .. "/", out, depth + 1)
            end
        end
    end
end

---- Returns the length of the JSON written to out["space:<id>"].
function RatoArena_Space(archetype_id)
    local arch = Archetypes[archetype_id]
    if not arch then
        return -1
    end
    local out = {}
    WalkSpace(arch, "", out, 0)
    return PutJSON("space:" .. archetype_id, out)
end

---- Returns obj itself when no gene lives under path, so unmutated subtrees stay shared.
local function BuildVariant(obj, path, genes, touched, depth)
    local proxy
    for _, prop in ipairs(obj:GetProperties()) do
        local id = prop.id
        if prop.editor == "number" then
            local v = genes[path .. id]
            if v ~= nil then
                proxy = proxy or setmetatable({}, { __index = obj })
                proxy[id] = v
                touched[path .. id] = true
            end
        elseif prop.editor == "nested_list" and type(obj[id]) == "table" and depth < 4 then
            local new, counts, changed = {}, {}, false
            for i, child in ipairs(obj[id]) do
                local c = BuildVariant(child, path .. id .. "/" .. ChildKey(child, counts) .. "/", genes, touched, depth + 1)
                new[i] = c
                changed = changed or c ~= child
            end
            if changed then
                proxy = proxy or setmetatable({}, { __index = obj })
                proxy[id] = new
            end
        end
    end
    return proxy or obj
end

---- genome = {[archetype_id] = {[path] = number}}; false clears the side. Returns unknown paths joined by ";".
function RatoArena_SetGenome(side, genome)
    RATOARENA.genomes[side] = genome or nil
    RATOARENA.variants[side] = nil
    RATOARENA.applied[side] = {}
    local unknown = {}
    for arch_id, genes in sorted_pairs(genome or empty_table) do
        local arch = Archetypes[arch_id]
        if not arch or NEVER_PROXY[arch_id] then
            unknown[#unknown + 1] = arch_id
        else
            local touched = {}
            BuildVariant(arch, "", genes, touched, 0)
            RATOARENA.applied[side][arch_id] = touched
            for path in sorted_pairs(genes) do
                if not touched[path] then
                    unknown[#unknown + 1] = arch_id .. ":" .. path
                end
            end
        end
    end
    return table.concat(unknown, ";")
end

local function Variant(unit, arch)
    if not RATOARENA.active or not arch then
        return arch
    end
    local side = unit.team and unit.team.side
    local genome = side and RATOARENA.genomes[side]
    local genes = genome and genome[arch.id]
    if not genes or NEVER_PROXY[arch.id] then
        return arch
    end
    local cache = RATOARENA.variants[side]
    if not cache then
        cache = {}
        RATOARENA.variants[side] = cache
    end
    local v = cache[arch.id]
    if not v then
        v = BuildVariant(arch, "", genes, {}, 0)
        cache[arch.id] = v
    end
    return v
end

local GetArchetype_orig = Unit.GetArchetype
function Unit:GetArchetype()
    return Variant(self, GetArchetype_orig(self))
end

local GetCurrentArchetype_orig = Unit.GetCurrentArchetype
function Unit:GetCurrentArchetype()
    return Variant(self, GetCurrentArchetype_orig(self))
end

---------------------------------------------------------------------------------------------------
-- turn flow
---------------------------------------------------------------------------------------------------

---- Side-based in vanilla: without this an AI-controlled player1 team takes the human branch and never gets AITurn.
local IsNetPlayerTurn_orig = IsNetPlayerTurn
function IsNetPlayerTurn(id)
    if RATOARENA.active then
        local team = g_Teams and g_Teams[g_CurrentTeam]
        if team and team.control == "AI" then
            return false
        end
    end
    return IsNetPlayerTurn_orig(id)
end

local function SideStats(m, side)
    local s = m.sides[side]
    if not s then
        s = { dealt = 0, friendly = 0, kills = 0, attacks = 0 }
        m.sides[side] = s
    end
    return s
end

---- opts: label, max_turns (default 15), time_factor
function RatoArena_Start(opts)
    opts = opts or {}
    if not g_Combat then
        return "no combat"
    end
    if RATOARENA.active then
        return "already active"
    end
    local m = {
        label = opts.label or "",
        max_turns = opts.max_turns or 15,
        start_turn = g_Combat.current_turn,
        start_time = GameTime(),
        start_ticks = GetPreciseTicks(),
        sides = {},
        units = {},
        controls = {},
    }
    for _, team in ipairs(g_Teams) do
        if team.side ~= "neutral" then
            for _, u in ipairs(team.units) do
                if not u:IsDead() then
                    SideStats(m, team.side)
                    m.units[#m.units + 1] = { unit = u, side = team.side, hp0 = u.HitPoints, dealt = 0, kills = 0 }
                end
            end
        end
    end

    local current = g_Teams[g_CurrentTeam]
    for _, team in ipairs(g_Teams) do
        if team.control == "UI" then
            m.controls[team] = team.control
            team.control = "AI"
        end
    end
    if opts.time_factor then
        m.time_factor_prev = GetTimeFactor()
        SetTimeFactor(opts.time_factor)
    end

    RATOARENA.variants = {}
    RATOARENA.match = m
    RATOARENA.active = true
    ---- The main loop is already parked in WaitEndTurn for the human turn: play it as AI, then end it
    ---- by hand (NetSyncEvents.EndTurn ignores a non-UI team). Ending it directly would cost that side a turn.
    if current and m.controls[current] then
        CreateGameTimeThread(function()
            g_Combat:AITurn(current)
            if g_Combat then
                g_Combat.player_end_turn[netUniqueId] = true
                g_Combat:CheckEndTurn()
            end
        end)
    end
    return "ok"
end

local function UnitRow(m, unit)
    for _, row in ipairs(m.units) do
        if row.unit == unit then
            return row
        end
    end
end

local function Finish(reason)
    local m = RATOARENA.match
    if not m or m.finished then
        return
    end
    m.finished = true
    RATOARENA.active = false
    for team, control in pairs(m.controls) do
        team.control = control
    end
    if m.time_factor_prev then
        SetTimeFactor(m.time_factor_prev)
    end

    local standing = {}
    local units = {}
    for _, row in ipairs(m.units) do
        local u, s = row.unit, m.sides[row.side]
        local hp = u:IsDead() and 0 or u.HitPoints
        s.units = (s.units or 0) + 1
        s.hp0 = (s.hp0 or 0) + row.hp0
        s.hp = (s.hp or 0) + hp
        if u:IsDead() then
            s.dead = (s.dead or 0) + 1
        elseif u:IsIncapacitated() then
            s.down = (s.down or 0) + 1
        else
            s.alive = (s.alive or 0) + 1
            standing[row.side] = true
        end
        units[#units + 1] = {
            id = u.session_id,
            side = row.side,
            arch = GetArchetype_orig(u).id,
            hp0 = row.hp0,
            hp = hp,
            dealt = row.dealt,
            kills = row.kills,
        }
    end
    local winner = "draw"
    local standing_sides = table.keys(standing, true)
    if #standing_sides == 1 then
        winner = standing_sides[1]
    end

    local genomes = {}
    for side, archs in pairs(RATOARENA.applied) do
        local n = 0
        for _, touched in pairs(archs) do
            n = n + table.count(touched)
        end
        genomes[side] = n
    end

    local rec = {
        label = m.label,
        reason = reason,
        winner = winner,
        turns = (g_Combat and g_Combat.current_turn or m.last_turn or m.start_turn) - m.start_turn + 1,
        game_ms = GameTime() - m.start_time,
        real_ms = GetPreciseTicks() - m.start_ticks,
        sector = gv_CurrentSectorId,
        sides = m.sides,
        units = units,
        genes = genomes,
    }
    m.result = rec
    RATOARENA.results[#RATOARENA.results + 1] = rec
    local err, json = LuaToJSON(rec)
    if not err and json then
        local line = tostring(json)
        RatoArena_Put("last_result", line)
        DebugPrint("[RATOARENA_RESULT] " .. line .. "\n")
    end
end

---- Ends the match now (e.g. driver timeout); control goes back to the player.
function RatoArena_Stop(reason)
    Finish(reason or "stopped")
    return "ok"
end

---- Short poll string for the driver: "idle", "running turn=N team=SIDE" or "done <reason> <winner> <json length>".
function RatoArena_Status()
    local m = RATOARENA.match
    if not m then
        return "idle"
    end
    if m.result then
        return string.format("done %s %s %d", m.result.reason, m.result.winner, #(RATOARENA.out.last_result or ""))
    end
    local team = g_Teams and g_Teams[g_CurrentTeam]
    return string.format("running turn=%s team=%s", tostring(g_Combat and g_Combat.current_turn), tostring(team and team.side))
end

---- Async; poll RATOARENA.load_state: "loading" -> "ok" or the error string.
function RatoArena_Load(savename)
    RATOARENA.load_state = "loading"
    CreateRealTimeThread(function()
        local err = LoadGame(savename)
        ---- the sector loading screen waits for a "Start" click and keeps the game paused until then
        local deadline = RealTime() + 30000
        while not err and RealTime() < deadline do
            local dlg = GetDialog("XZuluLoadingScreen")
            if dlg and (dlg:GetContext() or empty_table).loaded then
                LoadingScreenClose("idLoadedLoadingScreen", "loaded")
                break
            end
            Sleep(250)
        end
        RATOARENA.load_state = err and tostring(err) or "ok"
    end)
    return "loading"
end

---- RATOARENA is a plain global and survives the load; a match left running would never finish.
function OnMsg.PreLoadGame()
    if RATOARENA.active then
        Finish("aborted_by_load")
    end
end

---------------------------------------------------------------------------------------------------
-- composition: give a side one unit of every archetype
--
-- An arena whose enemies are all Soldier only exercises one archetype's weights. These spawn real
-- unit types of the faction already on the map, so gear and stats match the archetype instead of
-- being relabelled. Compose once, then SAVE: every match reloads the save.
---------------------------------------------------------------------------------------------------

---- archetypes that are not infantry, or belong to scripted fights -- never spawned for variety
local NOT_INFANTRY = {
    Turret = true, TurretBoss = true, Artillery = true, EmplacementGunner = true,
    TutorialMinion = true, ActiveCivilian = true, CorazonBoss = true, TheMajor = true,
}

local function IsSpawnable(id, archetype)
    if NOT_INFANTRY[archetype] or archetype:starts_with("Beast_") or archetype:starts_with("AnimTestDummy") then
        return false
    end
    return not id:find("Tutorial", 1, true)
end

---- the archetype a unit data class declares, before PickCustomArchetype swaps it at runtime
local function ClassArchetype(id)
    local c = g_Classes[id]
    return c and c.archetype or "Soldier"
end

local function UnitFamily(unit)
    local id = unit.unitdatadef_id or unit.class or ""
    return id:match("^%u%l+") or ""
end

---- shortest matching class id of that family, base version before _Stronger/_Elite
local function PickClass(family, archetype)
    local best
    for id in sorted_pairs(UnitDataDefs) do
        if id:starts_with(family) and ClassArchetype(id) == archetype and IsSpawnable(id, archetype) then
            if not best or #id < #best then
                best = id
            end
        end
    end
    return best
end

local spawn_seq = 0

local function SpawnFor(team, side, class_id)
    local anchor = team.units[1 + (spawn_seq % Max(1, #team.units))]
    local pos = anchor and (GetPassSlab(anchor) or anchor:GetPos())
    spawn_seq = spawn_seq + 1
    local free = pos and DbgFindFreePassPositions(pos, 1, 12, xxhash(pos, spawn_seq))
    if not free or not free[1] then
        return
    end
    local unit = SpawnUnit(class_id, string.format("RatoArena_%s_%d", class_id, spawn_seq), free[1])
    if unit then
        unit:SetSide(side)
        unit.pending_aware_state = "aware"
    end
    return unit
end

local function DespawnOne(team, archetype)
    for _, u in ipairs(team.units) do
        if not u:IsDead() and ClassArchetype(u.unitdatadef_id or u.class) == archetype then
            u:Despawn()
            return true
        end
    end
end

local function Census(team)
    local counts = {}
    for _, u in ipairs(team.units) do
        if not u:IsDead() then
            local a = ClassArchetype(u.unitdatadef_id or u.class)
            counts[a] = (counts[a] or 0) + 1
        end
    end
    return counts
end

local function CensusText(counts)
    local o = {}
    for a, n in sorted_pairs(counts) do
        o[#o + 1] = a .. ":" .. n
    end
    return table.concat(o, " ")
end

---- spec: size, pct = {[archetype] = percent}, utility = {archetypes sharing the remainder},
---- family, dry. Despawns what is over target and spawns what is missing.
function RatoArena_Mix(side, spec)
    side = side or "enemy1"
    spec = spec or {}
    local team = table.find_value(g_Teams or empty_table, "side", side)
    if not team or #(team.units or empty_table) == 0 then
        return "no units on side " .. side
    end

    local counts = Census(team)
    local size = spec.size or 0
    if size == 0 then
        for _, n in pairs(counts) do
            size = size + n
        end
    end
    local family = spec.family
    if not family then
        local by_family = {}
        for _, u in ipairs(team.units) do
            local f = UnitFamily(u)
            by_family[f] = (by_family[f] or 0) + 1
            if not family or by_family[f] > by_family[family] then
                family = f
            end
        end
    end

    ---- percentages first, then the leftover budget is split evenly over the utility list
    local targets, used = {}, 0
    for a, pct in sorted_pairs(spec.pct or empty_table) do
        targets[a] = MulDivRound(size, pct, 100)
        used = used + targets[a]
    end
    ---- round-robin instead of dividing: no integer-division surprise, remainder lands on the first entries
    local utility = spec.utility or empty_table
    local left = Max(0, size - used)
    for i = 1, (#utility > 0 and left or 0) do
        local a = utility[1 + ((i - 1) % #utility)]
        targets[a] = (targets[a] or 0) + 1
    end

    local plan = {}
    local seen = {}
    for a in sorted_pairs(targets) do
        seen[a] = true
        plan[#plan + 1] = { a = a, delta = targets[a] - (counts[a] or 0) }
    end
    for a in sorted_pairs(counts) do
        if not seen[a] then
            plan[#plan + 1] = { a = a, delta = -counts[a] }
        end
    end

    if spec.dry then
        local o = {}
        for _, p in ipairs(plan) do
            if p.delta ~= 0 then
                o[#o + 1] = string.format("%s %+d", p.a, p.delta)
            end
        end
        return string.format("%s size=%d family=%s now [%s] plan: %s",
            side, size, family, CensusText(counts), #o > 0 and table.concat(o, " ") or "nothing to do")
    end

    local done = {}
    for _, p in ipairs(plan) do
        if p.delta < 0 then
            for _ = 1, -p.delta do
                if DespawnOne(team, p.a) then
                    done[#done + 1] = p.a .. "-1"
                end
            end
        elseif p.delta > 0 then
            local class_id = PickClass(family, p.a)
            for _ = 1, p.delta do
                if class_id and SpawnFor(team, side, class_id) then
                    done[#done + 1] = class_id .. "+1"
                end
            end
        end
    end
    AlertPendingUnits()
    return string.format("%s %s -- now [%s] -- SAVE the game",
        side, #done > 0 and table.concat(done, " ") or "no change", CensusText(Census(team)))
end

---- opts: family (default: the one already fighting), remove (despawn that many of the most common
---- archetype, to keep team size), dry (only report)
function RatoArena_Compose(side, opts)
    side = side or "enemy1"
    opts = opts or {}
    local team = table.find_value(g_Teams or empty_table, "side", side)
    if not team or #(team.units or empty_table) == 0 then
        return "no units on side " .. side
    end

    local counts = Census(team)
    local family = opts.family
    if not family then
        local by_family = {}
        for _, u in ipairs(team.units) do
            local f = UnitFamily(u)
            by_family[f] = (by_family[f] or 0) + 1
            if not family or by_family[f] > by_family[family] then
                family = f
            end
        end
    end

    local add = {}
    for id in sorted_pairs(UnitDataDefs) do
        if id:starts_with(family) then
            local a = ClassArchetype(id)
            if not counts[a] and IsSpawnable(id, a) and (not add[a] or #id < #add[a]) then
                add[a] = id
            end
        end
    end
    if opts.dry then
        local o = {}
        for a, id in sorted_pairs(add) do
            o[#o + 1] = a .. "=" .. id
        end
        return string.format("%s family=%s now [%s] missing %d: %s",
            side, family, CensusText(counts), #o, table.concat(o, " "))
    end

    ---- despawn first, so the free positions account for the ones leaving
    local removed = 0
    for _ = 1, opts.remove or 0 do
        local top, top_n
        for a, n in sorted_pairs(counts) do
            if not top_n or n > top_n then
                top, top_n = a, n
            end
        end
        if top and DespawnOne(team, top) then
            counts[top] = counts[top] - 1
            removed = removed + 1
        end
    end

    local spawned = {}
    for a, id in sorted_pairs(add) do
        if SpawnFor(team, side, id) then
            spawned[#spawned + 1] = a .. "=" .. id
        end
    end
    AlertPendingUnits()

    return string.format("%s family=%s removed=%d spawned %d: %s -- now [%s] -- SAVE the game",
        side, family, removed, #spawned, table.concat(spawned, " "), CensusText(Census(team)))
end

---- archetype census of a side, as declared by unit data (what composition actually is)
function RatoArena_Census(side)
    side = side or "enemy1"
    local team = table.find_value(g_Teams or empty_table, "side", side)
    if not team then
        return "no team " .. side
    end
    local counts = {}
    for _, u in ipairs(team.units) do
        if not u:IsDead() then
            local a = ClassArchetype(u.unitdatadef_id or u.class)
            counts[a] = (counts[a] or 0) + 1
        end
    end
    local o = {}
    for a, n in sorted_pairs(counts) do
        o[#o + 1] = a .. ":" .. n
    end
    return side .. " " .. table.concat(o, " ")
end

---------------------------------------------------------------------------------------------------
-- console helpers (Enter, or Alt-Shift-C, in game)
---------------------------------------------------------------------------------------------------

---- Readable state/result for the console; the driver uses RatoArena_Status/Read instead.
function RatoArena_Print()
    local m = RATOARENA.match
    if not m then
        print("arena: idle -- RatoArena_Start({max_turns = 12}) to run a match")
        return
    end
    if not m.result then
        print("arena: " .. RatoArena_Status())
        return
    end
    local r = m.result
    printf("arena %s: %s after %d turns (%s)", r.label ~= "" and r.label or "match", r.winner, r.turns, r.reason)
    for side, s in sorted_pairs(r.sides) do
        printf("   %-8s %d/%d standing, %d dead, %d down, hp %d/%d, dealt %d in %d attacks",
            side, s.alive or 0, s.units or 0, s.dead or 0, s.down or 0, s.hp or 0, s.hp0 or 0, s.dealt, s.attacks)
    end
end

---- Savegame names as RatoArena_Load/the driver want them; filter is a lowercase substring.
function RatoArena_Saves(filter)
    local err, list = Savegame.ListForTag("savegame")
    if err then
        print("arena: " .. tostring(err))
        return
    end
    for _, s in ipairs(list) do
        if not filter or s.savename:lower():find(filter:lower(), 1, true) then
            print("   " .. s.savename)
        end
    end
end

function OnMsg.DamageDone(attacker, target, dmg, hit_descr)
    local m = RATOARENA.active and RATOARENA.match
    if not m or not IsKindOf(attacker, "Unit") or not IsKindOf(target, "Unit") or not attacker.team then
        return
    end
    local s = SideStats(m, attacker.team.side)
    if target.team and not attacker.team:IsEnemySide(target.team) then
        s.friendly = s.friendly + (dmg or 0)
        return
    end
    s.dealt = s.dealt + (dmg or 0)
    local row = UnitRow(m, attacker)
    if row then
        row.dealt = row.dealt + (dmg or 0)
    end
end

function OnMsg.UnitDied(unit, killer)
    local m = RATOARENA.active and RATOARENA.match
    if not m or not IsKindOf(killer, "Unit") or not killer.team or not unit.team then
        return
    end
    if killer.team:IsEnemySide(unit.team) then
        local s = SideStats(m, killer.team.side)
        s.kills = s.kills + 1
        local row = UnitRow(m, killer)
        if row then
            row.kills = row.kills + 1
        end
    end
end

function OnMsg.OnAttack(attacker, action, target, results, attack_args)
    local m = RATOARENA.active and RATOARENA.match
    if m and IsKindOf(attacker, "Unit") and attacker.team then
        local s = SideStats(m, attacker.team.side)
        s.attacks = s.attacks + 1
    end
end

function OnMsg.NewCombatTurn(turn)
    local m = RATOARENA.active and RATOARENA.match
    if m and turn - m.start_turn >= m.max_turns then
        Finish("turn_cap")
    end
end

function OnMsg.CombatEnd()
    if RATOARENA.active then
        local m = RATOARENA.match
        m.last_turn = g_Combat and g_Combat.current_turn
        Finish("combat_end")
    end
end
