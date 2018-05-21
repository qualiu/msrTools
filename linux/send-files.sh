#!/usr/bin/expect -f

if { $argc < 2 } {
  send_user "Usage     : $argv0  local_source_path  user_host_save_path \n"
  send_user "Example   : $argv0  test               lz@10.1.2.3:test \n"
  send_user "Example   : $argv0  test/*             lz@10.1.2.3:test/ \n"
  send_user "If no auto rsync/scp authentication, you should export MY_SS_PASS\n"
  exit
}

set LOCAL_SOURCE [lindex $argv 0]
set REMOTE_SAVE [lindex $argv 1]

set PASSWORD $env(MY_SS_PASS)

if { [ regexp {^\w+@\w+} $REMOTE_SAVE ] < 1 } {
    if { [ string length $env(SSUSER) ] > 0 } {
        send_user "Will add $env(SSUSER) to $REMOTE_SAVE\n"
        set REMOTE_SAVE $env(SSUSER)@$REMOTE_SAVE
    } elseif { [ string length $env(USER) ] > 0 } {
        send_user "Will add $env(USER) to $REMOTE_SAVE\n"
        set REMOTE_SAVE $env(USER)@$REMOTE_SAVE
    } elseif { [ string length $env(USERNAME) ] > 0 } {
        send_user "Will add $env(USERNAME) to $REMOTE_SAVE\n"
        set REMOTE_SAVE $env(USERNAME)@$REMOTE_SAVE
    } else {
      send_user "No user name can be add to $REMOTE_SAVE\n"
      exit
    }
}

set timeout -1
if { [ string length [ exec whereis rsync | grep /rsync ] ]  > 0 } {
    spawn rsync -aup -rvy  $LOCAL_SOURCE $REMOTE_SAVE --exclude=*.pdb
} else {
    spawn scp -rv $LOCAL_SOURCE $REMOTE_SAVE
}

expect {
    "*yes/no*" { send "yes\n"; exp_continue }
    "*assword:*"  { send -- $PASSWORD; send "\n"; send_user "\n\n"; exp_continue }
}
