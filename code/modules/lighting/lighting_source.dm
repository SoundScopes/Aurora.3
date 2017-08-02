// This is where the fun begins.
// These are the main datums that emit light.

/datum/light_source
	var/atom/top_atom        // The atom we're emitting light from (for example a mob if we're from a flashlight that's being held).
	var/atom/source_atom     // The atom that we belong to.

	var/turf/source_turf     // The turf under the above.
	var/light_power    	// Intensity of the emitter light.
	var/light_range     // The range of the emitted light.
	var/light_color    	// The colour of the light, string, decomposed by parse_light_color()
	var/light_uv		// The intensity of UV light, between 0 and 255.
	var/light_angle		// The light's emission angle, in degrees.

	// Variables for keeping track of the colour.
	var/lum_r
	var/lum_g
	var/lum_b
	var/lum_u

	// The lumcount values used to apply the light.
	var/tmp/applied_lum_r
	var/tmp/applied_lum_g
	var/tmp/applied_lum_b
	var/tmp/applied_lum_u

	// Variables used to keep track of the atom's angle.
	var/tmp/limit_a_x       // The first test point's X coord for the cone.
	var/tmp/limit_a_y       // The first test point's Y coord for the cone.
	var/tmp/limit_a_t       // The first test point's angle.
	var/tmp/limit_b_x       // The second test point's X coord for the cone.
	var/tmp/limit_b_y       // The second test point's Y coord for the cone.
	var/tmp/limit_b_t       // The second test point's angle.
	var/tmp/cached_origin_x // The last known X coord of the origin.
	var/tmp/cached_origin_y // The last known Y coord of the origin.
	var/tmp/old_direction   // The last known direction of the origin.
	var/tmp/targ_sign       // The sign to test the point against.
	var/tmp/test_x_offset   // How much the X coord should be offset due to direction.
	var/tmp/test_y_offset   // How much the Y coord should be offset due to direction.

	var/list/datum/lighting_corner/effect_str     // List used to store how much we're affecting corners.
	var/list/turf/affecting_turfs

	var/applied = FALSE // Whether we have applied our light yet or not.

	var/needs_update = LIGHTING_NO_UPDATE

/datum/light_source/New(var/atom/owner, var/atom/top)
	source_atom = owner // Set our new owner.

	LAZYADD(source_atom.light_sources, src)

	top_atom = top
	if (top_atom != source_atom)
		LAZYADD(top_atom.light_sources, src)

	source_turf = top_atom
	light_power = source_atom.light_power
	light_range = source_atom.light_range
	light_color = source_atom.light_color
	light_uv    = source_atom.uv_intensity
	light_angle = source_atom.light_wedge

	parse_light_color()

	update()

	//L_PROF(source_atom, "source_new([type])")

	return ..()

// Kill ourselves.
/datum/light_source/Destroy(force)
	//L_PROF(source_atom, "source_destroy")

	remove_lum()
	if (source_atom)
		LAZYREMOVE(source_atom.light_sources, src)

	if (top_atom)
		LAZYREMOVE(top_atom.light_sources, src)

	. = ..()
	if (!force)
		return QDEL_HINT_IWILLGC

// Picks either scheduled or instant updates based on current server load.
#define INTELLIGENT_UPDATE(level)                      \
	var/_should_update = needs_update == LIGHTING_NO_UPDATE; \
	if (needs_update < level) {                        \
		needs_update = level;                          \
	}                                                  \
	if (_should_update) {                              \
		if (world.tick_usage > SSlighting.instant_tick_limit || SSlighting.force_queued) {	\
			SSlighting.light_queue += src;              \
		}                                               \
		else {                                          \
			update_corners(TRUE);                       \
			needs_update = LIGHTING_NO_UPDATE;          \
		}                                               \
	}

// This proc will cause the light source to update the top atom, and add itself to the update queue.
/datum/light_source/proc/update(var/atom/new_top_atom)
	// This top atom is different.
	if (new_top_atom && new_top_atom != top_atom)
		if(top_atom != source_atom) // Remove ourselves from the light sources of that top atom.
			LAZYREMOVE(top_atom.light_sources, src)

		top_atom = new_top_atom

		if (top_atom != source_atom)
			if(!top_atom.light_sources)
				top_atom.light_sources = list()

			top_atom.light_sources += src // Add ourselves to the light sources of our new top atom.

	//L_PROF(source_atom, "source_update")

	INTELLIGENT_UPDATE(LIGHTING_CHECK_UPDATE)

// Will force an update without checking if it's actually needed.
/datum/light_source/proc/force_update()
	//L_PROF(source_atom, "source_forceupdate")

	INTELLIGENT_UPDATE(LIGHTING_FORCE_UPDATE)

