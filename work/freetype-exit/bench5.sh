#!/bin/zsh
# Wait until nobody has changed a source file for 2 minutes and DataBrowser loads, then run the browser
# workload 5 times in a row.
cd /Users/davide/code/Julia/DataBrowser-dev
out=work/freetype-exit
for attempt in {1..40}; do
    newest=$(find lib src bench -name '*.jl' -newermt '-120 seconds' | head -1)
    if [[ -z $newest ]] && julia --project=bench --threads=auto -e 'using DataBrowser' > $out/load.txt 2>&1; then
        break
    fi
    sleep 60
done
for i in 1 2 3 4 5; do
    julia --project=bench --threads=auto test/runtests.jl bench browser --force > $out/bench$i.txt 2>&1
    echo "bench run $i: exit $?"
done
