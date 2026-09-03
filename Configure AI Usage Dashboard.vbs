Option Explicit

Dim shell, folder, command
Set shell = CreateObject("WScript.Shell")
folder = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\\"))
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "dev.ps1""" -Setup"
shell.Run command, 0, False
