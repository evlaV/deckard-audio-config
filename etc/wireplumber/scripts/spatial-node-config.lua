log = Log.open_topic ("s-node")

steamaudioloadermodule = LocalModule("vraudioloadermodule", "vraudio.samplerate=48000", nil)

spatializers = {}

loopbackStereo = nil
loopback71 = nil

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
        elseif string.find(node.properties["node.name"], "loopback") and string.find(node.properties["node.name"], "stereo") and string.find(node.properties["node.name"], "sink") then
            return false
        elseif string.find(node.properties["node.name"], "loopback") and string.find(node.properties["node.name"], "71") and string.find(node.properties["node.name"], "sink") then
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

-- builds the string that contains the ladspa plugin name to use for a given channel count
function getLADSPAPluginName(numChannels)
    if numChannels == 2 then
        return "spatialize_stereo"
    elseif numChannels == 6 then
        return "spatialize_51"
    elseif numChannels == 8 then
        return "spatialize_71"
    else
        return ""
    end
end

-- builds the string that describes the ladspa plugin input ports for a given channel count
function getFilterNodeInputs(numChannels)
    if numChannels == 2 then
        return "[ \"filter:In_FL\" \"filter:In_FR\" ]"
    elseif numChannels == 6 then
        return "[ \"filter:In_FL\" \"filter:In_FR\" \"filter:In_FC\" \"filter:In_LFE\" \"filter:In_RL\" \"filter:In_RR\" ]"
    elseif numChannels == 8 then
        return "[ \"filter:In_FL\" \"filter:In_FR\" \"filter:In_FC\" \"filter:In_LFE\" \"filter:In_RL\" \"filter:In_RR\" \"filter:In_SL\" \"filter:In_SR\" ]"
    else
        return ""
    end
end

-- builds the string that describes the input channel map for a given channel count
function getChannelPositions(numChannels)
    if numChannels == 2 then
        return "[ FL FR ]"
    elseif numChannels == 6 then
        return "[ FL FR FC LFE RL RR ]"
    elseif numChannels == 8 then
        return "[ FL FR FC LFE RL RR SL SR ]"
    else
        return ""
    end
end

-- builds the string that should be set as the "args" parameter when instantiating the spatializer filter
-- chain for the given node
function getSpatializerArgs(node)
    local args
    local pid
    local numChannels

    -- figure out the pid from the node's properties
    pid = 0
    if node.properties["application.process.id"] ~= nil then
        pid = tonumber(node.properties["application.process.id"])
        -- log:warning(pid .. " : " .. tostring(node.properties["application.process.binary"]) .. " : " .. tostring(node.properties["application.name"]))
    end

    -- todo: what is the "correct" way to get at the channel format requested by the stream?
    numChannels = 2
    for pod in node:iterate_params("EnumFormat") do
        local pod_parsed = pod:parse()
        if pod_parsed ~= nil then
            numChannels = tonumber(pod_parsed.properties.channels)
            break
        end
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
                        "label = " .. getLADSPAPluginName(numChannels) .. " " ..
                        "control = { " ..
                            "\"PID\" = " .. tostring(pid) .. " " ..
                        "} " ..
                    "} " ..
                "] " ..
                "inputs = " .. getFilterNodeInputs(numChannels) .. " " ..
                "outputs = [ \"filter:Out_FL\" \"filter:Out_FR\" ] " ..
            "} " ..
            "capture.props = { " ..
                "node.name = \"" .. node.properties["node.name"] .. ".spatialize_filter_chain.capture\" " ..
                "media.class = Audio/Sink " ..
                "audio.channels = " .. numChannels .. " " ..
                "audio.position = " .. getChannelPositions(numChannels) .. " " ..
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

function getLoopbackStereoArgs(device_id, cpd)
    args =
        "{ " ..
            "node.name = \"Built-in Audio (Stereo)\" " ..
            "capture.props = { " ..
                "node.name = \"Built-in Audio (Stereo)\" " ..
                "media.class = Audio/Sink " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
                "priority.session = 1000 " ..
                "alsa.loopback = true " ..
                "device.id = " .. device_id .. " " ..
                "card.profile.device = " .. cpd .. " " ..
            "} " ..
            "playback.props = { " ..
                "node.name = \"loopback-stereo-sink-playback\" " ..
                "node.passive = true " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
                "node.target = \"filter-chain-sink\" " ..
                "alsa.loopback = true " ..
            "} " ..
        "}"

    return args
end

function getLoopback71Args(device_id, cpd)
    args =
        "{ " ..
            "node.name = \"Built-in Audio (7.1)\" " ..
            "capture.props = { " ..
                "node.name = \"Built-in Audio (7.1)\" " ..
                "device.description = \"Built-in Audio (7.1)\" " ..
                "media.class = Audio/Sink " ..
                "audio.channels = 8 " ..
                "audio.position = [ FL FR FC LFE RL RR SL SR ] " ..
                "priority.session = 1000 " ..
                "alsa.loopback = true " ..
                "device.id = " .. device_id .. " " ..
                "card.profile.device = " .. cpd .. " " ..
            "} " ..
            "playback.props = { " ..
                "node.name = \"loopback-71-sink-playback\" " ..
                "node.passive = true " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
                "node.target = \"filter-chain-sink\" " ..
                "alsa.loopback = true " ..
            "} " ..
        "}"

    return args
end

SimpleEventHook {
    name = "spatial-node/setup-71-loopback",
    interests = {
        EventInterest {
            Constraint { "event.type", "=", "rescan-for-default-nodes" }
        },
        EventInterest {
            Constraint { "event.type", "=", "metadata-changed" },
            Constraint { "metadata.name", "=", "sm-settings" },
            Constraint { "event.subject.key", "=", "node.stream.spatial-audio-surround" }
        }
    },
    execute = function (event)
        local source = event:get_source()
        local metadata_om = source:call("get-object-manager", "metadata")
        local settings = metadata_om:lookup{ Constraint{ "metadata.name", "=", "sm-settings" } }

        -- find the actual built-in audio node, and get its device.id
        local node_om = source:call("get-object-manager", "node")
        local node = node_om:lookup{ Constraint{ "node.name", "=", "alsa_output.platform-sound.HiFi__Speaker__sink" } }
        if not node then
            return
        end

        device_id = node.properties["device.id"]
        card_profile_device = node.properties["card.profile.device"]
        if not device_id or not card_profile_device then
            return
        end

        if settings:find(0, "node.stream.spatial-audio-surround") == "true" then
            if loopbackStereo then
                loopbackStereo = nil
            end
            if not loopback71 then
                loopback71 = LocalModule("libpipewire-module-loopback", getLoopback71Args(device_id, card_profile_device))
            end
        else
            if loopback71 then
                loopback71 = nil
            end
            if not loopbackStereo then
                loopbackStereo = LocalModule("libpipewire-module-loopback", getLoopbackStereoArgs(device_id, card_profile_device))
            end
        end
    end
}:register()
