#!/bin/bash
cd /home/st-wangjun/project/RISCV_A910/synth
mkdir -p /tmp/strat/logs
rm -f /tmp/strat/DONE /tmp/strat/logs/*.log
# tag       synth_strategy              impl_strategy
arms="ctrl      -                           -
ndhi      -                           Performance_NetDelay_high
pexp      -                           Performance_Explore
prpo      -                           Performance_ExplorePostRoutePhysOpt
retim     -                           Performance_Retiming
synperf   Flow_PerfOptimized_high     Performance_Explore
syncarry  Flow_PerfThresholdCarry     Performance_Explore"
echo "$arms" | while read tag ss is; do
  [ -z "$tag" ] && continue
  [ "$ss" = "-" ] && ss=""
  [ "$is" = "-" ] && is=""
  setsid nohup vivado -mode batch -nojournal -nolog -source /tmp/strat/build_fmax_strat.tcl \
    -tclargs 6.5 impl "" "$ss" "$is" "_${tag}" > /tmp/strat/logs/st_${tag}.log 2>&1 < /dev/null &
  sleep 2
done
for i in $(seq 1 160); do
  n=$(grep -l "^FMAX_SUMMARY" /tmp/strat/logs/*.log 2>/dev/null | wc -l); n=${n:-0}
  r=$(pgrep -fc "build_fmax_strat.tc[l]" 2>/dev/null); r=${r:-0}
  if [ "$n" -ge 7 ] || [ "$r" -eq 0 ]; then break; fi
  sleep 30
done
grep -h "^FMAX_SUMMARY\|^STRAT_SET\|^WORST_NON_EX" /tmp/strat/logs/*.log > /tmp/strat/summary.txt 2>/dev/null
echo DONE_ALL > /tmp/strat/DONE
