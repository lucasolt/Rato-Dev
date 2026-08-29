--[[
    RATODBG_CheatLog

    Overwrite dos cheats do vanilla (ModTools/Src/Lua/Cheat.lua) so para
    LOGAR no console toda vez que um cheat e ativado ou desativado, e
    expor uma funcao que imprime o estado atual de todos os cheats.

    - RatoDumpCheats()            -> imprime tudo (ativo / inativo)
    - RatoDumpCheats("God")       -> filtra por nome (case-insensitive)
    - console: chame  RatoDumpCheats()

    Ponto unico de mutacao no vanilla: NetSyncEvents.CheatEnable(id, state, side, args)
    (Cheat.lua:56). Envelopamos essa funcao: roda o original, le o estado
    final de gv_Cheats e loga a transicao.
]] --

if FirstLoad then
    RATO_CheatLog_orig_CheatEnable = false
end

local function rato_cheat_state(id, side)
    if not gv_Cheats then return nil end
    local v = gv_Cheats[id]
    if type(v) == "table" then
        if side then return v[side] end
        -- resume por lado
        local parts = {}
        for s, on in sorted_pairs(v) do
            parts[#parts + 1] = string.format("%s=%s", s, on and "ON" or "off")
        end
        return #parts > 0 and table.concat(parts, " ") or false
    end
    return v
end

local function rato_fmt(val)
    if val == true then return "ON" end
    if val == false or val == nil then return "off" end
    return tostring(val)
end

-- ---------------------------------------------------------------------------
-- Overwrite: NetSyncEvents.CheatEnable
-- ---------------------------------------------------------------------------
RATO_CheatLog_orig_CheatEnable = rawget(NetSyncEvents, "CheatEnable") or RATO_CheatLog_orig_CheatEnable

function NetSyncEvents.CheatEnable(id, state, side, args)
    local before = rato_cheat_state(id, side)

    if RATO_CheatLog_orig_CheatEnable then
        RATO_CheatLog_orig_CheatEnable(id, state, side, args)
    end

    local after = rato_cheat_state(id, side)
    local changed = before ~= after
    local tag = changed and "CHEAT >>" or "CHEAT  ="
    print(string.format("%s %s%s : %s -> %s%s",
        tag,
        id,
        side and (" [" .. tostring(side) .. "]") or "",
        rato_fmt(before),
        rato_fmt(after),
        changed and "" or "  (sem mudanca)"))
end

-- ---------------------------------------------------------------------------
-- Dump do estado atual de todos os cheats
-- ---------------------------------------------------------------------------
function check_cheats(filter)
    if not gv_Cheats then
        print("RatoDumpCheats: gv_Cheats ainda nao existe (entra numa campanha primeiro)")
        return
    end
    filter = filter and string.lower(filter) or nil

    local on, off = {}, {}
    for id in sorted_pairs(gv_Cheats) do
        if not filter or string.find(string.lower(id), filter, 1, true) then
            local v = gv_Cheats[id]
            if type(v) == "table" then
                local any = false
                local parts = {}
                for s, s_on in sorted_pairs(v) do
                    parts[#parts + 1] = string.format("%s=%s", s, s_on and "ON" or "off")
                    any = any or s_on
                end
                local line = string.format("  %-22s %s", id, table.concat(parts, "  "))
                if any then on[#on + 1] = line else off[#off + 1] = line end
            else
                local line = string.format("  %-22s %s", id, rato_fmt(v))
                if v then on[#on + 1] = line else off[#off + 1] = line end
            end
        end
    end

    print("===== RatoDumpCheats" .. (filter and (" (filtro: " .. filter .. ")") or "") .. " =====")
    print("-- ATIVOS --")
    if #on == 0 then print("  (nenhum)") else print(table.concat(on, "\n")) end
    print("-- INATIVOS --")
    if #off == 0 then print("  (nenhum)") else print(table.concat(off, "\n")) end
    print("==================================")
end
