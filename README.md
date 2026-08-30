# KRISHH SWING ROBOT

An MT5 Expert Advisor that swing-trades the **H4** timeframe in the direction of the
higher-timeframe trend, enters on the bar that breaks into the trend, uses a **small
stop-loss**, has **no fixed take-profit** (it rides the trend until the trend flips),
and pyramids up to 3 additional larger positions that all share **one single
stop-loss price**.

- EA source: [`MQL5/Experts/KRISHH/KRISHH_SwingRobot.mq5`](MQL5/Experts/KRISHH/KRISHH_SwingRobot.mq5)
- Risk-engine proof: [`docs/verify_risk_engine.py`](docs/verify_risk_engine.py)
- Static validator: [`docs/check_mq5.py`](docs/check_mq5.py)

---

## Install

1. In MetaTrader 5: **File → Open Data Folder**.
2. Copy `KRISHH_SwingRobot.mq5` into `MQL5/Experts/`.
3. Open it in MetaEditor and press **F7** to compile. You need MT5 build 2085 or
   newer (the EA uses `input group`).
4. Attach it to an **H4** chart and enable **Algo Trading**.
5. The EA needs at least ~260 H4 bars of history plus D1 history for the regime
   filter, so press the History button / scroll back once before the first run.

One chart per symbol. The magic number isolates its own positions, so it will not
touch trades placed by you or by another EA.

---

## How it decides to trade

### 1. Regime gate (D1)

Only one direction is permitted at a time, decided by D1 EMA50 vs EMA200.
`REGIME_STRICT` additionally requires the D1 close to be on the correct side of
EMA50. Set `InpRegimeMode = REGIME_OFF` to disable.

### 2. Trend quality (H4)

Five independent measurements must all agree before anything is considered:

| Filter | Meaning | Default gate |
|---|---|---|
| EMA stack 20/50/200 | trend structure | fast > mid > slow |
| ADX(14) + DI | trend strength and side | ADX ≥ 22, +DI > −DI |
| Linear-regression **R²** over 40 bars | how *straight* the move is | ≥ 0.45 |
| Kaufman **Efficiency Ratio** over 20 bars | signal-to-noise of the move | ≥ 0.30 |
| Regression slope ÷ ATR | trend speed, volatility-normalised | ≥ 0.12 ATR/bar |

**R²** comes from an ordinary least-squares fit of close price against bar index:

```
R² = SSxy² / (SSxx · SSyy)
```

`R² = 1` is a perfectly straight line, `0` is directionless. It rejects the case
where the EMAs are stacked but price is actually chopping sideways.

**Efficiency Ratio** is net displacement divided by total path length:

```
ER = |C[t] − C[t−n]| / Σ |C[i] − C[i−1]|
```

`ER = 1` means price moved in a straight line, `ER → 0` means it wandered a long
way to get nowhere. This is the filter that keeps the EA out of grinding markets.

A volatility-regime check also skips the symbol when `ATR / ATR-average` is below
0.70 (dead) or above 2.20 (chaotic).

### 3. Entry timing

The order is punched on the **H4 close** that:

- closes beyond the 20-bar Donchian extreme (i.e. price is stepping *into* the trend),
- has a body ≥ 50% of the candle range,
- closes in the top (or bottom) 38% of that range,
- and agrees with RSI > 50 and MACD main > signal.

### 4. Probability score

Everything above is fused into a 0–100 score and the trade is skipped below
`InpMinScore` (default 70):

| Component | Weight |
|---|---|
| D1 regime agreement and separation | 18 |
| EMA fast/mid separation in ATR | 12 |
| ADX strength above the minimum | 15 |
| Regression R² above the minimum | 15 |
| Efficiency Ratio above the minimum | 10 |
| Breakout distance + candle body | 10 |
| MACD histogram in ATR | 8 |
| Regression slope in ATR | 8 |
| RSI distance from 50 | 4 |

### 5. Stop-loss (small)

```
SL = tighter of ( swing low over 5 bars − 0.18·ATR )  and  ( entry − 1.20·ATR )
```

then floored so it is never tighter than `0.55·ATR`, and the whole setup is
**rejected** if the resulting stop is wider than `2.20·ATR`. That distance becomes
**1R** and every later decision is measured in R.

### 6. Exit — there is no fixed take-profit

The position is closed only when one of these happens:

- the shared stop-loss is hit (it trails up behind a Chandelier stop:
  `highest high over 22 bars − 2.8·ATR`, tightening to `1.8·ATR` once pyramided), or
- the trend flips on a closed H4 bar: EMA fast crosses EMA mid against the
  position **and** MACD has also flipped.

So the profit target is whatever the trend gives.

---

## The pyramiding, and the trap it avoids

The requested behaviour was: start with 0.01, then add 2–3 bigger positions once in
profit, all sharing one small stop-loss.

The obvious implementation is broken, and it is worth being explicit about why.
Suppose you enter 0.01 at 100 with 1R = 1.00, then at +1R (price 101) you add 0.03
and pin the shared stop at the volume-weighted basket breakeven:

```
basket breakeven = (0.01·100 + 0.03·101) / 0.04 = 100.75
```

The stop is now at 100.75 while price is 101 — a **0.25R** stop. Ordinary H4 noise
takes that out almost immediately. Bigger adds make it worse, not better. You cannot
simultaneously have a huge add, a breakeven basket, and a stop with room to breathe.

### The fix: an analytic risk gate

An add is allowed only when the shared stop can satisfy **both** conditions at once:

- **(a) risk-free** — the stop sits at or above the basket breakeven, so the worst
  case for the whole basket is a scratch;
- **(b) room to breathe** — that same stop is still at least
  `InpMinStopGapATR · ATR` (default 0.60 ATR) away from price.

