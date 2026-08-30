//+------------------------------------------------------------------+
//|                                        KRISHH_SwingRobot.mq5     |
//|                  H4 Swing Trend-Rider with Risk-Gated Pyramiding |
//|                  ONE single stop-loss shared by every ticket     |
//+------------------------------------------------------------------+
//  DESIGN
//  ------
//  1. REGIME GATE   : D1 EMA50/EMA200 decides the only side we may trade.
//
//  2. TREND QUALITY : H4 EMA stack + ADX/DI + linear-regression R^2 +
//                     Kaufman Efficiency Ratio + ATR-normalised slope,
//                     fused into a 0..100 probability score.
//
//  3. TIMING        : the order is punched on the H4 close that breaks a
//                     Donchian extreme with a momentum candle - i.e. at
//                     the exact moment price steps INTO the trend.
//
//  4. STOP LOSS     : small. Tighter of (swing structure + buffer) and
//                     (ATR * mult), floored so it is not razor thin,
//                     and the setup is rejected if it is wider than a cap.
//
//  5. TAKE PROFIT   : NONE. There is no fixed TP. The basket rides behind
//                     a Chandelier trailing stop and is closed only when
//                     the trend actually flips.
//
//  6. PYRAMIDING    : first ticket = base lot (0.01). Then up to 3 bigger
//                     tickets are added while the trend holds. Every
//                     ticket always carries the SAME single SL price.
//
//  7. THE RISK ENGINE (this is the important part)
//     A naive pyramid pins the shared SL at the volume weighted basket
//     breakeven. But a big add drags that breakeven right up under the
//     current price, leaving a stop only a fraction of an R away, which
//     gets swept by ordinary noise.
//
//     So an add is only allowed when BOTH conditions hold at once:
//        (a) the shared SL sits at/above basket breakeven  -> the basket
//            is risk free, worst case is a scratch, and
//        (b) that same SL is still at least InpMinStopGapATR * ATR away
//            from price -> it has room to breathe.
//
//     Solving (a) and (b) together for the add volume x, with existing
//     volume V, weighted average entry A, price P and safety gap g:
//
//            (V*A + x*P) / (V + x)  <=  P - g
//        =>  x  <=  V * (P - A - g) / g
//
//     The EA evaluates that bound on every H4 bar and simply waits until
//     the full ladder lot fits.
//
//     Verified by docs/verify_risk_engine.py with the shipped defaults
//     (R = 1.2 ATR, gap = 0.6 ATR, base 0.01, multipliers 3/5/8):
//
//        add #1  0.03 lots at 2.00 R  -> 0.04 lots, basket P/L at SL = 0
//        add #2  0.05 lots at 2.62 R  -> 0.09 lots, basket P/L at SL = 0
//        add #3  0.08 lots at 3.50 R  -> 0.17 lots, basket P/L at SL > 0
//
//     i.e. a 17x position riding one trend behind ONE stop that can no
//     longer lose money, and that never sits closer than 0.6 ATR to price.
//+------------------------------------------------------------------+
#property copyright   "KRISHH"
#property link        "https://github.com/honeyyx0009-source/KRISHH-SWING-ROBOT"
#property version     "1.10"
#property description "H4 swing trend-rider. Multi-factor probability score, small structural SL,"
#property description "no fixed TP (rides the trend until it flips), risk-gated pyramiding with"
#property description "ONE shared basket stop-loss that becomes risk-free after the first add."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,   // Fixed base lot (0.01 style)
   LOT_RISK  = 1    // Base lot sized from % risk of balance
  };

