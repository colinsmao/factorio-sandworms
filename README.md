### Sandworms

Proof of concept mod for sandworm enemies, which I've been working on on and off (mostly off) since FFF-401 talked about dunes. FFF-429 revealed Demolisher enemies, which are likely to obsolete what I'm doing, so I am sharing this incomplete mod.

Sandworms are tankier than their biter counterparts, having similar HP but 90% all res. They attack via impact, which means their destructive power is limited by their HP - dealing damage to them reduces the number of buildings they can destroy.

Additionally, explosive damage has 200% effectiveness against sandworms (which is 2000% taking into account the 90% damage resistance to other types). This is to encourage using landmines as automated defense, one of the usually neglected defensive layers. And grenades / rockets when actively engaging, the age old "feed it a bomb" worm fighting trope.

Sandworms spawn with unit groups (up to one per group for now), and are slightly faster than their biter counterparts, meaning they should reach your defenses before the group. 

They select new nearby targets after reaching/destroying their previous target, so they can chain attacks. If there are no more military targets in range, they stop and burrow into the ground, becoming a vanilla worm turret.

Note, I probably won't update this mod, since demolishers will be added in 2.0. Maybe I'll redo this mod in the future using the demolisher prototype.

---
#### WARNING
- There is an issue with the pathfinder api right now, which will occasionally hard crash Factorio ([bug report](https://forums.factorio.com/viewtopic.php?f=7&t=115524)). So this mod is not really stable and shouldn't be played in an actual game.
  - It seems like the pathfinding crash happens when pathing near water, so testing in a no-water world seems safe.

---
#### Testing
Debug mode available in settings
- Shows worm paths
- Clicking with an item on the cursor does stuff:
  - iron-plate = 
  - copper-plate = Select target position or nearby entity. All living worms will try to target the position/entity, and newly spawned worms will target the selected entity immediately.
  - plastic-bar = spawn worm, of random size
  - steel-plate = kill all worms
    - right clicking makes all worms burrow
- Worm head items available in cheat mode, which you can place and drive around like a tank. Note, reversing creates buggy behaviour.

---
#### TODO:
- Graphics, of all forms. Not an artist
  - Worm head+segment art. Corpses. Movement particles.
  - Spawn/despawn animations, eg burrowing into the ground
- Balancing. Some basic balancing done (eg health, speed), but not really tested in real game scenarios
- More complex target selection AI. Eg. Pollution gradient descent. Targetting areas with loud sounds (eg active machines).
- Idle worms sitting and/or moving around. Since worms are controlled via script, this seems like it could become inefficient.

#### Big Issues:
- Worm segments have the default unit collision_mask, so that they don't collide with themselves or with other units. But this means they collide with cliffs, which the pathfinder does not path around.
  - In normal maps most worms end up hitting cliffs and stopping/dying. They sometimes also spawn with half their segments behind a cliff, resulting in half the worm being left behind.
  - I tried using the cliff's collision mask instead, but the cliff collision mask has "item-layer", which means worms collide with items on the ground, dying instantly (since dropped items have infinite health).
  - They could be made to destroy cliffs. But then you cannot use cliffs as defenses anymore.
- The pathfinder doesn't path around water very well, which means worms often hit water and die. Though I guess water is poisonous to Dune sandworms, so this is thematic.

#### Small Issues:
- Chained worm targets are found using find_nearest_enemy (instead of find_entities_filtered + custom target selection), which may be behind the worm, causing it to make loops.
- Construction robots are military targets, which means worms sometimes end up chasing robots around. This results in them destroying roboports, an unintended effect.
- Rockets are slightly too effective against worms, but there is no differentiation between landmines and rockets in vanilla (both are explosive damage)

#### Notes:
- Worm HP: Small 100, Medium 400, Big 800, Behemoth 3200
- Worms are spawned along with on_unit_group_finished_gathering, ie when a usual unit group is dispatched on an attack. This way worms spawn with a known target, minimizing the number of living worms at once (since they are script powered). And I don't have to deal with evolution, since I can just base the worm size on the evolution of the units in the group.

