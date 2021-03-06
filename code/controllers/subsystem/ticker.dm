#define ROUND_START_MUSIC_LIST "strings/round_start_sounds.txt"

SUBSYSTEM_DEF(ticker)
	name = "Ticker"
	init_order = INIT_ORDER_TICKER

	priority = 200
	flags = SS_FIRE_IN_LOBBY|SS_KEEP_TIMING

	var/current_state = GAME_STATE_STARTUP	//state of current round (used by process()) Use the defines GAME_STATE_* !
	var/force_ending = 0					//Round was ended by admin intervention
	// If true, there is no lobby phase, the game starts immediately.
	var/start_immediately = FALSE

	var/hide_mode = 0
	var/datum/game_mode/mode = null
	var/event_time = null
	var/event = 0

	var/login_music							//music played in pregame lobby
	var/round_end_sound						//music/jingle played when the world reboots

	var/list/datum/mind/minds = list()		//The characters in the game. Used for objective tracking.

	var/list/syndicate_coalition = list()	//list of traitor-compatible factions
	var/list/factions = list()				//list of all factions
	var/list/availablefactions = list()		//list of factions with openings
	var/list/scripture_states = list(SCRIPTURE_DRIVER = TRUE, \
	SCRIPTURE_SCRIPT = FALSE, \
	SCRIPTURE_APPLICATION = FALSE, \
	SCRIPTURE_REVENANT = FALSE, \
	SCRIPTURE_JUDGEMENT = FALSE) //list of clockcult scripture states for announcements

	var/delay_end = 0						//if set true, the round will not restart on it's own

	var/triai = 0							//Global holder for Triumvirate
	var/tipped = 0							//Did we broadcast the tip of the day yet?
	var/selected_tip						// What will be the tip of the day?

	var/timeLeft						//pregame timer
	var/start_at

	var/gametime_offset = 432000 // equal to 12 hours, making gametime at roundstart 12:00:00

	var/totalPlayers = 0					//used for pregame stats on statpanel
	var/totalPlayersReady = 0				//used for pregame stats on statpanel

	var/queue_delay = 0
	var/list/queued_players = list()		//used for join queues when the server exceeds the hard population cap

	var/obj/screen/cinematic = null			//used for station explosion cinematic

	var/maprotatechecked = 0

	var/news_report

	var/late_join_disabled

	var/round_start_time = 0
	var/list/round_start_events

	var/modevoted = FALSE					//Have we sent a vote for the gamemode?

/datum/controller/subsystem/ticker/Initialize(timeofday)
	var/list/music = world.file2list(ROUND_START_MUSIC_LIST, "\n")
	login_music = pick(music)

	if(!GLOB.syndicate_code_phrase)
		GLOB.syndicate_code_phrase	= generate_code_phrase()
	if(!GLOB.syndicate_code_response)
		GLOB.syndicate_code_response = generate_code_phrase()
	..()
	start_at = world.time + (config.lobby_countdown * 10)

/datum/controller/subsystem/ticker/fire()
	switch(current_state)
		if(GAME_STATE_STARTUP)
			if(Master.initializations_finished_with_no_players_logged_in)
				start_at = world.time + (config.lobby_countdown * 10)
			for(var/client/C in GLOB.clients)
				window_flash(C, ignorepref = TRUE) //let them know lobby has opened up.
			to_chat(world, "<span class='boldnotice'>Welcome to [station_name()]!</span>")
			current_state = GAME_STATE_PREGAME
			if(!modevoted)
				send_gamemode_vote()
			fire()
		if(GAME_STATE_PREGAME)
				//lobby stats for statpanels
			if(isnull(timeLeft))
				timeLeft = max(0,start_at - world.time)
			totalPlayers = 0
			totalPlayersReady = 0
			for(var/mob/dead/new_player/player in GLOB.player_list)
				++totalPlayers
				if(player.ready)
					++totalPlayersReady

			if(start_immediately)
				timeLeft = 0

			//countdown
			if(timeLeft < 0)
				return
			timeLeft -= wait

			if(timeLeft <= 300 && !tipped)
				send_tip_of_the_round()
				tipped = TRUE

			if(timeLeft <= 0)
				current_state = GAME_STATE_SETTING_UP
				if(start_immediately)
					fire()

		if(GAME_STATE_SETTING_UP)
			if(!setup())
				//setup failed
				current_state = GAME_STATE_STARTUP

		if(GAME_STATE_PLAYING)
			mode.process(wait * 0.1)
			check_queue()
			check_maprotate()
			scripture_states = scripture_unlock_alert(scripture_states)
			SSshuttle.autoEnd()

			if(!mode.explosion_in_progress && mode.check_finished() || force_ending)
				current_state = GAME_STATE_FINISHED
				toggle_ooc(1) // Turn it on
				declare_completion(force_ending)

