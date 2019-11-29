@if "%PATH:~-1%" == "\" set "PATH=%PATH:~0,-1%"

git reflog expire --all --expire=now && git gc --prune=now --aggressive
