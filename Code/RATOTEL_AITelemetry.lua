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
-- PROFILER DE IA  (PERF_PROFILING.md, camadas N1-N4)
--
-- Mora aqui, e nao em arquivo proprio, por um motivo pratico: este ja esta na lista `code` do
-- metadata. Arquivo novo precisaria entrar por la E pelo items.lua do editor -- que foi
-- exatamente a armadilha que deixou o SOURCE_AIPrecalcConeTargetZones dormente por meses.
-- E o lugar tambem faz sentido: perfil E telemetria, e sai no MESMO registro JSONL.
--
-- LIGAR: `const.RATOAI.Profile = true` no console. Interruptor SEPARADO do RATOAI_Debug de
-- proposito -- perfilar com o debug ligado mede as tabelas de debug (o PERF C9 tirou-as do
-- caminho quente justamente para nao pagar por elas), ou seja, mede o overlay e nao a IA.
--
-- O QUE ELE MEDE, e por que cada coisa e medida do jeito que e:
--
--   N1  policies     tempo + alocacoes por CLASSE de AIPositioningPolicy. O laco OptLoc roda
--                    A x (numero de instancias) vezes, e a coluna `n` dividida por `opt`
--                    entrega quantas instancias daquela classe o arquetipo carrega -- e como
--                    se ve que o RATOAI_Demolition paga AIPolicyGrenadeRange duas vezes.
--   N2  fases        tempo dos globais que ninguem cronometra (AIPrecalcDamageScore e cia) e,
--                    de brinde, os cinco rotulos `thihk_steps` do vanilla passam a existir no
--                    TURNO REAL: o BeginStep so grava se receber debug_data, e o turno real
--                    chama `behavior:Think(unit)` sem tabela (CombatCamera.lua:1004).
--   N3  primitivas   CONTAGEM, nao cronometro. Uma chamada de CheckLOS esta ordens de grandeza
--                    abaixo da resolucao util do relogio; somar deltas zerados daria zero. E a
--                    contagem e melhor metrica de qualquer jeito: hoistar uma chamada faz o ms
--                    cair com ruido, e faz a contagem cair de 9.600 para 400 sem discussao.
--   N4  cardinalidade  #all_destinations, #destinations, #enemies. Sem elas, 40 ms com 300
--                    destinos e 40 ms com 1.400 viram a mesma linha na planilha.
--
-- RESOLUCAO DO RELOGIO. GetPreciseTicks(precision) tem `precision` = ticks por segundo, default
-- 1000 (ms). Aqui pedimos 1.000.000 (us), senao cada EvalDest individual arredondaria para 0 e a
-- soma da policy inteira sairia zero. Se o relogio da maquina nao entregar essa resolucao, a
-- coluna `z` (chamadas com delta zero) denuncia: z proximo de n quer dizer "nao confie no us
-- desta linha, olhe as alocacoes e a contagem".
--
-- ALOCACOES (`al`) sao EXATAS -- nao tem resolucao nem ruido. Para este codigo, onde metade dos
-- gargalos do PERF_PLAN e tabela criada dentro de laco, costuma ser o sinal mais acionavel.
--
-- QUANDO OS WRAPPERS SAO INSTALADOS: na PRIMEIRA unidade que raciocina depois de ligar o
-- interruptor, nao no load. A ordem de carga entre este mod e o Rato's AI Overhaul nao e
-- garantida, e varios destes globais SAO sobrescritos por la -- envolver no load poderia
-- envolver a versao vanilla e ser substituido logo em seguida.
--
-- Uma vez instalados, ficam. Desligar o interruptor nao os remove: eles passam a ser um
-- `if not cur then return f(...) end`, que e barato mas nao e zero. Para voltar ao custo zero,
-- recarregue o mod.
--
-- REINSTALAR NAO EMPILHA: `nossos` guarda wrapper -> original, entao reinstalar depois de um
-- reload de mod envolve sempre o ORIGINAL, nunca o wrapper anterior. Sem isso, cada reload
-- somaria uma camada e as contagens dobrariam em silencio.
---------------------------------------------------------------------------------------------------

