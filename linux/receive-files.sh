#!/usr/bin/expect -f

if { $argc < 2 } {
  send_user "Usage     : $argv0  user_host_source_path  local_save_path\n"
  send_user "Example   : $argv0  lz@10.1.2.3:test       test\n"
  send_user "Example   : $argv0  lz@10.1.2.3:test/*     test/\n"
  send_user "If no auto rsync/scp authentication, you should export MY_SS_PASS\n"
  exit
}

set REMOTE_SOURCE [lindex $argv 0]
set LOCAL_SAVE [lindex $argv 1]

if { [ regexp {^\w+@\w+} $REMOTE_SOURCE ] < 1 } {
    if { [ string length $env(SSUSER) ] > 0 } {
        send_user "Will add $env(SSUSER) to $REMOTE_SOURCE\n"
        set REMOTE_SOURCE $env(SSUSER)@$REMOTE_SOURCE
    } elseif { [ string length $env(USER) ] > 0 } {
        send_user "Will add $env(USER) to $REMOTE_SOURCE\n"
        set REMOTE_SOURCE $env(USER)@$REMOTE_SOURCE
    } elseif { [ string length $env(USERNAME) ] > 0 } {
        send_user "Will add $env(USERNAME) to $REMOTE_SOURCE\n"
        set REMOTE_SOURCE $env(USERNAME)@$REMOTE_SOURCE
    } else {
      send_user "No user name can be add to $REMOTE_SOURCE\n"
      exit
    }
}

set PASSWORD $env(MY_SS_PASS)
set timeout -1
if { [ string length [ exec whereis rsync | grep /rsync ] ]  > 0 } {
    spawn rsync -aup -rvy $REMOTE_SOURCE $LOCAL_SAVE --exclude=*.pdb
} else {
    spawn scp -rv $REMOTE_SOURCE $LOCAL_SAVE
}

expect {
    "*yes/no*" { send "yes\n"; exp_continue }
    "*assword:*"  { send -- $PASSWORD; send "\n"; send_user "\n\n"; exp_continue }
}
