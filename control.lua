--
-- runtime code
--

local util = require('util')
local collision_mask_util = require('collision-mask-util')
local tools = require('scripts.tools')
local const = require('scripts.constants')

local event_id = script.generate_event_name()

---@class EvenPickierDolliesMod
---@field event_id uint The event id registered with the main game.
---@field remote_interface EvenPickierDolliesRemoteInterface
---@field settings EvenPickierDolliesSettings
local epd = {
    event_id = event_id,
    settings = require('scripts.settings'),
    remote_interface = require('scripts.remote-interface')(event_id),
}

remote.add_interface(const.api_name, epd.remote_interface)

assert(remote.interfaces[const.api_name]['dolly_moved_entity_id'])

---@param move_event EvenPickierDolliesMoveEvent
function epd:move_entity(move_event)
    local player = move_event.player
    local cheat_mode = player.cheat_mode

    local entity = move_event.entity

    local debug = self.settings.get_debug(player)

    -- Check non cheat_mode player in range.
    if not (cheat_mode or player.can_reach_entity(entity)) then
        return tools.flying_text(player, { "cant-reach" }, entity.position)
    end

    -- Check if entity is blacklisted, cheat_mode allows moving more entities.
    if not tools.allow_moving(entity, cheat_mode) then
        return tools.flying_text(player, { "picker-dollies.cant-be-teleported", entity.localised_name }, entity.position)
    end

    -- Only move entities of the same force unless cheat_mode is enabled.
    local entity_force = entity.force --[[@as LuaForce]]
    if not (cheat_mode or entity_force == player.force) then
        return tools.flying_text(player, { "picker-dollies.wrong-force", entity.localised_name }, entity.position)
    end

    -- save start position in case we have to unwind
    local start_pos = entity.position        -- Where we started from in case we have to return it
    local start_direction = entity.direction -- Direction in which the entity currently points

    local surface = entity.surface

    -- Make sure there is not a rocket present.
    -- @todo Move the rocket-silo-rocket to the correct spot.
    if surface.find_entity("rocket-silo-rocket", start_pos) then
        return tools.flying_text(player, { "picker-dollies.rocket-present", entity.localised_name }, start_pos)
    end

    if debug then
        -- green box shows the current bounding box before moving/rotating
        rendering.draw_rectangle {
            color = { r = 0.3, g = 1, b = 0.3 },
            surface = player.surface,
            left_top = entity.bounding_box.left_top,
            right_bottom = entity.bounding_box.right_bottom,
            time_to_live = 120,
        }
    end

    local function undo_move(message)
        -- undo everything
        entity.direction = start_direction
        if entity.teleport(start_pos) then
            return tools.flying_text(player, { message, entity.localised_name }, start_pos)
        else
            -- error message at the original position
            return tools.flying_text(player, { 'picker-dollies.teleport-problem', entity.localised_name }, player.position)
        end
    end

    local target_pos = start_pos

    if move_event.rotate then entity.direction = move_event.rotate end -- operation was a rotate

    local target_box = entity.bounding_box
    local direction = move_event.direction -- Direction to move the source

    -- process move
    if direction then
        local distance = move_event.distance * entity.prototype.building_grid_bit_shift -- Distance to move the source, defaults to 1
        target_pos = tools.position_translate(start_pos, direction, distance)           -- Where we want to go too
        target_box = tools.area_translate(entity.bounding_box, direction, distance)     -- Target selection box location
    end

    -- update the saved entity for multiple moves
    tools.save_entity(move_event.pdata, entity, move_event.tick, move_event.save_time)

    -- see if we can place the entity in the new spot
    local ignore_collisions = self.settings.get_allow_ignore_collisions() and self.settings.get_ignore_collisions(player)

    if debug then
        -- red box is the target position
        rendering.draw_rectangle {
            color = { r = 1, g = 0.3, b = 0.3 },
            surface = player.surface,
            left_top = target_box.left_top,
            right_bottom = target_box.right_bottom,
            time_to_live = 120,
        }
    end

    -- unconditional move first. If that does not work, then we don't need to bother
    -- with anything else anyway. this can move an entity e.g. on water so it needs to
    -- be undone
    if not entity.teleport(target_pos) then
        entity.direction = start_direction
        return tools.flying_text(player, { 'picker-dollies.cant-be-teleported', entity.localised_name }, start_pos)
    end

    --  Check if all the wires can reach. If not, bail out.
    local wire_connectors = entity.get_wire_connectors(false) or {}
    if table_size(wire_connectors) > 0 then
        if not tools.can_wires_reach(entity) then
            return undo_move('picker-dollies.wires-maxed')
        end
    end

    -- move back to start position
    assert(entity.teleport(start_pos), "Could not move back to start position!")

    -- ------------
    -- check for items to hoover up
    -- ------------
    local collision_entities = surface.find_entities_filtered {
        area = target_box,
        type = { 'item-entity', 'item-request-proxy', 'resource', }, -- ignore those entities, we deal with them below
        invert = true,
    }

    if not ignore_collisions and
        -- more than one entity needs detailed collision checking
        (table_size(collision_entities) > 1
            -- if there is only one entity and it is ourselves, don't bother doing the detailed checking
            or (collision_entities[1] and (collision_entities[1].unit_number ~= entity.unit_number))) then
        -- do detailed collision check, entities that don't collide are ok (often invisible entities)
        for _, collision_entity in pairs(collision_entities) do
            -- don't check the entity against itself
            if collision_entity.unit_number ~= entity.unit_number
                -- only check layer collision if both entities have collision mask layers -- see https://forums.factorio.com/viewtopic.php?f=7&t=123332
                and entity.prototype.collision_mask.layers and collision_entity.prototype.collision_mask.layers
                -- but when they collide, do not move
                and collision_mask_util.masks_collide(entity.prototype.collision_mask, collision_entity.prototype.collision_mask) then
                return undo_move('picker-dollies.no-room')
            end
        end
    end

    -- Mine or move out of the way any items on the ground.
    local items_on_ground = surface.find_entities_filtered { type = "item-entity", area = target_box }
    for _, item_entity in pairs(items_on_ground) do
        if item_entity.valid and not player.mine_entity(item_entity) then
            local item_pos = item_entity.position
            local valid_pos = surface.find_non_colliding_position(item_entity, item_pos, 50, .20) or item_pos
            item_entity.teleport(valid_pos)
        end
    end

    -- all additional placement checks (e.g. on water) are done with this last teleport
    if not entity.teleport(target_pos, nil, false, false, ignore_collisions and defines.build_check_type.script or defines.build_check_type.ghost_revive) then
        -- this can happen in ignore-collisions mode
        return undo_move('picker-dollies.no-room')
    end

    -- everything seems to be fine
    if entity.last_user then entity.last_user = player end

    -- Move a proxy to the correct position...
    local proxy = surface.find_entity("item-request-proxy", start_pos)
    if proxy and proxy.valid then proxy.teleport(target_pos) end

    -- Update all connections.
    -- @todo Only add updateable_entities to a list.
    local updateable_entities = surface.find_entities_filtered { area = tools.area_expand(target_box, const.grid_size), force = entity_force }
    for _, updateable in pairs(updateable_entities) do updateable.update_connections() end

    ---@type EvenPickierDolliesRemoteInterfaceDollyMovedEvent
    local event_data = {
        player_index = player.index,
        moved_entity = entity,
        start_pos = start_pos
    }

    script.raise_event(self.event_id, event_data)
    player.play_sound { path = "utility/rotated_medium" }
