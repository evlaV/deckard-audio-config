log = Log.open_topic ("s-node")

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
        "}"

    log:warning("XXX " .. node.id .. " : " .. pid .. " : " .. tostring(node.properties["application.process.binary"]) .. " : " .. tostring(node.properties["application.name"]))
    log:warning(args)

    return args
end


-- helper function for adding a session item for a spatialized output stream node
function spatializeNode(node)
    -- create the filter chain
    -- Note: This won't cooperate with other things that want to insert filters, but we are not expecting other per-application filters for now.
    local filter_graph = {
        "audioconvert.filter-graph.0",
        getSpatializerArgs(node)
    }

    local pod = Pod.Object {
      "Spa:Pod:Object:Param:Props", "Props",
      params = Pod.Struct (filter_graph)
    }
    node:set_params("Props", pod)
end

SimpleEventHook {
  name = "spatial-node/create-item",
  after = "node/create-item",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Stream/*", type = "pw-global" },
      Constraint { "library.name", "=", "audioconvert/libspa-audioconvert", type = "pw" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Audio/*", type = "pw-global" },
      Constraint { "wireplumber.is-virtual", "-", type = "pw" },
      Constraint { "library.name", "=", "audioconvert/libspa-audioconvert", type = "pw" },
    },
  },
   execute = function (event)
     local node = event:get_subject ()
     local id = node.id

     -- if we should spatialize this node, create the filter chain
     if shouldSpatialize(node) then
         spatializeNode(node)
     end
   end
}:register ()