const.RATOAI = const.RATOAI or {}
if const.RATOAI.Profile == nil then
    const.RATOAI.Profile = false
end

local TICKS = 1000000 ---- microssegundos
local MAX_LINHAS = 20 ---- teto por secao no JSONL

---- bucket da unidade que esta sendo raciocinada AGORA, ou nil.
---- Ponteiro unico e nao tabela por unidade porque think e play sao sequenciais e de uma unidade
---- por vez; cada ponto de entrada salva o anterior e restaura, entao aninhamento nao mistura.
local cur = nil
local buckets = setmetatable({}, {__mode = "k"})
local nossos = setmetatable({}, {__mode = "k"}) ---- wrapper -> funcao original

local function novo_bucket()
    return {pol = {}, ph = {}, cnt = {}, card = {}}
end

local function slot(tab, nome)
    local s = tab[nome]
    if not s then
        s = {us = 0, n = 0, z = 0, al = 0}
        tab[nome] = s
    end
    return s
end

local function creditar(s, t0, a0)
    local dt = GetPreciseTicks(TICKS) - t0
    s.us = s.us + dt
    s.al = s.al + (GetAllocationsCount() - a0)
    s.n = s.n + 1
    if dt <= 0 then
        s.z = s.z + 1
    end
end

---- devolve a funcao ORIGINAL por tras de `f`, seja ela wrapper nosso ou nao
local function cru(f)
    return f and (nossos[f] or f)
end

---------------------------------------------------------------------------------------------------
-- N2 -- fases. `table.unpack` aloca, mas estas rodam algumas vezes por turno, nao por destino.
---------------------------------------------------------------------------------------------------

---- Sem guarda de existencia, de proposito (regra do CLAUDE.md): GBO3 e o Rato's AI Overhaul
---- sao dependencias duras. Se um destes globais nao existir, e melhor estourar na primeira
---- chamada do que devolver `atual` e -- pior -- apagar o global no caminho.
local function fase(nome, atual)
    local f = cru(atual)
    local w = function(...)
        if not cur then
            return f(...)
        end
        local s = slot(cur.ph, nome)
        local t0, a0 = GetPreciseTicks(TICKS), GetAllocationsCount()
        ---- table.pack e nao {f(...)}: um retorno nil NO MEIO faria `#r` truncar a lista e a
        ---- funcao envolvida passaria a devolver menos coisa do que devolvia.
        local r = table.pack(f(...))
        creditar(s, t0, a0)
        return table.unpack(r, 1, r.n)
    end
    nossos[w] = f
    return w
end

---------------------------------------------------------------------------------------------------
-- N3 -- contadores. `return f(...)` e chamada de cauda: preserva todos os retornos sem alocar.
---------------------------------------------------------------------------------------------------

local function contar(nome, atual)
    local f = cru(atual)
    local w = function(...)
        if cur then
            local c = cur.cnt
            c[nome] = (c[nome] or 0) + 1
        end
        return f(...)
    end
    nossos[w] = f
    return w
end

---------------------------------------------------------------------------------------------------
-- instalacao
---------------------------------------------------------------------------------------------------

local instalado = false

