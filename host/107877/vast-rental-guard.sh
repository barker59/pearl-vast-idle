#!/bin/bash
# Reacts to vast.ai rental state + drives GPU fans:
#   rental starts -> stop xmrig + stop pearl(srb) miner
#   rental ends   -> (after cooldown) restart pearl(srb) + xmrig
#   FANS: forced to 100% whenever a rental is active OR the pearl(srb) miner is
#         running; back to auto only when neither is true. (SRB's default curve
#         let GPU0 throttle at 93C, so we hold fans at max while mining/renting.)
#   GPU PROFILE: while pearl runs (and no rental), lock VRAM to 810 MHz (pearlhash
#         isn't memory-bound) and set per-GPU power: GPU0 325W (poor airflow, ~86C),
#         GPU1 510W. Otherwise stock: memory unlocked, 450W cap (gpu-power-cap.sh).
#         Tuned 2026-10-31 with SRBMiner 3.8.3.
#   TEMP CEILING: while in the pearl profile, every ~30s step each GPU's power
#         limit up while it's below PEARL_CEIL_C and down once it's above, within
#         PEARL_PL_MIN/MAX. No combined cap any more (3 kW PSU since 2026-11-02); the
#         only coupling is PEARL_BALANCE_W, which keeps the two limits within that
#         many watts of each other (GPU1 sits below GPU0 and heats it).

LIST=/var/lib/vastai_kaalia/data/container_list.json
FAN_TOOL=/usr/local/bin/vast-set-fan.py
PY=/home/aaron/miniconda3/bin/python3
PEARL_CONTAINER=kryptex-prl-srb
MINING_PAUSED_FLAG=/etc/vast-mining-paused
# GPU fan % while pearl mines (no rental). aaron can write a number (40-100) here to run the
# GPU fans below 100%; the power governor then trims power to stay under the temp ceiling.
# Missing/invalid file = 100%. Rentals always get 100%.
PEARL_FAN_FILE=/home/aaron/pearl-gpu-fan-pct

is_rental_active() {
    [ -s "$LIST" ] || return 1
    "$PY" - "$LIST" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(data, list):
    sys.exit(1)
for c in data:
    s = c.get("State", {}) or {}
    if s.get("Running") is True or s.get("Status") == "running":
        sys.exit(0)
sys.exit(1)
PYEOF
}

pearl_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$PEARL_CONTAINER" 2>/dev/null)" = true ]
}

stop_xmrig_all() {
    systemctl stop xmrig 2>/dev/null || true
    # memo: xmrig may also run as root outside the service
    pkill -KILL -f '/xmrig$|/xmrig ' 2>/dev/null || true
}

# Pearl runs as a docker container (--restart=unless-stopped). A manual `docker stop`
# is honored by the restart policy, so the guard is the sole controller of when pearl
# runs vs. yields the GPUs to a paying renter.
stop_pearl() {
    docker stop "$PEARL_CONTAINER" 2>&1 | logger -t vast-rental-guard
}

start_pearl() {
    docker start "$PEARL_CONTAINER" 2>&1 | logger -t vast-rental-guard
}

SMI=/usr/bin/nvidia-smi
PEARL_PL=(430 560)   # starting per-GPU power limit while mining, indexed by GPU
PEARL_PL_MIN=(300 300)
PEARL_PL_MAX=(600 600)
PEARL_CEIL_C=89      # hold each GPU at or under this: up when <= CEIL-2, down when >= CEIL+1
PEARL_BALANCE_W=150  # max gap between the two GPUs' power limits
PEARL_PL_UP=10       # W per step when cool
PEARL_PL_DOWN=15     # W per step when hot
cur_pl=()
PEARL_MEMCLK=810
STOCK_PL=450

gpu_profile_pearl() {
    local i
    for i in "${!PEARL_PL[@]}"; do
        "$SMI" -i "$i" -lmc "$PEARL_MEMCLK" 2>&1 | logger -t vast-rental-guard
        "$SMI" -i "$i" -pl "${PEARL_PL[$i]}" 2>&1 | logger -t vast-rental-guard
        cur_pl[$i]=${PEARL_PL[$i]}
    done
}

# Step each GPU's limit to sit just under the ceiling: hold at CEIL-1..CEIL, down at
# CEIL+1 or hotter, up at CEIL-2 or cooler (unless that would open the gap to the other
# GPU's limit past PEARL_BALANCE_W). A GPU that's pulled down also drags a far-ahead
# partner back within the balance gap.
tune_pearl_pl() {
    local i j t new lo
    for i in "${!cur_pl[@]}"; do
        t=$("$SMI" -i "$i" --query-gpu=temperature.gpu --format=csv,noheader,nounits) || continue
        new=${cur_pl[$i]}
        lo=${cur_pl[0]}; for j in "${!cur_pl[@]}"; do [ "${cur_pl[$j]}" -lt "$lo" ] && lo=${cur_pl[$j]}; done
        if [ "$t" -ge $((PEARL_CEIL_C + 1)) ]; then
            new=$((new - PEARL_PL_DOWN))
            [ "$new" -lt "${PEARL_PL_MIN[$i]}" ] && new=${PEARL_PL_MIN[$i]}
        elif [ "$t" -le $((PEARL_CEIL_C - 2)) ]; then
            [ $((new + PEARL_PL_UP - lo)) -le "$PEARL_BALANCE_W" ] && new=$((new + PEARL_PL_UP))
            [ "$new" -gt "${PEARL_PL_MAX[$i]}" ] && new=${PEARL_PL_MAX[$i]}
        fi
        # never sit more than the balance gap above the lowest GPU
        [ $((new - lo)) -gt "$PEARL_BALANCE_W" ] && [ "$new" -ne "$lo" ] && new=$((lo + PEARL_BALANCE_W))
        [ "$new" = "${cur_pl[$i]}" ] && continue
        logger -t vast-rental-guard "gpu$i ${t}C: power limit ${cur_pl[$i]}W -> ${new}W"
        "$SMI" -i "$i" -pl "$new" >/dev/null 2>&1 && cur_pl[$i]=$new
    done
}

