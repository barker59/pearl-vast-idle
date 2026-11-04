#!/bin/bash
# Drive chassis GPU-zone fans (BMC headers FAN1-5) from GPU temperature.
# The BMC can't read GeForce temps, so its auto mode runs this zone blind (~30%).
# ASRock Rack AST2600 OEM commands: 0x3a 0xd0 0x11 = per-fan mode (0 auto, 2 manual),
# 0x3a 0xd0 0x0e = per-fan manual duty (%). Rear fans (headers 8-12) run at REAR_DUTY, others stay on BMC auto.
# Fans are capped at MAX_DUTY (user: never ramp to 100%, too loud). Past the fan cap,
# heat is handled by cutting the GPU power limit instead.
REST="0x14 0x14 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e"  # must stay <= BMC max duty (35%, set in web UI 10-17) or the whole write is rejected
MAX_DUTY=30            # ~6400rpm, same as BMC auto
REAR_DUTY=30           # headers 8-12, matches REST. BMC auto held them at 4400 rpm (11-04); 20% = 2400 rpm
MIN_DUTY=10            # BMC rejects duty writes below its configured min (raw 0x3a 0xd0 0x14 byte 0; was 20% after the 11-02 BMC reset, 10% on 11-04)
TUNE=/opt/pearl-idle/pearl-tune.sh

GPUFAN=/opt/pearl-idle/gpufan.py
GPU_FLOOR=60           # GPU's own fans: 60% <=75C, 75% at 80C, GPU_MAX at 87C
GPU_MAX=100            # GPU's own fans may hit 100% (user OK'd); chassis fans stay capped

auto() {
  ipmitool raw 0x3a 0xd0 0x11 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 >/dev/null
  for i in $(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null); do $GPUFAN auto $i; done
}
trap 'auto; exit 0' TERM INT
trap 'auto' EXIT

curve() {  # max GPU temp (C) -> duty %  (user 11-04: back to the original 10-30% curve)
  local t=$1
  if   [ $t -le 85 ]; then echo 10
  elif [ $t -le 87 ]; then echo 20
  else echo $MAX_DUTY; fi
}

power_for() {  # one GPU's temp (C), its current cutback (W, 0 = none) -> cutback; step down hot, restore when cool
  local t=$1 cur=$2
  if   [ $t -ge 91 ]; then echo 150
  elif [ $t -ge 89 ]; then [ $cur -gt 0 ] && [ $cur -lt 200 ] && echo $cur || echo 200
  elif [ $t -le 82 ]; then echo 0
  else echo $cur; fi
}

rear_mode() {  # max GPU temp (C) -> 2 = manual at REAR_DUTY, 0 = BMC auto (when hot, or if CPU temps can't be read)
  local t=$1 c
  c=$(ipmitool sensor reading TEMP_CPU1 TEMP_CPU2 2>/dev/null | awk -F'|' '{print int($2)}' | sort -n | tail -1)
  if ! [[ $c =~ ^[0-9]+$ ]] || [ $c -ge 70 ] || [ $t -ge 85 ]; then echo 0
  elif [ $c -lt 60 ] && [ $t -lt 80 ]; then echo 2
  else echo $rear; fi
}

gpu_curve() {  # GPU temp (C) -> GPU's own fan %
  local t=$1
  if   [ $t -le 75 ]; then echo $GPU_FLOOR
  elif [ $t -le 80 ]; then echo $(( GPU_FLOOR + (t - 75) * (75 - GPU_FLOOR) / 5 ))
  elif [ $t -ge 87 ]; then echo $GPU_MAX
  else echo $(( 75 + (t - 80) * (GPU_MAX - 75) / 7 )); fi
}

declare -A glast cut
last=-1
rear=0
while true; do
  temps=$(nvidia-smi --query-gpu=index,temperature.gpu,power.limit --format=csv,noheader,nounits 2>/dev/null)
  while IFS=', ' read -r i gt lim; do
    [[ $gt =~ ^[0-9]+$ ]] || continue
    g=$(gpu_curve $gt); gl=${glast[$i]:--1}
    if [ $gl -lt 0 ] || [ $g -gt $gl ] || [ $g -le $((gl - 3)) ]; then
      $GPUFAN set $i $g && { echo "GPU$i ${gt}C -> GPU fans ${g}%"; glast[$i]=$g; }
    fi
    # Heat cutback is per card, so one hot GPU doesn't slow the others. Re-assert it if
    # pearl-tune.sh apply/reset put the card back on its normal limit while it's still hot.
    c=${cut[$i]:-0}; np=$(power_for $gt $c)
    if [ $np -ne $c ] || { [ $np -gt 0 ] && [ "${lim%.*}" != $np ]; }; then
      if [ $np -eq 0 ]; then $TUNE pl $i >/dev/null; else nvidia-smi -i $i -pl $np >/dev/null; fi &&
        { echo "GPU$i ${gt}C -> power cutback ${c}W -> ${np}W (0 = normal limit)"; cut[$i]=$np; }
    fi
  done <<<"$temps"
  t=$(awk -F', ' '{print $2}' <<<"$temps" | sort -n | tail -1)
  if ! [[ $t =~ ^[0-9]+$ ]]; then
    [ $last -ne -2 ] && { echo "cannot read GPU temps - BMC auto"; auto; last=-2; }
    sleep 10; continue
  fi
  d=$(curve $t)
  [ $d -lt $MIN_DUTY ] && d=$MIN_DUTY
  rm=$(rear_mode $t)
  # Hysteresis: only step down when 3+ points lower, step up immediately.
  if [ $last -lt 0 ] || [ $d -gt $last ] || [ $d -le $((last - 3)) ] || [ $rm -ne $rear ]; then
    h=$(printf '0x%02x' $d)
    if ipmitool raw 0x3a 0xd0 0x0e $h $h $h $h $h $REST >/dev/null &&
       ipmitool raw 0x3a 0xd0 0x11 2 2 2 2 2 0 0 $rm $rm $rm $rm $rm 0 0 0 0 >/dev/null; then
      echo "GPU max ${t}C -> GPU-zone fans ${d}%, rear $([ $rm -eq 2 ] && echo ${REAR_DUTY}% || echo 'BMC auto')"; last=$d; rear=$rm
    else
      echo "ipmitool failed - BMC auto"; auto; last=-1; rear=0
    fi
  fi
  sleep 10
done
