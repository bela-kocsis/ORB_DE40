//+------------------------------------------------------------------+
//|                                       ORB_Imbalance_EA_Fixed.mq5 |
//|  Opening Range Breakout + Imbalance Confirmation Strategy        |
//|  v4.0 - SL Buffer + Pyramid at halfway                           |
//+------------------------------------------------------------------+
#property copyright "BeKo Trading"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| INTERNAL CONSTANTS (NOT USER CONFIGURABLE)                       |
//+------------------------------------------------------------------+
const double POINT_VALUE_MULTIPLIER = 1.0;  // Fixed at 1 for proper pip calculation

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== Session Settings ==="
input int      SessionStartHour = 16;        // Session Start Hour (broker time)
input int      SessionStartMinute = 30;      // Session Start Minute
input int      ORB_Minutes = 15;             // Opening Range Duration (minutes)

input group "=== Entry Settings ==="
input int      ImbalanceCandles = 3;         // Imbalance Candles Required
input bool     RequireCleanBreak = false;    // Require Clean Break of ORB
input bool     EnableNoEntryAfter = true;    // Enable No Entry After Hour
input int      NoEntryAfterHour = 18;        // No Entry After This Hour (broker time)

input group "=== Risk Management ==="
input bool     UseFixedLot = false;          // Use Fixed Lot Size
input double   FixedLotSize = 0.01;          // Fixed Lot Size
input bool     UseFixedRiskAmount = false;   // Use Fixed Dollar Risk (overrides %)
input double   FixedRiskAmount = 100.0;      // Fixed Risk Amount ($)
input double   RiskPercent = 1.0;            // Risk Percent (if not fixed lot/amount)

input group "=== Stop Loss Settings ==="
input int      SL_BufferPoints = 10;         // SL Buffer beyond ORB (points)

input group "=== Pyramid Settings ==="
input bool     EnablePyramid = false;        // Enable Pyramid at Halfway
input double   PyramidRiskPercent = 0.5;     // Pyramid Risk Percent (if using %)
input double   PyramidRiskAmount = 50.0;     // Pyramid Risk Amount ($, if using fixed)

input group "=== Take Profit Settings ==="
input double   Target_RR = 2.0;              // Target R:R (for all trades)

input group "=== Breakeven Settings ==="
input bool     MoveToBreakeven = false;      // Move to Breakeven
input double   BreakevenTrigger_R = 1.0;     // Breakeven Trigger (R multiple)

input group "=== Daily Close Settings ==="
input bool     EnableDailyClose = true;      // Enable Daily Close at specified time
input int      DailyCloseHour = 21;          // Daily Close Hour (broker time)
input int      DailyCloseMinute = 0;         // Daily Close Minute

input group "=== Daily Trade Limits ==="
input bool     AllowSecondTrade = true;      // Allow 2nd Trade if 1st Loses

input group "=== Day Filter ==="
input bool     TradeMonday = true;           // Trade on Monday
input bool     TradeTuesday = true;          // Trade on Tuesday
input bool     TradeWednesday = true;        // Trade on Wednesday
input bool     TradeThursday = true;         // Trade on Thursday
input bool     TradeFriday = true;           // Trade on Friday

input group "=== Trade Management ==="
input int      MagicNumber = 123456;         // Magic Number
input int      PyramidMagicNumber = 123457;  // Pyramid Magic Number
input int      Slippage = 30;                // Slippage (points)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
double g_ORB_High = 0;
double g_ORB_Low = 0;
bool g_ORB_Set = false;
datetime g_ORB_Date = 0;
datetime g_LastTradeDate = 0;
int g_TradesToday = 0;
bool g_WonToday = false;
double g_StartingBalance = 0;

