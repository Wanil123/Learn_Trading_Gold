//+------------------------------------------------------------------+
//|                      Market_Sniper_v8.2.mq5                      |
//|               Smart Regime Scanner v8.2                           |
//|      21 Weighted Confluences | D1 Macro Trend | Regime Detection |
//|      ADX | News Cache | Correlation | Volume | BB Squeeze        |
//|      Momentum ROC | Fibonacci | Swing Failure Pattern (SFP)      |
//|      Anti-Fakeout | TF Alignment | Dynamic Score | Trail SL      |
//|      Advanced Regime Switching | Tick Delta Pressure              |
//+------------------------------------------------------------------+
// HONEST DISCLAIMER:
// This is a DETECTION tool, NOT a holy grail.
// False signals WILL occur. Losing streaks WILL happen.
// No amount of confluence eliminates risk entirely.
// Always verify signals manually before trading.
// Forward test 2-3 weeks minimum before trusting any signal.
// DOM/MarketBookGet NOT implemented — useless on retail Forex brokers.
//+------------------------------------------------------------------+
#property copyright "Market Sniper v8.2 — Regime"
#property version   "8.20"
#property description "21 weighted confluences | D1+H4 macro trend | 4-regime detection"
#property description "BOS | OB | FVG | LiqSweep | S/D | SR Break | Divergences"
#property description "Tick Delta | News Cache | Regime: Trend/Range/Volatile/Quiet"

//+------------------------------------------------------------------+
//| ENUMS                                                             |
//+------------------------------------------------------------------+
enum ENUM_SIGNAL_DIR  { DIR_NONE=0, DIR_BUY=1, DIR_SELL=-1 };
enum ENUM_MARKET_REGIME { REGIME_TRENDING=1, REGIME_RANGING=2, REGIME_VOLATILE=3, REGIME_QUIET=4 };

enum ENUM_SETUP_TYPE
{
   SETUP_NONE         = 0,
   SETUP_BOS          = 1,
   SETUP_SR_BREAKOUT  = 2,
   SETUP_ORDER_BLOCK  = 3,
   SETUP_FVG          = 4,
   SETUP_LIQ_SWEEP    = 5,
   SETUP_SD_ZONE      = 6,
   SETUP_RSI_DIV      = 7,
   SETUP_MACD_DIV     = 8,
   SETUP_CANDLE       = 9,
   SETUP_EMA_CROSS    = 10,
   SETUP_MULTI        = 11,
   SETUP_SFP          = 12   // [FUSION] Swing Failure Pattern as primary setup
};

enum ENUM_SETUP_GRADE { GRADE_NONE=0, GRADE_B=1, GRADE_A=2, GRADE_A_PLUS=3 };

//+------------------------------------------------------------------+
//| STRUCTS                                                           |
//+------------------------------------------------------------------+
struct HandleSet
{
   int hEMA21;
   int hEMA50;
   int hEMA200;
   int hRSI;
   int hATR;
   int hMACD;
   int hADX;
   int hBB;      // Bollinger Bands (v6)
};

struct SymbolData
{
   string    name;
   string    baseName;
   bool      active;
   int       digits;
   double    point;
   double    pipSize;
   HandleSet hD1;           // D1 — macro trend (EMA21/50/200 + ATR)
   HandleSet hTrend;        // H4 — intermediate trend
   HandleSet hSignal;       // H1 — signal detection (full set)
   HandleSet hEntry;        // M15 — entry confirmation
   datetime  lastAlertTime;
   datetime  lastScanBar;
   string    lastAlertHash;
   string    lastDir;
   string    lastType;
   datetime  lastTime;
   int       lastScore;
   // [v8] Regime state (persistent per-symbol, with hysteresis)
   ENUM_MARKET_REGIME currentRegime;
   int                regimeBarsHeld;
};

struct SwingPoint
{
   double price;
   int    barIndex;
   bool   isHigh;
};

struct SRLevel
{
   double price;
   int    strength;
   string source;
   int    touches;    // [PhD] how many times price approached this level
   int    respects;   // [PhD] how many times price bounced (vs broke through)
};

struct SignalResult
{
   string            symbol;
   ENUM_SIGNAL_DIR   direction;
   ENUM_SETUP_TYPE   setupType;
   ENUM_SETUP_GRADE  grade;
   int               score;
   double            entry;
   double            sl;
   double            tp1;
   double            tp2;
   double            tp3;
   double            slPips;
   double            tp1Pips;
   double            tp2Pips;
   double            tp3Pips;
   string            confluences;
   ENUM_TIMEFRAMES   timeframe;
   datetime          signalTime;
   int               trendD1;
   int               trendH4;
   int               trendH1;
   double            adxValue;
   ENUM_MARKET_REGIME regime;     // [FUSION] Market regime
   double            atrZScore;   // [FUSION] ATR Z-Score
   double            rocValue;    // [FUSION] Momentum ROC
   double            hurstExp;    // [PhD] Hurst Exponent
   double            atrPctile;   // [PhD] ATR Percentile Rank
   double            tickDelta;   // [v8] Tick delta pressure (-1.0 to +1.0)
};

struct TrackedSignal
{
   string            symbol;
   ENUM_SIGNAL_DIR   direction;
   ENUM_SETUP_TYPE   setupType;
   ENUM_SETUP_GRADE  grade;
   int               score;
   double            entry;        // signal price (bar[1].close)
   double            liveEntry;    // [FIX] actual bid/ask at signal time (realistic entry)
   double            sl;
   double            tp1;
   double            tp2;
   double            tp3;
   double            slPips;
   double            tp1Pips;
   double            tp2Pips;
   double            tp3Pips;
   datetime          signalTime;
   bool              tp1Hit;
   bool              tp2Hit;
   bool              tp3Hit;
   bool              slHit;
   bool              closed;
   double            maxFavorable;
   double            maxAdverse;
   datetime          closeTime;
   string            closeReason;
   double            pipSize;
   int               digits;
   // Trailing virtual SL
   double            virtualSL;
   bool              movedToBE;
   bool              movedToTP1;
};

struct TrackingStats
{
   int    totalSignals;
   int    tp1Wins;
   int    tp2Wins;
   int    tp3Wins;
   int    slLosses;
   int    breakevens;
   int    expired;
   double pipsWon;
   double pipsLost;
   double bestPips;
   double worstPips;
   // [PhD] Per-setup tracking
   int    setupWins[13];   // wins per ENUM_SETUP_TYPE (0-12)
   int    setupTotal[13];  // total signals per setup
   double setupPips[13];   // net pips per setup
   // sumWinSq/sumLossSq removed in v8.2 (were written but never read)
};

// [PhD] Bayesian reliability per setup type (Beta-Binomial model)
struct SetupBayes
{
   double alpha;  // success prior (starts at 2.0 = weakly informative)
   double beta;   // failure prior
   int    n;      // total observations
};

// Correlation tracking
struct FamilyTracker
{
   string family;
   int    signalsToday;
   datetime lastSignal;
   string lastDir;
};

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+
input group "=== TELEGRAM ==="
input bool     InpUseTelegram    = true;
input string   InpBotToken       = "7458102241:AAGt_JC0ly8kwcIDnDTJp9akiaXdJT2rsBU";
input string   InpChatID         = "843004056";

input group "=== SYMBOLS (VT Markets default) ==="
input string   InpCustomSymbols  = "EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,NZDUSD,USDCAD,EURGBP,EURJPY,GBPJPY,AUDNZD,EURAUD,EURCHF,GBPAUD,GBPNZD,XAUUSD,XAGUSD,NAS100,US30,GER40";
input bool     InpAutoDetect     = false;
input bool     InpScanForex      = true;
input bool     InpScanMetals     = true;
input bool     InpScanIndices    = true;

input group "=== TIMEFRAMES ==="
input ENUM_TIMEFRAMES InpTF_Trend  = PERIOD_H4;    // Trend TF (intermediate)
input ENUM_TIMEFRAMES InpTF_Signal = PERIOD_H1;    // Signal TF (detection)
input ENUM_TIMEFRAMES InpTF_Entry  = PERIOD_M15;   // Entry TF (confirmation)
// D1 is always used for macro trend (hardcoded)

input group "=== STRATEGIES (toggle on/off) ==="
input bool     InpStr_BOS         = true;    // Break of Structure
input bool     InpStr_SRBreakout  = true;    // S/R Breakout
input bool     InpStr_OrderBlock  = true;    // Order Block (SMC)
input bool     InpStr_FVG         = true;    // Fair Value Gap (ICT)
input bool     InpStr_LiqSweep    = true;    // Liquidity Sweep
input bool     InpStr_SupplyDemand= true;    // Supply/Demand Zones
input bool     InpStr_RSIDiverg   = true;    // RSI Divergence
input bool     InpStr_MACDDiverg  = true;    // MACD Divergence
input bool     InpStr_CandlePat   = true;    // Candle Patterns
input bool     InpStr_EMACross    = true;    // EMA Cross

input group "=== INDICATORS ==="
input int      InpEMA_Fast    = 21;
input int      InpEMA_Slow    = 50;
input int      InpEMA_Trend   = 200;
input int      InpRSI_Period  = 14;
input int      InpATR_Period  = 14;
input int      InpADX_Period  = 14;        // ADX period
input int      InpADX_Min     = 20;        // ADX min (< = marche en range, bloque)

input group "=== QUALITY FILTER ==="
input int      InpMinScore       = 8;       // Score minimum (sur 29)
input bool     InpSendGradeB     = false;   // Envoyer Grade B (3-5)
input bool     InpSendGradeA     = true;    // Envoyer Grade A (6-8)
input bool     InpSendGradeAPlus = true;    // Envoyer Grade A+ (9+)
input double   InpMinRR          = 1.8;     // R:R minimum [FUSION: 1.5->1.8]

input group "=== RISK MANAGEMENT ==="
input double   InpSL_ATR_Multi = 1.5;       // SL = ATR x ceci
input double   InpMinSL_Pips   = 15.0;      // SL minimum (pips forex)
input double   InpTP1_RR       = 2.0;       // TP1 R:R
input double   InpTP2_RR       = 3.0;       // TP2 R:R
input double   InpTP3_RR       = 5.0;       // TP3 R:R
input double   InpAccountBalance = 10000.0;  // Capital du compte (USD)
input double   InpRiskPercent    = 1.0;       // Risque par trade (%)
input bool     InpShowLotSize    = true;      // Afficher taille de lot dans l'alerte

input group "=== SCANNING ==="
input int      InpScanInterval   = 30;      // Intervalle scan (secondes)
input int      InpSwingLookback  = 5;       // Swing detection lookback
input int      InpStructureBars  = 50;      // Barres pour structure
input int      InpSD_Lookback    = 100;     // S/D zone lookback
input double   InpSD_MinMoveATR  = 2.0;     // S/D move min (x ATR)
input int      InpDivergBars     = 30;      // Barres pour divergence

input group "=== ANTI-SPAM ==="
input int      InpCooldownMin    = 240;     // Cooldown meme direction (minutes)
input int      InpCooldownFlip   = 60;      // Cooldown direction opposee (minutes)
input int      InpMaxAlertsDay   = 20;      // Max alertes par jour [FUSION: 25->20, qualite > quantite]

input group "=== NEWS FILTER ==="
input bool     InpNewsFilter     = true;    // Block signals during High-Impact news
input int      InpNewsBlockMins  = 30;      // Minutes before/after event

input group "=== SPREAD FILTER ==="
input bool     InpSpreadFilter    = true;      // Block signals if spread too wide
input double   InpMaxSpreadPips   = 5.0;       // Max spread (pips) - forex
input double   InpMaxSpreadGold   = 50.0;      // Max spread (pips) - XAUUSD

input group "=== CORRELATION FILTER ==="
input bool     InpCorrelFilter    = true;   // Filter correlated signals
input int      InpMaxPerFamily    = 2;      // Max signals per currency family/day

input group "=== VOLUME FILTER ==="
input bool     InpUseVolume       = true;   // Volume spike confirmation
input double   InpVolSpikeMult    = 1.5;    // Spike threshold (x 20-bar average)

input group "=== SMART FILTERS v8.2 ==="
input bool     InpRequireH4Align  = true;   // [FUSION] H4 OBLIGATOIRE dans direction (HARD BLOCK)
input bool     InpTFAlignFilter   = true;   // Require TF coherence >= InpTFCoherenceMin%
input double   InpTFCoherenceMin  = 75.0;   // TF coherence minimum (D1=40% H4=35% H1=25%)
input bool     InpBreakoutConfirm = true;   // Confirm breakouts (body ratio)
input double   InpMinBodyRatio    = 0.50;   // Min body/range ratio [FUSION: 0.40->0.50]
input bool     InpSFPFilter       = true;   // Swing Failure Pattern detection
input bool     InpDynScore        = true;   // Dynamic minimum score
input int      InpConsecLossMax   = 3;      // Consecutive losses before boost
input bool     InpCircuitBreaker  = true;      // Stop scanning after max daily losses
input int      InpMaxDailyLosses  = 5;         // Max SL hits per day before shutdown
input double   InpMaxDailyLossPips = 200.0;    // Max cumulative loss pips/day
input int      InpMinScoreAsia    = 9;      // [FUSION] Min score Asia session (0-7 GMT)
input int      InpMinScoreFriday  = 10;     // [FUSION] Min score Friday PM (>=14h)
input int      InpMinScoreCounter = 9;      // [FUSION] Min score counter-trend
input int      InpMinScoreAfterLoss = 9;    // [FUSION] Min score after consec losses
input int      InpCounterPenalty   = 3;     // Counter-trend penalty (score deducted)

input group "=== MOMENTUM / VOLATILITY ==="
input bool     InpUseROC          = true;   // Momentum Rate of Change
input int      InpROC_Period      = 10;     // ROC lookback bars
input double   InpROC_Min         = 0.05;   // ROC minimum (%)
input bool     InpUseBBSqueeze    = true;   // Bollinger Band Squeeze detection
input int      InpBB_Period       = 20;     // BB period
input double   InpBB_Dev          = 2.0;    // BB deviation
input bool     InpUseFibo         = true;   // Fibonacci confluence
input bool     InpUseZScore       = true;   // ATR Z-Score volatility filter
input double   InpZScore_Min      = 0.30;   // [FUSION] Z-Score min (<= dead market)
input double   InpZScore_Max      = 2.50;   // Z-Score max (>= blocks signal)
input double   InpMTS_Min         = 40.0;   // MTS minimum (0-100 composite tradability)
input double   InpOB_MinMoveATR   = 1.5;    // OB impulse move minimum (x ATR)
input double   InpRSI_DivBull     = 40.0;   // RSI divergence bull zone (RSI <)
input double   InpRSI_DivBear     = 60.0;   // RSI divergence bear zone (RSI >)
input double   InpRSI_EntryBullLo = 25.0;   // RSI entry confirm bull low bound
input double   InpRSI_EntryBullHi = 45.0;   // RSI entry confirm bull high bound
input double   InpRSI_EntryBearLo = 55.0;   // RSI entry confirm bear low bound
input double   InpRSI_EntryBearHi = 75.0;   // RSI entry confirm bear high bound
input double   InpBayesMinConf    = 0.40;   // Bayesian min posterior for full weight

input group "=== SESSION FILTER ==="
input bool     InpSessionFilter  = true;    // Bloquer sessions low-liquidity
input int      InpSessBlockStart = 21;      // Debut blocage (heure UTC, dimanche)
input int      InpSessBlockEnd   = 3;       // Fin blocage (heure UTC, lundi)

input group "=== REGIME DETECTION v8 ==="
input bool     InpUseRegime       = true;    // Advanced 4-regime detection (Trend/Range/Volatile/Quiet)
input double   InpRegimeADXTrend  = 25.0;    // ADX entry for TRENDING (exit at ADX-5)
input double   InpRegimeHurstMin  = 0.50;    // Hurst min for TRENDING (exit at Hurst-0.06) [FIX: was 0.58, too strict]
input double   InpRegimeBBWHigh   = 1.5;     // BBW ratio for VOLATILE entry (exit at 1.2)
input double   InpRegimeBBWLow    = 0.7;     // BBW ratio for QUIET entry (exit at 0.85)
input int      InpRegimeMinBars   = 5;       // Min bars before allowing regime switch

input group "=== TICK DELTA v8 ==="
input bool     InpUseTickDelta    = true;    // Tick pressure analysis (bid/ask movement)
input int      InpTickDeltaTicks  = 300;     // Number of recent ticks to analyze
input double   InpTickDeltaMin    = 0.15;    // Min abs delta for confluence (0.0-1.0)

input group "=== NOTIFICATION TOGGLES ==="
input bool     InpNotifyTP1     = true;
input bool     InpNotifyTP2     = true;
input bool     InpNotifyTP3     = true;
input bool     InpNotifySL      = true;
input bool     InpNotifyBE      = true;     // Notifier Breakeven
input group "=== SIGNAL TRACKING ==="
input bool     InpTrackSignals   = true;
input int      InpMaxTracked     = 100;
input int      InpTrackMaxHours  = 72;
input bool     InpDailyReport    = true;
input int      InpReportHour     = 22;

//+------------------------------------------------------------------+
//| CONFLUENCE WEIGHTS (21 scored factors, max 26 base + 3 bonus)     |
//+------------------------------------------------------------------+
#define W_MACRO_TREND    2   // 1. D1+H4 trend aligned (half-credit if H4 only)
#define W_EMA_ALIGN      1   // 2. EMA alignment signal TF
#define W_EMA_CROSS      1   // 3. EMA fast/slow cross
#define W_BOS            2   // 4. Break of Structure
#define W_SR_BREAKOUT    2   // 5. S/R Level Breakout (strong directional)
#define W_SD_ZONE        1   // 6. At Supply/Demand Zone
#define W_ORDER_BLOCK    1   // 7. At Order Block
#define W_FVG            1   // 8. Fair Value Gap
#define W_LIQ_SWEEP      1   // 9. Liquidity Sweep
#define W_RSI_DIV        2   // 10. RSI Divergence
#define W_MACD_DIV       1   // 11. MACD Divergence
#define W_CANDLE         1   // 12. Candlestick Pattern
#define W_SR_LEVEL       1   // 13. Near S/R Level
#define W_ENTRY_CONFIRM  1   // 14. Entry TF Confirmation
#define W_VOLUME         1   // 15. Volume + Accumulation Context
// W_SESSION removed in v8.2 — session modifies dynMinScore threshold, not score directly
#define W_ROC            1   // 16. Momentum Rate of Change
#define W_BB_SQUEEZE     1   // 17. Bollinger Band Squeeze Breakout
#define W_FIBO           1   // 18. Fibonacci Confluence
#define W_SFP            2   // 19. Swing Failure Pattern (anti-fakeout)
#define W_REGIME         1   // 20. [v8] Regime-Strategy fit (+1 if strategy matches regime)
#define W_TICK_DELTA     1   // 21. [v8] Tick delta confirms signal direction
// SCORING MAX: 21 weights = 26 base. Post-decision: Hurst +2, Bayes +1 = 29 theoretical.
// Practically ~18-20. Display as /29 (theoretical max with Hurst+Bayes bonuses).

//+------------------------------------------------------------------+
//| GLOBALS                                                           |
//+------------------------------------------------------------------+
#define MAX_SYMBOLS 50
#define MAX_SR      30

SymbolData    g_sym[];
int           g_symCount    = 0;
int           g_alertsToday = 0;
datetime      g_dayStart    = 0;
int           g_totalScans  = 0;
int           g_totalAlerts = 0;
bool          g_initialized = false;

TrackedSignal g_tracked[];
int           g_trackedCount = 0;
TrackingStats g_stats;
bool          g_dailyReportSent = false;

// Correlation filter
FamilyTracker g_families[];
int           g_familyCount = 0;

// v6 Smart Filters
int           g_consecLosses = 0;       // consecutive losses counter (resets on TP hit)
int           g_signalsBlockedToday = 0; // [FUSION] signals blocked by v6 filters

// [v9] Circuit breaker
int    g_dailySLHits = 0;
double g_dailyLossPips = 0.0;
bool   g_circuitBroken = false;

// [PhD] Bayesian system
SetupBayes    g_bayesSetup[13]; // one per ENUM_SETUP_TYPE

// [v8] News cache — reload every 30 min instead of calling Calendar API every scan
struct CachedNewsEvent
{
   datetime  eventTime;
   string    currency;
   string    eventName;
};
CachedNewsEvent g_newsCache[];
int             g_newsCacheCount = 0;
datetime        g_newsNextReload = 0;

// [Phase1] CSV Signal Logger — tracks every signal for forward-test analysis
int             g_csvSignalCount = 0;   // total signals logged to CSV this session
string          g_csvFileName    = "";  // CSV filename (set in OnInit)

//+------------------------------------------------------------------+
//| FORWARD DECLARATIONS                                              |
//+------------------------------------------------------------------+
bool   BuildSymbolList();
string ResolveSymbol(string base);
bool   SymCheck(string sym);
void   InitSymbolData(int idx, string sym, string base);
bool   InitIndicators();
void   ReleaseHandle(int &h);
void   ReleaseAllHandles();
bool   LoadBuf(int handle, int count, double &buf[]);
bool   LoadBufN(int handle, int bufIdx, int count, double &buf[]);
void   ScanSymbol(int idx);
int    GetTrend(double &ema21[], double &ema50[], double &ema200[]);
int    AnalyzeStructure(MqlRates &rates[], int lookback);
void   FindSwingPoints(MqlRates &rates[], int lookback, int maxBars, SwingPoint &swings[]);
int    DetectBOS(MqlRates &rates[], SwingPoint &swings[]);
int    CalcSRLevels(MqlRates &d1[], MqlRates &tRates[], MqlRates &sRates[],
                    double sigATR, double d1ATR, double curPrice, SRLevel &levels[]);
void   AddSR(SRLevel &levels[], int &count, double atr, double price, int strength, string source);
void   CalcSRSignificance(SRLevel &levels[], int count, MqlRates &rates[], double atr);
int    DetectSRBreakout(MqlRates &rates[], SRLevel &sr[], int srCount, double atr);
int    CheckSDZone(MqlRates &rates[], double atr, double curPrice);
int    DetectOrderBlock(MqlRates &rates[], double atr, double &zoneLo, double &zoneHi);
int    DetectFVG(MqlRates &rates[], double atr, double &gapLo, double &gapHi);
int    DetectLiqSweep(MqlRates &rates[], double atr);
bool   DetectDivergence(MqlRates &rates[], double &osc[], bool bullish, int lookback);
int    DetectCandlePattern(MqlRates &rates[]);
double FindLastSwingLow(MqlRates &rates[], int lookback);
double FindLastSwingHigh(MqlRates &rates[], int lookback);
double GetMinSLPips(int idx);
void   CalcSLTP(int idx, SignalResult &sig, double sigATR, double entATR,
                MqlRates &eRates[], double structSL, SRLevel &srLevels[], int srCount);
bool   IsDuplicate(int idx, SignalResult &sig);
void   RecordAlert(int idx, SignalResult &sig);
void   SendAlert(int idx, SignalResult &sig);
void   WriteSignalToCSV(int idx, SignalResult &sig);
bool   SendTelegram(string text);
void   AddToTracker(int idx, SignalResult &sig);
void   CheckTrackedSignals();
void   SendTPNotif(int tIdx, int level);
void   SendSLNotif(int tIdx);
string BuildRunningStats();
void   SendDailyReport();
void   CleanupTracker();
int    ActiveCount();
void   UpdateDashboard();
string SetupName(ENUM_SETUP_TYPE t);
string GradeLabel(ENUM_SETUP_GRADE g);
string GradeEmoji(ENUM_SETUP_GRADE g);
string TFStr(ENUM_TIMEFRAMES tf);
ENUM_SETUP_GRADE ScoreToGrade(int score);
bool   ShouldSend(ENUM_SETUP_GRADE g);
void   SetTrigger(ENUM_SETUP_TYPE &trigger, int &trigWeight, ENUM_SETUP_TYPE newType, int newWeight);
int    TriggerPriority(ENUM_SETUP_TYPE t);
string FormatElapsed(datetime startTime);
double CalcPipSize(string sym);
string ExtractBaseName(string sym);
bool   IsForexPair(string base);
bool   IsMetalSym(string base);
bool   IsIndexSym(string base);
bool   IsSymbolTradeable(string sym);
string GetCurrencyFamily(string baseName);
void   RecordFamilySignal(string baseName, ENUM_SIGNAL_DIR dir);
bool   IsNewsBlocked(string baseName);
bool   IsCorrelBlocked(string baseName, ENUM_SIGNAL_DIR dir);
// v6 Smart Functions
bool   IsBreakoutConfirmed(MqlRates &rates[], int direction);
int    DetectSFP(MqlRates &rates[], SwingPoint &swings[], double atr);
int    CheckFiboLevel(double curPrice, SwingPoint &swings[], double atr);
int    GetDynamicMinScore(int baseMin, bool isCounterTrend, int sessHour, int dow);
// [FUSION] Market Regime
ENUM_MARKET_REGIME GetMarketRegime(double adxVal, double zScore);
string RegimeName(ENUM_MARKET_REGIME r);
string RegimeEmoji(ENUM_MARKET_REGIME r);
// [v8] Advanced Regime + Tick Delta + News Cache
ENUM_MARKET_REGIME DetectRegimeAdvanced(int idx, double adxVal, double hurstVal,
                                        double bbwRatio, double atrRatio);
double GetTickDelta(string symbol, int dir);
void   LoadNewsCache();
// [PhD] Advanced mathematical functions
double CalcHurstExponent(MqlRates &rates[], int window); // [v8.2] now AR(1) autocorrelation
double CalcATRPercentileRank(double &atrBuf[], int period);
double CalcLinRegSlope(double &data[], int start, int len);
double CalcTFCoherence(int trendD1, int trendH4, int trendH1, int signalDir);
void   BayesUpdate(ENUM_SETUP_TYPE setup, bool success);
double BayesPosterior(ENUM_SETUP_TYPE setup);
int    BayesAdjustWeight(ENUM_SETUP_TYPE setup, int baseWeight);
double CalcSortino();
double CalcKellyFraction();
string CalcExpectedValueBySetup();

//+------------------------------------------------------------------+
//| CURRENCY FAMILY — for correlation filter                         |
//+------------------------------------------------------------------+
string GetCurrencyFamily(string baseName)
{
   if(StringFind(baseName, "XAU") >= 0) return "GOLD";
   if(StringFind(baseName, "XAG") >= 0) return "SILVER";
   if(StringFind(baseName, "NAS") >= 0 || StringFind(baseName, "US30") >= 0 ||
      StringFind(baseName, "US500") >= 0) return "US_INDEX";
   if(StringFind(baseName, "GER") >= 0) return "EU_INDEX";
   if(StringLen(baseName) >= 6)
      return StringSubstr(baseName, 0, 3);
   return baseName;
}