end

---@param event EventData.CustomInputEvent
function epd.dolly_move(event)
    local player, pdata = game.get_player(event.player_index), tools.pdata(event.player_index)
    if not player then return end

    local save_time = epd.settings.get_save_entity(player)
    local entity = tools.get_entity_to_move(player, pdata, event.tick, save_time)
    if not entity then return end

    ---@type EvenPickierDolliesMoveEvent
    local move_event = {
        player = player,
        pdata = pdata,
        tick = event.tick,
        entity = entity,
        save_time = save_time,
        direction = const.input_to_direction[event.input_name], -- direction in which the entity is moved
        distance = 1,
    }

    epd:move_entity(move_event)
end

---@param event EventData.CustomInputEvent
---@param reverse boolean
function epd.rotate_oblong_entity(event, reverse)
    ---@type LuaPlayer?
    local player = game.get_player(event.player_index)
    if not player then return end
    if player.cursor_stack.valid_for_read or player.cursor_ghost then return end

    local pdata = tools.pdata(event.player_index)

    local save_time = epd.settings.get_save_entity(player)
    local entity = tools.get_entity_to_move(player, pdata, event.tick, save_time)
    if not entity then return end

    local distance = storage.oblong_names[entity.name]

    if not (distance and tools.allow_moving(entity, player.cheat_mode)) then return end
    if not (player.cheat_mode or player.can_reach_entity(entity)) then return end

    local rotate = reverse and tools.direction_previous(entity.direction) or tools.direction_next(entity.direction)

    ---@type EvenPickierDolliesMoveEvent
    local move_event = {
        player = player,
        pdata = pdata,
        tick = event.tick,
        entity = entity,
        save_time = save_time,
        direction = const.oblong_diags[rotate],
        distance = distance,
        rotate = rotate,
    }

    epd:move_entity(move_event)
