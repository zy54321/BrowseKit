' BrowseKit hidden launcher.
' Usage: wscript.exe //nologo hidden-run.vbs program.exe arg1 arg2
' Starts the command with window style 0 and does not wait.
If WScript.Arguments.Count < 1 Then
  WScript.Quit 1
End If

Dim cmd, i, part
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
  part = WScript.Arguments(i)
  If i > 0 Then cmd = cmd & " "
  cmd = cmd & """" & part & """"
Next

CreateObject("Wscript.Shell").Run cmd, 0, False