enum ENUM_REGIME_MODE
  {
   REGIME_STRICT = 0, // Strict : D1 EMA50>EMA200 AND D1 close>EMA50
   REGIME_NORMAL = 1, // Normal : D1 EMA50>EMA200 only
   REGIME_OFF    = 2  // Off    : no higher-timeframe filter
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=========== GENERAL ==========="
input long             InpMagic             = 20260830;  // Magic number
input ENUM_TIMEFRAMES  InpTF                = PERIOD_H4; // Trading timeframe
input ENUM_TIMEFRAMES  InpRegimeTF          = PERIOD_D1; // Higher timeframe (regime)
input ulong            InpSlippagePts       = 20;        // Max slippage (points)
input double           InpMaxSpreadPts      = 35;        // Max allowed spread (points)
input string           InpComment           = "KSR";     // Order comment prefix
input bool             InpShowPanel         = true;      // Show info panel on chart
input bool             InpVerboseLog        = true;      // Log why setups/adds are skipped

input group "=========== REGIME / TREND ENGINE ==========="
input ENUM_REGIME_MODE InpRegimeMode        = REGIME_NORMAL; // Higher-TF regime filter
input int              InpEmaFast           = 20;       // H4 EMA fast
input int              InpEmaMid            = 50;       // H4 EMA mid
input int              InpEmaSlow           = 200;      // H4 EMA slow
input bool             InpRequireFullStack  = true;     // Require fast>mid>slow stack
input int              InpAdxPeriod         = 14;       // ADX period
input double           InpAdxMin            = 22.0;     // Min ADX to enter
input double           InpAdxRef            = 40.0;     // ADX scoring 100%
input int              InpAtrPeriod         = 14;       // ATR period
input int              InpRsiPeriod         = 14;       // RSI period
input int              InpMacdFast          = 12;       // MACD fast EMA
input int              InpMacdSlow          = 26;       // MACD slow EMA
input int              InpMacdSignal        = 9;        // MACD signal

input group "=========== STATISTICAL TREND FILTERS ==========="
input int              InpRegBars           = 40;       // Linear-regression window (bars)
input double           InpMinR2             = 0.45;     // Min regression R^2 (0..1)
input int              InpErPeriod          = 20;       // Efficiency Ratio period
input double           InpMinER             = 0.30;     // Min Efficiency Ratio (0..1)
input double           InpMinSlopeATR       = 0.12;     // Min |slope| per bar in ATR units
input double           InpMinAtrRatio       = 0.70;     // Min ATR/ATR-avg (skip dead market)
input double           InpMaxAtrRatio       = 2.20;     // Max ATR/ATR-avg (skip chaos)
input int              InpAtrAvgBars        = 50;       // Bars for the ATR average

input group "=========== ENTRY TIMING ==========="
input int              InpDonchian          = 20;       // Donchian breakout lookback
input double           InpMinBodyRatio      = 0.50;     // Min candle body / range
input double           InpMinClosePos        = 0.62;    // Min close position within range
input double           InpMinScore          = 70.0;     // Min probability score (0..100)
input int              InpCooldownBars      = 2;        // Cooldown bars after a basket closes

input group "=========== STOP LOSS (small) ==========="
input double           InpSlAtrMult         = 1.20;     // SL = ATR * this
input int              InpStructLookback    = 5;        // Swing lookback for structural SL
input double           InpSlBufferATR       = 0.18;     // Buffer beyond structure (ATR)
input double           InpMaxSlAtrMult      = 2.20;     // Reject setup if SL wider than ATR*this
input double           InpMinSlAtrMult      = 0.55;     // SL never tighter than ATR*this

input group "=========== BASE LOT ==========="
input ENUM_LOT_MODE    InpLotMode           = LOT_FIXED;// Base lot mode
input double           InpBaseLot           = 0.01;     // Base lot (first ticket)
input double           InpRiskPct           = 0.50;     // Risk % per trade (LOT_RISK mode)

input group "=========== PYRAMIDING (risk gated) ==========="
input int              InpMaxAdds           = 3;        // Max adds after the first ticket
input string           InpAddAtR            = "1.5,2.5,3.5"; // Min R multiples to consider an add
input string           InpAddLotMult        = "3,5,8";  // Add lot = base lot * these
input bool             InpAddStrictLadder   = true;     // true=wait for full ladder lot, false=shrink it
input double           InpBasketRiskAllowR  = 0.00;     // Allowed basket loss at SL, in R of base risk
input double           InpMinStopGapATR     = 0.60;     // Shared SL never closer than this*ATR to price
input bool             InpAddNeedsNewHigh   = true;     // Add only on a fresh Donchian extreme
input bool             InpAddNeedsTrendOK   = true;     // Add only while the trend is still valid
input int              InpMinBarsBetweenAdds = 1;       // Min H4 bars between adds

input group "=========== SHARED SL MANAGEMENT ==========="
input bool             InpLockBasketBE      = true;     // After 1st add pin SL >= basket breakeven
input double           InpBeBufferATR       = 0.10;     // Breakeven buffer (ATR)
input double           InpCostPts           = 8;        // Est. round-trip cost (points)
input double           InpBeAtR             = 1.00;     // Move SL to 1st-entry BE at this R (0=off)
input double           InpTrailStartR       = 1.20;     // Start Chandelier trail at this R
input int              InpChandelierLen     = 22;       // Chandelier lookback
input double           InpChandelierMult    = 2.80;     // Chandelier ATR mult (before any add)
input double           InpChandelierMultAdd = 1.80;     // Chandelier ATR mult (after an add)

input group "=========== TREND-FLIP EXIT (replaces TP) ==========="
input bool             InpExitOnEmaFlip     = true;     // Exit when EMA fast crosses mid against us
input bool             InpExitNeedsMacd     = true;     // ...only if MACD also flipped
input bool             InpExitOnAdxCollapse = false;    // Exit when ADX and R^2 both collapse
input double           InpAdxExit           = 16.0;     // ADX collapse level
input double           InpR2Exit            = 0.15;     // R^2 collapse level
input double           InpMinProfitRtoFlip  = 0.0;      // Only flip-exit above this R (0=always)

input group "=========== SAFETY ==========="
input double           InpMaxEquityDDpct    = 25.0;     // Halt new baskets above this equity DD %
input bool             InpFridayNoNewEntry  = true;     // No new baskets on Friday
input int              InpStartHour         = 0;        // Entry window start hour (server)
input int              InpEndHour           = 23;       // Entry window end hour (server)

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade trade;

// indicator handles
int h_emaFast = INVALID_HANDLE;
int h_emaMid  = INVALID_HANDLE;
int h_emaSlow = INVALID_HANDLE;
int h_adx     = INVALID_HANDLE;
int h_atr     = INVALID_HANDLE;
int h_rsi     = INVALID_HANDLE;
int h_macd    = INVALID_HANDLE;
int h_rEma50  = INVALID_HANDLE;
int h_rEma200 = INVALID_HANDLE;

// price cache (as_series: index 0 = newest)
double   cHigh[], cLow[], cClose[], cOpen[];
datetime cTime[];

// indicator value cache
double vEmaFast[], vEmaMid[], vEmaSlow[];
double vAdxMain[], vAdxPlus[], vAdxMinus[];
double vAtr[], vRsi[], vMacdMain[], vMacdSig[];
double vREma50[], vREma200[];

// symbol meta
double symPoint, symTickSize, symTickValue, symVolMin, symVolMax, symVolStep;
int    symDigits, symVolDigits;

// bar tracking
datetime g_lastBarTime  = 0;
datetime g_lastAddBar   = 0;
datetime g_lastCloseBar = 0;

// basket snapshot
int      g_bDir        = 0;     // 0 flat, 1 long, -1 short
int      g_bCount      = 0;
double   g_bVol        = 0.0;
double   g_bAvg        = 0.0;   // volume weighted average entry
double   g_bSL         = 0.0;   // most protective SL currently in the market
bool     g_bSlUniform  = true;  // do all tickets already share one SL?
double   g_bFirstEntry = 0.0;
datetime g_bFirstTime  = 0;
double   g_bProfit     = 0.0;
ulong    g_bTickets[];

// pyramid config
double g_addAtR[];
double g_addMult[];

// misc
double g_peakEquity = 0.0;
string g_skipMsg    = "";

//+------------------------------------------------------------------+
//| Setup evaluation result                                          |
//+------------------------------------------------------------------+
struct SetupInfo
  {
   int    dir;        // 1 long, -1 short, 0 none
   double score;      // 0..100
   double sl;         // proposed stop price
   double rDist;      // |entry - sl|
   double atr;
   double adx;
   double r2;
   double er;
   double slopeAtr;
   string reason;
  };

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
void   RefreshBasket(void);
bool   SyncBasketSL(const double rawSL);
double ProfitInR(const double rDist);
bool   TrendStillValid(const int dir);
void   ResetSetup(SetupInfo &s);
double ComputeSingleSL(const double addLot, const double addPrice, const double rDist);
void   ManageBasketSL(const double rDist, const bool force);
double BasketPLatPrice(const double p, const double addLot, const double addPrice);
double BaseLot(const double slDistance);
double NormalizeLots(double lots);
double StopsLevelPrice(void);
double HighestHigh(const int start, const int count);
double LowestLow(const int start, const int count);
bool   LinReg(const double &price[], const int start, const int n, double &slope, double &r2);

//+------------------------------------------------------------------+
//| Small utilities                                                  |
//+------------------------------------------------------------------+
double Clip01(const double v)
  {
   if(v < 0.0) return 0.0;
   if(v > 1.0) return 1.0;
   return v;
  }

// pick the more protective of two stop prices for the given direction
double MoreProtective(const int dir, const double a, const double b)
  {
   if(dir > 0) return MathMax(a, b);
   return MathMin(a, b);
  }

void Vlog(const string msg)
  {
   if(!InpVerboseLog) return;
   if(msg == g_skipMsg) return;   // don't spam the same reason
   g_skipMsg = msg;
   Print(msg);
  }

string RKey()
  {
   return "KSR_R_" + _Symbol + "_" + IntegerToString(InpMagic);
  }

void SetStoredR(const double r) { GlobalVariableSet(RKey(), r); }

double GetStoredR()
  {
   if(GlobalVariableCheck(RKey())) return GlobalVariableGet(RKey());
   return 0.0;
  }

void ClearStoredR()
  {
   if(GlobalVariableCheck(RKey())) GlobalVariableDel(RKey());
  }

//+------------------------------------------------------------------+
//| Parse a comma separated list of doubles                          |
//+------------------------------------------------------------------+
bool ParseCsvDoubles(const string src, double &out[])
  {
   string parts[];
   int n = StringSplit(src, ',', parts);
   if(n <= 0)
     {
      ArrayResize(out, 0);
      return false;
     }
   ArrayResize(out, n);
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      out[i] = StringToDouble(s);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   symDigits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   symPoint     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   symTickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   symTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   symVolMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   symVolMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   symVolStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(symPoint    <= 0.0) symPoint    = 0.00001;
   if(symTickSize <= 0.0) symTickSize = symPoint;
   if(symVolStep  <= 0.0) symVolStep  = 0.01;
   if(symVolMin   <= 0.0) symVolMin   = symVolStep;

   symVolDigits = 0;
   double st = symVolStep;
   while(st < 1.0 && symVolDigits < 8)
     {
      st *= 10.0;
      symVolDigits++;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   // ---- pyramid ladder ----
   ParseCsvDoubles(InpAddAtR,     g_addAtR);
   ParseCsvDoubles(InpAddLotMult, g_addMult);

   if(ArraySize(g_addAtR) == 0 || ArraySize(g_addMult) == 0)
     {
      Print("ERROR: InpAddAtR / InpAddLotMult could not be parsed.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(ArraySize(g_addAtR) != ArraySize(g_addMult))
     {
      PrintFormat("ERROR: InpAddAtR (%d entries) and InpAddLotMult (%d entries) must match.",
                  ArraySize(g_addAtR), ArraySize(g_addMult));
      return INIT_PARAMETERS_INCORRECT;
     }
   for(int i = 0; i < ArraySize(g_addAtR); i++)
     {
      if(g_addMult[i] <= 0.0)
        {
         Print("ERROR: InpAddLotMult entries must be > 0.");
         return INIT_PARAMETERS_INCORRECT;
        }
      if(i > 0 && g_addAtR[i] <= g_addAtR[i - 1])
        {
         Print("ERROR: InpAddAtR must be strictly increasing.");
         return INIT_PARAMETERS_INCORRECT;
        }
     }

   if(InpEmaFast >= InpEmaMid || InpEmaMid >= InpEmaSlow)
     {
      Print("ERROR: need EmaFast < EmaMid < EmaSlow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRegBars < 10)
     {
      Print("ERROR: InpRegBars must be >= 10.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinStopGapATR <= 0.0)
     {
      Print("ERROR: InpMinStopGapATR must be > 0 (it is what stops the shared SL choking the trade).");
      return INIT_PARAMETERS_INCORRECT;
     }

   // ---- indicator handles ----
   h_emaFast = iMA(_Symbol, InpTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   h_emaMid  = iMA(_Symbol, InpTF, InpEmaMid,  0, MODE_EMA, PRICE_CLOSE);
   h_emaSlow = iMA(_Symbol, InpTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   h_adx     = iADX(_Symbol, InpTF, InpAdxPeriod);
   h_atr     = iATR(_Symbol, InpTF, InpAtrPeriod);
   h_rsi     = iRSI(_Symbol, InpTF, InpRsiPeriod, PRICE_CLOSE);
   h_macd    = iMACD(_Symbol, InpTF, InpMacdFast, InpMacdSlow, InpMacdSignal, PRICE_CLOSE);

   if(InpRegimeMode != REGIME_OFF)
     {
      h_rEma50  = iMA(_Symbol, InpRegimeTF, 50,  0, MODE_EMA, PRICE_CLOSE);
      h_rEma200 = iMA(_Symbol, InpRegimeTF, 200, 0, MODE_EMA, PRICE_CLOSE);
     }

   if(h_emaFast == INVALID_HANDLE || h_emaMid == INVALID_HANDLE || h_emaSlow == INVALID_HANDLE ||
      h_adx == INVALID_HANDLE || h_atr == INVALID_HANDLE || h_rsi == INVALID_HANDLE ||
      h_macd == INVALID_HANDLE ||
      (InpRegimeMode != REGIME_OFF && (h_rEma50 == INVALID_HANDLE || h_rEma200 == INVALID_HANDLE)))
     {
      Print("ERROR: indicator handle creation failed.");
      return INIT_FAILED;
     }

   ArraySetAsSeries(cHigh,     true);
   ArraySetAsSeries(cLow,      true);
   ArraySetAsSeries(cClose,    true);
   ArraySetAsSeries(cOpen,     true);
   ArraySetAsSeries(cTime,     true);
   ArraySetAsSeries(vEmaFast,  true);
   ArraySetAsSeries(vEmaMid,   true);
   ArraySetAsSeries(vEmaSlow,  true);
   ArraySetAsSeries(vAdxMain,  true);
   ArraySetAsSeries(vAdxPlus,  true);
   ArraySetAsSeries(vAdxMinus, true);
   ArraySetAsSeries(vAtr,      true);
   ArraySetAsSeries(vRsi,      true);
   ArraySetAsSeries(vMacdMain, true);
   ArraySetAsSeries(vMacdSig,  true);
   ArraySetAsSeries(vREma50,   true);
   ArraySetAsSeries(vREma200,  true);

   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   PrintFormat("KRISHH_SwingRobot v1.10 init OK | %s %s | magic %I64d | base lot %.2f | max adds %d",
               _Symbol, EnumToString(InpTF), InpMagic, InpBaseLot, InpMaxAdds);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(h_emaFast != INVALID_HANDLE) IndicatorRelease(h_emaFast);
   if(h_emaMid  != INVALID_HANDLE) IndicatorRelease(h_emaMid);
   if(h_emaSlow != INVALID_HANDLE) IndicatorRelease(h_emaSlow);
   if(h_adx     != INVALID_HANDLE) IndicatorRelease(h_adx);
   if(h_atr     != INVALID_HANDLE) IndicatorRelease(h_atr);
   if(h_rsi     != INVALID_HANDLE) IndicatorRelease(h_rsi);
   if(h_macd    != INVALID_HANDLE) IndicatorRelease(h_macd);
   if(h_rEma50  != INVALID_HANDLE) IndicatorRelease(h_rEma50);
   if(h_rEma200 != INVALID_HANDLE) IndicatorRelease(h_rEma200);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Data refresh                                                     |
//+------------------------------------------------------------------+
int RequiredBars()
  {
   int need = InpEmaSlow + 20;
   need = MathMax(need, InpRegBars + 10);
   need = MathMax(need, InpErPeriod + 10);
   need = MathMax(need, InpDonchian + 10);
   need = MathMax(need, InpChandelierLen + 10);
   need = MathMax(need, InpAtrAvgBars + InpAtrPeriod + 10);
   return MathMax(need, 260);
  }

bool RefreshData()
  {
   int bars = RequiredBars();

   if(CopyHigh (_Symbol, InpTF, 0, bars, cHigh)  < bars) return false;
   if(CopyLow  (_Symbol, InpTF, 0, bars, cLow)   < bars) return false;
   if(CopyClose(_Symbol, InpTF, 0, bars, cClose) < bars) return false;
   if(CopyOpen (_Symbol, InpTF, 0, bars, cOpen)  < bars) return false;
   if(CopyTime (_Symbol, InpTF, 0, bars, cTime)  < bars) return false;

   if(CopyBuffer(h_emaFast, 0, 0, bars, vEmaFast) < bars) return false;
   if(CopyBuffer(h_emaMid,  0, 0, bars, vEmaMid)  < bars) return false;
   if(CopyBuffer(h_emaSlow, 0, 0, bars, vEmaSlow) < bars) return false;
   if(CopyBuffer(h_adx, 0, 0, bars, vAdxMain)  < bars) return false;
   if(CopyBuffer(h_adx, 1, 0, bars, vAdxPlus)  < bars) return false;
   if(CopyBuffer(h_adx, 2, 0, bars, vAdxMinus) < bars) return false;
   if(CopyBuffer(h_atr, 0, 0, bars, vAtr) < bars) return false;
   if(CopyBuffer(h_rsi, 0, 0, bars, vRsi) < bars) return false;
   if(CopyBuffer(h_macd, 0, 0, bars, vMacdMain) < bars) return false;
   if(CopyBuffer(h_macd, 1, 0, bars, vMacdSig)  < bars) return false;

   if(InpRegimeMode != REGIME_OFF)
     {
      if(CopyBuffer(h_rEma50,  0, 0, 5, vREma50)  < 5) return false;
      if(CopyBuffer(h_rEma200, 0, 0, 5, vREma200) < 5) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| MATH: linear regression slope + R^2 over n closed bars           |
//|  price[] is as_series, start = newest index used.                |
//|  slope = price change per bar going FORWARD in time.             |
//|  R^2   = (SSxy)^2 / (SSxx * SSyy)                                |
//+------------------------------------------------------------------+
bool LinReg(const double &price[], const int start, const int n, double &slope, double &r2)
  {
   slope = 0.0;
   r2    = 0.0;
   if(n < 3) return false;
   if(ArraySize(price) < start + n) return false;

   double sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0;
   for(int i = 0; i < n; i++)
     {
      double x = (double)i;                    // 0 = oldest bar in the window
      double y = price[start + (n - 1 - i)];   // walk forward in time
      sx  += x;
      sy  += y;
      sxx += x * x;
      syy += y * y;
      sxy += x * y;
     }
   double nn   = (double)n;
   double ssxx = sxx - sx * sx / nn;
   double ssyy = syy - sy * sy / nn;
   double ssxy = sxy - sx * sy / nn;

   if(ssxx <= 0.0) return false;
   slope = ssxy / ssxx;
   r2    = (ssyy > 0.0) ? (ssxy * ssxy) / (ssxx * ssyy) : 0.0;
   if(r2 > 1.0) r2 = 1.0;
   return true;
  }

//+------------------------------------------------------------------+
//| MATH: Kaufman Efficiency Ratio                                   |
//|   ER = |C[start] - C[start+n]| / sum(|C[i] - C[i+1]|)            |
//|   1.0 = perfectly straight move, 0.0 = pure noise                |
//+------------------------------------------------------------------+
double EfficiencyRatio(const double &price[], const int start, const int n)
  {
   if(n < 2) return 0.0;
   if(ArraySize(price) < start + n + 1) return 0.0;

   double direction  = MathAbs(price[start] - price[start + n]);
   double volatility = 0.0;
   for(int i = 0; i < n; i++)
      volatility += MathAbs(price[start + i] - price[start + i + 1]);

   if(volatility <= 0.0) return 0.0;
   return Clip01(direction / volatility);
  }

//+------------------------------------------------------------------+
//| Price / series helpers                                           |
//+------------------------------------------------------------------+
double HighestHigh(const int start, const int count)
  {
   double m  = -DBL_MAX;
   int    sz = ArraySize(cHigh);
   for(int i = start; i < start + count && i < sz; i++)
      if(cHigh[i] > m) m = cHigh[i];
   return m;
  }

double LowestLow(const int start, const int count)
  {
   double m  = DBL_MAX;
   int    sz = ArraySize(cLow);
   for(int i = start; i < start + count && i < sz; i++)
      if(cLow[i] < m) m = cLow[i];
   return m;
  }

double AtrAverage(const int start, const int count)
  {
   double s  = 0.0;
   int    k  = 0;
   int    sz = ArraySize(vAtr);
   for(int i = start; i < start + count && i < sz; i++)
     {
      s += vAtr[i];
      k++;
     }
   return (k > 0) ? s / (double)k : 0.0;
  }

double SpreadPoints()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (ask - bid) / symPoint;
  }

double StopsLevelPrice(void)
  {
   double lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * symPoint;
   double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return MathMax(lvl, spr) + 2.0 * symPoint;
  }

//+------------------------------------------------------------------+
//| Higher timeframe regime bias                                     |
//+------------------------------------------------------------------+
int RegimeBias(double &strength)
  {
   strength = 0.0;
   if(InpRegimeMode == REGIME_OFF)
     {
      strength = 0.6;
      return 0;
     }
   if(ArraySize(vREma50) < 2 || ArraySize(vREma200) < 2) return 0;

   double e50  = vREma50[0];
   double e200 = vREma200[0];
   double rc   = iClose(_Symbol, InpRegimeTF, 0);
   if(rc <= 0.0 || e200 == 0.0) return 0;

   strength = Clip01(MathAbs(e50 - e200) / e200 / 0.02);   // 2% separation = full

   if(e50 > e200)
     {
      if(InpRegimeMode == REGIME_STRICT && rc <= e50) return 0;
      return 1;
     }
   if(e50 < e200)
     {
      if(InpRegimeMode == REGIME_STRICT && rc >= e50) return 0;
      return -1;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Reset a SetupInfo                                                |
//+------------------------------------------------------------------+
void ResetSetup(SetupInfo &s)
  {
   s.dir      = 0;
   s.score    = 0.0;
   s.sl       = 0.0;
   s.rDist    = 0.0;
   s.atr      = 0.0;
   s.adx      = 0.0;
   s.r2       = 0.0;
   s.er       = 0.0;
   s.slopeAtr = 0.0;
   s.reason   = "";
  }

//+------------------------------------------------------------------+
//| Is the trend still valid in the given direction?                 |
//+------------------------------------------------------------------+
bool TrendStillValid(const int dir)
  {
   const int i = 1;
   if(dir > 0)
     {
      if(vEmaFast[i]  <= vEmaMid[i])   return false;
      if(vAdxMain[i]  <  InpAdxExit)   return false;
      if(vAdxPlus[i]  <= vAdxMinus[i]) return false;
      if(cClose[i]    <= vEmaMid[i])   return false;
      return true;
     }
   if(dir < 0)
     {
      if(vEmaFast[i]  >= vEmaMid[i])   return false;
      if(vAdxMain[i]  <  InpAdxExit)   return false;
      if(vAdxMinus[i] <= vAdxPlus[i])  return false;
      if(cClose[i]    >= vEmaMid[i])   return false;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| CORE: evaluate a fresh entry setup on the last CLOSED bar        |
//+------------------------------------------------------------------+
bool EvaluateSetup(SetupInfo &s)
  {
   ResetSetup(s);
   const int i = 1;   // last closed bar

   double atr = vAtr[i];
   if(atr <= 0.0) { s.reason = "ATR<=0"; return false; }
   s.atr = atr;

   // ---------- 0. volatility regime ----------
   double atrAvg = AtrAverage(i, InpAtrAvgBars);
   if(atrAvg <= 0.0) { s.reason = "ATRavg<=0"; return false; }
   double atrRatio = atr / atrAvg;
   if(atrRatio < InpMinAtrRatio) { s.reason = StringFormat("dead vol (ATRr %.2f)", atrRatio);  return false; }
   if(atrRatio > InpMaxAtrRatio) { s.reason = StringFormat("chaos vol (ATRr %.2f)", atrRatio); return false; }

   // ---------- 1. higher timeframe regime ----------
   double regStrength = 0.0;
   int    bias        = RegimeBias(regStrength);

   // ---------- 2. H4 directional structure ----------
   bool longStack  = false;
   bool shortStack = false;
   if(InpRequireFullStack)
     {
      longStack  = (vEmaFast[i] > vEmaMid[i] && vEmaMid[i] > vEmaSlow[i]);
      shortStack = (vEmaFast[i] < vEmaMid[i] && vEmaMid[i] < vEmaSlow[i]);
     }
   else
     {
      longStack  = (vEmaFast[i] > vEmaMid[i] && cClose[i] > vEmaSlow[i]);
      shortStack = (vEmaFast[i] < vEmaMid[i] && cClose[i] < vEmaSlow[i]);
     }

   // ---------- 3. statistical trend quality ----------
   double slope = 0.0, r2 = 0.0;
   if(!LinReg(cClose, i, InpRegBars, slope, r2)) { s.reason = "linreg failed"; return false; }

   double er       = EfficiencyRatio(cClose, i, InpErPeriod);
   double slopeAtr = slope / atr;

   s.r2       = r2;
   s.er       = er;
   s.slopeAtr = slopeAtr;
   s.adx      = vAdxMain[i];

   if(r2 < InpMinR2)                      { s.reason = StringFormat("R2 %.2f < %.2f", r2, InpMinR2); return false; }
   if(er < InpMinER)                      { s.reason = StringFormat("ER %.2f < %.2f", er, InpMinER); return false; }
   if(MathAbs(slopeAtr) < InpMinSlopeATR)  { s.reason = StringFormat("slope %.3f ATR/bar too flat", slopeAtr); return false; }
   if(vAdxMain[i] < InpAdxMin)             { s.reason = StringFormat("ADX %.1f < %.1f", vAdxMain[i], InpAdxMin); return false; }

   // ---------- 4. breakout timing ----------
   double priorHigh = HighestHigh(i + 1, InpDonchian);
   double priorLow  = LowestLow (i + 1, InpDonchian);
   bool   breakUp   = (cClose[i] > priorHigh);
   bool   breakDown = (cClose[i] < priorLow);

   // ---------- 5. candle quality ----------
   double range = cHigh[i] - cLow[i];
   if(range <= 0.0) { s.reason = "zero range bar"; return false; }
   double bodyRatio = MathAbs(cClose[i] - cOpen[i]) / range;
   double closePos  = (cClose[i] - cLow[i]) / range;   // 1 = closed at the high

   // ---------- 6. direction, all hard gates ----------
   int dir = 0;
   if(longStack && breakUp && slopeAtr > 0.0 &&
      vAdxPlus[i] > vAdxMinus[i] && vRsi[i] > 50.0 &&
      vMacdMain[i] > vMacdSig[i] &&
      bodyRatio >= InpMinBodyRatio && closePos >= InpMinClosePos &&
      bias >= 0)
      dir = 1;
   else if(shortStack && breakDown && slopeAtr < 0.0 &&
           vAdxMinus[i] > vAdxPlus[i] && vRsi[i] < 50.0 &&
           vMacdMain[i] < vMacdSig[i] &&
           bodyRatio >= InpMinBodyRatio && (1.0 - closePos) >= InpMinClosePos &&
           bias <= 0)
      dir = -1;

   if(dir == 0) { s.reason = "no aligned breakout"; return false; }

   // ---------- 7. probability score 0..100 ----------
   double sHtf   = (InpRegimeMode == REGIME_OFF) ? 0.60
                   : ((bias == dir) ? (0.55 + 0.45 * regStrength) : 0.35);
   double sStack = Clip01(MathAbs(vEmaFast[i] - vEmaMid[i]) / (0.60 * atr));
   double sAdx   = Clip01((vAdxMain[i] - InpAdxMin) / MathMax(1.0, InpAdxRef - InpAdxMin));
   double sR2    = Clip01((r2 - InpMinR2) / MathMax(0.01, 0.90 - InpMinR2));
   double sEr    = Clip01((er - InpMinER) / MathMax(0.01, 0.75 - InpMinER));
   double sMacd  = Clip01(MathAbs(vMacdMain[i] - vMacdSig[i]) / (0.18 * atr));
   double sRsi   = (dir > 0) ? Clip01((vRsi[i] - 50.0) / 22.0)
                             : Clip01((50.0 - vRsi[i]) / 22.0);
   double brkDist = (dir > 0) ? (cClose[i] - priorHigh) : (priorLow - cClose[i]);
   double sBrk   = Clip01(brkDist / (0.45 * atr)) * 0.6 + Clip01(bodyRatio / 0.85) * 0.4;
   double sSlope = Clip01(MathAbs(slopeAtr) / 0.40);

   double score = 18.0 * sHtf
                + 12.0 * sStack
                + 15.0 * sAdx
                + 15.0 * sR2
                + 10.0 * sEr
                +  8.0 * sMacd
                +  4.0 * sRsi
                + 10.0 * sBrk
                +  8.0 * sSlope;
   s.score = score;

   if(score < InpMinScore)
     {
      s.reason = StringFormat("score %.1f < %.1f", score, InpMinScore);
      return false;
     }

   // ---------- 8. small stop loss ----------
   double entry = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buffer = InpSlBufferATR * atr;
   double sl     = 0.0;

   if(dir > 0)
     {
      double slStruct = LowestLow(i, InpStructLookback) - buffer;
      double slAtr    = entry - InpSlAtrMult * atr;
      sl = MathMax(slStruct, slAtr);                    // the tighter of the two
      double floorSl = entry - InpMinSlAtrMult * atr;   // but not razor thin
      if(sl > floorSl) sl = floorSl;
     }
   else
     {
      double slStruct = HighestHigh(i, InpStructLookback) + buffer;
      double slAtr    = entry + InpSlAtrMult * atr;
      sl = MathMin(slStruct, slAtr);
      double floorSl = entry + InpMinSlAtrMult * atr;
      if(sl < floorSl) sl = floorSl;
     }

   double rDist = MathAbs(entry - sl);
   if(rDist > InpMaxSlAtrMult * atr)
     {
      s.reason = StringFormat("SL too wide (%.2f ATR)", rDist / atr);
      return false;
     }

   double minDist = StopsLevelPrice();
   if(rDist < minDist)
     {
      sl    = (dir > 0) ? entry - minDist : entry + minDist;
      rDist = minDist;
     }

   s.dir    = dir;
   s.sl     = NormalizeDouble(sl, symDigits);
   s.rDist  = rDist;
   s.reason = StringFormat("OK score %.1f R=%.0fpts", score, rDist / symPoint);
   return true;
  }

//+------------------------------------------------------------------+
//| Basket snapshot                                                  |
//+------------------------------------------------------------------+
void RefreshBasket(void)
  {
   g_bDir = 0; g_bCount = 0; g_bVol = 0.0; g_bAvg = 0.0;
   g_bSL = 0.0; g_bFirstEntry = 0.0; g_bFirstTime = 0; g_bProfit = 0.0;
   g_bSlUniform = true;
   ArrayResize(g_bTickets, 0);

   double weighted = 0.0;
   double bestSL   = 0.0;
   double firstSL  = 0.0;
   bool   haveSL   = false;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long     ptype = PositionGetInteger(POSITION_TYPE);
      int      d     = (ptype == POSITION_TYPE_BUY) ? 1 : -1;
      double   vol   = PositionGetDouble(POSITION_VOLUME);
      double   open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double   psl   = PositionGetDouble(POSITION_SL);
      datetime pt    = (datetime)PositionGetInteger(POSITION_TIME);

      if(g_bDir == 0) g_bDir = d;
      else if(g_bDir != d) continue;   // ignore any opposite-side leftovers

      int n = ArraySize(g_bTickets);
      ArrayResize(g_bTickets, n + 1);
      g_bTickets[n] = ticket;

      g_bCount++;
      g_bVol    += vol;
      weighted  += vol * open;
      g_bProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(g_bFirstTime == 0 || pt < g_bFirstTime)
        {
         g_bFirstTime  = pt;
         g_bFirstEntry = open;
        }

      if(!haveSL)
        {
         bestSL  = psl;
         firstSL = psl;
         haveSL  = true;
        }
      else
        {
         if(MathAbs(psl - firstSL) > symPoint * 0.5) g_bSlUniform = false;
         if(g_bDir > 0) bestSL = MathMax(bestSL, psl);
         else           bestSL = MathMin(bestSL, psl);
        }
     }

   if(g_bVol > 0.0) g_bAvg = weighted / g_bVol;
   g_bSL = haveSL ? bestSL : 0.0;
   if(haveSL && firstSL <= 0.0) g_bSlUniform = false;   // some ticket has no SL at all
  }

//+------------------------------------------------------------------+
//| Lot helpers                                                      |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   if(symVolStep <= 0.0) return 0.0;
   lots = MathFloor(lots / symVolStep + 0.5) * symVolStep;
   if(lots < symVolMin) lots = symVolMin;
   if(lots > symVolMax) lots = symVolMax;
   return NormalizeDouble(lots, symVolDigits);
  }

double BaseLot(const double slDistance)
  {
   if(InpLotMode == LOT_FIXED)
      return NormalizeLots(InpBaseLot);

   if(slDistance <= 0.0 || symTickSize <= 0.0 || symTickValue <= 0.0)
      return NormalizeLots(InpBaseLot);

   double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double lossPerLot = (slDistance / symTickSize) * symTickValue;
   if(lossPerLot <= 0.0) return NormalizeLots(InpBaseLot);

   return NormalizeLots(riskMoney / lossPerLot);
  }

//+------------------------------------------------------------------+
//| Basket P/L at a hypothetical price, in (lots * price) units.      |
//| Positive = the basket would be in profit if stopped there.        |
//+------------------------------------------------------------------+
double BasketPLatPrice(const double p, const double addLot, const double addPrice)
  {
   if(g_bDir > 0)
      return g_bVol * (p - g_bAvg) + addLot * (p - addPrice);
   return g_bVol * (g_bAvg - p) + addLot * (addPrice - p);
  }

//+------------------------------------------------------------------+
//| THE single shared stop-loss.                                     |
//| Returns the SL we want on EVERY ticket, optionally assuming we    |
//| are about to add `addLot` at `addPrice`.                          |
//|                                                                   |
//| Built as the most protective of:                                  |
//|   0. the original structural stop                                 |
//|   1. first-entry breakeven once profit >= InpBeAtR                 |
//|   2. volume weighted basket breakeven once an add exists           |
//|   3. Chandelier trailing stop once profit >= InpTrailStartR        |
//| then clamped so it is never closer to price than the safety gap,   |
//| then ratcheted so it never becomes less protective than the SL     |
//| already sitting in the market.                                    |
//+------------------------------------------------------------------+
double ComputeSingleSL(const double addLot, const double addPrice, const double rDist)
  {
   int dir = g_bDir;
   if(dir == 0) return 0.0;

   double atr = vAtr[1];
   if(atr <= 0.0) return g_bSL;

   double newVol = g_bVol + addLot;
   double newAvg = (newVol > 0.0) ? (g_bVol * g_bAvg + addLot * addPrice) / newVol : g_bAvg;
   int    adds   = (g_bCount - 1) + (addLot > 0.0 ? 1 : 0);

   double b    = InpCostPts * symPoint + InpBeBufferATR * atr;
   double curR = ProfitInR(rDist);

   // 0. original structural stop
   double target = (dir > 0) ? g_bFirstEntry - rDist : g_bFirstEntry + rDist;

   // 1. first-entry breakeven
   if(InpBeAtR > 0.0 && curR >= InpBeAtR)
      target = MoreProtective(dir, target, (dir > 0) ? g_bFirstEntry + b : g_bFirstEntry - b);

   // 2. basket breakeven once we have pyramided
   if(InpLockBasketBE && adds > 0 && newAvg > 0.0)
      target = MoreProtective(dir, target, (dir > 0) ? newAvg + b : newAvg - b);

   // 3. Chandelier trail - this is what rides the trend
   if(curR >= InpTrailStartR || adds > 0)
     {
      double chMult = (adds > 0) ? InpChandelierMultAdd : InpChandelierMult;
      double ch = (dir > 0) ? HighestHigh(1, InpChandelierLen) - chMult * atr
                            : LowestLow (1, InpChandelierLen) + chMult * atr;
      target = MoreProtective(dir, target, ch);
     }

   // 4. safety gap: never pull the stop right under the current price
   double px  = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                          : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double gap = MathMax(InpMinStopGapATR * atr, StopsLevelPrice());
   if(dir > 0 && target > px - gap) target = px - gap;
   if(dir < 0 && target < px + gap) target = px + gap;

   // 5. ratchet: never widen risk
   if(g_bSL > 0.0)
      target = MoreProtective(dir, target, g_bSL);

   return NormalizeDouble(target, symDigits);
  }

//+------------------------------------------------------------------+
//| Apply ONE stop-loss price to every ticket of the basket          |
//+------------------------------------------------------------------+
bool SyncBasketSL(const double rawSL)
  {
   if(g_bCount <= 0) return false;

   double newSL = NormalizeDouble(rawSL, symDigits);

   // respect broker stops level against the live price
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = StopsLevelPrice();

   if(g_bDir > 0 && newSL > bid - minD) newSL = NormalizeDouble(bid - minD, symDigits);
   if(g_bDir < 0 && newSL < ask + minD) newSL = NormalizeDouble(ask + minD, symDigits);

   bool anyChange = false;
   for(int i = 0; i < ArraySize(g_bTickets); i++)
     {
      ulong ticket = g_bTickets[i];
      if(!PositionSelectByTicket(ticket)) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      if(MathAbs(curSL - newSL) < symPoint * 0.5) continue;

      // never widen risk on an individual ticket
      if(curSL > 0.0)
        {
         if(g_bDir > 0 && newSL < curSL) continue;
         if(g_bDir < 0 && newSL > curSL) continue;
        }

      if(!trade.PositionModify(ticket, newSL, curTP))
         PrintFormat("SyncBasketSL: modify #%I64u failed ret=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      else
         anyChange = true;
     }

   if(anyChange)
      PrintFormat("Shared SL -> %s  (%d tickets, %.2f lots)",
                  DoubleToString(newSL, symDigits), g_bCount, g_bVol);
   return anyChange;
  }

//+------------------------------------------------------------------+
//| Manage the shared SL every tick                                  |
//+------------------------------------------------------------------+
void ManageBasketSL(const double rDist, const bool force)
  {
   if(g_bDir == 0 || g_bCount <= 0) return;

   double target = ComputeSingleSL(0.0, 0.0, rDist);
   if(target <= 0.0) return;

   // if every ticket already shares this exact SL there is nothing to do
   if(!force && g_bSlUniform && g_bSL > 0.0 && MathAbs(target - g_bSL) < symPoint * 0.5)
      return;

   SyncBasketSL(target);
  }

//+------------------------------------------------------------------+
//| Open the first ticket of a new basket                            |
//+------------------------------------------------------------------+
bool OpenFirst(const SetupInfo &s)
  {
   double lots = BaseLot(s.rDist);
   if(lots <= 0.0) return false;

   string cmt = StringFormat("%s|E0|s%.0f", InpComment, s.score);

   bool ok = (s.dir > 0) ? trade.Buy (lots, _Symbol, 0.0, s.sl, 0.0, cmt)
                         : trade.Sell(lots, _Symbol, 0.0, s.sl, 0.0, cmt);
   if(!ok)
     {
      PrintFormat("OpenFirst FAILED ret=%d (%s) lots=%.2f sl=%s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  lots, DoubleToString(s.sl, symDigits));
      return false;
     }

   SetStoredR(s.rDist);
   g_lastAddBar = cTime[0];

   PrintFormat("=== NEW BASKET %s | %.2f lots | fill %s | SL %s | R %.0f pts | score %.1f | ADX %.1f R2 %.2f ER %.2f",
               (s.dir > 0 ? "BUY" : "SELL"), lots,
               DoubleToString(trade.ResultPrice(), symDigits),
               DoubleToString(s.sl, symDigits),
               s.rDist / symPoint, s.score, s.adx, s.r2, s.er);
   return true;
  }

//+------------------------------------------------------------------+
//| Open profit of the basket measured in R (R = first-entry risk)    |
//+------------------------------------------------------------------+
double ProfitInR(const double rDist)
  {
   if(g_bDir == 0 || rDist <= 0.0 || g_bFirstEntry <= 0.0) return 0.0;
   double px = (g_bDir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                            : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double move = (g_bDir > 0) ? (px - g_bFirstEntry) : (g_bFirstEntry - px);
   return move / rDist;
  }

//+------------------------------------------------------------------+
//| Largest add volume that keeps the shared SL risk-free AND at      |
//| least the safety gap away from price.                             |
//|                                                                   |
//| The shared SL after an add is  min(basketBE + b, P - gap).         |
//| The basket is risk-free exactly when SL >= basketBE, and since     |
//| basketBE + b > basketBE always, the binding constraint is          |
//|                                                                   |
//|     P - gap  >=  (V*A + x*P) / (V + x)                             |
//|   =>      x  <=  V * (P - A - gap) / gap                           |
//|                                                                   |
//| V = existing volume, A = weighted avg entry, P = price.            |
//| This is the exact boundary the sizing loop converges to, so it is  |
//| the honest number to report in the log and the panel.              |
//+------------------------------------------------------------------+
double MaxRiskFreeAddLot(const double price, const double atr)
  {
   if(g_bVol <= 0.0) return 0.0;

   double gap = MathMax(InpMinStopGapATR * atr, StopsLevelPrice());
   if(gap <= 0.0) return 0.0;

   double headroom = (g_bDir > 0) ? (price - g_bAvg - gap)
                                  : (g_bAvg - price - gap);
   if(headroom <= 0.0) return 0.0;

   return g_bVol * headroom / gap;
  }

//+------------------------------------------------------------------+
//| PYRAMIDING: add a bigger position while the trend holds           |
//+------------------------------------------------------------------+
void TryPyramid(const double rDist)
  {
   if(g_bDir == 0) return;

   int addsDone = g_bCount - 1;
   int maxAdds  = InpMaxAdds;
   if(ArraySize(g_addAtR) < maxAdds) maxAdds = ArraySize(g_addAtR);
   if(addsDone >= maxAdds) return;

   // pacing
   if(InpMinBarsBetweenAdds > 0 && g_lastAddBar > 0)
     {
      int barsSince = iBarShift(_Symbol, InpTF, g_lastAddBar, false);
      if(barsSince < InpMinBarsBetweenAdds) return;
     }

   double atr = vAtr[1];
   if(atr <= 0.0) return;

   double curR = ProfitInR(rDist);
   if(curR < g_addAtR[addsDone]) return;

   if(InpAddNeedsTrendOK && !TrendStillValid(g_bDir))
     {
      Vlog(StringFormat("Add #%d held: trend no longer clean", addsDone + 1));
      return;
     }

   if(InpAddNeedsNewHigh)
     {
      if(g_bDir > 0 && cClose[1] <= HighestHigh(2, InpDonchian)) return;
      if(g_bDir < 0 && cClose[1] >= LowestLow (2, InpDonchian)) return;
     }

   double price = (g_bDir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double baseL   = BaseLot(rDist);
   double desired = NormalizeLots(baseL * g_addMult[addsDone]);

   // ---- risk gate ----
   double allow  = InpBasketRiskAllowR * baseL * rDist;   // in (lots * price) units
   double lot    = desired;
   double planSL = 0.0;
   bool   found  = false;

   for(int guard = 0; guard < 500; guard++)
     {
      double testLot = NormalizeLots(lot);
      if(testLot < symVolMin - 1e-12) break;

      planSL = ComputeSingleSL(testLot, price, rDist);
      double net = BasketPLatPrice(planSL, testLot, price);

      if(net >= -allow - 1e-12)
        {
         lot   = testLot;
         found = true;
         break;
        }

      if(InpAddStrictLadder) break;                 // do not shrink, just wait
      if(testLot <= symVolMin + 1e-12) break;       // cannot go any smaller
      lot = testLot - symVolStep;
     }

   if(!found)
     {
      double maxLot = MaxRiskFreeAddLot(price, atr);
      Vlog(StringFormat("Add #%d held at %.2fR: want %.2f lots, risk-free ceiling is %.2f lots",
                        addsDone + 1, curR, desired, maxLot));
      return;
     }

   // margin sanity
   double needMargin = 0.0;
   ENUM_ORDER_TYPE ot = (g_bDir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(ot, _Symbol, lot, price, needMargin))
     {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(needMargin > freeMargin * 0.80)
        {
         PrintFormat("Add #%d skipped: needs %.2f margin, only %.2f free",
                     addsDone + 1, needMargin, freeMargin);
         return;
        }
     }

   // the add is opened directly with the shared SL
   double useSL = planSL;
   double minD  = StopsLevelPrice();
   if(g_bDir > 0 && useSL > price - minD) useSL = price - minD;
   if(g_bDir < 0 && useSL < price + minD) useSL = price + minD;
   useSL = NormalizeDouble(useSL, symDigits);

   string cmt = StringFormat("%s|A%d|%.1fR", InpComment, addsDone + 1, curR);

   bool ok = (g_bDir > 0) ? trade.Buy (lot, _Symbol, 0.0, useSL, 0.0, cmt)
                          : trade.Sell(lot, _Symbol, 0.0, useSL, 0.0, cmt);
   if(!ok)
     {
      PrintFormat("Add #%d FAILED ret=%d (%s) lots=%.2f sl=%s",
                  addsDone + 1, trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  lot, DoubleToString(useSL, symDigits));
      return;
     }

   g_lastAddBar = cTime[0];
   g_skipMsg    = "";

   PrintFormat(">>> PYRAMID ADD #%d | %.2f lots at %.2fR | fill %s | shared SL %s",
               addsDone + 1, lot, curR,
               DoubleToString(trade.ResultPrice(), symDigits),
               DoubleToString(useSL, symDigits));

   // re-read the basket, then force every ticket onto the one shared SL
   RefreshBasket();
   ManageBasketSL(rDist, true);

   PrintFormat("    basket now %d tickets, %.2f lots, avg %s, worst case at SL = %.5f (lots*price)",
               g_bCount, g_bVol, DoubleToString(g_bAvg, symDigits),
               BasketPLatPrice(g_bSL, 0.0, 0.0));
  }

//+------------------------------------------------------------------+
//| Close the whole basket                                           |
//+------------------------------------------------------------------+
void CloseBasket(const string why)
  {
   if(g_bCount <= 0) return;

   PrintFormat("### CLOSING BASKET | %d tickets | %.2f lots | P/L %.2f | reason: %s",
               g_bCount, g_bVol, g_bProfit, why);

   for(int i = ArraySize(g_bTickets) - 1; i >= 0; i--)
     {
      ulong ticket = g_bTickets[i];
      if(!PositionSelectByTicket(ticket)) continue;
      if(!trade.PositionClose(ticket, InpSlippagePts))
         PrintFormat("Close #%I64u failed ret=%d (%s)",
                     ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   ClearStoredR();
   g_lastCloseBar = cTime[0];
   g_lastAddBar   = 0;
   g_skipMsg      = "";
  }

//+------------------------------------------------------------------+
//| Trend flip detection - this is the dynamic take-profit           |
//+------------------------------------------------------------------+
bool TrendFlipped(const double rDist)
  {
   if(g_bDir == 0) return false;

   if(InpMinProfitRtoFlip > 0.0 && ProfitInR(rDist) < InpMinProfitRtoFlip) return false;

   const int i = 1;

   if(InpExitOnEmaFlip)
     {
      bool emaFlip = (g_bDir > 0) ? (vEmaFast[i] < vEmaMid[i]) : (vEmaFast[i] > vEmaMid[i]);
      bool macdFlip = true;
      if(InpExitNeedsMacd)
         macdFlip = (g_bDir > 0) ? (vMacdMain[i] < vMacdSig[i]) : (vMacdMain[i] > vMacdSig[i]);
      if(emaFlip && macdFlip) return true;
     }

   if(InpExitOnAdxCollapse)
     {
      double slope = 0.0, r2 = 0.0;
      if(LinReg(cClose, i, InpRegBars, slope, r2))
         if(vAdxMain[i] < InpAdxExit && r2 < InpR2Exit) return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Entry guards                                                     |
//+------------------------------------------------------------------+
bool EntryAllowedNow(string &why)
  {
   why = "";

   double spr = SpreadPoints();
   if(spr > InpMaxSpreadPts)
     {
      why = StringFormat("spread %.0f > %.0f pts", spr, InpMaxSpreadPts);
      return false;
     }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpFridayNoNewEntry && dt.day_of_week == 5) { why = "Friday - no new baskets"; return false; }
   if(dt.hour < InpStartHour || dt.hour > InpEndHour) { why = "outside entry hours"; return false; }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity) g_peakEquity = eq;
   if(g_peakEquity > 0.0)
     {
      double dd = (g_peakEquity - eq) / g_peakEquity * 100.0;
      if(dd > InpMaxEquityDDpct)
        {
         why = StringFormat("equity DD %.1f%% > %.1f%%", dd, InpMaxEquityDDpct);
         return false;
        }
     }

   if(InpCooldownBars > 0 && g_lastCloseBar > 0)
     {
      int since = iBarShift(_Symbol, InpTF, g_lastCloseBar, false);
      if(since < InpCooldownBars)
        {
         why = StringFormat("cooldown %d/%d bars", since, InpCooldownBars);
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Chart panel                                                      |
//+------------------------------------------------------------------+
void DrawPanel(const SetupInfo &s, const double rDist)
  {
   if(!InpShowPanel) return;

   string dirTxt = (g_bDir == 0) ? "FLAT" : (g_bDir > 0 ? "LONG" : "SHORT");
   double curR   = ProfitInR(rDist);
   int    adds   = (g_bCount > 0) ? g_bCount - 1 : 0;
   int    maxAdds = InpMaxAdds;
   if(ArraySize(g_addAtR) < maxAdds) maxAdds = ArraySize(g_addAtR);

   string nextAdd = "-";
   if(g_bDir != 0 && adds < maxAdds)
     {
      double atr   = vAtr[1];
      double price = (g_bDir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ceil  = NormalizeLots(MaxRiskFreeAddLot(price, atr));
      double want  = NormalizeLots(BaseLot(rDist) * g_addMult[adds]);
      nextAdd = StringFormat("%.2f lots at >=%.1fR (risk-free ceiling now %.2f)",
                             want, g_addAtR[adds], ceil);
     }

   string slTxt = (g_bSL > 0.0) ? DoubleToString(g_bSL, symDigits) : "-";
   string riskTxt = "-";
   if(g_bDir != 0 && g_bSL > 0.0)
     {
      double net = BasketPLatPrice(g_bSL, 0.0, 0.0);
      riskTxt = StringFormat("%s (%.5f lots*price)",
                             (net >= 0.0 ? "RISK-FREE" : "at risk"), net);
     }

   string txt = StringFormat(
      "KRISHH SWING ROBOT v1.10   %s %s\n"
      "--------------------------------------------------\n"
      "Basket     : %s   tickets %d   volume %.2f\n"
      "Avg entry  : %s\n"
      "SHARED SL  : %s   uniform: %s\n"
      "At SL      : %s\n"
      "Open       : %.2f R    P/L %.2f\n"
      "Next add   : %s\n"
      "--------------------------------------------------\n"
      "ADX %.1f | R2 %.2f | ER %.2f | slope %.3f ATR/bar\n"
      "Score      : %.1f  (need %.1f)\n"
      "Status     : %s\n"
      "Spread     : %.0f pts",
      _Symbol, EnumToString(InpTF),
      dirTxt, g_bCount, g_bVol,
      (g_bAvg > 0.0 ? DoubleToString(g_bAvg, symDigits) : "-"),
      slTxt, (g_bSlUniform ? "yes" : "NO - syncing"),
      riskTxt,
      curR, g_bProfit,
      nextAdd,
      s.adx, s.r2, s.er, s.slopeAtr,
      s.score, InpMinScore,
      (s.reason == "" ? "waiting" : s.reason),
      SpreadPoints());

   Comment(txt);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!RefreshData()) return;

   bool newBar = (cTime[0] != g_lastBarTime);

   RefreshBasket();

   // ---- R (initial risk distance) with persistence across restarts ----
   double rDist = GetStoredR();
   if(g_bDir != 0 && rDist <= 0.0)
     {
      rDist = InpSlAtrMult * vAtr[1];
      if(g_bSL > 0.0 && g_bFirstEntry > 0.0)
        {
         double d = MathAbs(g_bFirstEntry - g_bSL);
         if(d > 0.0) rDist = d;
        }
      SetStoredR(rDist);
      PrintFormat("Recovered R for open basket: %.0f points", rDist / symPoint);
     }
   if(g_bDir == 0 && rDist > 0.0)
      ClearStoredR();

   // ---- manage an open basket ----
   if(g_bDir != 0)
     {
      ManageBasketSL(rDist, false);

      if(newBar && TrendFlipped(rDist))
        {
         CloseBasket("trend flipped");
         g_lastBarTime = cTime[0];
         RefreshBasket();
         return;
        }

      if(newBar)
         TryPyramid(rDist);
     }

   // ---- look for a new basket, only on a closed bar ----
   SetupInfo s;
   ResetSetup(s);

   if(newBar)
     {
      EvaluateSetup(s);

      if(g_bDir != 0)
         s.reason = StringFormat("in position (%d tickets)", g_bCount);
      else if(s.dir != 0)
        {
         string why = "";
         if(EntryAllowedNow(why))
            OpenFirst(s);
         else
           {
            s.reason = "blocked: " + why;
            Vlog("Setup found but " + why);
           }
        }

      g_lastBarTime = cTime[0];
      RefreshBasket();
     }
   else
     {
      // cheap read-only diagnostics for the panel between bars
      double slope = 0.0, r2 = 0.0;
      LinReg(cClose, 1, InpRegBars, slope, r2);
      s.atr      = vAtr[1];
      s.adx      = vAdxMain[1];
      s.r2       = r2;
      s.er       = EfficiencyRatio(cClose, 1, InpErPeriod);
      s.slopeAtr = (s.atr > 0.0) ? slope / s.atr : 0.0;
      s.reason   = (g_bDir != 0) ? StringFormat("in position (%d tickets)", g_bCount)
                                 : "waiting for bar close";
     }

   DrawPanel(s, rDist);
  }
//+------------------------------------------------------------------+