// Will cause the light source to recalculate turfs that were removed or added to visibility only.
/datum/light_source/proc/vis_update()
	//L_PROF(source_atom, "source_visupdate")

	INTELLIGENT_UPDATE(LIGHTING_VIS_UPDATE)

// Decompile the hexadecimal colour into lumcounts of each perspective.
/datum/light_source/proc/parse_light_color()
	if (light_color)
		lum_r = GetRedPart   (light_color) / 255
		lum_g = GetGreenPart (light_color) / 255
		lum_b = GetBluePart  (light_color) / 255
	else
		lum_r = 1
		lum_g = 1
		lum_b = 1

	if (light_uv)
		lum_u = light_uv / 255
	else
		lum_u = 0

#define POLAR_TO_CART_X(R,T) ((R) * cos(T))
#define POLAR_TO_CART_Y(R,T) ((R) * sin(T))
#define PSEUDO_WEDGE(A_X,A_Y,B_X,B_Y) ((A_X)*(B_Y) - (A_Y)*(B_X))
#define MINMAX(NUM) ((NUM) < 0 ? -round(-(NUM)) : round(NUM))
#define ARBITRARY_NUMBER 10

/datum/light_source/proc/update_angle()
	var/turf/T = get_turf(top_atom)
	// Don't do anything if nothing is different, trig ain't free.
	if (T.x == cached_origin_x && T.y == cached_origin_y && old_direction == top_atom.dir)
		return

	var/do_offset = TRUE
	var/turf/front = get_step(T, top_atom.dir)
	if (front && front.has_opaque_atom)
		do_offset = FALSE

	cached_origin_x = T.x
	test_x_offset = cached_origin_x
	cached_origin_y = T.y
	test_y_offset = cached_origin_y

	if (istype(top_atom, /mob) && top_atom:facing_dir)
		old_direction = top_atom:facing_dir
	else
		old_direction = top_atom.dir

	var/angle = light_angle / 2
	switch (old_direction)
		if (NORTH)
			limit_a_t = angle + 90
			limit_b_t = -(angle) + 90
			if (do_offset)
				test_y_offset += 1

		if (SOUTH)
			limit_a_t = (angle) - 90
			limit_b_t = -(angle) - 90
			if (do_offset)
				test_y_offset -= 1

		if (EAST)
			limit_a_t = angle
			limit_b_t = -(angle)
			if (do_offset)
				test_x_offset += 1

		if (WEST)
			limit_a_t = angle + 180
			limit_b_t = -(angle) - 180
			if (do_offset)
				test_x_offset -= 1

	// Convert our angle + range into a vector.
	limit_a_x = POLAR_TO_CART_X(light_range + ARBITRARY_NUMBER, limit_a_t)
	limit_a_x = MINMAX(limit_a_x)
	limit_a_y = POLAR_TO_CART_Y(light_range + ARBITRARY_NUMBER, limit_a_t)
	limit_a_y = MINMAX(limit_a_y)
	limit_b_x = POLAR_TO_CART_X(light_range + ARBITRARY_NUMBER, limit_b_t)
	limit_b_x = MINMAX(limit_b_x)
	limit_b_y = POLAR_TO_CART_Y(light_range + ARBITRARY_NUMBER, limit_b_t)
	limit_b_y = MINMAX(limit_b_y)
	// This won't change unless the origin or dir changes, might as well do it here.
	targ_sign = PSEUDO_WEDGE(limit_a_x, limit_a_y, limit_b_x, limit_b_y) > 0

#undef ARBITRARY_NUMBER

// I know this is 2D, calling it a cone anyways. Fuck the system.
// Returns true if the test point is NOT inside the cone.
// Make sure update_angle() is called first if the light's loc or dir have changed.
/datum/light_source/proc/check_light_cone(var/test_x, var/test_y)
	test_x -= test_x_offset
	test_y -= test_y_offset
	var/at = PSEUDO_WEDGE(limit_a_x, limit_a_y, test_x, test_y)
	var/tb = PSEUDO_WEDGE(test_x, test_y, limit_b_x, limit_b_y)

	// if the signs of both at and tb are NOT the same, the point is NOT within the cone.
	return (((at > 0) != targ_sign) || ((tb > 0) != targ_sign))

#undef POLAR_TO_CART_X
#undef POLAR_TO_CART_Y
#undef PSEUDO_WEDGE
#undef MINMAX

/datum/light_source/proc/remove_lum(var/now = FALSE)
	applied = FALSE

	var/thing
	for (thing in affecting_turfs)
		var/turf/T = thing
		LAZYREMOVE(T.affecting_lights, src)

	affecting_turfs = null

	for (thing in effect_str)
		var/datum/lighting_corner/C = thing
		REMOVE_CORNER(C,now)

		LAZYREMOVE(C.affecting, src)

	effect_str = null