/datum/controller/subsystem/ticker/proc/setup()
	to_chat(world, "<span class='boldannounce'>Starting game...</span>")
	var/init_start = world.timeofday
		//Create and announce mode
	var/list/datum/game_mode/runnable_modes
	if(GLOB.master_mode == "random" || GLOB.master_mode == "secret")
		runnable_modes = config.get_runnable_modes()

		if(GLOB.master_mode == "secret")
			hide_mode = 1
			if(GLOB.secret_force_mode != "secret")
				var/datum/game_mode/smode = config.pick_mode(GLOB.secret_force_mode)
				if(!smode.can_start())
					message_admins("\blue Unable to force secret [GLOB.secret_force_mode]. [smode.required_players] players and [smode.required_enemies] eligible antagonists needed.")
				else
					mode = smode

		if(!mode)
			if(!runnable_modes.len)
				to_chat(world, "<B>Unable to choose playable game mode.</B> Reverting to pre-game lobby.")
				return 0
			mode = pickweight(runnable_modes)

	else
		mode = config.pick_mode(GLOB.master_mode)
		if(!mode.can_start())
			to_chat(world, "<B>Unable to start [mode.name].</B> Not enough players, [mode.required_players] players and [mode.required_enemies] eligible antagonists needed. Reverting to pre-game lobby.")
			qdel(mode)
			mode = null
			SSjob.ResetOccupations()
			return 0

	CHECK_TICK
	//Configure mode and assign player to special mode stuff
	var/can_continue = 0
	can_continue = src.mode.pre_setup()		//Choose antagonists
	CHECK_TICK
	SSjob.DivideOccupations() 				//Distribute jobs
	CHECK_TICK

	if(!GLOB.Debug2)
		if(!can_continue)
			qdel(mode)
			mode = null
			to_chat(world, "<B>Error setting up [GLOB.master_mode].</B> Reverting to pre-game lobby.")
			SSjob.ResetOccupations()
			return 0
	else
		message_admins("<span class='notice'>DEBUG: Bypassing prestart checks...</span>")

	CHECK_TICK
	if(hide_mode)
		var/list/modes = new
		for (var/datum/game_mode/M in runnable_modes)
			modes += M.name
		modes = sortList(modes)
		to_chat(world, "<b>The gamemode is: secret!\nPossibilities:</B> [english_list(modes)]")
	else
		mode.announce()

	if(!config.ooc_during_round)
		toggle_ooc(0) // Turn it off

	CHECK_TICK
	GLOB.start_landmarks_list = shuffle(GLOB.start_landmarks_list) //Shuffle the order of spawn points so they dont always predictably spawn bottom-up and right-to-left
	create_characters() //Create player characters
	collect_minds()
	equip_characters()

	SSoverlays.Flush()	//Flush the majority of the shit

	GLOB.data_core.manifest()

	transfer_characters()	//transfer keys to the new mobs

	Master.RoundStart()	//let the party begin...

	for(var/I in round_start_events)
		var/datum/callback/cb = I
		cb.InvokeAsync()
	LAZYCLEARLIST(round_start_events)

	log_world("Game start took [(world.timeofday - init_start)/10]s")
	round_start_time = world.time

	to_chat(world, "<FONT color='blue'><B>Welcome to [station_name()], enjoy your stay!</B></FONT>")
	world << sound('sound/AI/welcome.ogg')

	current_state = GAME_STATE_PLAYING

	if(SSevents.holidays)
		to_chat(world, "<font color='blue'>and...</font>")
		for(var/holidayname in SSevents.holidays)
			var/datum/holiday/holiday = SSevents.holidays[holidayname]
			to_chat(world, "<h4>[holiday.greet()]</h4>")

	PostSetup()

	return 1

