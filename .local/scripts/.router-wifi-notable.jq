def bps_value:
    (
        (.download // "0 bps")
        | capture("(?<num>[0-9.]+)\\s*(?<unit>[GMK]?)bps")
        | (.num | tonumber) * (
            if .unit == "G" then 1000000000
            elif .unit == "M" then 1000000
            elif .unit == "K" then 1000
            else 1 end
          )
    ) // 0;

def is_offline: (.experience // "") as $e | $e == "" or $e == "-";

(map(select(.ap != "WireGuard")) | map(. + {bps: bps_value})) as $all
| ($all | map(select(is_offline | not)) | map(select(.experience != "Excellent"))) as $degraded
| ($all | sort_by(-.bps) | .[0:8] | map(select(.bps > 500000))) as $top
| ($degraded + $top | unique_by(.name + .ip)) as $notable
| {
    total: ($all | length),
    degraded: ($degraded | length),
    shown: ($notable | length),
    clients: ($notable | sort_by(if .experience == "Excellent" then 1 else 0 end, -.bps))
  }