Writing `V` for existing volume, `A` for weighted average entry, `P` for price and
`g` for the safety gap, condition (a) and (b) together give a closed-form ceiling on
the add volume `x`:

```
(V·A + x·P) / (V + x)  ≤  P − g        =>        x  ≤  V · (P − A − g) / g
```

The EA evaluates that bound on every H4 bar and simply **waits** until the full
ladder lot fits. The R-triggers in `InpAddAtR` are therefore *minimums*; the maths
decides the real timing.

### Verified behaviour

`docs/verify_risk_engine.py` re-implements the same functions and walks price up
through a clean trend. With shipped defaults (R = 1.2 ATR, gap = 0.6 ATR, base 0.01,
multipliers 3/5/8):

```
E0     0.01 lots at 0.00R    SL = −1.20 ATR        risk = 1.00 R
ADD#1  0.03 lots at 2.00R -> 0.04 lots   basket P/L at shared SL =  0.00 R
ADD#2  0.05 lots at 2.62R -> 0.09 lots   basket P/L at shared SL =  0.00 R
ADD#3  0.08 lots at 3.50R -> 0.17 lots   basket P/L at shared SL = +1.42 R
```

A **17× position riding one trend behind one stop that can no longer lose money**,
and the stop never sits closer than 0.60 ATR to price. Run it yourself:

```bash
python3 docs/verify_risk_engine.py
```

It asserts both invariants (basket never negative at the shared SL, stop never
inside the safety gap) and cross-checks the closed-form ceiling against the numeric
sizing loop.

### The shared stop-loss

`ComputeSingleSL()` produces **one** price that is written to every ticket. It is the
most protective of:

1. the original structural stop,
2. first-entry breakeven, once profit ≥ `InpBeAtR`,
3. volume-weighted basket breakeven, once at least one add exists,
4. the Chandelier trailing stop, once profit ≥ `InpTrailStartR`,

then clamped so it is never closer to price than the safety gap, then ratcheted so
it can **never** widen. `RefreshBasket()` tracks whether all tickets currently agree
on the stop and forces a re-sync if a broker-side modification left one behind.

---

## Key inputs

Defaults are the tested configuration. The ones actually worth touching:

| Input | Default | Effect |
|---|---|---|
| `InpBaseLot` | 0.01 | first ticket size |
| `InpMinScore` | 70 | raise for fewer, higher-conviction trades |
| `InpSlAtrMult` | 1.20 | stop size in ATR — this defines 1R |
| `InpMaxSlAtrMult` | 2.20 | reject the setup if the stop would be wider |
| `InpAddAtR` | `1.5,2.5,3.5` | **minimum** R for each add |
| `InpAddLotMult` | `3,5,8` | add lots as multiples of the base lot |
| `InpMinStopGapATR` | 0.60 | **the anti-choke lever.** Lower = adds sooner but a tighter shared stop |
| `InpAddStrictLadder` | true | `true` waits for the full ladder lot; `false` adds a smaller lot sooner |
| `InpBasketRiskAllowR` | 0.00 | how much basket risk an add may leave, in R. `0` = strictly risk-free |
| `InpChandelierMult` | 2.80 | trail width before any add |
| `InpChandelierMultAdd` | 1.80 | tighter trail once the position is large |
| `InpRegimeMode` | `REGIME_NORMAL` | D1 filter strictness |
| `InpLotMode` | `LOT_FIXED` | switch to `LOT_RISK` to size the base lot off `InpRiskPct` |

Trade-off to understand before changing anything: **`InpMinStopGapATR` and how early
you pyramid are the same dial.** Reducing the gap makes adds happen sooner and the
basket bigger, at the cost of a shared stop that is easier to sweep. Raising it
delays the adds but the stop survives more noise.

The chart panel shows the live basket, the shared stop, whether the basket is
currently risk-free, and the exact risk-free lot ceiling at that moment — so you can
see the gate working rather than guessing.

---

## Verification status

| Check | Status |
|---|---|
| Risk-engine maths and invariants | verified, `docs/verify_risk_engine.py` passes |
| Closed-form ceiling vs numeric sizing loop | verified, they agree exactly |
| Brackets, unknown calls, undeclared identifiers, `printf` arg counts | verified, `docs/check_mq5.py` passes |
| Validator itself | self-tested against 6 deliberately injected bug classes, all caught |
| `iBarShift`, `CTrade::LogLevel` API usage | confirmed against MQL5 documentation |
| **MetaEditor compile** | **not done — no MQL5 compiler runs on Linux** |
| **Strategy Tester backtest** | **not done — needs MT5 and your broker's data** |

The last two are on you and they matter. Compile with F7, then run the Strategy
Tester on your symbol and broker in **"Every tick based on real ticks"** mode across
several years before risking money. The defaults are mathematically coherent, not
curve-fitted to your instrument.

`docs/check_mq5.py` is a static analyser, not a compiler. It catches typos and
structural mistakes; it cannot catch a type error that only MetaEditor would report.

---

## Notes and limits

- **Not a guaranteed-profit system.** The risk engine bounds the loss *of a basket
  once an add is on*. The first ticket, before any add, can still lose its full 1R,
  and a run of those is normal for trend following.
- Pyramiding needs real trends. On mean-reverting instruments the adds will rarely
  fire and you will mostly trade the base lot — that is the gate doing its job.
- `InpFridayNoNewEntry` is on by default to avoid opening a new swing into the
  weekend gap. Existing baskets are still managed on Friday.
- The initial R is stored in a terminal global variable so it survives restarts. If
  it is lost, the EA reconstructs it from the first ticket's entry and stop.
- Best suited to major FX pairs, indices and gold on H4. Test spreads first —
  `InpMaxSpreadPts` (default 35 points) will block entries on wide-spread symbols.
