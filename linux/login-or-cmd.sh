#!/usr/bin/expect -f

if { $argc < 1 } {
  send_user "Usage     : $argv0  user_host    cmd\n"
  send_user "Example   : $argv0  lz@10.1.2.3  \n"
  send_user "Example   : $argv0  lz@10.1.2.3  ps -ef\n"
  send_user "If no auto SSH authentication, you should export MY_SS_PASS\n"
  exit
}

set USER_HOST [lindex $argv 0]
set CMD_ARGS [lrange $argv 1 end]

set PASSWORD $env(MY_SS_PASS)

if { [ regexp {^\w+@\w+} $USER_HOST ] < 1 } {
    if { [ string length $env(SSUSER) ] > 0 } {
        send_user "Will add $env(SSUSER) to $USER_HOST\n"
        set USER_HOST $env(SSUSER)@$USER_HOST
    } elseif { [ string length $env(USER) ] > 0 } {
        send_user "Will add $env(USER) to $USER_HOST\n"
        set USER_HOST $env(USER)@$USER_HOST
    } elseif { [ string length $env(USERNAME) ] > 0 } {
        send_user "Will add $env(USERNAME) to $USER_HOST\n"
        set USER_HOST $env(USERNAME)@$USER_HOST
    } else {
      send_user "No user name can be add to $USER_HOST\n"
      exit
    }
}

set timeout 2
if { [ string length $CMD_ARGS ]  > 0 } {
    spawn ssh $USER_HOST $CMD_ARGS
} else {
    spawn ssh $USER_HOST
}

expect {
    "*yes/no*" { send "yes\n"; exp_continue }
    "*assword:*"  { send -- $PASSWORD; send "\n"; send_user "\n\n"; exp_continue }
}

interact