void RecordFamilySignal(string baseName, ENUM_SIGNAL_DIR dir)
{
   string family = GetCurrencyFamily(baseName);
   for(int i = 0; i < g_familyCount; i++)
   {
      if(g_families[i].family == family)
      {
         g_families[i].signalsToday++;
         g_families[i].lastSignal = TimeCurrent();
         g_families[i].lastDir = (dir == DIR_BUY) ? "BUY" : "SELL";
         return;
      }
   }
   ArrayResize(g_families, g_familyCount + 1);
   g_families[g_familyCount].family = family;
   g_families[g_familyCount].signalsToday = 1;
   g_families[g_familyCount].lastSignal = TimeCurrent();
   g_families[g_familyCount].lastDir = (dir == DIR_BUY) ? "BUY" : "SELL";
   g_familyCount++;
}

bool IsCorrelBlocked(string baseName, ENUM_SIGNAL_DIR dir)
{
   if(!InpCorrelFilter) return false;
   string family = GetCurrencyFamily(baseName);
   for(int i = 0; i < g_familyCount; i++)
   {
      if(g_families[i].family == family)
      {
         if(g_families[i].signalsToday >= InpMaxPerFamily)
         {
            Print("[SNIPERv8.2] CORREL BLOCK: ", baseName, " family=", family,
                  " signals=", g_families[i].signalsToday, "/", InpMaxPerFamily);
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| v6: BREAKOUT CONFIRMATION — body ratio + close position          |
//+------------------------------------------------------------------+
bool IsBreakoutConfirmed(MqlRates &rates[], int direction)
{
   if(ArraySize(rates) < 3) return true; // can't check, let pass
   double body = MathAbs(rates[1].close - rates[1].open);
   double range = rates[1].high - rates[1].low;
   if(range <= 0) return true;

   // Body must be > minimum ratio of range (no doji / spinning top)
   if(body / range < InpMinBodyRatio) return false;

   // BUY breakout: bullish candle, close in upper half
   if(direction == 1)
   {
      if(rates[1].close <= rates[1].open) return false;
      if(rates[1].close < (rates[1].high + rates[1].low) / 2.0) return false;
   }
   // SELL breakout: bearish candle, close in lower half
   if(direction == -1)
   {
      if(rates[1].close >= rates[1].open) return false;
      if(rates[1].close > (rates[1].high + rates[1].low) / 2.0) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| v6: SWING FAILURE PATTERN (SFP) — the ultimate anti-fakeout      |
//| Returns: +1 bullish SFP (buy), -1 bearish SFP (sell), 0 none    |
//+------------------------------------------------------------------+
int DetectSFP(MqlRates &rates[], SwingPoint &swings[], double atr)
{
   if(ArraySize(swings) < 1 || ArraySize(rates) < 5) return 0;

   double lastSwHi = 0, lastSwLo = 0;
   for(int i = 0; i < ArraySize(swings); i++)
   {
      if(swings[i].isHigh && lastSwHi == 0)  lastSwHi = swings[i].price;
      if(!swings[i].isHigh && lastSwLo == 0) lastSwLo = swings[i].price;
      if(lastSwHi > 0 && lastSwLo > 0) break;
   }

   // [FUSION] Strict SFP from PrimeDev: 30% ATR + 35% wick ratio + body check
   // Bullish SFP: pierced below swing low BUT closed above it
   if(lastSwLo > 0)
   {
      bool piercedBelow = (rates[1].low < lastSwLo);
      bool closedAbove  = (rates[1].close > lastSwLo);
      double wickSize   = lastSwLo - rates[1].low;
      double bodySize   = MathAbs(rates[1].close - rates[1].open);
      double totalRange = rates[1].high - rates[1].low;

      if(piercedBelow && closedAbove && wickSize > atr * 0.3 && bodySize > 0 && totalRange > 0)
      {
         double wickRatio = wickSize / totalRange;
         if(wickRatio > 0.35) return 1; // Confirmed bullish SFP
      }
   }

   // Bearish SFP: pierced above swing high BUT closed below it
   if(lastSwHi > 0)
   {
      bool piercedAbove = (rates[1].high > lastSwHi);
      bool closedBelow  = (rates[1].close < lastSwHi);
      double wickSize   = rates[1].high - lastSwHi;
      double bodySize   = MathAbs(rates[1].close - rates[1].open);
      double totalRange = rates[1].high - rates[1].low;

      if(piercedAbove && closedBelow && wickSize > atr * 0.3 && bodySize > 0 && totalRange > 0)
      {
         double wickRatio = wickSize / totalRange;
         if(wickRatio > 0.35) return -1; // Confirmed bearish SFP
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| v6: FIBONACCI CONFLUENCE — check if price is near fib level      |
//| Returns: +1 buy zone (retracement in upswing),                   |
//|          -1 sell zone (retracement in downswing), 0 none         |
//+------------------------------------------------------------------+
int CheckFiboLevel(double curPrice, SwingPoint &swings[], double atr)
{
   if(ArraySize(swings) < 2) return 0;

   double swHi = 0, swLo = 0;
   int hiBarIdx = -1, loBarIdx = -1;
   for(int i = 0; i < ArraySize(swings); i++)
   {
      if(swings[i].isHigh && swHi == 0)
      { swHi = swings[i].price; hiBarIdx = swings[i].barIndex; }
      if(!swings[i].isHigh && swLo == 0)
      { swLo = swings[i].price; loBarIdx = swings[i].barIndex; }
      if(swHi > 0 && swLo > 0) break;
   }
   if(swHi == 0 || swLo == 0 || swHi <= swLo) return 0;

   double range = swHi - swLo;
   double tolerance = atr * 0.3;

   // Swing high more recent → price retracing down → fib levels are BUY zones
   if(hiBarIdx < loBarIdx)
   {
      double fib382 = swHi - range * 0.382;
      double fib500 = swHi - range * 0.500;
      double fib618 = swHi - range * 0.618;
      if(MathAbs(curPrice - fib382) < tolerance ||
         MathAbs(curPrice - fib500) < tolerance ||
         MathAbs(curPrice - fib618) < tolerance)
         return 1;
   }
   // Swing low more recent → price retracing up → fib levels are SELL zones
   else
   {
      double fib382 = swLo + range * 0.382;
      double fib500 = swLo + range * 0.500;
      double fib618 = swLo + range * 0.618;
      if(MathAbs(curPrice - fib382) < tolerance ||
         MathAbs(curPrice - fib500) < tolerance ||
         MathAbs(curPrice - fib618) < tolerance)
         return -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| v6: DYNAMIC MINIMUM SCORE — context-aware threshold              |
//+------------------------------------------------------------------+
int GetDynamicMinScore(int baseMin, bool isCounterTrend, int sessHour, int dow)
{
   if(!InpDynScore) return baseMin;
   int minScore = baseMin;

   // [FUSION] MathMax approach from PrimeDev — non-additive, takes highest floor
   // Counter-trend: floor at InpMinScoreCounter
   if(isCounterTrend)
      minScore = MathMax(minScore, InpMinScoreCounter);

   // Consecutive losses protection: floor at InpMinScoreAfterLoss
   if(g_consecLosses >= InpConsecLossMax)
      minScore = MathMax(minScore, InpMinScoreAfterLoss);

   // Asia/dead session (0-7 GMT): floor at InpMinScoreAsia
   if(sessHour >= 0 && sessHour < 7)
      minScore = MathMax(minScore, InpMinScoreAsia);

   // Friday PM (>=14h): floor at InpMinScoreFriday
   if(dow == 5 && sessHour >= 14)
      minScore = MathMax(minScore, InpMinScoreFriday);

   // Dead late night (21-23): also use Asia floor
   if(sessHour >= 21)
      minScore = MathMax(minScore, InpMinScoreAsia);

   return minScore;
}

//+------------------------------------------------------------------+
//| [FUSION] MARKET REGIME DETECTION (4 regimes)                       |
//| TRENDING = breakouts | RANGING = reversals                        |
//| VOLATILE = reduce exposure | QUIET = dead market                   |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME GetMarketRegime(double adxVal, double zScore)
{
   if(zScore > InpZScore_Max)   return REGIME_VOLATILE;
   if(zScore < InpZScore_Min)   return REGIME_QUIET;
   if(adxVal > InpRegimeADXTrend) return REGIME_TRENDING;
   return REGIME_RANGING;
}

string RegimeName(ENUM_MARKET_REGIME r)
{
   switch(r)
   {
      case REGIME_TRENDING:  return "TRENDING";
      case REGIME_RANGING:   return "RANGING";
      case REGIME_VOLATILE:  return "VOLATILE";
      case REGIME_QUIET:     return "QUIET";
   }
   return "UNKNOWN";
}

string RegimeEmoji(ENUM_MARKET_REGIME r)
{
   switch(r)
   {
      case REGIME_TRENDING:  return "📈";
      case REGIME_RANGING:   return "📊";
      case REGIME_VOLATILE:  return "⚡";
      case REGIME_QUIET:     return "🔇";
   }
   return "❓";
}

//+------------------------------------------------------------------+
//| [v8] ADVANCED REGIME DETECTION with hysteresis                    |
//| Uses ADX + Hurst + BB Width ratio + ATR ratio                    |
//| Hysteresis gap prevents flip-flopping between regimes            |
//| Per-symbol state tracking with minimum bars hold                  |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME DetectRegimeAdvanced(int idx, double adxVal, double hurstVal,
                                        double bbwRatio, double atrRatio)
{
   if(!InpUseRegime)
      return GetMarketRegime(adxVal, 0); // fallback to simple

   ENUM_MARKET_REGIME current = g_sym[idx].currentRegime;
   int barsHeld = g_sym[idx].regimeBarsHeld;
   g_sym[idx].regimeBarsHeld++;

   // Minimum bars hold — prevent rapid switching
   bool canSwitch = (barsHeld >= InpRegimeMinBars);

   // --- VOLATILE: BBW AND ATR both elevated ---
   // Entry: BBW > 1.5x avg AND ATR > 1.2x avg
   // Exit: BBW < 1.2x OR ATR < 1.0x
   if(current == REGIME_VOLATILE)
   {
      if(canSwitch && (bbwRatio < 1.2 || atrRatio < 1.0))
      { /* fall through to re-evaluate */ }
      else return REGIME_VOLATILE;
   }
   else if(bbwRatio > InpRegimeBBWHigh && atrRatio > 1.2)
   {
      if(canSwitch || current == REGIME_RANGING)
      {
         g_sym[idx].currentRegime = REGIME_VOLATILE;
         g_sym[idx].regimeBarsHeld = 0;
         return REGIME_VOLATILE;
      }
   }

   // --- QUIET: BBW AND ATR both depressed ---
   // Entry: BBW < 0.7x avg AND ATR < 0.85x avg
   // Exit: BBW > 0.85x OR ATR > 0.95x
   if(current == REGIME_QUIET)
   {
      if(canSwitch && (bbwRatio > 0.85 || atrRatio > 0.95))
      { /* fall through to re-evaluate */ }
      else return REGIME_QUIET;
   }
   else if(bbwRatio < InpRegimeBBWLow && atrRatio < 0.85)
   {
      if(canSwitch || current == REGIME_RANGING)
      {
         g_sym[idx].currentRegime = REGIME_QUIET;
         g_sym[idx].regimeBarsHeld = 0;
         return REGIME_QUIET;
      }
   }

   // --- TRENDING: ADX high AND Hurst persistent ---
   // Entry: ADX > 25 AND Hurst > 0.58
   // Exit: ADX < 20 OR Hurst < 0.52 (5-point and 0.06 hysteresis gap)
   if(current == REGIME_TRENDING)
   {
      // [FIX] ADX handle failure (-1) should NOT eject from TRENDING — only use Hurst for exit in that case
      bool adxExits = (adxVal >= 0) ? (adxVal < (InpRegimeADXTrend - 5.0)) : false;
      if(canSwitch && (adxExits || hurstVal < (InpRegimeHurstMin - 0.06)))
      { /* fall through to re-evaluate */ }
      else return REGIME_TRENDING;
   }
   else if(adxVal > InpRegimeADXTrend && hurstVal > InpRegimeHurstMin)
   {
      if(canSwitch || current == REGIME_RANGING)
      {
         g_sym[idx].currentRegime = REGIME_TRENDING;
         g_sym[idx].regimeBarsHeld = 0;
         return REGIME_TRENDING;
      }
   }

   // --- RANGING: default fallback ---
   if(current != REGIME_RANGING && canSwitch)
   {
      g_sym[idx].currentRegime = REGIME_RANGING;
      g_sym[idx].regimeBarsHeld = 0;
   }
   return REGIME_RANGING;
}

//+------------------------------------------------------------------+
//| [v8.2] AR(1) AUTOCORRELATION — replaces noisy R/S Hurst          |
//| Lag-1 autocorrelation of log-returns, mapped to [0, 1]:          |
//|   Output > 0.6 = persistent/trending  (trade breakouts)          |
//|   Output < 0.4 = mean-reverting       (trade reversals)          |
//|   Output ≈ 0.5 = random walk          (no edge)                  |
//| AR(1) is stable with 30+ bars vs Hurst needing 128+              |
//+------------------------------------------------------------------+
double CalcHurstExponent(MqlRates &rates[], int window)
{
   int n = MathMin(window, ArraySize(rates) - 2);
   if(n < 30) return 0.5; // need 30+ bars for stable estimate

   // Compute log-returns: r[i] = ln(close[i+1]) - ln(close[i+2])
   // (rates are series-ordered: [0]=current, [1]=prev, etc.)
   double returns[];
   ArrayResize(returns, n);
   for(int i = 0; i < n; i++)
   {
      if(rates[i+1].close <= 0 || rates[i+2].close <= 0) return 0.5;
      returns[i] = MathLog(rates[i+1].close) - MathLog(rates[i+2].close);
   }

   // Mean of returns
   double mean = 0;
   for(int i = 0; i < n; i++) mean += returns[i];
   mean /= n;

   // Lag-1 autocorrelation: sum((r[i]-mean)*(r[i+1]-mean)) / sum((r[i]-mean)^2)
   double num = 0, den = 0;
   for(int i = 0; i < n - 1; i++)
   {
      double di = returns[i] - mean;
      double di1 = returns[i+1] - mean;
      num += di * di1;
      den += di * di;
   }
   // Add last term to denominator
   double dLast = returns[n-1] - mean;
   den += dLast * dLast;

   if(den < 1e-15) return 0.5; // flat market

   double ar1 = num / den; // range [-1, +1]

   // Map AR(1) → pseudo-Hurst [0, 1]: H = (ar1 + 1) / 2
   // ar1 = +1 → H = 1.0 (trending), ar1 = 0 → H = 0.5 (random), ar1 = -1 → H = 0.0 (reverting)
   double H = (ar1 + 1.0) / 2.0;
   return MathMax(0.0, MathMin(1.0, H));
}

//+------------------------------------------------------------------+
//| [PhD] ATR PERCENTILE RANKING — fat-tail aware (not Z-Score)      |
//| Returns 0-100: 50 = median, 90 = very volatile, 10 = very quiet  |
//+------------------------------------------------------------------+
double CalcATRPercentileRank(double &atrBuf[], int period)
{
   int n = MathMin(period, ArraySize(atrBuf) - 2); // -2: skip bar[0] (incomplete) and bar[1] (current)
   if(n < 10) return 50.0; // not enough data

   double currentATR = atrBuf[1];
   int belowCount = 0;
   for(int i = 2; i <= n + 1; i++) // start at bar[2] to avoid self-comparison with bar[1]
   {
      if(atrBuf[i] <= currentATR) belowCount++;
   }
   return (double)belowCount / (double)n * 100.0;
}

//+------------------------------------------------------------------+
//| [PhD] LINEAR REGRESSION SLOPE — for divergence detection          |
//| Calculates slope of least-squares regression over N bars          |
//+------------------------------------------------------------------+
double CalcLinRegSlope(double &data[], int start, int len)
{
   if(start + len > ArraySize(data) || len < 3) return 0;
   double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
   for(int i = 0; i < len; i++)
   {
      double x = (double)i;
      double y = data[start + i];
      sumX += x; sumY += y; sumXY += x * y; sumX2 += x * x;
   }
   double denom = len * sumX2 - sumX * sumX;
   if(MathAbs(denom) < 1e-10) return 0;
   return (len * sumXY - sumX * sumY) / denom;
}

//+------------------------------------------------------------------+
//| [PhD] MULTI-TF WEIGHTED COHERENCE — D1=40%, H4=35%, H1=25%      |
//| Returns coherence score 0-100%. Signal passes if >= 75%           |
//+------------------------------------------------------------------+
double CalcTFCoherence(int trendD1, int trendH4, int trendH1, int signalDir)
{
   double score = 0;
   // D1 weight = 40%
   if(trendD1 == signalDir) score += 40.0;
   else if(trendD1 == 0) score += 15.0; // neutral = partial credit
   // H4 weight = 35%
   if(trendH4 == signalDir) score += 35.0;
   else if(trendH4 == 0) score += 12.0;
   // H1 weight = 25%
   if(trendH1 == signalDir) score += 25.0;
   else if(trendH1 == 0) score += 8.0;
   return score;
}

//+------------------------------------------------------------------+
//| [PhD] BAYESIAN WIN-RATE PER SETUP (Beta-Binomial)                |
//| Auto-adapts confidence as data accumulates                        |
//+------------------------------------------------------------------+
void BayesUpdate(ENUM_SETUP_TYPE setup, bool success)
{
   int idx = (int)setup;
   if(idx < 0 || idx > 12) return;
   if(success) g_bayesSetup[idx].alpha += 1.0;
   else        g_bayesSetup[idx].beta += 1.0;
   g_bayesSetup[idx].n++;
}

double BayesPosterior(ENUM_SETUP_TYPE setup)
{
   int idx = (int)setup;
   if(idx < 0 || idx > 12) return 0.5;
   double a = g_bayesSetup[idx].alpha;
   double b = g_bayesSetup[idx].beta;
   if(a + b <= 0) return 0.5;
   return a / (a + b); // Mean of Beta distribution
}

// Auto-adjust confluence weight based on Bayesian posterior
int BayesAdjustWeight(ENUM_SETUP_TYPE setup, int baseWeight)
{
   int idx = (int)setup;
   if(idx < 0 || idx > 12) return baseWeight;
   if(g_bayesSetup[idx].n < 10) return baseWeight; // need min 10 observations
   double post = BayesPosterior(setup);
   if(post < InpBayesMinConf) return MathMax(0, baseWeight - 1); // unreliable: reduce weight
   if(post > InpBayesMinConf + 0.30) return baseWeight + 1;       // very reliable: boost weight
   return baseWeight;
}

//+------------------------------------------------------------------+
//| [PhD] SORTINO RATIO — penalizes only downside volatility          |
//+------------------------------------------------------------------+
double CalcSortino()
{
   if(g_trackedCount < 5) return 0;
   double sumReturn = 0, sumDownSq = 0;
   int closedCount = 0;
   for(int i = 0; i < g_trackedCount; i++)
   {
      if(!g_tracked[i].closed) continue;
      // [FIX] Skip expired signals with no definitive outcome (no TP, no SL) — they dilute with ret=0
      if(!g_tracked[i].slHit && !g_tracked[i].tp1Hit) continue;
      double ret = 0;
      if(g_tracked[i].slHit && !g_tracked[i].movedToBE && !g_tracked[i].movedToTP1)
         ret = -g_tracked[i].slPips;
      else if(g_tracked[i].tp3Hit) ret = g_tracked[i].tp3Pips;
      else if(g_tracked[i].tp2Hit) ret = g_tracked[i].tp2Pips;
      else if(g_tracked[i].tp1Hit) ret = g_tracked[i].tp1Pips;
      sumReturn += ret;
      if(ret < 0) sumDownSq += ret * ret;
      closedCount++;
   }
   if(closedCount < 2) return 0;
   double meanRet = sumReturn / closedCount;
   double downDev = MathSqrt(sumDownSq / closedCount);
   if(downDev < 0.01) return (meanRet > 0) ? 99.99 : 0;
   return meanRet / downDev;
}

//+------------------------------------------------------------------+
//| [PhD] KELLY CRITERION — optimal position sizing fraction          |
//| Returns half-Kelly for safety (variance reduction)                |
//+------------------------------------------------------------------+
double CalcKellyFraction()
{
   // Total wins = any TP hit (tp1/tp2/tp3 are cumulative — tp2 implies tp1 was hit)
   int wins = g_stats.tp1Wins;  // tp1Wins = all signals that hit at least TP1
   int losses = g_stats.slLosses;
   if(wins + losses < 10) return 0;
   double p = (double)wins / (double)(wins + losses);
   double q = 1.0 - p;
   // [FIX] pipsWon is now weighted by 1/3 lot per TP (partial close model)
   // avgWin = realized pips per winning signal (already correctly weighted)
   double avgWin = (wins > 0) ? g_stats.pipsWon / wins : 0;
   // avgLoss = full position stopped out (no partial close on SL)
   double avgLoss = (losses > 0) ? g_stats.pipsLost / losses : 1;
   if(avgLoss < 0.01) return 0;
   double b = avgWin / avgLoss;
   double kelly = (p * b - q) / b;
   return MathMax(0, kelly * 0.5); // Half-Kelly for safety
}

//+------------------------------------------------------------------+
//| [PhD] EXPECTED VALUE PER SETUP TYPE                               |
//+------------------------------------------------------------------+
string CalcExpectedValueBySetup()
{
   string result = "";
   for(int s = 1; s <= 12; s++)
   {
      if(g_stats.setupTotal[s] < 3) continue;
      double ev = g_stats.setupPips[s] / (double)g_stats.setupTotal[s];
      double wr = (double)g_stats.setupWins[s] / (double)g_stats.setupTotal[s] * 100.0;
      double bayesWR = BayesPosterior((ENUM_SETUP_TYPE)s) * 100.0;
      result += SetupName((ENUM_SETUP_TYPE)s) + ": EV=" + DoubleToString(ev, 1) + "p";
      result += " WR=" + DoubleToString(wr, 1) + "%";
      result += " Bayes=" + DoubleToString(bayesWR, 1) + "%";
      result += " n=" + IntegerToString(g_stats.setupTotal[s]) + "\n";
   }
   return result;
}

//+------------------------------------------------------------------+
//| [v8] NEWS CACHE — Load high-impact events once every 30 min     |
//| Avoids calling CalendarValueHistory on every scan (16+ symbols)  |
//| Uses trade server time (not UTC) as required by Calendar API     |
//+------------------------------------------------------------------+
void LoadNewsCache()
{
   datetime serverNow = TimeCurrent();
   if(serverNow < g_newsNextReload && g_newsCacheCount > 0)
      return; // cache still valid

   // Reload: fetch events in a 6-hour window around current time
   datetime from = serverNow - 3 * 3600;
   datetime to   = serverNow + 3 * 3600;
   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to);

   g_newsCacheCount = 0;
   ArrayResize(g_newsCache, 0);

   if(total > 0)
   {
      ArrayResize(g_newsCache, total); // pre-allocate max
      for(int i = 0; i < total; i++)
      {
         MqlCalendarEvent event;
         if(!CalendarEventById(values[i].event_id, event)) continue;
         if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;
         MqlCalendarCountry country;
         if(!CalendarCountryById(event.country_id, country)) continue;

         g_newsCache[g_newsCacheCount].eventTime = values[i].time;
         g_newsCache[g_newsCacheCount].currency  = country.currency;
         g_newsCache[g_newsCacheCount].eventName = event.name;
         g_newsCacheCount++;
      }
      ArrayResize(g_newsCache, g_newsCacheCount);
   }

   g_newsNextReload = serverNow + 1800; // reload in 30 min
   Print("[SNIPERv8.2] News cache loaded: ", g_newsCacheCount, " high-impact events");
}

//+------------------------------------------------------------------+
//| NEWS FILTER — cached version + hardcoded fallback                |
//| Maps metals/indices to relevant currencies                       |
//+------------------------------------------------------------------+
bool IsNewsBlocked(string baseName)
{
   if(!InpNewsFilter) return false;

   // Determine affected currencies
   string ccy1 = "", ccy2 = "";
   if(StringLen(baseName) >= 6)
   {
      ccy1 = StringSubstr(baseName, 0, 3);
      ccy2 = StringSubstr(baseName, 3, 3);
   }
   // Map metals/indices to USD (they react to USD news)
   if(StringFind(baseName, "XAU") >= 0 || StringFind(baseName, "XAG") >= 0)
   { ccy1 = "USD"; ccy2 = "USD"; }
   else if(StringFind(baseName, "NAS") >= 0 || StringFind(baseName, "US30") >= 0 ||
           StringFind(baseName, "US500") >= 0 || StringFind(baseName, "SP500") >= 0)
   { ccy1 = "USD"; ccy2 = "USD"; }
   else if(StringFind(baseName, "GER") >= 0 || StringFind(baseName, "DAX") >= 0)
   { ccy1 = "EUR"; ccy2 = "EUR"; }
   else if(ccy1 == "" && ccy2 == "")
   { ccy1 = "USD"; ccy2 = "USD"; }

   // Refresh cache if needed
   LoadNewsCache();

   // Check cached events against current time
   datetime serverNow = TimeCurrent();
   int blockWindow = InpNewsBlockMins * 60;

   for(int i = 0; i < g_newsCacheCount; i++)
   {
      int timeDiff = (int)(serverNow - g_newsCache[i].eventTime);
      if(timeDiff > blockWindow || timeDiff < -blockWindow) continue;
      // Event is within the blocking window
      if(g_newsCache[i].currency == ccy1 || g_newsCache[i].currency == ccy2)
      {
         Print("[SNIPERv8.2] NEWS BLOCK: ", g_newsCache[i].eventName,
               " (", g_newsCache[i].currency, ") for ", baseName,
               " T=", TimeToString(g_newsCache[i].eventTime, TIME_MINUTES));
         return true;
      }
   }

   // FALLBACK if Calendar API returned nothing (Strategy Tester, old build, etc.)
   if(g_newsCacheCount == 0)
   {
      datetime gmtNow = TimeGMT();
      MqlDateTime dtGMT;
      TimeToStruct(gmtNow, dtGMT);

      // NFP (1st Friday, 13:30 UTC)
      if(dtGMT.day_of_week == 5 && dtGMT.day <= 7)
      {
         if((dtGMT.hour == 13 && dtGMT.min >= 0) || (dtGMT.hour == 14 && dtGMT.min <= 30))
         {
            if(ccy1 == "USD" || ccy2 == "USD")
            { Print("[SNIPERv8.2] NEWS BLOCK (fallback): NFP for ", baseName); return true; }
         }
      }
      // FOMC (3rd Wednesday, 19:00 UTC)
      if(dtGMT.day_of_week == 3 && dtGMT.day >= 15 && dtGMT.day <= 21)
      {
         if((dtGMT.hour == 18 && dtGMT.min >= 30) || (dtGMT.hour == 19 && dtGMT.min <= 30))
         {
            if(ccy1 == "USD" || ccy2 == "USD") return true;
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| [v8] TICK DELTA — Buy/sell pressure from bid/ask tick movement   |
//| TICK_FLAG_BUY/SELL don't work on retail Forex (always 0)         |
//| Instead: classify by which price moved (bid vs ask)              |
//|   Bid uptick = buy pressure | Ask downtick = buy pressure        |
//|   Bid downtick = sell pressure | Ask uptick = sell pressure      |
//| Returns: -1.0 (pure sell) to +1.0 (pure buy), normalized        |
//| dir: 1=BUY context, -1=SELL context (for logging only)          |
//+------------------------------------------------------------------+
double GetTickDelta(string symbol, int dir)
{
   if(!InpUseTickDelta) return 0.0;

   MqlTick ticks[];
   int copied = CopyTicks(symbol, ticks, COPY_TICKS_INFO, 0, InpTickDeltaTicks);
   if(copied < 20) return 0.0; // not enough ticks

   int buyPressure = 0, sellPressure = 0;

   for(int i = 1; i < copied; i++)
   {
      uint flags = ticks[i].flags;

      // Bid moved up → buy pressure (someone lifting the bid)
      if((flags & 2) != 0) // TICK_FLAG_BID
      {
         if(ticks[i].bid > ticks[i-1].bid)
            buyPressure++;
         else if(ticks[i].bid < ticks[i-1].bid)
            sellPressure++;
      }

      // Ask moved down → buy pressure (seller retreating)
      // Ask moved up → sell pressure (seller aggressive)
      if((flags & 4) != 0) // TICK_FLAG_ASK
      {
         if(ticks[i].ask < ticks[i-1].ask)
            buyPressure++;
         else if(ticks[i].ask > ticks[i-1].ask)
            sellPressure++;
      }
   }

   int total = buyPressure + sellPressure;
   if(total == 0) return 0.0;

   // Normalize to -1.0 (pure sell) to +1.0 (pure buy)
   double delta = (double)(buyPressure - sellPressure) / (double)total;
   return delta;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=============================================");
   Print("  Market Sniper v8.2 REGIME");
   Print("  21 confluences | D1+H4 macro trend");
   Print("  4-Regime detection with hysteresis");
   Print("  News cache | Tick delta pressure");
   Print("  MTS composite | PhD Bayesian scoring");
   Print("  SFP + Fibo + BB + Dynamic Score");
   Print("=============================================");

   if(!BuildSymbolList())
   {
      Print("[SNIPERv8.2] ERROR: No symbols found.");
      return INIT_FAILED;
   }
   Print("[SNIPERv8.2] Symbols: ", g_symCount);

   if(!InitIndicators())
   {
      Print("[SNIPERv8.2] ERROR: Indicator creation failed.");
      return INIT_FAILED;
   }

   g_alertsToday = 0;
   g_dayStart    = TimeCurrent();
   g_totalScans  = 0;
   g_totalAlerts = 0;
   g_trackedCount = 0;
   g_dailyReportSent = false;
   g_familyCount = 0;
   g_consecLosses = 0;
   g_signalsBlockedToday = 0;
   ZeroMemory(g_stats);
   // [PhD] Initialize Bayesian priors (weakly informative: alpha=2, beta=2)
   for(int b = 0; b < 13; b++)
   { g_bayesSetup[b].alpha = 2.0; g_bayesSetup[b].beta = 2.0; g_bayesSetup[b].n = 0; }
   ArrayResize(g_tracked, 0);
   ArrayResize(g_families, 0);

   // [v8] Initialize regime state for all symbols
   for(int r = 0; r < g_symCount; r++)
   {
      g_sym[r].currentRegime = REGIME_RANGING;
      g_sym[r].regimeBarsHeld = InpRegimeMinBars; // allow immediate first detection
   }
   // [v8] Pre-load news cache
   g_newsNextReload = 0;
   g_newsCacheCount = 0;
   LoadNewsCache();

   EventSetTimer(InpScanInterval);

   int activeCount = 0;
   string symList = "";
   for(int i = 0; i < g_symCount; i++)
   {
      if(g_sym[i].active)
      {
         symList += g_sym[i].baseName + " ";
         activeCount++;
      }
   }
   Print("[SNIPERv8.2] Active: ", symList);

   if(InpUseTelegram)
   {
      string msg = "*MARKET SNIPER v8.2 REGIME ONLINE* 🔥\n";
      msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
      msg += "📊 Symboles: " + IntegerToString(activeCount) + "\n";
      msg += "📐 Score: 0-29 (min " + IntegerToString(InpMinScore) + "+dyn)\n";
      msg += "🎯 21 confluences | D1 macro trend\n";
      msg += "🛡 Min SL: " + DoubleToString(InpMinSL_Pips, 0) + " pips | RR>=" + DoubleToString(InpMinRR, 1) + "\n";
      msg += "⚠ Counter-trend: -" + IntegerToString(InpCounterPenalty) + " | Min CT score: " + IntegerToString(InpMinScoreCounter) + "\n";
      msg += "📊 ADX>" + IntegerToString(InpADX_Min) + " | Z-Score: " + DoubleToString(InpZScore_Min, 2) + "-" + DoubleToString(InpZScore_Max, 2) + "\n";
      msg += "🕐 TF: D1+" + TFStr(InpTF_Trend) + "/" + TFStr(InpTF_Signal) + "/" + TFStr(InpTF_Entry) + "\n";
      msg += "⏱ Scan: " + IntegerToString(InpScanInterval) + "s\n";
      msg += "🧪 MTS composite | 4-Regime | News cache | Tick delta\n";
      msg += "🔬 v8.2: AR(1) autocorr | Adaptive div | Breakout anti-chase fix\n";
      string features = "";
      if(InpTrackSignals)   features += "📋Track ";
      if(InpSessionFilter)  features += "🕐Sess ";
      if(InpNewsFilter)     features += "📰News ";
      if(InpCorrelFilter)   features += "🔗Corr ";
      if(InpUseVolume)      features += "📊Vol ";
      if(InpTFAlignFilter)  features += "🎯TFAlign ";
      if(InpBreakoutConfirm)features += "✅BrkConf ";
      if(InpSFPFilter)      features += "🔄SFP ";
      if(InpUseBBSqueeze)   features += "📉BB ";
      if(InpUseROC)         features += "📈ROC ";
      if(InpUseFibo)        features += "🔢Fibo ";
      if(InpDynScore)       features += "🧠DynScore ";
      if(InpUseRegime)      features += "🔀Regime ";
      if(InpUseTickDelta)   features += "📊TDelta ";
      if(features != "") msg += features + "\n";
      if(InpDynScore)
      {
         msg += "🧠 Asia:" + IntegerToString(InpMinScoreAsia);
         msg += " Fri:" + IntegerToString(InpMinScoreFriday);
         msg += " Loss:" + IntegerToString(InpMinScoreAfterLoss) + "\n";
      }
      msg += "📰 News events cached: " + IntegerToString(g_newsCacheCount) + "\n";
      msg += "📋 CSV Log: " + g_csvFileName + " (" + IntegerToString(g_csvSignalCount) + " prior)\n";
      msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
      msg += "🔍 Phase 1: Forward Testing - All signals logged to CSV";
      SendTelegram(msg);
   }

   // [Phase1] Initialize CSV signal log file
   g_csvSignalCount = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_csvFileName = "MarketSniper_Signals_" +
                   IntegerToString(dt.year) +
                   StringFormat("%02d", dt.mon) +
                   StringFormat("%02d", dt.day) + ".csv";
   // Create file with headers if it doesn't exist
   if(!FileIsExist(g_csvFileName))
   {
      int fh = FileOpen(g_csvFileName, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(fh != INVALID_HANDLE)
      {
         FileWrite(fh,
            "SignalID", "DateTime", "Symbol", "Direction", "Setup", "Grade", "Score",
            "Entry", "LiveEntry", "Slippage_Pips",
            "SL", "TP1", "TP2", "TP3",
            "SL_Pips", "TP1_Pips", "TP2_Pips", "TP3_Pips",
            "RR1", "RR2", "RR3",
            "TrendD1", "TrendH4", "TrendH1",
            "ADX", "Regime", "ZScore", "ROC", "Hurst", "ATRPctile", "TickDelta",
            "Confluences",
            "Result", "HitTP1", "HitTP2", "HitTP3", "HitSL",
            "ExitPrice", "ExitTime", "PnL_Pips", "Notes");
         FileClose(fh);
         Print("[Phase1] CSV created: ", g_csvFileName);
      }
   }
   else
   {
      // Count existing signals in file to continue numbering
      int fh = FileOpen(g_csvFileName, FILE_READ | FILE_CSV | FILE_ANSI, ',');
      if(fh != INVALID_HANDLE)
      {
         while(!FileIsEnding(fh)) { FileReadString(fh); if(FileIsLineEnding(fh)) g_csvSignalCount++; }
         g_csvSignalCount = MathMax(0, g_csvSignalCount - 1); // subtract header
         FileClose(fh);
         Print("[Phase1] CSV exists, ", g_csvSignalCount, " signals already logged");
      }
   }

   g_initialized = true;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseAllHandles();
   Comment("");

   Print("[SNIPERv8.2] Stopped. Scans: ", g_totalScans, " Alerts: ", g_totalAlerts);

   if(InpTrackSignals && g_stats.totalSignals > 0)
      SendDailyReport();

   if(InpUseTelegram)
   {
      string msg = "*MARKET SNIPER v8.2 OFFLINE*\n";
      msg += "Scans: " + IntegerToString(g_totalScans) + " | Alerts: " + IntegerToString(g_totalAlerts) + "\n";
      msg += "📋 CSV: " + IntegerToString(g_csvSignalCount) + " signals logged to " + g_csvFileName;
      SendTelegram(msg);
   }
}

//+------------------------------------------------------------------+
//| OnTimer — Main scan loop                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_initialized) return;

   // Daily reset
   MqlDateTime dtNow;
   TimeCurrent(dtNow);
   datetime today = StringToTime(IntegerToString(dtNow.year) + "." +
                    IntegerToString(dtNow.mon) + "." + IntegerToString(dtNow.day));
   if(today != g_dayStart)
   {
      g_alertsToday = 0;
      g_dayStart = today;
      g_dailyReportSent = false;
      // Reset correlation tracking
      g_familyCount = 0;
      g_signalsBlockedToday = 0; // [FUSION] reset blocked counter
      g_dailySLHits = 0;
      g_dailyLossPips = 0.0;
      g_circuitBroken = false;
      ArrayResize(g_families, 0);
   }

   // [v9] Circuit breaker — stop scanning if too many losses today
   if(g_circuitBroken) { Comment("⛔ CIRCUIT BREAKER — Scanning stopped. Reset tomorrow."); return; }

   // Track active signals
   if(InpTrackSignals)
      CheckTrackedSignals();

   // Daily report
   if(InpDailyReport && InpTrackSignals && !g_dailyReportSent)
   {
      MqlDateTime dtCheck;
      TimeCurrent(dtCheck);
      if(dtCheck.hour >= InpReportHour)
      {
         SendDailyReport();
         g_dailyReportSent = true;
      }
   }

   // Session filter — block low-liquidity windows (Sunday open / Monday Asia early)
   bool sessionBlocked = false;
   if(InpSessionFilter)
   {
      datetime gmtNow = TimeGMT();
      MqlDateTime dtGMT;
      TimeToStruct(gmtNow, dtGMT);
      int dow  = dtGMT.day_of_week;  // 0=Sunday
      int hour = dtGMT.hour;
      // Sunday after InpSessBlockStart or Monday before InpSessBlockEnd
      if((dow == 0 && hour >= InpSessBlockStart) || (dow == 1 && hour < InpSessBlockEnd))
         sessionBlocked = true;
      // Saturday (market closed)
      if(dow == 6) sessionBlocked = true;
   }

   // Scan all symbols
   for(int i = 0; i < g_symCount; i++)
   {
      if(!g_sym[i].active) continue;

      // New bar check on entry TF
      datetime curBar = iTime(g_sym[i].name, InpTF_Entry, 0);
      if(curBar == 0 || curBar == g_sym[i].lastScanBar) continue;
      g_sym[i].lastScanBar = curBar;

      g_totalScans++;

      // Daily cap
      if(g_alertsToday >= InpMaxAlertsDay) continue;

      // Block signals during low-liquidity session
      if(sessionBlocked) continue;

      // News filter
      if(InpNewsFilter && IsNewsBlocked(g_sym[i].baseName))
         continue;

      // [v9] Spread filter
      if(InpSpreadFilter)
      {
         double ask = SymbolInfoDouble(g_sym[i].name, SYMBOL_ASK);
         double bid = SymbolInfoDouble(g_sym[i].name, SYMBOL_BID);
         double spreadPips = (ask - bid) / g_sym[i].pipSize;
         bool isGold = (StringFind(g_sym[i].name, "XAU") >= 0);
         double maxSpread = isGold ? InpMaxSpreadGold : InpMaxSpreadPips;
         if(spreadPips > maxSpread)
         {
            Print("[v9] ", g_sym[i].baseName, " spread ", DoubleToString(spreadPips, 1),
                  " > max ", DoubleToString(maxSpread, 1), " — BLOCKED");
            continue; // skip this symbol
         }
      }

      ScanSymbol(i);
   }

   UpdateDashboard();
}

void OnTick() { /* EA stays alive via OnTimer */ }

//+------------------------------------------------------------------+
//| BUILD SYMBOL LIST — Custom string + auto-detect + ResolveSymbol  |
//+------------------------------------------------------------------+
bool BuildSymbolList()
{
   ArrayResize(g_sym, MAX_SYMBOLS);
   g_symCount = 0;

   if(InpCustomSymbols != "" && !InpAutoDetect)
   {
      string parts[];
      int count = StringSplit(InpCustomSymbols, ',', parts);

      for(int i = 0; i < count && g_symCount < MAX_SYMBOLS; i++)
      {
         string base = parts[i];
         StringTrimLeft(base);
         StringTrimRight(base);
         if(base == "") continue;

         string resolved = ResolveSymbol(base);
         if(resolved == "")
         {
            Print("[SNIPERv8.2] Not found: ", base);
            continue;
         }

         InitSymbolData(g_symCount, resolved, base);
         g_symCount++;
         Print("[SNIPERv8.2] + ", base, " -> ", resolved,
               " (", g_sym[g_symCount-1].digits, "d, pip=",
               DoubleToString(g_sym[g_symCount-1].pipSize, g_sym[g_symCount-1].digits), ")");
      }
   }
   else
   {
      int total = SymbolsTotal(false);
      for(int i = 0; i < total && g_symCount < MAX_SYMBOLS; i++)
      {
         string sym = SymbolName(i, false);
         if(!IsSymbolTradeable(sym)) continue;

         string base = ExtractBaseName(sym);
         bool include = false;
         if(InpScanForex && IsForexPair(base))   include = true;
         if(InpScanMetals && IsMetalSym(base))    include = true;
         if(InpScanIndices && IsIndexSym(base))   include = true;

         if(!include) continue;

         SymbolSelect(sym, true);
         InitSymbolData(g_symCount, sym, base);
         g_symCount++;
      }
   }

   ArrayResize(g_sym, g_symCount);
   return g_symCount > 0;
}

//+------------------------------------------------------------------+
//| SYMBOL RESOLUTION — multi-broker fallback                        |
//+------------------------------------------------------------------+
string ResolveSymbol(string base)
{
   // Try exact match first
   if(SymCheck(base)) { SymbolSelect(base, true); return base; }

   // Common broker suffixes (VT Markets, IC, Pepperstone, etc.)
   string suffixes[] = {"-ECN",".",".a","-STD","-PRO","m",".raw","_",".pro",".std",".i",".e",".ecn"};
   for(int i = 0; i < ArraySize(suffixes); i++)
   {
      string test = base + suffixes[i];
      if(SymCheck(test)) { SymbolSelect(test, true); return test; }
   }

   // Index aliases
   if(base == "NAS100")
   {
      string a[] = {"NAS100.","NAS100-ECN","USTEC","USTEC.","US100","US100.","USTECH","NSDQ100","NAS100ft."};
      for(int i = 0; i < ArraySize(a); i++)
         if(SymCheck(a[i])) { SymbolSelect(a[i], true); return a[i]; }
   }
   if(base == "US30")
   {
      string a[] = {"DJ30.","DJ30","DJ30-ECN","US30.","US30-ECN","WS30","WS30.","DOWJONES","DJ30ft."};
      for(int i = 0; i < ArraySize(a); i++)
         if(SymCheck(a[i])) { SymbolSelect(a[i], true); return a[i]; }
   }
   if(base == "US500")
   {
      string a[] = {"SP500.","SP500","US500.","US500-ECN","SPX500","SPX500.","SP500-ECN"};
      for(int i = 0; i < ArraySize(a); i++)
         if(SymCheck(a[i])) { SymbolSelect(a[i], true); return a[i]; }
   }
   if(base == "GER40")
   {
      string a[] = {"GER40.","GER40-ECN","DE40.","DE40","DAX40","DAX40.","GER30","GER30."};
      for(int i = 0; i < ArraySize(a); i++)
         if(SymCheck(a[i])) { SymbolSelect(a[i], true); return a[i]; }
   }

   Print("[SNIPERv8.2] Symbol not found: ", base);
   return "";
}

bool SymCheck(string sym)
{
   bool isCustom = false;
   return SymbolExist(sym, isCustom);
}

void InitSymbolData(int idx, string sym, string base)
{
   g_sym[idx].name          = sym;
   g_sym[idx].baseName      = base;
   g_sym[idx].active        = true;
   g_sym[idx].digits        = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   g_sym[idx].point         = SymbolInfoDouble(sym, SYMBOL_POINT);
   g_sym[idx].pipSize       = CalcPipSize(sym);
   g_sym[idx].lastAlertTime = 0;
   g_sym[idx].lastScanBar   = 0;
   g_sym[idx].lastAlertHash = "";
   g_sym[idx].lastDir       = "-";
   g_sym[idx].lastType      = "-";
   g_sym[idx].lastTime      = 0;
   g_sym[idx].lastScore     = 0;
}

//+------------------------------------------------------------------+
//| SYMBOL CLASSIFICATION                                             |
//+------------------------------------------------------------------+
bool IsSymbolTradeable(string sym)
{
   long mode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   return (mode != SYMBOL_TRADE_MODE_DISABLED);
}

string ExtractBaseName(string sym)
{
   string r = sym;
   StringToUpper(r);
   StringReplace(r, "-ECN", "");
   StringReplace(r, ".ECN", "");
   StringReplace(r, ".PRO", "");
   StringReplace(r, ".RAW", "");
   StringReplace(r, ".STD", "");
   StringReplace(r, ".STP", "");
   StringReplace(r, ".CRP", "");
   int len = StringLen(r);
   if(len > 0)
   {
      ushort last = StringGetCharacter(r, len - 1);
      if(last == '.' || last == '#')
         r = StringSubstr(r, 0, len - 1);
   }
   int ftPos = StringFind(r, "FT");
   if(ftPos > 2) r = StringSubstr(r, 0, ftPos);
   return r;
}

bool IsForexPair(string base)
{
   string pairs[] = {"EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","NZDUSD","USDCAD",
                     "EURGBP","EURJPY","GBPJPY","EURAUD","EURNZD","EURCHF","EURCAD",
                     "GBPAUD","GBPNZD","GBPCHF","GBPCAD","AUDJPY","AUDNZD","AUDCHF",
                     "AUDCAD","NZDJPY","NZDCAD","CADJPY","CHFJPY"};
   for(int i = 0; i < ArraySize(pairs); i++)
      if(base == pairs[i]) return true;
   if(StringLen(base) == 6)
   {
      bool ok = true;
      for(int i = 0; i < 6; i++)
      {
         ushort c = StringGetCharacter(base, i);
         if(c < 'A' || c > 'Z') { ok = false; break; }
      }
      if(ok) return true;
   }
   return false;
}

bool IsIndexSym(string base)
{
   string idx[] = {"US30","US500","US100","NAS100","SPX500","DJ30","GER40","GER30",
                   "UK100","FRA40","JP225","AUS200","USTEC","DAX40","DAX","ES35"};
   for(int i = 0; i < ArraySize(idx); i++)
      if(base == idx[i] || StringFind(base, idx[i]) >= 0) return true;
   return false;
}

bool IsMetalSym(string base)
{
   string metals[] = {"XAUUSD","XAGUSD","GOLD","SILVER","XAUAUD","XAGAUD","XPTUSD","XPDUSD"};
   for(int i = 0; i < ArraySize(metals); i++)
      if(base == metals[i] || StringFind(base, metals[i]) >= 0) return true;
   return false;
}

//+------------------------------------------------------------------+
//| PIP SIZE CALCULATION — robust instrument detection               |
//+------------------------------------------------------------------+
double CalcPipSize(string sym)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   string upper = sym;
   StringToUpper(upper);

   // Gold
   if(StringFind(upper, "XAU") >= 0 || StringFind(upper, "GOLD") >= 0)
   {
      if(digits == 2) return 0.1;
      if(digits == 3) return 0.01 * 10;
      return point * 10;
   }
   // Silver
   if(StringFind(upper, "XAG") >= 0 || StringFind(upper, "SILVER") >= 0)
   {
      if(digits <= 3) return 0.01;
      return point * 10;
   }
   // Platinum / Palladium
   if(StringFind(upper, "XPT") >= 0 || StringFind(upper, "XPD") >= 0)
      return 0.1;
   // Indices
   if(StringFind(upper, "NAS") >= 0 || StringFind(upper, "US30") >= 0 ||
      StringFind(upper, "DJ30") >= 0 || StringFind(upper, "US500") >= 0 ||
      StringFind(upper, "SP500") >= 0 || StringFind(upper, "GER") >= 0 ||
      StringFind(upper, "DAX") >= 0 || StringFind(upper, "UK100") >= 0 ||
      StringFind(upper, "USTEC") >= 0)
   {
      if(digits <= 1) return (digits == 0) ? 1.0 : 0.1;
      return 1.0;
   }
   // Forex
   if(digits == 5 || digits == 3) return point * 10;
   if(digits == 4 || digits == 2) return point;
   return point;
}

//+------------------------------------------------------------------+
//| INDICATOR INITIALIZATION — D1 + Trend + Signal + Entry           |
//+------------------------------------------------------------------+
bool InitIndicators()
{
   int count = 0;
   for(int i = 0; i < g_symCount; i++)
   {
      string sym = g_sym[i].name;

      // D1 — Macro trend (always PERIOD_D1)
      g_sym[i].hD1.hEMA21  = iMA(sym, PERIOD_D1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hD1.hEMA50  = iMA(sym, PERIOD_D1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hD1.hEMA200 = iMA(sym, PERIOD_D1, InpEMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hD1.hRSI    = INVALID_HANDLE;
      g_sym[i].hD1.hATR    = iATR(sym, PERIOD_D1, InpATR_Period);
      g_sym[i].hD1.hMACD   = INVALID_HANDLE;
      g_sym[i].hD1.hADX    = INVALID_HANDLE;
      g_sym[i].hD1.hBB     = INVALID_HANDLE;
      count += 4;

      // Trend TF (H4) — Intermediate trend
      g_sym[i].hTrend.hEMA21  = iMA(sym, InpTF_Trend, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hTrend.hEMA50  = iMA(sym, InpTF_Trend, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hTrend.hEMA200 = iMA(sym, InpTF_Trend, InpEMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hTrend.hRSI    = INVALID_HANDLE;
      g_sym[i].hTrend.hATR    = INVALID_HANDLE;
      g_sym[i].hTrend.hMACD   = INVALID_HANDLE;
      g_sym[i].hTrend.hADX    = INVALID_HANDLE;
      g_sym[i].hTrend.hBB     = INVALID_HANDLE;
      count += 3;

      // Signal TF (H1) — Full set + ADX + BB
      g_sym[i].hSignal.hEMA21  = iMA(sym, InpTF_Signal, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hSignal.hEMA50  = iMA(sym, InpTF_Signal, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hSignal.hEMA200 = iMA(sym, InpTF_Signal, InpEMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hSignal.hRSI    = iRSI(sym, InpTF_Signal, InpRSI_Period, PRICE_CLOSE);
      g_sym[i].hSignal.hATR    = iATR(sym, InpTF_Signal, InpATR_Period);
      g_sym[i].hSignal.hMACD   = iMACD(sym, InpTF_Signal, 12, 26, 9, PRICE_CLOSE);
      g_sym[i].hSignal.hADX    = iADX(sym, InpTF_Signal, InpADX_Period);
      g_sym[i].hSignal.hBB     = InpUseBBSqueeze ? iBands(sym, InpTF_Signal, InpBB_Period, 0, InpBB_Dev, PRICE_CLOSE) : INVALID_HANDLE;
      count += (InpUseBBSqueeze ? 8 : 7);

      // Entry TF (M15) — Confirmation
      g_sym[i].hEntry.hEMA21  = iMA(sym, InpTF_Entry, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      g_sym[i].hEntry.hEMA50  = INVALID_HANDLE;
      g_sym[i].hEntry.hEMA200 = INVALID_HANDLE;
      g_sym[i].hEntry.hRSI    = iRSI(sym, InpTF_Entry, InpRSI_Period, PRICE_CLOSE);
      g_sym[i].hEntry.hATR    = iATR(sym, InpTF_Entry, InpATR_Period);
      g_sym[i].hEntry.hMACD   = INVALID_HANDLE;
      g_sym[i].hEntry.hADX    = INVALID_HANDLE;
      g_sym[i].hEntry.hBB     = INVALID_HANDLE;
      count += 3;

      // Validate critical handles
      if(g_sym[i].hSignal.hRSI == INVALID_HANDLE ||
         g_sym[i].hSignal.hATR == INVALID_HANDLE ||
         g_sym[i].hSignal.hEMA21 == INVALID_HANDLE ||
         g_sym[i].hD1.hATR == INVALID_HANDLE)
      {
         Print("[SNIPERv8.2] CRITICAL handle failed: ", sym, " — deactivated");
         g_sym[i].active = false;
      }
      // Warn if BB handle failed — regime detection degrades to 2-regime (TRENDING/RANGING only)
      if(InpUseBBSqueeze && g_sym[i].hSignal.hBB == INVALID_HANDLE)
         Print("[SNIPERv8.2] WARNING: BB handle failed for ", sym, " — VOLATILE/QUIET regimes disabled for this symbol");
   }
   Print("[SNIPERv8.2] Handles created: ", count);
   return true;
}

void ReleaseHandle(int &h) { if(h != INVALID_HANDLE) { IndicatorRelease(h); h = INVALID_HANDLE; } }

void ReleaseAllHandles()
{
   for(int i = 0; i < g_symCount; i++)
   {
      ReleaseHandle(g_sym[i].hD1.hEMA21);  ReleaseHandle(g_sym[i].hD1.hEMA50);
      ReleaseHandle(g_sym[i].hD1.hEMA200); ReleaseHandle(g_sym[i].hD1.hATR);
      ReleaseHandle(g_sym[i].hTrend.hEMA21);  ReleaseHandle(g_sym[i].hTrend.hEMA50);
      ReleaseHandle(g_sym[i].hTrend.hEMA200);
      ReleaseHandle(g_sym[i].hSignal.hEMA21);  ReleaseHandle(g_sym[i].hSignal.hEMA50);
      ReleaseHandle(g_sym[i].hSignal.hEMA200); ReleaseHandle(g_sym[i].hSignal.hRSI);
      ReleaseHandle(g_sym[i].hSignal.hATR);    ReleaseHandle(g_sym[i].hSignal.hMACD);
      ReleaseHandle(g_sym[i].hSignal.hADX);   ReleaseHandle(g_sym[i].hSignal.hBB);
      ReleaseHandle(g_sym[i].hEntry.hEMA21);   ReleaseHandle(g_sym[i].hEntry.hRSI);
      ReleaseHandle(g_sym[i].hEntry.hATR);
   }
}

//+------------------------------------------------------------------+
//| BUFFER HELPERS                                                    |
//+------------------------------------------------------------------+
bool LoadBuf(int handle, int count, double &buf[])
{
   if(handle == INVALID_HANDLE) return false;
   ArraySetAsSeries(buf, true);
   return (CopyBuffer(handle, 0, 0, count, buf) >= count);
}

bool LoadBufN(int handle, int bufIdx, int count, double &buf[])
{
   if(handle == INVALID_HANDLE) return false;
   ArraySetAsSeries(buf, true);
   return (CopyBuffer(handle, bufIdx, 0, count, buf) >= count);
}

//+------------------------------------------------------------------+
//| SCAN SYMBOL — 21 weighted confluences, parallel BUY/SELL         |
//| D1 macro trend | ADX + Volume + Session + News + Correlation     |
//| v6: SFP + ROC + BB Squeeze + Fibo + TF Align + Dynamic Score    |
//+------------------------------------------------------------------+
void ScanSymbol(int idx)
{
   string sym = g_sym[idx].name;

   //=== LOAD D1 INDICATORS (Macro trend) ===
   double d1EMA21[], d1EMA50[], d1EMA200[], d1ATR[];
   if(!LoadBuf(g_sym[idx].hD1.hEMA21,  5, d1EMA21))  return;
   if(!LoadBuf(g_sym[idx].hD1.hEMA50,  5, d1EMA50))  return;
   if(!LoadBuf(g_sym[idx].hD1.hEMA200, 5, d1EMA200)) return;
   if(!LoadBuf(g_sym[idx].hD1.hATR,    5, d1ATR))    return;

   //=== LOAD TREND TF INDICATORS ===
   double tEMA21[], tEMA50[], tEMA200[];
   if(!LoadBuf(g_sym[idx].hTrend.hEMA21,  5, tEMA21))  return;
   if(!LoadBuf(g_sym[idx].hTrend.hEMA50,  5, tEMA50))  return;
   if(!LoadBuf(g_sym[idx].hTrend.hEMA200, 5, tEMA200)) return;

   //=== LOAD SIGNAL TF INDICATORS ===
   double sEMA21[], sEMA50[], sEMA200[], sRSI[], sATR[], sMACD[], sMACDSig[], sADX[];
   if(!LoadBuf(g_sym[idx].hSignal.hEMA21,  5, sEMA21))       return;
   if(!LoadBuf(g_sym[idx].hSignal.hEMA50,  5, sEMA50))       return;
   if(!LoadBuf(g_sym[idx].hSignal.hEMA200, 5, sEMA200))      return;
   if(!LoadBufN(g_sym[idx].hSignal.hRSI, 0, 40, sRSI))      return;
   if(!LoadBufN(g_sym[idx].hSignal.hATR, 0, 60, sATR))       return;
   if(!LoadBufN(g_sym[idx].hSignal.hMACD, 0, 40, sMACD))     return;
   if(!LoadBufN(g_sym[idx].hSignal.hMACD, 1, 40, sMACDSig))  return;

   //=== ADX — compute value (no standalone block) ===
   double adxVal = -1;   // [FIX] -1 = unavailable (distinct from 0 = genuinely no trend)
   if(LoadBufN(g_sym[idx].hSignal.hADX, 0, 5, sADX))
      adxVal = sADX[1];  // bar[1] = completed bar (0+ = real value)

   //=== ATR Z-SCORE — compute value (no standalone block) ===
   double atrZScore = 1.0;
   if(InpUseZScore && ArraySize(sATR) >= 52)
   {
      double atrMean = 0, atrStd = 0;
      int atrN = 50;
      for(int a = 1; a <= atrN; a++) atrMean += sATR[a];
      atrMean /= atrN;
      for(int a = 1; a <= atrN; a++) atrStd += (sATR[a] - atrMean) * (sATR[a] - atrMean);
      atrStd = MathSqrt(atrStd / atrN);
      if(atrStd > 0) atrZScore = (sATR[1] - atrMean) / atrStd;
   }

   //=== v6: LOAD BOLLINGER BANDS (signal TF) ===
   double bbUpper[], bbLower[], bbMiddle[];
   bool hasBB = false;
   if(InpUseBBSqueeze && g_sym[idx].hSignal.hBB != INVALID_HANDLE)
   {
      if(LoadBufN(g_sym[idx].hSignal.hBB, 0, 60, bbMiddle) &&
         LoadBufN(g_sym[idx].hSignal.hBB, 1, 60, bbUpper) &&
         LoadBufN(g_sym[idx].hSignal.hBB, 2, 60, bbLower))
         hasBB = true;
   }

   //=== LOAD ENTRY TF INDICATORS ===
   double eEMA21[], eRSI[], eATR[];
   if(!LoadBuf(g_sym[idx].hEntry.hEMA21, 5, eEMA21))     return;
   if(!LoadBufN(g_sym[idx].hEntry.hRSI, 0, 5, eRSI))     return;
   if(!LoadBufN(g_sym[idx].hEntry.hATR, 0, 5, eATR))      return;

   //=== LOAD PRICE DATA ===
   MqlRates d1Rates[], tRates[], sRates[], eRates[];
   if(CopyRates(sym, PERIOD_D1,     0, 30, d1Rates) < 10)               return;
   if(CopyRates(sym, InpTF_Trend,   0, 50, tRates) < 20)                return;
   if(CopyRates(sym, InpTF_Signal,  0, InpStructureBars + 50, sRates) < InpStructureBars) return;
   if(CopyRates(sym, InpTF_Entry,   0, 50, eRates) < 20)                return;
   ArraySetAsSeries(d1Rates, true);
   ArraySetAsSeries(tRates, true);
   ArraySetAsSeries(sRates, true);
   ArraySetAsSeries(eRates, true);

   double curPrice = sRates[1].close;  // [FUSION] bar[1] = confirmed closed bar
   double curATR   = sATR[1];   // [FIX] bar[1] confirmed, was bar[0]
   double entATR   = eATR[1];   // [FIX] bar[1] confirmed, was bar[0]
   if(curATR <= 0 || entATR <= 0) return;

   //=== PRE-CALCULATIONS ===
   SwingPoint swings[];
   FindSwingPoints(sRates, InpSwingLookback, InpStructureBars, swings);

   SRLevel srLevels[];
   int srCount = CalcSRLevels(d1Rates, tRates, sRates, curATR, d1ATR[1], curPrice, srLevels);
   // [PhD] Calculate S/R statistical significance (touch/respect ratio)
   CalcSRSignificance(srLevels, srCount, sRates, curATR);

   //=== MULTI-TF TREND (D1 + H4 + H1) ===
   int trendD1 = GetTrend(d1EMA21, d1EMA50, d1EMA200);
   int trendH4 = GetTrend(tEMA21, tEMA50, tEMA200);
   int trendH1 = (sEMA21[1] > sEMA50[1]) ? 1 : (sEMA21[1] < sEMA50[1]) ? -1 : 0; // [FUSION] bar[1]
   int mktStruct = AnalyzeStructure(tRates, 20);

   //=== COMPUTE all volatility metrics (no standalone blocks) ===
   double hurstVal = CalcHurstExponent(sRates, 60);
   double atrPctRank = CalcATRPercentileRank(sATR, 100);
   double rocVal = 0;
   if(InpUseROC && ArraySize(sRates) > InpROC_Period + 2)
   {
      double rocBase = sRates[1 + InpROC_Period].close;
      if(rocBase > 0) rocVal = (sRates[1].close - rocBase) / rocBase * 100.0;
   }

   //=== [v8] ADVANCED REGIME DETECTION — after Hurst/ATR available ===
   // Compute BB Width ratio (current vs 50-bar average)
   double bbwRatio = 1.0;
   bool hasBBRatio = false;
   if(hasBB && ArraySize(bbUpper) >= 52 && ArraySize(bbLower) >= 52 && ArraySize(bbMiddle) >= 52)
   {
      double curBBW = 0;
      if(bbMiddle[1] > 0) curBBW = (bbUpper[1] - bbLower[1]) / bbMiddle[1];
      double avgBBW = 0;
      int bbCount = 0;
      for(int bw = 2; bw < 50; bw++)
      {
         if(bbMiddle[bw] > 0)
         {
            avgBBW += (bbUpper[bw] - bbLower[bw]) / bbMiddle[bw];
            bbCount++;
         }
      }
      if(bbCount > 0) avgBBW /= bbCount;
      if(avgBBW > 0) { bbwRatio = curBBW / avgBBW; hasBBRatio = true; }
   }
   // ATR ratio (current vs 50-bar average)
   double atrRatio = 1.0;
   if(ArraySize(sATR) >= 52)
   {
      double avgATR = 0;
      for(int ar = 2; ar <= 50; ar++) avgATR += sATR[ar];
      avgATR /= 49.0;
      if(avgATR > 0) atrRatio = sATR[1] / avgATR;
   }
   // [FIX] BB fallback: if BB unavailable, derive bbwRatio from ATR ratio
   // ATR ratio is always available and correlates with BB width (~0.85 correlation)
   // This ensures VOLATILE/QUIET regimes remain detectable even without BB
   if(!hasBBRatio && atrRatio != 1.0)
   {
      bbwRatio = atrRatio;
   }
   // Detect regime with hysteresis
   ENUM_MARKET_REGIME regime = DetectRegimeAdvanced(idx, adxVal, hurstVal, bbwRatio, atrRatio);

   //=== MARKET TRADABILITY SCORE (MTS) — ONE composite check replaces 5 separate blocks ===
   // Avoids the over-filtering trap: each filter alone is good, but stacking 5 kills frequency
   double mts = 0;
   // ADX: optimal trending range InpADX_Min-50 → 30 points
   // [FIX] adxVal == -1 means handle unavailable → 15 partial credit (don't penalize broker issues)
   // adxVal == 0 means genuinely flat market → 0 points (no free credit for dead markets)
   if(adxVal > InpADX_Min && adxVal <= 50.0) mts += 30.0;       // optimal trending range
   else if(adxVal > 50.0) mts += 20.0;                         // [FIX] strong trend: tradable but overextension risk
   else if(adxVal < 0) mts += 15.0;                             // handle unavailable: partial credit
   else if(adxVal > InpADX_Min * 0.75) mts += 15.0;             // borderline: partial credit
   // ATR Percentile: healthy 20-85% → 30 points
   if(atrPctRank > 20.0 && atrPctRank < 85.0) mts += 30.0;
   else if(atrPctRank > 10.0 && atrPctRank < 95.0) mts += 15.0; // marginal but tradable
   // ROC: market actually moving → 20 points
   if(MathAbs(rocVal) >= InpROC_Min) mts += 20.0;
   else if(MathAbs(rocVal) >= InpROC_Min * 0.5) mts += 10.0;
   // Hurst: clear regime (trending or mean-reverting, not random) → 20 points
   if(hurstVal > 0.60 || hurstVal < 0.40) mts += 20.0;       // clear regime
   else if(hurstVal > 0.55 || hurstVal < 0.45) mts += 10.0;  // borderline but usable

   if(mts < InpMTS_Min)
   {
      Print("[SNIPERv8.2] MTS BLOCK: ", g_sym[idx].baseName,
            " MTS=", DoubleToString(mts, 0), "/100 (min ", DoubleToString(InpMTS_Min, 0), ")",
            " ADX=", DoubleToString(adxVal, 0),
            " Pctl=", DoubleToString(atrPctRank, 0), "%",
            " H=", DoubleToString(hurstVal, 2),
            " ROC=", DoubleToString(rocVal, 3), "%");
      g_signalsBlockedToday++;
      return;
   }

   //=================================================================
   // PARALLEL CONFLUENCE SCORING — BUY and SELL independently
   //=================================================================
   int buyScore = 0, sellScore = 0;
   string buyConf = "", sellConf = "";
   ENUM_SETUP_TYPE buyTrig = SETUP_NONE, sellTrig = SETUP_NONE;
   int buyTrigW = 0, sellTrigW = 0;
   double buySL_struct = 0, sellSL_struct = 0;

   //--- 1. MACRO TREND D1+H4 [+2 full, +1 half-credit]
   bool d1Bull = (trendD1 == 1);
   bool d1Bear = (trendD1 == -1);
   bool h4Bull = (trendH4 == 1 || mktStruct == 1);
   bool h4Bear = (trendH4 == -1 || mktStruct == -1);

   if(d1Bull && h4Bull)
   {
      buyScore += W_MACRO_TREND;
      buyConf += "D1+H4 trend bull\n";
   }
   else if(h4Bull)
   {
      buyScore += 1;  // half credit
      buyConf += TFStr(InpTF_Trend) + " trend bull (D1 neutral)\n";
   }

   if(d1Bear && h4Bear)
   {
      sellScore += W_MACRO_TREND;
      sellConf += "D1+H4 trend bear\n";
   }
   else if(h4Bear)
   {
      sellScore += 1;  // half credit
      sellConf += TFStr(InpTF_Trend) + " trend bear (D1 neutral)\n";
   }

   //--- 2. EMA ALIGNMENT signal TF [+1] — [FUSION] bar[1] confirmed
   if(sEMA21[1] > sEMA50[1] && curPrice > sEMA200[1])
   {
      buyScore += W_EMA_ALIGN;
      buyConf += "EMAs aligned bull (" + TFStr(InpTF_Signal) + ")\n";
   }
   if(sEMA21[1] < sEMA50[1] && curPrice < sEMA200[1])
   {
      sellScore += W_EMA_ALIGN;
      sellConf += "EMAs aligned bear (" + TFStr(InpTF_Signal) + ")\n";
   }

   //--- 3. EMA CROSS [+1] — [FUSION] bar[1] vs bar[2]
   if(InpStr_EMACross)
   {
      if(sEMA21[2] <= sEMA50[2] && sEMA21[1] > sEMA50[1])
      {
         buyScore += W_EMA_CROSS;
         buyConf += "EMA " + IntegerToString(InpEMA_Fast) + "/" + IntegerToString(InpEMA_Slow) + " cross bull\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_EMA_CROSS, W_EMA_CROSS);
      }
      if(sEMA21[2] >= sEMA50[2] && sEMA21[1] < sEMA50[1])
      {
         sellScore += W_EMA_CROSS;
         sellConf += "EMA " + IntegerToString(InpEMA_Fast) + "/" + IntegerToString(InpEMA_Slow) + " cross bear\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_EMA_CROSS, W_EMA_CROSS);
      }
   }

   //--- 4. BREAK OF STRUCTURE [+2] — with breakout confirmation v6
   if(InpStr_BOS)
   {
      int bos = DetectBOS(sRates, swings);
      if(bos > 0)
      {
         bool bosConf = (!InpBreakoutConfirm || IsBreakoutConfirmed(sRates, 1));
         int bosW = bosConf ? W_BOS : 1;
         buyScore += bosW;
         buyConf += "Break of Structure UP" + (bosConf ? " (confirmed)" : " (weak)") + "\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_BOS, bosW);
      }
      if(bos < 0)
      {
         bool bosConf = (!InpBreakoutConfirm || IsBreakoutConfirmed(sRates, -1));
         int bosW = bosConf ? W_BOS : 1;
         sellScore += bosW;
         sellConf += "Break of Structure DOWN" + (bosConf ? " (confirmed)" : " (weak)") + "\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_BOS, bosW);
      }
   }

   //--- 5. S/R BREAKOUT [+2] — with breakout confirmation v6
   if(InpStr_SRBreakout)
   {
      int brk = DetectSRBreakout(sRates, srLevels, srCount, curATR);
      if(brk > 0)
      {
         bool brkConf = (!InpBreakoutConfirm || IsBreakoutConfirmed(sRates, 1));
         int brkW = brkConf ? W_SR_BREAKOUT : 1;
         buyScore += brkW;
         buyConf += "S/R Breakout bull" + (brkConf ? " (confirmed)" : " (weak)") + "\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_SR_BREAKOUT, brkW);
      }
      if(brk < 0)
      {
         bool brkConf = (!InpBreakoutConfirm || IsBreakoutConfirmed(sRates, -1));
         int brkW = brkConf ? W_SR_BREAKOUT : 1;
         sellScore += brkW;
         sellConf += "S/R Breakout bear" + (brkConf ? " (confirmed)" : " (weak)") + "\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_SR_BREAKOUT, brkW);
      }
   }

   //--- 6. SUPPLY/DEMAND ZONE [+1]
   if(InpStr_SupplyDemand)
   {
      int sdZone = CheckSDZone(eRates, entATR, eRates[1].close); // [FIX] M15 entry TF, was H1
      if(sdZone > 0)
      {
         buyScore += W_SD_ZONE;
         buyConf += "At Demand Zone\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_SD_ZONE, W_SD_ZONE);
      }
      if(sdZone < 0)
      {
         sellScore += W_SD_ZONE;
         sellConf += "At Supply Zone\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_SD_ZONE, W_SD_ZONE);
      }
   }

   //--- 7. ORDER BLOCK [+1]
   double obLo = 0, obHi = 0;
   if(InpStr_OrderBlock)
   {
      int ob = DetectOrderBlock(eRates, entATR, obLo, obHi);
      if(ob > 0)
      {
         buyScore += W_ORDER_BLOCK;
         buyConf += "Bullish Order Block\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_ORDER_BLOCK, W_ORDER_BLOCK);
         buySL_struct = obLo;
      }
      if(ob < 0)
      {
         sellScore += W_ORDER_BLOCK;
         sellConf += "Bearish Order Block\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_ORDER_BLOCK, W_ORDER_BLOCK);
         sellSL_struct = obHi;
      }
   }

   //--- 8. FAIR VALUE GAP [+1]
   if(InpStr_FVG)
   {
      double fvgLo = 0, fvgHi = 0;
      int fvg = DetectFVG(eRates, entATR, fvgLo, fvgHi);
      if(fvg > 0)
      {
         buyScore += W_FVG;
         buyConf += "Bullish FVG fill\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_FVG, W_FVG);
      }
      if(fvg < 0)
      {
         sellScore += W_FVG;
         sellConf += "Bearish FVG fill\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_FVG, W_FVG);
      }
   }

   //--- 9. LIQUIDITY SWEEP [+1]
   if(InpStr_LiqSweep)
   {
      int liq = DetectLiqSweep(eRates, entATR);
      if(liq > 0)
      {
         buyScore += W_LIQ_SWEEP;
         buyConf += "Liquidity sweep + rejection\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_LIQ_SWEEP, W_LIQ_SWEEP);
         buySL_struct = eRates[1].low;
      }
      if(liq < 0)
      {
         sellScore += W_LIQ_SWEEP;
         sellConf += "Liquidity sweep + rejection\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_LIQ_SWEEP, W_LIQ_SWEEP);
         sellSL_struct = eRates[1].high;
      }
   }

   //--- 10. RSI DIVERGENCE [+2]
   if(InpStr_RSIDiverg)
   {
      if(DetectDivergence(sRates, sRSI, true, InpDivergBars) && sRSI[1] < InpRSI_DivBull)
      {
         buyScore += W_RSI_DIV;
         buyConf += "RSI Divergence bull (RSI=" + DoubleToString(sRSI[1], 0) + ")\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_RSI_DIV, W_RSI_DIV);
      }
      if(DetectDivergence(sRates, sRSI, false, InpDivergBars) && sRSI[1] > InpRSI_DivBear)
      {
         sellScore += W_RSI_DIV;
         sellConf += "RSI Divergence bear (RSI=" + DoubleToString(sRSI[1], 0) + ")\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_RSI_DIV, W_RSI_DIV);
      }
   }

   //--- 11. MACD DIVERGENCE [+1]
   if(InpStr_MACDDiverg)
   {
      double hist[];
      int histSz = MathMin(ArraySize(sMACD), ArraySize(sMACDSig));
      ArrayResize(hist, histSz);
      ArraySetAsSeries(hist, true);
      for(int h = 0; h < histSz; h++) hist[h] = sMACD[h] - sMACDSig[h];

      if(DetectDivergence(sRates, hist, true, InpDivergBars))
      {
         buyScore += W_MACD_DIV;
         buyConf += "MACD Divergence bull\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_MACD_DIV, W_MACD_DIV);
      }
      if(DetectDivergence(sRates, hist, false, InpDivergBars))
      {
         sellScore += W_MACD_DIV;
         sellConf += "MACD Divergence bear\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_MACD_DIV, W_MACD_DIV);
      }
   }

   //--- 12. CANDLESTICK PATTERN at key level [+1]
   if(InpStr_CandlePat)
   {
      int candle = DetectCandlePattern(eRates);
      if(candle != 0)
      {
         bool atLevel = false;
         for(int s = 0; s < srCount; s++)
         {
            if(MathAbs(curPrice - srLevels[s].price) < curATR * 1.0)
            { atLevel = true; break; }
         }
         if(atLevel)
         {
            if(candle > 0)
            {
               buyScore += W_CANDLE;
               buyConf += "Bullish candle at key level\n";
               SetTrigger(buyTrig, buyTrigW, SETUP_CANDLE, W_CANDLE);
            }
            if(candle < 0)
            {
               sellScore += W_CANDLE;
               sellConf += "Bearish candle at key level\n";
               SetTrigger(sellTrig, sellTrigW, SETUP_CANDLE, W_CANDLE);
            }
         }
      }
   }

   //--- 13. NEAR S/R LEVEL [+1] — DIRECTIONAL v6: support=BUY, resistance=SELL
   bool srBuyAdded = false, srSellAdded = false;
   for(int s = 0; s < srCount; s++)
   {
      double dist = MathAbs(curPrice - srLevels[s].price);
      if(dist < curATR * 0.5)
      {
         bool isAbove = (curPrice > srLevels[s].price); // level below = support
         string srInfo = srLevels[s].source + " (" + DoubleToString(srLevels[s].price, g_sym[idx].digits) + ")";

         if(!srBuyAdded)
         {
            if(isAbove) // Level is below price = support → good for BUY
            { buyScore += W_SR_LEVEL; buyConf += "Support: " + srInfo + "\n"; }
            else // Level above = resistance → bad for BUY, noted only
            { buyConf += "! Resistance above: " + srInfo + "\n"; }
            srBuyAdded = true;
         }
         if(!srSellAdded)
         {
            if(!isAbove) // Level is above price = resistance → good for SELL
            { sellScore += W_SR_LEVEL; sellConf += "Resistance: " + srInfo + "\n"; }
            else // Level below = support → bad for SELL, noted only
            { sellConf += "! Support below: " + srInfo + "\n"; }
            srSellAdded = true;
         }
         if(srBuyAdded && srSellAdded) break;
      }
   }

   //--- 14. ENTRY TF CONFIRMATION [+1]
   if(eRSI[1] < InpRSI_EntryBullHi && eRSI[1] > InpRSI_EntryBullLo && eRates[1].close > eEMA21[1])
   {
      buyScore += W_ENTRY_CONFIRM;
      buyConf += TFStr(InpTF_Entry) + " RSI+EMA confirm bull\n";
   }
   if(eRSI[1] > InpRSI_EntryBearLo && eRSI[1] < InpRSI_EntryBearHi && eRates[1].close < eEMA21[1])
   {
      sellScore += W_ENTRY_CONFIRM;
      sellConf += TFStr(InpTF_Entry) + " RSI+EMA confirm bear\n";
   }

   //--- 15. VOLUME + ACCUMULATION CONTEXT [+1] — v6 enhanced
   if(InpUseVolume && ArraySize(sRates) > 22)
   {
      double avgVol = 0;
      for(int v = 2; v < 22; v++) avgVol += (double)sRates[v].tick_volume;
      avgVol /= 20.0;
      if(avgVol > 0)
      {
         bool currentSpike = ((double)sRates[1].tick_volume / avgVol >= InpVolSpikeMult);
         // Count recent high-volume bars (accumulation context)
         int highVolBars = 0;
         for(int v = 2; v < 22; v++)
         {
            if((double)sRates[v].tick_volume > avgVol * 1.3) highVolBars++;
         }
         bool accumContext = (highVolBars >= 3);

         if(currentSpike && accumContext) // Spike WITH accumulation = strong
         {
            if(sRates[1].close > sRates[1].open)
            {
               buyScore += W_VOLUME;
               buyConf += "Volume + accumulation (" + IntegerToString((int)sRates[1].tick_volume) + ")\n";
            }
            if(sRates[1].close < sRates[1].open)
            {
               sellScore += W_VOLUME;
               sellConf += "Volume + accumulation (" + IntegerToString((int)sRates[1].tick_volume) + ")\n";
            }
         }
      }
   }

   //--- 16. SESSION — hard block during dead sessions, threshold ease during active
   int sessType = 0; // 1=active, -1=dead, 0=neutral
   {
      datetime gmtSess = TimeGMT();
      MqlDateTime dtSess;
      TimeToStruct(gmtSess, dtSess);
      int sessHour = dtSess.hour;
      if((sessHour >= 7 && sessHour <= 9) || (sessHour >= 13 && sessHour <= 16))
         sessType = 1;  // London/NY active
      else if((sessHour >= 0 && sessHour <= 3) || (sessHour >= 21 && sessHour <= 23))
         sessType = -1; // Dead session → HARD BLOCK below
   }

   //--- 17. MOMENTUM ROC [+1] — [FUSION] uses pre-computed rocVal (hard-blocked if too low)
   if(InpUseROC && MathAbs(rocVal) >= InpROC_Min)
   {
      if(rocVal > InpROC_Min)
      { buyScore += W_ROC; buyConf += "Momentum ROC +" + DoubleToString(rocVal, 2) + "%\n"; }
      if(rocVal < -InpROC_Min)
      { sellScore += W_ROC; sellConf += "Momentum ROC " + DoubleToString(rocVal, 2) + "%\n"; }
   }

   //--- 18. BOLLINGER BAND SQUEEZE BREAKOUT [+1] — v6
   if(InpUseBBSqueeze && hasBB && ArraySize(bbUpper) >= 52)
   {
      double curWidth = 0;
      if(bbMiddle[1] > 0) curWidth = (bbUpper[1] - bbLower[1]) / bbMiddle[1];
      double minWidth = curWidth;
      for(int b = 2; b < 50; b++)
      {
         double w = 0;
         if(bbMiddle[b] > 0) w = (bbUpper[b] - bbLower[b]) / bbMiddle[b];
         if(w > 0 && w < minWidth) minWidth = w;
      }
      bool squeeze = (minWidth > 0 && curWidth <= minWidth * 1.2);
      if(squeeze)
      {
         if(sRates[1].close > bbUpper[1])
         { buyScore += W_BB_SQUEEZE; buyConf += "BB squeeze breakout ^\n"; }
         if(sRates[1].close < bbLower[1])
         { sellScore += W_BB_SQUEEZE; sellConf += "BB squeeze breakout v\n"; }
      }
   }

   //--- 19. FIBONACCI CONFLUENCE [+1] — v6
   if(InpUseFibo)
   {
      int fiboDir = CheckFiboLevel(curPrice, swings, curATR);
      if(fiboDir > 0)
      { buyScore += W_FIBO; buyConf += "Near Fibonacci level (buy zone)\n"; }
      if(fiboDir < 0)
      { sellScore += W_FIBO; sellConf += "Near Fibonacci level (sell zone)\n"; }
   }

   //--- 20. SWING FAILURE PATTERN [+2/-2] — [FUSION] strict + penalize opposite + SETUP_SFP
   if(InpSFPFilter)
   {
      int sfp = DetectSFP(sRates, swings, curATR);
      if(sfp > 0)  // Bullish SFP: failed breakdown → buy
      {
         buyScore += W_SFP;
         buyConf += "Swing Failure Pattern (bullish)\n";
         SetTrigger(buyTrig, buyTrigW, SETUP_SFP, W_SFP); // [FUSION] SFP as primary setup
         // Penalize bearish breakout signals (they're likely fakeouts)
         if(sellTrig == SETUP_SR_BREAKOUT || sellTrig == SETUP_BOS)
         { sellScore -= W_SFP; sellConf += "! SFP invalidates bear breakout\n"; }
      }
      if(sfp < 0)  // Bearish SFP: failed breakout → sell
      {
         sellScore += W_SFP;
         sellConf += "Swing Failure Pattern (bearish)\n";
         SetTrigger(sellTrig, sellTrigW, SETUP_SFP, W_SFP); // [FUSION] SFP as primary setup
         // Penalize bullish breakout signals
         if(buyTrig == SETUP_SR_BREAKOUT || buyTrig == SETUP_BOS)
         { buyScore -= W_SFP; buyConf += "! SFP invalidates bull breakout\n"; }
      }
   }

   //--- 21. [v8] REGIME-STRATEGY FIT [+1/-1] — boost/penalize based on regime match
   if(InpUseRegime)
   {
      // TRENDING regime: boost breakout strategies, penalize reversal
      if(regime == REGIME_TRENDING)
      {
         if(buyTrig == SETUP_BOS || buyTrig == SETUP_SR_BREAKOUT || buyTrig == SETUP_EMA_CROSS)
         { buyScore += W_REGIME; buyConf += "Regime fit: TRENDING + breakout\n"; }
         if(sellTrig == SETUP_BOS || sellTrig == SETUP_SR_BREAKOUT || sellTrig == SETUP_EMA_CROSS)
         { sellScore += W_REGIME; sellConf += "Regime fit: TRENDING + breakout\n"; }
         // Penalize divergence/reversal setups in strong trend
         if(buyTrig == SETUP_RSI_DIV || buyTrig == SETUP_MACD_DIV)
         { buyScore -= 1; buyConf += "! Regime mismatch: reversal in TRENDING -1\n"; }
         if(sellTrig == SETUP_RSI_DIV || sellTrig == SETUP_MACD_DIV)
         { sellScore -= 1; sellConf += "! Regime mismatch: reversal in TRENDING -1\n"; }
      }
      // RANGING regime: boost reversal strategies, penalize breakout
      else if(regime == REGIME_RANGING)
      {
         if(buyTrig == SETUP_RSI_DIV || buyTrig == SETUP_MACD_DIV || buyTrig == SETUP_ORDER_BLOCK || buyTrig == SETUP_FVG)
         { buyScore += W_REGIME; buyConf += "Regime fit: RANGING + reversal\n"; }
         if(sellTrig == SETUP_RSI_DIV || sellTrig == SETUP_MACD_DIV || sellTrig == SETUP_ORDER_BLOCK || sellTrig == SETUP_FVG)
         { sellScore += W_REGIME; sellConf += "Regime fit: RANGING + reversal\n"; }
         // Penalize breakout setups in range
         if(buyTrig == SETUP_SR_BREAKOUT || buyTrig == SETUP_BOS)
         { buyScore -= 1; buyConf += "! Regime mismatch: breakout in RANGING -1\n"; }
         if(sellTrig == SETUP_SR_BREAKOUT || sellTrig == SETUP_BOS)
         { sellScore -= 1; sellConf += "! Regime mismatch: breakout in RANGING -1\n"; }
      }
      // VOLATILE and QUIET: no strategy bonus, handled via dynMinScore threshold
   }

   //--- 22. [v8] TICK DELTA PRESSURE [+1] — confirms direction from bid/ask movement
   double tickDeltaVal = 0.0;
   if(InpUseTickDelta)
   {
      tickDeltaVal = GetTickDelta(sym, 0);
      if(tickDeltaVal > InpTickDeltaMin)
      {
         buyScore += W_TICK_DELTA;
         buyConf += "Tick delta buy pressure +" + DoubleToString(tickDeltaVal, 2) + "\n";
      }
      if(tickDeltaVal < -InpTickDeltaMin)
      {
         sellScore += W_TICK_DELTA;
         sellConf += "Tick delta sell pressure " + DoubleToString(tickDeltaVal, 2) + "\n";
      }
   }

   //=================================================================
   // COUNTER-TREND PENALTY — penalize signals against D1 macro trend
   //=================================================================
   if(trendD1 == -1 && buyScore > 0)
   {
      buyScore -= InpCounterPenalty;
      if(buyScore > 0) buyConf += "⚠ Counter-trend penalty -" + IntegerToString(InpCounterPenalty) + " (D1 bearish)\n";
   }
   if(trendD1 == 1 && sellScore > 0)
   {
      sellScore -= InpCounterPenalty;
      if(sellScore > 0) sellConf += "⚠ Counter-trend penalty -" + IntegerToString(InpCounterPenalty) + " (D1 bullish)\n";
   }

   // [FIX] Floor scores at 0 — negative scores are semantically meaningless
   if(buyScore < 0) buyScore = 0;
   if(sellScore < 0) sellScore = 0;

   // H4 hard block: applied below, after direction decision, before TF coherence
   // TF coherence (D1=40% H4=35% H1=25%) adds further weighted filtering below.

   //=================================================================
   // DECISION — best side wins + v6 smart filters
   //=================================================================

   // v6: Dynamic minimum score (context-aware)
   int dynMinScore = InpMinScore;
   if(InpDynScore)
   {
      datetime gmtDec = TimeGMT();
      MqlDateTime dtDec;
      TimeToStruct(gmtDec, dtDec);
      // Check if best side is counter-trend
      bool bestIsBuy = (buyScore > sellScore);
      bool isCT = (bestIsBuy && trendD1 == -1) || (!bestIsBuy && trendD1 == 1);
      dynMinScore = GetDynamicMinScore(InpMinScore, isCT, dtDec.hour, dtDec.day_of_week);
   }
   // Session hard block: dead sessions (0-3, 21-23 UTC) = no signals at all
   if(InpSessionFilter && sessType == -1)
   {
      Print("[SNIPERv8.2] SESSION HARD BLOCK: ", g_sym[idx].baseName, " dead session (",
            TimeToString(TimeGMT(), TIME_MINUTES), " UTC)");
      g_signalsBlockedToday++;
      return;
   }
   // [FIX] Session reduction REMOVED — was letting marginal score 7 signals through as score 6
   // Active session no longer lowers the bar

   // [v8] Regime threshold modifier — NOT a hard block, just requires more confluence
   if(InpUseRegime)
   {
      if(regime == REGIME_VOLATILE)  dynMinScore += 2;  // Volatile: require +2 (risky conditions)
      if(regime == REGIME_QUIET)     dynMinScore += 3;  // Quiet: require +3 (dead market, most signals fail)
   }

   ENUM_SIGNAL_DIR direction = DIR_NONE;
   int finalScore = 0;
   string finalConf = "";
   ENUM_SETUP_TYPE finalSetup = SETUP_NONE;
   double structSL = 0;

   if(buyScore >= dynMinScore && buyScore > sellScore)
   {
      direction  = DIR_BUY;
      finalScore = buyScore;
      finalConf  = buyConf;
      finalSetup = (buyTrig != SETUP_NONE) ? buyTrig : SETUP_MULTI;
      structSL   = buySL_struct;
   }
   else if(sellScore >= dynMinScore && sellScore > buyScore)
   {
      direction  = DIR_SELL;
      finalScore = sellScore;
      finalConf  = sellConf;
      finalSetup = (sellTrig != SETUP_NONE) ? sellTrig : SETUP_MULTI;
      structSL   = sellSL_struct;
   }
   else return;

   // [v8.2] H4 HARD BLOCK — if enabled, reject signals against H4 trend
   if(InpRequireH4Align)
   {
      bool h4Against = (direction == DIR_BUY && trendH4 == -1) ||
                       (direction == DIR_SELL && trendH4 == 1);
      if(h4Against)
      {
         Print("[SNIPERv8.2] H4 HARD BLOCK: ", g_sym[idx].baseName, " ",
               (direction == DIR_BUY ? "BUY" : "SELL"), " vs H4=",
               (trendH4 == 1 ? "BULL" : "BEAR"));
         g_signalsBlockedToday++;
         return;
      }
   }

   // [PhD] WEIGHTED TF COHERENCE — D1=40% H4=35% H1=25%
   if(InpTFAlignFilter)
   {
      int dir = (direction == DIR_BUY) ? 1 : -1;
      double coherence = CalcTFCoherence(trendD1, trendH4, trendH1, dir);
      if(coherence < InpTFCoherenceMin)
      {
         Print("[SNIPERv8.2] TF COHERENCE BLOCK: ", g_sym[idx].baseName, " ", (dir > 0 ? "BUY" : "SELL"),
               " coherence=", DoubleToString(coherence, 1), "% < ", DoubleToString(InpTFCoherenceMin, 0), "%");
         return;
      }
   }

   // [PhD] HURST ADAPTIVE BONUS — boost setups that match market regime
   if(hurstVal > 0.60)
   {
      // Trending market: boost breakout/trend setups
      if(finalSetup == SETUP_BOS || finalSetup == SETUP_SR_BREAKOUT)
      {
         finalScore += 2;
         finalConf += "Hurst trending +" + DoubleToString(hurstVal, 2) + " boost breakout +2\n";
      }
   }
   else if(hurstVal < 0.40)
   {
      // Mean-reverting market: boost reversal setups
      if(finalSetup == SETUP_RSI_DIV || finalSetup == SETUP_MACD_DIV ||
         finalSetup == SETUP_ORDER_BLOCK || finalSetup == SETUP_FVG)
      {
         finalScore += 2;
         finalConf += "Hurst mean-revert +" + DoubleToString(hurstVal, 2) + " boost reversal +2\n";
      }
   }

   // [PhD] BAYESIAN CONFIDENCE — auto-adjust score based on posterior win-rate
   if(finalSetup != SETUP_NONE && finalSetup != SETUP_MULTI)
   {
      int sIdx = (int)finalSetup;
      if(sIdx >= 0 && sIdx < 13 && g_bayesSetup[sIdx].n >= 10)
      {
         double post = BayesPosterior(finalSetup);
         if(post < 0.35)
         {
            finalScore -= 2;
            finalConf += "! Bayes -2 (WR=" + DoubleToString(post * 100, 0) + "% < 35%)\n";
         }
         else if(post > 0.70)
         {
            finalScore += 1;
            finalConf += "Bayes +1 (WR=" + DoubleToString(post * 100, 0) + "% > 70%)\n";
         }
         if(finalScore < 0) finalScore = 0;
      }
   }

   // [FIX v8.2] PRICE-POSITION FILTER — avoid chasing (buying top 25%, selling bottom 25%)
   // EXCEPTION: Breakout setups (BOS, SR_BREAKOUT, SFP) are EXEMPT — they occur at range
   // extremes by definition. Penalizing them is a logical contradiction.
   bool isBreakoutSetup = (finalSetup == SETUP_BOS || finalSetup == SETUP_SR_BREAKOUT || finalSetup == SETUP_SFP);
   if(ArraySize(sRates) > 21 && !isBreakoutSetup)
   {
      double high20 = sRates[1].high, low20 = sRates[1].low;
      for(int k = 2; k <= 20; k++)
      {
         if(sRates[k].high > high20) high20 = sRates[k].high;
         if(sRates[k].low < low20) low20 = sRates[k].low;
      }
      double range20 = high20 - low20;
      if(range20 > 0)
      {
         double pricePos = (curPrice - low20) / range20; // 0=bottom, 1=top
         if(direction == DIR_BUY && pricePos > 0.75)
         {
            finalScore -= 1;
            finalConf += "! Chasing penalty -1 (price at " + DoubleToString(pricePos * 100, 0) + "% of range)\n";
         }
         if(direction == DIR_SELL && pricePos < 0.25)
         {
            finalScore -= 1;
            finalConf += "! Chasing penalty -1 (price at " + DoubleToString(pricePos * 100, 0) + "% of range)\n";
         }
         if(finalScore < 0) finalScore = 0;
      }
   }

   // [FIX] LOW ATR PENALTY — if ATR-based SL < asset minimum, penalize score -1 instead of hard block
   // Rationale: hard block killed valid high-score winners (e.g. AUDUSD SFP score 9 full runner)
   {
      double _pip = g_sym[idx].pipSize;
      if(_pip > 0)
      {
         double atrSLPips = (entATR * InpSL_ATR_Multi) / _pip;
         double minSLPips = GetMinSLPips(idx);
         if(atrSLPips < minSLPips)
         {
            finalScore -= 1;
            finalConf += "! Low ATR penalty -1 (atr_sl=" + DoubleToString(atrSLPips, 1)
                         + "p < min=" + DoubleToString(minSLPips, 1) + "p)\n";
            if(finalScore < 0) finalScore = 0;
            Print("[SNIPERv8.2] LOW ATR PENALTY: ", g_sym[idx].baseName,
                  " atr_sl=", DoubleToString(atrSLPips, 1),
                  "p < min=", DoubleToString(minSLPips, 1), "p — score -1");
         }
      }
   }

   // Grade check
   ENUM_SETUP_GRADE grade = ScoreToGrade(finalScore);
   if(!ShouldSend(grade)) return;

   // Correlation filter — block too many signals from same currency family
   if(IsCorrelBlocked(g_sym[idx].baseName, direction)) return;

   // Build signal
   SignalResult sig;
   sig.symbol         = sym;
   sig.direction      = direction;
   sig.setupType      = finalSetup;
   sig.grade          = grade;
   sig.score          = finalScore;
   sig.confluences    = finalConf;
   sig.timeframe      = InpTF_Signal;
   sig.signalTime     = TimeCurrent();
   sig.entry          = NormalizeDouble(eRates[1].close, g_sym[idx].digits); // [FIX] M15 entry, was H1
   sig.trendD1        = trendD1;
   sig.trendH4        = trendH4;
   sig.trendH1        = trendH1;
   sig.adxValue       = adxVal;
   sig.regime         = regime;      // [FUSION]
   sig.atrZScore      = atrZScore;   // [FUSION]
   sig.rocValue       = rocVal;      // [FUSION]
   sig.hurstExp       = hurstVal;    // [PhD]
   sig.atrPctile      = atrPctRank;  // [PhD]
   sig.tickDelta      = tickDeltaVal; // [v8]

   // SL/TP
   CalcSLTP(idx, sig, curATR, entATR, eRates, structSL, srLevels, srCount);

   // R:R check
   if(sig.slPips <= 0) return;
   if(sig.tp1Pips / sig.slPips < InpMinRR) return;

   // Anti-spam
   if(IsDuplicate(idx, sig)) return;

   // SEND
   RecordAlert(idx, sig);
   RecordFamilySignal(g_sym[idx].baseName, direction);
   SendAlert(idx, sig);
}

//+------------------------------------------------------------------+
//| MULTI-TF TREND (uses bar[1] = completed bar)                     |
//+------------------------------------------------------------------+
int GetTrend(double &ema21[], double &ema50[], double &ema200[])
{
   // [FIX] Added slope verification: EMAs must be rising/falling, not just aligned
   // Full alignment: EMA21 > EMA50 > EMA200 AND both fast EMAs rising
   if(ArraySize(ema21) >= 3 && ArraySize(ema50) >= 3)
   {
      bool ema21Rising  = (ema21[1] > ema21[2]);
      bool ema21Falling = (ema21[1] < ema21[2]);
      bool ema50Rising  = (ema50[1] > ema50[2]);
      bool ema50Falling = (ema50[1] < ema50[2]);

      // Strong bullish: perfect alignment + rising EMAs
      if(ema21[1] > ema50[1] && ema50[1] > ema200[1] && ema21Rising && ema50Rising)
         return 1;
      // Strong bearish: perfect alignment + falling EMAs
      if(ema21[1] < ema50[1] && ema50[1] < ema200[1] && ema21Falling && ema50Falling)
         return -1;

      // Moderate: alignment without slope = weak trend, half credit
      // Not as reliable as slope-confirmed, but still directional
      if(ema21[1] > ema50[1] && ema50[1] > ema200[1]) return 1;  // aligned, no slope
      if(ema21[1] < ema50[1] && ema50[1] < ema200[1]) return -1; // aligned, no slope
   }

   // No 3-EMA alignment: return 0 = no clear trend
   return 0;
}

//+------------------------------------------------------------------+
//| MARKET STRUCTURE (HH/HL vs LH/LL counting)                       |
//+------------------------------------------------------------------+
int AnalyzeStructure(MqlRates &rates[], int lookback)
{
   // [REWRITE] Use real swing points instead of bar-by-bar comparison
   if(ArraySize(rates) < lookback + 1) return 0;

   // Find swings within the lookback window
   SwingPoint swgs[];
   FindSwingPoints(rates, 3, lookback, swgs);
   if(ArraySize(swgs) < 4) return 0;

   // Count HH/HL vs LH/LL from swing points
   int hh = 0, hl = 0, lh = 0, ll = 0;
   double prevHi = 0, prevLo = 0;
   for(int i = ArraySize(swgs) - 1; i >= 0; i--) // oldest to newest
   {
      if(swgs[i].isHigh)
      {
         if(prevHi > 0)
         { if(swgs[i].price > prevHi) hh++; else lh++; }
         prevHi = swgs[i].price;
      }
      else
      {
         if(prevLo > 0)
         { if(swgs[i].price > prevLo) hl++; else ll++; }
         prevLo = swgs[i].price;
      }
   }
   // Bullish structure: Higher Highs AND Higher Lows
   if(hh >= 2 && hl >= 1) return 1;
   // Bearish structure: Lower Lows AND Lower Highs
   if(ll >= 2 && lh >= 1) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| SWING POINT DETECTION                                             |
//+------------------------------------------------------------------+
void FindSwingPoints(MqlRates &rates[], int lookback, int maxBars, SwingPoint &swings[])
{
   ArrayResize(swings, 0);
   int barsToCheck = MathMin(maxBars, ArraySize(rates) - lookback);

   // [FIX] Calculate local ATR for significance filter (avoids micro-swing noise)
   double localATR = 0;
   int atrBars = MathMin(14, ArraySize(rates) - 1);
   if(atrBars > 0)
   {
      for(int a = 1; a <= atrBars; a++)
         localATR += rates[a].high - rates[a].low;
      localATR /= atrBars;
   }
   double minSwingSize = localATR * 0.3; // Swing must be at least 30% of ATR to be significant

   for(int i = lookback; i < barsToCheck; i++)
   {
      bool isHigh = true, isLow = true;
      for(int j = 1; j <= lookback; j++)
      {
         if(i - j < 0 || i + j >= ArraySize(rates)) { isHigh = false; isLow = false; break; }
         if(rates[i].high <= rates[i-j].high || rates[i].high <= rates[i+j].high) isHigh = false;
         if(rates[i].low >= rates[i-j].low || rates[i].low >= rates[i+j].low)     isLow = false;
      }

      // [FIX] Significance filter: swing must protrude from neighbors by min ATR fraction
      if(isHigh && minSwingSize > 0)
      {
         double prominence = rates[i].high - MathMax(
            MathMax(rates[i-1].high, rates[i+1].high),
            (i-2 >= 0 && i+2 < ArraySize(rates)) ? MathMax(rates[i-2].high, rates[i+2].high) : 0);
         if(prominence < minSwingSize) isHigh = false;
      }
      if(isLow && minSwingSize > 0)
      {
         double prominence = MathMin(
            MathMin(rates[i-1].low, rates[i+1].low),
            (i-2 >= 0 && i+2 < ArraySize(rates)) ? MathMin(rates[i-2].low, rates[i+2].low) : 99999999) - rates[i].low;
         if(prominence < minSwingSize) isLow = false;
      }

      // [FIX] If same bar is both high and low (outside bar), keep only the larger swing
      if(isHigh && isLow)
      {
         double hiDelta = rates[i].high - MathMax(rates[i-1].high, rates[i+1].high);
         double loDelta = MathMin(rates[i-1].low, rates[i+1].low) - rates[i].low;
         if(hiDelta >= loDelta) isLow = false; else isHigh = false;
      }

      if(isHigh)
      {
         int sz = ArraySize(swings);
         ArrayResize(swings, sz + 1);
         swings[sz].price    = rates[i].high;
         swings[sz].barIndex = i;
         swings[sz].isHigh   = true;
      }
      if(isLow)
      {
         int sz = ArraySize(swings);
         ArrayResize(swings, sz + 1);
         swings[sz].price    = rates[i].low;
         swings[sz].barIndex = i;
         swings[sz].isHigh   = false;
      }
   }
}

//+------------------------------------------------------------------+
//| BREAK OF STRUCTURE                                                |
//+------------------------------------------------------------------+
int DetectBOS(MqlRates &rates[], SwingPoint &swings[])
{
   // [REWRITE] Proper SMC BOS: needs HH/HL sequence (bullish) or LH/LL (bearish)
   // BOS bullish = price breaks above the last Higher High in an uptrend
   // BOS bearish = price breaks below the last Higher Low (structure shift)
   if(ArraySize(swings) < 4 || ArraySize(rates) < 3) return 0;

   // Collect the last 2 swing highs and 2 swing lows
   double swHi[2] = {0, 0}; // [0]=most recent, [1]=previous
   double swLo[2] = {0, 0};
   int hiCount = 0, loCount = 0;
   for(int i = 0; i < ArraySize(swings); i++)
   {
      if(swings[i].isHigh && hiCount < 2)
      { swHi[hiCount] = swings[i].price; hiCount++; }
      if(!swings[i].isHigh && loCount < 2)
      { swLo[loCount] = swings[i].price; loCount++; }
      if(hiCount >= 2 && loCount >= 2) break;
   }
   if(hiCount < 2 || loCount < 2) return 0;

   // Bullish BOS: price breaks above the last swing high
   // AND we have a Higher Low structure (recent low > previous low)
   bool hasHL = (swLo[0] > swLo[1]); // Higher Low = uptrend structure
   if(hasHL && swHi[0] > 0 && rates[1].close > swHi[0] && rates[2].close <= swHi[0])
   {
      // Confirm with body ratio (no doji breakouts)
      double body = MathAbs(rates[1].close - rates[1].open);
      double range = rates[1].high - rates[1].low;
      if(range > 0 && body / range > InpMinBodyRatio) return 1;
   }

   // Bearish BOS: price breaks below the last swing low
   // AND we have a Lower High structure (recent high < previous high)
   bool hasLH = (swHi[0] < swHi[1]); // Lower High = downtrend structure
   if(hasLH && swLo[0] > 0 && rates[1].close < swLo[0] && rates[2].close >= swLo[0])
   {
      double body = MathAbs(rates[1].close - rates[1].open);
      double range = rates[1].high - rates[1].low;
      if(range > 0 && body / range > InpMinBodyRatio) return -1;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| S/R LEVELS — D1 real bars + swing pivots + round levels          |
//+------------------------------------------------------------------+
int CalcSRLevels(MqlRates &d1[], MqlRates &tRates[], MqlRates &sRates[],
                 double sigATR, double d1ATR, double curPrice, SRLevel &levels[])
{
   ArrayResize(levels, 0);
   int count = 0;
   if(ArraySize(d1) < 6) return 0;

   // 1. Previous Day H/L — [FIX] use d1ATR for D1-scale merge threshold
   AddSR(levels, count, d1ATR, d1[1].high, 4, "PrevDay High");
   AddSR(levels, count, d1ATR, d1[1].low,  4, "PrevDay Low");

   // 2. Previous Day Open/Close
   AddSR(levels, count, d1ATR, d1[1].open,  2, "PrevDay Open");
   AddSR(levels, count, d1ATR, d1[1].close, 2, "PrevDay Close");

   // 3. Week H/L (5 D1 bars)
   double weekHi = d1[1].high, weekLo = d1[1].low;
   for(int i = 2; i <= 5 && i < ArraySize(d1); i++)
   {
      if(d1[i].high > weekHi) weekHi = d1[i].high;
      if(d1[i].low  < weekLo) weekLo = d1[i].low;
   }
   AddSR(levels, count, d1ATR, weekHi, 5, "Week High");
   AddSR(levels, count, d1ATR, weekLo, 5, "Week Low");

   // 4. 3-Day Range
   double d3Hi = d1[1].high, d3Lo = d1[1].low;
   for(int i = 2; i <= 3 && i < ArraySize(d1); i++)
   {
      if(d1[i].high > d3Hi) d3Hi = d1[i].high;
      if(d1[i].low  < d3Lo) d3Lo = d1[i].low;
   }
   if(MathAbs(d3Hi - weekHi) > d1ATR * 0.1)
      AddSR(levels, count, d1ATR, d3Hi, 3, "3Day High");
   if(MathAbs(d3Lo - weekLo) > d1ATR * 0.1)
      AddSR(levels, count, d1ATR, d3Lo, 3, "3Day Low");

   // 5. Monthly H/L (20 D1 bars)
   double mHi = d1[1].high, mLo = d1[1].low;
   for(int i = 2; i <= 20 && i < ArraySize(d1); i++)
   {
      if(d1[i].high > mHi) mHi = d1[i].high;
      if(d1[i].low  < mLo) mLo = d1[i].low;
   }
   if(MathAbs(mHi - weekHi) > d1ATR * 0.2)
      AddSR(levels, count, d1ATR, mHi, 5, "Monthly High");
   if(MathAbs(mLo - weekLo) > d1ATR * 0.2)
      AddSR(levels, count, d1ATR, mLo, 5, "Monthly Low");

   // 6. Trend TF swing pivots
   if(ArraySize(tRates) > 5)
   {
      for(int i = 2; i < ArraySize(tRates) - 1 && i < 20 && count < MAX_SR; i++)
      {
         if(tRates[i].high > tRates[i-1].high && tRates[i].high > tRates[i+1].high)
            AddSR(levels, count, sigATR, tRates[i].high, 2, TFStr(InpTF_Trend) + " Swing Hi");
         if(tRates[i].low < tRates[i-1].low && tRates[i].low < tRates[i+1].low)
            AddSR(levels, count, sigATR, tRates[i].low, 2, TFStr(InpTF_Trend) + " Swing Lo");
      }
   }

   // 7. Signal TF swing pivots (5-bar confirmation)
   for(int i = 2; i < ArraySize(sRates) - 2 && i < 30 && count < MAX_SR; i++)
   {
      if(sRates[i].high > sRates[i-1].high && sRates[i].high > sRates[i+1].high &&
         sRates[i].high > sRates[i-2].high && sRates[i].high > sRates[i+2].high)
         AddSR(levels, count, sigATR, sRates[i].high, 2, "Swing Hi");
      if(sRates[i].low < sRates[i-1].low && sRates[i].low < sRates[i+1].low &&
         sRates[i].low < sRates[i-2].low && sRates[i].low < sRates[i+2].low)
         AddSR(levels, count, sigATR, sRates[i].low, 2, "Swing Lo");
   }

   // 8. Round levels
   double roundStep = 0;
   if(d1ATR > 100)       roundStep = 1000;
   else if(d1ATR > 1)    roundStep = 100;
   else if(d1ATR > 0.01) roundStep = 0.01;
   else                   roundStep = 0.001;

   if(roundStep > 0)
   {
      double nearest = MathRound(curPrice / roundStep) * roundStep;
      if(MathAbs(curPrice - nearest) < d1ATR * 2)
         AddSR(levels, count, d1ATR, nearest, 1, "Round Level");
   }

   return count;
}

void AddSR(SRLevel &levels[], int &count, double atr, double price, int strength, string source)
{
   if(count >= MAX_SR) return;
   for(int i = 0; i < count; i++)
   {
      if(MathAbs(levels[i].price - price) < atr * 0.3)
      {
         // [FIX] Weighted average merge instead of keeping first price
         levels[i].price = (levels[i].price * levels[i].strength + price * strength) /
                           (levels[i].strength + strength);
         levels[i].strength += strength; // cumulative strength
         if(StringLen(source) > 0 && StringFind(levels[i].source, source) < 0)
            levels[i].source += "+" + source;
         return;
      }
   }
   ArrayResize(levels, count + 1);
   levels[count].price    = price;
   levels[count].strength = strength;
   levels[count].source   = source;
   levels[count].touches  = 0;
   levels[count].respects = 0;
   count++;
}

// [PhD] S/R STATISTICAL SIGNIFICANCE — count touches and respects
// A level touched 6 times and respected 5/6 is 3x more reliable than touched 2 times
void CalcSRSignificance(SRLevel &levels[], int count, MqlRates &rates[], double atr)
{
   int barsToCheck = MathMin(80, ArraySize(rates) - 1);
   double tolerance = atr * 0.3;

   for(int s = 0; s < count; s++)
   {
      int touches = 0, respects = 0;
      double lvl = levels[s].price;

      for(int i = 2; i < barsToCheck; i++)
      {
         // Price approached the level (within tolerance)
         bool approached = (MathAbs(rates[i].high - lvl) < tolerance) ||
                          (MathAbs(rates[i].low - lvl) < tolerance) ||
                          (rates[i].low < lvl && rates[i].high > lvl); // crossed through

         if(!approached) continue;
         touches++;

         // Did price respect the level? (closed on the approach side)
         bool closedAbove = (rates[i].close > lvl);
         bool closedBelow = (rates[i].close < lvl);
         bool previousAbove = (rates[i+1].close > lvl);

         // Respect = price touched the level and bounced back
         if(previousAbove && closedAbove) respects++; // support held
         else if(!previousAbove && closedBelow) respects++; // resistance held
      }
      levels[s].touches  = touches;
      levels[s].respects = respects;

      // Boost strength based on respect ratio
      if(touches >= 3)
      {
         double respectRatio = (double)respects / (double)touches;
         if(respectRatio > 0.75) levels[s].strength += 3; // very reliable
         else if(respectRatio > 0.60) levels[s].strength += 1;
         else if(respectRatio < 0.30) levels[s].strength = MathMax(1, levels[s].strength - 2); // unreliable
      }
   }
}

//+------------------------------------------------------------------+
//| S/R BREAKOUT                                                      |
//+------------------------------------------------------------------+
int DetectSRBreakout(MqlRates &rates[], SRLevel &srLevels[], int srCount, double atr)
{
   if(ArraySize(rates) < 4 || srCount == 0) return 0;

   // [FIX] Find the STRONGEST broken level, not just the first
   int bestDir = 0;
   int bestStrength = 0;

   for(int s = 0; s < srCount; s++)
   {
      double lvl = srLevels[s].price;

      // Bullish breakout: closed below, now closed above
      if(rates[2].close < lvl && rates[1].close > lvl)
      {
         double body = MathAbs(rates[1].close - rates[1].open);
         double range1 = rates[1].high - rates[1].low;
         // [FIX] Use InpMinBodyRatio (0.50) instead of hardcoded 0.35
         if(range1 > 0 && body > range1 * InpMinBodyRatio &&
            rates[1].close > rates[1].open) // must be bullish candle
         {
            if(srLevels[s].strength > bestStrength)
            { bestDir = 1; bestStrength = srLevels[s].strength; }
         }
      }
      // Bearish breakout: closed above, now closed below
      if(rates[2].close > lvl && rates[1].close < lvl)
      {
         double body = MathAbs(rates[1].close - rates[1].open);
         double range1 = rates[1].high - rates[1].low;
         if(range1 > 0 && body > range1 * InpMinBodyRatio &&
            rates[1].close < rates[1].open) // must be bearish candle
         {
            if(srLevels[s].strength > bestStrength)
            { bestDir = -1; bestStrength = srLevels[s].strength; }
         }
      }
   }
   return bestDir;
}

//+------------------------------------------------------------------+
//| SUPPLY/DEMAND ZONE with zone validity check                       |
//+------------------------------------------------------------------+
int CheckSDZone(MqlRates &rates[], double atr, double curPrice)
{
   double minMove = atr * InpSD_MinMoveATR;
   int barsToCheck = MathMin(InpSD_Lookback, ArraySize(rates) - 5);
   if(barsToCheck < 10) return 0;

   for(int i = 5; i < barsToCheck; i++)
   {
      double moveUp = rates[i-3].close - rates[i].open;
      if(moveUp > minMove)
      {
         double zTop = MathMax(rates[i].open, rates[i].close);
         double zLo  = rates[i].low;
         if(curPrice >= zLo - atr * 0.1 && curPrice <= zTop + atr * 0.3)
         {
            bool valid = true;
            for(int k = i - 1; k >= 1; k--)
               if(rates[k].close < zLo) { valid = false; break; }
            if(valid) return 1;
         }
      }

      double moveDn = rates[i].open - rates[i-3].close;
      if(moveDn > minMove)
      {
         double zLo  = MathMin(rates[i].open, rates[i].close);
         double zTop = rates[i].high;
         if(curPrice >= zLo - atr * 0.3 && curPrice <= zTop + atr * 0.1)
         {
            bool valid = true;
            for(int k = i - 1; k >= 1; k--)
               if(rates[k].close > zTop) { valid = false; break; }
            if(valid) return -1;
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| ORDER BLOCK                                                       |
//+------------------------------------------------------------------+
int DetectOrderBlock(MqlRates &rates[], double atr, double &zoneLo, double &zoneHi)
{
   if(ArraySize(rates) < 20) return 0;

   // [FIX] Bullish OB: last bearish candle before impulsive up move
   for(int i = 5; i < 40 && i < ArraySize(rates) - 1; i++)
   {
      if(rates[i].close >= rates[i].open) continue; // need bearish candle

      double moveUp = rates[i-3].close - rates[i].open;
      if(moveUp < atr * InpOB_MinMoveATR) continue;

      int bullBars = 0;
      for(int j = i - 3; j < i; j++)
         if(j >= 0 && rates[j].close > rates[j].open) bullBars++;
      if(bullBars < 2) continue;

      double obTop = rates[i].open;
      double obBot = rates[i].low;
      // [FIX] rates[0]→rates[1] = confirmed bar for retest check
      if(rates[1].low <= obTop && rates[1].close > obBot)
      {
         zoneLo = obBot; zoneHi = obTop;
         return 1;
      }
   }

   // [FIX] Bearish OB: last bullish candle before impulsive down move
   for(int i = 5; i < 40 && i < ArraySize(rates) - 1; i++)
   {
      if(rates[i].close <= rates[i].open) continue; // need bullish candle

      double moveDn = rates[i].open - rates[i-3].close;
      if(moveDn < atr * InpOB_MinMoveATR) continue;

      int bearBars = 0;
      for(int j = i - 3; j < i; j++)
         if(j >= 0 && rates[j].close < rates[j].open) bearBars++;
      if(bearBars < 2) continue;

      double obTop = rates[i].high;
      double obBot = rates[i].close;
      // [FIX] rates[0]→rates[1] = confirmed bar for retest check
      if(rates[1].high >= obBot && rates[1].close < obTop)
      {
         zoneLo = obBot; zoneHi = obTop;
         return -1;
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| FAIR VALUE GAP                                                    |
//+------------------------------------------------------------------+
int DetectFVG(MqlRates &rates[], double atr, double &gapLo, double &gapHi)
{
   if(ArraySize(rates) < 10) return 0;

   for(int i = 2; i < 15 && i + 2 < ArraySize(rates); i++)
   {
      // Bullish FVG: gap between candle[i+2].high and candle[i].low
      double gBot = rates[i+2].high;
      double gTop = rates[i].low;
      if(gTop > gBot && (gTop - gBot) > atr * 0.3)
      {
         // [FIX] Check if FVG already mitigated (filled by prior bars)
         bool mitigated = false;
         for(int k = 1; k < i; k++)
         { if(rates[k].low <= gBot) { mitigated = true; break; } }
         if(mitigated) continue;

         // [FIX] rates[0]→rates[1] = confirmed bar for retest
         if(rates[1].low <= gTop && rates[1].close >= gBot)
         { gapLo = gBot; gapHi = gTop; return 1; }
      }

      // Bearish FVG: gap between candle[i].high and candle[i+2].low
      gBot = rates[i].high;
      gTop = rates[i+2].low;
      if(gTop > gBot && (gTop - gBot) > atr * 0.3)
      {
         // [FIX] Check if FVG already mitigated
         bool mitigated = false;
         for(int k = 1; k < i; k++)
         { if(rates[k].high >= gTop) { mitigated = true; break; } }
         if(mitigated) continue;

         // [FIX] rates[0]→rates[1] = confirmed bar for retest
         if(rates[1].high >= gBot && rates[1].close <= gTop)
         { gapLo = gBot; gapHi = gTop; return -1; }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| LIQUIDITY SWEEP                                                   |
//+------------------------------------------------------------------+
int DetectLiqSweep(MqlRates &rates[], double atr)
{
   if(ArraySize(rates) < 10) return 0;

   for(int i = 2; i < 15 && i + 1 < ArraySize(rates); i++)
   {
      if(rates[i].low < rates[i-1].low && rates[i].low < rates[i+1].low)
      {
         if(rates[1].low < rates[i].low && rates[1].close > rates[i].low)
         {
            double wick = MathMin(rates[1].open, rates[1].close) - rates[1].low;
            double range = rates[1].high - rates[1].low;
            if(range > 0 && wick / range > 0.5) return 1;
         }
      }
      if(rates[i].high > rates[i-1].high && rates[i].high > rates[i+1].high)
      {
         if(rates[1].high > rates[i].high && rates[1].close < rates[i].high)
         {
            double wick = rates[1].high - MathMax(rates[1].open, rates[1].close);
            double range = rates[1].high - rates[1].low;
            if(range > 0 && wick / range > 0.5) return -1;
         }
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| GENERIC DIVERGENCE (RSI or MACD histogram)                       |
//| [v8.2] Adaptive magnitude: oscDiff < StdDev(osc) * 0.5          |
//|   RSI StdDev ~8-15 → threshold ~4-7.5 (was hardcoded 3.0)       |
//|   MACD hist StdDev ~0.0005 → threshold ~0.00025 (3.0 was wrong) |
//+------------------------------------------------------------------+
bool DetectDivergence(MqlRates &rates[], double &osc[], bool bullish, int lookback)
{
   int maxBars = MathMin(lookback, MathMin(ArraySize(rates), ArraySize(osc)) - 2);
   if(maxBars < 10) return false;

   // [v8.2] Compute StdDev of oscillator for adaptive magnitude threshold
   double oscMean = 0;
   int oscN = MathMin(maxBars, ArraySize(osc) - 1);
   for(int k = 1; k <= oscN; k++) oscMean += osc[k];
   oscMean /= oscN;
   double oscVar = 0;
   for(int k = 1; k <= oscN; k++) oscVar += (osc[k] - oscMean) * (osc[k] - oscMean);
   double oscStdDev = MathSqrt(oscVar / oscN);
   double minMagnitude = oscStdDev * 0.5; // adaptive threshold

   if(bullish)
   {
      // [FIX] Use 2-bar swing confirmation instead of 1-bar
      for(int a = 2; a < 8 && a + 2 < ArraySize(rates); a++)
      {
         if(!(rates[a].low < rates[a-1].low && rates[a].low < rates[a+1].low &&
              rates[a].low < rates[a-2].low && rates[a].low < rates[a+2].low)) continue;
         for(int b = a + 5; b < maxBars && b + 2 < ArraySize(rates); b++)
         {
            if(!(rates[b].low < rates[b-1].low && rates[b].low < rates[b+1].low &&
                 rates[b].low < rates[b-2].low && rates[b].low < rates[b+2].low)) continue;
            if(a < ArraySize(osc) && b < ArraySize(osc) &&
               rates[a].low < rates[b].low && osc[a] > osc[b])
            {
               double oscDiff = osc[a] - osc[b];
               if(oscDiff < minMagnitude) continue; // [v8.2] adaptive magnitude
               // [PhD] Regression slope confirmation: price slope negative, osc slope positive
               int regLen = b - a + 1;
               if(regLen >= 4)
               {
                  double priceSeries[], oscSeries[];
                  ArrayResize(priceSeries, regLen);
                  ArrayResize(oscSeries, regLen);
                  for(int r = 0; r < regLen; r++)
                  {
                     priceSeries[r] = rates[a + r].low;
                     oscSeries[r] = osc[a + r];
                  }
                  double priceSlope = CalcLinRegSlope(priceSeries, 0, regLen);
                  double oscSlope = CalcLinRegSlope(oscSeries, 0, regLen);
                  // Bullish div: price going down (slope < 0) but osc going up (slope > 0)
                  // Note: series is bar[a]..bar[b], a=recent, b=older (series-as-series)
                  // So positive slope means values increase from recent→older = actually falling
                  // We need opposite slopes to confirm divergence
                  if(priceSlope * oscSlope >= 0) continue; // same direction = no real divergence
               }
               return true;
            }
         }
      }
   }
   else
   {
      for(int a = 2; a < 8 && a + 2 < ArraySize(rates); a++)
      {
         if(!(rates[a].high > rates[a-1].high && rates[a].high > rates[a+1].high &&
              rates[a].high > rates[a-2].high && rates[a].high > rates[a+2].high)) continue;
         for(int b = a + 5; b < maxBars && b + 2 < ArraySize(rates); b++)
         {
            if(!(rates[b].high > rates[b-1].high && rates[b].high > rates[b+1].high &&
                 rates[b].high > rates[b-2].high && rates[b].high > rates[b+2].high)) continue;
            if(a < ArraySize(osc) && b < ArraySize(osc) &&
               rates[a].high > rates[b].high && osc[a] < osc[b])
            {
               double oscDiff = osc[b] - osc[a];
               if(oscDiff < minMagnitude) continue; // [v8.2] adaptive magnitude
               // [PhD] Regression slope confirmation: price slope positive, osc slope negative
               int regLen = b - a + 1;
               if(regLen >= 4)
               {
                  double priceSeries[], oscSeries[];
                  ArrayResize(priceSeries, regLen);
                  ArrayResize(oscSeries, regLen);
                  for(int r = 0; r < regLen; r++)
                  {
                     priceSeries[r] = rates[a + r].high;
                     oscSeries[r] = osc[a + r];
                  }
                  double priceSlope = CalcLinRegSlope(priceSeries, 0, regLen);
                  double oscSlope = CalcLinRegSlope(oscSeries, 0, regLen);
                  if(priceSlope * oscSlope >= 0) continue; // same direction = no divergence
               }
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| CANDLE PATTERNS (Engulfing, Pin Bar, Morning/Evening Star)       |
//+------------------------------------------------------------------+
int DetectCandlePattern(MqlRates &rates[])
{
   if(ArraySize(rates) < 4) return 0;

   double body1 = rates[1].close - rates[1].open;
   double body2 = rates[2].close - rates[2].open;
   double range1 = rates[1].high - rates[1].low;
   if(range1 <= 0) return 0;

   if(body2 < 0 && body1 > 0 && rates[1].close > rates[2].open && rates[1].open < rates[2].close)
      return 1;
   if(body2 > 0 && body1 < 0 && rates[1].open > rates[2].close && rates[1].close < rates[2].open)
      return -1;

   double lowerWick = MathMin(rates[1].close, rates[1].open) - rates[1].low;
   double upperWick = rates[1].high - MathMax(rates[1].close, rates[1].open);
   if(lowerWick > MathAbs(body1) * 2.0 && lowerWick > range1 * 0.6 && upperWick < MathAbs(body1) * 0.5)
      return 1;
   if(upperWick > MathAbs(body1) * 2.0 && upperWick > range1 * 0.6 && lowerWick < MathAbs(body1) * 0.5)
      return -1;

   double range2 = rates[2].high - rates[2].low;
   if(range2 > 0)
   {
      double body3 = rates[3].close - rates[3].open;
      if(body3 < 0 && MathAbs(body2) < range2 * 0.3 && body1 > 0)
      {
         if(rates[1].close > (rates[3].open + rates[3].close) / 2)
            return 1;
      }
      if(body3 > 0 && MathAbs(body2) < range2 * 0.3 && body1 < 0)
      {
         if(rates[1].close < (rates[3].open + rates[3].close) / 2)
            return -1;
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| FIND SWING for SL (extended 40-bar range, configurable lookback) |
//+------------------------------------------------------------------+
double FindLastSwingLow(MqlRates &rates[], int lookback)
{
   int maxBar = MathMin(40, ArraySize(rates) - lookback);
   for(int i = lookback; i < maxBar; i++)
   {
      bool isLow = true;
      for(int j = 1; j <= lookback && (i-j) >= 0 && (i+j) < ArraySize(rates); j++)
      {
         if(rates[i].low >= rates[i-j].low || rates[i].low >= rates[i+j].low)
         { isLow = false; break; }
      }
      if(isLow) return rates[i].low;
   }
   return 0;
}

double FindLastSwingHigh(MqlRates &rates[], int lookback)
{
   int maxBar = MathMin(40, ArraySize(rates) - lookback);
   for(int i = lookback; i < maxBar; i++)
   {
      bool isHigh = true;
      for(int j = 1; j <= lookback && (i-j) >= 0 && (i+j) < ArraySize(rates); j++)
      {
         if(rates[i].high <= rates[i-j].high || rates[i].high <= rates[i+j].high)
         { isHigh = false; break; }
      }
      if(isHigh) return rates[i].high;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| MINIMUM SL per instrument type (in pips)                          |
//+------------------------------------------------------------------+
double GetMinSLPips(int idx)
{
   string upper = g_sym[idx].name;
   StringToUpper(upper);
   if(StringFind(upper, "XAU") >= 0 || StringFind(upper, "GOLD") >= 0) return 50.0;
   if(StringFind(upper, "XAG") >= 0 || StringFind(upper, "SILVER") >= 0) return 30.0;
   if(StringFind(upper, "NAS") >= 0 || StringFind(upper, "US30") >= 0 ||
      StringFind(upper, "DJ30") >= 0 || StringFind(upper, "SP500") >= 0 ||
      StringFind(upper, "GER") >= 0 || StringFind(upper, "DAX") >= 0 ||
      StringFind(upper, "USTEC") >= 0) return 20.0;
   return MathMax(InpMinSL_Pips, 10.0);
}

//+------------------------------------------------------------------+
//| SL/TP — ATR + Swing + Structural + Min SL + Side Validation      |
//+------------------------------------------------------------------+
void CalcSLTP(int idx, SignalResult &sig, double sigATR, double entATR, MqlRates &eRates[], double structSL, SRLevel &srLevels[], int srCount)
{
   int d = g_sym[idx].digits;
   double pip = g_sym[idx].pipSize;
   if(pip <= 0) pip = g_sym[idx].point;
   if(pip <= 0) { Print("[SNIPERv8.2] ERROR: pip=0 for ", g_sym[idx].baseName); return; } // [FIX] div-by-zero guard
   double slDist = entATR * InpSL_ATR_Multi;
   double atrSL  = slDist;
   double minSLDist = MathMax(GetMinSLPips(idx) * pip, entATR * 0.75);

   if(sig.direction == DIR_BUY)
   {
      sig.sl = sig.entry - slDist;
      double swLow = FindLastSwingLow(eRates, InpSwingLookback);
      if(swLow > 0 && swLow < sig.entry)
      {
         double adj = swLow - entATR * 0.2;
         if(adj > sig.entry - slDist * 2.0 && (sig.entry - adj) >= minSLDist)
         { sig.sl = adj; slDist = sig.entry - sig.sl; }
      }
      if(structSL > 0 && structSL < sig.entry)
      {
         double adj = structSL - entATR * 0.2;
         if(adj > sig.entry - slDist * 2.0 && adj < sig.sl && (sig.entry - adj) >= minSLDist)
         { sig.sl = adj; slDist = sig.entry - sig.sl; }
      }
      if(slDist < minSLDist) { slDist = MathMax(atrSL, minSLDist); sig.sl = sig.entry - slDist; }
      if(slDist <= 0) slDist = entATR * 0.5;
      sig.tp1 = sig.entry + slDist * InpTP1_RR;
      sig.tp2 = sig.entry + slDist * InpTP2_RR;
      sig.tp3 = sig.entry + slDist * InpTP3_RR;
   }
   else
   {
      sig.sl = sig.entry + slDist;
      double swHigh = FindLastSwingHigh(eRates, InpSwingLookback);
      if(swHigh > 0 && swHigh > sig.entry)
      {
         double adj = swHigh + entATR * 0.2;
         if(adj < sig.entry + slDist * 2.0 && (adj - sig.entry) >= minSLDist)
         { sig.sl = adj; slDist = sig.sl - sig.entry; }
      }
      if(structSL > 0 && structSL > sig.entry)
      {
         double adj = structSL + entATR * 0.2;
         if(adj < sig.entry + slDist * 2.0 && adj > sig.sl && (adj - sig.entry) >= minSLDist)
         { sig.sl = adj; slDist = sig.sl - sig.entry; }
      }
      if(slDist < minSLDist) { slDist = MathMax(atrSL, minSLDist); sig.sl = sig.entry + slDist; }
      if(slDist <= 0) slDist = entATR * 0.5;
      sig.tp1 = sig.entry - slDist * InpTP1_RR;
      sig.tp2 = sig.entry - slDist * InpTP2_RR;
      sig.tp3 = sig.entry - slDist * InpTP3_RR;
   }
   // SL SIDE VALIDATION
   if(sig.direction == DIR_BUY && sig.sl >= sig.entry)
   { sig.sl = sig.entry - MathMax(atrSL, minSLDist); slDist = sig.entry - sig.sl; }
   if(sig.direction == DIR_SELL && sig.sl <= sig.entry)
   { sig.sl = sig.entry + MathMax(atrSL, minSLDist); slDist = sig.sl - sig.entry; }
   // SANITY CHECK — max 5x signal ATR
   if(MathAbs(sig.entry - sig.sl) > sigATR * 5.0)
   {
      slDist = MathMax(atrSL, minSLDist);
      if(sig.direction == DIR_BUY) sig.sl = sig.entry - slDist;
      else sig.sl = sig.entry + slDist;
   }
   // Recalc TPs — first set RR-based fallbacks
   if(sig.direction == DIR_BUY)
   { slDist = sig.entry - sig.sl; sig.tp1 = sig.entry + slDist * InpTP1_RR; sig.tp2 = sig.entry + slDist * InpTP2_RR; sig.tp3 = sig.entry + slDist * InpTP3_RR; }
   else
   { slDist = sig.sl - sig.entry; sig.tp1 = sig.entry - slDist * InpTP1_RR; sig.tp2 = sig.entry - slDist * InpTP2_RR; sig.tp3 = sig.entry - slDist * InpTP3_RR; }

   // DYNAMIC S/R-BASED TPs — use real market structure instead of fixed RR multiples
   // S/R levels are more realistic targets: price is more likely to stall at a real level
   // than at an arbitrary 2:1 or 3:1 distance. RR-based TPs remain as fallback.
   if(srCount > 0 && slDist > 0)
   {
      double offset = entATR * 0.15; // Take profit slightly before S/R (don't wait for exact hit)
      int dMul = (sig.direction == DIR_BUY) ? 1 : -1;
      double minTP1 = slDist * MathMax(InpMinRR, InpTP1_RR * 0.7); // Min TP1 distance

      // Collect S/R distances in signal direction
      double tgtDist[];
      int tgtN = 0;
      for(int s = 0; s < srCount; s++)
      {
         if(srLevels[s].touches < 2) continue; // Need some significance
         double d = (sig.direction == DIR_BUY) ?
            (srLevels[s].price - sig.entry) : (sig.entry - srLevels[s].price);
         if(d < minTP1 || d > slDist * 8.0) continue; // Too close or too far
         ArrayResize(tgtDist, tgtN + 1);
         tgtDist[tgtN] = d;
         tgtN++;
      }
      // Sort ascending (closest first)
      for(int a = 0; a < tgtN - 1; a++)
         for(int b = a + 1; b < tgtN; b++)
            if(tgtDist[b] < tgtDist[a])
            { double t = tgtDist[a]; tgtDist[a] = tgtDist[b]; tgtDist[b] = t; }

      // Apply: S/R target with offset, only if meets minimum RR
      if(tgtN >= 1 && (tgtDist[0] - offset) >= minTP1)
         sig.tp1 = sig.entry + dMul * (tgtDist[0] - offset);
      if(tgtN >= 2)
         sig.tp2 = sig.entry + dMul * (tgtDist[1] - offset);
      if(tgtN >= 3)
         sig.tp3 = sig.entry + dMul * (tgtDist[2] - offset);
   }

   // [FIX] TP SPACING — ensure minimum gap between consecutive TPs (50% of SL distance)
   // Prevents TP2 ≈ TP1 or TP3 ≈ TP2 from near-duplicate S/R levels (e.g. GER40 TP2 < TP1)
   {
      double minTPGap = slDist * 0.5;
      if(sig.direction == DIR_BUY)
      {
         if(sig.tp2 - sig.tp1 < minTPGap) sig.tp2 = sig.tp1 + slDist;
         if(sig.tp3 - sig.tp2 < minTPGap) sig.tp3 = sig.tp2 + slDist;
      }
      else
      {
         if(sig.tp1 - sig.tp2 < minTPGap) sig.tp2 = sig.tp1 - slDist;
         if(sig.tp2 - sig.tp3 < minTPGap) sig.tp3 = sig.tp2 - slDist;
      }
   }

   sig.sl = NormalizeDouble(sig.sl, d); sig.tp1 = NormalizeDouble(sig.tp1, d);
   sig.tp2 = NormalizeDouble(sig.tp2, d); sig.tp3 = NormalizeDouble(sig.tp3, d);
   sig.slPips  = NormalizeDouble(MathAbs(sig.entry - sig.sl) / pip, 1);
   sig.tp1Pips = NormalizeDouble(MathAbs(sig.tp1 - sig.entry) / pip, 1);
   sig.tp2Pips = NormalizeDouble(MathAbs(sig.tp2 - sig.entry) / pip, 1);
   sig.tp3Pips = NormalizeDouble(MathAbs(sig.tp3 - sig.entry) / pip, 1);
}

//+------------------------------------------------------------------+
//| ANTI-SPAM — Differential cooldown                                 |
//+------------------------------------------------------------------+
bool IsDuplicate(int idx, SignalResult &sig)
{
   if(g_sym[idx].lastAlertTime == 0) return false;
   string newDir = (sig.direction == DIR_BUY) ? "BUY" : "SELL";
   int elapsed = (int)(TimeCurrent() - g_sym[idx].lastAlertTime);
   if(newDir == g_sym[idx].lastDir) { if(elapsed < InpCooldownMin * 60) return true; }
   else { if(elapsed < InpCooldownFlip * 60) return true; }
   string hash = sig.symbol + "_" + newDir;
   if(hash == g_sym[idx].lastAlertHash && elapsed < InpCooldownMin * 60) return true;
   return false;
}

void RecordAlert(int idx, SignalResult &sig)
{
   g_sym[idx].lastAlertTime = TimeCurrent();
   g_sym[idx].lastAlertHash = sig.symbol + "_" + (sig.direction == DIR_BUY ? "BUY" : "SELL");
   g_sym[idx].lastDir   = (sig.direction == DIR_BUY) ? "BUY" : "SELL";
   g_sym[idx].lastType  = SetupName(sig.setupType);
   g_sym[idx].lastTime  = sig.signalTime;
   g_sym[idx].lastScore = sig.score;
   g_alertsToday++;
   g_totalAlerts++;
}

//+------------------------------------------------------------------+
//| SEND ALERT — Telegram Markdown + backtick prices + timestamp     |
//+------------------------------------------------------------------+
void SendAlert(int idx, SignalResult &sig)
{
   if(InpTrackSignals) AddToTracker(idx, sig);
   int d = g_sym[idx].digits;
   string dir = (sig.direction == DIR_BUY) ? "BUY" : "SELL";
   string dirEmoji = (sig.direction == DIR_BUY) ? "🟢" : "🔴";
   string gradeStr = GradeLabel(sig.grade);
   string gEmoji = GradeEmoji(sig.grade);
   string tD1 = (sig.trendD1 == 1) ? "↑" : (sig.trendD1 == -1) ? "↓" : "→";
   string tH4 = (sig.trendH4 == 1) ? "↑" : (sig.trendH4 == -1) ? "↓" : "→";
   string tH1 = (sig.trendH1 == 1) ? "↑" : (sig.trendH1 == -1) ? "↓" : "→";

   string msg = "";
   msg += gEmoji + " *SIGNAL " + gradeStr + "* | " + g_sym[idx].baseName + " | " + dirEmoji + " " + dir + "\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "🎯 *" + SetupName(sig.setupType) + "* | " + TFStr(sig.timeframe) + "\n";
   msg += "⭐ Score: " + IntegerToString(sig.score) + "/29\n";
   string adxStr = (sig.adxValue >= 40) ? "🔥" : (sig.adxValue >= 25) ? "📈" : "📊";
   string adxDisplay = (sig.adxValue < 0) ? "N/A" : DoubleToString(sig.adxValue, 0);
   msg += "📈 Trend: D1" + tD1 + " " + TFStr(InpTF_Trend) + tH4 + " " + TFStr(InpTF_Signal) + tH1 +
          " | ADX:" + adxDisplay + adxStr + "\n";
   msg += RegimeEmoji(sig.regime) + " Regime: " + RegimeName(sig.regime) +
          " | Z:" + DoubleToString(sig.atrZScore, 2) +
          " | ROC:" + DoubleToString(sig.rocValue, 2) + "%\n";
   // [PhD] Hurst + ATR Percentile line
   string hurstLabel = (sig.hurstExp > 0.6) ? "TREND" : (sig.hurstExp < 0.4) ? "REVERT" : "MIXED";
   msg += "🧬 Hurst:" + DoubleToString(sig.hurstExp, 2) + " (" + hurstLabel + ")" +
          " | ATR Pctl:" + DoubleToString(sig.atrPctile, 0) + "%\n";
   // [v8] Tick delta pressure
   if(InpUseTickDelta && MathAbs(sig.tickDelta) > 0.01)
   {
      string tdEmoji = (sig.tickDelta > InpTickDeltaMin) ? "🟢" : (sig.tickDelta < -InpTickDeltaMin) ? "🔴" : "⚪";
      msg += tdEmoji + " TickDelta: " + DoubleToString(sig.tickDelta, 2) +
             (sig.tickDelta > 0 ? " (buy pressure)" : " (sell pressure)") + "\n";
   }
   // === POSITION SIZING ===
   if(InpShowLotSize && sig.slPips > 0)
   {
      double riskUSD = InpAccountBalance * InpRiskPercent / 100.0;
      double pipValue = 1.0; // default
      string sym = g_sym[idx].name;
      double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      if(tickSize > 0) pipValue = tickValue * (g_sym[idx].pipSize / tickSize);
      double lotSize = 0;
      if(pipValue > 0 && sig.slPips > 0)
         lotSize = riskUSD / (sig.slPips * pipValue);
      // Round to lot step
      if(lotStep > 0) lotSize = MathFloor(lotSize / lotStep) * lotStep;
      lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
      double potLoss = lotSize * sig.slPips * pipValue;
      double potTP1  = lotSize * sig.tp1Pips * pipValue;
      msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
      msg += "💰 *Position Sizing (" + DoubleToString(InpRiskPercent, 1) + "% risk):*\n";
      msg += "📐 Lot: `" + DoubleToString(lotSize, 2) + "` | Risk: $" + DoubleToString(potLoss, 0) + "\n";
      msg += "💵 TP1 profit: ~$" + DoubleToString(potTP1, 0) + "\n";
   }
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "📍 Entry: `" + DoubleToString(sig.entry, d) + "`\n";
   msg += "🛡 SL: `" + DoubleToString(sig.sl, d) + "` (-" + DoubleToString(sig.slPips, 1) + " pips)\n";
   double rr1 = (sig.slPips > 0) ? sig.tp1Pips / sig.slPips : InpTP1_RR;
   double rr2 = (sig.slPips > 0) ? sig.tp2Pips / sig.slPips : InpTP2_RR;
   double rr3 = (sig.slPips > 0) ? sig.tp3Pips / sig.slPips : InpTP3_RR;
   msg += "✅ TP1: `" + DoubleToString(sig.tp1, d) + "` (+" + DoubleToString(sig.tp1Pips, 1) + "p | " + DoubleToString(rr1, 1) + ":1)\n";
   msg += "✅ TP2: `" + DoubleToString(sig.tp2, d) + "` (+" + DoubleToString(sig.tp2Pips, 1) + "p | " + DoubleToString(rr2, 1) + ":1)\n";
   msg += "✅ TP3: `" + DoubleToString(sig.tp3, d) + "` (+" + DoubleToString(sig.tp3Pips, 1) + "p | " + DoubleToString(rr3, 1) + ":1)\n";
   // [v9] Pre-trade checklist for the trader
   msg += "📋 *Checklist:*\n";
   string ck1 = (sig.trendD1 == sig.direction || sig.trendH4 == sig.direction) ? "✅" : "⚠️";
   msg += ck1 + " H4 bias aligned\n";
   // Session quality check
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bool goodSession = (dt.hour >= 7 && dt.hour <= 16); // London+NY
   string ck2 = goodSession ? "✅" : "⚠️";
   msg += ck2 + " Active session (London/NY)\n";
   string ck3 = (sig.slPips > 0 && sig.tp1Pips / sig.slPips >= 2.0) ? "✅" : "⚠️";
   msg += ck3 + " R:R >= 2:1\n";
   string ck4 = (sig.score >= 12) ? "✅" : (sig.score >= 8) ? "🟡" : "⚠️";
   msg += ck4 + " Confluence score (" + IntegerToString(sig.score) + "/29)\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "📐 *Confluences (" + IntegerToString(sig.score) + "/29):*\n";
   msg += sig.confluences;
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "⏰ " + TimeToString(sig.signalTime, TIME_DATE | TIME_MINUTES) + " UTC\n";
   // [v9] Current spread info
   double askNow = SymbolInfoDouble(g_sym[idx].name, SYMBOL_ASK);
   double bidNow = SymbolInfoDouble(g_sym[idx].name, SYMBOL_BID);
   double spreadNow = (askNow - bidNow) / g_sym[idx].pipSize;
   msg += "📊 Spread: " + DoubleToString(spreadNow, 1) + " pips\n";
   msg += "_Market Sniper v8.2 REGIME | Scanner Only_";

   if(InpUseTelegram) SendTelegram(msg);
   WriteSignalToCSV(idx, sig);
   Alert("[SNIPERv8.2] ", dir, " ", sig.symbol, " Score:", sig.score);
   Print("[SNIPERv8.2] ALERT: ", dir, " ", sig.symbol, " ", SetupName(sig.setupType),
         " Score=", sig.score, " Regime=", RegimeName(sig.regime),
         " Delta=", DoubleToString(sig.tickDelta, 2));
}

//+------------------------------------------------------------------+
//| [Phase1] CSV SIGNAL LOGGER — append each signal to daily CSV     |
//| File: MQL5/Files/MarketSniper_Signals_YYYYMMDD.csv               |
//| Columns Result/HitTP1-3/HitSL/ExitPrice/ExitTime/PnL/Notes      |
//| are left EMPTY — to be filled manually or by future auto-tracker |
//+------------------------------------------------------------------+
void WriteSignalToCSV(int idx, SignalResult &sig)
{
   if(g_csvFileName == "") return;
   int fh = FileOpen(g_csvFileName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
   {
      Print("[Phase1] CSV write FAILED: ", GetLastError());
      return;
   }
   FileSeek(fh, 0, SEEK_END);
   g_csvSignalCount++;

   int d = g_sym[idx].digits;
   string dir = (sig.direction == DIR_BUY) ? "BUY" : "SELL";
   string grade = GradeLabel(sig.grade);
   double rr1 = (sig.slPips > 0) ? sig.tp1Pips / sig.slPips : 0;
   double rr2 = (sig.slPips > 0) ? sig.tp2Pips / sig.slPips : 0;
   double rr3 = (sig.slPips > 0) ? sig.tp3Pips / sig.slPips : 0;

   // [FIX] Capture live bid/ask for realistic entry price comparison
   double liveBid = SymbolInfoDouble(g_sym[idx].name, SYMBOL_BID);
   double liveAsk = SymbolInfoDouble(g_sym[idx].name, SYMBOL_ASK);
   double liveEntry = (sig.direction == DIR_BUY) ? liveAsk : liveBid; // buy at ask, sell at bid
   double slippagePips = 0;
   if(g_sym[idx].pipSize > 0)
      slippagePips = MathAbs(liveEntry - sig.entry) / g_sym[idx].pipSize;

   // Clean confluences for CSV (remove newlines → semicolons)
   string confClean = sig.confluences;
   StringReplace(confClean, "\n", "; ");
   StringReplace(confClean, ",", ";"); // avoid breaking CSV commas
   StringReplace(confClean, "✓ ", "");
   StringReplace(confClean, "✗ ", "");
   // Trim trailing separator
   if(StringLen(confClean) > 2 && StringSubstr(confClean, StringLen(confClean) - 2) == "; ")
      confClean = StringSubstr(confClean, 0, StringLen(confClean) - 2);

   FileWrite(fh,
      IntegerToString(g_csvSignalCount),                          // SignalID
      TimeToString(sig.signalTime, TIME_DATE | TIME_MINUTES),     // DateTime
      g_sym[idx].baseName,                                        // Symbol
      dir,                                                        // Direction
      SetupName(sig.setupType),                                   // Setup
      grade,                                                      // Grade
      IntegerToString(sig.score),                                 // Score
      DoubleToString(sig.entry, d),                               // Entry (bar[1].close)
      DoubleToString(liveEntry, d),                               // LiveEntry (actual bid/ask)
      DoubleToString(slippagePips, 1),                            // Slippage_Pips
      DoubleToString(sig.sl, d),                                  // SL
      DoubleToString(sig.tp1, d),                                 // TP1
      DoubleToString(sig.tp2, d),                                 // TP2
      DoubleToString(sig.tp3, d),                                 // TP3
      DoubleToString(sig.slPips, 1),                              // SL_Pips
      DoubleToString(sig.tp1Pips, 1),                             // TP1_Pips
      DoubleToString(sig.tp2Pips, 1),                             // TP2_Pips
      DoubleToString(sig.tp3Pips, 1),                             // TP3_Pips
      DoubleToString(rr1, 2),                                     // RR1
      DoubleToString(rr2, 2),                                     // RR2
      DoubleToString(rr3, 2),                                     // RR3
      IntegerToString(sig.trendD1),                               // TrendD1
      IntegerToString(sig.trendH4),                               // TrendH4
      IntegerToString(sig.trendH1),                               // TrendH1
      DoubleToString(sig.adxValue, 1),                            // ADX
      RegimeName(sig.regime),                                     // Regime
      DoubleToString(sig.atrZScore, 2),                           // ZScore
      DoubleToString(sig.rocValue, 2),                            // ROC
      DoubleToString(sig.hurstExp, 2),                            // Hurst
      DoubleToString(sig.atrPctile, 0),                           // ATRPctile
      DoubleToString(sig.tickDelta, 2),                           // TickDelta
      confClean,                                                  // Confluences
      "", "", "", "", "",                                         // Result, HitTP1, HitTP2, HitTP3, HitSL (MANUAL)
      "", "", "", "");                                            // ExitPrice, ExitTime, PnL_Pips, Notes (MANUAL)

   FileClose(fh);
   Print("[Phase1] Signal #", g_csvSignalCount, " logged: ", dir, " ", g_sym[idx].baseName,
         " Score=", sig.score, " → ", g_csvFileName);
}

//+------------------------------------------------------------------+
//| TELEGRAM — Markdown parse mode                                    |
//+------------------------------------------------------------------+
bool SendTelegram(string text)
{
   if(InpBotToken == "" || InpChatID == "") return false;

   // [FIX] Use POST instead of GET to avoid URL length limits on long messages
   string url = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";
   string payload = "chat_id=" + InpChatID + "&parse_mode=Markdown&text=";

   // [FIX] Proper URL encoding including parentheses and special chars
   string encoded = text;
   StringReplace(encoded, "%", "%25");
   StringReplace(encoded, "\n", "%0A");
   StringReplace(encoded, "\r", "");
   StringReplace(encoded, " ", "%20");
   StringReplace(encoded, "#", "%23");
   StringReplace(encoded, "&", "%26");
   StringReplace(encoded, "+", "%2B");
   StringReplace(encoded, "=", "%3D");
   StringReplace(encoded, "?", "%3F");
   StringReplace(encoded, "<", "%3C");
   StringReplace(encoded, ">", "%3E");
   StringReplace(encoded, "(", "%28");
   StringReplace(encoded, ")", "%29");
   StringReplace(encoded, "!", "%21");
   StringReplace(encoded, "'", "%27");
   payload += encoded;

   char data[];
   StringToCharArray(payload, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1); // remove null terminator

   char res[];
   string reqH = "Content-Type: application/x-www-form-urlencoded\r\n", resH;
   int code = WebRequest("POST", url, reqH, 5000, data, res, resH);
   if(code != 200) Print("[SNIPERv8.2] Telegram HTTP ", code);
   if(code == -1) Print("[SNIPERv8.2] Add https://api.telegram.org in MT5 Options");
   return (code == 200);
}

//+------------------------------------------------------------------+
//| TRACKER — Add signal                                              |
//+------------------------------------------------------------------+
void AddToTracker(int idx, SignalResult &sig)
{
   if(g_trackedCount >= InpMaxTracked) CleanupTracker();
   if(g_trackedCount >= InpMaxTracked) return;

   // [FIX] SANITY CHECK — reject signal if live price already violates SL
   // Prevents "0-minute SL hits" (e.g. XAGUSD entry 87.675, SL 87.055, but price already at 86.9)
   {
      double liveBidCheck = SymbolInfoDouble(sig.symbol, SYMBOL_BID);
      double liveAskCheck = SymbolInfoDouble(sig.symbol, SYMBOL_ASK);
      if(sig.direction == DIR_BUY && liveBidCheck > 0 && liveBidCheck <= sig.sl)
      {
         Print("[TRACKER] SANITY BLOCK: ", sig.symbol, " BUY — liveBid=",
               DoubleToString(liveBidCheck, g_sym[idx].digits),
               " already <= SL=", DoubleToString(sig.sl, g_sym[idx].digits),
               " — signal dead on arrival");
         return;
      }
      if(sig.direction == DIR_SELL && liveAskCheck > 0 && liveAskCheck >= sig.sl)
      {
         Print("[TRACKER] SANITY BLOCK: ", sig.symbol, " SELL — liveAsk=",
               DoubleToString(liveAskCheck, g_sym[idx].digits),
               " already >= SL=", DoubleToString(sig.sl, g_sym[idx].digits),
               " — signal dead on arrival");
         return;
      }
   }

   ArrayResize(g_tracked, g_trackedCount + 1);
   int t = g_trackedCount;
   g_tracked[t].symbol = sig.symbol; g_tracked[t].direction = sig.direction;
   g_tracked[t].setupType = sig.setupType; g_tracked[t].grade = sig.grade;
   g_tracked[t].score = sig.score; g_tracked[t].entry = sig.entry;
   // [FIX] Capture live bid/ask as realistic entry — accounts for spread + slippage vs bar[1].close
   double liveBid = SymbolInfoDouble(sig.symbol, SYMBOL_BID);
   double liveAsk = SymbolInfoDouble(sig.symbol, SYMBOL_ASK);
   g_tracked[t].liveEntry = (sig.direction == DIR_BUY) ? liveAsk : liveBid; // buy at ask, sell at bid
   g_tracked[t].sl = sig.sl; g_tracked[t].tp1 = sig.tp1;
   g_tracked[t].tp2 = sig.tp2; g_tracked[t].tp3 = sig.tp3;
   g_tracked[t].slPips = sig.slPips; g_tracked[t].tp1Pips = sig.tp1Pips;
   g_tracked[t].tp2Pips = sig.tp2Pips; g_tracked[t].tp3Pips = sig.tp3Pips;
   g_tracked[t].tp1Hit = false; g_tracked[t].tp2Hit = false;
   g_tracked[t].tp3Hit = false; g_tracked[t].slHit = false;
   g_tracked[t].closed = false; g_tracked[t].signalTime = sig.signalTime;
   g_tracked[t].closeTime = 0; g_tracked[t].closeReason = "";
   g_tracked[t].maxFavorable = 0; g_tracked[t].maxAdverse = 0;
   g_tracked[t].pipSize = g_sym[idx].pipSize; g_tracked[t].digits = g_sym[idx].digits;
   // Initialize trailing virtual SL
   g_tracked[t].virtualSL = sig.sl;
   g_tracked[t].movedToBE = false;
   g_tracked[t].movedToTP1 = false;
   g_trackedCount++;
   g_stats.totalSignals++;
   Print("[TRACKER] + ", sig.symbol, " ", (sig.direction == DIR_BUY ? "BUY" : "SELL"), " Active:", ActiveCount());
}

//+------------------------------------------------------------------+
//| TRACKER — Monitor all active signals                              |
//+------------------------------------------------------------------+
void CheckTrackedSignals()
{
   for(int i = 0; i < g_trackedCount; i++)
   {
      if(g_tracked[i].closed) continue;

      // Expire check
      if(TimeCurrent() - g_tracked[i].signalTime > InpTrackMaxHours * 3600)
      {
         string result = "";
         if(g_tracked[i].tp1Hit) result = "TP1";
         if(g_tracked[i].tp2Hit) result += (result != "" ? "+TP2" : "TP2");
         if(g_tracked[i].tp3Hit) result += (result != "" ? "+TP3" : "TP3");
         if(result == "") result = "No target";

         g_tracked[i].closed = true;
         g_tracked[i].closeTime = TimeCurrent();
         g_tracked[i].closeReason = "Expired";
         g_stats.expired++;

         // [FIX] Bayesian update for expired signals without any TP hit (= failed setup)
         if(!g_tracked[i].tp1Hit)
         {
            int sIdx = (int)g_tracked[i].setupType;
            if(sIdx >= 0 && sIdx < 13) g_stats.setupTotal[sIdx]++;
            BayesUpdate(g_tracked[i].setupType, false);
         }

         // [FIX] Account for remaining lot P/L on expiry (1/3 partial close model)
         // Lots already closed at TPs are accounted for. Remaining lots close at current price.
         double expBid = SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_BID);
         double expAsk = SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_ASK);
         double expPrice = (g_tracked[i].direction == DIR_BUY) ? expBid : expAsk;
         if(expPrice > 0 && g_tracked[i].pipSize > 0)
         {
            double expPnl = 0;
            if(g_tracked[i].direction == DIR_BUY) expPnl = (expPrice - g_tracked[i].entry) / g_tracked[i].pipSize;
            else expPnl = (g_tracked[i].entry - expPrice) / g_tracked[i].pipSize;
            // Remaining lots: 3/3 if no TP, 2/3 if TP1 only, 1/3 if TP1+TP2
            double remainLots = 1.0;
            if(g_tracked[i].tp1Hit) remainLots = 2.0 / 3.0;
            if(g_tracked[i].tp2Hit) remainLots = 1.0 / 3.0;
            if(g_tracked[i].tp3Hit) remainLots = 0;  // all closed already
            double expPips = expPnl * remainLots;
            if(expPips >= 0) g_stats.pipsWon += expPips;
            else             g_stats.pipsLost += MathAbs(expPips);
         }

         string dir = (g_tracked[i].direction == DIR_BUY) ? "BUY" : "SELL";
         string msg = "⏰ *EXPIRED* | " + g_tracked[i].symbol + " " + dir + "\n";
         msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
         msg += "🎯 " + SetupName(g_tracked[i].setupType) + " (Score " + IntegerToString(g_tracked[i].score) + ")\n";
         msg += "📊 Result: " + result + "\n";
         msg += "⏱ Duration: " + FormatElapsed(g_tracked[i].signalTime);
         if(InpUseTelegram) SendTelegram(msg);
         continue;
      }

      double bid = SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0) continue;

      double checkPrice = (g_tracked[i].direction == DIR_BUY) ? bid : ask;
      double pip = g_tracked[i].pipSize;
      if(pip <= 0) pip = SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_POINT);

      double pnlPips = 0;
      if(g_tracked[i].direction == DIR_BUY) pnlPips = (checkPrice - g_tracked[i].entry) / pip;
      else pnlPips = (g_tracked[i].entry - checkPrice) / pip;

      if(pnlPips > g_tracked[i].maxFavorable) g_tracked[i].maxFavorable = pnlPips;
      if(-pnlPips > g_tracked[i].maxAdverse)  g_tracked[i].maxAdverse = -pnlPips;

      //--- TRAILING VIRTUAL SL ---
      // After TP1 hit: move virtualSL to breakeven
      if(g_tracked[i].tp1Hit && !g_tracked[i].movedToBE)
      {
         g_tracked[i].virtualSL = g_tracked[i].entry;
         g_tracked[i].movedToBE = true;
         if(InpNotifyBE)
         {
            string dir2 = (g_tracked[i].direction == DIR_BUY) ? "BUY" : "SELL";
            string beMsg = "🔄 *SL -> BREAKEVEN* | " + g_tracked[i].symbol + " " + dir2 + "\n";
            beMsg += "📍 Entry: " + DoubleToString(g_tracked[i].entry, g_tracked[i].digits) + "\n";
            beMsg += "🛡 Virtual SL moved to entry";
            if(InpUseTelegram) SendTelegram(beMsg);
         }
      }
      // After TP2 hit: move virtualSL to TP1
      if(g_tracked[i].tp2Hit && !g_tracked[i].movedToTP1)
      {
         g_tracked[i].virtualSL = g_tracked[i].tp1;
         g_tracked[i].movedToTP1 = true;
         string dir2 = (g_tracked[i].direction == DIR_BUY) ? "BUY" : "SELL";
         string t1Msg = "🔄 *SL -> TP1* | " + g_tracked[i].symbol + " " + dir2 + "\n";
         t1Msg += "🛡 Virtual SL moved to TP1: " + DoubleToString(g_tracked[i].tp1, g_tracked[i].digits);
         if(InpUseTelegram) SendTelegram(t1Msg);
      }

      // [FIX] REAL Dynamic Trailing SL — trails at 50% of max favorable after TP1
      // Instead of just 2 discrete jumps, the SL follows the price dynamically
      if(g_tracked[i].movedToBE && pnlPips > g_tracked[i].tp1Pips * 1.5 && pip > 0)
      {
         double trailDist = g_tracked[i].maxFavorable * pip * 0.50; // 50% of max profit
         double newSL = 0;
         if(g_tracked[i].direction == DIR_BUY)
            newSL = g_tracked[i].entry + trailDist;
         else
            newSL = g_tracked[i].entry - trailDist;

         // Only move SL in the profitable direction (never backwards)
         bool shouldMove = false;
         if(g_tracked[i].direction == DIR_BUY && newSL > g_tracked[i].virtualSL)
            shouldMove = true;
         if(g_tracked[i].direction == DIR_SELL && newSL < g_tracked[i].virtualSL)
            shouldMove = true;

         if(shouldMove)
            g_tracked[i].virtualSL = NormalizeDouble(newSL, g_tracked[i].digits);
      }

      // TP1
      if(!g_tracked[i].tp1Hit)
      {
         bool hit = (g_tracked[i].direction == DIR_BUY && checkPrice >= g_tracked[i].tp1) ||
                    (g_tracked[i].direction == DIR_SELL && checkPrice <= g_tracked[i].tp1);
         if(hit)
         {
            g_tracked[i].tp1Hit = true;
            g_stats.tp1Wins++;
            g_consecLosses = 0; // v6: reset consecutive losses on win
            g_stats.pipsWon += g_tracked[i].tp1Pips / 3.0; // [FIX] 1/3 lot closes at TP1
            if(g_tracked[i].tp1Pips > g_stats.bestPips) g_stats.bestPips = g_tracked[i].tp1Pips;
            // [PhD] Bayesian + per-setup tracking
            int sIdx = (int)g_tracked[i].setupType;
            if(sIdx >= 0 && sIdx < 13) { g_stats.setupWins[sIdx]++; g_stats.setupTotal[sIdx]++; g_stats.setupPips[sIdx] += g_tracked[i].tp1Pips / 3.0; }
            BayesUpdate(g_tracked[i].setupType, true);
            if(InpNotifyTP1) SendTPNotif(i, 1);
            // [FIX] Immediately apply BE so SL check below uses updated level (was deferred to next tick)
            if(!g_tracked[i].movedToBE)
            {
               g_tracked[i].virtualSL = g_tracked[i].entry;
               g_tracked[i].movedToBE = true;
               if(InpNotifyBE)
               {
                  string dir2 = (g_tracked[i].direction == DIR_BUY) ? "BUY" : "SELL";
                  string beMsg = "🔄 *SL -> BREAKEVEN* | " + g_tracked[i].symbol + " " + dir2 + "\n";
                  beMsg += "📍 Entry: " + DoubleToString(g_tracked[i].entry, g_tracked[i].digits) + "\n";
                  beMsg += "🛡 Virtual SL moved to entry";
                  if(InpUseTelegram) SendTelegram(beMsg);
               }
            }
         }
      }

      // TP2
      if(!g_tracked[i].tp2Hit && g_tracked[i].tp1Hit)
      {
         bool hit = (g_tracked[i].direction == DIR_BUY && checkPrice >= g_tracked[i].tp2) ||
                    (g_tracked[i].direction == DIR_SELL && checkPrice <= g_tracked[i].tp2);
         if(hit)
         {
            g_tracked[i].tp2Hit = true;
            g_stats.tp2Wins++;
            // [FIX] 1/3 lot closes at TP2 — add TP2 distance weighted by lot fraction
            g_stats.pipsWon += g_tracked[i].tp2Pips / 3.0;
            if(g_tracked[i].tp2Pips > g_stats.bestPips) g_stats.bestPips = g_tracked[i].tp2Pips;
            if(InpNotifyTP2) SendTPNotif(i, 2);
         }
      }

      // TP3
      if(!g_tracked[i].tp3Hit && g_tracked[i].tp2Hit)
      {
         bool hit = (g_tracked[i].direction == DIR_BUY && checkPrice >= g_tracked[i].tp3) ||
                    (g_tracked[i].direction == DIR_SELL && checkPrice <= g_tracked[i].tp3);
         if(hit)
         {
            g_tracked[i].tp3Hit = true;
            g_tracked[i].closed = true;
            g_tracked[i].closeTime = TimeCurrent();
            g_tracked[i].closeReason = "TP3 Full Target";
            g_stats.tp3Wins++;
            // [FIX] 1/3 lot closes at TP3 — add TP3 distance weighted by lot fraction
            g_stats.pipsWon += g_tracked[i].tp3Pips / 3.0;
            if(g_tracked[i].tp3Pips > g_stats.bestPips) g_stats.bestPips = g_tracked[i].tp3Pips;
            if(InpNotifyTP3) SendTPNotif(i, 3);
         }
      }

      // SL / TRAILING VIRTUAL SL CHECK
      if(!g_tracked[i].slHit && !g_tracked[i].closed)
      {
         // [FIX] BE is now applied immediately when TP1 is hit (above), so no need to skip SL check

         double slCheck = g_tracked[i].virtualSL;  // Uses trailing SL (moved after TP hits)
         bool hit = (g_tracked[i].direction == DIR_BUY && checkPrice <= slCheck) ||
                    (g_tracked[i].direction == DIR_SELL && checkPrice >= slCheck);
         if(hit)
         {
            g_tracked[i].slHit = true;
            g_tracked[i].closed = true;
            g_tracked[i].closeTime = TimeCurrent();

            // Determine if it's a real SL loss or a protected exit
            if(g_tracked[i].movedToTP1)
            {
               // [FIX] Stopped at TP1 level — this is a WIN (locked profit), NOT breakeven
               g_tracked[i].closeReason = "Trail-TP1 (Profit)";
               // Don't increment breakevens — TP1+TP2 already counted as wins above
               // Don't add pips — already counted when TPs were hit
               string dir = (g_tracked[i].direction == DIR_BUY) ? "BUY" : "SELL";
               string msg = "🔒 *TRAIL STOP (TP1)* | " + g_tracked[i].symbol + " " + dir + "\n";
               msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
               msg += "✅ TP1+TP2 hit, SL trailed to TP1\n";
               msg += "💰 Locked: +" + DoubleToString(g_tracked[i].tp1Pips, 1) + " pips\n";
               msg += "⏱ Duration: " + FormatElapsed(g_tracked[i].signalTime) + "\n";
               msg += "🏔 Max: +" + DoubleToString(g_tracked[i].maxFavorable, 1) + " pips";
               if(InpUseTelegram) SendTelegram(msg);
            }
            else if(g_tracked[i].movedToBE)
            {
               // Stopped at breakeven — no loss
               g_tracked[i].closeReason = "Breakeven";
               g_stats.breakevens++;
               if(InpNotifyBE)
               {
                  string dir = (g_tracked[i].direction == DIR_BUY) ? "BUY" : "SELL";
                  string tpsHit = "TP1";
                  if(g_tracked[i].tp2Hit) tpsHit += "+TP2";
                  string msg = "⚪ *BREAKEVEN* | " + g_tracked[i].symbol + " " + dir + "\n";
                  msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
                  msg += "📍 Entry: " + DoubleToString(g_tracked[i].entry, g_tracked[i].digits) + "\n";
                  msg += "✅ " + tpsHit + " hit, then return to entry\n";
                  msg += "💰 Net: ~0 pips\n";
                  msg += "⏱ Duration: " + FormatElapsed(g_tracked[i].signalTime) + "\n";
                  msg += "🏔 Max: +" + DoubleToString(g_tracked[i].maxFavorable, 1) + " pips";
                  if(InpUseTelegram) SendTelegram(msg);
               }
            }
            else
            {
               // Real stop loss — actual loss
               g_tracked[i].closeReason = "Stop Loss";
               g_stats.slLosses++;
               g_consecLosses++; // v6: track consecutive losses
               g_stats.pipsLost += g_tracked[i].slPips;
               if(g_tracked[i].slPips > g_stats.worstPips) g_stats.worstPips = g_tracked[i].slPips;
               // [PhD] Per-setup tracking + Bayesian update on loss
               int sIdx = (int)g_tracked[i].setupType;
               if(sIdx >= 0 && sIdx < 13)
               {
                  g_stats.setupTotal[sIdx]++;
                  g_stats.setupPips[sIdx] -= g_tracked[i].slPips;
               }
               BayesUpdate(g_tracked[i].setupType, false);
               // [v9] Circuit breaker tracking
               g_dailySLHits++;
               g_dailyLossPips += g_tracked[i].slPips;
               if(InpCircuitBreaker && (g_dailySLHits >= InpMaxDailyLosses || g_dailyLossPips >= InpMaxDailyLossPips))
               {
                  g_circuitBroken = true;
                  string cbMsg = "🚨 *CIRCUIT BREAKER ACTIVATED*\n";
                  cbMsg += "Daily losses: " + IntegerToString(g_dailySLHits) + " SL hits (" + DoubleToString(g_dailyLossPips, 1) + " pips)\n";
                  cbMsg += "Scanning stopped until tomorrow. Take a break.";
                  if(InpUseTelegram) SendTelegram(cbMsg);
                  Print("[v9] CIRCUIT BREAKER: ", g_dailySLHits, " losses, ", DoubleToString(g_dailyLossPips, 1), " pips");
               }
               if(InpNotifySL) SendSLNotif(i);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| TRACKER — TP Notification with running stats                      |
//+------------------------------------------------------------------+
void SendTPNotif(int tIdx, int level)
{
   string dir = (g_tracked[tIdx].direction == DIR_BUY) ? "BUY" : "SELL";
   double tpPips = (level == 1) ? g_tracked[tIdx].tp1Pips : (level == 2) ? g_tracked[tIdx].tp2Pips : g_tracked[tIdx].tp3Pips;
   string tpName = "TP" + IntegerToString(level);
   string emoji = (level == 3) ? "💎" : (level == 2) ? "🎯" : "✅";

   string msg = emoji + " *" + tpName + " HIT* | " + g_tracked[tIdx].symbol + " " + dir + "\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "🎯 " + SetupName(g_tracked[tIdx].setupType) + " (Score " + IntegerToString(g_tracked[tIdx].score) + "/29)\n";
   msg += "📍 Entry: " + DoubleToString(g_tracked[tIdx].entry, g_tracked[tIdx].digits) + "\n";
   msg += "💰 " + tpName + ": +" + DoubleToString(tpPips, 1) + " pips\n";
   msg += "⏱ Duration: " + FormatElapsed(g_tracked[tIdx].signalTime) + "\n";
   msg += "🏔 Max: +" + DoubleToString(g_tracked[tIdx].maxFavorable, 1) + " pips\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += BuildRunningStats();
   if(InpUseTelegram) SendTelegram(msg);
   Print("[TRACKER] ", tpName, " HIT: ", g_tracked[tIdx].symbol, " +", DoubleToString(tpPips, 1), "p");
}

//+------------------------------------------------------------------+
//| TRACKER — SL Notification with running stats                      |
//+------------------------------------------------------------------+
void SendSLNotif(int tIdx)
{
   string dir = (g_tracked[tIdx].direction == DIR_BUY) ? "BUY" : "SELL";
   string msg = "🛑 *SL HIT* | " + g_tracked[tIdx].symbol + " " + dir + "\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "🎯 " + SetupName(g_tracked[tIdx].setupType) + " (Score " + IntegerToString(g_tracked[tIdx].score) + "/29)\n";
   msg += "📍 Entry: " + DoubleToString(g_tracked[tIdx].entry, g_tracked[tIdx].digits) + "\n";
   msg += "💔 SL: -" + DoubleToString(g_tracked[tIdx].slPips, 1) + " pips\n";
   msg += "⏱ Duration: " + FormatElapsed(g_tracked[tIdx].signalTime) + "\n";
   msg += "📉 Max DD: -" + DoubleToString(g_tracked[tIdx].maxAdverse, 1) + " pips\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += BuildRunningStats();
   if(InpUseTelegram) SendTelegram(msg);
   Print("[TRACKER] SL HIT: ", g_tracked[tIdx].symbol, " -", DoubleToString(g_tracked[tIdx].slPips, 1), "p");
}

//+------------------------------------------------------------------+
//| TRACKER — Running stats string                                    |
//+------------------------------------------------------------------+
string BuildRunningStats()
{
   double winRate = 0;
   if(g_stats.tp1Wins + g_stats.slLosses > 0)
      winRate = (double)g_stats.tp1Wins / (double)(g_stats.tp1Wins + g_stats.slLosses) * 100.0;
   double netPips = g_stats.pipsWon - g_stats.pipsLost;
   string netSign = (netPips >= 0) ? "+" : "";

   string s = "📊 *" + IntegerToString(g_stats.tp1Wins) + "W / " +
              IntegerToString(g_stats.slLosses) + "L";
   if(g_stats.breakevens > 0) s += " / " + IntegerToString(g_stats.breakevens) + "BE";
   s += " (" + DoubleToString(winRate, 0) + "%)* | " + netSign + DoubleToString(netPips, 1) + "p\n";
   s += "🔵 Active: " + IntegerToString(ActiveCount());
   return s;
}

//+------------------------------------------------------------------+
//| TRACKER — Daily Report with active signals + P/L                  |
//+------------------------------------------------------------------+
void SendDailyReport()
{
   if(g_stats.totalSignals == 0) return;

   double winRate = 0;
   if(g_stats.tp1Wins + g_stats.slLosses > 0)
      winRate = (double)g_stats.tp1Wins / (double)(g_stats.tp1Wins + g_stats.slLosses) * 100.0;
   double netPips = g_stats.pipsWon - g_stats.pipsLost;
   string netSign = (netPips >= 0) ? "+" : "";

   string msg = "📋 *RAPPORT — MARKET SNIPER v8.2*\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "📅 " + TimeToString(TimeCurrent(), TIME_DATE) + "\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "📊 Total: " + IntegerToString(g_stats.totalSignals) + "\n";
   msg += "✅ TP1: " + IntegerToString(g_stats.tp1Wins) + "\n";
   msg += "🎯 TP2: " + IntegerToString(g_stats.tp2Wins) + "\n";
   msg += "💎 TP3: " + IntegerToString(g_stats.tp3Wins) + "\n";
   msg += "🛑 SL: " + IntegerToString(g_stats.slLosses) + "\n";
   msg += "⚪ BE: " + IntegerToString(g_stats.breakevens) + "\n";
   msg += "⏰ Expired: " + IntegerToString(g_stats.expired) + "\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "📈 Win Rate: " + DoubleToString(winRate, 1) + "%\n";
   msg += "💰 Net: " + netSign + DoubleToString(netPips, 1) + " pips\n";
   if(g_stats.bestPips > 0) msg += "🏆 Best: +" + DoubleToString(g_stats.bestPips, 1) + " pips\n";
   if(g_stats.worstPips > 0) msg += "💀 Worst: -" + DoubleToString(g_stats.worstPips, 1) + " pips\n";
   if(g_stats.pipsLost > 0)
   {
      double pf = g_stats.pipsWon / g_stats.pipsLost;
      msg += "📐 Profit Factor: " + DoubleToString(pf, 2) + "\n";
   }
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";

   // Active signals with live P/L
   int act = ActiveCount();
   if(act > 0)
   {
      msg += "📌 *Active (" + IntegerToString(act) + "):*\n";
      for(int i = 0; i < g_trackedCount; i++)
      {
         if(g_tracked[i].closed) continue;
         string dir = (g_tracked[i].direction == DIR_BUY) ? "BUY" : "SELL";
         double pip = g_tracked[i].pipSize;
         if(pip <= 0) pip = SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_POINT);

         double curP = (g_tracked[i].direction == DIR_BUY) ?
            SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_BID) :
            SymbolInfoDouble(g_tracked[i].symbol, SYMBOL_ASK);
         double pl = 0;
         if(pip > 0)
            pl = (g_tracked[i].direction == DIR_BUY) ? (curP - g_tracked[i].entry) / pip : (g_tracked[i].entry - curP) / pip;

         string plSign = (pl >= 0) ? "+" : "";
         string tpSt = "";
         if(g_tracked[i].tp1Hit) tpSt += "✅";
         if(g_tracked[i].tp2Hit) tpSt += "🎯";
         if(tpSt == "") tpSt = "⏳";

         msg += "  " + tpSt + " " + g_tracked[i].symbol + " " + dir + " " + plSign + DoubleToString(pl, 1) + "p\n";
      }
   }

   // [PhD] Advanced metrics section
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "🧬 *PhD Metrics:*\n";
   double sortino = CalcSortino();
   msg += "  Sortino: " + DoubleToString(sortino, 2) + "\n";
   double kelly = CalcKellyFraction();
   if(kelly > 0)
      msg += "  Half-Kelly: " + DoubleToString(kelly * 100, 1) + "%\n";
   string evBySetup = CalcExpectedValueBySetup();
   if(StringLen(evBySetup) > 0)
   {
      msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
      msg += "📊 *EV by Setup:*\n";
      msg += evBySetup;
   }
   // [v9] Daily summary extras: winrate, best/worst, discipline reminder
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "📋 *Daily Summary:*\n";
   double dayWR = 0;
   int dayDecided = g_stats.tp1Wins + g_stats.slLosses + g_stats.breakevens;
   if(dayDecided > 0)
      dayWR = (double)g_stats.tp1Wins / (double)dayDecided * 100.0;
   msg += "📈 Winrate (decided): " + DoubleToString(dayWR, 1) + "% (" + IntegerToString(g_stats.tp1Wins) + "W/" + IntegerToString(g_stats.slLosses) + "L)\n";
   if(g_stats.bestPips > 0)
      msg += "🏆 Best trade: +" + DoubleToString(g_stats.bestPips, 1) + " pips\n";
   if(g_stats.worstPips > 0)
      msg += "💀 Worst trade: -" + DoubleToString(g_stats.worstPips, 1) + " pips\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "⚠️ *Discipline Reminder:*\n";
   msg += "  - Max 2 consecutive losses = STOP trading\n";
   msg += "  - No revenge trades. Walk away.\n";
   msg += "  - Only A/A+ setups. Skip if unsure.\n";
   msg += "━━━━━━━━━━━━━━━━━━━━━━━\n";
   msg += "_Market Sniper v8.2 REGIME_";
   if(InpUseTelegram) SendTelegram(msg);
   Print("[TRACKER] Daily report sent");
}

//+------------------------------------------------------------------+
//| TRACKER — Cleanup + Helpers                                       |
//+------------------------------------------------------------------+
void CleanupTracker()
{
   int writeIdx = 0;
   for(int i = 0; i < g_trackedCount; i++)
   {
      if(!g_tracked[i].closed)
      {
         if(writeIdx != i) g_tracked[writeIdx] = g_tracked[i];
         writeIdx++;
      }
   }
   g_trackedCount = writeIdx;
   ArrayResize(g_tracked, g_trackedCount);
}

int ActiveCount()
{
   int c = 0;
   for(int i = 0; i < g_trackedCount; i++)
      if(!g_tracked[i].closed) c++;
   return c;
}

string FormatElapsed(datetime startTime)
{
   int secs = (int)(TimeCurrent() - startTime);
   int mins = secs / 60;
   int hours = mins / 60;
   mins = mins % 60;
   if(hours > 0) return IntegerToString(hours) + "h " + IntegerToString(mins) + "m";
   return IntegerToString(mins) + "m";
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   string d = "";
   d += "===== MARKET SNIPER v8.2 REGIME =====\n";
   d += "Alerts: " + IntegerToString(g_alertsToday) + "/" + IntegerToString(InpMaxAlertsDay);
   d += " | Scans: " + IntegerToString(g_totalScans);
   d += " | Blocked: " + IntegerToString(g_signalsBlockedToday) + "\n";
   d += "Min:" + IntegerToString(InpMinScore) + "/29+dyn | RR>=" + DoubleToString(InpMinRR, 1) + " | SL:" + DoubleToString(InpMinSL_Pips, 0) + "p\n";
   d += "MTS>" + DoubleToString(InpMTS_Min, 0) + " | 4-Regime | News cache | TDelta\n";
   d += "CSV: " + IntegerToString(g_csvSignalCount) + " signals logged | " + g_csvFileName + "\n";
   string filt = "";
   if(InpNewsFilter)    filt += "News ";
   if(InpCorrelFilter)  filt += "Corr ";
   if(InpUseVolume)     filt += "Vol ";
   if(InpTFAlignFilter) filt += "TFAl ";
   if(InpSFPFilter)     filt += "SFP ";
   if(InpUseBBSqueeze)  filt += "BB ";
   if(InpUseROC)        filt += "ROC ";
   if(InpUseFibo)       filt += "Fibo ";
   if(filt != "") d += "Filters: " + filt + "\n";
   if(g_consecLosses > 0) d += "ConsecLoss: " + IntegerToString(g_consecLosses) + "\n";

   if(InpTrackSignals && g_stats.totalSignals > 0)
   {
      double wr = 0;
      if(g_stats.tp1Wins + g_stats.slLosses > 0)
         wr = (double)g_stats.tp1Wins / (double)(g_stats.tp1Wins + g_stats.slLosses) * 100.0;
      double net = g_stats.pipsWon - g_stats.pipsLost;
      string ns = (net >= 0) ? "+" : "";

      d += "--- TRACKER ---\n";
      d += "W:" + IntegerToString(g_stats.tp1Wins) +
           " L:" + IntegerToString(g_stats.slLosses) +
           " BE:" + IntegerToString(g_stats.breakevens) +
           " WR:" + DoubleToString(wr, 0) + "%" +
           " Net:" + ns + DoubleToString(net, 1) + "p" +
           " Act:" + IntegerToString(ActiveCount()) + "\n";
   }

   d += "-------------------------------\n";
   for(int i = 0; i < g_symCount; i++)
   {
      if(!g_sym[i].active) continue;
      string status = "OK";
      if(g_sym[i].lastAlertTime > 0 && TimeCurrent() - g_sym[i].lastAlertTime < InpCooldownMin * 60)
         status = "CD";
      string regTag = StringSubstr(RegimeName(g_sym[i].currentRegime), 0, 4);
      string line = StringFormat("%-14s %2s %-5s %-14s %d/29 %s",
         g_sym[i].baseName, status, g_sym[i].lastDir, g_sym[i].lastType, g_sym[i].lastScore, regTag);
      if(g_sym[i].lastTime > 0) line += " " + TimeToString(g_sym[i].lastTime, TIME_MINUTES);
      d += line + "\n";
   }
   d += "-------------------------------\n";
   d += "TF: D1+" + TFStr(InpTF_Trend) + "/" + TFStr(InpTF_Signal) + "/" + TFStr(InpTF_Entry) + "\n";
   Comment(d);
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                  |
//+------------------------------------------------------------------+
string SetupName(ENUM_SETUP_TYPE t)
{
   switch(t)
   {
      case SETUP_BOS:         return "Break of Structure";
      case SETUP_SR_BREAKOUT: return "S/R Breakout";
      case SETUP_ORDER_BLOCK: return "Order Block";
      case SETUP_FVG:         return "Fair Value Gap";
      case SETUP_LIQ_SWEEP:   return "Liquidity Sweep";
      case SETUP_SD_ZONE:     return "Supply/Demand";
      case SETUP_RSI_DIV:     return "RSI Divergence";
      case SETUP_MACD_DIV:    return "MACD Divergence";
      case SETUP_CANDLE:      return "Candle Pattern";
      case SETUP_EMA_CROSS:   return "EMA Cross";
      case SETUP_MULTI:       return "Multi-Confluence";
      case SETUP_SFP:         return "Swing Failure Pattern";
      default: return "Unknown";
   }
}

string GradeLabel(ENUM_SETUP_GRADE g)
{
   switch(g) { case GRADE_A_PLUS: return "A+"; case GRADE_A: return "A"; case GRADE_B: return "B"; default: return "-"; }
}

string GradeEmoji(ENUM_SETUP_GRADE g)
{
   switch(g) { case GRADE_A_PLUS: return "💎"; case GRADE_A: return "⭐"; case GRADE_B: return "📊"; default: return "❓"; }
}

string TFStr(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1: return "M1"; case PERIOD_M5: return "M5";
      case PERIOD_M15: return "M15"; case PERIOD_M30: return "M30";
      case PERIOD_H1: return "H1"; case PERIOD_H4: return "H4";
      case PERIOD_D1: return "D1"; case PERIOD_W1: return "W1";
      default: return EnumToString(tf);
   }
}

ENUM_SETUP_GRADE ScoreToGrade(int score)
{
   if(score >= 9) return GRADE_A_PLUS;
   if(score >= 6) return GRADE_A;
   if(score >= 3) return GRADE_B;
   return GRADE_NONE;
}

bool ShouldSend(ENUM_SETUP_GRADE g)
{
   if(g == GRADE_A_PLUS && InpSendGradeAPlus) return true;
   if(g == GRADE_A && InpSendGradeA) return true;
   if(g == GRADE_B && InpSendGradeB) return true;
   return false;
}

void SetTrigger(ENUM_SETUP_TYPE &trigger, int &trigWeight, ENUM_SETUP_TYPE newType, int newWeight)
{
   if(newWeight > trigWeight) { trigger = newType; trigWeight = newWeight; }
   else if(newWeight == trigWeight)
   {
      if(TriggerPriority(newType) > TriggerPriority(trigger))
      { trigger = newType; trigWeight = newWeight; }
   }
}

int TriggerPriority(ENUM_SETUP_TYPE t)
{
   switch(t)
   {
      case SETUP_BOS:         return 10;
      case SETUP_RSI_DIV:     return 9;
      case SETUP_ORDER_BLOCK: return 8;
      case SETUP_LIQ_SWEEP:   return 7;
      case SETUP_FVG:         return 6;
      case SETUP_SR_BREAKOUT: return 5;
      case SETUP_SD_ZONE:     return 4;
      case SETUP_CANDLE:      return 3;
      case SETUP_MACD_DIV:    return 2;
      case SETUP_EMA_CROSS:   return 1;
      case SETUP_SFP:         return 11; // [FIX] was 7 (same as LIQ_SWEEP), SFP is anti-fakeout king
      default: return 0;
   }
}
//+------------------------------------------------------------------+
