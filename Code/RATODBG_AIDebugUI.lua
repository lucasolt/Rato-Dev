---------------------------------------------------------------------------------------------------
---- Rato Dev -- IModeAIDebug estendido
----
---- Copia de Lua/UI/IModeAIDebug.lua + Lua/XTemplates/IModeAIDebug.lua, com:
----   1. painel com BARRA DE ROLAGEM (o original cortava a parte de baixo)
----   2. camadas por POLICY: pinta cada slab com a contribuicao individual de uma
----      policy (Custom Seek Cover, Deal Damage, WeaponRange, ...), descobertas
----      dinamicamente a partir das tabelas de score_details
----   3. formatacao condicional por cor nos modos de score
----
----------------------------------------------------------------
---------------------------------------------------------------------------------------------------
-- PARAMETROS  (tudo local; edite aqui e recarregue o mod)
---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
---- zero exato, ou tile sem valor
local CLR_ZERO = RGB(125, 128, 132)

local POS_RAMP = {
    RGB(152, 170, 160), RGB(200, 215, 115), RGB(232, 240, 55), RGB(120, 240, 130), RGB(0, 250, 200)
}

local NEG_RAMP = {
    RGB(180, 150, 150), RGB(214, 118, 108), RGB(236, 80, 62), RGB(250, 40, 26), RGB(255, 0, 72)
}

---- cortes do gradiente, em % da faixa [min, max]
local RAMP_STOPS = {20, 40, 60, 80}


local RATIO_CLR_LOW = {255, 0, 72}
local RATIO_CLR_PIVOT = {232, 240, 55}
local RATIO_CLR_HIGH = {0, 250, 200}
local RATIO_CLR_NULL = {130, 130, 130}


local PANEL_MAX_WIDTH = 700


local CLR_FINALIST = RGB(255, 255, 255)
local RING_SCALE = 165 ---- % do tamanho do quadrado normal


local INFL_MODES = {
    {id = "threat", name = "Ameaca", name_cancel = "Ameaca BRUTA"},
    {id = "cover", name = "Cobertura", name_cancel = "Cobertura CANCELOU"},
    {id = "sum", name = "Ameaca + Cobertura", name_cancel = "LIQUIDO"}
}

---- uma cor por alvo, estavel dentro do turno (indice em context.enemies)
local TARGET_COLORS = {
    RGB(255, 90, 90), RGB(90, 170, 255), RGB(255, 225, 70), RGB(120, 255, 130), RGB(255, 150, 245),
    RGB(120, 245, 255), RGB(255, 175, 65), RGB(195, 145, 255)
}

---------------------------------------------------------------------------------------------------
-- helpers (copias dos locais do arquivo original)
---------------------------------------------------------------------------------------------------

local ap_scale = const.Scale.AP

local function format_ap(ap)
    return ap and string.format("%d.%d", ap / ap_scale, (10 * ap / ap_scale) / 10) or "N/A"
end

local function VoxelToPoint(voxel)
    return point(point_unpack(voxel))
end

local function DestToPoint(dest)
    local x, y, z = stance_pos_unpack(dest)
    return point(x, y, z)
end

---- PlaceSquareFX do jogo tem TAMANHO FIXO -- o primeiro parametro e offset em Z,
---- nao escala. Por isso um "anel" desenhado com ela sai identico ao quadrado normal,
---- so que flutuando. Esta versao aceita escala de verdade.
local function PlaceScaledSquareFX(z_offset, pos, color, scale_pct)
    local border = 5 * guic
    local trim = const.SlabSizeX / 10
    local x, y, z = pos:xyz()
    z = (z or terrain.GetHeight(pos)) + z_offset
    local w1 = MulDivRound(const.SlabSizeX / 2 - border, scale_pct or 100, 100)
    local w2 = w1 - trim
    local path = pstr("")
    path:AppendVertex(x - w1, y - w2, z, color)
    path:AppendVertex(x - w2, y - w1, z)
    path:AppendVertex(x + w2, y - w1, z)
    path:AppendVertex(x + w1, y - w2, z)
    path:AppendVertex(x + w1, y + w2, z)
    path:AppendVertex(x + w2, y + w1, z)
    path:AppendVertex(x - w2, y + w1, z)
    path:AppendVertex(x - w1, y + w2, z)
    path:AppendVertex(x - w1, y - w2, z)
    local fx = PlaceObject("Polyline")
    fx:SetPos(x, y, z)
    fx:SetMesh(path)
    return fx
end

local function PlaceTextFx(text, pos, color)
    local dbg_text = Text:new()
    dbg_text:SetText(tostring(text))
    dbg_text:SetPos(pos)
    if color then
        dbg_text:SetColor(color)
    end
    return dbg_text
end