/datum/controller/subsystem/ticker/proc/PostSetup()
	set waitfor = 0
	mode.post_setup()
	//Cleanup some stuff
	for(var/obj/effect/landmark/start/S in GLOB.landmarks_list)
		//Deleting Startpoints but we need the ai point to AI-ize people later
		if(S.name != "AI")
			qdel(S)

	var/list/adm = get_admin_counts()
	var/list/allmins = adm["present"]
	send2irc("Server", "Round of [hide_mode ? "secret":"[mode.name]"] has started[allmins.len ? ".":" with no active admins online!"]")

/datum/controller/subsystem/ticker/proc/OnRoundstart(datum/callback/cb)
	if(!HasRoundStarted())
		LAZYADD(round_start_events, cb)
	else
		cb.InvokeAsync()

/datum/controller/subsystem/ticker/proc/station_explosion_detonation(atom/bomb)
	if(bomb)	//BOOM
		var/turf/epi = bomb.loc
		qdel(bomb)
		if(epi)
			explosion(epi, 0, 256, 512, 0, TRUE, TRUE, 0, TRUE)

//Plus it provides an easy way to make cinematics for other events. Just use this as a template
/datum/controller/subsystem/ticker/proc/station_explosion_cinematic(station_missed=0, override = null, atom/bomb = null)
	if( cinematic )
		return	//already a cinematic in progress!

	for (var/datum/html_interface/hi in GLOB.html_interfaces)
		hi.closeAll()
	SStgui.close_all_uis()

	//Turn off the shuttles, there's no escape now
	if(!station_missed && bomb)
		SSshuttle.registerHostileEnvironment(src)
		SSshuttle.lockdown = TRUE

	//initialise our cinematic screen object
	cinematic = new /obj/screen{icon='icons/effects/station_explosion.dmi';icon_state="station_intact";layer=21;mouse_opacity=0;screen_loc="1,0";}(src)

	for(var/mob/M in GLOB.mob_list)
		M.notransform = TRUE //stop everything moving
		if(M.client)
			M.client.screen += cinematic	//show every client the cinematic

	var/actually_blew_up = TRUE
	//Now animate the cinematic
	switch(station_missed)
		if(NUKE_NEAR_MISS)	//nuke was nearby but (mostly) missed
			if( mode && !override )
				override = mode.name
			switch( override )
				if("nuclear emergency") //Nuke wasn't on station when it blew up
					flick("intro_nuke",cinematic)
					sleep(35)
					world << sound('sound/effects/explosionfar.ogg')
					station_explosion_detonation(bomb)
					flick("station_intact_fade_red",cinematic)
					cinematic.icon_state = "summary_nukefail"
				if("gang war") //Gang Domination (just show the override screen)
					cinematic.icon_state = "intro_malf_still"
					flick("intro_malf",cinematic)
					actually_blew_up = FALSE
					sleep(70)
				if("fake") //The round isn't over, we're just freaking people out for fun
					flick("intro_nuke",cinematic)
					sleep(35)
					world << sound('sound/items/bikehorn.ogg')
					flick("summary_selfdes",cinematic)
					actually_blew_up = FALSE
				else
					flick("intro_nuke",cinematic)
					sleep(35)
					world << sound('sound/effects/explosionfar.ogg')
					station_explosion_detonation(bomb)


		if(NUKE_MISS_STATION || NUKE_SYNDICATE_BASE)	//nuke was nowhere nearby	//TODO: a really distant explosion animation
			sleep(50)
			world << sound('sound/effects/explosionfar.ogg')
			station_explosion_detonation(bomb)
			actually_blew_up = station_missed == NUKE_SYNDICATE_BASE	//don't kill everyone on station if it detonated off station
		else	//station was destroyed
			if( mode && !override )
				override = mode.name
			switch( override )
				if("nuclear emergency") //Nuke Ops successfully bombed the station
					flick("intro_nuke",cinematic)
					sleep(35)
					flick("station_explode_fade_red",cinematic)
					world << sound('sound/effects/explosionfar.ogg')
					station_explosion_detonation(bomb)
					cinematic.icon_state = "summary_nukewin"
				if("AI malfunction") //Malf (screen,explosion,summary)
					flick("intro_malf",cinematic)
					sleep(76)
					flick("station_explode_fade_red",cinematic)
					world << sound('sound/effects/explosionfar.ogg')
					station_explosion_detonation(bomb)	//TODO: If we ever decide to actually detonate the vault bomb
					cinematic.icon_state = "summary_malf"
				if("blob") //Station nuked (nuke,explosion,summary)
					flick("intro_nuke",cinematic)
					sleep(35)
					flick("station_explode_fade_red",cinematic)
					world << sound('sound/effects/explosionfar.ogg')
					station_explosion_detonation(bomb)	//TODO: no idea what this case could be
					cinematic.icon_state = "summary_selfdes"
				if("no_core") //Nuke failed to detonate as it had no core
					flick("intro_nuke",cinematic)
					sleep(35)
					flick("station_intact",cinematic)
					world << sound('sound/ambience/signal.ogg')
					addtimer(CALLBACK(src, .proc/finish_cinematic, null, FALSE), 100)
					return	//Faster exit, since nothing happened
				else //Station nuked (nuke,explosion,summary)
					flick("intro_nuke",cinematic)
					sleep(35)
					flick("station_explode_fade_red", cinematic)
					world << sound('sound/effects/explosionfar.ogg')
					station_explosion_detonation(bomb)
					cinematic.icon_state = "summary_selfdes"
	//If its actually the end of the round, wait for it to end.
	//Otherwise if its a verb it will continue on afterwards.

	var/bombloc = null
	if(actually_blew_up)
		if(bomb && bomb.loc)
			bombloc = bomb.z
		else if(!station_missed)
			bombloc = ZLEVEL_STATION

		if(mode)
			mode.explosion_in_progress = 0
			to_chat(world, "<B>The station was destoyed by the nuclear blast!</B>")
			mode.station_was_nuked = (station_missed<2)	//station_missed==1 is a draw. the station becomes irradiated and needs to be evacuated.

	addtimer(CALLBACK(src, .proc/finish_cinematic, bombloc, actually_blew_up), 300)

