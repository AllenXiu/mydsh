' Auto-start official DeepSeek Harness Web UI at logon (user startup folder).
' TEMPLATE - do not copy verbatim. install.ps1 generates the real Startup copy
' with <REPO_ROOT> substituted by this repo's absolute path, so the boot chain
' runs the repo's deploy\windows\dsh-autostart.cmd directly and `git pull`
' ships new boot logic.
Set sh = CreateObject("WScript.Shell")
sh.Run """<REPO_ROOT>\deploy\windows\dsh-autostart.cmd""", 0, False
Set sh = Nothing
