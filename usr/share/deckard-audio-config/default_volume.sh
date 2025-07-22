#!/usr/bin/env bash

# Take a string node description and return the corresponding wpctl ID.
wpctl_id() {
    local node_desc="$1"
    local node_id=$(wpctl status | grep -m 1 "$node_desc" | cut -d '[' -f 1 | grep -o -E "[0-9]+")
    echo "$node_id"
}

echo "Waiting until pw-metadata lists the default audio sink..."
until [[ ! -z $(pw-metadata 0 'default.audio.sink' | grep 'value' | sed "s/.* value:'//;s/' type:.*$//;" | jq .name) ]]
do
    echo "Sleeping until pw-metadata gives us something..."
    sleep 2
done

if [[ ! -f "/data/home/steamvr/.local/state/wireplumber/default_volume" ]]; then
    echo "Setting default volume and writing sentinel file."
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.6 || true
    date > /data/home/steamvr/.local/state/wireplumber/default_volume
else
    echo "Found sentinel file at /data/home/steamvr/.local/state/wireplumber/default_volume. Not modifying default sink volume."
fi

wpctl status || true