/datum/controller/subsystem/ticker/proc/finish_cinematic(killz, actually_blew_up)
	if(cinematic)
		qdel(cinematic)		//end the cinematic
		cinematic = null
	for(var/mob/M in GLOB.mob_list)
		M.notransform = FALSE
		if(actually_blew_up && !isnull(killz) && M.stat != DEAD && M.z == killz)
			M.gib()

/datum/controller/subsystem/ticker/proc/create_characters()
	for(var/mob/dead/new_player/player in GLOB.player_list)
		if(player.ready && player.mind)
			GLOB.joined_player_list += player.ckey
			player.create_character(FALSE)
		else
			player.new_player_panel()
		CHECK_TICK

/datum/controller/subsystem/ticker/proc/collect_minds()
	for(var/mob/dead/new_player/P in GLOB.player_list)
		if(P.new_character && P.new_character.mind)
			SSticker.minds += P.new_character.mind
		CHECK_TICK


/datum/controller/subsystem/ticker/proc/equip_characters()
	var/captainless=1
	for(var/mob/dead/new_player/N in GLOB.player_list)
		var/mob/living/carbon/human/player = N.new_character
		if(istype(player) && player.mind && player.mind.assigned_role)
			if(player.mind.assigned_role == "Captain")
				captainless=0
			if(player.mind.assigned_role != player.mind.special_role)
				SSjob.EquipRank(N, player.mind.assigned_role, 0)
		CHECK_TICK
	if(captainless)
		for(var/mob/dead/new_player/N in GLOB.player_list)
			if(N.new_character)
				to_chat(N, "Captainship not forced on anyone.")
			CHECK_TICK

/datum/controller/subsystem/ticker/proc/transfer_characters()
	var/list/livings = list()
	for(var/mob/dead/new_player/player in GLOB.player_list)
		var/mob/living = player.transfer_character()
		if(living)
			qdel(player)
			living.notransform = TRUE
			if(living.client)
				var/obj/screen/splash/S = new(living.client, TRUE)
				S.Fade(TRUE)
			livings += living
	if(livings.len)
		addtimer(CALLBACK(src, .proc/release_characters, livings), 30, TIMER_CLIENT_TIME)

/datum/controller/subsystem/ticker/proc/release_characters(list/livings)
	for(var/I in livings)
		var/mob/living/L = I
		L.notransform = FALSE

