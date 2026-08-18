Platform.developer = true
Platform.cheats = true
Platform.rat = true

--[[
    CommonLua/Preset.lua:1808 define SaveCollapsedPresetGroups / LoadCollapsedPresetGroups
    dentro de "if Platform.developer and not Platform.ged". Esse arquivo roda no autorun,
    quando Platform.developer ainda e nil (build goldmaster + sem developer.lua na raiz),
    entao as funcoes nunca sao criadas. A flag so vira true aqui, DEPOIS - e ai o
    Msg("ClassesBuilt") chama LoadCollapsedPresetGroups em XTemplate.lua:1494 e em
    ClassDef-PresetDefs.generated.lua:2056, batendo num global nil.
    Em ClassDef-PresetDefs o erro ainda aborta a funcao antes do GedRebindRoot da linha 2058.
    ReloadLua (lib.lua:338) re-executa o autorun e zera a flag de novo, entao o buraco
    volta a cada reload. Corpo copiado do vanilla, Preset.lua:1812-1834.
]] --

if not rawget(_G, "LoadCollapsedPresetGroups") then
    function LoadCollapsedPresetGroups()
        local collapsed = GetDeveloperOption("CollapsedPresetGroups")
        if not collapsed then
            return
        end
        for _, item in ipairs(collapsed) do
            local preset_group = Presets[item[1]]
            local group = preset_group and preset_group[item[2]]
            if group then
                GedTreePanelCollapsedNodes[group] = true
            end
        end
    end
end

if not rawget(_G, "SaveCollapsedPresetGroups") then
    function SaveCollapsedPresetGroups()
        local collapsed = {}
        for presets_name, groups in pairs(Presets) do
            for group_name, group in pairs(groups) do
                if type(group_name) == "string" and GedTreePanelCollapsedNodes[group] then
                    collapsed[#collapsed + 1] = {presets_name, group_name}
                end
            end
        end
        SetDeveloperOption("CollapsedPresetGroups", collapsed)
    end

    --- sem este handler o estado de colapso nunca e gravado e o Load acima le sempre vazio
    GedSaveCollapsedPresetGroupsThread = rawget(_G, "GedSaveCollapsedPresetGroupsThread") or false

    function OnMsg.GedTreeNodeCollapsedChanged()
        DeleteThread(GedSaveCollapsedPresetGroupsThread)
        GedSaveCollapsedPresetGroupsThread = CreateRealTimeThread(function()
            Sleep(250)
            SaveCollapsedPresetGroups()
        end)
    end
end

--[[
    Cala os asserts de localizacao que reclamam de texto plano onde se espera um T:
      localization.lua:673  "Attempt to use plain text or numbers '%s' as a localized string"
      localization.lua:319  "Attempt to concatenate plain text or numbers '%s' to a localized string"
      localization.lua:337  idem, para o segundo operando
      localization.lua:410  "Separator in table.concat must be a localized string ..."

    IsTagsAndPunctuation (localization.lua:133) e usada em exatamente dois lugares, e os
    dois sao caminhos de assert de debug: a linha 673, e IsTCompatible (localization.lua:40),
    que por sua vez so existe de verdade sob Platform.debug e so alimenta os asserts de
    concatenacao. Forcar true nao muda o resultado de nenhuma concatenacao: no ramo do
    assert o codigo faz exatamente o mesmo com a string ({T1} / T1[1+#T1] = T2).

    Nao mexe nos asserts de "invalid value" (319/340) nem em nenhum outro erro Lua - esses
    continuam aparecendo normalmente.

    Para voltar ao normal em runtime:  IsTagsAndPunctuation = RATODEV_IsTagsAndPunctuation
]] --

if not rawget(_G, "RATODEV_IsTagsAndPunctuation") then
    RATODEV_IsTagsAndPunctuation = IsTagsAndPunctuation
end

function IsTagsAndPunctuation(str)
    return true
end
