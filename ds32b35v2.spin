'' ******************************************************************************
'' * DS32B35 Object V1.0                                                        *
'' * Andrew Silverman, November 2010                                            *
'' * Mostly derived from James Burrows' DS1307 Object, v1.2, May 2006           *
'' ******************************************************************************
''
'' Modifications, November 2010, Andrew Silverman
'' - Switched to using the "PASM i2c driver" sub object to enable Fast Mode operation (400khz clock)
'' - Separated resetting the seconds from the remaining registers so that the chip can be reset as rapidly as possible for accuracy.
'' - Per the datasheet, you then have 1 second to set the remaining registers to avoid rollover issues.
'' - Removed seconds parameter from SetTime, which then sets just the hours and minutes.  SetDate is unmodified.
'' - Also added GetWeekday function to return the Day Of The Week from the chip.
'' - Added functions to get/set OSF bit in the status register, which indicates whether the on-chip time is considered valid. (Resets on power loss.)
'' - Added function to clear the aging register.
'' - Added functions to read and write bytes in the 2K FRAM (NVRAM) of the DS32B35 chip, given a page and an address.
''
'' The init object takes some new parameters, including the start address of several contiguous variables which make up a global time array,
'' as well as a global "Run" flag which is used to communicate when writes back to the clock chip should take place.
'' 
'' Init spins off a separate cog which reads the clock chip continuously and writes the results into the global time structure.
'' In order to interrupt the read cycle to write new values to the chip, update the global time structure and set Run to 1 or 2.
'' It will be reset to 0 when the command has completed.
'' To call various public functions directly from other modules, set the Semaphore (lock bit) first, to pause the clock-reading cog.
'' When complete, lockclr(semaphore) to return it to normal operation.
'' 
'' Run = 0 means the clock is in its normal read loop. 1 = Write date and time (but not seconds), 2 = Run the syncseconds routine.
'' A semaphore is provided by the GetSemID function to allow atomic reads/writes of the global time structure from the caller.
'' Also, ensure that Run = 0 before setting to 1 or 2:  It's possible to create a race condition if you run multiple commands
'' in near-succession without waiting for the first to complete.

''
'' Original documentation follows:
''------------------------------------------------------------------------------------------------------
'' this object provides the PUBLIC functions:
''  -> Init  - sets up the address and inits sub-objects such
''  -> settime - sets the clock time
''  -> setdate - sets the date
''  -> gettime - gets the time into the object - use getday, getmonth etc to read the variables
''  -> getdate - gets the date into the object - see above
''  -> getday/getmonth etc - returns the data got when you call gettime/getdate
''
'' this object provides the PRIVATE functions:
''  -> i2c2bcd - performs integer to BCD conversion
''  -> bcd2int - performs BCD to integer conversion
''
'' this object uses the following sub OBJECTS:
''  -> PASM i2c driver
''
'' Revision History:
''  -> V1 - Release
''      -> V1.1 - Documentation update, slight code tidy-up
''                Changed to include a start status
''                Changed to stop object initializing if device not present on i2cBus
''      -> V1.2 - Updated to allow i2cSCL line driving pass-true to i2cObject
''  -> V2 - Modified by Andrew Silverman as described above
''
'' The default address is %1101_0000 for the clock, and %1010_abcR for FRAM, where abc specifies page 0-7 (256 bytes each)
'' and R specifies read(1)/write(0).

OBJ
  PASM          : "PASM i2c driver"

VAR
  long  DS32B35_Seconds
  long  DS32B35_Minutes
  long  DS32B35_Hours
  long  DS32B35_Date
  long  DS32B35_Days
  long  DS32B35_Months   
  long  DS32B35_Years
  long  started
  long  Stack[30] ' Tested at 16 max usage.

CON
' Clock modes
  READCLOCK   = 0
  WRITECLOCK  = 1
  SYNCCLOCK   = 2

' Memmap of NVRAM
  DSTSTATUS = 0
  GMTZONE = 1                   ' This is a LONG - takes 4 bytes. Next avail is 5!                   

