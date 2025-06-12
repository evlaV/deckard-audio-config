-- WirePlumber
--
-- Copyright © 2021 Collabora Ltd.
--    @author Julian Bouzas <julian.bouzas@collabora.com>
--
-- SPDX-License-Identifier: MIT

-- create-item.lua script takes pipewire nodes and creates session items (a.k.a
-- linkable) objects out of them.

cutils = require ("common-utils")
log = Log.open_topic ("s-node")

items = {}
spatializers = {}
spatializer_stream_nodes = {}

function configProperties (node)
  local properties = node.properties
  local media_class = properties ["media.class"] or ""

  -- ensure a media.type is set
  if not properties ["media.type"] then
    for _, i in ipairs ({ "Audio", "Video", "Midi" }) do
      if media_class:find (i) then
        properties ["media.type"] = i
        break
      end
    end
  end

  properties ["item.node"] = node
  properties ["item.node.direction"] =
      cutils.mediaClassToDirection (media_class)
  properties ["item.node.type"] =
      media_class:find ("^Stream/") and "stream" or "device"
  properties ["item.plugged.usec"] = GLib.get_monotonic_time ()
  properties ["item.features.no-dsp"] =
      Settings.get_boolean ("node.features.audio.no-dsp")
  properties ["item.features.monitor"] =
      Settings.get_boolean ("node.features.audio.monitor-ports")
  properties ["item.features.control-port"] =
      Settings.get_boolean ("node.features.audio.control-port")
  properties ["node.id"] = node ["bound-id"]

  -- set the default media.role, if configured
  -- avoid Settings.get_string(), as it will parse the default "null" value
  -- as a string instead of returning nil
  local default_role = Settings.get ("node.stream.default-media-role")
  if default_role then
    default_role = default_role:parse()
    properties ["media.role"] = properties ["media.role"] or default_role
  end

  return properties
end

-- returns true if we should spatialize the node
function shouldSpatialize(node)
    -- only spatialize if the relevant wireplumber setting is enabled
    if not Settings.get_boolean("node.stream.spatial-audio") then
      return false
    end

    -- for now, spatialize every output stream...
    if string.find(node.properties["media.class"], "Audio") and string.find(node.properties["media.class"], "Output") then
        -- ...except nodes that are part of the spatializer filter chains or device filter chains themselves
        if string.find(node.properties["node.name"], "filter") and string.find(node.properties["node.name"], "chain") then
            return false
        elseif string.find(node.properties["node.name"], "virtual") and string.find(node.properties["node.name"], "sink") then
            return false
        elseif string.find(node.properties["node.name"], ".spatialize_filter_chain") then
            return false
        else
            return true
        end
    else
        return false
    end
end

-- returns true if we currently support spatializing audio streams with the given number of channels
function canSpatialize(numChannels)
    if numChannels == 1 or numChannels == 2 or numChannels == 6 or numChannels == 8 then
        return true
    else
        return false
    end
end

-- builds the string that should be set as the "args" parameter when instantiating the spatializer filter
-- chain for the given node
function getSpatializerArgs(node)
    local args
    local pid

    -- figure out the pid from the node's properties
    pid = 0
    if node.properties["application.process.id"] ~= nil then
        pid = tonumber(node.properties["application.process.id"])
        -- log:warning(pid .. " : " .. tostring(node.properties["application.process.binary"]) .. " : " .. tostring(node.properties["application.name"]))
    end

    args = 
        "{ " ..
            "node.description = \"" .. node.properties["node.name"] .. ".spatialize_filter_chain\" " ..
            "media.name = \"" .. node.properties["node.name"] .. ".spatialize_filter_chain\" " ..
            "filter.graph = { " ..
                "nodes = [ " ..
                    "{ " ..
                        "type = ladspa " ..
                        "name = filter " ..
                        "plugin = /usr/local/steamvr/bin/linuxarm64/vraudiocompositor.so " ..
                        "label = spatialize_stereo " ..
                        "control = { " ..
                            "\"PID\" = " .. tostring(pid) .. " " ..
                        "} " ..
                    "} " ..
                "] " ..
                "inputs = [ \"filter:In_FL\" \"filter:In_FR\" ] " ..
                "outputs = [ \"filter:Out_FL\" \"filter:Out_FR\" ] " ..
            "} " ..
            "capture.props = { " ..
                "node.name = \"" .. node.properties["node.name"] .. ".spatialize_filter_chain.capture\" " ..
                "media.class = Audio/Sink " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
                "spatialize.node = " .. tostring(node.id) .. " " ..
                "filter.smart = true " ..
                "filter.smart.name = filter-chain-spatialize " ..
                "filter.smart.target = { media.class = Audio/Sink, alsa.card_name = \"SM8250 LPASS\", device.profile.description = \"Speaker playback\" } " ..
                "filter.smart.before = [ filter-chain-sink ] " ..
            "} " ..
            "playback.props = { " ..
                "node.name = \"" .. node.properties["node.name"] .. ".spatialize_filter_chain.playback\" " ..
                "node.passive = true " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
            "} " ..
        "}"

    return args
