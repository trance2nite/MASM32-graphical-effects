@echo off
\masm32\bin\rc /v rotozoom.rc
\masm32\bin\ml.exe /c /coff /Cp /nologo rotozoom.asm
\masm32\bin\link.exe /SUBSYSTEM:WINDOWS /RELEASE /VERSION:4.0 /OUT:rotozoom.exe rotozoom.obj rotozoom.res
del rotozoom.res
del rotozoom.obj
pause