local function instalar()
    if instalado then
        return
    end
    instalado = true

    ---- N1: uma entrada por CLASSE de policy. `rawget` de proposito -- so envolve quem tem
    ---- EvalDest PROPRIO; herdado seria contado duas vezes, e o da classe base so tem um assert.
    for nome, class in pairs(ClassDescendants("AIPositioningPolicy")) do
        local f = cru(rawget(class, "EvalDest"))
        if f then
            local w = function(self, context, dest, grid_voxel)
                if not cur then
                    return f(self, context, dest, grid_voxel)
                end
                local s = slot(cur.pol, nome)
                local t0, a0 = GetPreciseTicks(TICKS), GetAllocationsCount()
                local v = f(self, context, dest, grid_voxel)
                creditar(s, t0, a0)
                return v
            end
            nossos[w] = f
            class.EvalDest = w
        end
    end

    ---- N2: fases
    AIFindDestinations = fase("AIFindDestinations", AIFindDestinations)
    AIFindOptimalLocation = fase("AIFindOptimalLocation", AIFindOptimalLocation)
    AIPrecalcDamageScore = fase("AIPrecalcDamageScore", AIPrecalcDamageScore)
    AIScoreReachableVoxels = fase("AIScoreReachableVoxels", AIScoreReachableVoxels)
    AISelectAction = fase("AISelectAction", AISelectAction)

    ---- AIScoreDest tem wrapper PROPRIO, e nao o `fase` generico, por um motivo que importa: ele
    ---- roda uma vez POR DESTINO (milhares por turno), e o `fase` usa table.pack/unpack -- uma
    ---- tabela por chamada. Isso injetaria custo no laco mais quente que existe aqui E poluiria
    ---- a coluna `al` de tudo que roda dentro dele, que e justamente o numero que se quer olhar.
    ---- Assinatura fixa, um retorno, zero alocacao.
    local sd = cru(AIScoreDest)
    local sd_w = function(context, policies, dest, grid_voxel, base_score, visual_voxels,
                          score_details)
        if not cur then
            return sd(context, policies, dest, grid_voxel, base_score, visual_voxels,
                      score_details)
        end
        local s = slot(cur.ph, "AIScoreDest")
        local t0, a0 = GetPreciseTicks(TICKS), GetAllocationsCount()
        local v = sd(context, policies, dest, grid_voxel, base_score, visual_voxels, score_details)
        creditar(s, t0, a0)
        return v
    end
    nossos[sd_w] = sd
    AIScoreDest = sd_w

    ---- N3: primitivas
    CheckLOS = contar("CheckLOS", CheckLOS)
    GetCoverPercentage = contar("GetCoverPercentage", GetCoverPercentage)
    GetLoFData = contar("GetLoFData", GetLoFData)
    get_recoil = contar("get_recoil", get_recoil)
    AIGetAttackArgs = contar("AIGetAttackArgs", AIGetAttackArgs)
    AICalcAttacksAndAim = contar("AICalcAttacksAndAim", AICalcAttacksAndAim)
    RATOAI_ScoreAttacksDetailed = contar("ScoreAttacksDetailed", RATOAI_ScoreAttacksDetailed)
    Unit.CalcChanceToHit = contar("CalcChanceToHit", Unit.CalcChanceToHit)

    ---- N2: Think. Reaproveita o BeginStep/EndStep do vanilla passando uma tabela nossa -- tabela
    ---- NOVA a cada chamada, porque o BeginStep tem `assert(not thihk_steps[label])`.
    for _, class in pairs(ClassDescendants("AIBehavior")) do
        local f = cru(rawget(class, "Think"))
        if f then
            ---- O Think NAO roda dentro de nenhum wrapper da telemetria: o controlador de
            ---- execucao chama `behavior:Think(unit)` no laco de preparacao, antes de qualquer
            ---- AIExecuteUnitBehavior (CombatCamera.lua:1004). Entao a ativacao e feita AQUI, a
            ---- partir do bucket que o StartAI ja abriu para esta unidade.
            local w = function(self, unit, debug_data)
                local b = buckets[unit]
                if not b then
                    return f(self, unit, debug_data)
                end
                local prev = cur
                cur = b
                local dd = debug_data or {}
                local s = slot(cur.ph, "Think")
                local t0, a0 = GetPreciseTicks(TICKS), GetAllocationsCount()
                local r = f(self, unit, dd)
                creditar(s, t0, a0)
                for _, step in ipairs(dd.thihk_steps or empty_table) do
                    ---- indentado para sair aninhado sob o Think na listagem
                    local ss = slot(cur.ph, "  " .. tostring(step.label))
                    ss.us = ss.us + (step.time or 0) * 1000 ---- BeginStep mede em ms
                    ss.n = ss.n + 1
                end
                cur = prev
                return r
            end
            nossos[w] = f
            class.Think = w
        end
    end
end

---------------------------------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------------------------------

---- bucket cru da unidade (ou nil). Lido pelo RATODBG_AIDebugUI.
function RATOTEL_ProfFor(unit)
    return buckets[unit]
end

