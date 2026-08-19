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
---- So para teste. Nao publicar.
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- PARAMETROS  (tudo local; edite aqui e recarregue o mod)
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
---- ESCALA DIVERGENTE
----
---- O sinal e a cor (vermelho = negativo, mint = positivo) e a MAGNITUDE e a saturacao:
---- perto do zero as duas rampas desbotam para o mesmo cinza, longe do zero saturam.
---- Assim "quase neutro" le como quase neutro dos dois lados, e o olho encontra os
---- extremos sem precisar ler numero.
----
---- Vermelho e exclusivo do lado negativo -- por isso a rampa positiva nao passa mais
---- por vermelho/laranja/amarelo. O preco e menos variacao de matiz no positivo; a
---- compensacao vem da saturacao, que agora carrega a informacao.
----
---- Luminancia alta em toda a escala, de proposito: PlaceTextFx pinta o texto com a
---- MESMA cor do quadrado, entao tom escuro sobre mapa escuro fica ilegivel. Por isso
---- o extremo negativo e vermelho vivo e nao vermelho-sangue.
---------------------------------------------------------------------------------------------------

---- zero exato, ou tile sem valor
local CLR_ZERO = RGB(125, 128, 132)

---- As duas rampas foram espacadas medindo deltaE (CIE76) entre vizinhos, e nao a olho.
---- A rampa violeta anterior tinha um par com deltaE 9,3 -- indistinguivel na pratica.
---- Aqui o menor passo e ~22 nas duas, e o L* varia pouco DENTRO de cada rampa, entao a
---- leitura vem da saturacao/matiz e nao de "uma e mais clara que a outra".

---- positivo: indice 1 = quase zero (cinza esverdeado), 5 = melhor (mint saturado),
---- com AMARELO no meio -- so saturacao nao dava passos grandes o bastante entre as
---- bandas do meio. passos deltaE: 48.2, 34.7, 50.6, 33.1
---- O amarelo nao conflita com o vermelho do lado negativo: o par mais proximo entre as
---- duas rampas continua sendo o das pontas desbotadas (deltaE 19.7), e nao o amarelo.
local POS_RAMP = {
    RGB(152, 170, 160),
    RGB(200, 215, 115),
    RGB(232, 240, 55),
    RGB(120, 240, 130),
    RGB(0, 250, 200),
}

---- negativo: indice 1 = quase zero (cinza avermelhado), 5 = pior (vermelho saturado)
---- passos deltaE: 31.3, 31.3, 22.4, 24.5
---- O extremo puxa para carmim (255,0,72) em vez de vermelho puro: entre (250,40,26) e
---- (255,22,22) o olho nao separava nada -- era o mesmo defeito da rampa violeta.
local NEG_RAMP = {
    RGB(180, 150, 150),
    RGB(214, 118, 108),
    RGB(236, 80, 62),
    RGB(250, 40, 26),
    RGB(255, 0, 72),
}

---- cortes do gradiente, em % da faixa [min, max]
local RAMP_STOPS = {20, 40, 60, 80}

---- largura maxima do painel, na mesma unidade do `MinWidth 300` do XTemplate do jogo.
---- Aumente se preferir o painel mais largo; o conteudo quebra linha sozinho.
local PANEL_MAX_WIDTH = 700

---- finalista = passou o corte de AIDecisionThreshold. Branco de proposito: nenhuma das
---- duas rampas produz branco, entao nao ha como confundir com "score alto".
local CLR_FINALIST = RGB(255, 255, 255)
local RING_SCALE = 165 ---- % do tamanho do quadrado normal

---- policies somadas na camada "soma". Sao os GetEditorView() delas -- os mesmos
---- rotulos que aparecem no score_details. Mudou o GetEditorView, muda aqui.
local SUM_LABELS = {"Custom Seek Cover", "Threat Exposure"}

