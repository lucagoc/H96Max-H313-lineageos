::Script for packing/unpacking a SoChip Firmware
@echo off
  echo.
  echo  ------------------------------------------------------------------------------
  echo  I                                                                            I
  echo  I                      Script for runnig imgRePacker.exe                     I
  echo  I                      (c) losber       v1.2                                 I
  echo  I                                                                            I
  echo  ------------------------------------------------------------------------------
  echo.

::Determine target file or directory name

:link1

set target=

  echo.
  echo        Usage:       enter file/directory name and options 
  echo.
  echo        Examples: 
  echo        unpacking    file name: TL-C430PE.img
  echo                     options: /noiso /smt
  echo.
  echo        packing      directory name: TL-C430PE.img.dump
  echo                     options: /noiso /smt
  echo.
  echo        For help:    file name:/help
  echo.
  echo.

set /p target=Enter file name or drag a file/directory here:

if '%target%'=='/help' (imgRePacker "%target%"
 goto link1)

if defined target (goto link2) else (goto link1) 

:link2

set options=

set /p options=Enter options or leave it blank:

:link3
if exist %target% (goto link4) else (goto link1)

::Executing "imgRePacker.exe"
:link4

"%~dp0imgRePacker" "%options%" "%target%"

if not exist "%~dp0%target%.dump\_iso\extracted_rootfs" (
if exist "%~dp0%target%.dump\_iso\rootfs.az.iso" (
set /p rootfs="Do you want to extract files from rootfs image? (y) yes:"
)
)

if not exist "%~dp0%target%.dump\_iso\extracted_rootfs" (
if exist "%~dp0%target%.dump\_iso\rootfs.fex.iso" (
set /p rootfs="Do you want to extract files from rootfs image? (y) yes:"
)
)

if "%rootfs%"=="y" (
if exist "%~dp0%target%.dump\_iso\rootfs.az.iso" (
   mkdir "%target%.dump\_iso\extracted_rootfs"
   "%PROGRAMFILES%\UltraISO\UltraISO.exe" -input "%target%.dump\_iso\rootfs.az.iso" -extract "%target%.dump\_iso\extracted_rootfs" )
) 
if "%rootfs%"=="y" (
if exist "%~dp0%target%.dump\_iso\rootfs.fex.iso" (
   mkdir "%target%.dump\_iso\extracted_rootfs"
   "%PROGRAMFILES%\UltraISO\UltraISO.exe" -input "%target%.dump\_iso\rootfs.fex.iso" -extract "%target%.dump\_iso\extracted_rootfs" )
)

if not exist "%~dp0%target%.dump\_iso\extracted_bootfs" (
if exist "%~dp0%target%.dump\_iso\bootfs.fex.iso" (
set /p bootfs="Do you want to extract files from bootfs image? (y) yes:"
)
)

if "%bootfs%"=="y" (
if exist "%~dp0%target%.dump\_iso\bootfs.fex.iso" (
   mkdir "%target%.dump\_iso\extracted_bootfs"
   "%PROGRAMFILES%\UltraISO\UltraISO.exe" -input "%target%.dump\_iso\bootfs.fex.iso" -extract "%target%.dump\_iso\extracted_bootfs" )
) 

if not exist "%~dp0%target%.dump\_iso\extracted_rootfs\extracted_ramdisk" (
if exist "%~dp0%target%.dump\_iso\extracted_rootfs\ramdisk.iso" (
set /p ramdisk="Do you want to extract files from ramdisk.iso image? (y) yes:"
)
)

if "%ramdisk%"=="y" (
if exist "%~dp0%target%.dump\_iso\extracted_rootfs\ramdisk.iso" (
   mkdir "%target%.dump\_iso\extracted_rootfs\extracted_ramdisk"
   "%PROGRAMFILES%\UltraISO\UltraISO.exe" -input "%target%.dump\_iso\extracted_rootfs\ramdisk.iso" -extract "%target%.dump\_iso\extracted_rootfs\extracted_ramdisk" )
)

echo Done! Press any key for close window

pause>nul

exit
