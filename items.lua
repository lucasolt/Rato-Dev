return {
	PlaceObj('ModItemFolder', {
		'name', "Utility",
	}, {
		PlaceObj('ModItemCode', {
			'name', "ForceDev",
			'CodeFileName', "Code/ForceDev.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "ForceShowCTH",
			'CodeFileName', "Code/ForceShowCTH.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "magazine_check",
			'CodeFileName', "Code/magazine_check.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "magazine_build",
			'CodeFileName', "Code/magazine_build.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "extract_functions",
			'CodeFileName', "Code/extract_functions.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "extract_unit",
			'CodeFileName', "Code/extract_unit.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "fix_editor_enemysquads",
			'CodeFileName', "Code/fix_editor_enemysquads.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "rew_table_separator",
			'CodeFileName', "Code/rew_table_separator.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "PrintAttack",
			'CodeFileName', "Code/PrintAttack.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "FirearmExec_debug",
			'CodeFileName', "Code/FirearmExec_debug.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "CheckIfChangedPatchingMethod",
			'CodeFileName', "Code/CheckIfChangedPatchingMethod.lua",
		}),
		}),
	PlaceObj('ModItemCode', {
		'name', "used_comps_brute_TOG",
		'CodeFileName', "Code/used_comps_brute_TOG.lua",
	}),
	PlaceObj('ModItemCode', {
		'name', "Script1",
		'CodeFileName', "Code/Script1.lua",
	}),
	PlaceObj('ModItemCode', {
		'name', "RATOAI_WORKSHOP",
		'CodeFileName', "Code/RATOAI_WORKSHOP.lua",
	}),
	PlaceObj('ModItemCode', {
		'CodeFileName', "Code/Script.lua",
	}),
	PlaceObj('ModItemFolder', {
		'name', "TOGPATCHWORKSHOP",
	}),
	PlaceObj('ModItemInventoryItemCompositeDef', {
		'Id', "NewInventoryItem",
		'object_class', "AssaultRifle",
		'ScrapParts', 15,
		'RepairCost', 110,
		'Reliability', 95,
		'Icon', "Mod/KKh3Yhf/Images/G11_icon.png",
		'DisplayName', T(987267705513, --[[ModItemInventoryItemCompositeDef NewInventoryItem DisplayName]] "G 11 test"),
		'DisplayNamePlural', T(434010049423, --[[ModItemInventoryItemCompositeDef NewInventoryItem DisplayNamePlural]] "G 11s"),
		'Description', T(483015059058, --[[ModItemInventoryItemCompositeDef NewInventoryItem Description]] "<style PerkststsBold ><scale 900>The G11 is a non-production prototype assault rifle developed from the late 1960s-1980s.<newline><newline>It was primarily a project of West Germany, though it was of significance to the other NATO countries as well. In particular, versions of the G11 were included in the U.S. Advanced Combat Rifle program. In 1990, the development of the G11 was finished.<newline><newline>Although the weapon was a technical success, it never entered full production due to the political changes of German reunification and lack of procurement contract.<newline><newline>Only 1000 units were ever produced, some of which made their way into the hands of the Bundeswehr. Ultimately, the German armed forces replaced the G3 with the G36.<newline><newline><style MMOptionEntry>Made in Germany <image UI/Icons/Flags/f_germany.dds 1600>"),
		'AdditionalHint', T(400305309563, --[[ModItemInventoryItemCompositeDef NewInventoryItem AdditionalHint]] "<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Longer range\n<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Increased bonus from Aiming\n<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Low attack costs\n<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Exceptionaly low reload costs"),
		'LargeItem', 1,
		'UnitStat', "Marksmanship",
		'Cost', 24499,
		'Tier', 3,
		'MaxStock', 2,
		'RestockWeight', 25,
		'CategoryPair', "AssaultRifles",
		'Caliber', "556",
		'Damage', 24,
		'AimAccuracy', 8,
		'MagazineSize', 45,
		'PenetrationClass', 2,
		'WeaponRange', 30,
		'OverwatchAngle', 1818,
		'HandSlot', "TwoHanded",
		'Entity', "G11",
		'fxClass', "G36",
		'ComponentSlots', {
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Barrel",
				'AvailableComponents', {
					"G11_Barrel_def_1",
					"G11_Barrel_ext_1",
				},
				'DefaultComponent', "G11_Barrel_def_1",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Scope",
				'AvailableComponents', {
					"G11_Scope_1",
					"G11_Rail_1",
				},
				'DefaultComponent', "G11_Scope_1",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Muzzle",
				'AvailableComponents', {
					"CAWS_Muzzle_def_1",
					"RAT_TOG_compensator",
					"RAT_TOG_suppressor_762",
				},
				'DefaultComponent', "CAWS_Muzzle_def_1",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Magazine",
				'AvailableComponents', {
					"G11_Mag_def_1",
					"G11_Mag_ext_1",
					"G11_Mag_ext2_1",
				},
				'DefaultComponent', "G11_Mag_def_1",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Under",
				'CanBeEmpty', true,
				'AvailableComponents', {
					"G11_Grenadelauncher_1",
					"G11_Grip_CAWS_1",
				},
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Bipod",
				'CanBeEmpty', true,
				'AvailableComponents', {
					"G11_Bipod_1",
				},
			}),
		},
		'HolsterSlot', "Shoulder",
		'AvailableAttacks', {
			"BurstFire",
			"MGBurstFire",
			"AutoFire",
			"SingleShot",
			"CancelShot",
		},
		'ShootAP', 4000,
	}),
	PlaceObj('ModItemInventoryItemCompositeDef', {
		'Id', "NewInventoryItem_copy",
		'object_class', "AssaultRifle",
		'ScrapParts', 10,
		'Reliability', 90,
		'Icon', "Mod/KKh3Yhf/Images/A91_icon.png",
		'DisplayName', T(524387256746, --[[ModItemInventoryItemCompositeDef NewInventoryItem_copy DisplayName]] "A91 TESTE"),
		'DisplayNamePlural', T(900526981251, --[[ModItemInventoryItemCompositeDef NewInventoryItem_copy DisplayNamePlural]] "A91s"),
		'Description', T(832950361147, --[[ModItemInventoryItemCompositeDef NewInventoryItem_copy Description]] "<style PerkststsBold ><scale 900>The A-91 is a bullpup assault rifle developed during the 1990s as an offspring of the 9A-91 firearm family.<newline><newline>The A-91 has a forward ejection system, initially developed in Tula by designers like Afanasiev during the early 1960s. In this system, the ejection port is located right above the pistol grip, and is directed forward. Extracted cases go from bolt head through the short ejection tube to the ejection port, and fall out of the gun well clear of the shooter's face, even when firing from the left shoulder.<newline><newline> As for now, the A-91 is made in small numbers and, probably, is used by some elite police units in Russia<newline><newline><style MMOptionEntry>Made in Russia <image UI/Icons/Flags/f_russia.dds 1600>"),
		'AdditionalHint', T(836660682051, --[[ModItemInventoryItemCompositeDef NewInventoryItem_copy AdditionalHint]] "<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Low damage\n<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Increased bonus from Aiming\n<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Low attack costs\n<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Increased Reload cost\n<image UI/Conversation/T_Dialogue_IconBackgroundCircle.tga 400 130 128 120> Less noisy"),
		'LargeItem', 1,
		'UnitStat', "Marksmanship",
		'Cost', 2500,
		'RestockWeight', 40,
		'CategoryPair', "AssaultRifles",
		'Caliber', "556",
		'Damage', 17,
		'AimAccuracy', 5,
		'CritChanceScaled', 20,
		'MagazineSize', 30,
		'PenetrationClass', 2,
		'WeaponRange', 24,
		'OverwatchAngle', 1440,
		'Noise', 10,
		'HandSlot', "TwoHanded",
		'Entity', "A91_556",
		'ComponentSlots', {
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Under",
				'CanBeEmpty', true,
				'AvailableComponents', {
					"VerticalGrip",
				},
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Bipod",
				'CanBeEmpty', true,
				'AvailableComponents', {
					"Bipod",
				},
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "General",
				'Modifiable', false,
				'AvailableComponents', {
					"bullup",
				},
				'DefaultComponent', "bullup",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Grenadelauncher",
				'Modifiable', false,
				'AvailableComponents', {
					"M60_GrenadeLauncher_1",
				},
				'DefaultComponent', "M60_GrenadeLauncher_1",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Side",
				'CanBeEmpty', true,
				'AvailableComponents', {
					"Flashlight",
					"LaserDot",
					"FlashlightDot",
					"UVDot",
				},
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Barrel",
				'AvailableComponents', {
					"A91_762_barrel_shrt_1",
					"A91_762_barrel_def_1",
					"A91_762_barrel_ext_1",
				},
				'DefaultComponent', "A91_762_barrel_def_1",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Scope",
				'AvailableComponents', {
					"LROptics",
					"ReflexSight",
					"ScopeCOGQuick",
					"ScopeCOG",
					"ThermalScope",
					"RAT_TOG_vigilanceRS",
					"RAT_TOG_WideScope",
					"DefaultIronsight_AR15",
				},
				'DefaultComponent', "DefaultIronsight_AR15",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Muzzle",
				'Modifiable', false,
				'AvailableComponents', {
					"ToG_VFX_Muzzle",
				},
				'DefaultComponent', "ToG_VFX_Muzzle",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Gassblock",
				'AvailableComponents', {
					"RAT_TOG_CompensatorNoEntity",
				},
				'DefaultComponent', "RAT_TOG_CompensatorNoEntity",
			}),
			PlaceObj('WeaponComponentSlot', {
				'SlotType', "Magazine",
				'AvailableComponents', {
					"A91_762_mag_def_1",
					"A91_762_mag_ext_1",
				},
				'DefaultComponent', "A91_762_mag_def_1",
			}),
		},
		'HolsterSlot', "Shoulder",
		'AvailableAttacks', {
			"BurstFire",
			"AutoFire",
			"SingleShot",
			"CancelShot",
		},
		'ShootAP', 5000,
		'ReloadAP', 4000,
	}),
	PlaceObj('ModItemCode', {
		'name', "Script3",
		'CodeFileName', "Code/Script3.lua",
	}),
	PlaceObj('ModItemCode', {
		'name', "Script2",
		'CodeFileName', "Code/Script2.lua",
	}),
	PlaceObj('ModItemFolder', {
		'name', "IA Debug Tools",
	}, {
		PlaceObj('ModItemCode', {
			'name', "RATODBG_AIDebugUI",
			'CodeFileName', "Code/RATODBG_AIDebugUI.lua",
		}),
		PlaceObj('ModItemCode', {
			'name', "RATOTEL_AITelemetry",
			'CodeFileName', "Code/RATOTEL_AITelemetry.lua",
		}),
		}),
}