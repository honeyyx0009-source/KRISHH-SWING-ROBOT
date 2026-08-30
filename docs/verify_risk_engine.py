"""
Numerical verification of the KRISHH_SwingRobot shared-SL risk engine.

This mirrors ComputeSingleSL(), MaxRiskFreeAddLot() and the TryPyramid()
sizing loop from KRISHH_SwingRobot.mq5 so the claims in the EA header can be
checked instead of assumed.

Units: 1.0 == 1 ATR. Entry price of the first ticket is 0.0.
Price is walked upward monotonically (a clean uptrend) which is the
best case for pyramiding and therefore the right case to size against.
"""

# ---- EA inputs mirrored -------------------------------------------------
ATR                 = 1.0
R_DIST              = 1.20 * ATR   # InpSlAtrMult
BASE_LOT            = 0.01
VOL_STEP            = 0.01
VOL_MIN             = 0.01
ADD_AT_R            = [1.5, 2.5, 3.5]   # InpAddAtR
ADD_LOT_MULT        = [3, 5, 8]         # InpAddLotMult
STRICT_LADDER       = True              # InpAddStrictLadder
RISK_ALLOW_R        = 0.00              # InpBasketRiskAllowR
MIN_STOP_GAP_ATR    = 0.60              # InpMinStopGapATR
BE_BUFFER_ATR       = 0.10              # InpBeBufferATR
COST_PX             = 0.0               # InpCostPts, negligible in ATR units
BE_AT_R             = 1.00              # InpBeAtR
TRAIL_START_R       = 1.20              # InpTrailStartR
CH_MULT             = 2.80              # InpChandelierMult
CH_MULT_ADD         = 1.80              # InpChandelierMultAdd
STOPS_LEVEL         = 0.0               # broker minimum, negligible here

FIRST_ENTRY = 0.0


def norm_lots(x):
    v = round(x / VOL_STEP) * VOL_STEP
    if v < VOL_MIN:
        v = VOL_MIN
    return round(v, 2)


def floor_lots(x):
    """Largest tradable lot <= x, or 0 if below the minimum."""
    v = int(x / VOL_STEP + 1e-9) * VOL_STEP
    if v < VOL_MIN - 1e-12:
        return 0.0
    return round(v, 2)


class Basket:
    def __init__(self):
        self.vol = 0.0
        self.avg = 0.0
        self.count = 0
        self.sl = 0.0          # shared SL currently in the market
        self.has_sl = False

    def add(self, lot, price, sl):
        self.avg = (self.vol * self.avg + lot * price) / (self.vol + lot)
        self.vol += lot
        self.count += 1
        self.sl = sl
        self.has_sl = True

    def pl_at(self, p, add_lot=0.0, add_price=0.0):
        """Basket P/L at price p, in (lots * price) units."""
        return self.vol * (p - self.avg) + add_lot * (p - add_price)


def profit_in_r(price):
    return (price - FIRST_ENTRY) / R_DIST


def highest_high(price):
    # monotonic uptrend -> the running high is the current price
    return price


def compute_single_sl(b, add_lot, add_price, price):
    """Mirror of ComputeSingleSL()."""
    new_vol = b.vol + add_lot
    new_avg = ((b.vol * b.avg + add_lot * add_price) / new_vol) if new_vol > 0 else b.avg
    adds = max(0, b.count - 1) + (1 if add_lot > 0 else 0)

    buf = COST_PX + BE_BUFFER_ATR * ATR
    cur_r = profit_in_r(price)

    # 0. original structural stop
    target = FIRST_ENTRY - R_DIST

    # 1. first-entry breakeven
    if BE_AT_R > 0 and cur_r >= BE_AT_R:
        target = max(target, FIRST_ENTRY + buf)

    # 2. basket breakeven once pyramided
    if adds > 0:
        target = max(target, new_avg + buf)

    # 3. chandelier trail
    if cur_r >= TRAIL_START_R or adds > 0:
        ch_mult = CH_MULT_ADD if adds > 0 else CH_MULT
        target = max(target, highest_high(price) - ch_mult * ATR)

    # 4. safety gap
    gap = max(MIN_STOP_GAP_ATR * ATR, STOPS_LEVEL)
    if target > price - gap:
        target = price - gap

    # 5. ratchet
    if b.has_sl:
        target = max(target, b.sl)

    return target


def max_risk_free_add_lot(b, price):
    """Mirror of MaxRiskFreeAddLot():  x <= V*(P - A - gap)/gap"""
    if b.vol <= 0:
        return 0.0
    gap = max(MIN_STOP_GAP_ATR * ATR, STOPS_LEVEL)
    headroom = price - b.avg - gap
    if headroom <= 0:
        return 0.0
    return b.vol * headroom / gap


