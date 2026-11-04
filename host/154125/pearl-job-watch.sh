#!/bin/bash
# Tune only the GPUs running the Pearl Vast default job. A card is tuned when the job starts
# on it and reset to stock as soon as the job stops; cards with no state change are never touched.
JOB_IMAGE_RE='^ghcr\.io/barker59/pearl-srb(:|$)'
TUNE=/opt/pearl-idle/pearl-tune.sh
STATE_DIR=/run/pearl-tuned.d   # one file per tuned GPU, maintained by pearl-tune.sh
STABLE=${STABLE:-20}           # seconds the job must stay up on a GPU before tuning; resets are immediate
declare -A seen                # GPU index -> when the job was first seen on it

log() { echo "$(date '+%F %T') $*"; }

job_gpus() {  # GPU indexes running the job; fails if docker can't be read
  local ps id devs d
  ps=$(docker ps --filter status=running --format '{{.ID}} {{.Image}}') || return 1
  while read -r id image; do
    [[ $image =~ $JOB_IMAGE_RE ]] || continue
    devs=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" | sed -n 's/^NVIDIA_VISIBLE_DEVICES=//p')
    for d in ${devs//,/ }; do
      [[ $d =~ ^[0-9]+$ ]] && echo "$d" || log "ignoring GPU id '$d' from container $id" >&2
    done
  done <<<"$ps"
}

sync_gpus() {
  local want i
  want=$(job_gpus) || { log "cannot read docker - leaving GPUs as they are"; return; }
  for f in "$STATE_DIR"/*; do
    [ -e "$f" ] || continue
    i=${f##*/}
    grep -qx "$i" <<<"$want" || log "GPU$i: $($TUNE reset-gpu "$i" 2>&1)"
  done
  for i in "${!seen[@]}"; do
    grep -qx "$i" <<<"$want" || unset "seen[$i]"
  done
  for i in $want; do
    : "${seen[$i]:=$(date +%s)}"
    [ -e "$STATE_DIR/$i" ] && continue
    [ $(( $(date +%s) - seen[$i] )) -ge $STABLE ] && log "GPU$i: $($TUNE apply-gpu "$i" 2>&1)"
  done
}

reset_all() {
  for f in "$STATE_DIR"/*; do
    [ -e "$f" ] && log "GPU${f##*/}: $($TUNE reset-gpu "${f##*/}" 2>&1)"
  done
}

trap 'reset_all; exit 0' TERM INT
# Container events give a fast reset when a client takes a card; the timeout is the fallback.
exec {EV}< <(docker events --filter type=container --filter event=start --filter event=die \
               --filter event=stop --filter event=pause --filter event=unpause --format '{{.Status}}')
while true; do
  read -t 5 -u $EV _ || [ $? -gt 128 ] || { log "docker event stream closed - exiting for restart"; reset_all; exit 1; }
  sync_gpus
done
