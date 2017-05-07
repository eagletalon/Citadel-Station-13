/datum/antagonist/cult
	var/datum/action/innate/cultcomm/communion = new

/datum/antagonist/cult/Destroy()
	qdel(communion)
	return ..()

/datum/antagonist/cult/can_be_owned(datum/mind/new_owner)
	. = ..()
	if(.)
		. = is_convertable_to_cult(new_owner.current)

/datum/antagonist/cult/on_gain()
	. = ..()
	SSticker.mode.cult += owner
	SSticker.mode.update_cult_icons_added(owner)
	if(istype(SSticker.mode, /datum/game_mode/cult))
		var/datum/game_mode/cult/C = SSticker.mode
		C.memorize_cult_objectives(owner)
	if(jobban_isbanned(owner.current, ROLE_CULTIST))
		addtimer(CALLBACK(SSticker.mode, /datum/game_mode.proc/replace_jobbaned_player, owner.current, ROLE_CULTIST, ROLE_CULTIST), 0)
	owner.current.log_message("<font color=#960000>Has been converted to the cult of Nar'Sie!</font>", INDIVIDUAL_ATTACK_LOG)

/datum/antagonist/cult/apply_innate_effects(mob/living/mob_override)
	. = ..()
	var/mob/living/current = owner.current
	if(mob_override)
		current = mob_override
	current.faction |= "cult"
	current.verbs += /mob/living/proc/cult_help
	communion.Grant(current)

/datum/antagonist/cult/remove_innate_effects(mob/living/mob_override)
	. = ..()
	var/mob/living/current = owner.current
	if(mob_override)
		current = mob_override
	current.faction -= "cult"
	current.verbs -= /mob/living/proc/cult_help
	communion.Remove(current)

/datum/antagonist/cult/on_removal()
	owner.wipe_memory()
	SSticker.mode.cult -= owner
	SSticker.mode.update_cult_icons_removed(owner)
	if(!silent)
		to_chat(owner.current, "<span class='userdanger'>An unfamiliar white light flashes through your mind, cleansing the taint of the Geometer and all your memories as her servant.</span>")
		owner.current.log_message("<font color=#960000>Has renounced the cult of Nar'Sie!</font>", INDIVIDUAL_ATTACK_LOG)
		owner.current.visible_message("<span class='big'>[owner.current] looks like [owner.current.p_they()] just reverted to their old faith!</span>")
	if(GLOB.blood_target && GLOB.blood_target_image && owner.current.client)
		owner.current.client.images -= GLOB.blood_target_image
	. = ..()

/datum/antagonist/cult/master
	var/datum/action/innate/cultmast/finalreck/reckoning = new
	var/datum/action/innate/cultmast/cultmark/bloodmark = new

/datum/antagonist/cult/master/Destroy()
	QDEL_NULL(reckoning)
	QDEL_NULL(bloodmark)
	return ..()

/datum/antagonist/cult/master/on_gain()
	. = ..()
	var/mob/living/current = owner.current
	SSticker.mode.set_antag_hud(current, "cultmaster")

/datum/antagonist/cult/master/greet()
	to_chat(owner.current, "<span class='cultlarge'>You are the cult's Master</span>. As the cult's Master, you have a unique title and loud voice when communicating, are capable of marking \
	targets, such as a location or a noncultist, to direct the cult to them, and, finally, you are capable of summoning the entire living cult to your location <b><i>once</i></b>.")
	to_chat(owner.current, "Use these abilities to direct the cult to victory at any cost.")

/datum/antagonist/cult/master/apply_innate_effects(mob/living/mob_override)
	. = ..()
	var/mob/living/current = owner.current
	if(mob_override)
		current = mob_override
	if(!GLOB.reckoning_complete)
		reckoning.Grant(current)
	bloodmark.Grant(current)
	current.update_action_buttons_icon()
	current.apply_status_effect(/datum/status_effect/cult_master)

/datum/antagonist/cult/master/remove_innate_effects(mob/living/mob_override)
	. = ..()
	var/mob/living/current = owner.current
	if(mob_override)
		current = mob_override
	reckoning.Remove(current)
	bloodmark.Remove(current)
	current.update_action_buttons_icon()
	current.remove_status_effect(/datum/status_effect/cult_master)
