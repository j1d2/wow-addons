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

Version 3 saved each day's exact sum and sum of squares, and those were nearly all different numbers. With about 5.5 scans a day they passed the limit at 20,000 items x 14 days or 10,000 x 30. Version 4 saves each day's average (4 significant digits, or the exact low or high when it equals one) and spread (2 digits) instead, which repeat. The `--full` run's heavy case (20,000 x 30, 1 to 10 scans a day) is now at 16%.

Checked on a real 13-day file (7,246 items, about 3 scans a day): 29% of the limit as version 3, 12% after converting to version 4. One item's typical price moved more than 1% (a few-copper item, one copper at a rounding edge) and one trend verdict changed. The synthetic data now undercounts real files: it gives 7% for a similar size, because its prices are rounded to four digits and real ones aren't. Read the `different values` lines as about half of a real file's.

What's left is the exact lows and highs. On a house where nearly every price is new, that part alone can still come near the limit at 20,000 items x 30 days.

60 days (a Settings choice since 0.5.0): the heavy case at 20,000 x 60 is 16% (about 30% for a real file, going by the undercount above). Memory is the bigger cost: about 67 MB kept at 6,600 x 60 against 24 MB at 14 days, and loading the 20,000 x 60 file (about 66 MB) takes about 0.7 s here.

## The synthetic data

`bench/synth.lua` makes the same data on every run: a fixed-seed generator, never `math.random`. It's tuned against one real 7-day file. 84% of item-days are listed, prices are rounded to four significant digits, and a scan finds the same cheapest price as the scan before 85% of the time. With those settings, 6,661 items x 7 days gives about 42,000 different values (the real file: 41,351) and 225 bytes of memory per day row (the real file: about 250). Those numbers are from before scan lists. Each item now also keeps its last 30 scans; synth.lua spaces a day's 1 to 3 scans evenly up to 12:00, so every item in one scan shares its time, as in a real scan. That adds about 90 bytes per day row and almost no different values: a scan's time is shared by every item in it, and its price is nearly always that day's low or high.

## Budgets

The smoke run (`--smoke`, 2,000 items x 14 days and 2,000 Unmaker entries) fails a step that:

- allocates more than its `kb` budget,
- keeps more than `keptPerDayRow` bytes per day row,
- holds more than `constantShare` of the constant limit, or
- takes more than its `ms` budget. The time limit is loose, a guard against hangs, not a speed target.

The budgets in `BUDGETS` were set from measured values with about 1.5x headroom. An optimization that lowers a number should lower its budget in the same change, so the gain can't quietly slip back. Raise a budget only with a reason in the commit message. `BENCH_BUDGET_SCALE` multiplies every budget; `scripts/bench_test.sh` sets it tiny to check that a step over budget fails.
