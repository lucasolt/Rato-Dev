found_comp = {}

function get_components_with(effect)
	local effect = effect or "IncreaseAimAccuracy"
	for v,k in pairs(WeaponComponents) do
		if k.ModificationEffects then
			
		for i, eff in ipairs(k.ModificationEffects) do
			if eff == effect then
				found_comp[k.Slot] = found_comp[k.Slot] or {}
				table.insert(found_comp[k.Slot], v)
			end
		end
	end
	end
end