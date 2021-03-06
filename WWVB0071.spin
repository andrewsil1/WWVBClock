'' ToDo list:
'' - Apply DST/end-DST change.
'' - Use button to select 12/24hr display.

{{
Documentation:

This module implements a clock displayed on a Parallax 2x16 serial LCD, where the time source is a C-Max CMMR-6 radio module
that receives the U.S. WWVB amplitude-based time signal.  The time is stored into a Maxim DS32B35 clock chip, which is much like the
common Dallas Semi clock chips, except that it has an internal temperature-compensated crystal oscillator (TCXO) which is
good to +/- 2ppm accuracy over most common temperatures. This is 10x more accurate than the typical +/- 20ppm crystals used
to derive the Propeller's 80Mhz clock. Furthermore, the system listens to the incoming radio signal continuously, and
resyncs the clock chip any time an error-free frame is received, virtually guaranteeing that the clock will remain
extremely accurate for lengthy periods when normal reception is available (typically at night). It will remain accurate to within
63 seconds per year even if reception was lost completely for that entire time. I proved this empirically by leaving the clock entirely
unused for a period of at least 5 or 6 years and on firing it up again it had lost only about 40 seconds or so.

A single push button allows the user access to view some debug information on the LCD as well as to change the GMT offset
for the local timezone (hold the button down on the GMT screen to go into "set" mode, then use short presses to change
the value, and one more long press when the desired value is reached.)

Leap years, leap seconds, offset between UTC and DUT, and daylight savings time beginning/ending are all monitored and
accounted for. (Not thoroughly debugged yet, however.)

Cogs used:
0 - Initialization, followed by Main loop, signal parsing and decoding, conversion from GMT to local time.
1 - Radio receiver.  Watches low pulses from the CMMR-6 on a pin, returns their duration and starting CNT via global memory.
2 - Parallax Serial Terminal uses one cog for high speed serial debug text output
3 - Clock display: Loops continuously, displaying contents of global memory to the serial LCD. Bit-bang serial is performed
    within the cog using an enhanced standard Serial_LCD library object. (Added Str/Dec functions from PST object.) This
    cog also monitors button presses and changes the display to show debug information, as well as setting GMT offset when
    needed.  As GMT offset is modified, the clock chip registers are rewritten to the new local time from this cog.
4 - The DS32B35 object provides the calling cog with access to the clock chip's control registers as well as its NVRAM
    section for saving a few global values used across power cycles.  However, it also starts this cog to read the
    clock chip in a tight loop over I2C, and stores the current values to global memory for other cogs to use. Setting
    the clock registers and resyncing it are performed via a global used to change the function the tight loop is
    performing. The Propeller's lock bits are used to provide mutually exclusive access to the chip.
5 - The PASM i2c driver uses a cog to do i2c serial communication in assembly, permitting use of the 400khz i2c Fast mode.
6/7 - Used to send some serial debug information to the PST port without having to interrupt the main loop. These
      routines end after use which frees the cog once complete. These cogs are also used to sync the RTC chip
      to the received top-of-minute signal without interrupting the ongoing pulse parsing in Cog 0, which needs to stay on time.

}}

OBJ
  GetPulse: "RadioInput"
  pst     : "Modified Parallax Serial Terminal"         ' Serial communication object
  LCD     : "Modified_Serial_LCD"                       ' Serial communication object for LCD
  DOTW    : "DayOfTheWeek"                              ' Calendar math functions
  RTC     : "DS32B35v2"                                 ' RTC object
  Button  : "Button"                                    ' Button functions
  Num     : "Numbers"                                   ' Number formatting

'  Stk     : "Stack Length"                             ' For determining maximum stack lengths required for separate cogs.

CON
   _CLKMODE = XTAL1 + PLL16X                            ' Standard 80Mhz clock
   _XINFREQ = 5_000_000

   MARKER = 2                                           ' MARKER = special bit type for WWVB
   TOLERANCE = 25                                       ' Number of ms a bit can be off from its expected start time and still be treated as valid
   NUMFRAMES = 1                                        ' Number of frames to average
   LCD_PIN = 15                                         ' Pin that the Parallax Serial LCD output is on
   BUTTON1 = 8                                          ' Pin for control button 1
   SNRSamples = 30                                      ' Number of samples to average to estimate signal quality
   SCLPin = 22                                          ' Pin for I2C SCL
   SDAPin = 23                                          ' Pin for I2C SDA
   RTCAddr = %11010000                                  ' I2C Address for DS32B35 RTC chip.
   DebugRTC = FALSE                                     ' If True, clears RTC on startup for test purposes.
   #0,DSTStandard,DSTEnding,DSTStarting,DSTEnabled      ' Define enum for possible DST states

VAR
 LONG ms, TopOfMinuteCnt, correction, edgeCnt, pulseWidth, last, tempBit, tempCnt, DSTStat, DSTChanging, SyncLocked, ClockValid, LeapSec
 LONG ClockMode, DUTSign, DUT, SNR[SNRSamples], SNRpointer, SNRAverage, LocalRTCTime, duration1, Reset, LY, DSTStatus
 LONG stack[50], serialstack[50], clockstack[80], ResyncStack[30]', syncstack[50], serialstack2[250]