end

-- helper function for adding a session item
function addItem(node, id, item_type, transition, no_advance, node_target_object)
    local props

    log:info (node, "creating item for node -> " .. item_type)

    -- create item
    item = SessionItem (item_type)
    items [id] = item

    -- configure item
    props = configProperties(node)
    if node_target_object ~= nil then
        props["target.object"] = tostring(node_target_object)
    end

    if not item:configure (props) then
        transition:return_error ("failed to configure item for node "
            .. tostring (id))
        return
    end

    -- activate item
    item:activate (Features.ALL, function (_, e)
        if e then
            transition:return_error ("failed to activate item: "
                .. tostring (e));
        else
            if not no_advance then
                transition:advance ()
            end
        end
    end)
end

-- helper function for adding a session item for a spatialized output stream node
function addSpatializedItem(node, id, item_type, transition)
    local spatializer
    local args

    -- create the filter chain
    args = getSpatializerArgs(node)
    spatializer = LocalModule("libpipewire-module-filter-chain", args, nil)
    if spatializer == nil then
        transition:return_error("failed to create filter chain")
        return
    end

    -- keep track of the filter chain, so we can destroy it when the stream node is destroyed
    spatializers[node.id] = spatializer

    -- keep track of the fact that we still need to create a session item for this node,
    -- which we're currently deferring to _after_ the session items for the filter chain's nodes
    -- have been created
    spatializer_stream_nodes[node.id] = node

    transition:advance()
end

-- helper function for adding a session item for the capture node of a spatializer filter chain
function addSpatializerCaptureItem(node, id, item_type, transition)
    local stream_node
    local stream_node_id

    stream_node_id = tonumber(node.properties["spatialize.node"])
    stream_node = spatializer_stream_nodes[stream_node_id]

    -- create a session item for this filter chain capture node, but don't advance the transition yet
    addItem(node, id, item_type, transition, true, nil)

    -- create a session item for the stream node which needs to use this filter chain
    addItem(stream_node, stream_node_id, item_type, transition, false, nil)
end

AsyncEventHook {
  name = "node/create-item",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Stream/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Video/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Audio/*", type = "pw-global" },
      Constraint { "wireplumber.is-virtual", "-", type = "pw" },
    },
  },
  steps = {
    start = {
      next = "register",
      execute = function (event, transition)
        local node = event:get_subject ()
        local id = node.id
        local item
        local item_type

        local media_class = node.properties ['media.class']
        if string.find (media_class, "Audio") then
          item_type = "si-audio-adapter"
        else
          item_type = "si-node"
        end

        -- if we should spatialize this node, create the filter chain and don't do anything else
        if shouldSpatialize(node) then
            -- create filter chain, don't create any session item yet
            addSpatializedItem(node, id, item_type, transition)
        elseif string.find(node.properties["node.name"], "spatialize_filter_chain.capture") then
            -- create a session item for the capture node
            -- create a session item for the output stream
            addSpatializerCaptureItem(node, id, item_type, transition)
        else
            -- create a session item
            addItem(node, id, item_type, transition, false, nil)
        end
      end,
    },
    register = {
      next = "none",
      execute = function (event, transition)
        local node = event:get_subject ()
        local bound_id = node ["bound-id"]
        local item = items [node.id]

        if item ~= nil then
            log:info (item, "activated item for node " .. tostring (bound_id))
            item:register ()
        end
        if node.properties["spatialize.node"] ~= nil then
            items[tonumber(node.properties["spatialize.node"])]:register()
        end
        transition:advance ()
      end,
    },
  },
}:register ()

SimpleEventHook {
  name = "node/destroy-item",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "media.class", "#", "Stream/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "media.class", "#", "Video/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "media.class", "#", "Audio/*", type = "pw-global" },
      Constraint { "wireplumber.is-virtual", "-", type = "pw" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local id = node.id
    if items [id] then
      items [id]:remove ()
      items [id] = nil
    end

    if spatializers[node.id] then
        spatializers[node.id] = nil
    end
    if spatializer_stream_nodes[node.id] then
        spatializer_stream_nodes[node.id] = nil
    end
  end
}:register ()
