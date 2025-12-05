log = Log.open_topic ("s-node")

steamaudioloadermodule = LocalModule("vraudioloadermodule", "vraudio.samplerate=48000", nil)

spatializers = {}

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
                        "plugin = /opt/steamvr/bin/linuxarm64/vraudiocompositor.so " ..
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


-- helper function for adding a session item for a spatialized output stream node
function addSpatializedItem(node, id)
    local spatializer
    local args

    -- create the filter chain
    args = getSpatializerArgs(node)
    spatializer = LocalModule("libpipewire-module-filter-chain", args)
    if spatializer == nil then
        log:warning("failed to create filter chain")
        return
    end

    -- keep track of the filter chain, so we can destroy it when the stream node is destroyed
    spatializers[node.id] = spatializer
end

SimpleEventHook {
  name = "spatial-node/create-item",
  before = "node/create-item",
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
   execute = function (event)
     local node = event:get_subject ()
     local id = node.id

     -- if we should spatialize this node, create the filter chain
     if shouldSpatialize(node) then
         addSpatializedItem(node, id)
         local extra_si_properties = {
           ["target.object"] = node.properties["node.name"] .. ".spatialize_filter_chain.capture"
         }
         event:set_data ("extra-si-properties", extra_si_properties)
     end
   end
}:register ()

SimpleEventHook {
  name = "spatial-node/destroy-item",
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
    if spatializers[node.id] then
        spatializers[node.id] = nil
    end
  end
}:register ()