/datum/controller/subsystem/ticker/proc/declare_completion()
	set waitfor = FALSE
	var/station_evacuated = EMERGENCY_ESCAPED_OR_ENDGAMED
	var/num_survivors = 0
	var/num_escapees = 0
	var/num_shuttle_escapees = 0

	to_chat(world, "<BR><BR><BR><FONT size=3><B>The round has ended.</B></FONT>")

	//Player status report
	for(var/mob/Player in GLOB.mob_list)
		if(Player.mind && !isnewplayer(Player))
			if(Player.stat != DEAD && !isbrain(Player))
				num_survivors++
				if(station_evacuated) //If the shuttle has already left the station
					var/area/shuttle_area
					if(SSshuttle && SSshuttle.emergency)
						shuttle_area = SSshuttle.emergency.areaInstance
					if(!Player.onCentcom() && !Player.onSyndieBase())
						to_chat(Player, "<font color='blue'><b>You managed to survive, but were marooned on [station_name()]...</b></FONT>")
					else
						num_escapees++
						to_chat(Player, "<font color='green'><b>You managed to survive the events on [station_name()] as [Player.real_name].</b></FONT>")
						if(get_area(Player) == shuttle_area)
							num_shuttle_escapees++
				else
					to_chat(Player, "<font color='green'><b>You managed to survive the events on [station_name()] as [Player.real_name].</b></FONT>")
			else
				to_chat(Player, "<font color='red'><b>You did not survive the events on [station_name()]...</b></FONT>")

		CHECK_TICK

	//Round statistics report
	var/datum/station_state/end_state = new /datum/station_state()
	end_state.count()
	var/station_integrity = min(PERCENT(GLOB.start_state.score(end_state)), 100)

	to_chat(world, "<BR>[GLOB.TAB]Shift Duration: <B>[round(world.time / 36000)]:[add_zero("[world.time / 600 % 60]", 2)]:[world.time / 100 % 6][world.time / 100 % 10]</B>")
	to_chat(world, "<BR>[GLOB.TAB]Station Integrity: <B>[mode.station_was_nuked ? "<font color='red'>Destroyed</font>" : "[station_integrity]%"]</B>")
	if(mode.station_was_nuked)
		SSticker.news_report = STATION_DESTROYED_NUKE
	var/total_players = GLOB.joined_player_list.len
	if(total_players)
		to_chat(world, "<BR>[GLOB.TAB]Total Population: <B>[total_players]</B>")
		if(station_evacuated)
			to_chat(world, "<BR>[GLOB.TAB]Evacuation Rate: <B>[num_escapees] ([PERCENT(num_escapees/total_players)]%)</B>")
			to_chat(world, "<BR>[GLOB.TAB](on emergency shuttle): <B>[num_shuttle_escapees] ([PERCENT(num_shuttle_escapees/total_players)]%)</B>")
			news_report = STATION_EVACUATED
			if(SSshuttle.emergency.is_hijacked())
				news_report = SHUTTLE_HIJACK
		to_chat(world, "<BR>[GLOB.TAB]Survival Rate: <B>[num_survivors] ([PERCENT(num_survivors/total_players)]%)</B>")
	to_chat(world, "<BR>")

	CHECK_TICK

	//Silicon laws report
	for (var/mob/living/silicon/ai/aiPlayer in GLOB.mob_list)
		if (aiPlayer.stat != 2 && aiPlayer.mind)
			to_chat(world, "<b>[aiPlayer.name] (Played by: [aiPlayer.mind.key])'s laws at the end of the round were:</b>")
			aiPlayer.show_laws(1)
		else if (aiPlayer.mind) //if the dead ai has a mind, use its key instead
			to_chat(world, "<b>[aiPlayer.name] (Played by: [aiPlayer.mind.key])'s laws when it was deactivated were:</b>")
			aiPlayer.show_laws(1)

		to_chat(world, "<b>Total law changes: [aiPlayer.law_change_counter]</b>")

		if (aiPlayer.connected_robots.len)
			var/robolist = "<b>[aiPlayer.real_name]'s minions were:</b> "
			for(var/mob/living/silicon/robot/robo in aiPlayer.connected_robots)
				if(robo.mind)
					robolist += "[robo.name][robo.stat?" (Deactivated) (Played by: [robo.mind.key]), ":" (Played by: [robo.mind.key]), "]"
			to_chat(world, "[robolist]")

	CHECK_TICK

	for (var/mob/living/silicon/robot/robo in GLOB.mob_list)
		if (!robo.connected_ai && robo.mind)
			if (robo.stat != 2)
				to_chat(world, "<b>[robo.name] (Played by: [robo.mind.key]) survived as an AI-less borg! Its laws were:</b>")
			else
				to_chat(world, "<b>[robo.name] (Played by: [robo.mind.key]) was unable to survive the rigors of being a cyborg without an AI. Its laws were:</b>")

			if(robo) //How the hell do we lose robo between here and the world messages directly above this?
				robo.laws.show_laws(world)

	CHECK_TICK

	mode.declare_completion()//To declare normal completion.

	CHECK_TICK

	//calls auto_declare_completion_* for all modes
	for(var/handler in typesof(/datum/game_mode/proc))
		if (findtext("[handler]","auto_declare_completion_"))
			call(mode, handler)(force_ending)

	CHECK_TICK

	if(config.cross_allowed)
		send_news_report()

	CHECK_TICK

	//Print a list of antagonists to the server log
	var/list/total_antagonists = list()
	//Look into all mobs in world, dead or alive
	for(var/datum/mind/Mind in minds)
		var/temprole = Mind.special_role
		if(temprole)							//if they are an antagonist of some sort.
			if(temprole in total_antagonists)	//If the role exists already, add the name to it
				total_antagonists[temprole] += ", [Mind.name]([Mind.key])"
			else
				total_antagonists.Add(temprole) //If the role doesnt exist in the list, create it and add the mob
				total_antagonists[temprole] += ": [Mind.name]([Mind.key])"

	CHECK_TICK

	//Now print them all into the log!
	log_game("Antagonists at round end were...")
	for(var/i in total_antagonists)
		log_game("[i]s[total_antagonists[i]].")

	CHECK_TICK

	//Borers
	var/borerwin = FALSE
	if(GLOB.borers.len)
		var/borertext = "<br><font size=3><b>The borers were:</b></font>"
		for(var/mob/living/simple_animal/borer/B in GLOB.borers)
			if((B.key || B.controlling) && B.stat != DEAD)
				borertext += "<br>[B.controlling ? B.victim.key : B.key] was [B.truename] ("
				var/turf/location = get_turf(B)
				if(location.z == ZLEVEL_CENTCOM && B.victim)
					borertext += "escaped with host"
				else
					borertext += "failed"
				borertext += ")"
		to_chat(world, borertext)

		var/total_borers = 0
		for(var/mob/living/simple_animal/borer/B in GLOB.borers)
			if((B.key || B.victim) && B.stat != DEAD)
				total_borers++
		if(total_borers)
			var/total_borer_hosts = 0
			for(var/mob/living/carbon/C in GLOB.mob_list)
				var/mob/living/simple_animal/borer/D = C.has_brain_worms()
				var/turf/location = get_turf(C)
				if(location.z == ZLEVEL_CENTCOM && D && D.stat != DEAD)
					total_borer_hosts++
			if(GLOB.total_borer_hosts_needed <= total_borer_hosts)
				borerwin = TRUE
			to_chat(world, "<b>There were [total_borers] borers alive at round end!</b>")
			to_chat(world, "<b>A total of [total_borer_hosts] borers with hosts escaped on the shuttle alive. The borers needed [GLOB.total_borer_hosts_needed] hosts to escape.</b>")
			if(borerwin)
				to_chat(world, "<b><font color='green'>The borers were successful!</font></b>")
			else
				to_chat(world, "<b><font color='red'>The borers have failed!</font></b>")

	CHECK_TICK

	mode.declare_station_goal_completion()

	CHECK_TICK

	//Adds the del() log to world.log in a format condensable by the runtime condenser found in tools
	if(SSgarbage.didntgc.len || SSgarbage.sleptDestroy.len)
		var/dellog = ""
		for(var/path in SSgarbage.didntgc)
			dellog += "Path : [path] \n"
			dellog += "Failures : [SSgarbage.didntgc[path]] \n"
			if(path in SSgarbage.sleptDestroy)
				dellog += "Sleeps : [SSgarbage.sleptDestroy[path]] \n"
				SSgarbage.sleptDestroy -= path
		for(var/path in SSgarbage.sleptDestroy)
			dellog += "Path : [path] \n"
			dellog += "Sleeps : [SSgarbage.sleptDestroy[path]] \n"
		log_world(dellog)

	CHECK_TICK

	//Collects persistence features
	SSpersistence.CollectData()

	sleep(50)
	if(mode.station_was_nuked)
		world.Reboot("Station destroyed by Nuclear Device.", "end_proper", "nuke")
	else
		world.Reboot("Round ended.", "end_proper", "proper completion")

