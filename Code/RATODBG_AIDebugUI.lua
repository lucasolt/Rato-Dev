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

---- gradiente do pior para o melhor (indice 1 = zero / sem valor)
local RAMP = {
    RGB(120, 120, 130),
    RGB(210, 55, 45),
    RGB(230, 130, 35),
    RGB(225, 210, 60),
    RGB(120, 220, 70),
    RGB(60, 245, 140),
}
---- cortes do gradiente, em % da faixa [min, max]
local RAMP_STOPS = {20, 40, 60, 80}

---- finalista = passou o corte de AIDecisionThreshold. Branco de proposito: a rampa
---- de gradiente nunca produz branco, entao nao ha como confundir com "score alto".
local CLR_FINALIST = RGB(255, 255, 255)
local RING_SCALE = 165 ---- % do tamanho do quadrado normal
local CLR_NEG = RGB(180, 60, 200) ---- score negativo

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
local function ScoreColor(value, vmin, vmax)
    if not value then
        return RAMP[1]
    end
    if value < 0 then
        return CLR_NEG
    end
    if value == 0 then
        return RAMP[1]
    end
    local span = (vmax or 0) - (vmin or 0)
    if span <= 0 then
        return RAMP[#RAMP]
    end
    local t = Clamp(MulDivRound(value - vmin, 100, span), 0, 100)
    ---- bandas explicitas: divisao em Lua devolve float e RAMP[4.5] seria nil
    local idx = #RAMP
    for i, stop in ipairs(RAMP_STOPS) do
        if t < stop then
            idx = i + 1
            break
        end
    end
    return RAMP[idx]
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
                fx[#fx + 1] = PlaceSquareFX(5 * guic, pt, RAMP[1])
                fx[#fx + 1] = PlaceTextFx("-", pt, RAMP[1])
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

    self.dbg_labels_end = CollectPolicyLabels(td.reachable_scores)
    if #self.dbg_labels_end > 0 then
        text = text .. "\n\n<color 0 255 255>End-Turn policies</color> (por slab):"
        for i, label in ipairs(self.dbg_labels_end) do
            local mark = (self.dbg_layer == "policy_end_" .. i) and
                             " <color 0 255 0>&lt;&lt;</color>" or ""
            text = text .. "\n  " .. link("ShowAIVoxels", "policy_end_" .. i, label) .. mark
        end
    end

    self.dbg_labels_opt = CollectPolicyLabels(td.optimal_scores)
    if #self.dbg_labels_opt > 0 then
        text = text .. "\n\n<color 0 255 0>Optimal-Location policies</color> (por slab):"
        for i, label in ipairs(self.dbg_labels_opt) do
            local mark = (self.dbg_layer == "policy_opt_" .. i) and
                             " <color 0 255 0>&lt;&lt;</color>" or ""
            text = text .. "\n  " .. link("ShowAIVoxels", "policy_opt_" .. i, label) .. mark
        end
    end

    if self.dbg_layer and self.dbg_layer_range then
        local vmin, vmax, threshold = self.dbg_layer_range[1], self.dbg_layer_range[2],
                                      self.dbg_layer_range[3]
        text = text .. "\n\n<color 255 200 0>Camada ativa:</color> " ..
                   (self.dbg_layer_label or self.dbg_layer)
        text = text .. string.format("\n  faixa: %d .. %d", vmin or 0, vmax or 0)
        if threshold then
            text = text .. string.format("\n  corte (%d%% do melhor): %d",
                                         const.AIDecisionThreshold, threshold)
            text = text .. "\n  <color 255 255 255>anel branco maior + *</color> = finalista (entra no sorteio)"
        end
        text = text ..
                   "\n  <color 210 55 45>pior</color> <color 230 130 35>-</color> <color 225 210 60>-</color> <color 120 220 70>-</color> <color 60 245 140>melhor</color>"
        text = text .. "   <color 180 60 200>roxo</color> = negativo"
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
