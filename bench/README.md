# Speed and memory benchmarks

`scripts/bench.sh` runs `bench/bench.lua`, which times the pure Lua parts of HouseLedger (`PriceLedger.lua`) and Unmaker (`UnmakerStats.lua`) on made-up data. It uses plain `lua5.1` and no packages, and it never reads a real saved file.

```bash
scripts/bench.sh --smoke   # small sizes with budgets; the gate runs it
scripts/bench.sh --full    # 6,600 and 20,000 items at 14, 30 and 60 days; about 30 seconds
```

## What the lines mean

| Line | Meaning |
| --- | --- |
| `memory ... kept` | Memory the data set holds after a full garbage collection, in MB and bytes per day row. |
| `memory ... different values` | How many different numbers and strings the saved file holds, as a share of Lua's constant limit (below). |
| `step ... ms` | Time for the step, from `os.clock`. It varies by machine. |
| `step ... KB allocated` | Memory the step allocates, counted with the garbage collector stopped. It's the same on every run. In game, all of it becomes garbage the game has to clean up. |
| `file about ... MB` | Size of the saved file, written in the game's format. |

A step over about 16 ms freezes a 60 frames per second game for at least one frame.

## The constant limit

The game loads a saved file as one Lua function. A Lua 5.1 function holds at most 262,143 constants, and each different number or string in the file is one constant. A file over the limit fails to load. Addon authors report that the game can then lose that addon's saved data. Blizzard doesn't document WoW's own limit; this is stock Lua 5.1's.

Day keys, prices that repeat and item names are shared, so a real file holds far fewer constants than values: a real 7-day file with 6,661 items had 41,351. Any change to the saved format or to how many days are kept must keep the `different values` line well under the limit, at 20,000 items too.

## The synthetic data

`bench/synth.lua` makes the same data on every run: a fixed-seed generator, never `math.random`. It's tuned against one real 7-day file. 84% of item-days are listed, prices are rounded to four significant digits, and a scan finds the same cheapest price as the scan before 85% of the time. With those settings, 6,661 items x 7 days gives about 42,000 different values (the real file: 41,351) and 225 bytes of memory per day row (the real file: about 250). Those numbers are from before scan lists. Each item now also keeps its last 30 scans; synth.lua spaces a day's 1 to 3 scans evenly up to 12:00, so every item in one scan shares its time, as in a real scan. That adds about 90 bytes per day row and almost no different values: a scan's time is shared by every item in it, and its price is nearly always that day's low or high.

## Budgets

The smoke run (`--smoke`, 2,000 items x 14 days and 2,000 Unmaker entries) fails a step that:

- allocates more than its `kb` budget,
- keeps more than `keptPerDayRow` bytes per day row,
- holds more than `constantShare` of the constant limit, or
- takes more than its `ms` budget. The time limit is loose, a guard against hangs, not a speed target.

The budgets in `BUDGETS` were set from measured values with about 1.5x headroom. An optimization that lowers a number should lower its budget in the same change, so the gain can't quietly slip back. Raise a budget only with a reason in the commit message. `BENCH_BUDGET_SCALE` multiplies every budget; `scripts/bench_test.sh` sets it tiny to check that a step over budget fails.