DAT
 pin         LONG 1                             ' Pin used to read the CMMR-6P-60 module (radio pulses in)
 ppsPin      LONG 0                             ' Pin for reading clock chip 1hz signal.
 RadioSem    LONG -1                            ' Semaphore for reading radio pulsewidths and cnt-of-start.
 SerialSem   LONG -1                            ' Semaphore to allow mutex access to serial port for messages.
 i2cSem      LONG -1                            ' Semaphore for access to time structure
 Frames      LONG 0[NUMFRAMES * 2]              ' Track const number of frames for averaging
 GMTHrs      LONG 0                             ' TODO: Deal with fractional GMT offsets of less than 1 hour.
 DSTObserved LONG TRUE                          ' Observe DST when it's "in effect?"
 GlSeconds   LONG 0                             '\
 GlMinutes   LONG 0                             ' |
 GlHours     LONG 0                             ' |
 GlWeekDay   LONG 0                             ' }-- Global time structure
 GlDays      LONG 0                             ' |
 GlMonths    LONG 0                             ' |
 GlYears     LONG 0                             '/

PUB Main

Initialize

'------------------------------Main loop---------------------------------
Repeat
  TopOfMinuteCnt := WaitForTopOfMinute                  ' Wait for the top of a minute and save the CNT when it happens.
  if FillCurrentFrame(TopOfMinuteCnt) == TRUE           ' Fill all the bits in the frame for 1 minute. If the frame was perfect,
    ParseRawFrame                                       ' then parse it and write it to the chip, and check for DST adjustments.
    CheckDST

PRI Initialize
{ Initialization code to start communication with debug terminal, LCD, clock chip, and radio receiver.

}
ms := clkfreq / 1_000                                   ' Save some time by not doing this division repeatedly.
ClockValid := False                                     ' Clock's not valid yet
Reset := TRUE
pst.Start(1000000,31,30)                                ' Start the Parallax Serial Terminal cog on programming port
ClockMode := RTC#READCLOCK                              ' Set ClockMode state flag before starting clock object.
Num.Init

Repeat                                                 ' Check out a lock for use as serial output mutex
  SerialSem := locknew
Until SerialSem <> -1