/datum/controller/subsystem/ticker/proc/send_tip_of_the_round()
	var/m
	if(selected_tip)
		m = selected_tip
	else
		var/list/randomtips = world.file2list("strings/tips.txt")
		var/list/memetips = world.file2list("strings/sillytips.txt")
		if(randomtips.len && prob(95))
			m = pick(randomtips)
		else if(memetips.len)
			m = pick(memetips)

	if(m)
		to_chat(world, "<font color='purple'><b>Tip of the round: </b>[html_encode(m)]</font>")

/datum/controller/subsystem/ticker/proc/check_queue()
	if(!queued_players.len || !config.hard_popcap)
		return

	queue_delay++
	var/mob/dead/new_player/next_in_line = queued_players[1]

	switch(queue_delay)
		if(5) //every 5 ticks check if there is a slot available
			if(living_player_count() < config.hard_popcap)
				if(next_in_line && next_in_line.client)
					to_chat(next_in_line, "<span class='userdanger'>A slot has opened! You have approximately 20 seconds to join. <a href='?src=\ref[next_in_line];late_join=override'>\>\>Join Game\<\<</a></span>")
					next_in_line << sound('sound/misc/notice1.ogg')
					next_in_line.LateChoices()
					return
				queued_players -= next_in_line //Client disconnected, remove he
			queue_delay = 0 //No vacancy: restart timer
		if(25 to INFINITY)  //No response from the next in line when a vacancy exists, remove he
			to_chat(next_in_line, "<span class='danger'>No response recieved. You have been removed from the line.</span>")
			queued_players -= next_in_line
			queue_delay = 0

