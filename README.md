

Worms spawn with unit groups (up to one per group for now), and are slightly faster than their biter counterparts, meaning they should reach your defenses slightly before the group. 

Worms have 90% of all resistances, except explosion which is -100% (ie 200% effectiveness). This is to encourage using landmines as automated defense, one of the defense layers that players usually don't use. Or grenades / rockets when actively fighting, the age old "Feed It a Bomb" worm fighting trope.

I probably won't update this though, since demolishers will be added soon. Maybe I'll redo this mod using the demolisher prototype in 2.0.

---

TODO:
- Graphics, of all forms. Not an artist
  - Worm head+segment art. Corpses. Movement particles.
  - Spawn/despawn animations, eg burrowing into the ground
- Balancing. Some basic balancing done (eg health, speed), but not really tested in real scenarios
- Idle worms sitting and/or moving around. Since worms are controlled via script, this seems like it could become inefficient.

Big Issues:
- Worm segments have the unit collision_mask, so that they don't collide with themselves or with units. But this means they collide with cliffs, which the pathfinder does not path around.
  - In normal maps most worms end up hitting cliffs and stopping/dying. They sometimes also spawn with half their segments behind a cliff, resulting in half the worm being left behind.
  - I tried using the cliff's collision mask instead, but the cliff collision mask has "item-layer", which means worms collide with items on the ground, dying instantly (since dropped items have infinite health).
  - They could also be made to destroy cliffs. But then you cannot use cliffs as defenses anymore.
- The pathfinder doesn't path around water very well, which means worms often hit water and die. Though I guess water is poisonous to Dune sandworms, so this is thematic.

Small Issues:
- Chained worm targets are found using find_nearest_enemy (instead of find_entities_filtered + custom target selection), which may be behind the worm, causing it to make loops.
- Construction robots are military targets, which means worms sometimes end up chasing robots around. This results in them destroying roboports, an unintended effect.
- Rockets are slightly too effective against worms, but there is no differentiation between landmines and rockets in vanilla

Notes:
- Worm HP: Small 100, Medium 400, Big 800, Behemoth 3200
- Worms are spawned along with on_unit_group_finished_gathering, ie when a usual unit group is dispatched on an attack. This way worms spawn with a known target, minimizing the number of living worms at once (since they are script powered). And I don't have to deal with evolution, since I can just base the worm size on the evolution of the units in the group.

