---------------------------------------------------------------------------------------------------
-- Rato Dev -- telemetria de decisao da IA
--
-- Grava, por unidade e por turno, o que a IA decidiu E os numeros que sustentaram a
-- decisao, em JSONL (uma linha JSON por registro) em:
--
--     AppData/RatoTelemetry/ai_telemetry.jsonl
--     -> C:/Users/<voce>/AppData/Roaming/Jagged Alliance 3/RatoTelemetry/
--
-- Existe porque `unit.ai_context` e apagado no fim do turno
-- (CombatCamera.lua:1362, `unit.ai_context = nil` para toda unidade jogada), entao
-- nao ha como inspecionar o raciocinio depois que o turno acaba. Aqui capturamos
-- durante.
--
-- Regras de seguranca (isto roda numa campanha inteira):
--   * todo trabalho de telemetria esta dentro de pcall -- um erro meu nunca pode
--     derrubar o turno da IA;
--   * os wrappers sao ADITIVOS: chamam o original, gravam, devolvem o resultado
--     intacto;
--   * a decomposicao por policy roda DEPOIS que a unidade ja agiu, entao mesmo que
--     ela mexa em cache do context, nao influencia decisao nenhuma;
--   * const.RATOAI.Telemetry = false desliga tudo, deixando so a chamada direta ao
--     original; sem ela, segue o RATOAI_Debug.
---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------
-- PARAMETROS
---------------------------------------------------------------------------------------------------
---- LIGADO PELO MESMO INTERRUPTOR DO RESTO DO DEBUG.
---- Era um `false` chumbado, o que fazia esta ferramenta -- que existe exatamente para nao
---- precisar forcar comportamento pela UI -- ficar invisivel. `const.RATOAI.Telemetry` sobrepoe
---- explicitamente (true/false); sem ela, segue o RATOAI_Debug.
---- Funcao e nao valor: o RATOAI_Debug e recomputado no CombatStart, DEPOIS deste load. Um
---- booleano capturado aqui congelaria o valor errado. Nao ha custo de laco quente -- estes
---- wrappers rodam uma vez por unidade por turno.
local function ENABLED()
    local v = const.RATOAI and const.RATOAI.Telemetry
    if v ~= nil then
        return v
    end
    return RATOAI_Debug and true or false
end
local OUT_DIR = "AppData/RatoTelemetry"
local OUT_FILE = OUT_DIR .. "/ai_telemetry.jsonl"

---- quantos registros ficam em memoria antes de ir para o disco
local FLUSH_EVERY = 15
---- decompor o score do best_dest e do destino final policy a policy
local RECORD_BREAKDOWN = true
---- teto de itens em listas, para nao gerar linha gigante
local MAX_ACTIONS = 24
local MAX_BEHAVIORS = 12
local MAX_PARTS = 16

---------------------------------------------------------------------------------------------------
-- estado
---------------------------------------------------------------------------------------------------

local buffer = {}
local pending = setmetatable({}, {__mode = "k"}) ---- [unit] = registro em construcao
local session_id = tostring(GetPreciseTicks())

local function slabs(dist)
    if not dist then
        return nil
    end
    return MulDivRound(dist, 10, const.SlabSizeX) / 10
end

local function ap(v)
    if not v then
        return nil
    end
    return MulDivRound(v, 10, const.Scale.AP) / 10
end

---------------------------------------------------------------------------------------------------
-- escrita
---------------------------------------------------------------------------------------------------

local function Flush()
    if #buffer == 0 then
        return
    end
    local lines = buffer
    buffer = {}
    CreateRealTimeThread(function()
        AsyncCreatePath(OUT_DIR)
        AsyncStringToFile(OUT_FILE, table.concat(lines), -1)
    end)
end