// Pyramid tracking
bool g_PyramidTriggered = false;
double g_MainEntryPrice = 0;
double g_MainStopLoss = 0;
double g_MainTakeProfit = 0;
long g_MainPositionType = -1;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   
   g_StartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("=== ORB_Imbalance_EA v4.0 Initialized ===");
   Print("Session: ", SessionStartHour, ":", SessionStartMinute);
   Print("ORB Duration: ", ORB_Minutes, " minutes");
   Print("Imbalance Candles: ", ImbalanceCandles);
   Print("No Entry After: ", EnableNoEntryAfter ? IntegerToString(NoEntryAfterHour) + ":00" : "Disabled");
   
   // Risk mode display
   if(UseFixedLot)
      Print("Risk Mode: Fixed Lot (", FixedLotSize, " lots)");
   else if(UseFixedRiskAmount)
      Print("Risk Mode: Fixed Dollar Amount ($", FixedRiskAmount, " per trade)");
   else
      Print("Risk Mode: Percentage (", RiskPercent, "% of balance)");
   
   Print("SL Buffer: ", SL_BufferPoints, " points");
   
   // Pyramid display
   if(EnablePyramid)
   {
      if(UseFixedRiskAmount)
         Print("Pyramid: Enabled at $", PyramidRiskAmount);
      else
         Print("Pyramid: Enabled at ", DoubleToString(PyramidRiskPercent, 1), "% risk");
   }
   else
      Print("Pyramid: Disabled");
   
   Print("Target R:R: ", Target_RR);
   Print("Daily Close: ", EnableDailyClose ? "Enabled at " + IntegerToString(DailyCloseHour) + ":00" : "Disabled");
   Print("Allow Second Trade: ", AllowSecondTrade ? "Yes" : "No");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== ORB_Imbalance_EA Deinitialized ===");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check daily close first
   if(EnableDailyClose)
      CheckDailyClose();
   
   // Reset daily variables
   ResetDailyVariables();
   
   // Check for breakeven management
   if(MoveToBreakeven)
      ManageBreakeven();
   
   // Check for pyramid entry
   if(EnablePyramid && !g_PyramidTriggered && HasMainPosition())
      CheckPyramidEntry();
   
   // Build ORB if not set
   if(!g_ORB_Set)
      BuildORB();
   
   // Determine max trades allowed today
   int maxTrades = AllowSecondTrade ? 2 : 1;
   
   // Check for entry if ORB is set (don't enter after close time or no-entry hour)
   if(g_ORB_Set && g_TradesToday < maxTrades && !g_WonToday && !HasOpenPosition())
   {
      if(!IsPastCloseTime() && !IsPastNoEntryHour() && IsTradingDay())
         CheckEntry();
   }
}

//+------------------------------------------------------------------+
//| Check if today is an allowed trading day                          |
//+------------------------------------------------------------------+
bool IsTradingDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   switch(dt.day_of_week)
   {
      case 1: return TradeMonday;
      case 2: return TradeTuesday;
      case 3: return TradeWednesday;
      case 4: return TradeThursday;
      case 5: return TradeFriday;
      default: return false;  // Saturday/Sunday
   }
}

//+------------------------------------------------------------------+
//| Check if current time is past the daily close time                |
//+------------------------------------------------------------------+
bool IsPastCloseTime()
{
   if(!EnableDailyClose)
      return false;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   int currentMinutes = dt.hour * 60 + dt.min;
   int closeMinutes = DailyCloseHour * 60 + DailyCloseMinute;
   
   return (currentMinutes >= closeMinutes);
}

//+------------------------------------------------------------------+
//| Check if current time is past the no-entry hour                   |
//+------------------------------------------------------------------+
bool IsPastNoEntryHour()
{
   if(!EnableNoEntryAfter)
      return false;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   return (dt.hour >= NoEntryAfterHour);
}