gpu_profile_stock() {
    "$SMI" -rmc 2>&1 | logger -t vast-rental-guard
    "$SMI" -pl "$STOCK_PL" 2>&1 | logger -t vast-rental-guard
}

fans_max() {
    "$PY" "$FAN_TOOL" 100 2>&1 | logger -t vast-rental-guard
}

pearl_fan_pct() {  # validated override from PEARL_FAN_FILE, else 100
    local v
    v=$(head -c 8 "$PEARL_FAN_FILE" 2>/dev/null | tr -cd '0-9')
    if [ -n "$v" ] && [ "$v" -ge 40 ] && [ "$v" -le 100 ]; then echo "$v"; else echo 100; fi
}

fans_auto() {
    "$PY" "$FAN_TOOL" auto 2>&1 | logger -t vast-rental-guard
}

# Centralized fan control. Only calls the fan tool when the desired state changes,
# so we don't spam nvidia-settings every poll.
fan_state=unset
apply_fans() {  # $1 = max | auto | <pct>
    [ "$1" = "$fan_state" ] && return
    if [ "$1" = max ]; then
        logger -t vast-rental-guard "fans -> 100% (rental active or pearl running)"
        fans_max
    elif [ "$1" != auto ]; then
        logger -t vast-rental-guard "fans -> $1% (pearl running, $PEARL_FAN_FILE)"
        "$PY" "$FAN_TOOL" "$1" 2>&1 | logger -t vast-rental-guard
    else
        logger -t vast-rental-guard "fans -> auto (idle, no pearl)"
        fans_auto
    fi
    fan_state="$1"
}

# Xcel peak: Mon-Fri 17:00-20:59 local. The xmrig-stop-peak timer fires once at 17:00,
# so if we restart inside that window nothing will re-stop xmrig until tomorrow's offpeak timer.
in_peak_hours() {
    local dow hour
    dow=$(date +%u)
    hour=$(date +%H)
    [ "$dow" -ge 1 ] && [ "$dow" -le 5 ] && [ "$hour" -ge 17 ] && [ "$hour" -le 20 ]
}

# Backgrounded on active->idle edge. Cooldown to absorb container cycling, re-check
# rental, skip if peak, then start xmrig.
delayed_start_xmrig() {
    sleep 30
    if [ -f "$MINING_PAUSED_FLAG" ]; then
        logger -t vast-rental-guard "mining paused ($MINING_PAUSED_FLAG exists); not restarting xmrig"
        return
    fi
    if is_rental_active; then
        logger -t vast-rental-guard "rental returned during cooldown; not restarting xmrig"
        return
    fi
    if in_peak_hours; then
        logger -t vast-rental-guard "in Xcel peak window; not restarting xmrig"
        return
    fi
    logger -t vast-rental-guard "cooldown elapsed and offpeak; starting xmrig"
    systemctl start xmrig 2>&1 | logger -t vast-rental-guard
}

# Pearl mirrors xmrig's cooldown+recheck, but is NOT peak-gated: runs whenever idle.
delayed_start_pearl() {
    sleep 15
    if [ -f "$MINING_PAUSED_FLAG" ]; then
        logger -t vast-rental-guard "mining paused ($MINING_PAUSED_FLAG exists); not restarting pearl"
        return
    fi
    if is_rental_active; then
        logger -t vast-rental-guard "rental returned during cooldown; not restarting pearl"
        return
    fi
    logger -t vast-rental-guard "cooldown elapsed; starting pearl miner"
    start_pearl
}

# Same change-only pattern as apply_fans.
gpu_state=unset
apply_gpu_profile() {  # $1 = pearl | stock
    [ "$1" = "$gpu_state" ] && return
    logger -t vast-rental-guard "gpu profile -> $1"
    if [ "$1" = pearl ]; then gpu_profile_pearl; else gpu_profile_stock; fi
    gpu_state="$1"
}

prev=unknown
tick=0
while true; do
    if is_rental_active; then active=1; else active=0; fi

    if [ "$active" = 1 ]; then
        if [ "$prev" != active ]; then
            logger -t vast-rental-guard "rental container detected; stopping xmrig + pearl"
            stop_xmrig_all
            stop_pearl
            prev=active
        fi
    else
        if [ "$prev" != idle ]; then
            if [ "$prev" = active ]; then
                logger -t vast-rental-guard "rental ended; scheduling xmrig + pearl restart"
                delayed_start_xmrig &
                delayed_start_pearl &
            else
                logger -t vast-rental-guard "no rental active at startup"
            fi
            prev=idle
        fi
    fi

    # FANS: 100% whenever a rental is active OR the pearl(srb) miner is running.
    if [ "$active" = 1 ]; then
        apply_fans max
    elif pearl_running; then
        fp=$(pearl_fan_pct)
        if [ "$fp" = 100 ]; then apply_fans max; else apply_fans "$fp"; fi
    else
        apply_fans auto
    fi

    # Mining profile only when pearl owns the GPUs; renters always get stock.
    if [ "$active" = 0 ] && pearl_running; then
        apply_gpu_profile pearl
    else
        apply_gpu_profile stock
    fi
    tick=$((tick + 1))
    [ "$gpu_state" = pearl ] && [ $((tick % 15)) = 0 ] && tune_pearl_pl

    sleep 2
done