local function Emit(rec)
    rec.sess = session_id
    rec.t = GameTime()
    rec.sector = gv_CurrentSectorId
    rec.turn = g_Combat and g_Combat.current_turn
    ---- LuaToJSON devolve (err, json); err = nil em sucesso (verificado no processo vivo)
    local err, json = LuaToJSON(rec)
    if err or type(json) ~= "string" then
        return
    end
    buffer[#buffer + 1] = json .. "\n"
    if #buffer >= FLUSH_EVERY then
        Flush()
    end
end

---------------------------------------------------------------------------------------------------
-- coleta
---------------------------------------------------------------------------------------------------

local function DestInfo(dest)
    if not dest then
        return nil
    end
    local x, y, z, stance_idx = stance_pos_unpack(dest)
    return {x = x, y = y, z = z, stance = StancesList[stance_idx]}
end

---- decomposicao de um score de posicao, policy a policy
local function Breakdown(context, policies, dest)
    if not dest or not policies or #policies == 0 then
        return nil
    end
    local unit = context.unit
    local filtered = table.ifilter(policies, function(idx, p)
        return p:MatchUnit(unit)
    end)
    if #filtered == 0 then
        return nil
    end
    local details = {}
    local total = AIScoreDest(context, filtered, dest, nil, 0, {}, details)
    local parts = {}
    for i = 1, #details - 1, 2 do
        if #parts >= MAX_PARTS then
            break
        end
        parts[#parts + 1] = {n = tostring(details[i]), v = details[i + 1]}
    end
    return {total = total, parts = parts}
end

local function SnapshotBehaviors(debug_data)
    local out = {}
    for _, d in ipairs((debug_data or empty_table).behaviors or empty_table) do
        if #out >= MAX_BEHAVIORS then
            break
        end
        out[#out + 1] = {
            n = tostring(d.name),
            s = d.score,
            pri = d.priority and true or nil,
            off = d.disable and true or nil
        }
    end
    return out
end

local function SnapshotActions(context)
    local out, total = {}, 0
    for _, descr in ipairs(context.choose_actions or empty_table) do
        if not descr.priority then
            total = total + Max(0, descr.weight or 0)
        end
    end
    for _, descr in ipairs(context.choose_actions or empty_table) do
        if #out >= MAX_ACTIONS then
            break
        end
        out[#out + 1] = {
            n = descr.action and tostring(descr.action:GetEditorView()) or "BaseAttack",
            w = descr.weight,
            pct = (total > 0 and not descr.priority) and
                MulDivRound(Max(0, descr.weight or 0), 100, total) or nil,
            pri = descr.priority and true or nil,
            ---- DEBUG (D5): `w = false` cobre DOIS estados -- desabilitada (nem chegou ao
            ---- PrecalcAction) e indisponivel (IsAvailable reprovou). Sem este campo o log
            ---- nao separa "a regra vetou" de "faltou AP/municao/CTH".
            off = descr.disabled_by or nil
        }
    end
    return out, total
end

local function EnemyStats(context)
    local unit = context.unit
    local upos = unit:GetPos()
    local visible, closest = 0, nil
    for _, enemy in ipairs(context.enemies or empty_table) do
        if IsValid(enemy) and not enemy:IsDead() then
            if context.enemy_visible and context.enemy_visible[enemy] then
                visible = visible + 1
            end
            local epos = context.enemy_pos and context.enemy_pos[enemy]
            if epos then
                local d = upos:Dist(epos)
                if not closest or d < closest then
                    closest = d
                end
            end
        end
    end
    return visible, closest
end

local function CaptureBefore(unit, rec)
    local ctx = unit.ai_context
    if not ctx or not rec then
        return
    end

    rec.unit = unit.session_id
    rec.arch = ctx.archetype and ctx.archetype.id
    rec.kw = unit.AIKeywords and table.concat(unit.AIKeywords, ",") or nil
    rec.side = unit.team and unit.team.side
    rec.hp = unit.HitPoints
    rec.maxhp = unit.MaxHitPoints
    rec.ap0 = ap(unit.ActionPoints)
    rec.beh = ctx.behavior and tostring(ctx.behavior:GetEditorView())
    rec.max_atk = ctx.max_attacks

    rec.pos0 = DestInfo(GetPackedPosAndStance(unit))
    rec.best = DestInfo(ctx.best_dest)
    rec.best_score = ctx.best_score
    rec.dest = DestInfo(ctx.ai_destination)
    rec.dest_score = ctx.best_end_score

    local d = ctx.ai_destination
    if d then
        local tgt = ctx.dest_target and ctx.dest_target[d]
        rec.target = IsValid(tgt) and tgt.session_id or nil
        rec.tgt_score = ctx.dest_target_score and ctx.dest_target_score[d]
        rec.hit_score = ctx.dest_hit_score and ctx.dest_hit_score[d]
        rec.dest_ap = ap(ctx.dest_ap and ctx.dest_ap[d])
    end

    local visible, closest = EnemyStats(ctx)
    rec.enemies = #(ctx.enemies or empty_table)
    rec.enemies_vis = visible
    rec.closest = slabs(closest)
end

local function CaptureAfter(unit, rec, status)
    local ctx = unit.ai_context
    if not rec then
        return
    end

    rec.ap1 = ap(IsValid(unit) and unit.ActionPoints or nil)
    rec.status = status and tostring(status) or nil
    rec.dead = (not IsValid(unit) or unit:IsDead()) and true or nil

    if IsValid(unit) then
        rec.pos1 = DestInfo(GetPackedPosAndStance(unit))
        if rec.pos0 and rec.pos1 then
            local a = point(rec.pos0.x, rec.pos0.y, rec.pos0.z or 0)
            local b = point(rec.pos1.x, rec.pos1.y, rec.pos1.z or 0)
            rec.moved = slabs(a:Dist2D(b))
        end
    end

    ---- RESULTADO ESPERADO (do Rato's AI Overhaul).
    ---- Copia do que o proprio turno gravou no context -- nao recalcula nada. Sem isto o JSONL
    ---- mostra o PESO final de cada acao sem mostrar a razao que o produziu, que e justamente a
    ---- parte que se quer auditar sem ter de forcar a acao pela UI.
    if ctx then
        rec.expected = ctx.dbg_expected
        rec.aim_plan = ctx.dbg_aim_plan
        rec.atk = ctx.default_attack and ctx.default_attack.id
        rec.degraded = ctx.__ratoai_degraded and true or nil
    end

    ---- decomposicao rodada AQUI de proposito: a unidade ja agiu, entao qualquer
    ---- efeito colateral em cache do context nao influencia decisao nenhuma
    if RECORD_BREAKDOWN and ctx then
        rec.best_parts = Breakdown(ctx, ctx.archetype and ctx.archetype.OptLocPolicies,
                                   ctx.best_dest)
        rec.dest_parts = Breakdown(ctx, ctx.behavior and ctx.behavior.EndTurnPolicies,
                                   ctx.ai_destination)
    end

    Emit(rec)
end

---------------------------------------------------------------------------------------------------
-- wrappers
--
-- Os originais ficam numa tabela pendurada no classdef Unit (nao em _G) para
-- sobreviver ao reload do mod sem risco de capturar o proprio wrapper e recursar.
---------------------------------------------------------------------------------------------------

Unit.ratotel_orig = Unit.ratotel_orig or {
    StartAI = Unit.StartAI,
    AIChooseSignatureAction = AIChooseSignatureAction,
    AIExecuteUnitBehavior = AIExecuteUnitBehavior
}
local orig = Unit.ratotel_orig

function Unit:StartAI(debug_data, forced_behavior)
    if not ENABLED() then
        return orig.StartAI(self, debug_data, forced_behavior)
    end
    ---- passamos um debug_data proprio quando o jogo nao passa nenhum: e a unica
    ---- forma de capturar os scores de behavior, e StartAI so ESCREVE nessa tabela
    local dd = debug_data or {}
    local res = orig.StartAI(self, dd, forced_behavior)
    pcall(function()
        pending[self] = {ev = "turn", behs = SnapshotBehaviors(dd)}
    end)
    return res
end

function AIChooseSignatureAction(context)
    local action = orig.AIChooseSignatureAction(context)
    if ENABLED() then
        pcall(function()
            local rec = pending[context.unit]
            if rec then
                local list, total = SnapshotActions(context)
                rec.actions = list
                rec.actions_total = total
                rec.sig = action and tostring(action:GetEditorView()) or "(nenhuma)"
            end
        end)
    end
    return action
end

function AIExecuteUnitBehavior(unit, force_or_skip_action)
    if not ENABLED() then
        return orig.AIExecuteUnitBehavior(unit, force_or_skip_action)
    end

    local rec = pending[unit]
    if rec then
        rec.run = (rec.run or 0) + 1
        pcall(CaptureBefore, unit, rec)
    end

    local status = orig.AIExecuteUnitBehavior(unit, force_or_skip_action)

    if rec then
        pcall(CaptureAfter, unit, rec, status)
        ---- AIExecuteUnitBehavior pode ser reexecutada ("restart"); o proximo passe
        ---- comeca um registro novo, herdando so os scores de behavior
        pending[unit] = {ev = "turn", behs = rec.behs, run = rec.run}
    end

    return status
end

---------------------------------------------------------------------------------------------------
-- marcos de combate
---------------------------------------------------------------------------------------------------

function OnMsg.CombatStart()
    if not ENABLED() then
        return
    end
    pcall(function()
        local sides = {}
        for _, team in ipairs(g_Teams or empty_table) do
            if #(team.units or empty_table) > 0 then
                sides[#sides + 1] = string.format("%s:%d", tostring(team.side), #team.units)
            end
        end
        Emit({ev = "combat_start", teams = table.concat(sides, " ")})
    end)
end

function OnMsg.CombatEnd()
    if not ENABLED() then
        return
    end
    pcall(function()
        Emit({ev = "combat_end"})
    end)
    Flush()
end

function OnMsg.DoneMap()
    Flush()
end
