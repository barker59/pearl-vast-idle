#!/bin/bash
# GPU tuning for Pearl mining. Mode comes from /opt/pearl-idle/mode (supereco | eco | perf).
#   supereco: core locked to 1500 MHz, no offset, STOCK_PL  (~125 W per card, ~980 W wall)
#   eco : core locked per GPU (ECO_CLKS) for ~145 W each, no offset, STOCK_PL  (was 2200: ~182 TH/s, ~190 W per card)
#   ecoplus    : per-GPU locks (ECOP_CLKS) for ~165 W each (3.8.0: ~860 TH/s, ~1204 W wall)
#   ecoplusplus: per-GPU locks (ECOPP_CLKS) for ~190 W each (3.8.0: ~943 TH/s, ~1340 W wall)
#   perf: core unlocked, +350 MHz core offset, 270 W on all cards
# +500 core crashed GPU 3 twice (Xid 62); +1000 mem crashed it too and memory offsets gain nothing.
# pearl-tune.sh apply | reset | pl [gpu]     (root)
#   apply: tune for the current mode (called when the miner starts)
#   reset: stock settings for rentals - unlocked clock, 0 offsets, 300 W
#   pl   : restore the normal power limit, on one GPU if given (used by gpu-fan-curve after a heat cutback)
DIR=/opt/pearl-idle
MODE=$(cat $DIR/mode 2>/dev/null || echo eco)
STATE=/run/pearl-tuned        # exists while mining tuning is applied
ECO_CLK=1850
ECO_CLKS=(1890 1790 2040 2105 1985)  # per-GPU eco locks, ~145 W each with mem at 810 (2026-10-26: ~826 TH/s, ~1092 W wall); was 1740 1640 1815 1985 1730
SUPERECO_CLK=1500
ECOP_CLKS=(2025 1860 2115 2145 2040)   # ~165 W each (tuned on SRBMiner 3.8.0, 2026-10-24)
ECOPP_CLKS=(2235 2160 2235 2265 2235)  # ~190 W each
PERF_OFFSET=350
PERF_PL=270                   # user (10-25): 270 W cap on all cards in perf. 11-01 A/B on 3.8.3: 300 W = +1.7% TH/s for +7% power - not worth it
PERF_PL_6C=270                # .6C VBIOS cards would use 300 W; 270 W loses ~3% hashrate for 10% less power
STOCK_PL=300                  # matches gpu-power-limit.service

gpus() { nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null; }
offset() { for i in $(gpus); do $DIR/gpuoffset.py set $i core $1 0 >/dev/null; $DIR/gpuoffset.py set $i core $1 1 >/dev/null; done; }
perf_pl() {  # per-GPU limit by VBIOS family; optional GPU index
  nvidia-smi ${1:+-i $1} --query-gpu=index,vbios_version --format=csv,noheader | while IFS=', ' read -r i v; do
    if [[ $v == 98.03.6C.* ]]; then pl=$PERF_PL_6C; else pl=$PERF_PL; fi
    nvidia-smi -i $i -pl $pl >/dev/null
  done
}
set_pl() { [ -e $STATE ] && [ "$MODE" = perf ] && perf_pl $1 || nvidia-smi ${1:+-i $1} -pl $STOCK_PL >/dev/null; }

case $1 in
  apply)
    if [ "$MODE" = perf ]; then
      nvidia-smi -rgc >/dev/null; offset $PERF_OFFSET; perf_pl
    else
      offset 0; nvidia-smi -pl $STOCK_PL >/dev/null
      for i in $(gpus); do
        case $MODE in
          supereco)    clk=$SUPERECO_CLK ;;
          ecoplus)     clk=${ECOP_CLKS[$i]:-$ECO_CLK} ;;
          ecoplusplus) clk=${ECOPP_CLKS[$i]:-$ECO_CLK} ;;
          *)           clk=${ECO_CLKS[$i]:-$ECO_CLK} ;;
        esac
        nvidia-smi -i $i -lgc 210,$clk >/dev/null
      done
    fi
    nvidia-smi -lmc 810,810 >/dev/null  # pearlhash runs on-chip; idle the GDDR7 (+1.6% TH/s at 270 W, 2026-10-26)
    touch $STATE; echo "tuned: $MODE" ;;
  reset)
    rm -f $STATE; nvidia-smi -rgc >/dev/null; nvidia-smi -rmc >/dev/null; offset 0; nvidia-smi -pl $STOCK_PL >/dev/null
    echo "tuning reset to stock" ;;
  pl)
    set_pl $2 && echo "power limits restored ($MODE)" ;;
  *) echo "usage: $0 apply|reset|pl [gpu]"; exit 2 ;;
esac