/datum/controller/subsystem/ticker/proc/check_maprotate()
	if (!config.maprotation)
		return
	if (SSshuttle.emergency && SSshuttle.emergency.mode != SHUTTLE_ESCAPE || SSshuttle.canRecall())
		return
	if (maprotatechecked)
		return

	maprotatechecked = 1

	//map rotate chance defaults to 75% of the length of the round (in minutes)
	if (!prob((world.time/600)*config.maprotatechancedelta))
		return
	INVOKE_ASYNC(SSmapping, /datum/controller/subsystem/mapping/.proc/maprotate)

/datum/controller/subsystem/ticker/proc/HasRoundStarted()
	return current_state >= GAME_STATE_PLAYING

/datum/controller/subsystem/ticker/proc/IsRoundInProgress()
	return current_state == GAME_STATE_PLAYING

/proc/send_gamemode_vote()
	SSticker.modevoted = TRUE
	SSvote.initiate_vote("roundtype","server")

/datum/controller/subsystem/ticker/Recover()
	current_state = SSticker.current_state
	force_ending = SSticker.force_ending
	hide_mode = SSticker.hide_mode
	mode = SSticker.mode
	event_time = SSticker.event_time
	event = SSticker.event

	login_music = SSticker.login_music
	round_end_sound = SSticker.round_end_sound

	minds = SSticker.minds

	syndicate_coalition = SSticker.syndicate_coalition
	factions = SSticker.factions
	availablefactions = SSticker.availablefactions

	delay_end = SSticker.delay_end

	triai = SSticker.triai
	tipped = SSticker.tipped
	selected_tip = SSticker.selected_tip

	timeLeft = SSticker.timeLeft

	totalPlayers = SSticker.totalPlayers
	totalPlayersReady = SSticker.totalPlayersReady

	queue_delay = SSticker.queue_delay
	queued_players = SSticker.queued_players
	cinematic = SSticker.cinematic
	maprotatechecked = SSticker.maprotatechecked
	round_start_time = SSticker.round_start_time

	queue_delay = SSticker.queue_delay
	queued_players = SSticker.queued_players
	cinematic = SSticker.cinematic
	maprotatechecked = SSticker.maprotatechecked

	modevoted = SSticker.modevoted

