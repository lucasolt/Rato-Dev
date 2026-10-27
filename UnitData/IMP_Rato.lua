UndefineClass('IMP_Rato')
DefineClass.IMP_Rato = {
	__parents = { "UnitData" },
	__generated_by_class = "ModItemUnitDataCompositeDef",


	object_class = "UnitData",
	Health = 30,
	Agility = 30,
	Dexterity = 30,
	Strength = 30,
	Wisdom = 30,
	Leadership = 30,
	Marksmanship = 30,
	Mechanical = 0,
	Explosives = 0,
	Medical = 0,
	Portrait = "Mod/WxLXvdc/Images/IMP_Rato_small.png",
	BigPortrait = "Mod/WxLXvdc/Images/IMP_Rato_big.png",
	IsMercenary = true,
	Name = T(152196758436, --[[ModItemUnitDataCompositeDef IMP_Rato Name]] "Alpha"),
	Nick = T(245205059561, --[[ModItemUnitDataCompositeDef IMP_Rato Nick]] "Alpha"),
	AllCapsNick = T(757948885932, --[[ModItemUnitDataCompositeDef IMP_Rato AllCapsNick]] "ALPHA"),
	Affiliation = "Other",
	HireStatus = "NotMet",
	Bio = T(547482275590, --[[ModItemUnitDataCompositeDef IMP_Rato Bio]] "A merc based on your I.M.P. evaluation."),
	SalaryLv1 = 0,
	SalaryMaxLv = 0,
	MaxHitPoints = 80,
	AppearancesList = {
		PlaceObj('AppearanceWeight', {
			'Preset', "Rato",
		}),
	},
	Equipment = {
		"IMP_equipment_basic",
	},
	Specialization = "AllRounder",
	pollyvoice = "Geraint",
	gender = "Male",
	VoiceResponseId = "IMP_male_01",
}