' I2C addresses  
  RTC_ADDR = %11010000                                    ' I2C Address for DS32B35 RTC chip.
  NV_ADDR = %10100000                                     ' I2C Address for DS32B35 FRAM section

DAT
TimeAddr      LONG 0
DateAddr      LONG 0
RTCAddr       LONG 0
SDAPin        LONG 0
SCLPin        LONG 0
I2CSemaphore  LONG -1
RunAddr       LONG 0
ms            LONG 0
ClockValid    LONG 0 

PUB init(_TimeAddr, _RunAddr, _ClockValid, _SDAPin, _SCLPin) : okay

  ms := clkfreq / 1000
  ClockValid := _ClockValid
  RunAddr := _RunAddr
  TimeAddr := _TimeAddr
  RTCAddr := RTC_ADDR
  SDAPin := _SDAPin
  SCLPin := _SCLPin
 
  Okay := start
  
  if Okay
    ClearAgingRegister                                  ' Clear aging register at startup
    Repeat
      i2cSemaphore := locknew                           ' Check out a semaphore for accessing the global time structure.
    Until i2cSemaphore <> -1
    COGNEW(ClockLoop,@Stack)                            ' Start the clock reading/writing cog.
    
  return okay
    
PUB start : okay
  ' start the object

  if started == false
    if devicepresent(RTCAddr)
      started := true
      pasm.Initialize(SCLPin)                           ' Start the chip
      SetRegister($0,$0E)                               ' Set the square wave to 1hz output (register $0E, value 0.)
    else
      started := false

  return started

PUB stop
  ' stop the object
  if started == true
    started := false
    
PUB isStarted : result
  return started

'PUB geti2cError : errorCode
'  return i2cObject.getError

PUB GetSemID
  Return i2cSemaphore                  ' Provide method for other cogs to get the semaphore ID being used here.

PUB setDSTStatus(value) | storedVal
  if started == true
    storedVal := readNVRAM(0, DSTSTATUS) ' Check current NVRAM value
    if storedVal <> value                ' Don't bother overwriting memory unless the new value is different from the old.
      writeNVRAM(0, DSTSTATUS, value)
    
PUB getDSTStatus
  if started == true
    return readNVRAM(0, DSTSTATUS)

PUB setGMTHours(value) | index
  if started == true
    repeat index from 0 to 3
      writeNVRAM(0, GMTZONE+index, BYTE[@value][index])

PUB getGMTHours : value | index
  if started == true
    repeat index from 0 to 3
      BYTE[@value][index] := readNVRAM(0, GMTZONE+index)
                                            
PUB setTime(ds_hour, ds_minute)
  if started == true
    ' set the time
    DS32B35_Hours   := int2bcd(ds_hour)
    DS32B35_Minutes := int2bcd(ds_minute)
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 0)        ' Write to clock chip
    pasm.Write(SCLPin,1)                  ' Write to register 1
    pasm.Write(SCLPin,DS32B35_Minutes)    ' Write the minutes
    pasm.Write(SCLPin,DS32B35_Hours)      ' Write the hours to next consecutive register (2)        
    pasm.Stop(SCLPin)

PUB setDate(ds_date,ds_day,ds_month,ds_year)
  if started == true
  ' set the date
    DS32B35_Date   := int2bcd(ds_date)
    DS32B35_Days   := int2bcd(ds_day)
    DS32B35_Months := int2bcd(ds_month)
    DS32B35_Years  := int2bcd(ds_year)  
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 0)        ' Write to clock chip
    pasm.Write(SCLPin,3)                  ' Start writing at register 3 (weekday)
    pasm.Write(SCLPin,DS32B35_Date)       ' Write weekday
    pasm.Write(SCLPin,DS32B35_Days)       ' Write day of month to 4
    pasm.Write(SCLPin,DS32B35_Months)     ' Write month to 5
    pasm.Write(SCLPin,DS32B35_Years)      ' Write years to 6.
    pasm.Stop(SCLPin)    
  