/datum/controller/subsystem/ticker/proc/send_news_report()
	var/news_message
	var/news_source = "Nanotrasen News Network"
	switch(news_report)
		if(NUKE_SYNDICATE_BASE)
			news_message = "In a daring raid, the heroic crew of [station_name()] detonated a nuclear device in the heart of a terrorist base."
		if(STATION_DESTROYED_NUKE)
			news_message = "We would like to reassure all employees that the reports of a Syndicate backed nuclear attack on [station_name()] are, in fact, a hoax. Have a secure day!"
		if(STATION_EVACUATED)
			news_message = "The crew of [station_name()] has been evacuated amid unconfirmed reports of enemy activity."
		if(GANG_LOSS)
			news_message = "Organized crime aboard [station_name()] has been stamped out by members of our ever vigilant security team. Remember to thank your assigned officers today!"
		if(GANG_TAKEOVER)
			news_message = "Contact with [station_name()] has been lost after a sophisticated hacking attack by organized criminal elements. Stay vigilant!"
		if(BLOB_WIN)
			news_message = "[station_name()] was overcome by an unknown biological outbreak, killing all crew on board. Don't let it happen to you! Remember, a clean work station is a safe work station."
		if(BLOB_NUKE)
			news_message = "[station_name()] is currently undergoing decontanimation after a controlled burst of radiation was used to remove a biological ooze. All employees were safely evacuated prior, and are enjoying a relaxing vacation."
		if(BLOB_DESTROYED)
			news_message = "[station_name()] is currently undergoing decontamination procedures after the destruction of a biological hazard. As a reminder, any crew members experiencing cramps or bloating should report immediately to security for incineration."
		if(CULT_ESCAPE)
			news_message = "Security Alert: A group of religious fanatics have escaped from [station_name()]."
		if(CULT_FAILURE)
			news_message = "Following the dismantling of a restricted cult aboard [station_name()], we would like to remind all employees that worship outside of the Chapel is strictly prohibited, and cause for termination."
		if(CULT_SUMMON)
			news_message = "Company officials would like to clarify that [station_name()] was scheduled to be decommissioned following meteor damage earlier this year. Earlier reports of an unknowable eldritch horror were made in error."
		if(NUKE_MISS)
			news_message = "The Syndicate have bungled a terrorist attack [station_name()], detonating a nuclear weapon in empty space nearby."
		if(OPERATIVES_KILLED)
			news_message = "Repairs to [station_name()] are underway after an elite Syndicate death squad was wiped out by the crew."
		if(OPERATIVE_SKIRMISH)
			news_message = "A skirmish between security forces and Syndicate agents aboard [station_name()] ended with both sides bloodied but intact."
		if(REVS_WIN)
			news_message = "Company officials have reassured investors that despite a union led revolt aboard [station_name()] there will be no wage increases for workers."
		if(REVS_LOSE)
			news_message = "[station_name()] quickly put down a misguided attempt at mutiny. Remember, unionizing is illegal!"
		if(WIZARD_KILLED)
			news_message = "Tensions have flared with the Space Wizard Federation following the death of one of their members aboard [station_name()]."
		if(STATION_NUKED)
			news_message = "[station_name()] activated its self destruct device for unknown reasons. Attempts to clone the Captain so he can be arrested and executed are underway."
		if(CLOCK_SUMMON)
			news_message = "The garbled messages about hailing a mouse and strange energy readings from [station_name()] have been discovered to be an ill-advised, if thorough, prank by a clown."
		if(CLOCK_SILICONS)
			news_message = "The project started by [station_name()] to upgrade their silicon units with advanced equipment have been largely successful, though they have thus far refused to release schematics in a violation of company policy."
		if(CLOCK_PROSELYTIZATION)
			news_message = "The burst of energy released near [station_name()] has been confirmed as merely a test of a new weapon. However, due to an unexpected mechanical error, their communications system has been knocked offline."
		if(SHUTTLE_HIJACK)
			news_message = "During routine evacuation procedures, the emergency shuttle of [station_name()] had its navigation protocols corrupted and went off course, but was recovered shortly after."

	if(news_message)
		send2otherserver(news_source, news_message,"News_Report")

/datum/controller/subsystem/ticker/proc/GetTimeLeft()
	if(isnull(SSticker.timeLeft))
		return max(0, start_at - world.time)
	return timeLeft

/datum/controller/subsystem/ticker/proc/SetTimeLeft(newtime)
	if(newtime >= 0 && isnull(timeLeft))	//remember, negative means delayed
		start_at = world.time + newtime
	else
		timeLeft = newtime