def try_pyramid(b, price, adds_done):
    """Mirror of the TryPyramid() risk gate. Returns (lot, sl) or None."""
    if adds_done >= len(ADD_AT_R):
        return None
    if profit_in_r(price) < ADD_AT_R[adds_done]:
        return None

    desired = norm_lots(BASE_LOT * ADD_LOT_MULT[adds_done])
    allow = RISK_ALLOW_R * BASE_LOT * R_DIST

    lot = desired
    for _ in range(500):
        test = norm_lots(lot)
        if test < VOL_MIN - 1e-12:
            break
        sl = compute_single_sl(b, test, price, price)
        net = b.pl_at(sl, test, price)
        if net >= -allow - 1e-12:
            return test, sl
        if STRICT_LADDER:
            break
        if test <= VOL_MIN + 1e-12:
            break
        lot = test - VOL_STEP
    return None


def main():
    b = Basket()

    # ---- first ticket ----
    initial_sl = FIRST_ENTRY - R_DIST
    b.add(BASE_LOT, FIRST_ENTRY, initial_sl)
    print("=" * 78)
    print("KRISHH_SwingRobot shared-SL risk engine verification")
    print("=" * 78)
    print(f"ATR = {ATR}, R = {R_DIST} ATR, base lot = {BASE_LOT}")
    print(f"ladder: adds at R {ADD_AT_R} with lot multipliers {ADD_LOT_MULT}")
    print(f"strict ladder = {STRICT_LADDER}, risk allowance = {RISK_ALLOW_R} R")
    print(f"min stop gap = {MIN_STOP_GAP_ATR} ATR, BE buffer = {BE_BUFFER_ATR} ATR")
    print("-" * 78)
    print(f"E0  : {BASE_LOT:.2f} lots at {FIRST_ENTRY:+.3f}  SL {initial_sl:+.3f} "
          f"(risk {BASE_LOT * R_DIST:.5f} lots*price = 1.00 R)")
    print("-" * 78)

    initial_risk = BASE_LOT * R_DIST
    adds_done = 0
    fired = []

    # walk price up in fine steps
    p = 0.0
    while p < 12.0 * ATR:
        p += 0.005 * ATR

        # trail the shared SL every step (ManageBasketSL)
        sl = compute_single_sl(b, 0.0, 0.0, p)
        if sl > b.sl:
            b.sl = sl

        res = try_pyramid(b, p, adds_done)
        if res is not None:
            lot, add_sl = res

            # cross-check: the closed-form ceiling must agree with the
            # numeric gate that actually authorised this add
            ceiling = max_risk_free_add_lot(b, p)
            assert lot <= ceiling + 1e-9, (
                f"closed-form ceiling {ceiling:.5f} is below the lot {lot:.2f} "
                f"the numeric gate accepted - the two disagree"
            )

            b.add(lot, p, max(add_sl, b.sl))
            adds_done += 1
            net = b.pl_at(b.sl)
            fired.append((adds_done, p, lot, b.vol, b.avg, b.sl, net))
            print(f"ADD#{adds_done}: {lot:.2f} lots at {p:+.3f} ({profit_in_r(p):.2f} R)")
            print(f"        closed-form risk-free ceiling here: {ceiling:.4f} lots")
            print(f"        basket -> {b.vol:.2f} lots, avg {b.avg:+.3f}")
            print(f"        shared SL {b.sl:+.3f}  "
                  f"(gap to price {p - b.sl:.3f} ATR = {(p - b.sl) / R_DIST:.2f} R)")
            print(f"        basket P/L if stopped here: {net:+.6f} lots*price "
                  f"= {net / initial_risk:+.2f} initial R")
            assert net >= -1e-9, "INVARIANT BROKEN: basket would lose at the shared SL"
            print("-" * 78)

    print()
    print("RESULT")
    print("-" * 78)
    if len(fired) == len(ADD_AT_R):
        print(f"all {len(fired)} ladder adds fired")
    else:
        print(f"only {len(fired)}/{len(ADD_AT_R)} adds fired within +12 ATR")

    print(f"final volume      : {b.vol:.2f} lots "
          f"({b.vol / BASE_LOT:.0f}x the starting size)")
    print(f"final shared SL   : {b.sl:+.3f}")
    print(f"worst case at SL  : {b.pl_at(b.sl):+.6f} lots*price "
          f"= {b.pl_at(b.sl) / initial_risk:+.2f} initial R")
    print()
    print("stop distance never fell below the safety gap:")
    for n, p, lot, vol, avg, sl, net in fired:
        print(f"  after ADD#{n}: price {p:+.3f}, SL {sl:+.3f}, "
              f"distance {p - sl:.3f} ATR (min allowed {MIN_STOP_GAP_ATR})")
        assert p - sl >= MIN_STOP_GAP_ATR - 1e-9, "INVARIANT BROKEN: stop too close to price"
    print()
    print("All invariants held: single SL, never widened, never closer than the")
    print("safety gap, and the basket cannot lose money once the first add is on.")


if __name__ == "__main__":
    main()
