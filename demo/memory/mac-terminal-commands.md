# Mac terminal commands

## Network
Flush the DNS cache: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`
Show this Mac's IP address: `ipconfig getifaddr en0`
Turn WiFi off: `networksetup -setairportpower en0 off`
Turn WiFi on: `networksetup -setairportpower en0 on`
List open ports: `lsof -iTCP -sTCP:LISTEN -n -P`

## Files and disk
Show free disk space: `df -h /`
Show the size of the current folder: `du -sh .`
Find a file by name: `mdfind -name "name"`
Show hidden files in Finder: `defaults write com.apple.finder AppleShowAllFiles -bool true; killall Finder`

## System
Show macOS version: `sw_vers`
Show battery status: `pmset -g batt`
Keep the Mac awake: `caffeinate -d`
Show the busiest processes: `top -o cpu -l 1 | head -20`
Restart the Dock: `killall Dock`
Take a screenshot to the desktop: `screencapture ~/Desktop/shot.png`

## Developer
Show the current git branch and changes: `git status -sb`
Start a local web server in this folder: `python3 -m http.server 8000`