pst.Str(String("WWVB Clock with Accurate DS32B35 RTC   Version 0.7, (c)2021 Andrew Silverman",pst#NL))

if NOT (RTC.init(@GlSeconds, @ClockMode, @ClockValid, SDAPin, SCLPin)) ' Setup RTC object
  DbgErr(String("DS32B35 Clock Missing!"))
  Abort

If NOT GetPulse.start(@pin,@pulseWidth,@edgeCnt)       ' Start a Cog measuring pulses on Pin 1 using CtrA.
  DbgErr(String("GetPulse start failed"))
  Abort

Waitcnt(2*clkfreq + cnt)                               ' Give radio 2 seconds to start measuring

Repeat until (RadioSem := GetPulse.GetSemID) <> -1     ' Wait until semID for Radio object is valid (set by the subobject)
Repeat until (i2cSem := RTC.GetSemID) <> -1            ' Wait until semID for Time/Date array is valid (set by the subobject)

If DebugRTC                                            ' For debugging:
  Repeat until ClockMode == RTC#READCLOCK              ' Make sure any previous command completed.
  repeat until not lockset(i2cSem)
  RTC.SetRegister($88,$0F)                             ' Set the "clock invalid" flag in the chip.
  lockclr(i2cSem)

if cognew(WriteRTCTime,@clockstack) == -1              ' Output RTC clock to LCD.
  DbgErr(String("LCD startup failed"))
  Abort


PRI WaitForTopOfMinute : Starttime| TempValid
{{ This function reads bits until two markers in a row are received, and returns the system counter where the second
one was detected. This signifies the top of a minute and parsing of a full frame can now begin.

}}

Repeat
  SyncLocked := FALSE
  Repeat
    TempBit := ParseWWVB(@TempCnt,@TempValid) ' Synchronously read bits until a marker bit comes in. We have no sync yet.
  While TempBit <> MARKER or NOT TempValid

  TempBit := ParseWWVB(@TempCnt,@TempValid) ' Read another bit
While TempBit <> MARKER or NOT TempValid    ' If the very next bit isn't also a marker, do it all over again until it is.

' Process Leap Second if it happens when it's supposed to (last day of month, LS signalled true, 11:59pm...), otherwise resync.
If LeapSec and LastDayOfMonth and GlHours == 23 and GLMinutes == 59
  TempBit := ParseWWVB(@TempCnt,@TempValid)             'Read the extra bit that's coming.  Now we have the right tempcnt (Top Of Minute)
Else
  SyncLocked := TRUE
  if cognew(Resync(0),@ResyncStack) == -1                 ' Normal resync. Leap second resync is done in the clock display code.
    DbgErr(String("No cog for resyncing clock chip"))
    Abort

If TempValid
  Starttime := TempCnt          ' We got two or three markers in a row, now we know where the top of the minute occurred.

PRI FillCurrentFrame(MinuteCnt): Value | temp, bit, threshoffset, sec, addr, valid, framevalid
{{ This function takes the CNT from the known beginning of the minute, and then reads the rest of the minute, stuffing as many bits
as it can parse at the proper 1-second "centers" into Frames[0] and [1] (two longs are needed to store an entire frame.) }}

Longfill(@Frames[0],0,2)                                     ' Clear frame we're about to fill
FrameValid := TRUE                                           ' Assume frame is valid at start.

' This section takes a minute to complete retrieving the whole data frame, but bails early if it hits invalid bits.
Repeat sec from 1 to 58
  bit := ParseWWVB(@temp,@valid)                             ' Get a bit
  if NOT valid
    FrameValid := FALSE                                      ' Set to false if any bit fails during the frame.

  threshoffset := ||(temp - MinuteCnt) // CLKFREQ            ' Get # of clks from an "exact" tick (remainder of int division)

  'Calculate whether we just passed a second, or are approaching one. Large remainder means just approaching, small
  'one means we just passed an exact second.

  if threshoffset * 2 > CLKFREQ                              ' If True, we're closer to the next second
    threshoffset := -(||(CLKFREQ - threshoffset))            ' Then calculate distance to next second instead and call it negative

  if (sec =< 32)
     addr := 0
  else
     addr := 1  'For seconds 32-59, put it in the second field. (QWORD, basically.) Only bits 0-25 will be used.

  LONG[@Frames][addr] <<= 1    'Shift left then add the new bit on the end
  if  (bit == 1 and ((1000 * ||threshoffset) / CLKFREQ =< TOLERANCE)) ' If bit is close to expected arrival time, as long as it's not invalid or a marker, store it.
    LONG[@Frames][addr] += bit

  if (sec // 10 == 9 and bit <> MARKER) or (sec // 10 <> 9 and bit == MARKER)
    FrameValid := False                                       ' If the bit is a marker in the wrong place, or it isn't a marker in the right place, the frame's bad.

  WriteSyncedBits(threshoffset,sec,LONG[@frames][0],LONG[@frames][1],Framevalid)  ' DEBUGOUT: Write info to debug terminal

  if not FrameValid
    Return                                                    ' Bail prematurely

' We've received the whole data frame successfully
LONG[@Frames][1] <<= 6 ' Shift the 2nd long left by 6 bits to make parsing easier.
Value := FrameValid    ' Return whether the whole frame was good or not.

PRI ParseRawFrame | Temp, Date, Month, Hours24, Minutes, Days, Years, TempLeapSec, tempStr, tm1

{{This routine runs once per frame (minute) and extracts the stored bits, parsing it into the individual fields
defined for the WWVB timecode. The days are converted to a month and date within that month from 0-366 representation and leap years
are accounted for. It then applies local GMT conversion, and resets the RTC chip to the received time/date.

This routine should only be called when the received frame was "perfect" - i.e. all bit durations were valid, received within a
few ms of the expected time, and inter-pulse durations were ~1 sec apart (no noise.)
}}

' We're going to do some pretty ugly shifting of the stored bits here to add them together into decimal representations
' of the encoded fields.
' Don't bother initializing the locals, they all get assigned before use.
  tm1 := cnt

  Minutes := ((BYTE[@Frames][3] & %11100000) >> 5) * 10      ' Now parse the frame into component fields
  Minutes += (BYTE[@Frames][3] & %1111)

  Hours24 := ((BYTE[@Frames][2] & %11000) >> 3) * 10
  Hours24 += ((BYTE[@Frames][2] & %11) << 2) + ((BYTE[@Frames][1] & %11000000) >> 6)

  Days := ((BYTE[@Frames][1] & %110) >> 1) * 100
  Days += ((Byte[@Frames][0] & %11110000) >> 4) * 10
  Days += ((Byte[@Frames][0] & %111) << 1) + ((Byte[@Frames][7] & %10000000) >> 7)

  If (Byte[@Frames][7] & %00011100) == %00010100
    DUTSign := 1
  Elseif (Byte[@Frames][7] & %00011100) == %00001000
    DUTSign := -1
  Else
    DUTSign := NEGX                                            'Invalid pattern detected for DUT sign
    'BUGBUG: trap invalid pattern and ignore it or assert out

  DUT := (((Byte[@Frames][7] & %1) << 3) + ((Byte[@Frames][6] & %11100000) >> 5)) * DUTSign

  Years := (Byte[@Frames][6] & %1111) * 10
  Years += ((Byte[@Frames][5] & %01111000) >> 3)

  LY := (Byte[@Frames][5] & %10) == 2                           'True/False
  TempLeapSec := (Byte[@Frames][5] & %01) == 1                  'True/False
  DSTStatus := ((Byte[@Frames][4] & %11000000) >> 6)

  If Days =< 365 - LY
    Month := 0                                                  ' Convert 1-366 date into Date/Month representation
    Temp := Days
    Repeat while Temp > 0                                       ' Repetitively subtract the number of days in the month
      Month++                                                   ' until we hit zero or less.  Then we know what month
      Case Month                                                ' we're in and how many days into it we are.
        4, 6, 9, 11:
          If Temp =< 30
            Date := Temp
          Temp -= 30
        2:
          If Temp =< (28 - LY)
            Date := Temp
          Temp -= (28 - LY)
        OTHER:
          If Temp =< 31
            Date := Temp
          Temp -= 31
  Else
    Month := 1                                                  ' Should never get here.  Consider bluescreening...
    Date := 1

'---------Update the RTC with the parsed time--------------------
  'AdjustForGMT(@Hours24,@Date,@Month,@Years)               '0070: Store actual GMT, not local time

  Repeat until ClockMode == RTC#READCLOCK                   ' Make sure the previous command (writing seconds) completed.
  Repeat until not lockset(i2cSem)                          ' Get the lock, reset the current time, and send it to the chip.
  RTC.SetDSTStatus(DSTStatus)                               ' Write the parsed DST status to NVRAM

  if minutes =< 59
    GlMinutes := Minutes
  if Hours24 =< 23
    GlHours := Hours24
  if Years =< 99
    GlYears := Years
  if Month =< 12
    GlMonths := Month
  if Date =< 31
    GlDays := Date
  GlWeekday := DOTW.DOTW(GlYears+2000, GLMonths, GLDays)    ' BUGBUG: Not needed, can be calculated on the fly...?

  ClockMode := RTC#WRITECLOCK                               ' Write Everything but the seconds to the chip (we did that earlier.)
  Lockclr(i2cSem)                                           ' Write it to the chip.

  ClockValid := TRUE                                        ' Set VALID once we have a real time to show on the LCD.

'---------------Debug Out of the parsed frame-----------------------
{Convert frame to strings for LCD debug output}
TempStr := Num.ToStr(Hours24, Num#DEC3)                                         'Get hours as string
bytemove(@Text1, TempStr+1, strsize(TempStr)-1)                                 'Copy hours to friendly string (chop leading sign.)
TempStr := Num.ToStr(Minutes, Num#DEC3)
bytemove(@Text1+3, TempStr+1, strsize(TempStr)-1)                               'Copy minutes to friendly string
TempStr := Num.ToStr(Days, Num#DEC4)
bytemove(@Text1+11, TempStr+1, strsize(TempStr)-1)                              'Copy minutes to friendly string
TempStr := Num.ToStr(Years, Num#DEC3)
bytemove(@Text2+5, TempStr+1, strsize(TempStr)-1)                               'Copy years to friendly string
TempStr := Num.ToStr(DUT, Num#DEC+NUM#CHAR2+NUM#PLUS)
bytemove(@Text2+12, TempStr, strsize(TempStr))                                  'Copy years to friendly string
Case LY
  TRUE:  bytefill(@Text3+3,89,1)                                                '"Y"
  FALSE: bytefill(@Text3+3,78,1)                                                '"N"
Case LeapSec
  TRUE: bytefill(@Text3+8,89,1)
  FALSE: bytefill(@Text3+8,78,1)
Case DSTStatus
  DSTStandard : bytefill(@Text3+14,78,1)                                                  '"N"ot in effect
  DSTEnding   : bytefill(@Text3+14,69,1)                                                  '"E"nding
  DSTStarting : bytefill(@Text3+14,66,1)                                                  '"B"eginning
  DSTEnabled  : bytefill(@Text3+14,89,1)                                                  '"Y" (in effect)

{Do serial debug out}
Repeat until not lockset(SerialSem)
pst.char(pst#PC)
pst.char(0)
pst.char(6)                           ' Move cursor
pst.str(String("Last Valid Frame:",pst#NL))
pst.bin(Frames,32)
pst.Str(String(" "))
pst.bin(Frames[1],32)
pst.char(pst#NL)
pst.Dec(Minutes)
pst.Str(String("m, "))
pst.Dec(Hours24)
pst.Str(String("h, "))
pst.Dec(Days)
pst.Str(String("days. DUT: "))
If DUTSign == NEGX
  pst.Str(String("E"))
pst.dec(DUT)
pst.str(String(" sc/10, Year 20"))
pst.dec(Years)
pst.str(String(". LY:"))
if LY
  pst.str(String("Y"))
else
  pst.str(String("N"))
pst.str(String(" LeapSec coming:"))
if LeapSec
  pst.str(String("Y"))
else
  pst.str(String("N"))
pst.str(String(" DST: "))
case DSTStatus
  DSTStandard : pst.str(String("No "))
  DSTEnding   : pst.str(String("Ending "))
  DSTStarting : pst.str(String("Beginning "))
  DSTEnabled  : pst.str(String("Yes "))
pst.str(String("GMT"))

if GMThrs => 0
  pst.char("+")
pst.dec(GMThrs)
pst.char(pst#CE)
pst.char(pst#NL)
if LastDayOfMonth
  pst.str(String("Last Day of Month = TRUE"))
else
  pst.char(pst#CE)

tm1 := (cnt - tm1)/ms
pst.str(String("Parse routine took: "))
pst.dec(tm1)
pst.str(String(" ms."))

lockclr(SerialSem)

PRI CheckDST

If (GlHours == 1 and GlMinutes == 59) and (DSTStat == DSTEnding or DSTStat == DSTStarting)
'If it's 1:59am and the DST status is about to change, and we haven't already done a rollback once tonight already,
  Case DSTStat
    DSTStarting :
      DSTChanging := 1 ' We're leaping forward from 1:59 to 3:00am (Springtime, DST Starting.)
    DSTEnding :
      DSTChanging := -1  ' We're doing the 1:00am hour twice tonight.

PRI ParseWWVB(EdgeTime, Valid) : Value | tempwidth, tempcount, tempSNR

{{This function waits for the pulse measuring cog to update the global edgeCnt variable, signifying a new bit has been
detected. This is checked once per 10ms and then we go back to sleep if no new bit is ready. When a new bit is found,
the function then codes the result based on the overall duration of the pulse. WWVB pulses are verrry long.

The function returns 0 for a 200ms pulse, 1 for a 500ms pulse, 2 for a "marker" 800ms pulse, and NEGX for a pulse of
an obviously invalid duration.

EdgeTime (pass by reference) returns the CNT at the time of the detected leading negative edge in this variable
(if the pulse is valid), so that real time clockkeeping can be as accurate as possible.
}}

Repeat
  last := edgeCnt                                       ' Save current pulse edge time
  Repeat while last == edgeCnt                          ' As long as we don't have a new pulse yet, just wait.
    WaitCnt(ms + cnt)                                   ' Pause, wait for a new pulse to be returned: Poll every 1ms

  Repeat until not LockSet(RadioSem)  ' Get lock again
  tempcount := edgeCnt                ' Read both the new edge start time and the pulsewidth as a matched set
  tempwidth := pulsewidth
  LockClr(RadioSem)                   ' Release semaphore

  tempSNR := (tempcount - last) / ms
  UpdateSNR(tempsnr)                        ' Update running average of p-p times
  LONG[Valid] := ||(1000 - tempSNR) =< 50   ' Pulse is "valid" if within 50ms of 1 second total duration since last pulse.
Until tempwidth => 150                      ' Just ignore short pulses entirely.

Case tempWidth                  ' Parse new bit value from the duration (within defined tolerance range)
    150..230 :
       Value := 0
    450..530 :
       Value := 1
    650..830 :                   ' More leeway for short markers, since they're very long pulses and more noise prone.
       Value := MARKER
    Other : Value := NEGX

If Value <> NEGX                ' If the bit was valid, save the counter value when the leading edge was detected,
  Long[EdgeTime] := tempCount
Else
  Long[EdgeTime] := NEGX        ' Otherwise set it to NEGX.
  Long[Valid] := False          ' Bad pulsewidth means invalid bit as well.

'Writerawbits(tempwidth, tempcount-last, tempcount)                                     'DEBUGOUT: Raw bits
if Cognew(Writerawbits(tempwidth, tempcount-last, tempcount),@stack) == -1                 'DEBUGOUT: Raw bits
  DbgErr(String("No cog for Writerawbits."))
  Abort

PRI AdjustForGMT(hoursaddr,daysaddr,monthaddr,yearsaddr)

{Add GMT offset, and then add one more hour if DST is observed, and either "in effect" or "DST ends today but it's
not 2AM (local time) yet."}

LONG[hoursaddr] += GMTHrs - (DSTObserved and (DSTStatus == DSTEnabled or (DSTStatus == DSTEnding and (LONG[hoursaddr] + GMTHrs < 2))))

'Now we need to deal with the rollovers/rollbacks that might result from GMT/DST offset.
If LONG[hoursaddr] < 0
  LONG[hoursaddr] += 24        ' If Hours becomes negative, add 24 and subtract a day.
  LONG[daysaddr]--
Elseif LONG[hoursaddr] > 23    ' Alternately, if Hours exceeds 24, subtract 24 and add a day.
  LONG[hoursaddr] -= 24
  LONG[daysaddr]++

If LONG[daysaddr] < 1          ' If Days becomes less than 1 we have to roll back to the previous month,
  LONG[monthaddr]--
  If LONG[monthaddr] < 1       ' And if month then becomes less than January it needs to be reset to December...
    LONG[monthaddr] := 12
    LONG[yearsaddr]--          ' Which means it's also the previous year.
  Case LONG[monthaddr]         ' Furthermore, if we had to roll back the month now we have to figure out what the last day of that month is and reset also.
    2:
      LONG[daysaddr] := 28 - LY
    4, 6, 9, 11:
      LONG[daysaddr] := 30
    Other:
      LONG[daysaddr] := 31

If LONG[daysaddr] > 28         ' Finally, if we're in day 29+, we might have rolled forward past the end of the month.
  Case LONG[monthaddr]
    2:                         ' In February we might've rolled forward to the 29th via GMT offset, so is that legit (LY), or do we need to roll to March 1?
      LONG[daysaddr] -= LY     ' ADDS 1 if it's a leap year, 0 if not.
      If (LONG[daysaddr] == 29 and not LY) or (LONG[daysaddr] == 30 and LY) ' Check if we rolled forward past the end of the month and move to March 1 if so.
        LONG[daysaddr] := 1                                                 '
        LONG[monthaddr]++
    4, 6, 9, 11:               ' Handles roll-forward of 30-day months
      If LONG[daysaddr] > 30
        LONG[daysaddr] := 1
        LONG[monthaddr]++
    Other:                     ' Handles roll-forward of 31-day months
      If LONG[daysaddr] > 31
        LONG[daysaddr] := 1
        LONG[monthaddr]++
        If LONG[monthaddr] > 12 ' If we roll past December, it's now January of next year.
          LONG[monthaddr] := 1
          LONG[yearsaddr]++

PRI LastDayOfMonth
 ' Returns TRUE/FALSE if it's the last day of the present month.
Case GlMonths
  2 :
    If GlDays == 28 - DOTW.IsLY(GlYears)                         ' TRUE is -1, so subtract to get proper number of days in a leap year Feb.
      Return TRUE
  4, 6, 9, 11:
    If GlDays == 30
      Return TRUE
  Other:
    If GlDays == 31
      Return TRUE

Return FALSE

PRI Resync(SecNum) | SecAdjust, MinWait
{This method resyncs the running clock and applies a correction via global variable so that the seconds
themselves are shifted to the correct position based on the leading edge of the minute-start MARK from the radio as well as
the indicated UTC-to-DUT conversion factor indicated by the radio frame (+/- 0-0.9 sec.)                                         }

SecAdjust := 0
MinWait := (205*ms) + (clkfreq / 10 * DUT)                   ' Adjustment for DUT in clock ticks.
Repeat
  If MinWait < 381                                           ' If true, WaitCnt would fail.
    MinWait := clkfreq + MinWait                             ' A sufficiently small or neg DUT means we have to set seconds back by one but waitcnt for longer.
    SecAdjust += 1
Until MinWait => 381

waitcnt(MinWait + cnt)                                       ' Calibrated delay - gets us close to being in sync.

Repeat until ClockMode == RTC#READCLOCK
Repeat until not lockset(i2cSem)                             ' Get the clock lock
GlSeconds := SecNum + 1 + SecAdjust                          ' Set seconds to the next second value
ClockMode := RTC#SYNCCLOCK                                   ' Write the seconds to the chip immediately.
Lockclr(i2cSem)                                              ' Release the lock

PRI UpdateSNR(ppTime) | Index, Average
{
This function keeps a running average of the last SNRSAMPLES pulses' time between leading edges.  In a
perfect noise-free environment, each pulse's leading edge will be exactly 1 second apart. In reality, the
leading edges can be off by +/-30ms or so, but they tend to cluster within +/-10.  In any event, as noise starts
to creep in, you get spurious pulses that artificially shorten ones that should be longer, and the p-p times
decrease.  The further away from 1000ms the average gets, the noisier the signal is.  This can be used to generate
a display of rough signal quality, averaged over as many samples as you care to track.
}

SNR[SNRPointer] := ppTime                               ' Update the oldest sample with the latest p-p time.
If ++SNRPointer == SNRSamples
  SNRPointer := 0

Average := 0                                            ' Average all trailing samples.
Repeat Index from 0 to SNRSamples - 1
  Average += SNR[Index]
Average /= SNRSamples

Case ||(1000 - Average)                                 ' How far from 1000ms is the current average?
  0..100:
    SNRAverage := 3
  100..400:
    SNRAverage := 2
  401..700:
    SNRAverage := 1
  Other:
    SNRAverage := 0

PRI Writerawbits(tempwidth, ppTime, count) | bitvalid
{Report basic info about detected bits to the terminal}

bitvalid := TRUE
Repeat until not lockset(SerialSem)
if tempwidth => 150
  pst.Str(String(pst#PC,1,1))                           ' Move cursor
  pst.Str(String(pst#NL, "Last pulse width: "))
  pst.Dec(tempwidth)
  pst.Str(String("ms. p-p time: "))
  pst.Dec(pptime / ms)
  pst.Str(String("ms.   "))
else
  pst.Str(String(".    "))

Case tempWidth                  ' Parse new bit value from the duration (within defined tolerance range)
    150..235 :
       pst.Str(String(pst#px,42," 0 bit"))
    450..530 :
       pst.Str(String(pst#px,42," 1 bit"))
    650..830 :                   ' More leeway for short markers, since they're very long pulses.
       pst.Str(String(pst#px,42," MARK"))
    Other:
       bitvalid := FALSE

if ||(1000 -(pptime/ms)) > 50
  bitvalid := FALSE

If not bitvalid
  pst.Str(String(pst#px,42," INVALID"))
else
  pst.Char(pst#CE)

pst.Str(String(pst#px,50," Cnt: "))
pst.hex(count,8)

lockclr(SerialSem)

PRI WriteSyncedBits(threshoffset,sec,Frame0,Frame1,Framevalid)
{Write additional info to the terminal when locked onto the signal and parsing specific bits}

Repeat until not lockset(SerialSem)
pst.char(pst#PC)
pst.char(0)
pst.char(4)                           ' Move cursor
pst.Str(String("Sync locked.",Pst#NL,"threshoffset = "))
pst.Dec(1000 * threshoffset / CLKFREQ)
pst.Str(String(" bitplace ="))
pst.Dec(sec)
pst.Str(String(" Frame ="))
pst.Hex(Frame0,8)
pst.Hex(Frame1,8)
if not framevalid
  pst.Str(String(" Frame Invalid",pst#CE))
else
  pst.Char(pst#CE)
lockclr(SerialSem)

PRI DbgErr(ErrorMsg)
{"Bluescreen" the terminal and print the string at location ErrorMsg repeatedly.}

  repeat until not lockset(SerialSem)
  repeat                                                   ' Loop forever. ("Bluescreen." :-) )
     pst.char(pst#CS)
     pst.Str(ErrorMsg)                                     ' Don't release the semaphore!
     waitcnt(clkfreq + cnt)                                ' Resend every second for late-attach debugging.


PRI WriteRTCTime | blink,OldSeconds,OldMinutes,OldHours,OldWeekday,OldDays,OldMonths,OldYear
{
This function runs in a separate cog and does the main output to a Parallax 2x16 serial LCD.
  1. Set up buttons, temporary variables, and custom characters.
  2. Display splash screen.
  3. Main loop: Look for a button press and enter debug/options screens if so.  Otherwise, display the time.
}

OldSeconds := NEGX
OldMinutes := NEGX
OldHours := NEGX
OldWeekday := NEGX
OldDays := NEGX
OldMonths := NEGX
OldYear := NEGX
Reset := TRUE

DIRA[BUTTON1]~                                           'Set button pins as inputs

Blink := FALSE
LCD.init(LCD_PIN,19200,2)                               ' 2nd serial port for clock output
LCD.backlight(TRUE)                                     ' Turn on the light
waitcnt(ms * 50 + cnt)
LCD.custom(1,@OneBar)                                   ' Set up custom chars
LCD.custom(2,@TwoBars)
LCD.custom(3,@ThreeBars)
LCD.custom(6,@SyncFound)
LCD.custom(7,@NoSync)
LCD.cursor(0)                                           ' Cursor invisible

LCD.cls                                                 ' Splash screen
LCD.str(String("WWVB Clock 0.7"))
LCD.putc(pst#NL)
LCD.str(String("Andrew Silverman"))
waitcnt(clkfreq*2 + cnt)
LCD.cls

{Main Loop}
repeat
  if Button.ChkBtnPulse(BUTTON1,0,50)                      ' See if button one has been pressed (low) for at least 1 ms.
    DisplayDiags                                           ' Switch to diagnostic display.
  else
    DisplayTime(@OldSeconds,@OldMinutes,@OldHours,@OldWeekday,@OldDays,@OldMonths,@OldYear)

PRI DisplayDiags | press
{Display debug and options screens, use button presses to advance.}
  LCD.Cls
  LCD.str(String("Last good frame:"))
  LCD.str(@TEXT1)
  Repeat Until Button.ChkBtnPulse(BUTTON1,0,50)         ' Wait for button press to move on to page 2.
  LCD.gotoxy(0,1)
  LCD.str(@TEXT2)
  Repeat Until Button.ChkBtnPulse(BUTTON1,0,50)         ' Wait for button press to move on to page 3.
  LCD.Cls
  LCD.str(String("LY/LS/DST:"))
  Case LY
    TRUE: bytefill(@Text3+3,89,1)
    FALSE: bytefill(@Text3+3,78,1)
  Case LeapSec
    TRUE: bytefill(@Text3+8,89,1)
    FALSE: bytefill(@Text3+8,78,1)
  Case DSTStatus
    0 : bytefill(@Text3+14,78,1)
    1 : bytefill(@Text3+14,69,1)
    2 : bytefill(@Text3+14,66,1)
    3 : bytefill(@Text3+14,89,1)
  LCD.gotoxy(0,1)
  LCD.str(@TEXT3)
  Repeat Until Button.ChkBtnPulse(BUTTON1,0,50)         ' Wait for button press to move on to page 4.

  LCD.Cls
  LCD.str(String("Current GMT:"))
  LCD.gotoxy(0,1)
  LCD.str(String("GMT:"))
  If GmtHrs => 0
    LCD.str(String("+"))
  LCD.dec(GmtHrs)

  Repeat
    press := Button.ChkBtnHoldTime(BUTTON1,0,1,1000)
    If press => 1000 ' If the button was held for one second let the user change GMT
      Button.WaitforClear(Button1,0,5)
      UpdateGMTSetting
  Until press > 0
  Button.WaitforClear(Button1,0,5)

  Reset := TRUE

PRI UpdateGMTSetting | blink, delta, delay, press, temp
{Blink the GMT setting and use the button to change its value.}

Blink := FALSE
press := 0
delta := clkfreq / 3
delay := cnt + delta

Repeat
  LCD.gotoxy(4,1)                                         ' Position cursor at the GMT value
  If cnt => delay
    if not Blink
      LCD.str(String("   "))
      Blink := TRUE
    else
       If GmtHrs => 0
         LCD.str(string("+"))
       LCD.dec(GmtHrs)
       Blink := FALSE
    delay := delta + cnt                                  ' Reset the blink timer

  press := Button.ChkBtnHoldTime(BUTTON1,0,1,1000)

  if press < 1000 and press > 0                           ' Short button press detected
    GMTHrs++
    if GMTHrs > 14                                        ' Wraparound
      GMTHrs := -12
Until press => 1000                                       ' Exit the loop
Button.WaitforClear(Button1,0,5)

repeat until ClockMode == RTC#READCLOCK
repeat until not lockset(i2cSem)

RTC.setGMTHours(GMTHrs)                               ' Write GMT value to NVRAM - safe while we have semaphore.

'Debug assertion
temp := RTC.getGMTHours
if temp <> GMTHrs
  DbgErr(String("GMT not read back successfully!"))

Lockclr(i2cSem)

PRI DisplayTime(_OldSeconds,_OldMinutes,_OldHours,_OldWeekday,_OldDays,_OldMonths,_OldYear) | AdjHours,AdjDays,AdjMonths,AdjYears,Weekday

    If Reset == TRUE
       LCD.Cls

    LCD.gotoxy(2,0)
    LCD.putc("/")
    LCD.gotoxy(2,1)
    LCD.putc(":")
    LCD.gotoxy(5,1)
    LCD.putc(":")

    If ClockValid

      If Reset
        LY := DOTW.IsLY(GlYears+2000)                   ' Initialize LY value
        repeat until not lockset(i2csem)
        DSTStatus := RTC.GetDSTStatus                  ' Read DST from NVRAM
        if DSTStatus < 0 or DSTStatus > 4
          RTC.setDSTStatus(0)
        GMTHrs := RTC.GetGMTHours
        if GMTHrs < -12 or GMTHrs > 14
          RTC.setGMTHours(0)
        lockclr(i2csem)

      ' Now we need to convert the GMT time from the chip to local-adjusted offset time.
      AdjHours := GLHours
      AdjDays := GLDays
      AdjMonths := GLMonths
      AdjYears := GLYears
      AdjustForGMT(@AdjHours,@AdjDays,@AdjMonths,@AdjYears)

      If LONG[_OldMonths] <> AdjMonths or Reset           ' Has clock value changed, or are we resetting the whole display due to mode change?
        LONG[_OldMonths] := AdjMonths
        LCD.gotoxy(0,0)
        if AdjMonths < 10
          LCD.putc("0")
        LCD.dec(AdjMonths)                                 ' Display Date to the LCD

      If LONG[_OldDays] <> AdjDays or Reset
        LONG[_OldDays] := AdjDays
        LCD.gotoxy(3,0)
        if AdjDays < 10
          LCD.putc("0")
        LCD.dec(AdjDays)

      If LONG[_OldYear] <> AdjYears or Reset
        LONG[_OldYear] := AdjYears
        LCD.gotoxy(5,0)
        LCD.str(String("/20"))
        if AdjYears < 10
          LCD.putc("0")
        LCD.dec(AdjYears)

      If LONG[_OldHours] <> AdjHours or Reset
        LONG[_OldHours] := AdjHours
        LCD.gotoxy(0,1)
        if AdjHours == 0 or AdjHours == 12
          LCD.str(String("12"))
        else
          if AdjHours // 12 < 10
            LCD.putc("0")
          LCD.dec(AdjHours // 12)                            ' Display Time to the LCD

      'GMT Adjustment does not affect minutes or seconds
      If LONG[_OldMinutes] <> GlMinutes or Reset
        LONG[_OldMinutes] := GlMinutes
        LCD.gotoxy(3,1)
        if GlMinutes < 10
          LCD.putc("0")
        LCD.dec(GlMinutes)

      if GlSeconds <> LONG[_OldSeconds] or Reset                 ' Has the time changed since last iteration?
        LONG[_OldSeconds] := GlSeconds                           ' Save the current seconds for the next iteration.
        LCD.gotoxy(6,1)
        if GlSeconds < 10
          LCD.putc("0")
        LCD.dec(GlSeconds)

        If LeapSec and LastDayOfMonth and AdjHours == 23 and GLMinutes == 59 and GLSeconds == 59 ' Special leap second processing
          Repeat until GLSeconds == 1                   ' Wait for next second
          Resync(0)                                     ' Set clock back to 0 seconds

      LCD.gotoxy(8,1)
      if AdjHours > 11
        LCD.str(String("pm"))
      else
        LCD.str(String("am"))

      LCD.gotoxy(11,0)

      Weekday := DOTW.DOTW(AdjYears+2000, AdjMonths, AdjDays)
      Case WeekDay
        0: LCD.str(String("Sun"))
        1: LCD.str(String("Mon"))
        2: LCD.str(String("Tue"))
        3: LCD.str(String("Wed")) ' Write the day of the week to the LCD
        4: LCD.str(String("Thu"))
        5: LCD.str(String("Fri"))
        6: LCD.str(String("Sat"))

    Else
      LCD.gotoxy(0,0)
      LCD.str(String("--/--/----",pst#NL,"--:--:--am")) ' Time isn't valid yet, so display dashes until it is.

    LCD.gotoxy(15,0)            ' Display signal locked indicator
    If Not SyncLocked           ' Blink the "searching" indicator
      If GlSeconds // 2 == 0    ' One second per flip
        LCD.putc(7 + SyncLocked)
      Else
        LCD.putc(" ")             ' Blank it to avoid leftover dots.
    Else
      LCD.putc(7 + SyncLocked)  ' Display the locked indicator solidly

    LCD.gotoxy(15,1)
    If SNRAverage > 0           ' If the SNR is better than 0, display some cellphone bars to tell the user about signal quality.
      LCD.putc(SNRAverage)
    else
      LCD.putc(" ")

    LCD.gotoxy(11,1)
    LCD.putc("G")
    if GmtHrs => 0
      LCD.putc("+")
    LCD.dec(GmtHrs)

    if Reset                    ' Go back to optimized updating.
      Reset := False

DAT
SyncFound     Byte $08,$15,$02,$04,$04,$04,$0E,$00
NoSync        Byte $00,$00,$00,$04,$04,$04,$0E,$00                ' Custom Chars
OneBar        Byte $00,$00,$00,$00,$00,$10,$10,$00
TwoBars       Byte $00,$00,$00,$04,$04,$14,$14,$00
ThreeBars     Byte $00,$01,$01,$05,$05,$15,$15,$00
Text1         byte "xx:xx, Day xxx", 0
Text2         byte "Yr:20xx, DUTxx", 0
Text3         byte "LY:x LS:x DST:x",0

{{
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                   TERMS OF USE: MIT License                                                  │
├──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation    │
│files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,    │
│modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software│
│is furnished to do so, subject to the following conditions:                                                                   │
│                                                                                                                              │
│The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.│
│                                                                                                                              │
│THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE          │
│WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR         │
│COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,   │
│ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
}}