{{
===================================================
│ WWVB pulse duration counter/timer.              │
===================================================

Liberally modified from David Gregory's Servo_Input module.


 This Object uses one of a cog's counters to continuously
 poll a negative pulse signal from a WWVB radio clock receiver
 and store the pulse width in milliseconds. CNT at the time of the pulse's
 leading edge is also returned to the caller.

Arguments for the Start method can be declared like this:

  DAT
    pin         LONG 1          'Use Pin 1
    pulseWidth  LONG 1          'Returns pulse width in ms
    edgeCnt     LONG 1          'Holds CNT at the time the reported pulse started.

And then Start would be called like this:

  servoInput.start(@pin,@pulseWidth,@edgeCnt)

}}

VAR
  long  SemID                          'Semaphore for returning results
  byte  Cog                            'Hold ID of cog in use, if any
  long  ms                             'clks per milliseconds
  long  Stack[12]                      'Stack space for new cog

PUB Start(address,width,timestamp) : Success ',ppsPinaddr,ppsstamp): Success
{{Start new radio receiver input process. Return True if successful.}}

  ms := clkfreq / 1000

  Stop

  Repeat
     semID := Locknew            ' Spin until we get a semaphore. (Should just run once.)
  Until semID <> -1

  Success := (Cog := cognew(Measure(address,width,timestamp), @Stack) + 1)

PUB Stop
{{Stop measuring process, if any.}}
  if Cog
    cogstop(Cog~ - 1)

PUB Active: YesNo
{{Return TRUE if process is active, FALSE otherwise.}}
  YesNo := Cog > 0

PUB GetSemID
  Return semID                  ' Provide method for other cogs to get the semaphore ID being used here.

PRI Measure (pinIn,pulsesOut,timestamp) | starttime
{{Continuously acquire pulse width on the pins at address pinsIn,
     and store as milliseconds at the address pulsesOut }}

  dira[LONG[pinIn]]~            ' Set pin for input
  ctra[30..26] := %01100        ' Set mode to "APIN == 0"
  frqa := 1                     ' Increment phsa by 1 for each clock tick
  ctra[5..0] := LONG[pinIn]     ' Set APIN to match the specified input pin

  repeat
      waitpne(|< LONG[pinIn], |< LONG[pinIn], 0) ' Wait for pulse to go low
      starttime := cnt
      waitpeq(|< LONG[pinIn], |< LONG[pinIn], 0) ' Wait for pulse to go high again

      Repeat until not lockset(semID)                   ' Wait until we set the semaphore
      LONG[pulsesOut] := phsa / ms                      ' Calculate pulse Width, in milliseconds
      LONG[timestamp] := starttime                      ' Save system counter of the pulse leading edge (used as synchronization for caller)
      lockclr(semID)                                    ' Clear the semaphore again.
      phsa := 0                                         ' Clear the width counter and do it all again.

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