---- uma cor por alvo, estavel dentro do turno (indice em context.enemies)
local TARGET_COLORS = {
    RGB(255, 90, 90), RGB(90, 170, 255), RGB(255, 225, 70), RGB(120, 255, 130),
    RGB(255, 150, 245), RGB(120, 245, 255), RGB(255, 175, 65), RGB(195, 145, 255),
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

---- cor de `value` dentro da faixa [vmin, vmax]
----
---- Positivos e negativos sao escalados SEPARADAMENTE, cada um contra o proprio extremo:
---- o positivo contra vmax, o negativo contra vmin. Escalar os dois juntos sobre o span
---- inteiro faria o zero cair no meio de uma rampa continua, e um -1 num mapa que vai de
---- -200 a +100 apareceria com cor de "bem ruim" em vez de "quase neutro".
---- t (0..100) -> indice de banda numa rampa de 5. Bandas explicitas porque divisao em
---- Lua devolve float e ramp[4.5] seria nil.
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

    ---- A escala positiva sempre parte do ZERO, nunca de vmin. Esticar entre vmin e vmax
    ---- (como antes) fazia o menor positivo do mapa aparecer sempre desbotado mesmo
    ---- sendo alto -- e agora que a saturacao significa magnitude, isso mentiria.
    local top = Max(0, vmax or 0)
    if top <= 0 then
        return POS_RAMP[#POS_RAMP]
    end
    return RampBand(Clamp(MulDivRound(value, 100, top), 0, 100), POS_RAMP)
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

---------------------------------------------------------------------------------------------------
-- Selecao multipla de policies (estado)
--
-- Guardada por LABEL, nao por indice: `dbg_labels_*` e reconstruido a cada Update e a
-- ordem muda quando uma policy some da lista (uma Required que falhou, por exemplo).
-- Indice sobreviveria ao redesenho apontando para outra policy.
--
-- Separada por escopo, porque a mesma policy pode ter pesos diferentes em OptLoc e End
-- Turn -- somar as duas seria somar coisas de escalas diferentes.
---------------------------------------------------------------------------------------------------

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

    elseif group == "sum_cover_threat_end" or group == "sum_cover_threat_opt" then
        local is_end = group == "sum_cover_threat_end"
        local score_tbl = (is_end and self.think_data.reachable_scores or
                              self.think_data.optimal_scores) or empty_table
        local dests = is_end and (ctx.destinations or empty_table) or
                          (ctx.all_destinations or ctx.destinations or empty_table)

        self.dbg_layer_label = table.concat(SUM_LABELS, " + ") ..
                                   (is_end and " <EndTurn>" or " <OptLoc>")

        NumericLayer(self, fx, dests, function(dest)
            local scores = score_tbl[dest]
            if not scores then
                return nil
            end
            ---- nil quando NENHUMA das duas rodou neste tile: pintar 0 ali diria
            ---- "equilibrado" quando o certo e "sem dado"
            local total, found = 0, false
            for _, label in ipairs(SUM_LABELS) do
                local v = PolicyValue(scores, label)
                if v then
                    total = total + v
                    found = true
                end
            end
            return found and total or nil
        end)

        ------------------------------------------------------------------------------
        ---- camadas de ALVO -- de cada tile alcancavel, em quem a IA atiraria e quao bem
        ------------------------------------------------------------------------------
    elseif group == "target_recalc" then
        ---- HoldPositionAI so avalia dano na posicao atual, entao as camadas de alvo
        ---- ficam com um tile so. Isto recalcula em TODOS os destinos alcancaveis --
        ---- resposta hipotetica ("se ela se movesse, atiraria em quem"), nao o que a
        ---- IA de fato avaliou. So no modo de debug, a unidade nao esta agindo.
        pcall(AIPrecalcDamageScore, ctx, ctx.destinations)
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

local PAGES = {"Unidade", "Destinos", "Alvo", "Acoes", "Camadas", "Controles"}

---- paginas ativas: conjunto {[indice] = true}. Varias podem ficar ligadas ao mesmo
---- tempo; sao concatenadas na ordem em que aparecem em PAGES.
local function EnabledPages(self)
    local on = self.dbg_pages
    if not on then
        on = {[1] = true} ---- comeca so na Unidade
        self.dbg_pages = on
    end
    for i = 1, #PAGES do
        if on[i] then
            return on
        end
    end
    on[1] = true ---- nunca deixa tudo desligado
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
    bar = bar .. "  " .. link("SetDebugPagesOnly", 1, "so Unidade", 255, 200, 0)
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
        text = text .. string.format("\n  %s: %s",
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

    return text
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

    text = text .. string.format("\n\n<color 255 200 0>Acoes</color> (%d) -- clique para forcar",
                                 #ctx.choose_actions)
    text = text .. string.format("\npeso total: %d", total)

    for i, descr in ipairs(ctx.choose_actions) do
        local action_name = descr.action and descr.action:GetEditorView() or "Base Attack"
        local val
        if descr.priority then
            val = "PRIORITY"
        elseif total > 0 then
            val = string.format("%d  (%d%%)", descr.weight or 0,
                                MulDivRound(Max(0, descr.weight or 0), 100, total))
        else
            val = tostring(descr.weight)
        end

        if self.forced_action == i then
            text = text .. string.format("\n  <color 0 255 0>%s: %s</color>", action_name, val)
        elseif (descr.weight or 0) > 0 or descr.priority then
            text = text .. "\n  " ..
                       link("UnitForceAction", i, string.format("%s: %s", action_name, val), 255,
                            255, 0)
        else
            text = text .. string.format("\n  <color 130 130 130>%s: %s</color>", action_name, val)
        end
    end

    return text
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

    ---- balanco cobertura vs exposicao: as duas policies medem lados opostos da mesma
    ---- pergunta, entao a soma delas e mais legivel que as duas camadas separadas
    text = text .. "\n\n<color 160 105 245>Soma</color> " ..
               table.concat(SUM_LABELS, " + ") .. ":"
    text = text .. "\n" .. link("ShowAIVoxels", "sum_cover_threat_opt", "OptLoc")
    text = text .. "   " .. link("ShowAIVoxels", "sum_cover_threat_end", "End Turn")

    text = text .. "\n\n<color 255 160 60>Alvo</color> (por tile alcancavel):"
    text = text .. "\n" .. link("ShowAIVoxels", "target_who", "Quem seria o alvo")
    text = text .. "   " .. link("ShowAIVoxels", "target_cth", "CTH 1o disparo")
    text = text .. "\n" .. link("ShowAIVoxels", "target_hits", "Acertos esperados")
    text = text .. "   " .. link("ShowAIVoxels", "target_score", "Score de alvo (cru)")
    text = text .. "\n" ..
               link("ShowAIVoxels", "target_recalc", "Recalcular alvo em TODOS os tiles", 255, 160, 60)
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
        pcall(AIPrecalcDamageScore, ctx, {d}, nil, ctx.dbg_enemy_damage_score)
    end

    local chosen = ctx.dest_target and ctx.dest_target[d]
    local hits = ctx.dest_hit_score and ctx.dest_hit_score[d]

    if is_current then
        text = text .. "\n\n<color 255 200 0>Na posicao ATUAL</color>" ..
                   " <color 150 150 150>(behavior sem ai_destination, ex. HoldPosition)</color>"
    else
        text = text .. "\n\n<color 255 200 0>No destino escolhido</color>"
    end
    text = text .. string.format("\n  alvo: <color 0 255 0>%s</color>",
                                 IsValid(chosen) and chosen.session_id or "nenhum")
    text = text .. string.format("\n  dest_target_score: %s",
                                 tostring(ctx.dest_target_score and ctx.dest_target_score[d]))
    text = text .. string.format("\n  CTH 1o disparo: %s",
                                 tostring(ctx.dest_cth and ctx.dest_cth[d]))
    if hits then
        ---- hit_score e "acertos esperados x100"; parte inteira e centesimos, so com
        ---- aritmetica inteira para nao passar float para o %d
        local frac = hits % 100
        text = text .. string.format("\n  acertos esperados: %d.%02d  (hit_score bruto %d)",
                                     (hits - frac) / 100, frac, hits)
    end
    text = text .. string.format("\n  recoil no alvo: %s",
                                 tostring(ctx.dest_target_recoil_cth and
                                              ctx.dest_target_recoil_cth[d]))
    text = text .. string.format("\n  ataques permitidos (max_attacks): %s",
                                 tostring(ctx.max_attacks))

    ---- por-alvo naquele destino. dest_target_dist / _cover_score / _los sao campos
    ---- do AIPrecalcDamageScore do Rato AI Overhaul; sem ele, ficam nil.
    local dists = ctx.dest_target_dist and ctx.dest_target_dist[d]
    local covers = ctx.dest_target_cover_score and ctx.dest_target_cover_score[d]
    local los = ctx.dest_target_los and ctx.dest_target_los[d]
    local scored = ctx.dbg_enemy_damage_score

    text = text .. "\n\n<color 255 200 0>Candidatos</color>  (#i = cor na camada de mapa)"
    text = text .. "\n<color 120 120 120>  #  alvo            dist  cover  LOS  score</color>"

    for i, enemy in ipairs(ctx.enemies or empty_table) do
        if IsValid(enemy) then
            local dist = dists and dists[enemy]
            local cover = covers and covers[enemy]
            local l = los and los[enemy]
            local sc = scored and scored[enemy]

            local marker = (enemy == chosen) and "<color 0 255 0>" or
                               (sc and "<color 255 255 255>" or "<color 150 150 150>")

            text = text .. string.format("\n%s  #%-2d %-14s %5s %6s %4s %6s</color>",
                                         marker, i,
                                         tostring(enemy.session_id):sub(1, 14),
                                         dist and tostring(MulDivRound(dist, 1, const.SlabSizeX)) or
                                             "-",
                                         cover and tostring(cover) or "-",
                                         l and tostring(l) or "-",
                                         sc and tostring(sc) or "-")
        end
    end

    text = text .. "\n\n<color 120 120 120>verde = escolhido | branco = passou o corte de 80% | cinza = descartado</color>"
    text = text .. "\n<color 120 120 120>score so aparece para quem entrou no sorteio</color>"
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
    return text
end

local PAGE_FUNCS = {PageUnidade, PageDestinos, PageAlvo, PageAcoes, PageCamadas,
                    PageControles}

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
        text = text .. string.format("Selected unit: %s, AP = %d", unit.session_id,
                                     (unit.ActionPoints / const.Scale.AP))
        text = text .. string.format("\n   Archetype: %s (Unaware)", unit:GetArchetype().id)
        text = text .. string.format("\n   AI Keywords: %s",
                                     table.concat(unit.AIKeywords or empty_table, ","))
        text = text .. "\n\n" .. link("WakeUp", nil, "Alert")
        text = text .. "   " .. link("WakeUp", "reposition", "Alert+Reposition")
        ctrl:SetText(text)
        return
    end

    if not self.ai_context then
        text = text .. string.format("Selected unit: %s, AP = %d", unit.session_id,
                                     (unit.ActionPoints / const.Scale.AP))
        text = text .. string.format("\n   Archetype: %s (AI disabled)", unit:GetArchetype().id)
        text = text .. string.format("\n   AI Keywords: %s",
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