end

---@param event EventData.CustomInputEvent
---@param reverse boolean
function epd.rotate_saved_dolly(event, reverse)
    ---@type LuaPlayer?
    local player = game.get_player(event.player_index)
    if not player then return end

    if player.cursor_stack.valid_for_read or player.cursor_ghost or player.selected then return end

    local pdata = tools.pdata(event.player_index)

    local save_time = epd.settings.get_save_entity(player)
    local entity = tools.get_entity_to_move(player, pdata, event.tick, save_time)
    if not entity or not entity.supports_direction then return end

    tools.save_entity(pdata, entity, event.tick, save_time)
    entity.rotate { reverse = reverse, by_player = player }
end

function epd.on_init()
    storage.blacklist_names = util.copy(const.blacklist_names)
    storage.oblong_names = util.copy(const.oblong_names)
end

function epd.on_configuration_changed()
    -- Make sure the blacklists exist.
    storage.blacklist_names = storage.blacklist_names or util.copy(const.blacklist_names)
    storage.oblong_names = storage.oblong_names or {}

    for name, distance in pairs(const.oblong_names) do
        storage.oblong_names[name] = distance
    end

    for name in pairs(storage.oblong_names) do
        if type(storage.oblong_names[name]) ~= 'number' then
            storage.oblong_names[name] = 0.5 -- default offset for a 2x1 oblong entity
        end
    end

    -- Remove any invalid prototypes from the blacklists.
    for name in pairs(storage.blacklist_names) do
        if not prototypes.entity[name] then storage.blacklist_names[name] = nil end
    end
    for name in pairs(storage.oblong_names) do
        if not prototypes.entity[name] then storage.oblong_names[name] = nil end
    end
end

script.on_event({ "dolly-move-north", "dolly-move-east", "dolly-move-south", "dolly-move-west" }, epd.dolly_move)
script.on_event("dolly-rotate-rectangle", function (event) epd.rotate_oblong_entity(event, false) end)
script.on_event("dolly-rotate-rectangle-reverse", function (event) epd.rotate_oblong_entity(event, true) end)
script.on_event("dolly-rotate-saved", function (event) epd.rotate_saved_dolly(event, false) end)
script.on_event("dolly-rotate-saved-reverse", function (event) epd.rotate_saved_dolly(event, true) end)
script.on_init(epd.on_init)
script.on_configuration_changed(epd.on_configuration_changed)