---------------------------------------------------------------------------------------------------
-- formatacao condicional
---------------------------------------------------------------------------------------------------
local function RampBand(t, ramp)
    local idx = #ramp
    for i, stop in ipairs(RAMP_STOPS) do
        if t < stop then
            idx = i
            break
        end
    end
    return ramp[Clamp(idx, 1, #ramp)]
end

local function ScoreColor(value, vmin, vmax)
    if not value or value == 0 then
        return CLR_ZERO
    end

    if value < 0 then
        ---- vmin e o mais negativo; t vai de 0 (quase zero) a 100 (o pior do mapa)
        local worst = Min(0, vmin or 0)
        if worst >= 0 then
            return NEG_RAMP[1]
        end
        return RampBand(Clamp(MulDivRound(-value, 100, -worst), 0, 100), NEG_RAMP)
    end

    local top = Max(0, vmax or 0)
    if top <= 0 then
        return POS_RAMP[#POS_RAMP]
    end
    return RampBand(Clamp(MulDivRound(value, 100, top), 0, 100), POS_RAMP)
end

local function LerpClrTag(a, b, t)
    t = Clamp(t, 0, 100)
    return string.format("%d %d %d", Clamp(a[1] + MulDivRound(b[1] - a[1], t, 100), 0, 255),
                         Clamp(a[2] + MulDivRound(b[2] - a[2], t, 100), 0, 255),
                         Clamp(a[3] + MulDivRound(b[3] - a[3], t, 100), 0, 255))
end


local function RatioColorTag(ratio)
    if not ratio then
        return LerpClrTag(RATIO_CLR_NULL, RATIO_CLR_NULL, 0)
    end
    if ratio >= 100 then
        ---- acima do empate: o quanto da faixa [100, teto] ja foi percorrido
        local teto = (const.RATOAI and const.RATOAI.ExpectedRatioMax) or 300
        return LerpClrTag(RATIO_CLR_PIVOT, RATIO_CLR_HIGH,
                          MulDivRound(ratio - 100, 100, Max(1, teto - 100)))
    end
    ---- abaixo do empate a faixa ja e 0..100, entao `ratio` e o proprio t
    return LerpClrTag(RATIO_CLR_LOW, RATIO_CLR_PIVOT, ratio)
end

---------------------------------------------------------------------------------------------------
-- leitura das tabelas de score_details
--
-- Cada `scores` e um array intercalado { label1, valor1, label2, valor2, ... } com
-- `final_score` como campo nomeado. AIScoreDest prefixa "[FAILED] " quando uma policy
-- Required falha, e insere entradas extras ("ADJACENT FIRE", "BOMBARD ZONE",
-- "Bias Marker ...") -- por isso indexamos por LABEL, nao por posicao.
---------------------------------------------------------------------------------------------------

local function CleanLabel(label)
    if type(label) ~= "string" then
        return nil
    end
    return (string.gsub(label, "^%[FAILED%] ", ""))
end

---- soma todas as entradas com o mesmo label (duas policies identicas na mesma lista)
local function PolicyValue(scores, label)
    if not scores or not label then
        return nil
    end
    local total, found = 0, false
    for i = 1, #scores - 1, 2 do
        if CleanLabel(scores[i]) == label then
            total = total + (scores[i + 1] or 0)
            found = true
        end
    end
    return found and total or nil
end


local function SumSelection(self, scope)
    self.dbg_sum_sel = self.dbg_sum_sel or {}
    self.dbg_sum_sel[scope] = self.dbg_sum_sel[scope] or {}
    return self.dbg_sum_sel[scope]
end

local function SumSelectedLabels(self, scope, labels)
    local sel = SumSelection(self, scope)
    local out = {}
    ---- percorre `labels` e nao `sel`: sai na ordem da lista na tela, e descarta sozinho
    ---- o que foi marcado num think anterior e nao existe mais
    for _, label in ipairs(labels or empty_table) do
        if sel[label] then
            out[#out + 1] = label
        end
    end
    return out
end

---- descobre todos os labels presentes numa tabela de score_details
local function CollectPolicyLabels(score_tbl)
    local labels, seen = {}, {}
    for _, scores in pairs(score_tbl or empty_table) do
        for i = 1, #scores - 1, 2 do
            local label = CleanLabel(scores[i])
            if label and not seen[label] then
                seen[label] = true
                labels[#labels + 1] = label
            end
        end
    end
    table.sort(labels)
    return labels
end

---- Qual destino a analise de alvo deve usar.
---- HoldPositionAI (o teu "ShootingStance", o "In Setup" do MG) nunca seta
---- ai_destination -- o Think dele chama AIPrecalcDamageScore com
---- { GetPackedPosAndStance(unit) }, ou seja, avalia na posicao ATUAL.
---- Mesmo fallback que o GetDestArgs do Rato AI Overhaul ja faz.
local function EvalDestOf(context)
    local d = context.ai_destination
    if d then
        return d, false
    end
    local here = GetPackedPosAndStance(context.unit)
    if here and context.dest_cth and context.dest_cth[here] then
        return here, true
    end
    ---- ainda assim devolve a posicao atual: melhor mostrar "sem dados" no tile
    ---- certo do que nao mostrar nada
    return here, true
end

local function TargetIndex(context, target)
    for i, e in ipairs(context.enemies or empty_table) do
        if e == target then
            return i
        end
    end
end

local function TargetColor(idx)
    return TARGET_COLORS[((idx or 1) - 1) % #TARGET_COLORS + 1]
end

---- camada numerica generica: mede min/max, pinta com gradiente e escreve o valor
local function NumericLayer(self, fx, dests, getter, fmt)
    local vmin, vmax
    for _, dest in ipairs(dests) do
        local v = getter(dest)
        if v then
            vmin = vmin and Min(vmin, v) or v
            vmax = vmax and Max(vmax, v) or v
        end
    end
    vmin, vmax = vmin or 0, vmax or 0
    self.dbg_layer_range = {vmin, vmax, nil}

    for _, dest in ipairs(dests) do
        local v = getter(dest)
        if v then
            local pt = DestToPoint(dest)
            local color = ScoreColor(v, vmin, vmax)
            fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, color)
            fx[#fx + 1] = PlaceTextFx(string.format(fmt or "%d", v), pt, color)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- ShowAIVoxels estendido
---------------------------------------------------------------------------------------------------

function IModeAIDebug:ShowAIVoxels(group)
    local fx = {}
    self:ClearVoxelFx(fx)
    self.dbg_layer = group
    self.dbg_layer_label = nil
    self.dbg_layer_range = nil

    if not self.selected_unit or not self.ai_context then
        self:Update()
        return
    end

    local ctx = self.ai_context

    if group == "candidates" then
        for _, dest in ipairs(ctx.best_dests or empty_table) do
            fx[#fx + 1] = PlaceSquareFX(5 * guic, DestToPoint(dest), const.clrSilverGray)
        end

    elseif group == "collapsed" then
        for _, dest in ipairs(ctx.collapsed or empty_table) do
            fx[#fx + 1] = PlaceSquareFX(5 * guic, DestToPoint(dest), const.clrSilverGray)
        end

    elseif group == "combatpath_ap" then
        for _, dest in ipairs(ctx.destinations or empty_table) do
            local pt = DestToPoint(dest)
            fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, const.clrYellow)
            fx[#fx + 1] = PlaceTextFx(format_ap(ctx.dest_ap[dest]), pt, const.clrYellow)
        end

    elseif group == "combatpath_dist" then
        local dists = ctx.dest_dist or empty_table
        for _, dest in ipairs(ctx.destinations or empty_table) do
            local pt = DestToPoint(dest)
            fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, const.clrYellow)
            fx[#fx + 1] = PlaceTextFx(tostring(dists[dest]), pt, const.clrYellow)
        end

    elseif group == "pathtotarget" then
        local reachable = ctx.voxel_to_dest or empty_table
        for _, voxel in ipairs(ctx.path_to_target or empty_table) do
            local dest = reachable[voxel]
            local clr = dest and const.clrYellow or const.clrRed
            local pt = VoxelToPoint(voxel)
            fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, clr)
            fx[#fx + 1] = PlaceTextFx(tostring(ctx.dest_dist and ctx.dest_dist[dest]), pt,
                                      const.clrYellow)
        end

        ------------------------------------------------------------------------------
        ---- scores totais, com gradiente
        ------------------------------------------------------------------------------
    elseif group == "combatpath_score" or group == "combatpath_optscore" then
        local is_end = group == "combatpath_score"
        local score_tbl = (is_end and self.think_data.reachable_scores or
                              self.think_data.optimal_scores) or empty_table
        local dests = is_end and (ctx.destinations or empty_table) or
                          (ctx.all_destinations or ctx.destinations or empty_table)

        local vmin, vmax
        for _, dest in ipairs(dests) do
            local s = (score_tbl[dest] or empty_table).final_score
            if s then
                vmin = vmin and Min(vmin, s) or s
                vmax = vmax and Max(vmax, s) or s
            end
        end
        vmin, vmax = vmin or 0, vmax or 0

        local best = is_end and (ctx.best_end_score or 0) or (ctx.best_score or 0)
        local threshold = MulDivRound(best, const.AIDecisionThreshold, 100)
        self.dbg_layer_range = {vmin, vmax, threshold}

        for _, dest in ipairs(dests) do
            local scores = score_tbl[dest]
            if scores then
                local pt = DestToPoint(dest)
                local score = scores.final_score or 0
                local color = ScoreColor(score, vmin, vmax)
                local finalist = score > 0 and score >= threshold
                fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, color)
                fx[#fx + 1] = PlaceTextFx(finalist and ("*" .. score) or tostring(score), pt,
                                          finalist and CLR_FINALIST or color)
                if finalist then
                    fx[#fx + 1] = PlaceScaledSquareFX(14 * guic, pt, CLR_FINALIST, RING_SCALE)
                end
            end
        end

        ------------------------------------------------------------------------------
        ---- soma de policies -- o balanco cobertura vs exposicao num numero so
        ------------------------------------------------------------------------------
    elseif group == "sumsel_end" or group == "sumsel_opt" then
        local scope = (group == "sumsel_end") and "end" or "opt"
        local is_end = scope == "end"
        local score_tbl = (is_end and self.think_data.reachable_scores or
                              self.think_data.optimal_scores) or empty_table
        local dests = is_end and (ctx.destinations or empty_table) or
                          (ctx.all_destinations or ctx.destinations or empty_table)

        local labels = SumSelectedLabels(self, scope,
                                         is_end and self.dbg_labels_end or self.dbg_labels_opt)
        if #labels == 0 then
            self.dbg_layer_label = "nenhuma policy marcada"
            self:Update()
            return
        end

        self.dbg_layer_label = table.concat(labels, " + ") ..
                                   (is_end and "  <EndTurn>" or "  <OptLoc>")

        NumericLayer(self, fx, dests, function(dest)
            local scores = score_tbl[dest]
            if not scores then
                return nil
            end
            local total, found = 0, false
            for _, label in ipairs(labels) do
                local v = PolicyValue(scores, label)
                if v then
                    total = total + v
                    found = true
                end
            end
            return found and total or nil
        end)

    elseif group == "decomp_end" or group == "decomp_opt" then
        ------------------------------------------------------------------------------
        ---- DECOMPOSICAO -- pinta o slab com o componente selecionado no modo mestre
        ----
        ---- Substituiu a camada "Soma": somar as duas policies era o caso particular
        ---- `liquido` desta. E o escopo/modo daqui sao os MESMOS que as linhas de
        ---- rollover usam, entao o numero do slab e a soma das linhas dele batem.
        ------------------------------------------------------------------------------
        local is_end = group == "decomp_end"
        local dests = is_end and (ctx.destinations or empty_table) or
                          (ctx.all_destinations or ctx.destinations or empty_table)

        ---- a camada segue o escopo do modo mestre, para nao existirem dois escopos
        self.dbg_influence_scope = is_end and "end" or "opt"
        local mode = self.dbg_influence or "sum"
        local threat_pol, cancels, cover_pol = self:InfluencePolicy()

        if not threat_pol and not cover_pol then
            self.dbg_layer_label = "nenhuma policy de ameaca/cobertura neste escopo"
            self:Update()
            return
        end

        local nome
        for _, m in ipairs(INFL_MODES) do
            if m.id == mode then
                nome = (cancels and m.name_cancel) or m.name
            end
        end
        self.dbg_layer_label = string.format("%s%s", tostring(nome),
                                             is_end and "  <EndTurn>" or "  <OptLoc>")

        NumericLayer(self, fx, dests, function(dest)
            return self:DecompValue(dest, nil, mode)
        end)

        ------------------------------------------------------------------------------
        ---- camadas de ALVO -- de cada tile alcancavel, em quem a IA atiraria e quao bem
        ------------------------------------------------------------------------------
    elseif group == "target_recalc" then
        ---- HoldPositionAI so avalia dano na posicao atual, entao as camadas de alvo
        ---- ficam com um tile so. Isto recalcula em TODOS os destinos alcancaveis --
        ---- resposta hipotetica ("se ela se movesse, atiraria em quem"), nao o que a
        ---- IA de fato avaliou. So no modo de debug, a unidade nao esta agindo.
        ---- via PrecalcForDebug para congelar a randomizacao por alvo: sem isso o
        ---- recalculo re-sorteia `target_score_mod` e os scores da pagina Alvo mudam
        ---- so por ter-se aberto esta camada.
        self:PrecalcForDebug(ctx.destinations)
        self.dbg_targets_recalced = true
        self.dbg_layer = nil
        self:Update()
        return

    elseif group == "target_who" then
        self.dbg_layer_label = "alvo escolhido por tile"
        self.dbg_layer_range = nil
        for _, dest in ipairs(ctx.destinations or empty_table) do
            local pt = DestToPoint(dest)
            local tgt = ctx.dest_target and ctx.dest_target[dest]
            if IsValid(tgt) then
                local idx = TargetIndex(ctx, tgt)
                local color = TargetColor(idx)
                fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, color)
                fx[#fx + 1] = PlaceTextFx("#" .. tostring(idx or "?"), pt, color)
            else
                fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, CLR_ZERO)
                fx[#fx + 1] = PlaceTextFx("-", pt, CLR_ZERO)
            end
        end

    elseif group == "target_cth" then
        self.dbg_layer_label = "CTH do 1o disparo (%)"
        NumericLayer(self, fx, ctx.destinations or empty_table, function(dest)
            return ctx.dest_cth and ctx.dest_cth[dest]
        end)

    elseif group == "target_hits" then
        self.dbg_layer_label = "acertos esperados x100 (dest_hit_score)"
        NumericLayer(self, fx, ctx.destinations or empty_table, function(dest)
            return ctx.dest_hit_score and ctx.dest_hit_score[dest]
        end)

    elseif group == "target_score" then
        self.dbg_layer_label = "dest_target_score cru"
        NumericLayer(self, fx, ctx.destinations or empty_table, function(dest)
            return ctx.dest_target_score and ctx.dest_target_score[dest]
        end)

        ------------------------------------------------------------------------------
        ---- camada de UMA policy
        ------------------------------------------------------------------------------
    else
        local scope, idx = string.match(group or "", "^policy_(%a+)_(%d+)$")
        if not scope then
            self:Update()
            return
        end
        idx = tonumber(idx)

        local is_end = scope == "end"
        local score_tbl = (is_end and self.think_data.reachable_scores or
                              self.think_data.optimal_scores) or empty_table
        local labels = (is_end and self.dbg_labels_end or self.dbg_labels_opt) or empty_table
        local label = labels[idx]
        if not label then
            self:Update()
            return
        end

        local dests = is_end and (ctx.destinations or empty_table) or
                          (ctx.all_destinations or ctx.destinations or empty_table)

        local vmin, vmax
        for _, dest in ipairs(dests) do
            local v = PolicyValue(score_tbl[dest], label)
            if v then
                vmin = vmin and Min(vmin, v) or v
                vmax = vmax and Max(vmax, v) or v
            end
        end
        vmin, vmax = vmin or 0, vmax or 0

        self.dbg_layer_label = label
        self.dbg_layer_range = {vmin, vmax, nil}

        for _, dest in ipairs(dests) do
            local v = PolicyValue(score_tbl[dest], label)
            if v then
                local pt = DestToPoint(dest)
                local color = ScoreColor(v, vmin, vmax)
                fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, color)
                fx[#fx + 1] = PlaceTextFx(string.format("%d", v), pt, color)
            end
        end
    end

    self:Update()
end

---------------------------------------------------------------------------------------------------
-- Selecao multipla de policies
--
-- A selecao e guardada por LABEL, nao por indice: `dbg_labels_*` e reconstruido a cada
-- Update e a ordem muda quando uma policy some da lista (Required que falhou, por
-- exemplo). Indice sobreviveria ao redesenho apontando para outra policy.
--
-- Por escopo, porque a mesma policy pode ter pesos diferentes em OptLoc e End Turn e nao
-- faz sentido somar as duas coisas.
---------------------------------------------------------------------------------------------------

---- arg vem como "end_3" / "opt_12": escopo + indice na lista daquele escopo
function IModeAIDebug:ToggleSumPolicy(arg)
    local scope, idx = string.match(tostring(arg or ""), "^(%a+)_(%d+)$")
    if not scope then
        return
    end
    local labels = (scope == "end" and self.dbg_labels_end or self.dbg_labels_opt) or empty_table
    local label = labels[tonumber(idx)]
    if not label then
        return
    end
    local sel = SumSelection(self, scope)
    sel[label] = (not sel[label]) or nil

    ---- se a camada de soma esta no ar, repinta com a selecao nova
    if self.dbg_layer == "sumsel_" .. scope then
        self:ShowAIVoxels(self.dbg_layer)
    else
        self:Update()
    end
end

function IModeAIDebug:ClearSumPolicies(scope)
    if scope then
        self.dbg_sum_sel = self.dbg_sum_sel or {}
        self.dbg_sum_sel[scope] = {}
    else
        self.dbg_sum_sel = {}
    end
    if self.dbg_layer and string.match(self.dbg_layer, "^sumsel_") then
        self:ClearAILayer()
    else
        self:Update()
    end
end

function IModeAIDebug:ClearAILayer()
    self.dbg_layer = nil
    self.dbg_layer_label = nil
    self.dbg_layer_range = nil
    self:ClearVoxelFx()
    self:Update()
end

---------------------------------------------------------------------------------------------------
-- FILTRO DE AMEACA -- isolar quais inimigos contam
--
-- Com varios inimigos em campo, os termos da AIPolicyThreatExposure (rampa de distancia,
-- cancelamento por cobertura, postura, custo de preparo) chegam ao tile SOMADOS. Um numero que e a
-- soma de quatro coisas nao deixa verificar nenhuma delas. Restringindo a ameaca a um inimigo,
-- cada termo fica legivel no rollover.
--
-- O estado mora em `const.RATOAI.ThreatOnly` (mod RATOAI, cabecalho em UTIL.lua) e nao em `self`:
-- quem consome sao as policies, que rodam dentro do Think e nao enxergam o painel. Vazio/false =
-- todos contam, que e o comportamento normal.
--
-- Como o filtro muda o RESULTADO do scoring e nao so a apresentacao, todo toggle re-roda o
-- `Process` -- sem isso o painel mostraria os numeros do think anterior e pareceria quebrado.
--
-- A lista fica em `dbg_threat_ids` pelo mesmo motivo dos `dbg_labels_*`: o arg do link e um
-- indice, e a ordem de `context.enemies` pode mudar entre redesenhos.
---------------------------------------------------------------------------------------------------
function IModeAIDebug:ToggleThreatUnit(arg)
    local idx = tonumber(arg)
    local id = idx and (self.dbg_threat_ids or empty_table)[idx]
    if not id then
        return
    end
    local only = const.RATOAI.ThreatOnly
    if not only then
        only = {}
        const.RATOAI.ThreatOnly = only
    end
    only[id] = (not only[id]) or nil
    ---- tabela vazia ja significa "sem filtro", mas deixar `{}` faria o `next()` do
    ---- RATOAI_ThreatCounts rodar a toa em todo destino. Normaliza para false.
    if next(only) == nil then
        const.RATOAI.ThreatOnly = false
    end
    self:Process(self.selected_unit)
end

function IModeAIDebug:ClearThreatUnits()
    const.RATOAI.ThreatOnly = false
    self:Process(self.selected_unit)
end

---- Marca SO este -- o caso de uso comum (isolar um) em um clique, em vez de desmarcar os outros
---- um a um.
function IModeAIDebug:SoloThreatUnit(arg)
    local idx = tonumber(arg)
    local id = idx and (self.dbg_threat_ids or empty_table)[idx]
    if not id then
        return
    end
    const.RATOAI.ThreatOnly = {[id] = true}
    self:Process(self.selected_unit)
end

---------------------------------------------------------------------------------------------------
-- Update -- copia do original + secao de camadas
---------------------------------------------------------------------------------------------------

local function link(func, arg, text, r, g, b)
    r, g, b = r or 0, g or 255, b or 255
    if arg then
        return string.format("<h %s %s 255 255 255><color %d %d %d>%s</color></h>", func,
                             tostring(arg), r, g, b, text)
    end
    return string.format("<h %s 255 255 255><color %d %d %d>%s</color></h>", func, r, g, b, text)
end

---------------------------------------------------------------------------------------------------
-- Update paginado
--
-- O painel do modo de debug e um XText de altura fixa no template do jogo; com muitas
-- acoes ou muitas policies o conteudo passava da tela e nao havia como chegar embaixo.
-- Em vez de mexer no layout (XScrollArea dentro deste modo nao colaborou), o conteudo
-- foi quebrado em paginas. E so string -- nao toca em janela nenhuma.
--
-- O cabecalho com as abas e sempre desenhado, entao qualquer pagina e alcancavel de
-- qualquer pagina.
---------------------------------------------------------------------------------------------------

local PAGES = {"Controles", "Unidade", "Destinos", "Alvo", "Acoes", "Camadas", "Perf"}

---- A pagina que abre por default e a que o "so <nome>" da barra restaura. Resolvida por
---- NOME e nao por indice: a ordem de PAGES ja mudou uma vez, e indice fixo faria o
---- default virar silenciosamente outra pagina na proxima vez que mudar.
local PAGE_DEFAULT = table.find(PAGES, "Unidade") or 1

---- Paginas ligadas quando o painel abre. Resolvidas por NOME e nao por indice, pela
---- mesma razao do PAGE_DEFAULT: a ordem de PAGES ja mudou uma vez, e indice fixo faria
---- o painel abrir em outra pagina sem ninguem perceber.
local PAGE_STARTUP = {"Controles", "Camadas"}

local function StartupPages()
    local on = {}
    for _, name in ipairs(PAGE_STARTUP) do
        local i = table.find(PAGES, name)
        if i then
            on[i] = true
        end
    end
    ---- nome errado em PAGE_STARTUP nao pode abrir o painel vazio
    if not next(on) then
        on[PAGE_DEFAULT] = true
    end
    return on
end

---- paginas ativas: conjunto {[indice] = true}. Varias podem ficar ligadas ao mesmo
---- tempo; sao concatenadas na ordem em que aparecem em PAGES.
local function EnabledPages(self)
    local on = self.dbg_pages
    if not on then
        on = StartupPages()
        self.dbg_pages = on
    end
    for i = 1, #PAGES do
        if on[i] then
            return on
        end
    end
    on[PAGE_DEFAULT] = true ---- nunca deixa tudo desligado
    return on
end

---- clique na aba liga/desliga aquela pagina
function IModeAIDebug:SetDebugPage(n)
    n = Clamp(tonumber(n) or 1, 1, #PAGES)
    local on = EnabledPages(self)
    on[n] = (not on[n]) or nil
    EnabledPages(self) ---- reacende a primeira se o clique apagou a ultima
    self:Update()
end

function IModeAIDebug:SetDebugPagesAll()
    local on = EnabledPages(self)
    for i = 1, #PAGES do
        on[i] = true
    end
    self:Update()
end

function IModeAIDebug:SetDebugPagesOnly(n)
    self.dbg_pages = {[Clamp(tonumber(n) or 1, 1, #PAGES)] = true}
    self:Update()
end

---- marcadores 3d que devem existir independente da pagina aberta
local function UpdateDestMarkers(self)
    local ctx = self.ai_context
    if not ctx then
        return
    end

    local best_dest = ctx.best_dest or ctx.unit_world_voxel
    if best_dest then
        self.best_voxel_fx = PlaceSquareFX(15 * guic, DestToPoint(best_dest), const.clrGreen,
                                           self.best_voxel_fx)
    end

    if ctx.closest_dest then
        self.fallback_voxel_fx = PlaceSquareFX(15 * guic, DestToPoint(ctx.closest_dest),
                                               const.clrMagenta, self.fallback_voxel_fx)
    end

    if ctx.best_end_dest then
        self.end_voxel_fx = PlaceSquareFX(10 * guic, DestToPoint(ctx.best_end_dest), const.clrCyan,
                                          self.end_voxel_fx)
    elseif self.end_voxel_fx then
        DoneObject(self.end_voxel_fx)
        self.end_voxel_fx = nil
    end
end

local function TabBar(self)
    local on = EnabledPages(self)
    local out = {}
    for i, name in ipairs(PAGES) do
        if on[i] then
            out[#out + 1] = link("SetDebugPage", i, "[" .. name .. "]", 0, 255, 0)
        else
            out[#out + 1] = link("SetDebugPage", i, name, 140, 140, 140)
        end
    end
    local bar = table.concat(out, " ")
    bar = bar .. "\n" .. link("SetDebugPagesAll", nil, "todas", 255, 200, 0)
    bar = bar .. "  " ..
              link("SetDebugPagesOnly", PAGE_DEFAULT, "so " .. PAGES[PAGE_DEFAULT], 255, 200, 0)
    return bar
end

---------------------------------------------------------------------------------------------------

local function PageUnidade(self, text)
    local ctx = self.ai_context

    text = text .. string.format("\n   Archetype: %s", self.selected_unit:GetArchetype().id)
    text = text .. string.format("\n   AI Keywords: %s",
                                 table.concat(self.selected_unit.AIKeywords or empty_table, ","))
    text = text .. string.format("\n   Behavior: %s", ctx.behavior:GetEditorView())

    text = text .. "\n\n<color 255 200 0>Behaviors</color> (clique para forcar):"
    for _, data in ipairs((self.think_data or empty_table).behaviors or empty_table) do
        local score_text
        if data.disabled then
            score_text = "disabled"
        elseif data.priority then
            score_text = "priority"
        else
            score_text = data.score and tostring(data.score) or "N/A"
        end
        text = text ..
                   string.format("\n  %s: %s",
                                 link("UnitForceBehavior", data.index, data.name, 255, 255, 0),
                                 score_text)
    end

    text = text .. "\n\n<color 255 200 0>Tempos</color>:"
    for _, step in ipairs((self.think_data or empty_table).thihk_steps or empty_table) do
        text = text .. string.format("\n  %s: %s ms", step.label, tostring(step.time))
    end
    text = text .. string.format("\n  StartAI: %s ms", tostring(self.time_start_ai))

    text = text .. "\n\nVoxel atual: " .. self:FormatVoxelHyperlink(ctx.unit_world_voxel)
    return text
end

---------------------------------------------------------------------------------------------------
-- FORCAR O DESTINO (E A POSTURA) DO TURNO
--
-- Para que serve: montar a situacao especifica em vez de esperar ela acontecer. Colocar a unidade
-- num tile onde sobra EXATAMENTE o AP que se quer testar -- por exemplo o suficiente para stance e
-- nao para o tiro, que e o cenario do PrepareWeapon.
--
-- SO ENTRE OS CANDIDATOS DA PROPRIA IA, e isso nao e limitacao preguicosa. O AIBehavior:BeginMovement
-- (AIBehaviors.lua:143) le `context.dest_combat_path[dest]` e `context.combat_paths[...]` para
-- montar o caminho, e o `context.dest_ap[dest]` e o orcamento que todo o resto assume. Um tile
-- fora de `context.destinations` nao tem nada disso: o movimento falharia ou -- pior -- rodaria
-- com AP inventado, e o turno "forcado" voltaria a ser ficcao. Que e exatamente o defeito que o
-- UnitExecuteTurn fiel acabou de consertar.
--
-- A POSTURA vem de graca: `context.destinations` guarda pos+postura empacotadas juntas, entao o
-- mesmo tile costuma aparecer mais de uma vez, uma por postura viavel. Cada uma vira um link.
--
-- Como usar: passe o mouse no tile, va na pagina Destinos, clique na postura. Depois Execute Turn.
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- PENDENTE (2026-08-23): O DESTINO FORCADO NEM SEMPRE E OBEDECIDO.
--
-- Relatado em campo: fixa o tile, escolhe a postura, Execute Turn -- e a unidade vai para outro
-- lugar. Registrado com o que ja foi MEDIDO, para a proxima investigacao nao repetir trabalho.
--
-- DESCARTADO, com medicao no processo vivo: "o contexto do painel e uma copia". NAO e.
--     dlg.ai_context == unit.ai_context  ->  true
--     endereco dlg = table: 000001D6C2737C88 = endereco unit
--     (escrito um campo pelo lado do painel, lido pelo lado da unidade: chegou)
-- Em Lua tabela e referencia; `self.ai_context = context` (IModeAIDebug.lua:145) so cria outro
-- nome para a mesma tabela. Escrever `context.ai_destination` chega na unidade.
--
-- HIPOTESE PRINCIPAL -- nao e copia, e SUBSTITUICAO. O Process (IModeAIDebug.lua:141-147) faz:
--     unit.ai_context = nil          -- descarta o contexto antigo
--     unit:StartAI(...)              -- cria um NOVO
--     self.ai_context = <novo>
--     context.behavior:Think(unit, ...)   -- e o Think RECALCULA ai_destination
-- Ou seja, qualquer Process entre a escolha e o Execute Turn (a) joga fora a tabela em que se
-- escreveu e (b) recomputa o destino por conta propria. O `ratodbg_forced_dest` vive no PAINEL e
-- sobrevive a isso -- mas o RATODBG_ForcedDest so o aplica se ele ainda constar de
-- `context.destinations`, e a lista nova pode nao te-lo. Nesse caso ele desiste, de proposito,
-- porem em silencio para quem nao esta lendo o painel.
--     Como checar: apos escolher, confirmar se o painel marca `(sumiu do think atual)` em
--     vermelho. Se marcar, e isto, e a decisao passa a ser de produto: reprojetar o destino
--     forcado para o tile+postura mais proximo da nova lista, ou bloquear o Process enquanto
--     houver destino forcado.
--
-- HIPOTESE SECUNDARIA: TakeStance zera o destino. AIBehaviors.lua:130 faz
-- `context.ai_destination = false` quando o AIPlayChangeStance falha no ramo de movimento. Se a
-- postura forcada nao for a que o `dest_combat_path` previu para aquele caminho, o destino
-- evapora em silencio. Como checar: logar `context.ai_destination` antes e depois do TakeStance.
--
-- HIPOTESE TERCIARIA: o link nao chega no handler. `link("ForceDest", i, ...)` depende da
-- convencao <h Nome ...> mapear para IModeAIDebug:ForceDest. Como checar: printf no ForceDest.
---------------------------------------------------------------------------------------------------

---- opcoes do ultimo desenho, indexadas por numero -- mesmo padrao do UnitForceAction do jogo.
---- Passar o valor empacotado direto no link seria fragil: sao inteiros grandes e o parser de
---- <h ...> os trata como texto.
local function OpcoesNoVoxel(self)
    local ctx = self.ai_context
    if not ctx or not self.ratodbg_pinned_voxel then
        return
    end
    local vx, vy = point_unpack(self.ratodbg_pinned_voxel)
    local out = {}
    for _, dest in ipairs(ctx.destinations or empty_table) do
        local x, y, z, si = stance_pos_unpack(dest)
        ---- compara so x,y: o z do voxel sob o cursor e o do slab, e o do destino pode vir da
        ---- altura do terreno. Em mapa de varios andares isto pode listar os dois -- e o `z` no
        ---- rotulo desempata visualmente.
        if x == vx and y == vy then
            out[#out + 1] = {
                dest = dest,
                stance = StancesList[si] or ("?" .. tostring(si)),
                z = z,
                ap = ctx.dest_ap and ctx.dest_ap[dest]
            }
        end
    end
    self.ratodbg_force_opts = out
    return out
end

function IModeAIDebug:ForceDest(index)
    local o = self.ratodbg_force_opts and self.ratodbg_force_opts[tonumber(index)]
    if o then
        self.ratodbg_forced_dest = o.dest
    end
    self:Update()
end

function IModeAIDebug:ClearForceDest()
    self.ratodbg_forced_dest = nil
    self.ratodbg_pinned_voxel = nil
    self:Update()
end

---- Devolve o destino forcado se ele AINDA existe na lista de candidatos. O Process refaz o think
---- e recalcula `context.destinations`; um destino guardado de antes pode ter sumido, e usa-lo
---- levaria de volta ao turno ficticio. Valida na hora de usar, nao na hora de escolher.
function RATODBG_ForcedDest(self, context)
    local dest = self.ratodbg_forced_dest
    if not dest or not context then
        return
    end
    for _, d in ipairs(context.destinations or empty_table) do
        if d == dest then
            return dest
        end
    end
end

function RATODBG_ForceDestBlock(self)
    local NL = string.char(10)
    local ctx = self.ai_context
    local text = NL .. NL .. "<color 255 200 0>Forcar destino</color>"

    local atual = self.ratodbg_forced_dest
    if atual then
        local x, y, z, si = stance_pos_unpack(atual)
        local valido = RATODBG_ForcedDest(self, ctx)
        text = text .. NL ..
                   string.format("  atual: %d,%d %s  ap=%s %s   %s", x, y,
                                 tostring(StancesList[si]),
                                 tostring(ctx and ctx.dest_ap and ctx.dest_ap[atual]),
                                 valido and "" or "<color 255 80 80>(sumiu do think atual)</color>",
                                 link("ClearForceDest", nil, "[limpar]", 255, 150, 150))
    else
        text = text .. NL .. "  <color 130 130 130>(nenhum -- a IA escolhe)</color>"
    end

    if not self.ratodbg_pinned_voxel then
        text = text .. NL ..
                   "  <color 130 130 130>clique com o BOTAO ESQUERDO num tile do mapa para" ..
                   " escolher a postura</color>"
        return text
    end

    local px, py = point_unpack(self.ratodbg_pinned_voxel)
    local opts = OpcoesNoVoxel(self)

    if not opts or #opts == 0 then
        text = text .. NL ..
                   string.format(
                       "  tile %d,%d: <color 255 80 80>nao esta entre os destinos que a" ..
                           " IA calculou</color>   %s", px, py,
                       link("ClearForceDest", nil, "[limpar]", 255, 150, 150))
        return text
    end

    text = text .. NL .. string.format("  tile fixado %d,%d:", px, py)
    for i, o in ipairs(opts) do
        local rotulo = string.format("%s (ap %s, z %s)", o.stance, tostring(o.ap), tostring(o.z))
        if o.dest == atual then
            text = text .. NL .. string.format("    <color 0 255 0>%s [forcado]</color>", rotulo)
        else
            text = text .. NL .. "    " .. link("ForceDest", i, rotulo, 255, 255, 0)
        end
    end
    return text
end

local function PageDestinos(self, text)
    local ctx = self.ai_context
    local td = self.think_data or empty_table

    local best_dest = ctx.best_dest or ctx.unit_world_voxel
    text = text .. "\n\n<color 0 255 0>Best</color> dest: " .. self:FormatDestHyperlink(best_dest)
    text = text .. string.format("\nBest voxel score: %d", ctx.best_score or 0)
    local best_scores = (td.optimal_scores or empty_table)[best_dest] or empty_table
    for i = 1, #best_scores - 1, 2 do
        text = text .. string.format("\n  %s: %d", best_scores[i], best_scores[i + 1])
    end

    if ctx.best_end_dest then
        text = text .. "\n\n<color 0 255 255>End Turn</color> dest: " ..
                   self:FormatDestHyperlink(ctx.best_end_dest)
        text = text .. string.format("\nEnd Turn voxel score: %d", ctx.best_end_score or 0)
        local reach_scores = (td.reachable_scores or empty_table)[ctx.best_end_dest] or empty_table
        for i = 1, #reach_scores - 1, 2 do
            text = text .. string.format("\n  %s: %d", reach_scores[i], reach_scores[i + 1])
        end
    end

    if ctx.closest_dest then
        text = text .. "\n\n<color 255 0 255>Fallback</color> dest: " ..
                   self:FormatDestHyperlink(ctx.closest_dest)
    end

    if ctx.ai_destination and ctx.dbg_enemy_damage_score then
        text = text .. "\n\n<color 255 200 0>Alvos potenciais</color>:"
        local target_scores = {}
        for target, score in pairs(ctx.dbg_enemy_damage_score) do
            table.insert(target_scores, {target = target, score = score})
        end
        table.sortby_field_descending(target_scores, "score")
        for _, ts in ipairs(target_scores) do
            text = text .. string.format("\n  %s: %d", ts.target.session_id, ts.score)
        end
    end

    text = text .. RATODBG_ForceDestBlock(self)

    return text
end

---------------------------------------------------------------------------------------------------
-- RESULTADO ESPERADO POR ACAO  (do Rato's AI Overhaul)
--
-- Responde "por que este peso" para as acoes que usam o scoring por resultado. O peso mostrado
-- acima ja e o produto (Weight do preset x razao); aqui ficam as DUAS pontas que produziram a
-- razao e os insumos de cada uma.
--
-- Le so o que o mod ja deixou no context (ctx.dbg_expected, ctx.dbg_aim_plan). Nao chama nada e
-- nao recalcula -- se recalculasse, mostraria um numero diferente do que a IA usou, que e o
-- unico jeito de um painel de debug mentir. Com o Overhaul desligado (ou antigo) as tabelas nao
-- existem e o bloco some sozinho.
--
-- NL em vez de escape: o resto deste arquivo usa "\n" normalmente; aqui ele esta como
-- string.char(10) porque o bloco foi gerado por ferramenta e o escape nao sobreviveu ao caminho.
-- Funcionalmente identico.
--
-- Como ler:
--   acertos = soma de CTH sobre todos os disparos que cabem no AP, /100. "padrao" e a mesma
--             conta para o ataque basico, e e o denominador da razao.
--   razao   = 100 significa "rende igual a so atirar". 170 = rende 70% mais. 0 = desabilita.
--   miras   = nivel de mira de cada ataque planejado. A AutoFire tem teto 1 por natureza.
--   MIRA    = o replan (RATOAI_AimReplan): que nivel a heuristica de distancia queria, qual o
--             resultado escolheu, e os acertos de cada nivel avaliado. Descer de mira paga a
--             margem; subir nao, porque a mira compra critico e a conta nao ve critico.
---------------------------------------------------------------------------------------------------
function RATODBG_ExpectedBlock(ctx)
    local exp, plan = ctx.dbg_expected, ctx.dbg_aim_plan
    if not exp and not plan then
        return ""
    end

    local NL = string.char(10)
    local text = NL .. NL .. "<color 255 200 0>Resultado esperado</color>"

    if plan then
        local trocou = plan.best ~= plan.heur
        local escolha =
            trocou and string.format("<color 0 255 0>m%s</color>", tostring(plan.best)) or
                string.format("m%s (mantida)", tostring(plan.best))
        text = text .. NL ..
                   string.format("  MIRA heuristica m%s (%d.%02d) -> %s (%d.%02d)  margem %d%%",
                                 tostring(plan.heur), (plan.base or 0) / 100,
                                 (plan.base or 0) % 100, escolha, (plan.hits or 0) / 100,
                                 (plan.hits or 0) % 100, plan.margem or 0)
        if plan.planos then
            text = text .. NL .. string.format("       planos: %s", plan.planos)
        end
    end

    for id, e in sorted_pairs(exp or empty_table) do
        ---- `ratio` nil = a linha nao chegou a comparar nada (limiar desligado pela constante, ou
        ---- uma CustomScoring booleana que so tem `motivo`). Mostrar "razao 0" ali seria inventar
        ---- um numero: 0 quer dizer "nao rende nada", que e uma afirmacao.
        local ratio = e.ratio
        local rotulo = ratio and string.format("razao %d", ratio) or "sem razao"
        local par = ""
        if ratio then
            par = string.format("  (%d.%02d vs padrao %d.%02d)", (e.hits or 0) / 100,
                                (e.hits or 0) % 100, (e.base or 0) / 100, (e.base or 0) % 100)
            ---- DEBUG (D6): no MGSetup/PrepareWeapon o numerador e o LIMIAR, nao uma medicao --
            ---- aquelas acoes nao disparam, entao nao ha o que medir. Marcado para ninguem ler o
            ---- primeiro numero como acertos observados.
            if e.proxy then
                par = par .. "  <color 130 130 130>limiar-proxy</color>"
            end
        end

        text = text .. NL ..
                   string.format("  %s: <color %s>%s</color>%s", tostring(id), RatioColorTag(ratio),
                                 rotulo, par)

        ---- DEBUG (D7): o A/B da mudanca de modelo. `razao` acima ja e a NOVA (turno contra
        ---- turno); esta linha abre o numerador e mostra a ANTIGA (N ataques da candidata) ao
        ---- lado, que e o numero contra o qual os `Weight` dos presets foram calibrados.
        ---- Some sozinha quando a recalibragem terminar e o campo deixar de ser gravado.
        local tn = e.turno
        if tn then
            ---- AP em unidade de tela. O engine guarda AP x const.Scale.AP (1000), e `/` neste
            ---- Lua e divisao INTEIRA -- 8380/1000 daria "8" e comeria justamente a fracao que
            ---- decide se mais um disparo cabe. Parte inteira e centesimos, separados.
            local escala = const.Scale.AP
            local function ap(v)
                v = v or 0
                return string.format("%d.%02d", v / escala, (v % escala) * 100 / escala)
            end
            ---- o denominador, escrito por extenso -- e contra ELE que a razao e formada
            text = text .. NL .. string.format(
                       "       <color 150 150 150>denominador: %d.%02d  (%s ataques do padrao com %s AP)</color>",
                       (e.base or 0) / 100, (e.base or 0) % 100, tostring(tn.m or "?"),
                       ap(tn.ap_total))

            if tn.sustentado then
                text = text .. NL .. string.format(
                           "       <color 150 200 150>sustentada: %d.%02d  (%s ataques dela, sustenta o modo o turno todo)</color>",
                           (tn.sozinha or 0) / 100, (tn.sozinha or 0) % 100, tostring(tn.n or "?"))
            else
                local total = (tn.primeiro or 0) + (tn.resto or 0)
                text = text .. NL .. string.format(
                           "       <color 200 180 140>turno: %d.%02d (1 dela) + %d.%02d (%s do padrao com %s AP) = %d.%02d</color>",
                           (tn.primeiro or 0) / 100, (tn.primeiro or 0) % 100,
                           (tn.resto or 0) / 100, (tn.resto or 0) % 100, tostring(tn.k or "?"),
                           ap(tn.ap_left), total / 100, total % 100)
                if e.ratio_antigo then
                    text = text .. NL .. string.format(
                               "       <color 130 130 130>modelo antigo: razao %d  (%d.%02d = %s ataques dela, turno que nao acontece)</color>",
                               e.ratio_antigo, (tn.sozinha or 0) / 100, (tn.sozinha or 0) % 100,
                               tostring(tn.n or "?"))
                end
            end
        end

        local d = e.trace

        ---- DEBUG (D4): CONTRA QUEM. O estimador nao escolhe alvo, ele recebe o
        ---- `dest_target[dest]`; sem esta linha "0 acertos" nao se distingue de "0 acertos
        ---- contra o alvo errado". O `alvo` vem do trace do RATOAI_ExpectedFor ou, nas
        ---- CustomScoring que montam a linha a mao (MGSetup, PrepareWeapon), do proprio `e`.
        local alvo = (d and d.alvo) or e.alvo
        local dist = (d and d.dist) or e.dist
        if alvo then
            text = text .. NL ..
                       string.format("       <color 180 200 255>alvo: %s</color>%s", tostring(alvo),
                                     dist and string.format("  (%d tiles)", dist / const.SlabSizeX) or
                                         "")
        end

        if d then
            text = text .. NL ..
                       string.format(
                           "       custo %d AP  balas %s  ataques %s  miras %s  recoil %s",
                           (d.cost or 0) / 1000, tostring(d.shots), tostring(d.attacks),
                           tostring(d.aims), d.recoil and tostring(d.recoil) or "-")
            if d.cth then
                text = text .. NL .. string.format("       CTH por nivel: %s", d.cth)
            end
        elseif e.motivo then
            ---- DEBUG (D6): antes so aparecia com `hits == 0` -- o MGSetup/PrepareWeapon
            ---- tambem tem motivo a dizer quando JA rende (hits >= limiar), e a mudanca que
            ---- passou a gravar esse ramo (ver RegistrarExpectedMG) ficaria muda sem isto.
            text = text .. NL ..
                       string.format("       <color 130 130 130>(%s)</color>", tostring(e.motivo))
        end

        ---- DEBUG (D6): PESO, separado da RAZAO. `razao` acima e sempre hits/base x100 -- "quanto
        ---- rende" --, nunca o peso do preset. `peso_base -> peso_final` e o outro numero, o que
        ---- de fato entra na roleta do AISelectAction (ver pagina Acoes). So aparece quando a
        ---- CustomScoring gravou (MGSetup, PrepareWeapon); as demais acoes nao multiplicam peso
        ---- aqui dentro, esse trabalho e feito depois, fora da CustomScoring.
        if e.peso_final ~= nil then
            local mudou = e.peso_base ~= e.peso_final
            text = text .. NL .. string.format("       peso: %d%s", e.peso_base or 0, mudou and
                                                   string.format(" -> <color 0 255 0>%d</color>",
                                                                 e.peso_final) or " (sem alteracao)")
        end
        if e.stance ~= nil or e.base_stance ~= nil then
            text = text .. NL ..
                       string.format(
                           "       <color 130 130 130>prepara arma: acao=%s padrao=%s</color>",
                           tostring(e.stance), tostring(e.base_stance))
        end
    end

    return text
end

---------------------------------------------------------------------------------------------------
-- POR QUE A ACAO ESTA CINZA
--
-- Peso e disponibilidade sao portoes DIFERENTES e independentes, e a pagina mostrava so o peso.
-- Dava para ver "razao 87" (peso perfeitamente bom) numa acao cinza sem nenhuma forma de saber
-- o motivo.
--
-- AISignatureAction:IsAvailable roda DEPOIS do CustomScoring e do PrecalcAction, e para as
-- acoes de tiro (AIActions.lua:753) exige tres coisas de uma vez:
--     has_ap    -- cabe no AP. ATENCAO: este custo vem do AIGetAttackArgs, que monta `args` com
--                  alvo e mira, entao ele JA INCLUI o AP de shooting stance -- e portanto e
--                  MAIOR que o custo nu (action:GetAPCost(unit)) que o scoring por resultado
--                  usa para comparar modos de tiro entre si.
--     has_ammo  -- `results.fired` do GetActionResults. Uma rajada de 15 exige 15 no pente.
--     can_hit   -- chance_to_hit > 0 no GetActionResults.
--
-- Le so o action_state que o proprio AISelectAction ja gravou. Nao recalcula nada -- recalcular
-- aqui poderia dar outra resposta que a que a IA usou, que e o unico jeito de um painel mentir.
---------------------------------------------------------------------------------------------------
local function IndisponivelPorque(ctx, action)
    local st = action and ctx.action_states and ctx.action_states[action]
    if not st then
        return ""
    end
    local faltas = {}
    if st.has_ap == false then
        faltas[#faltas + 1] = "AP"
    end
    if st.has_ammo == false then
        faltas[#faltas + 1] = "municao"
    end
    if st.can_hit == false then
        faltas[#faltas + 1] = "CTH zero"
    end
    if st.args and not IsValidTarget(st.args.target) then
        faltas[#faltas + 1] = "alvo invalido"
    end
    if #faltas == 0 then
        ---- o PrecalcAction so avalia municao e CTH quando has_ap passa; entao "nenhuma falta"
        ---- numa acao cinza normalmente quer dizer que ela nem chegou a ser testada.
        return (st.has_ap == nil) and "  <color 130 130 130>[nao avaliada]</color>" or ""
    end
    return string.format("  <color 255 80 80>[falta: %s]</color>", table.concat(faltas, ", "))
end

local function PageAcoes(self, text)
    local ctx = self.ai_context

    if not ctx.choose_actions or #ctx.choose_actions == 0 then
        return text .. "\n\n(sem acoes avaliadas)"
    end

    ---- total para mostrar a fatia de cada uma na roleta
    local total = 0
    for _, descr in ipairs(ctx.choose_actions) do
        if not descr.priority then
            total = total + Max(0, descr.weight or 0)
        end
    end

    text = text ..
               string.format("\n\n<color 255 200 0>Acoes</color> (%d) -- clique para forcar",
                             #ctx.choose_actions)
    text = text .. string.format("\npeso total: %d", total)

    for i, descr in ipairs(ctx.choose_actions) do
        local action_name = descr.action and descr.action:GetEditorView() or "Base Attack"
        local val
        if descr.priority then
            val = "PRIORITY"
        elseif descr.weight == false then
            ---- DEBUG (D5): `false` cru na tela nao dizia nada. Sao dois estados diferentes e
            ---- agora eles se chamam pelo nome -- ver o marcador em SOURCE_AISelectAction.lua.
            val = descr.disabled_by and "desabilitada" or "indisponivel"
        elseif total > 0 then
            val = string.format("%d  (%d%%)", descr.weight or 0,
                                MulDivRound(Max(0, descr.weight or 0), 100, total))
        else
            val = tostring(descr.weight)
        end

        ---- DEBUG (D5): desabilitada NAO passou pelo PrecalcAction, entao o action_state esta
        ---- vazio e o IndisponivelPorque so poderia dizer "[nao avaliada]" -- que e verdade e e
        ---- inutil. Quem sabe o motivo e quem desabilitou.
        local motivo
        if descr.disabled_by == "CustomScoring" then
            motivo = "  <color 255 140 60>[desabilitada pela CustomScoring]</color>"
        elseif descr.disabled_by then
            motivo = "  <color 255 140 60>[desabilitada pelo bias]</color>"
        else
            motivo = IndisponivelPorque(ctx, descr.action)
        end

        if self.forced_action == i then
            text = text .. string.format("\n  <color 0 255 0>%s: %s</color>", action_name, val)
        elseif (descr.weight or 0) > 0 or descr.priority then
            text = text .. "\n  " ..
                       link("UnitForceAction", i, string.format("%s: %s", action_name, val), 255,
                            255, 0)
        else
            text = text ..
                       string.format("\n  <color 130 130 130>%s: %s</color>%s", action_name, val,
                                     motivo)
        end
    end

    text = text .. RATODBG_ExpectedBlock(ctx)

    return text
end

---------------------------------------------------------------------------------------------------
-- LINHAS DE INFLUENCIA POR INIMIGO  (rollover)
--
-- Passe o mouse num tile e cada inimigo puxa uma linha ate ele, com o NUMERO da
-- contribuicao daquele inimigo para o score do tile e a cor da mesma escala divergente
-- das camadas (ScoreColor): vermelho = tira score, mint/amarelo = poe score, saturacao
-- = magnitude.
--
-- Tres modos:
--   threat -- so a AIPolicyThreatExposure   (sempre <= 0)
--   cover  -- so a AIPolicyCustomSeekCover  (>= 0, salvo ExposedAtCloseRange)
--   sum    -- os dois somados por inimigo. Este e o que responde "contra QUEM este tile
--             me protege e contra quem nao", que o agregado do tile sozinho nao
--             responde.
--
-- COMO O NUMERO E OBTIDO -- e a parte que importa para ele nao mentir:
--
--   1. peso bruto por inimigo, chamando as MESMAS funcoes que as policies chamam
--      (RATOAI_ThreatRamp + GetEnemyRange; GetCoverScore), nunca uma copia da formula;
--   2. o EvalDest REAL da policy e entao RATEADO sobre esses pesos.
--
-- O passo 2 e o que faz o painel acompanhar sozinho qualquer mudanca de normalizacao
-- (presence, ThreatRelative, clamp de saturacao, Weight): daqui sai so a PROPORCAO
-- entre inimigos; o total vem da policy. Reimplementar a formula aqui era o caminho
-- curto e seria o primeiro lugar a divergir em silencio.
--
-- O valor mostrado ja inclui o `Weight` da policy -- e a mesma quantidade que o
-- score_details guarda e que as camadas pintam, entao a soma das linhas bate com o
-- numero que a camada escreve no tile.
---------------------------------------------------------------------------------------------------

---- alturas das duas pontas da linha. A do inimigo na altura do peito (o spheroid de
---- pathfind tem 165cm) para a linha nao afundar no terreno; a do tile rente ao chao,
---- logo acima do quadrado da camada (que fica em 5*guic).
local INFL_Z_ENEMY = 110 * guic
local INFL_Z_TILE = 25 * guic

---- fracao do caminho, do tile para o inimigo, onde o numero e escrito. Perto do tile
---- as linhas convergem e os rotulos se empilham; a 65% elas ja se abriram.
local INFL_LABEL_AT = 65

local function InflValidZ(pt)
    return pt:IsValidZ() and pt or pt:SetTerrainZ()
end

local function PlaceLineFX(p1, p2, color)
    local path = pstr("")
    path:AppendVertex(p1, color)
    path:AppendVertex(p2)
    local line = PlaceObject("Polyline")
    line:SetPos(p1)
    line:SetMesh(path)
    return line
end

local function FindPolicy(list, class)
    for _, pol in ipairs(list or empty_table) do
        if IsKindOf(pol, class) then
            return pol
        end
    end
end

---- As duas policies usam exatamente este gate. Replicado porque nao da para perguntar
---- a elas "voce contaria este inimigo?" sem rodar o EvalDest inteiro -- e o EvalDest
---- devolve o agregado, que e justamente o que estamos abrindo.
local function PolicySeesEnemy(pol, context, enemy)
    if pol.visibility_mode == "self" then
        return context.enemy_visible[enemy]
    elseif pol.visibility_mode == "team" then
        return context.enemy_visible_by_team[enemy]
    end
    return true
end

---- peso bruto de cada inimigo na AIPolicyThreatExposure
---- Dois cuidados na chamada da rampa:
----   * GetEnemyRange devolve DOIS valores (range, is_firearm), e em Lua o multi-retorno
----     na ultima posicao de argumento EXPANDE -- sem os parenteses o booleano cai no
----     parametro `plateau`, e o `dist <= plateau` dentro de RATOAI_ThreatRamp compara
----     numero com booleano e estoura. So nao aparecia porque ThreatRaw e do ramo de
----     DUAS policies, e o CoverCancels vem ligado por default.
----   * o plateau precisa ser passado de verdade: sem ele este "bruto" ignora o
----     PlateauTiles e diverge da propria policy que ele diz estar decompondo.
local function ThreatRaw(pol, context, dest, target_pos)
    local raw = {}
    local plateau = (pol.PlateauTiles or 0) * const.SlabSizeX
    for _, enemy in ipairs(context.enemies or empty_table) do
        local alive = IsValid(enemy) and not (enemy:IsDead() or enemy:IsDowned())
        if alive and PolicySeesEnemy(pol, context, enemy) then
            local att_pos = InflValidZ(enemy:GetPos())
            if IsValidPos(att_pos) then
                raw[enemy] = RATOAI_ThreatRamp(att_pos:Dist(target_pos), (pol:GetEnemyRange(enemy)),
                                               plateau)
            end
        end
    end
    return raw
end

---- peso bruto de cada inimigo na AIPolicyCustomSeekCover: c_i * w_i, o proprio termo
---- que a policy acumula no numerador
local function CoverRaw(pol, context, dest, grid_voxel)
    local raw = {}
    local _, _, _, stance_idx = stance_pos_unpack(dest)
    local ustance = StancesList[stance_idx]
    for _, enemy in ipairs(context.enemies or empty_table) do
        if IsValid(enemy) and PolicySeesEnemy(pol, context, enemy) then
            local cover, weight = pol:GetCoverScore(context, enemy, context.unit, dest, nil,
                                                    grid_voxel, ustance)
            raw[enemy] = (cover or 0) * (weight or 0)
        end
    end
    return raw
end

---- rateia o EvalDest real (ja com Weight) sobre os pesos brutos
local function InfluenceShares(pol, context, dest, grid_voxel, raw)
    local total_raw = 0
    for _, v in pairs(raw) do
        total_raw = total_raw + v
    end
    local eval = pol:EvalDest(context, dest, grid_voxel) or 0
    local total = MulDivRound(eval, pol.Weight or 100, 100)

    ---- soma dos brutos em zero: ou ninguem pesa, ou os sinais se cancelaram
    ---- (ExposedAtCloseRange negativo contra cobertura positiva). Ratear por zero
    ---- inventaria numero -- melhor devolver nada e dizer que nao ha rateio.
    if total_raw == 0 then
        return {}, total, false
    end

    local out, assigned, biggest, biggest_v = {}, 0, nil, 0
    for enemy, v in pairs(raw) do
        if v ~= 0 then
            local share = MulDivRound(total, v, total_raw)
            out[enemy] = share
            assigned = assigned + share
            if not biggest or abs(v) > abs(biggest_v) then
                biggest, biggest_v = enemy, v
            end
        end
    end

    ---- sobra de arredondamento no maior termo. Sem isto a soma das linhas erra o total
    ---- do tile por alguns pontos -- e um painel de conferencia que nao fecha a conta e
    ---- pior do que painel nenhum: vira mais uma coisa para desconfiar.
    if biggest and assigned ~= total then
        out[biggest] = out[biggest] + (total - assigned)
    end

    return out, total, true
end

---- Policy de ameaca do escopo ativo, e se ela esta no regime CoverCancels. Usado tanto
---- pelo desenho quanto pelos rotulos do painel, para os dois nunca discordarem.
---------------------------------------------------------------------------------------------------
---- DECOMPOSICAO -- nucleo compartilhado pelo TILE e pelas LINHAS
----
---- Um so lugar calcula, para um destino: quanto de ameaca BRUTA existe ali, quanto a
---- cobertura CANCELOU, e quanto sobra LIQUIDO. A camada de mapa e as linhas de rollover
---- consomem exatamente esta funcao -- e o que garante que o numero pintado no slab e a
---- soma das linhas que saem dele sejam o MESMO numero. Enquanto eram dois caminhos de
---- calculo, nada impedia de divergirem em silencio.
----
---- Funciona nos dois regimes:
----
----   CoverCancels LIGADO  -- uma policy so. `bruta` e a rampa crua, `liquida` e a rampa
----     ja descontada da cobertura, e cada total passa pela normalizacao da PROPRIA
----     policy (mesma saturacao, mesmo clamp, mesmo Weight).
----
----   CoverCancels DESLIGADO -- duas policies. `bruta` e a AIPolicyThreatExposure e
----     `cancelada` e a AIPolicyCustomSeekCover, cada uma com o EvalDest dela. E o que a
----     antiga camada "Soma" mostrava, agora decomposta em vez de so somada.
----
---- TOTAIS: cada componente e normalizado pela formula da policy, e nao por rateio de um
---- sobre o outro. Isso remove a singularidade do caso "cobertura cancelou tudo" (a soma
---- liquida vai a zero e nao havia por onde dividir) e faz `bruta + cancelada = liquido`
---- valer sempre, por construcao -- `cancelada` e DEFINIDA como a diferenca.
---------------------------------------------------------------------------------------------------

---- normalizacao da AIPolicyThreatExposure aplicada a uma soma de rampas qualquer:
---- e a mesma linha do EvalDest dela, incluindo clamp de saturacao e Weight
local function ThreatNormalize(pol, soma)
    if not soma or soma <= 0 then
        return 0
    end
    local sat = pol:GetSaturation()
    return MulDivRound(MulDivRound(pol.Penalty, Min(soma, sat), sat), pol.Weight or 100, 100)
end

---- Devolve: totais {bruta, cancelada, liquida} e as tabelas por inimigo de cada um.
---- `nil` no primeiro retorno = nao ha policy para responder neste escopo.
local function Decompose(threat_pol, cover_pol, context, dest, grid_voxel)
    if not dest then
        return nil
    end
    local target_pos = InflValidZ(DestToPoint(dest))
    if not IsValidPos(target_pos) then
        return nil
    end

    -----------------------------------------------------------------------------------
    ---- regime de UMA policy
    -----------------------------------------------------------------------------------
    if threat_pol and threat_pol.CoverCancels then
        local _, _, _, stance_idx = stance_pos_unpack(dest)
        local stance = StancesList[stance_idx]
        local plateau = (threat_pol.PlateauTiles or 0) * const.SlabSizeX

        ---------------------------------------------------------------------------
        ---- Estes tres eram OMITIDOS aqui e aplicados no EvalDest, entao o painel e a
        ---- policy davam numeros diferentes para o mesmo tile -- exatamente o que o
        ---- cabecalho desta secao existe para impedir. `curve` ficou de fora desde
        ---- sempre; `ThreatEffectMods` e o custo de preparo entraram depois e ninguem
        ---- propagou. Resolvido uma vez, fora do laco.
        ---------------------------------------------------------------------------
        local curve = Clamp(threat_pol.FalloffCurve or 0, 0, 100)
        local setup = threat_pol.SetupBias and (const.RATOAI.ThreatSetupBias ~= false)
        local ready_pct, costly_pct
        if setup then
            ready_pct = (threat_pol.SetupReadyPct or 0) > 0 and threat_pol.SetupReadyPct or
                            (const.RATOAI.ThreatSetupReady or 100)
            costly_pct = (threat_pol.SetupCostlyPct or 0) > 0 and threat_pol.SetupCostlyPct or
                             (const.RATOAI.ThreatSetupCostly or 100)
            if ready_pct == 100 and costly_pct == 100 then
                setup = false
            end
        end

        ---- BUGFIX (B49): teto de um inimigo so. Sai da propria policy para os dois lados
        ---- nunca discordarem -- e o mesmo motivo de `ThreatNormalize` chamar GetSaturation.
        local ceiling = threat_pol:GetEnemyCeiling()

        local bruta, cancelada, liquida = {}, {}, {}
        local sb, sl = 0, 0
        for _, enemy in ipairs(context.enemies or empty_table) do
            local alive = IsValid(enemy) and not (enemy:IsDead() or enemy:IsDowned())
            ---- DEBUG (D8): mesmo filtro de isolamento que a policy usa. Sem ele o painel
            ---- mostraria ameaca de quem o filtro tirou da conta.
            if alive and RATOAI_ThreatCounts(enemy) and
                PolicySeesEnemy(threat_pol, context, enemy) then
                local att_pos = InflValidZ(enemy:GetPos())
                if IsValidPos(att_pos) then
                    local range, is_firearm = threat_pol:GetEnemyRange(enemy)
                    local d = att_pos:Dist(target_pos)
                    local ramp = RATOAI_ThreatRamp(d, range, plateau, curve)
                    local unc = 100
                    if ramp > 0 then
                        ---- `d` explicito: o GetUncovered precisa da distancia para a
                        ---- rampa de CoverNearTiles e, sem receber, recalcula a mesma
                        ---- Dist() que a linha acima ja pagou
                        unc = threat_pol:GetUncovered(att_pos, target_pos, stance, is_firearm, d)
                    end

                    ---- Os fatores por inimigo (status effect, custo de preparo) escalam a
                    ---- ameaca DELE, e por isso entram nos DOIS lados -- bruta e liquida.
                    ---- Aplicar so na liquida jogaria o efeito deles dentro de `cancelada`,
                    ---- que quer dizer "o que a COBERTURA tirou" e passaria a mentir.
                    local mods = RATOAI_ThreatEnemyFactor(enemy, context)
                    if setup then
                        mods = MulDivRound(mods, RATOAI_SetupFactor(enemy, context, target_pos,
                                                                    ready_pct, costly_pct), 100)
                    end

                    local raw = (mods == 100) and ramp or MulDivRound(ramp, mods, 100)
                    local net = MulDivRound(raw, unc, 100)
                    ---- BUGFIX (B49): mesmo clamp por inimigo que o EvalDest aplica. Sem
                    ---- ele o painel mostraria um inimigo valendo mais que o teto e a soma
                    ---- das linhas nao bateria com o numero do slab.
                    if raw > ceiling then
                        raw = ceiling
                    end
                    if net > ceiling then
                        net = ceiling
                    end
                    bruta[enemy], liquida[enemy], cancelada[enemy] = raw, net, raw - net
                    sb, sl = sb + raw, sl + net
                end
            end
        end

        ---- portao de LOS: a policy zera o tile inteiro, entao a decomposicao dele
        ---- tambem e zero -- senao o mapa mostraria ameaca num tile que a policy ignora
        if threat_pol.RequireLOS and g_AIDestEnemyLOSCache and g_AIDestEnemyLOSCache[dest] == false then
            return {bruta = 0, cancelada = 0, liquida = 0}, {}, {}, {}
        end

        local tb = ThreatNormalize(threat_pol, sb)
        local tl = ThreatNormalize(threat_pol, sl)
        return {bruta = tb, cancelada = tl - tb, liquida = tl}, bruta, cancelada, liquida
    end

    -----------------------------------------------------------------------------------
    ---- regime de DUAS policies
    -----------------------------------------------------------------------------------
    local bruta, cancelada, liquida = {}, {}, {}
    local tb, tc = 0, 0

    if threat_pol then
        local raw = ThreatRaw(threat_pol, context, dest, target_pos)
        local part = InfluenceShares(threat_pol, context, dest, grid_voxel, raw)
        for enemy, v in pairs(part) do
            bruta[enemy] = v
            tb = tb + v
        end
    end
    if cover_pol then
        local raw = CoverRaw(cover_pol, context, dest, grid_voxel)
        local part = InfluenceShares(cover_pol, context, dest, grid_voxel, raw)
        for enemy, v in pairs(part) do
            cancelada[enemy] = v
            tc = tc + v
        end
    end
    for enemy, v in pairs(bruta) do
        liquida[enemy] = v + (cancelada[enemy] or 0)
    end
    for enemy, v in pairs(cancelada) do
        if not bruta[enemy] then
            liquida[enemy] = v
        end
    end

    return {bruta = tb, cancelada = tc, liquida = tb + tc}, bruta, cancelada, liquida
end

function IModeAIDebug:InfluencePolicy()
    local ctx = self.ai_context
    if not ctx or not self.selected_unit then
        return nil, false
    end
    local list
    if (self.dbg_influence_scope or "opt") == "end" then
        list = ctx.behavior and ctx.behavior.EndTurnPolicies or empty_table
    else
        list = self.selected_unit:GetArchetype().OptLocPolicies
    end
    local pol = FindPolicy(list, "AIPolicyThreatExposure")
    return pol, (pol and pol.CoverCancels) and true or false,
           FindPolicy(list, "AIPolicyCustomSeekCover"), list
end

---- Decomposicao deste destino no escopo ativo. Ponto unico de entrada da camada de
---- mapa e das linhas -- os dois passam por aqui, entao nao ha como divergirem.
function IModeAIDebug:DecomposeAt(dest, grid_voxel)
    local threat_pol, _, cover_pol = self:InfluencePolicy()
    if not threat_pol and not cover_pol then
        return nil
    end
    return Decompose(threat_pol, cover_pol, self.ai_context, dest, grid_voxel)
end

---- So o componente pedido. E METODO, e nao local, de proposito: a camada de mapa vive
---- em ShowAIVoxels, que e definida bem acima daqui no arquivo -- uma local declarada
---- depois nao seria visivel la dentro (viraria busca de global, nil em runtime).
function IModeAIDebug:DecompValue(dest, grid_voxel, mode)
    local totals = self:DecomposeAt(dest, grid_voxel)
    if not totals then
        return nil
    end
    if mode == "threat" then
        return totals.bruta
    elseif mode == "cover" then
        return totals.cancelada
    end
    return totals.liquida
end

function IModeAIDebug:ClearInfluenceFx()
    for _, fx in ipairs(self.dbg_infl_fx or empty_table) do
        DoneObject(fx)
    end
    self.dbg_infl_fx = nil
end

---- arg: "threat" | "cover" | "sum" -- clicar no modo ativo desliga
---- Modo e escopo sao MESTRES: valem para as linhas e para a camada de mapa. Se a
---- camada estiver no ar, ela e repintada -- senao o slab mostraria um componente e a
---- linha outro, que e exatamente a divergencia que esta secao existe para evitar.
local function RefreshDecomp(self)
    self:DrawInfluenceLines()
    if self.dbg_layer == "decomp_opt" or self.dbg_layer == "decomp_end" then
        self:ShowAIVoxels(self.dbg_layer)
    else
        self:Update()
    end
end

function IModeAIDebug:SetInfluenceMode(arg)
    self.dbg_influence = (self.dbg_influence ~= arg) and arg or nil
    RefreshDecomp(self)
end

function IModeAIDebug:SetInfluenceScope(arg)
    self.dbg_influence_scope = arg
    ---- a camada carrega o escopo no proprio id; trocar o escopo troca a camada
    if self.dbg_layer == "decomp_opt" or self.dbg_layer == "decomp_end" then
        self.dbg_layer = (arg == "end") and "decomp_end" or "decomp_opt"
    end
    RefreshDecomp(self)
end

function IModeAIDebug:DrawInfluenceLines()
    self:ClearInfluenceFx()

    local mode = self.dbg_influence
    local ctx = self.ai_context
    if not mode or not ctx or not self.selected_unit or not self.selected_voxel then
        return
    end

    ---- mesmo destino que o rollover de texto usa: o alcancavel quando existe, senao um
    ---- empacotado com a PrefStance. A postura importa -- cobertura baixa nao conta em pe.
    local x, y, z = point_unpack(self.selected_voxel)
    local dest = (ctx.voxel_to_dest or empty_table)[self.selected_voxel] or
                     stance_pos_pack(x, y, z, StancesList[ctx.archetype.PrefStance])
    local gx, gy, gz = WorldToVoxel(x, y, z)
    local grid_voxel = point_pack(gx, gy, gz)
    local tile_pos = InflValidZ(DestToPoint(dest))

    local threat_pol, cancels, cover_pol = self:InfluencePolicy()
    local totals, bruta, cancelada, liquida = self:DecomposeAt(dest, grid_voxel)

    local fx = {}
    if not totals then
        fx[#fx + 1] = PlaceTextFx("sem policy de ameaca/cobertura neste escopo",
                                  tile_pos:AddZ(INFL_Z_ENEMY + 40 * guic), CLR_ZERO)
        self.dbg_infl_fx = fx
        return
    end

    ---- MESMA fonte que a camada de mapa: `Decompose`. O slab e as linhas que saem dele
    ---- nao tem como mostrar numeros diferentes porque ha um calculo so.
    local per, total
    if mode == "threat" then
        per, total = bruta, totals.bruta
    elseif mode == "cover" then
        per, total = cancelada, totals.cancelada
    else
        per, total = liquida, totals.liquida
    end

    ---- As parcelas por inimigo vem em unidades CRUAS no regime de uma policy (rampas) e
    ---- ja em unidades de score no regime de duas. Ratear pelo proprio somatorio resolve
    ---- os dois casos com o mesmo codigo, e faz a soma das linhas fechar o total exato.
    local soma_raw = 0
    for _, v in pairs(per or empty_table) do
        soma_raw = soma_raw + v
    end

    local shares = {}
    if soma_raw ~= 0 then
        local assigned, biggest, biggest_v = 0, nil, 0
        for enemy, v in pairs(per) do
            if v ~= 0 then
                local sh = MulDivRound(total, v, soma_raw)
                shares[enemy] = sh
                assigned = assigned + sh
                if not biggest or abs(v) > abs(biggest_v) then
                    biggest, biggest_v = enemy, v
                end
            end
        end
        ---- sobra de arredondamento no maior termo: o painel promete que as linhas somam
        ---- o numero do tile, e um painel de conferencia que nao fecha e pior que nenhum
        if biggest and assigned ~= total then
            shares[biggest] = shares[biggest] + (total - assigned)
        end
    end

    local vmin, vmax
    for _, v in pairs(shares) do
        vmin = vmin and Min(vmin, v) or v
        vmax = vmax and Max(vmax, v) or v
    end

    for _, enemy in ipairs(ctx.enemies or empty_table) do
        local v = shares[enemy]
        if v and IsValid(enemy) then
            local from = InflValidZ(enemy:GetPos()):AddZ(INFL_Z_ENEMY)
            local to = tile_pos:AddZ(INFL_Z_TILE)
            ---- escala por TILE e nao pelo mapa: a pergunta aqui e quem domina ESTE
            ---- tile. Normalizar pelo mapa deixaria tudo desbotado nos tiles tranquilos,
            ---- que sao justamente os que interessa comparar.
            local color = ScoreColor(v, vmin, vmax)
            fx[#fx + 1] = PlaceLineFX(from, to, color)
            fx[#fx + 1] = PlaceTextFx(string.format("#%d %+d", TargetIndex(ctx, enemy) or 0, v),
                                      to + (from - to) * INFL_LABEL_AT / 100, color)
        end
    end

    ---- cabecalho no tile: o total do MODO, mais os tres componentes juntos para nao ser
    ---- preciso trocar de modo so para comparar
    local head = string.format("%+d", total)
    if cancels then
        ---------------------------------------------------------------------------
        ---- `[bruta | cancelada | liquido]` era impresso SEMPRE -- e quando a cobertura
        ---- nao cancela nada (o caso comum) os tres numeros sao identicos, entao a linha
        ---- gastava tres campos para repetir o mesmo valor ao lado do total que ja esta
        ---- ali. Era o principal ruido visual da camada. Agora so aparece quando ha de
        ---- fato uma diferenca para mostrar.
        ----
        ---- No lugar entra a ESCALA, que e o que faltava para o numero significar algo
        ---- sem divisao mental: quanto vale um inimigo e onde e o piso da policy.
        ---------------------------------------------------------------------------
        if totals.cancelada ~= 0 then
            head = head ..
                       string.format("   [bruta %+d | cobertura %+d]", totals.bruta,
                                     totals.cancelada)
        end
        if threat_pol then
            local w = threat_pol.Weight or 100
            local sat = threat_pol:GetSaturation()
            local ceil = threat_pol:GetEnemyCeiling()
            head = head ..
                       string.format("   (1 inim max %d | piso %d | soma %d/%d)",
                                     MulDivRound(MulDivRound(threat_pol.Penalty, ceil, sat), w, 100),
                                     MulDivRound(threat_pol.Penalty, w, 100), soma_raw, sat)
        end
        if soma_raw == 0 and totals.bruta ~= 0 then
            head = head .. "  (cobertura cancelou TUDO)"
        end
        if cover_pol then
            head = head .. "  (SeekCover nesta lista: contagem DOBRADA)"
        end
    else
        head = head ..
                   string.format("   [ameaca %+d | cobertura %+d | soma %+d]", totals.bruta,
                                 totals.cancelada, totals.liquida)
        if not threat_pol then
            head = head .. "  (sem Threat Exposure)"
        end
        if not cover_pol then
            head = head .. "  (sem Seek Cover)"
        end
    end
    fx[#fx + 1] = PlaceTextFx(head, tile_pos:AddZ(INFL_Z_ENEMY + 40 * guic),
                              ScoreColor(total, Min(vmin or 0, total), Max(vmax or 0, total)))

    self.dbg_infl_fx = fx
end

---------------------------------------------------------------------------------------------------
-- Ganchos
--
-- OnMousePos so redesenha quando o voxel MUDA. O original retorna cedo quando e o mesmo
-- voxel e nao diz se mudou, entao comparamos com o ultimo voxel desenhado.
--
-- Os originais sao guardados em GLOBAIS com o idioma `rawget(_G, x) or ...`: este e o
-- mod de desenvolvimento, recarregado o tempo todo, e capturar `IModeAIDebug.OnMousePos`
-- direto numa local pegaria o WRAPPER da carga anterior na segunda recarga -- recursao
-- infinita no primeiro movimento do mouse. Com a global, a captura acontece uma vez so.
---------------------------------------------------------------------------------------------------

RATODBG_Orig_OnMousePos = rawget(_G, "RATODBG_Orig_OnMousePos") or IModeAIDebug.OnMousePos
function IModeAIDebug:OnMousePos(pt)
    RATODBG_Orig_OnMousePos(self, pt)
    if self.dbg_influence and self.dbg_infl_voxel ~= self.selected_voxel then
        self.dbg_infl_voxel = self.selected_voxel
        self:DrawInfluenceLines()
    end
end

---- O original guardado NA CLASSE, e nao numa global com guarda de `rawget`.
---- Medido no processo vivo: `rawget(_G, "RATODBG_Orig_Done")` devolve nil mesmo com a global
---- definida e viva -- neste engine os globais moram atras do `__index` do `_G` (mesmo motivo do
---- BUGFIX B34 no mod de IA). Ou seja, a guarda nunca guardou: a cada reload o `or` capturava o
---- `Done` JA PATCHEADO da carga anterior e empilhava mais um wrapper. Nao quebrava -- so ficava
---- N chamadas de profundidade, uma por reload, em silencio.
---- A tabela da classe e tabela comum, entao aqui o `or` significa o que diz.
IModeAIDebug.RATODBG_Orig_Done = IModeAIDebug.RATODBG_Orig_Done or IModeAIDebug.Done
function IModeAIDebug:Done(...)
    self:ClearInfluenceFx()
    return IModeAIDebug.RATODBG_Orig_Done(self, ...)
end

---------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------
function IModeAIDebug:Process(unit)
    if not CurrentThread() then
        CreateRealTimeThread(self.Process, self, unit)
        return
    end
    self.selected_unit = IsValidTarget(unit) and unit
    if IsValid(unit) and unit:IsAware() then
        if unit:HasStatusEffect("ManningEmplacement") and
            not g_Combat:GetEmplacementAssignment(unit) then
            AIPlayCombatAction("MGLeave", unit, 0)
        end

        unit:SetEnumFlags(const.efVisible)

        self.think_data = {optimal_scores = {}, reachable_scores = {}}

        local t = GetPreciseTicks()
        g_AIDestEnemyLOSCache = {}
        g_AIDestIndoorsCache = {}
        unit.ai_context = nil
        if unit:StartAI(self.think_data, self.forced_behavior) then
            self.time_start_ai = GetPreciseTicks() - t
            local context = unit.ai_context
            self.ai_context = context


            context.behavior:Think(unit, self.think_data)

            local dest = context.ai_destination
            if dest then
                context.dbg_enemy_damage_score = {}
                context.dest_ap[dest] = context.dest_ap[dest] or unit.ActionPoints
                AIPrecalcDamageScore(context, {dest}, context.target_locked or
                                         (context.dest_target or empty_table)[dest],
                                     context.dbg_enemy_damage_score)
            end

            AIChooseSignatureAction(context) -- for debug purposes
        end
    end
    self:ClearVoxelFx()
    self:Update()

    if self.dbg_influence then
        self:DrawInfluenceLines()
    end
end

local function PageCamadas(self, text)
    local td = self.think_data or empty_table

    text = text .. "\n\n" .. link("ShowAIVoxels", "candidates", "Optimal Candidates")
    text = text .. "   " .. link("ShowAIVoxels", "collapsed", "Collapsed Candidates")
    text = text .. "\n" .. link("ShowAIVoxels", "combatpath_ap", "Combat Path (AP)")
    text = text .. "   " .. link("ShowAIVoxels", "combatpath_dist", "Combat Path (Dist)")
    text = text .. "\n" .. link("ShowAIVoxels", "combatpath_score", "Combat Path (Score)")
    text = text .. "   " .. link("ShowAIVoxels", "combatpath_optscore", "Optimal Score")
    text = text .. "\n" .. link("ShowAIVoxels", "pathtotarget", "Path to Target")
    text = text .. "   " .. link("ClearAILayer", nil, "Limpar", 255, 120, 120)

    -----------------------------------------------------------------------------------
    ---- DECOMPOSICAO -- um modo mestre que governa o TILE e a LINHA ao mesmo tempo
    ----
    ---- Substituiu a antiga secao "Soma": somar as duas policies era o caso particular
    ---- `liquido` desta. Modo e escopo sao unicos, entao o slab pintado e as linhas do
    ---- rollover falam sempre do mesmo numero.
    -----------------------------------------------------------------------------------
    local infl_pol, cancels, infl_cover = self:InfluencePolicy()
    text = text .. "\n\n<color 160 105 245>Decomposicao</color> (tile + rollover):"
    text = text .. "\n "
    for _, m in ipairs(INFL_MODES) do
        local on = self.dbg_influence == m.id
        local nome = (cancels and m.name_cancel) or m.name
        text = text .. "  " ..
                   link("SetInfluenceMode", m.id, on and ("[" .. nome .. "]") or nome,
                        on and 160 or 0, on and 105 or 255, on and 245 or 255)
    end

    local scope = self.dbg_influence_scope or "opt"
    text = text .. "\n   escopo: " ..
               link("SetInfluenceScope", "opt", (scope == "opt") and "[OptLoc]" or "OptLoc", 0, 255,
                    0)
    text = text .. "  " ..
               link("SetInfluenceScope", "end", (scope == "end") and "[End Turn]" or "End Turn", 0,
                    255, 255)
    text = text .. "\n   pintar no mapa: " ..
               link("ShowAIVoxels", "decomp_opt", "OptLoc", 160, 105, 245)
    text = text .. "  " .. link("ShowAIVoxels", "decomp_end", "End Turn", 160, 105, 245)

    if not infl_pol and not infl_cover then
        text = text .. "\n   <color 255 120 120>nenhuma policy de ameaca/cobertura neste" ..
                   " escopo</color>"
    elseif cancels then
        ---- com CoverNearTiles ligado a confianca passa a ser POR INIMIGO, entao um
        ---- numero fixo aqui anunciaria uma coisa enquanto as linhas usam outra -- a
        ---- mesma divergencia silenciosa que o Decompose existe para nao permitir
        local near_t = infl_pol.CoverNearTiles or 0
        local trust_txt = string.format("trust %d%%", Clamp(infl_pol.CoverTrust or 100, 0, 100))
        if near_t > 0 then
            trust_txt = string.format("trust %d%% -> %d%% dentro de %dt",
                                      Clamp(infl_pol.CoverTrust or 100, 0, 100),
                                      Clamp(infl_pol.CoverTrustNear or 0, 0, 100), near_t)
        end
        text = text .. string.format("\n   <color 120 245 255>CoverCancels ON</color>" ..
                                         "  <color 120 120 120>%s | plato %dt | saturacao %d</color>",
                                     trust_txt, infl_pol.PlateauTiles or 0, infl_pol:GetSaturation())
        if infl_cover then
            text = text .. "\n   <color 255 120 120>ha uma Seek Cover nesta mesma lista:" ..
                       " contagem DOBRADA</color>"
        end
    else
        text = text .. "\n   <color 120 120 120>duas policies (CoverCancels off)</color>"
        if not infl_pol then
            text = text .. " <color 255 120 120>sem Threat Exposure</color>"
        end
        if not infl_cover then
            text = text .. " <color 255 120 120>sem Seek Cover</color>"
        end
    end
    text = text .. "\n   <color 120 120 120>bruta + cancelada = liquido | valores ja com" ..
               " o Weight | linhas somam o numero do tile</color>"

    text = text .. "\n\n<color 255 160 60>Alvo</color> (por tile alcancavel):"
    text = text .. "\n" .. link("ShowAIVoxels", "target_who", "Quem seria o alvo")
    text = text .. "   " .. link("ShowAIVoxels", "target_cth", "CTH 1o disparo")
    text = text .. "\n" .. link("ShowAIVoxels", "target_hits", "Acertos esperados")
    text = text .. "   " .. link("ShowAIVoxels", "target_score", "Score de alvo (cru)")
    text = text .. "\n" ..
               link("ShowAIVoxels", "target_recalc", "Recalcular alvo em TODOS os tiles", 255, 160,
                    60)
    if self.dbg_targets_recalced then
        text = text .. " <color 255 160 60>(hipotetico)</color>"
    end

    ---- lista de policies com caixa de selecao: [ ] marca/desmarca para a soma,
    ---- o nome continua abrindo a camada individual como sempre
    local function PolicyList(scope, labels, title, r, g, b)
        if #labels == 0 then
            return
        end
        local selected = SumSelectedLabels(self, scope, labels)

        text = text .. string.format("\n\n<color %d %d %d>%s</color> (por slab):", r, g, b, title)
        if #selected > 0 then
            text = text .. "   " ..
                       link("ShowAIVoxels", "sumsel_" .. scope,
                            string.format("somar %d", #selected), 150, 210, 255)
            text = text .. "  " .. link("ClearSumPolicies", scope, "desmarcar", 255, 120, 120)
        end

        local sel = SumSelection(self, scope)
        for i, label in ipairs(labels) do
            local on = sel[label]
            local box = link("ToggleSumPolicy", scope .. "_" .. i, on and "[x]" or "[ ]",
                             on and 150 or 130, on and 210 or 130, on and 255 or 130)
            local mark = (self.dbg_layer == "policy_" .. scope .. "_" .. i) and
                             " <color 0 255 0>&lt;&lt;</color>" or ""
            text = text .. "\n  " .. box .. " " ..
                       link("ShowAIVoxels", "policy_" .. scope .. "_" .. i, label) .. mark
        end
    end

    self.dbg_labels_end = CollectPolicyLabels(td.reachable_scores)
    self.dbg_labels_opt = CollectPolicyLabels(td.optimal_scores)
    PolicyList("end", self.dbg_labels_end, "End-Turn policies", 0, 255, 255)
    PolicyList("opt", self.dbg_labels_opt, "Optimal-Location policies", 0, 255, 0)

    ---- O bloco "Camada ativa" foi removido: o painel e um XText de largura automatica,
    ---- e as linhas dele eram as mais compridas da pagina -- o nome da camada de soma
    ---- cresce com cada policy marcada ("A + B + C  <OptLoc>"), esticando a janela na
    ---- horizontal. As mesmas informacoes continuam disponiveis: o que esta marcado
    ---- aparece nas caixas [x] da lista, e a camada ativa no marcador << .
    ---- `dbg_layer_range` continua sendo preenchido pelas camadas, so nao e mais exibido.

    return text
end

---------------------------------------------------------------------------------------------------
-- Pagina ALVO
--
-- A versao anterior desta pagina so conseguia mostrar o alvo VENCEDOR: tudo que
-- AIPrecalcDamageScore expunha era indexado por DESTINO com o eixo de alvo ja colapsado
-- (dest_cth, dest_hit_score, dest_target_score guardam best_*). Score por candidato so
-- aparecia para quem tinha passado o corte, via debug_data, e "descartado" era o mesmo
-- `-` para fora de alcance, sem LOF e CTH zero.
--
-- Agora le `context.dbg_targets[dest]`, gravado pelo DEBUG (D1) do Rato AI Overhaul:
-- uma linha por (destino, alvo) com CTH, disparos, cadeia do score e motivo de descarte,
-- mais o corte dos 80%, o total e o valor do sorteio.
---------------------------------------------------------------------------------------------------

local function num(v)
    return v and tostring(v) or "-"
end

local function slabs(dist)
    return dist and tostring(MulDivRound(dist, 1, const.SlabSizeX)) or "-"
end

local function cover_txt(v)
    if not v or v == 0 then
        return "-"
    end
    ---- target_covers guarda o valor de CTH da cobertura (max = alta, metade = baixa)
    local full = RATOAI_GetMaxCoverCTH and RATOAI_GetMaxCoverCTH()
    if full and v >= full then
        return "alta"
    end
    return "baixa"
end

---- Lista que o precalc realmente percorreu: `action:GetTargets()` filtrado por lado,
---- mais alvos injetados por gv_AITargetModifiers. Pode divergir de context.enemies --
---- iterar so `enemies`, como a versao anterior fazia, escondia alvos que a IA de fato
---- considerou (e mostrava como candidato quem nunca entrou na lista).
local function CandidateList(ctx)
    local list = ctx.dbg_target_list
    if list and #list > 0 then
        return list
    end
    return ctx.enemies or empty_table
end

---- Os precalcs disparados pela UI (esta pagina e a camada "target_recalc") re-sorteiam
---- a randomizacao por alvo. Congelar antes de chamar: senao o numero que se esta
---- investigando muda so por ter sido observado.
function IModeAIDebug:PrecalcForDebug(dests)
    local ctx = self.ai_context
    if not ctx then
        return
    end
    ctx.dbg_freeze_target_rand = true
    pcall(AIPrecalcDamageScore, ctx, dests, nil, ctx.dbg_enemy_damage_score)
end

---- Alvo aberto no cartao de detalhe, identificado pelo HANDLE. Nao por indice na
---- lista (a ordenacao da tabela muda quando os scores mudam) e nao por session_id: o
---- hyperlink do painel e `<h Func arg ...>`, com o argumento delimitado por espaco --
---- um session_id com espaco quebraria o parse. handle e numerico.
function IModeAIDebug:SetTargetFocus(arg)
    arg = tostring(arg or "")
    self.dbg_target_focus = (self.dbg_target_focus ~= arg) and arg or nil
    self:Update()
end

---- uma linha da tabela, ja resolvida para exibicao
local function BuildRows(ctx, dbg_dest, scored)
    local fin = {}
    for _, t in ipairs((dbg_dest or empty_table).finalists or empty_table) do
        fin[t] = true
    end

    local rows = {}
    for _, target in ipairs(CandidateList(ctx)) do
        if IsValid(target) then
            local r = (dbg_dest and dbg_dest.by_target[target]) or empty_table
            ---- fallback para o debug_data do jogo quando o precalc rodou sem
            ---- RATOAI_Debug: ali so ha score, e so para finalistas
            local score = r.score or (scored and scored[target])
            rows[#rows + 1] = {
                target = target,
                idx = TargetIndex(ctx, target),
                row = r,
                score = score,
                finalist = fin[target] or false,
                sort = score or -1
            }
        end
    end

    ---- maior score primeiro; descartados (sem score) caem para o fim
    table.sort(rows, function(a, b)
        if a.sort ~= b.sort then
            return a.sort > b.sort
        end
        return tostring(a.target.session_id) < tostring(b.target.session_id)
    end)
    return rows
end

---- cartao de detalhe: CTH disparo a disparo + cadeia do score
local function TargetCard(ctx, d, entry)
    local target = entry.target
    local r = entry.row
    local text = string.format("\n\n<color 255 200 0>Detalhe #%s %s</color>  %s", num(entry.idx),
                               tostring(target.session_id),
                               link("SetTargetFocus", target.handle, "[fechar]", 150, 150, 150))

    ---- CTH por disparo -- capturado por FUNCTION_ScoreAttacksDetailed sob RATOAI_Debug
    local shots = ctx.cth_attacks_at and ctx.cth_attacks_at[d] and ctx.cth_attacks_at[d][target]
    local aims = ctx.aims_at and ctx.aims_at[d] and ctx.aims_at[d][target]

    if shots and #shots > 0 then
        local soma = 0
        ---- `CTH` e a bala LIDER do ataque; `rajada` e o que aquele ataque rendeu
        ---- depois de expandido bala a bala (BUGFIX B21). Em arma de tiro unico os
        ---- dois sao iguais e a coluna some.
        local balas = ctx.burst_shots or 1
        local bursts = ctx.burst_hits_at and ctx.burst_hits_at[d] and ctx.burst_hits_at[d][target]
        if balas > 1 then
            text = text ..
                       string.format("\n<color 120 120 120>  atq mira  CTH  rajada x%d</color>",
                                     balas)
        else
            text = text .. "\n<color 120 120 120>  atq mira  CTH</color>"
        end
        for i, cth in ipairs(shots) do
            local exp = (bursts and bursts[i]) or cth
            soma = soma + exp
            if balas > 1 then
                text = text ..
                           string.format("\n   %-3d %-4s %4d %8d", i, num(aims and aims[i]), cth,
                                         exp)
            else
                text = text .. string.format("\n   %-3d %-4s %4d", i, num(aims and aims[i]), cth)
            end
        end
        if r.hit then
            ---- `hit - soma` e o recoil aplicado ENTRE ataques; o de DENTRO da rajada
            ---- ja esta em cada `exp`. Derivado, nao remontado: 0 = nao houve.
            text = text ..
                       string.format(
                           "\n  soma %d | recoil pers %s | <color 255 255 255>hit %d</color> = %d.%02d acertos",
                           soma, tostring(
                               (ctx.recoil_loss_at and ctx.recoil_loss_at[d] and
                                   ctx.recoil_loss_at[d][target]) or 0), r.hit,
                           (r.hit - r.hit % 100) / 100, r.hit % 100)
        end
    else
        text = text ..
                   "\n  <color 150 150 150>(sem CTH por disparo -- alvo descartado antes de pontuar)</color>"
    end

    ---- cadeia do score
    local c = r.chain
    if c then
        text = text .. "\n\n<color 255 200 0>  cadeia do score</color>"
        text = text .. string.format("\n    soma de CTH (hit_score)   %6s", num(c.hit))
        text = text .. string.format("\n    + pos_mod (stance)        %6s", num(c.pos))
        text = text .. string.format("\n    x TargetBaseScore         %6s", num(c.base))
        text = text .. string.format("\n    + TargetingPolicies       %6s", num(c.pol))
        for _, p in ipairs(c.pol_parts or empty_table) do
            text = text .. string.format("\n        %-22s %+6d", tostring(p.name), p.value)
        end
        if c.downed then
            text = text .. string.format("\n    x 5%% (alvo caido)         %6s", num(c.downed))
        end
        if c.ff then
            text = text .. string.format("\n    x fogo amigo              %6s", num(c.ff))
        end
        text = text ..
                   string.format("\n    x randomizacao %3s%%       %6s", num(c.rnd_pct), num(c.rnd))
        if c.group then
            text = text ..
                       string.format("\n    x grupo %3s%%              %6s", num(c.group_pct),
                                     num(c.group))
        end
        text = text ..
                   string.format("\n    <color 255 255 255>= score final             %6s</color>",
                                 num(c.final))
    elseif r.reject then
        text = text .. string.format("\n\n  <color 255 150 150>descartado: %s</color>", r.reject)
    end

    return text
end

local function PageAlvo(self, text)
    local ctx = self.ai_context
    local d, is_current = EvalDestOf(ctx)

    if not d then
        return text .. "\n(sem posicao avaliavel)"
    end

    ---- o jogo so preenche dbg_enemy_damage_score quando ha ai_destination
    ---- (IModeAIDebug:Process). Sem ele -- HoldPositionAI -- calculamos aqui.
    if not ctx.dbg_enemy_damage_score then
        ctx.dbg_enemy_damage_score = {}
        self:PrecalcForDebug({d})
    end

    local dbg_dest = ctx.dbg_targets and ctx.dbg_targets[d]
    local chosen = ctx.dest_target and ctx.dest_target[d]
    local hits = ctx.dest_hit_score and ctx.dest_hit_score[d]

    if is_current then
        text = text .. "\n\n<color 255 200 0>Na posicao ATUAL</color>" ..
                   " <color 150 150 150>(behavior sem ai_destination, ex. HoldPosition)</color>"
    else
        text = text .. "\n\n<color 255 200 0>No destino escolhido</color>"
    end

    if dbg_dest then
        text = text ..
                   string.format("\n  AP no destino: %s   custo do ataque: %s",
                                 format_ap(dbg_dest.ap), format_ap(dbg_dest.cost_ap))
        if dbg_dest.no_ap then
            text = text .. "  <color 255 150 150>(AP insuficiente -- nenhum alvo avaliado)</color>"
        end
    end

    text = text .. string.format("\n  alvo: <color 0 255 0>%s</color>",
                                 IsValid(chosen) and chosen.session_id or "nenhum")
    if dbg_dest and dbg_dest.preferred then
        text = text .. " <color 150 150 150>(preferred_target -- imposto, sem sorteio)</color>"
    end
    ---- `dest_target_score`, `dest_cth` e `dest_hit_score` NAO aparecem aqui: sao as
    ---- colunas `score`, `CTH1` e `hits` da linha marcada com `>` na tabela abaixo.
    ---- Esta aba vive no limite da altura da tela; duplicar dado custa linha.
    text = text .. string.format("\n  recoil no alvo: %s | max_attacks: %s | balas/ataque: %s",
                                 tostring(
                                     ctx.dest_target_recoil_cth and ctx.dest_target_recoil_cth[d]),
                                 tostring(ctx.max_attacks), tostring(ctx.burst_shots))

    ---- O SORTEIO. best_target nao e o de maior score: e um sorteio ponderado entre os
    ---- finalistas (>= AIDecisionThreshold do melhor). Sem estes tres numeros nao ha
    ---- como separar "o scoring escolheu mal" de "o dado caiu assim".
    if dbg_dest and dbg_dest.total then
        text = text .. string.format(
                   "\n  <color 255 200 0>sorteio:</color> corte %s (%d%% de %s) | roll %s de %s | %d finalistas",
                   num(dbg_dest.threshold), const.AIDecisionThreshold, num(dbg_dest.best_score),
                   num(dbg_dest.roll), num(dbg_dest.total), #(dbg_dest.finalists or empty_table))
    end

    ---- fallback: dist/cover/LOS ainda vem das tabelas antigas quando nao ha dbg_dest
    local dists = ctx.dest_target_dist and ctx.dest_target_dist[d]
    local covers = ctx.dest_target_cover_score and ctx.dest_target_cover_score[d]
    local los = ctx.dest_target_los and ctx.dest_target_los[d]
    local scored = ctx.dbg_enemy_damage_score

    local rows = BuildRows(ctx, dbg_dest, scored)

    text = text .. "\n\n<color 255 200 0>Candidatos</color>  (#i = cor na camada de mapa)"
    text = text ..
               "\n<color 120 120 120>   #  alvo           dist LOS   cvr | tiros CTH1  hits |  score   p%  situacao</color>"

    local total = dbg_dest and dbg_dest.total or 0

    for _, e in ipairs(rows) do
        local r = e.row
        local target = e.target

        local dist = r.dist or (dists and dists[target])
        local cover = r.cover or (covers and covers[target])
        local l = r.los
        if l == nil and los then
            l = los[target]
        end

        local status, marker
        if target == chosen then
            status, marker = "escolhido", "<color 0 255 0>"
        elseif e.finalist then
            status, marker = "finalista", "<color 255 255 255>"
        elseif e.score then
            status, marker = "abaixo do corte", "<color 170 170 170>"
        else
            status, marker = r.reject or "nao avaliado", "<color 130 130 130>"
        end

        ---- probabilidade real do sorteio: so faz sentido para finalista
        local pct = (e.finalist and total > 0) and
                        string.format("%d%%", MulDivRound(e.score or 0, 100, total)) or "-"

        ---- LOS mostrado CRU. `targets_attack_data[k].los` vem do GetLoFData da engine e
        ---- nao ha garantia de que seja booleano -- se for numerico, `l and "sim"`
        ---- transformaria um 0 legitimo em "sim".
        local los_txt = (l == nil) and "-" or tostring(l):sub(1, 4)

        text = text ..
                   string.format(
                       "\n%s%s #%-2s %-14s %4s %-4s %-5s| %5s %4s %5s | %6s %4s  %s</color>",
                       marker, (target == chosen) and ">" or " ", num(e.idx),
                       tostring(target.session_id):sub(1, 14), slabs(dist), los_txt,
                       cover_txt(cover), num(r.shots), num(r.cth1), num(r.hit), num(e.score), pct,
                       status)
    end

    ---- links de detalhe numa linha so, para nao alargar a tabela
    if #rows > 0 then
        local links = {}
        for _, e in ipairs(rows) do
            links[#links + 1] = link("SetTargetFocus", e.target.handle, "#" .. num(e.idx),
                                     (self.dbg_target_focus == tostring(e.target.handle)) and 255 or
                                         0, 255, 255)
        end
        text = text .. "\n  detalhe: " .. table.concat(links, "  ")
    end

    ---- cartao do alvo aberto
    if self.dbg_target_focus then
        for _, e in ipairs(rows) do
            if tostring(e.target.handle) == self.dbg_target_focus then
                text = text .. TargetCard(ctx, d, e)
                break
            end
        end
    end

    return text
end

local function PageControles(self, text)
    text = text .. "\n\n" .. link("UnitBeginTurn", nil, "Begin Turn", 0, 255, 0)
    text = text .. "   " .. link("UnitExecuteTurn", nil, "Execute Turn", 0, 255, 0)

    text = text .. "\n\n" .. link("SetUnitStance", "MoveStance", "Move Stance")
    text = text .. "   " .. link("SetUnitStance", "PrefStance", "Pref Stance")
    text = text .. "\n" .. link("MakeUnaware", nil, "Make Unaware")

    text = text .. "\n\n" .. link("ProcessEmplacements", "assign", "Assign Emplacements (Team)")
    text = text .. "\n" .. link("ProcessEmplacements", "reset", "Reset Emplacements Appeal (Team)")

    -----------------------------------------------------------------------------------------------
    -- Quem conta como AMEACA (ver o cabecalho de ToggleThreatUnit)
    -----------------------------------------------------------------------------------------------
    local ctx = self.ai_context
    local enemies = ctx and ctx.enemies
    if enemies and #enemies > 0 then
        local only = const.RATOAI.ThreatOnly
        local filtrando = only and next(only) ~= nil

        self.dbg_threat_ids = {}
        for i, e in ipairs(enemies) do
            self.dbg_threat_ids[i] = e.session_id
        end

        text = text .. "\n\n<color 255 160 80>Contam como ameaca</color>"
        if filtrando then
            text = text .. "   " ..
                       link("ClearThreatUnits", nil, "todos de volta", 255, 120, 120)
            text = text .. "\n   <color 200 140 60>FILTRO ATIVO -- a IA esta cega para o resto. " ..
                       "So para inspecionar.</color>"
        else
            text = text .. "   <color 130 130 130>(todos)</color>"
        end

        for i, e in ipairs(enemies) do
            local on = (not filtrando) or only[e.session_id]
            local box = link("ToggleThreatUnit", i, on and "[x]" or "[ ]", on and 255 or 130,
                             on and 160 or 130, on and 80 or 130)
            ---- "so" some quando ja e o unico marcado: naquele estado o clique nao mudaria nada
            local solo = ""
            if not (filtrando and only[e.session_id] and #table.keys(only) == 1) then
                solo = "  " .. link("SoloThreatUnit", i, "so", 150, 210, 255)
            end
            text = text .. "\n  " .. box .. " " .. tostring(e.session_id) .. solo
        end
    end

    return text
end

---------------------------------------------------------------------------------------------------
-- PAGINA PERF -- o perfil do turno da unidade selecionada
--
-- Os numeros vem do profiler do RATOTEL_AITelemetry (PERF_PROFILING.md). Esta pagina e a leitura
-- AO VIVO de UMA unidade; o diagnostico de verdade e o campo `prof` do JSONL, que da a campanha
-- inteira com distribuicao e cauda. Aqui e para iterar enquanto se mexe no codigo.
--
-- DUAS ADVERTENCIAS QUE MUDAM A LEITURA:
--
--  1. `AIScoreDest` CONTEM as policies -- ele e quem chama EvalDest. A diferenca entre o ms dele
--     e a soma das policies e o custo do proprio laco (GetVisualVoxels, fogo/fumaca, marcadores
--     de bias). Nao some as duas secoes.
--
--  2. Se `z` (chamadas com delta zero) chega perto de `n`, o relogio nao esta resolvendo aquela
--     linha e o `ms` dela nao vale nada. Olhe `aloc` e `n/dest`, que sao exatos.
---------------------------------------------------------------------------------------------------

---- us -> "X.XX ms". Divisao inteira em toda parte: `/` aqui e truncado.
local function ms(us)
    us = us or 0
    return string.format("%d.%02d", us / 1000, (us % 1000) / 10)
end

---- razao com duas casas, sem float
local function razao(c, base)
    if not base or base == 0 then
        return "-"
    end
    local v = MulDivRound(c or 0, 100, base)
    return string.format("%d.%02d", v / 100, v % 100)
end

local function ordenado(tab, campo)
    local lista = {}
    for nome, s in pairs(tab or empty_table) do
        lista[#lista + 1] = {nome = nome, s = s}
    end
    table.sort(lista, function(a, b)
        return (a.s[campo] or 0) > (b.s[campo] or 0)
    end)
    return lista
end

local function PagePerf(self, text)
    local ligado = const.RATOAI and const.RATOAI.Profile

    text = text .. "\n\n<color 255 200 0>Profiler</color>: " ..
               link("ToggleProfile", nil, ligado and "[ligado]" or "desligado",
                    ligado and 0 or 160, ligado and 255 or 160, ligado and 120 or 160) ..
               "   <color 120 120 120>(const.RATOAI.Profile)</color>"

    if not ligado then
        text = text .. "\n  <color 160 160 160>Ligue e rode o turno de novo (begin turn):" ..
                   " os wrappers entram na primeira unidade que raciocinar depois disso.</color>"
        return text
    end

    local b = self.selected_unit and RATOTEL_ProfFor(self.selected_unit)
    if not b then
        text = text .. "\n  <color 160 160 160>Sem perfil para esta unidade ainda.</color>"
        return text
    end

    local opt = b.card.opt or 0
    local dests = b.card.dests or 0
    if opt == 0 then
        ---- o snapshot do JSONL preenche card no fim do turno; ao vivo, tira do context
        local ctx = self.ai_context
        if ctx then
            opt = #(ctx.all_destinations or empty_table)
            dests = #(ctx.destinations or empty_table)
        end
    end

    text = text .. string.format(
               "\n  cardinalidade: <color 255 255 255>%d</color> optloc |" ..
                   " <color 255 255 255>%d</color> destinos | %d inimigos", opt, dests,
               b.card.enemies or #((self.ai_context or empty_table).enemies or empty_table))

    ---- FASES -----------------------------------------------------------------------------------
    local fases = ordenado(b.ph, "us")
    if #fases > 0 then
        text = text .. "\n\n<color 255 200 0>Fases</color>   " ..
                   "<color 120 120 120>ms / chamadas / aloc</color>"
        for _, e in ipairs(fases) do
            text = text .. string.format("\n  %-26s %8s  %6d  %9d", e.nome, ms(e.s.us), e.s.n,
                                         e.s.al or 0)
        end
    end

    ---- POLICIES --------------------------------------------------------------------------------
    local pols = ordenado(b.pol, "us")
    if #pols > 0 then
        text = text .. "\n\n<color 255 200 0>Policies</color>   " ..
                   "<color 120 120 120>ms / chamadas / por-dest / aloc</color>"
        for _, e in ipairs(pols) do
            local suspeito = e.s.z and e.s.n > 0 and (e.s.z * 2 > e.s.n)
            text = text .. string.format("\n  %s%-28s %8s %6d %6s %9d%s",
                                         suspeito and "<color 200 160 60>" or "", e.nome,
                                         ms(e.s.us), e.s.n, razao(e.s.n, opt), e.s.al or 0,
                                         suspeito and "  (relogio grosso)</color>" or "")
        end
    end

    ---- PRIMITIVAS ------------------------------------------------------------------------------
    local prims = {}
    for nome, c in pairs(b.cnt or empty_table) do
        prims[#prims + 1] = {nome = nome, c = c}
    end
    table.sort(prims, function(a, c)
        return a.c > c.c
    end)
    if #prims > 0 then
        text = text .. "\n\n<color 255 200 0>Primitivas</color>   " ..
                   "<color 120 120 120>chamadas / por-dest</color>"
        for _, e in ipairs(prims) do
            text = text .. string.format("\n  %-28s %8d %8s", e.nome, e.c, razao(e.c, opt))
        end
    end

    return text
end

function IModeAIDebug:ToggleProfile()
    const.RATOAI = const.RATOAI or {}
    const.RATOAI.Profile = not const.RATOAI.Profile
    self:Update()
end

---- MESMA ordem de PAGES -- as duas sao indexadas pelo mesmo numero
local PAGE_FUNCS = {PageControles, PageUnidade, PageDestinos, PageAlvo, PageAcoes, PageCamadas,
                    PagePerf}

---------------------------------------------------------------------------------------------------

function IModeAIDebug:Update()
    local ctrl = self:ResolveId("idText")
    if not ctrl then
        return
    end

    ---- Teto de largura. O XTemplate do jogo da ao idText `MinWidth 300` e nenhum
    ---- MaxWidth, entao o painel acompanha a linha mais comprida do conteudo e a janela
    ---- cresce sem limite na horizontal. Mesma unidade do MinWidth do template.
    ---- Com WordWrap ligado a linha quebra; sem ele, MaxWidth cortaria o texto.
    ---- HasMember antes de chamar: se o setter nao existir nesta versao da engine, a
    ---- UI segue como estava em vez de estourar erro a cada Update.
    if ctrl.MaxWidth ~= PANEL_MAX_WIDTH and ctrl:HasMember("SetMaxWidth") then
        ctrl:SetMaxWidth(PANEL_MAX_WIDTH)
    end
    if not ctrl.WordWrap and ctrl:HasMember("SetWordWrap") then
        ctrl:SetWordWrap(true)
    end

    local text = ""
    if not g_Combat then
        text = "<color 255 0 0>WARNING: out of combat!</color>\n\n"
    end

    local unit = self.selected_unit

    if not unit then
        ctrl:SetText(text .. "No unit selected")
        return
    end

    if self.running_turn then
        ctrl:SetText(text .. string.format("Executing AI turn (%s)...", unit.session_id))
        return
    end

    if not unit:IsAware() then
        text = text ..
                   string.format("Selected unit: %s, AP = %d", unit.session_id,
                                 (unit.ActionPoints / const.Scale.AP))
        text = text .. string.format("\n   Archetype: %s (Unaware)", unit:GetArchetype().id)
        text = text ..
                   string.format("\n   AI Keywords: %s",
                                 table.concat(unit.AIKeywords or empty_table, ","))
        text = text .. "\n\n" .. link("WakeUp", nil, "Alert")
        text = text .. "   " .. link("WakeUp", "reposition", "Alert+Reposition")
        ctrl:SetText(text)
        return
    end

    if not self.ai_context then
        text = text ..
                   string.format("Selected unit: %s, AP = %d", unit.session_id,
                                 (unit.ActionPoints / const.Scale.AP))
        text = text .. string.format("\n   Archetype: %s (AI disabled)", unit:GetArchetype().id)
        text = text ..
                   string.format("\n   AI Keywords: %s",
                                 table.concat(unit.AIKeywords or empty_table, ","))
        ctrl:SetText(text)
        return
    end

    ---- Process() refaz o think e cria um ai_context novo; a marca de "hipotetico"
    ---- pertence ao context antigo e nao pode sobreviver a ele
    if self.dbg_ctx_ref ~= self.ai_context then
        self.dbg_ctx_ref = self.ai_context
        self.dbg_targets_recalced = nil
    end

    ---- marcadores 3d sempre atualizados, independente da pagina
    UpdateDestMarkers(self)

    local on = EnabledPages(self)

    ---- cabecalho fixo
    text = text .. string.format("<color 255 255 255>%s</color>  AP %d  |  %s", unit.session_id,
                                 (unit.ActionPoints / const.Scale.AP), unit:GetArchetype().id)
    text = text .. "\n" .. TabBar(self)

    ---- so rotula as secoes quando ha mais de uma ligada
    local count = 0
    for i = 1, #PAGES do
        if on[i] then
            count = count + 1
        end
    end

    for i = 1, #PAGES do
        if on[i] then
            if count > 1 then
                text = text .. string.format("\n<color 120 120 120>---- %s ----</color>", PAGES[i])
            else
                text = text .. "\n<color 120 120 120>----</color>"
            end
            text = PAGE_FUNCS[i](self, text)
        end
    end

    ctrl:SetText(text)
end

---------------------------------------------------------------------------------------------------
-- EXECUTAR TURNO FIEL AO CONTROLADOR REAL
---------------------------------------------------------------------------------------------------
const.RATOAI = const.RATOAI or {}

function IModeAIDebug:UnitExecuteTurn()
    if not self.selected_unit then
        return
    end
    assert(self.ai_context and self.ai_context.unit == self.selected_unit)

    self.running_turn = true
    CreateGameTimeThread(function()
        local unit = self.selected_unit
        local context = self.ai_context

        ---- canal oficial: e assim que o proprio jogo passa uma acao escolhida a mao
        local descr = self.forced_action and
                          (context.choose_actions or empty_table)[self.forced_action]
        local anterior = context.forced_signature_action
        context.forced_signature_action = descr and descr.action or nil

        ---- pcall em tudo: este e um modo de DEBUG, e um erro aqui nao pode deixar a sessao com
        ---- running_turn preso em true (o painel congelaria sem explicacao).
        ---- destino forcado pelo painel, validado contra o think ATUAL (ver RATODBG_ForcedDest)
        local forcado = RATODBG_ForcedDest(self, context)
        if forcado then
            context.ai_destination = forcado
        end

        local ok, err = pcall(function()
            if context.behavior then
                context.behavior:TakeStance(unit)
            end

            local result = "continue"
            if context.ai_destination and IsValid(unit) and not unit:IsDead() and context.behavior then
                result = context.behavior:BeginMovement(unit)
                WaitCombatActionsEnd(unit)
            end

            self.ratodbg_last_move_result = result

            if result ~= "continue" then
                ---- exatamente o que o controlador real faz: movimento interrompido encerra a
                ---- execucao desta unidade. Antes daqui, o painel atacava assim mesmo.
                return
            end

            if IsValid(unit) and not unit:IsDead() then
                self.ratodbg_last_status = AIExecuteUnitBehavior(unit)
            end
        end)

        context.forced_signature_action = anterior
        if not ok then
            self.ratodbg_last_status = "ERRO: " .. tostring(err)
        end

        self.running_turn = false
        self:Process(self.selected_unit)
    end)
    self:Update()
end

---------------------------------------------------------------------------------------------------
-- CLIQUE ESQUERDO NO VAZIO NAO PODE DESMONTAR A SESSAO DE DEBUG

IModeAIDebug.ratodbg_orig = IModeAIDebug.ratodbg_orig or {}
IModeAIDebug.ratodbg_orig.OnMouseButtonDown = IModeAIDebug.ratodbg_orig.OnMouseButtonDown or
                                                  IModeAIDebug.OnMouseButtonDown

function IModeAIDebug:OnMouseButtonDown(pt, button)
    if button == "L" then
        local obj = SelectionMouseObj()
        obj = IsKindOf(obj, "Unit") and obj or nil
        if not obj or obj == self.selected_unit then
            ---- FIXA O TILE. 

            local pos = GetCursorPassSlab()
            if pos then
                self.ratodbg_pinned_voxel = point_pack(pos)
                self:Update()
            end
            return "break"
        end
    end
    return IModeAIDebug.ratodbg_orig.OnMouseButtonDown(self, pt, button)
end