/datum/light_source/proc/recalc_corner(var/datum/lighting_corner/C, var/now = FALSE)
	LAZYINITLIST(effect_str)
	if (effect_str[C]) // Already have one.
		REMOVE_CORNER(C,now)
		effect_str[C] = 0

	APPLY_CORNER(C,now)
	UNSETEMPTY(effect_str)

// If you update this, update the equivalent proc in lighting_source_novis.dm.
/datum/light_source/proc/update_corners(now = FALSE)
	var/update = FALSE

	if (QDELETED(source_atom))
		qdel(src)
		return

	if (source_atom.light_power != light_power)
		light_power = source_atom.light_power
		update = TRUE

	if (source_atom.light_range != light_range)
		light_range = source_atom.light_range
		update = TRUE

	if (!top_atom)
		top_atom = source_atom
		update = TRUE

	if (top_atom.loc != source_turf)
		source_turf = top_atom.loc
		update = TRUE

	if (!light_range || !light_power)
		qdel(src)
		return

	if (isturf(top_atom))
		if (source_turf != top_atom)
			source_turf = top_atom
			update = TRUE
	else if (top_atom.loc != source_turf)
		source_turf = top_atom.loc
		update = TRUE

	if (!source_turf)
		return	// Somehow we've got a light in nullspace, no-op.

	if (light_range && light_power && !applied)
		update = TRUE

	if (source_atom.light_color != light_color)
		light_color = source_atom.light_color
		parse_light_color()
		update = TRUE

	else if (applied_lum_r != lum_r || applied_lum_g != lum_g || applied_lum_b != lum_b)
		update = TRUE

	if (source_atom.light_wedge != light_angle)
		light_angle = source_atom.light_wedge
		update = TRUE

	if (light_angle && top_atom.dir != old_direction)
		update = TRUE

	if (update && light_angle)
		update_angle()

	if (update)
		needs_update = LIGHTING_CHECK_UPDATE
	else if (needs_update == LIGHTING_CHECK_UPDATE)
		return	// No change.

	var/list/datum/lighting_corner/corners = list()
	var/list/turf/turfs                    = list()
	var/thing
	var/datum/lighting_corner/C
	var/turf/T
	var/list/Tcorners
	var/Sx = source_turf.x
	var/Sy = source_turf.y

	FOR_DVIEW(T, Ceiling(light_range), source_turf, 0)
		check_t:
		if (light_angle && check_light_cone(T.x, T.y))
			continue

		if (T.dynamic_lighting || T.light_sources)
			Tcorners = T.corners
			if (!T.lighting_corners_initialised)
				T.lighting_corners_initialised = TRUE

				if (!Tcorners)
					T.corners = list(null, null, null, null)
					Tcorners = T.corners

				for (var/i = 1 to 4)
					if (Tcorners[i])
						continue

					Tcorners[i] = new /datum/lighting_corner(T, LIGHTING_CORNER_DIAGONAL[i])

			if (!T.has_opaque_atom)
				for (thing in Tcorners)
					C = thing
					corners[C] = 0

		turfs += T

		if (isopenturf(T) && T:below)
			T = T:below	// Consider the turf below us as well. (Z-lights)
			goto check_t

	END_FOR_DVIEW

	LAZYINITLIST(affecting_turfs)

	var/list/L = turfs - affecting_turfs // New turfs, add us to the affecting lights of them.
	affecting_turfs += L
	for (thing in L)
		T = thing
		LAZYADD(T.affecting_lights, src)

	L = affecting_turfs - turfs // Now-gone turfs, remove us from the affecting lights.
	affecting_turfs -= L
	for (thing in L)
		T = thing
		LAZYREMOVE(T.affecting_lights, src)

	LAZYINITLIST(effect_str)
	if (needs_update == LIGHTING_VIS_UPDATE)
		for (thing in corners - effect_str)
			C = thing
			LAZYADD(C.affecting, src)
			if (!C.active)
				effect_str[C] = 0
				continue

			APPLY_CORNER_XY(C, now, Sx, Sy)
	else
		L = corners - effect_str
		for (thing in L)
			C = thing
			LAZYADD(C.affecting, src)
			if (!C.active)
				effect_str[C] = 0
				continue

			APPLY_CORNER_XY(C, now, Sx, Sy)

		for (thing in corners - L)
			C = thing
			if (!C.active)
				effect_str[C] = 0
				continue

			APPLY_CORNER_XY(C, now, Sx, Sy)

	L = effect_str - corners
	for (thing in L)
		C = thing
		REMOVE_CORNER(C, now)
		LAZYREMOVE(C.affecting, src)

	effect_str -= L

	applied_lum_r = lum_r
	applied_lum_g = lum_g
	applied_lum_b = lum_b
	applied_lum_u = lum_u

	UNSETEMPTY(effect_str)
	UNSETEMPTY(affecting_turfs)

#undef QUEUE_UPDATE
#undef DO_UPDATE
#undef INTELLIGENT_UPDATE
