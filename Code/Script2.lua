function findprop()
	for i, prop in ipairs(FirearmProperties.properties) do
		if prop.id == "MaxAimActions" then
			print(prop)
			break
		end
	end
end