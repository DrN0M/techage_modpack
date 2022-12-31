--[[

	TechAge
	=======

	Copyright (C) 2020-2022 Joachim Stolberg

	AGPL v3
	See LICENSE.txt for more information

	Block fly/move library

]]--

-- for lazy programmers
local M = minetest.get_meta
local P2S = function(pos) if pos then return minetest.pos_to_string(pos) end end
local S2P = minetest.string_to_pos
local S = techage.S

local flylib = {}

local function lvect_add_vec(lvect1, offs)
	if not lvect1 or not offs then return end

	local lvect2 = {}
	for _, v in ipairs(lvect1) do
		lvect2[#lvect2 + 1] = vector.add(v, offs)
	end
	return lvect2
end

local function lvect_add(lvect1, lvect2)
	if not lvect1 or not lvect2 then return end

	local lvect3 = {}
	for i, v in ipairs(lvect1) do
		lvect3[#lvect3 + 1] = vector.add(v, lvect2[i])
	end
	return lvect3
end

local function lvect_subtract(lvect1, lvect2)
	if not lvect1 or not lvect2 then return end

	local lvect3 = {}
	for i, v in ipairs(lvect1) do
		lvect3[#lvect3 + 1] = vector.subtract(v, lvect2[i])
	end
	return lvect3
end

-- yaw in radiant
local function rotate(v, yaw)
	local sinyaw = math.sin(yaw)
	local cosyaw = math.cos(yaw)
	return {x = v.x * cosyaw - v.z * sinyaw, y = v.y, z = v.x * sinyaw + v.z * cosyaw}
end

local function set_node(item)
	local dest_pos = item.dest_pos
	local name = item.name or "air"
	local param2 = item.param2 or 0
	local metadata = item.metadata or {}
	local nvm = techage.get_nvm(item.base_pos)
	local node = techage.get_node_lvm(dest_pos)
	local ndef1 = minetest.registered_nodes[name]
	local ndef2 = minetest.registered_nodes[node.name]

	nvm.running = false
	M(item.base_pos):set_string("status", S("Stopped"))
	if ndef1 and ndef2 then
		if ndef2.buildable_to then
			local meta = M(dest_pos)
			minetest.set_node(dest_pos, {name=name, param2=param2})
			meta:from_table(item.metadata or {})
			meta:set_string("ta_move_block", "")
			meta:set_int("ta_door_locked", 1)
			return
		end
		local meta = M(dest_pos)
		if not meta:contains("ta_move_block") then
			meta:set_string("ta_move_block", minetest.serialize({name=name, param2=param2}))
			return
		end
	elseif ndef1 then
		minetest.add_item(dest_pos, ItemStack(name))
	end
end

-------------------------------------------------------------------------------
-- Entity monitoring
-------------------------------------------------------------------------------
local queue = {}
local first = 0
local last = -1

local function push(item)
	last = last + 1
	queue[last] = item
end

local function pop(nvm, time)
	if first > last then return end
	local item = queue[first]
	queue[first] = nil -- to allow garbage collection
	first = first + 1
	return item
end

local function monitoring()
	local num = last - first + 1
	for _ = 1, num do
		local item = pop()
		if item.ttl >= techage.SystemTime then
			-- still valud
			push(item)
		elseif item.ttl ~= 0 then
			set_node(item)
		end
	end
	minetest.after(1, monitoring)
end
minetest.after(1, monitoring)

minetest.register_on_shutdown(function()
	local num = last - first + 1
	for _ = 1, num do
		local item = pop()
		if item.ttl ~= 0 then
			set_node(item)
		end
	end
end)

local function monitoring_add_entity(item)
	item.ttl = techage.SystemTime + 1
	push(item)
end

local function monitoring_del_entity(item)
	-- Mark as timed out
	item.ttl = 0
end

local function monitoring_trigger_entity(item)
	item.ttl = techage.SystemTime + 1
end

-------------------------------------------------------------------------------
-- to_path function for the fly/move path
-------------------------------------------------------------------------------

local function strsplit(text)
	text = text:gsub("\r\n", "\n")
	text = text:gsub("\r", "\n")
	return string.split(text, "\n", true)
end

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function flylib.distance(v)
	return math.abs(v.x) + math.abs(v.y) + math.abs(v.z)
end

function flylib.to_vector(s, max_dist)
	local x,y,z = unpack(string.split(s, ","))
	x = tonumber(x) or 0
	y = tonumber(y) or 0
	z = tonumber(z) or 0
	if x and y and z then
		if not max_dist or (math.abs(x) + math.abs(y) + math.abs(z)) <= max_dist then
			return {x = x, y = y, z = z}
		end
	end
end

function flylib.to_path(s, max_dist)
	local tPath
	local dist = 0

	for _, line in ipairs(strsplit(s)) do
		line = trim(line)
		line = string.split(line, "--", true, 1)[1] or ""
		if line ~= "" then
			local v = flylib.to_vector(line)
			if v then
				dist = dist + flylib.distance(v)
				if not max_dist or dist <= max_dist then
					tPath = tPath or {}
					tPath[#tPath + 1] = v
				else
					return tPath, S("Error: Max. length of the flight route exceeded by @1 blocks !!", dist - max_dist)
				end
			else
				return tPath, S("Error: Invalid path !!")
			end
		end
	end
	return tPath
end

local function next_path_pos(pos, lpath, idx)
	local offs = lpath[idx]
	if offs then
		return vector.add(pos, offs)
	end
end

local function reverse_path(lpath)
	local lres = {}
	for i = #lpath, 1, -1 do
		lres[#lres + 1] = vector.multiply(lpath[i], -1)
	end
	return lres
end

local function dest_offset(lpath)
	local offs = {x=0, y=0, z=0}
	for i = 1,#lpath do
		offs = vector.add(offs, lpath[i])
	end
	return offs
end

-------------------------------------------------------------------------------
-- Protect the doors from being opened by hand
-------------------------------------------------------------------------------
local function new_on_rightclick(old_on_rightclick)
	return function(pos, node, clicker, itemstack, pointed_thing)
		if M(pos):contains("ta_door_locked") then
			return itemstack
		end
		if old_on_rightclick then
			return old_on_rightclick(pos, node, clicker, itemstack, pointed_thing)
		else
			return itemstack
		end
	end
end

function flylib.protect_door_from_being_opened(name)
	-- Change on_rightclick function.
	local ndef = minetest.registered_nodes[name]
	if ndef then
		local old_on_rightclick = ndef.on_rightclick
		minetest.override_item(ndef.name, {
			on_rightclick = new_on_rightclick(old_on_rightclick)
		})
	end
end

-------------------------------------------------------------------------------
-- Entity / Move / Attach / Detach
-------------------------------------------------------------------------------
local MIN_SPEED = 0.4
local MAX_SPEED = 8
local CORNER_SPEED = 4

local function calc_speed(v)
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

-- Only the ID ist stored, not the object
local function get_object_id(object)
	for id, entity in pairs(minetest.luaentities) do
		if entity.object == object then
			return id
		end
	end
end

-- determine exact position of attached entities
local function obj_pos(obj)
	local _, _, pos = obj:get_attach()
	if pos then
		pos = vector.divide(pos, 29)
		return vector.add(obj:get_pos(), pos)
	end
end

-- Check access conflicts with other mods
local function lock_player(player)
	local meta = player:get_meta()
	if meta:get_int("player_physics_locked") == 0 then
		meta:set_int("player_physics_locked", 1)
		meta:set_string("player_physics_locked_by", "ta_flylib")
		return true
	end
	return false
end

local function unlock_player(player)
	local meta = player:get_meta()
	if meta:get_int("player_physics_locked") == 1 then
		if meta:get_string("player_physics_locked_by") == "ta_flylib" then
			meta:set_int("player_physics_locked", 0)
			meta:set_string("player_physics_locked_by", "")
			return true
		end
	end
	return false
end

local function detach_player(player)
	local pos = obj_pos(player)
	if pos then
		player:set_detach()
		player:set_properties({visual_size = {x=1, y=1}})
		player:set_pos(pos)
	end
	-- TODO: move to save position
end

-- Attach player/mob to given parent object (block)
local function attach_single_object(parent, obj, dir)
	local self = parent:get_luaentity()
	local res = obj:get_attach()
	if not res then -- not already attached
		local yaw
		if obj:is_player() then
			yaw = obj:get_look_horizontal()
		else
			yaw = obj:get_rotation().y
		end
		-- store for later use
		local offs = table.copy(dir)
		-- Calc entity rotation, which is relative to the parent's rotation
		local rot = parent:get_rotation()
		if self.param2 >= 20 then
			dir = rotate(dir, 2 * math.pi - rot.y)
			dir.y = -dir.y
			dir.x = -dir.x
			rot.y = rot.y - yaw
		elseif self.param2 < 4 then
			dir = rotate(dir, 2 * math.pi - rot.y)
			rot.y = rot.y - yaw
		end
		dir = vector.multiply(dir, 29)
		obj:set_attach(parent, "", dir, vector.multiply(rot, 180 / math.pi))
		obj:set_properties({visual_size = {x=2.9, y=2.9}})
		if obj:is_player() then
			if lock_player(obj) then
				table.insert(self.players, {name = obj:get_player_name(), offs = offs})
			end
		else
			table.insert(self.entities, {objID = get_object_id(obj), offs = offs})
		end
	end
end

-- Attach all objects around to the parent object
-- offs is the search/attach position offset
local function attach_objects(pos, offs, parent, yoffs)
	local pos1 = vector.add(pos, offs)
	for _, obj in pairs(minetest.get_objects_inside_radius(pos1, 0.9)) do
		local dir = vector.subtract(obj:get_pos(), pos)
		local entity = obj:get_luaentity()
		if entity then
			local mod = entity.name:gmatch("(.-):")()
			if techage.RegisteredMobsMods[mod] then
				dir.y = dir.y + yoffs
				attach_single_object(parent, obj, dir)
			end
		elseif obj:is_player() then
			attach_single_object(parent, obj, dir)
		end
	end
end

-- Detach all attached objects from the parent object
local function detach_objects(pos, self)
	for _, item in ipairs(self.entities or {}) do
		local entity = minetest.luaentities[item.objID]
		if entity then
			local obj = entity.object
			obj:set_detach()
			obj:set_properties({visual_size = {x=1, y=1}})
			local pos1 = vector.add(pos, item.offs)
			pos1.y = pos1.y - (self.yoffs or 0)
			obj:set_pos(pos1)
		end
	end
	for _, item in ipairs(self.players or {}) do
		local obj = minetest.get_player_by_name(item.name)
		if obj then
			obj:set_detach()
			obj:set_properties({visual_size = {x=1, y=1}})
			local pos1 = vector.add(pos, item.offs)
			pos1.y = pos1.y + 0.1
			obj:set_pos(pos1)
			unlock_player(obj)
		end
	end
	self.entities = {}
	self.players = {}
end

local function entity_to_node(pos, obj)
	local self = obj:get_luaentity()
	if self and self.item then
		detach_objects(pos, self)
		monitoring_del_entity(self.item)
		minetest.after(0.1, obj.remove, obj)
		set_node(self.item)
	end
end

local function node_to_entity(base_pos, start_pos, dest_pos)
	local meta = M(start_pos)
	local node, metadata

	if meta:contains("ta_move_block") then
		-- Move-block stored as metadata
		node = minetest.deserialize(meta:get_string("ta_move_block"))
		metadata = {}
		meta:set_string("ta_move_block", "")
		meta:set_string("ta_block_locked", "true")
	elseif not meta:contains("ta_block_locked") then
		-- Block with other metadata
		node = techage.get_node_lvm(start_pos)
		metadata = meta:to_table()
		minetest.after(0.1, minetest.remove_node, start_pos)
	else
		return
	end
	local obj = minetest.add_entity(start_pos, "techage:move_item")
	if obj then
		local self = obj:get_luaentity()
		local rot = techage.facedir_to_rotation(node.param2)
		obj:set_rotation(rot)
		obj:set_properties({wield_item=node.name})
		obj:set_armor_groups({immortal=1})

		-- To be able to revert to node
		self.param2 = node.param2
		self.item = {
			name = node.name,
			param2 = node.param2,
			metadata = metadata or {},
			dest_pos = dest_pos,
			base_pos = base_pos,
		}
		monitoring_add_entity(self.item)

		-- Prepare for attachments
		self.players = {}
		self.entities = {}
		-- Prepare for path walk
		self.path_idx = 1
		return obj
	end
end

-- move block direction
local function determine_dir(pos1, pos2)
	local vdist = vector.subtract(pos2, pos1)
	local ndist = vector.length(vdist)
	if ndist > 0 then
		return vector.divide(vdist, ndist)
	end
	return {x=0, y=0, z=0}
end

local function move_entity(obj, dest_pos, dir, is_corner)
	local self = obj:get_luaentity()
	self.dest_pos = dest_pos
	self.dir = dir
	if is_corner then
		local vel = vector.multiply(dir, math.min(CORNER_SPEED, self.max_speed))
		obj:set_velocity(vel)
	end
	local acc = vector.multiply(dir, self.max_speed / 2)
	obj:set_acceleration(acc)
end

local function moveon_entity(obj, self, pos1)
	local pos2 = next_path_pos(pos1, self.lpath, self.path_idx)
	if pos2 then
		self.path_idx = self.path_idx + 1
		local dir = determine_dir(pos1, pos2)
		move_entity(obj, pos2, dir, true)
		return true
	end
end

-- Handover the entity to the next movecontroller
local function handover_to(obj, self, pos1)
	if self.handover then
		local info = techage.get_node_info(self.handover)
		if info and info.name == "techage:ta4_movecontroller" then
			local meta = M(info.pos)
			if self.move2to1 then
				self.handover = meta:contains("handoverA") and meta:get_string("handoverA") or nil
			else
				self.handover = meta:contains("handoverB") and meta:get_string("handoverB") or nil
			end

			self.lpath = flylib.to_path(meta:get_string("path"))
			if pos1 and self.lpath then
				self.path_idx = 2
				if self.move2to1 then
					self.lpath[1] = vector.multiply(self.lpath[1], - 1)
				end
				local pos2 = next_path_pos(pos1, self.lpath, 1)
				local dir = determine_dir(pos1, pos2)
				if not self.handover then
					local nvm = techage.get_nvm(info.pos)
					nvm.lpos1 = nvm.lpos1 or {}
					if self.move2to1 then
						nvm.lpos1[self.pos1_idx] = pos2

					else
						nvm.lpos1[self.pos1_idx] = pos1
					end
				end
				move_entity(obj, pos2, dir)
				return true
			end
		end
	end
end

minetest.register_entity("techage:move_item", {
	initial_properties = {
		pointable = true,
		makes_footstep_sound = true,
		static_save = false,
		collide_with_objects = false,
		physical = false,
		visual = "wielditem",
		wield_item = "default:dirt",
		visual_size = {x=0.67, y=0.67, z=0.67},
		selectionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
	},

	on_step = function(self, dtime, moveresult)
		local stop_obj = function(obj, self)
			local dest_pos = self.dest_pos
			obj:move_to(self.dest_pos, true)
			obj:set_acceleration({x=0, y=0, z=0})
			obj:set_velocity({x=0, y=0, z=0})
			self.dest_pos = nil
			self.old_dist = nil
			return dest_pos
		end

		if self.dest_pos then
			local obj = self.object
			local pos = obj:get_pos()
			local dist = vector.distance(pos, self.dest_pos)
			local speed = calc_speed(obj:get_velocity())
			self.old_dist = self.old_dist or dist

			-- Landing
			if self.lpath and self.lpath[self.path_idx] then
				if dist < 1 or dist > self.old_dist then
					local dest_pos = stop_obj(obj, self)
					if not moveon_entity(obj, self, dest_pos) then
						minetest.after(0.5, entity_to_node, dest_pos, obj)
					end
					return
				end
			elseif self.handover and dist < 0.2 or dist > self.old_dist then
				local dest_pos = stop_obj(obj, self)
				if not handover_to(obj, self, dest_pos) then
					minetest.after(0.5, entity_to_node, dest_pos, obj)
				end
				return
			else
				if dist < 0.05 or dist > self.old_dist then
					local dest_pos = stop_obj(obj, self)
					minetest.after(0.5, entity_to_node, dest_pos, obj)
					return
				end
			end

			self.old_dist = dist

			-- Braking or limit max speed
			if self.handover then
				if speed > (dist * 4) or speed > self.max_speed then
					speed = math.min(speed, math.max(dist * 4, MIN_SPEED))
					local vel = vector.multiply(self.dir,speed)
					obj:set_velocity(vel)
					obj:set_acceleration({x=0, y=0, z=0})
				end
			else
				if speed > (dist * 2) or speed > self.max_speed then
					speed = math.min(speed, math.max(dist * 2, MIN_SPEED))
					local vel = vector.multiply(self.dir,speed)
					obj:set_velocity(vel)
					obj:set_acceleration({x=0, y=0, z=0})
				end
			end

			monitoring_trigger_entity(self.item)
		end
	end,
})

local function is_valid_dest(pos)
	local node = techage.get_node_lvm(pos)
	if techage.is_air_like(node.name) then
		return true
	end
	if not M(pos):contains("ta_move_block") then
		return true
	end
	return false
end

local function is_simple_node(pos)
	local node =techage.get_node_lvm(pos)
	local ndef = minetest.registered_nodes[node.name]
	return not techage.is_air_like(node.name) and techage.can_dig_node(node.name, ndef)
end

local function move_node(pos, pos1_idx, start_pos, lpath, max_speed, height, move2to1, handover, cpos)
	local pos2 = next_path_pos(start_pos, lpath, 1)
	-- optional for non-player objects
	local yoffs = M(pos):get_float("offset")

	if pos2 then
		local dir = determine_dir(start_pos, pos2)
		local obj = node_to_entity(pos, start_pos, pos2)

		if obj then
			local offs = {x=0, y=height or 1, z=0}
			attach_objects(start_pos, offs, obj, yoffs)
			if dir.y == 0 then
				if (dir.x ~= 0 and dir.z == 0) or (dir.x == 0 and dir.z ~= 0) then
					attach_objects(start_pos, dir, obj, yoffs)
				end
			end
			local self = obj:get_luaentity()
			self.path_idx = 2
			self.pos1_idx = pos1_idx
			self.lpath = lpath
			self.max_speed = max_speed
			self.move2to1 = move2to1
			self.handover = handover
			self.yoffs = yoffs
			move_entity(obj, pos2, dir)
			return true
		else
			return false
		end
	end
end

local function move_nodes(pos, meta, nvm, lpath, max_speed, height, move2to1, handover)
	local owner = meta:get_string("owner")
	techage.counting_add(owner, #lpath, #nvm.lpos1 * #lpath)

	for idx = 1, #nvm.lpos1 do
		local pos1 = nvm.lpos1[idx]
		local pos2 = nvm.lpos2[idx]
		--print("move_nodes", idx, P2S(pos1), P2S(pos2))

		if move2to1 then
			pos1, pos2 = pos2, pos1
		end

		if not minetest.is_protected(pos1, owner) and not minetest.is_protected(pos2, owner) then
			if is_simple_node(pos1) and is_valid_dest(pos2) then
				if move_node(pos, idx, pos1, lpath, max_speed, height, move2to1, handover) == false then
					meta:set_string("status", S("No valid node at the start position"))
					return false
				end
			else
				if not is_simple_node(pos1) then
					meta:set_string("status", S("No valid node at the start position"))
				else
					meta:set_string("status", S("No valid destination position"))
				end
				return false
			end
		else
			if minetest.is_protected(pos1, owner) then
				meta:set_string("status", S("Start position is protected"))
			else
				meta:set_string("status", S("Destination position is protected"))
			end
			return false
		end
	end
	meta:set_string("status", S("Running"))
	return true
end

-- Move nodes from lpos1 by the given x/y/z 'line'
local function move_nodes2(pos, meta, lpos1, line, max_speed, height)
	local owner = meta:get_string("owner")
	techage.counting_add(owner, #lpos1)

	local lpos2 = {}
	for idx = 1, #lpos1 do

		local pos1 = lpos1[idx]
		local pos2 = vector.add(lpos1[idx], line)
		lpos2[idx] = pos2

		if not minetest.is_protected(pos1, owner) and not minetest.is_protected(pos2, owner) then
			if is_simple_node(pos1) and is_valid_dest(pos2) then
				move_node(pos, idx, pos1, {line}, max_speed, height, false, false)
			else
				if not is_simple_node(pos1) then
					meta:set_string("status", S("No valid node at the start position"))
				else
					meta:set_string("status", S("No valid destination position"))
				end
				return false, lpos1
			end
		else
			if minetest.is_protected(pos1, owner) then
				meta:set_string("status", S("Start position is protected"))
			else
				meta:set_string("status", S("Destination position is protected"))
			end
			return false, lpos1
		end
	end

	meta:set_string("status", S("Running"))
	return true, lpos2
end

function flylib.move_to_other_pos(pos, move2to1)
	local meta = M(pos)
	local nvm = techage.get_nvm(pos)
	local lpath, err = flylib.to_path(meta:get_string("path")) or {}
	local max_speed = meta:contains("max_speed") and meta:get_int("max_speed") or MAX_SPEED
	local height = meta:contains("height") and meta:get_float("height") or 1
	local handover

	if err or nvm.running then return false end

	height = techage.in_range(height, 0, 1)
	max_speed = techage.in_range(max_speed, MIN_SPEED, MAX_SPEED)
	nvm.lpos1 = nvm.lpos1 or {}

	local offs = dest_offset(lpath)
	if move2to1 then
		lpath = reverse_path(lpath)
	end
	-- calc destination positions
	nvm.lpos2 = lvect_add_vec(nvm.lpos1, offs)

	if move2to1 then
		handover = meta:contains("handoverA") and meta:get_string("handoverA") or nil
	else
		handover = meta:contains("handoverB") and meta:get_string("handoverB") or nil
	end
	nvm.running = move_nodes(pos, meta, nvm, lpath, max_speed, height, move2to1, handover)
	nvm.moveBA = nvm.running and not move2to1
	return nvm.running
end

function flylib.move_to(pos, line)
	local meta = M(pos)
	local nvm = techage.get_nvm(pos)
	local height = techage.in_range(meta:contains("height") and meta:get_float("height") or 1, 0, 1)
	local max_speed = meta:contains("max_speed") and meta:get_int("max_speed") or MAX_SPEED
	local resp

	if nvm.running then return false end

	nvm.running, nvm.lastpos = move_nodes2(pos, meta, nvm.lastpos or nvm.lpos1, line, max_speed, height)
	return nvm.running
end

function flylib.reset_move(pos)
	local meta = M(pos)
	local nvm = techage.get_nvm(pos)
	local height = techage.in_range(meta:contains("height") and meta:get_float("height") or 1, 0, 1)
	local max_speed = meta:contains("max_speed") and meta:get_int("max_speed") or MAX_SPEED

	if nvm.running then return false end

	if nvm.lpos1 and nvm.lpos1[1] then
		local move = vector.subtract(nvm.lpos1[1], (nvm.lastpos or nvm.lpos1)[1])
		local resp

		nvm.running, nvm.lastpos = move_nodes2(pos, meta, nvm.lastpos or nvm.lpos1, move, max_speed, height)
		return nvm.running
	end
	return false
end

-- rot is one of "l", "r", "2l", "2r"
-- cpos is the center pos (optional)
function flylib.rotate_nodes(pos, posses1, rot)
	local meta = M(pos)
	local owner = meta:get_string("owner")
	local cpos = meta:contains("center") and flylib.to_vector(meta:get_string("center"))
	local posses2 = techage.rotate_around_center(posses1, rot, cpos)
	local param2
	local nodes2 = {}

	techage.counting_add(owner, #posses1 * 2)

	for i, pos1 in ipairs(posses1) do
		local node = techage.get_node_lvm(pos1)
		if rot == "l" then
			param2 = techage.param2_turn_right(node.param2)
		elseif rot == "r" then
			param2 = techage.param2_turn_left(node.param2)
		else
			param2 = techage.param2_turn_right(techage.param2_turn_right(node.param2))
		end
		if not minetest.is_protected(pos1, owner) and is_simple_node(pos1) then
			minetest.remove_node(pos1)
			nodes2[#nodes2 + 1] = {pos = posses2[i], name = node.name, param2 = param2}
		end
	end
	for _,item in ipairs(nodes2) do
		if not minetest.is_protected(item.pos, owner) and is_valid_dest(item.pos) then
			minetest.add_node(item.pos, {name = item.name, param2 = item.param2})
		end
	end
	return posses2
end

function flylib.exchange_node(pos, name, param2)
	local meta = M(pos)
	local move_block

	-- consider stored "objects"
	if meta:contains("ta_move_block") then
		move_block = meta:get_string("ta_move_block")
	end

	minetest.swap_node(pos, {name = name, param2 = param2})

	if move_block then
		meta:set_string("ta_move_block", move_block)
	end
end

function flylib.remove_node(pos)
	local meta = M(pos)
	local move_block

	-- consider stored "objects"
	if meta:contains("ta_move_block") then
		move_block = meta:get_string("ta_move_block")
	end

	minetest.remove_node(pos)

	if move_block then
		local node = minetest.deserialize(move_block)
		minetest.add_node(pos, node)
		meta:set_string("ta_move_block", "")
	end
end

minetest.register_on_joinplayer(function(player)
	unlock_player(player)
end)

minetest.register_on_leaveplayer(function(player)
	if unlock_player(player) then
		detach_player(player)
	end
end)

minetest.register_on_dieplayer(function(player)
	if unlock_player(player) then
		detach_player(player)
	end
end)

techage.flylib = flylib