//+------------------------------------------------------------------+
//| Close all positions at daily close time                           |
//+------------------------------------------------------------------+
void CheckDailyClose()
{
   if(!IsPastCloseTime())
      return;
   
   // Close all positions with our magic numbers
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i)))
         continue;
      
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic != MagicNumber && posMagic != PyramidMagicNumber)
         continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      
      if(trade.PositionClose(ticket))
      {
         Print("🕐 Daily Close: Position ", ticket, " closed");
      }
      else
      {
         Print("❌ Daily Close failed for ticket ", ticket, ": ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Breakeven                                                  |
//+------------------------------------------------------------------+
void ManageBreakeven()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i)))
         continue;
      
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic != MagicNumber && posMagic != PyramidMagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long posType = PositionGetInteger(POSITION_TYPE);
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      
      double riskDistance = MathAbs(openPrice - currentSL);
      double triggerDistance = riskDistance * BreakevenTrigger_R;
      
      if(posType == POSITION_TYPE_BUY)
      {
         double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentPrice >= openPrice + triggerDistance && currentSL < openPrice)
         {
            trade.PositionModify(ticket, openPrice, currentTP);
            Print("✅ Moved to breakeven: Ticket ", ticket);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(currentPrice <= openPrice - triggerDistance && currentSL > openPrice)
         {
            trade.PositionModify(ticket, openPrice, currentTP);
            Print("✅ Moved to breakeven: Ticket ", ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Reset daily variables at new day                                  |
//+------------------------------------------------------------------+
void ResetDailyVariables()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(IntegerToString(dt.year) + "." + 
                                 IntegerToString(dt.mon) + "." + 
                                 IntegerToString(dt.day));
   
   if(today != g_LastTradeDate)
   {
      g_LastTradeDate = today;
      g_TradesToday = 0;
      g_WonToday = false;
      g_ORB_Set = false;
      g_ORB_High = 0;
      g_ORB_Low = 0;
      
      // Reset pyramid tracking
      g_PyramidTriggered = false;
      g_MainEntryPrice = 0;
      g_MainStopLoss = 0;
      g_MainTakeProfit = 0;
      g_MainPositionType = -1;
   }
}

//+------------------------------------------------------------------+
//| Build Opening Range High/Low                                      |
//+------------------------------------------------------------------+
void BuildORB()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Check if we're past ORB formation time
   int currentMinutes = dt.hour * 60 + dt.min;
   int orbStartMinutes = SessionStartHour * 60 + SessionStartMinute;
   int orbEndMinutes = orbStartMinutes + ORB_Minutes;
   
   if(currentMinutes < orbEndMinutes)
      return;  // ORB not complete yet
   
   // Get ORB candles
   datetime orbStart = StringToTime(IntegerToString(dt.year) + "." + 
                                    IntegerToString(dt.mon) + "." + 
                                    IntegerToString(dt.day) + " " +
                                    IntegerToString(SessionStartHour) + ":" +
                                    IntegerToString(SessionStartMinute));
   
   int startBar = iBarShift(_Symbol, PERIOD_M1, orbStart);
   int endBar = startBar - ORB_Minutes + 1;
   
   if(startBar < 0 || endBar < 0)
      return;
   
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   if(CopyHigh(_Symbol, PERIOD_M1, endBar, startBar - endBar + 1, high) <= 0)
      return;
   if(CopyLow(_Symbol, PERIOD_M1, endBar, startBar - endBar + 1, low) <= 0)
      return;
   
   g_ORB_High = high[ArrayMaximum(high)];
   g_ORB_Low = low[ArrayMinimum(low)];
   g_ORB_Set = true;
   
   Print("✅ ORB Set: High = ", g_ORB_High, ", Low = ", g_ORB_Low);
}

//+------------------------------------------------------------------+
//| Check for entry signals                                           |
//+------------------------------------------------------------------+
void CheckEntry()
{
   double close[], open[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(open, true);
   
   if(CopyClose(_Symbol, PERIOD_M1, 0, ImbalanceCandles + 2, close) <= 0)
      return;
   if(CopyOpen(_Symbol, PERIOD_M1, 0, ImbalanceCandles + 2, open) <= 0)
      return;
   
   double currentPrice = close[0];
   
   // Check for long setup
   if(currentPrice > g_ORB_High)
   {
      bool imbalance = true;
      for(int i = 1; i <= ImbalanceCandles; i++)
      {
         if(close[i] <= open[i])  // Not bullish
         {
            imbalance = false;
            break;
         }
      }
      
      if(imbalance)
      {
         if(!RequireCleanBreak || close[ImbalanceCandles + 1] <= g_ORB_High)
         {
            ExecuteLong();
         }
      }
   }
   
   // Check for short setup
   if(currentPrice < g_ORB_Low)
   {
      bool imbalance = true;
      for(int i = 1; i <= ImbalanceCandles; i++)
      {
         if(close[i] >= open[i])  // Not bearish
         {
            imbalance = false;
            break;
         }
      }
      
      if(imbalance)
      {
         if(!RequireCleanBreak || close[ImbalanceCandles + 1] >= g_ORB_Low)
         {
            ExecuteShort();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Execute Long Trade                                                |
//+------------------------------------------------------------------+
void ExecuteLong()
{
   // Double-check we haven't already won today (prevents race condition)
   if(g_WonToday)
      return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // SL is ORB_Low minus buffer points
   double stopLoss = g_ORB_Low - (SL_BufferPoints * point);
   double stopDistance = entryPrice - stopLoss;
   
   if(stopDistance <= 0)
      return;
   
   // Calculate TP at target RR
   double takeProfit = entryPrice + (stopDistance * Target_RR);
   
   // Calculate lot size based on the new SL distance
   double lotSize = CalculateLotSize(stopDistance, RiskPercent);
   
   if(lotSize <= 0)
   {
      Print("❌ Invalid lot size calculated: ", lotSize);
      return;
   }
   
   // Execute trade
   if(trade.Buy(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "ORB_Long"))
   {
      g_TradesToday++;
      
      // Store for pyramid
      g_MainEntryPrice = entryPrice;
      g_MainStopLoss = stopLoss;
      g_MainTakeProfit = takeProfit;
      g_MainPositionType = POSITION_TYPE_BUY;
      g_PyramidTriggered = false;
      
      Print("✅ LONG Entry: Price=", entryPrice, " SL=", stopLoss, " (ORB_Low ", g_ORB_Low, " - ", SL_BufferPoints, " pts) TP=", takeProfit, " Lots=", lotSize);
   }
   else
   {
      Print("❌ Long order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute Short Trade                                               |
//+------------------------------------------------------------------+
void ExecuteShort()
{
   // Double-check we haven't already won today (prevents race condition)
   if(g_WonToday)
      return;
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // SL is ORB_High plus buffer points
   double stopLoss = g_ORB_High + (SL_BufferPoints * point);
   double stopDistance = stopLoss - entryPrice;
   
   if(stopDistance <= 0)
      return;
   
   // Calculate TP at target RR
   double takeProfit = entryPrice - (stopDistance * Target_RR);
   
   // Calculate lot size based on the new SL distance
   double lotSize = CalculateLotSize(stopDistance, RiskPercent);
   
   if(lotSize <= 0)
   {
      Print("❌ Invalid lot size calculated: ", lotSize);
      return;
   }
   
   // Execute trade
   if(trade.Sell(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "ORB_Short"))
   {
      g_TradesToday++;
      
      // Store for pyramid
      g_MainEntryPrice = entryPrice;
      g_MainStopLoss = stopLoss;
      g_MainTakeProfit = takeProfit;
      g_MainPositionType = POSITION_TYPE_SELL;
      g_PyramidTriggered = false;
      
      Print("✅ SHORT Entry: Price=", entryPrice, " SL=", stopLoss, " (ORB_High ", g_ORB_High, " + ", SL_BufferPoints, " pts) TP=", takeProfit, " Lots=", lotSize);
   }
   else
   {
      Print("❌ Short order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Check for Pyramid Entry at Halfway                                |
//+------------------------------------------------------------------+
void CheckPyramidEntry()
{
   if(g_MainEntryPrice == 0 || g_MainStopLoss == 0)
      return;
   
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Calculate halfway point between entry and SL
   double halfwayPrice = (g_MainEntryPrice + g_MainStopLoss) / 2.0;
   
   if(g_MainPositionType == POSITION_TYPE_BUY)
   {
      // For long: trigger when price drops to halfway
      if(currentBid <= halfwayPrice)
      {
         ExecutePyramidLong();
      }
   }
   else if(g_MainPositionType == POSITION_TYPE_SELL)
   {
      // For short: trigger when price rises to halfway
      if(currentAsk >= halfwayPrice)
      {
         ExecutePyramidShort();
      }
   }
}

//+------------------------------------------------------------------+
//| Execute Pyramid Long Trade                                        |
//+------------------------------------------------------------------+
void ExecutePyramidLong()
{
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopLoss = g_MainStopLoss;  // Same SL as main position
   double stopDistance = entryPrice - stopLoss;
   
   if(stopDistance <= 0)
      return;
   
   // TP is the same as main trade TP
   double takeProfit = g_MainTakeProfit;
   
   // Calculate lot size with pyramid-specific risk values
   double lotSize;
   if(UseFixedRiskAmount)
   {
      // Use pyramid fixed dollar amount
      lotSize = CalculateLotSize(stopDistance, PyramidRiskPercent, PyramidRiskAmount);
   }
   else
   {
      // Use pyramid percentage
      lotSize = CalculateLotSize(stopDistance, PyramidRiskPercent, 0);
   }
   
   if(lotSize <= 0)
   {
      Print("❌ Invalid pyramid lot size: ", lotSize);
      return;
   }
   
   // Set pyramid magic number for this trade
   trade.SetExpertMagicNumber(PyramidMagicNumber);
   
   if(trade.Buy(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "ORB_Pyramid_Long"))
   {
      g_PyramidTriggered = true;
      
      string riskInfo = UseFixedRiskAmount ? 
         "$" + DoubleToString(PyramidRiskAmount, 2) + " risk" : 
         DoubleToString(PyramidRiskPercent, 1) + "% risk";
      
      Print("🔺 PYRAMID LONG: Price=", entryPrice, " SL=", stopLoss, " TP=", takeProfit, 
            " (same as main) Lots=", lotSize, " (", riskInfo, ")");
   }
   else
   {
      Print("❌ Pyramid long failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
   
   // Reset magic number back to main
   trade.SetExpertMagicNumber(MagicNumber);
}

//+------------------------------------------------------------------+
//| Execute Pyramid Short Trade                                       |
//+------------------------------------------------------------------+
void ExecutePyramidShort()
{
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopLoss = g_MainStopLoss;  // Same SL as main position
   double stopDistance = stopLoss - entryPrice;
   
   if(stopDistance <= 0)
      return;
   
   // TP is the same as main trade TP
   double takeProfit = g_MainTakeProfit;
   
   // Calculate lot size with pyramid-specific risk values
   double lotSize;
   if(UseFixedRiskAmount)
   {
      // Use pyramid fixed dollar amount
      lotSize = CalculateLotSize(stopDistance, PyramidRiskPercent, PyramidRiskAmount);
   }
   else
   {
      // Use pyramid percentage
      lotSize = CalculateLotSize(stopDistance, PyramidRiskPercent, 0);
   }
   
   if(lotSize <= 0)
   {
      Print("❌ Invalid pyramid lot size: ", lotSize);
      return;
   }
   
   // Set pyramid magic number for this trade
   trade.SetExpertMagicNumber(PyramidMagicNumber);
   
   if(trade.Sell(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "ORB_Pyramid_Short"))
   {
      g_PyramidTriggered = true;
      
      string riskInfo = UseFixedRiskAmount ? 
         "$" + DoubleToString(PyramidRiskAmount, 2) + " risk" : 
         DoubleToString(PyramidRiskPercent, 1) + "% risk";
      
      Print("🔻 PYRAMID SHORT: Price=", entryPrice, " SL=", stopLoss, " TP=", takeProfit, 
            " (same as main) Lots=", lotSize, " (", riskInfo, ")");
   }
   else
   {
      Print("❌ Pyramid short failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
   
   // Reset magic number back to main
   trade.SetExpertMagicNumber(MagicNumber);
}

//+------------------------------------------------------------------+
//| Check if main position exists                                     |
//+------------------------------------------------------------------+
bool HasMainPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                                |
//| Optional overrides for pyramid trades                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopDistance, double riskPct, double fixedRiskOverride = 0)
{
   // Mode 1: Fixed Lot Size
   if(UseFixedLot)
   {
      Print("📊 Using fixed lot: ", FixedLotSize);
      return NormalizeLot(FixedLotSize);
   }
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount;
   
   // Mode 2: Fixed Dollar Risk Amount
   if(UseFixedRiskAmount)
   {
      // Use override if provided (for pyramid trades), otherwise use main setting
      riskAmount = (fixedRiskOverride > 0) ? fixedRiskOverride : FixedRiskAmount;
      Print("📊 Using fixed dollar risk: $", DoubleToString(riskAmount, 2));
   }
   // Mode 3: Percentage Risk
   else
   {
      riskAmount = balance * (riskPct / 100.0);
      Print("📊 Using percentage risk: ", DoubleToString(riskPct, 2), "% of $", DoubleToString(balance, 2), " = $", DoubleToString(riskAmount, 2));
   }
   
   // Get symbol specifications
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(tickSize == 0 || point == 0)
   {
      Print("❌ Invalid symbol specifications");
      return 0;
   }
   
   // Calculate point value (multiplier fixed at 1.0)
   double basePointValue = tickValue / (tickSize / point);
   double pointValue = basePointValue * POINT_VALUE_MULTIPLIER;
   
   // Calculate stop in points
   double stopPoints = stopDistance / point;
   
   // Calculate lot size
   double lotSize = riskAmount / (stopPoints * pointValue);
   
   // Detailed logging
   Print(">>> Risk Calculation:");
   Print("    Balance: $", DoubleToString(balance, 2));
   Print("    Risk Amount: $", DoubleToString(riskAmount, 2));
   Print(">>> Symbol Specs:");
   Print("    Tick Value: ", tickValue);
   Print("    Tick Size: ", tickSize);
   Print("    Point: ", point);
   Print(">>> Calculation:");
   Print("    Base Point Value: ", DoubleToString(basePointValue, 8));
   Print("    Final Point Value: ", DoubleToString(pointValue, 8));
   Print("    Stop Distance: ", stopDistance);
   Print("    Stop Points: ", stopPoints);
   Print(">>> Result:");
   Print("    Raw Lot Size: ", DoubleToString(lotSize, 4));
   
   // Normalize to broker limits
   lotSize = NormalizeLot(lotSize);
   
   // Final sanity check - calculate actual risk
   double actualRisk = lotSize * stopPoints * pointValue;
   double actualRiskPercent = (actualRisk / balance) * 100;
   
   Print("    Final Lot Size: ", DoubleToString(lotSize, 2));
   Print("    Actual Risk: $", DoubleToString(actualRisk, 2), " (", DoubleToString(actualRiskPercent, 2), "%)");
   
   // Warn if actual risk differs significantly from target
   if(!UseFixedRiskAmount && MathAbs(actualRiskPercent - riskPct) > 0.5)
   {
      Print("⚠️ WARNING: Actual risk ", DoubleToString(actualRiskPercent, 2), 
            "% differs from target ", DoubleToString(riskPct, 2), "%");
   }
   else if(UseFixedRiskAmount && MathAbs(actualRisk - riskAmount) > 1.0)
   {
      Print("⚠️ WARNING: Actual risk $", DoubleToString(actualRisk, 2), 
            " differs from target $", DoubleToString(riskAmount, 2));
   }
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker specifications                       |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Apply broker limits
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   
   // Round to lot step
   lot = MathFloor(lot / lotStep) * lotStep;
   
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Check if there's an open position                                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         long posMagic = PositionGetInteger(POSITION_MAGIC);
         if((posMagic == MagicNumber || posMagic == PyramidMagicNumber) &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Track trade results for daily limit                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      {
         // Check if this is a closing deal
         if(HistoryDealSelect(trans.deal))
         {
            long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
            string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
            
            // Only process closing deals for this EA's positions on this symbol
            if(entry == DEAL_ENTRY_OUT && 
               (dealMagic == MagicNumber || dealMagic == PyramidMagicNumber) &&
               dealSymbol == _Symbol)
            {
               double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
               double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
               double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
               
               // Total P&L including swap and commission
               double totalPnL = profit + swap + commission;
               
               // Count as winner if main position closes with profit
               if(dealMagic == MagicNumber && totalPnL > 0)
               {
                  g_WonToday = true;
                  Print("🎉 Winner! (P&L: $", DoubleToString(totalPnL, 2), ") - Stopping for the day.");
               }
               else if(dealMagic == MagicNumber && totalPnL <= 0)
               {
                  Print("❌ Loss detected (P&L: $", DoubleToString(totalPnL, 2), ")");
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