---- Zera e ativa o bucket da unidade. Usado no comeco do raciocinio dela.
local function ProfBegin(unit)
    if not const.RATOAI.Profile then
        return nil, false
    end
    instalar()
    buckets[unit] = novo_bucket()
    local prev = cur
    cur = buckets[unit]
    return prev, true
end

---- Reativa um bucket ja existente (fases que rodam depois do Think).
local function ProfResume(unit)
    if not const.RATOAI.Profile or not buckets[unit] then
        return nil, false
    end
    local prev = cur
    cur = buckets[unit]
    return prev, true
end

local function ProfEnd(prev)
    cur = prev
end

local function ordenar(tab)
    local lista = {}
    for nome, s in pairs(tab) do
        lista[#lista + 1] = {
            n = nome,
            us = s.us,
            c = s.n,
            z = s.z ~= 0 and s.z or nil,
            al = s.al ~= 0 and s.al or nil
        }
    end
    table.sort(lista, function(a, b)
        return (a.us or 0) > (b.us or 0)
    end)
    while #lista > MAX_LINHAS do
        table.remove(lista)
    end
    return lista
end

---- forma serializavel, para o campo `prof` do JSONL
local function ProfSnapshot(unit, context)
    local b = buckets[unit]
    if not b then
        return nil
    end
    if context then
        b.card.dests = #(context.destinations or empty_table)
        b.card.opt = #(context.all_destinations or empty_table)
        b.card.enemies = #(context.enemies or empty_table)
    end
    local cnt = {}
    for nome, v in pairs(b.cnt) do
        cnt[#cnt + 1] = {n = nome, c = v}
    end
    table.sort(cnt, function(x, y)
        return x.c > y.c
    end)
    return {pol = ordenar(b.pol), ph = ordenar(b.ph), cnt = cnt, card = b.card}
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

    ---- PROFILER (PERF_PROFILING.md). Sai no MESMO registro do resto, de proposito: o ms so
    ---- significa alguma coisa ao lado da cardinalidade e do arquetipo que o produziu.
    rec.prof = ProfSnapshot(unit, ctx)

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
    ---- O profiler tem interruptor PROPRIO (const.RATOAI.Profile) e precisa valer mesmo com a
    ---- telemetria desligada -- perfilar com o debug ligado mede as tabelas de debug, que e
    ---- justamente o que nao se quer medir. Sem este ramo, `Profile = true` sozinho nao abriria
    ---- bucket nenhum e a pagina Perf ficaria eternamente vazia.
    if not ENABLED() then
        local pprev = ProfBegin(self)
        local res = orig.StartAI(self, debug_data, forced_behavior)
        ProfEnd(pprev)
        return res
    end
    ---- passamos um debug_data proprio quando o jogo nao passa nenhum: e a unica
    ---- forma de capturar os scores de behavior, e StartAI so ESCREVE nessa tabela
    local dd = debug_data or {}
    ---- PROFILER: aqui comeca o raciocinio desta unidade neste turno -- e o unico ponto em que
    ---- ZERAR o bucket faz sentido. O Think vem depois, num laco separado do controlador de
    ---- execucao, e reativa este mesmo bucket.
    local pprev = ProfBegin(self)
    local res = orig.StartAI(self, dd, forced_behavior)
    ProfEnd(pprev)
    pcall(function()
        pending[self] = {ev = "turn", behs = SnapshotBehaviors(dd)}
    end)
    return res
end

function AIChooseSignatureAction(context)
    ---- PROFILER: no painel esta chamada acontece fora do AIExecuteUnitBehavior, entao sem esta
    ---- ativacao o AISelectAction sairia zerado exatamente no caminho que se esta olhando.
    local pprev = ProfResume(context.unit)
    local action = orig.AIChooseSignatureAction(context)
    ProfEnd(pprev)
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
        local pprev = ProfResume(unit)
        local status = orig.AIExecuteUnitBehavior(unit, force_or_skip_action)
        ProfEnd(pprev)
        return status
    end

    local rec = pending[unit]
    if rec then
        rec.run = (rec.run or 0) + 1
        pcall(CaptureBefore, unit, rec)
    end

    local pprev = ProfResume(unit)
    local status = orig.AIExecuteUnitBehavior(unit, force_or_skip_action)
    ProfEnd(pprev)

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