PUB getDate : ds_seconds | ackbit
  ' get the date bytes from the clock
  if started == true
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 0)                      ' Tell clock chip we want to address register 3.
    pasm.Write(SCLPin,3)
    pasm.Start(SCLPin)                                  ' "Restart"
    pasm.Write(SCLPin,RTCAddr | 1)                      ' And tell it we really want to read.
    DS32B35_Date   := pasm.Read(SCLPin,pasm#ACK)        ' Next byte is register 3 (weekday)
    DS32B35_Days   := pasm.Read(SCLPin,pasm#ACK)        ' Then day of month
    DS32B35_Months := pasm.Read(SCLPin,pasm#ACK)        ' Months
    DS32B35_Years  := pasm.Read(SCLPin,pasm#NAK)        ' Years - and send a NAK to terminate the transfer.
    pasm.Stop(SCLPin)
  
PUB getTime : ds_seconds | ackbit
  ' get the time bytes from the clock
  if started == true
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 0)                      
    pasm.Write(SCLPin,0)                                ' Tell chip we're going to address register 0.
    pasm.Start(SCLPin)                                  ' Restart and initiate reads.
    pasm.Write(SCLPin,RTCAddr | 1)
    DS32B35_Seconds := pasm.Read(SCLPin,pasm#ACK)       ' Read seconds from register 0.
    DS32B35_Minutes := pasm.Read(SCLPin,pasm#ACK)       ' Then minutes (register 1)
    DS32B35_Hours   := pasm.Read(SCLPin,pasm#NAK)       ' Hours, and terminate with a NAK.
    pasm.Stop(SCLPin)
    return bcd2int(DS32B35_Seconds)    
  
PUB getOSFValid : Status
  if started == true
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 0)
    pasm.Write(SCLPin,$0F)                              ' We're going to be reading register 0Fh
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 1)                      ' Initiate reads.
    Status := pasm.read(SCLPin,pasm#NAK) >> 7           ' Read one byte, shift bit 7 (OSF) down to bit 0.
    pasm.Stop(SCLPin)
    Status := (Status == 0)                             ' If 0, clock is considered valid. If 1, it's not (so return FALSE.)
    return Status 

PUB SetRegister(input, register)
  if started == true
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 0)                      ' Select our chip.
    pasm.Write(SCLPin,register)                         ' We're going to be writing the selected register
    pasm.Write(SCLPin,input)                            ' Write input
    pasm.Stop(SCLPin)

PUB ClearAgingRegister                                  ' Writes 0 to the aging register in the chip.
  if started == true
    pasm.Start(SCLPin)
    pasm.Write(SCLPin,RTCAddr | 0)
    pasm.Write(SCLPin,$10)
    pasm.Write(SCLPin,0)
    pasm.Stop(SCLPin)

PUB devicePresent(deviceAddress) : ackbit
  ' send the deviceAddress and listen for the ACK
  ackbit := pasm#NAK
  if started == true
    pasm.Start(SCLPin)
    ackbit := pasm.Write(SCLPin,deviceAddress | 0) & 1
    pasm.Stop(SCLPin)
    if ackbit == pasm#ACK
      ackbit := true
    else
      ackbit := false
    return ackbit
        
PUB getHours : result
  return bcd2int(DS32B35_Hours)

PUB getMinutes : result
  return bcd2int(DS32B35_Minutes)

PUB getSeconds : result
  return bcd2int(DS32B35_Seconds)  

PUB getDays : result
  return bcd2int(DS32B35_Days)

PUB getMonths : result
  return bcd2int(DS32B35_Months)

PUB getYears : result
  return bcd2int(DS32B35_Years)

PUB getWeekday : result
  return DS32B35_Date      
  
PRI int2bcd(value) : result
  ' convert integer to BCD (Binary Coded Decimal)
  result := ((value / 10) *16) + (value // 10) 
  return result

PRI bcd2int(value) : result
  ' convert BCD (Binary Coded Decimal) to Integer
  result :=((value / 16) *10) + (value // 16) 
  return result

PRI syncSeconds(_timeaddr)
  if started == true
    ' set everything at once, sets all registers atomically for the chip.
    pasm.Start(SCLpin)
    pasm.Write(SCLpin,RTCAddr | 0)       ' Write to clock chip
    pasm.Write(SCLpin,0)                 ' Write to register 0
    DS32B35_Seconds := int2bcd(LONG[_timeaddr][0])
    pasm.Write(SCLPin,DS32B35_Seconds)   ' Set the specified number

    DS32B35_Hours   := int2bcd(LONG[_timeaddr][2])
    DS32B35_Minutes := int2bcd(LONG[_timeaddr][1])
    DS32B35_Date    := int2bcd(LONG[_timeaddr][3]+1) ' Weekday is 1 to 7 here, not 0 to 6.
    DS32B35_Days    := int2bcd(LONG[_timeaddr][4])
    DS32B35_Months  := int2bcd(LONG[_timeaddr][5])
    DS32B35_Years   := int2bcd(LONG[_timeaddr][6])
    pasm.Write(SCLPin,DS32B35_Minutes)    ' Write the minutes (1)
    pasm.Write(SCLPin,DS32B35_Hours)      ' Write the hours to next consecutive register (2)        
    pasm.Write(SCLPin,DS32B35_Date)       ' Write weekday
    pasm.Write(SCLPin,DS32B35_Days)       ' Write day of month to 4
    pasm.Write(SCLPin,DS32B35_Months)     ' Write month to 5
    pasm.Write(SCLPin,DS32B35_Years)      ' Write years to 6.
    
    pasm.Stop(SCLPin)
    
PRI readNVRAM(page, address): value
  if started == true
    pasm.Start(SCLpin)
    pasm.Write(SCLpin,NV_ADDR | page)
    pasm.Write(SCLPin, address)                         ' Read byte at address
    pasm.Start(SCLpin)                                  ' "Restart"
    pasm.Write(SCLPin,NV_ADDR | 1)                      ' And tell it we really want to read.
    value := pasm.Read(SCLPin,pasm#NAK)                 ' Read the byte, and send NAK.
    pasm.Stop(SCLPin)
    return value
    
PRI writeNVRAM(page, address, value)
  if started == true
    pasm.Start(SCLpin)
    pasm.Write(SCLpin,NV_ADDR | page)
    pasm.Write(SCLpin, address)                         ' Write byte to address
    pasm.Write(SCLPin, value)
    pasm.Stop(SCLPin)
                                                                                                                     
PRI ClockLoop

repeat
  Repeat until not lockset(i2cSemaphore)                ' Get the semaphore
  If LONG[RunAddr] == SYNCCLOCK
    SyncSeconds(TimeAddr)                               ' Syncing the seconds only (for speed)
    LONG[RunAddr] := READCLOCK

  ElseIf LONG[RunAddr] == READCLOCK                      ' If Run is 0, read the clock and set the globals with the result.
    ' get the TIME
    
    LONG[TimeAddr][0] := gettime                         ' Read the chip. (Also returns seconds)
    getdate
    LONG[TimeAddr][1] := getMinutes
    LONG[TimeAddr][2] := getHours
    LONG[TimeAddr][3] := getWeekday - 1                  ' Chip uses 1-7, other funcs are using 0-6.
    LONG[TimeAddr][4] := getDays
    LONG[TimeAddr][5] := getMonths
    LONG[TimeAddr][6] := getYears

    If not LONG[ClockValid]                             ' Our clock isn't valid, we should check whether the chip is valid or not.
      If GetOSFValid
         LONG[ClockValid] := TRUE                       ' If OSF in the chip is 0, our program's clock is now valid too.

  Elseif LONG[RunAddr] == WRITECLOCK                    ' Somebody's asked us to write the time/date back to the chip
    SetTime(LONG[TimeAddr][2], LONG[TimeAddr][1])
    SetDate(LONG[TimeAddr][3]+1, LONG[TimeAddr][4], LONG[TimeAddr][5], LONG[TimeAddr][6]) ' Weekday needs to be 1-7 here hence the +1
    SetRegister($08,$0F)                                ' Clear the OSF bit to tell us later that the chip time is valid now. (Leave 32khz enabled)
    LONG[RunAddr] := READCLOCK                          ' Go back to reading the time.
    
  Lockclr(i2cSemaphore)                                 ' Release the semaphore
   