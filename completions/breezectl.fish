# fish completion for breezectl.
#
# Unit names come from `breezectl __complete units`, which reads the list the
# client keeps of the last units it saw, so a Tab does not wait on the network.

# The words before the cursor, without `breezectl` and the options before the
# command. (fish 4 spells -o as -x; both are tried.)
function __breezectl_args
    set -l tokens (commandline -xpc 2>/dev/null; or commandline -opc)
    set -e tokens[1]
    while set -q tokens[1]
        switch $tokens[1]
            case --server -s
                set -e tokens[1..2]
            case '--server=*' --
                set -e tokens[1]
            case '*'
                break
        end
    end
    # Not printf alone: with no words it still prints an empty line.
    set -q tokens[1]; and printf '%s\n' $tokens
end

# The --server given before the command, to pass on.
function __breezectl_server_opt
    set -l tokens (commandline -xpc 2>/dev/null; or commandline -opc)
    for i in (seq (count $tokens))
        switch $tokens[$i]
            case --server -s
                set -l next (math $i + 1)
                set -q tokens[$next]; and printf '%s\n' --server $tokens[$next]
                return
            case '--server=*'
                printf '%s\n' --server (string replace -- '--server=' '' $tokens[$i])
                return
        end
    end
end

function __breezectl_units
    breezectl (__breezectl_server_opt) __complete units 2>/dev/null
end

function __breezectl_servers
    breezectl __complete servers 2>/dev/null
end

set -g __breezectl_commands status st units list timers timer login pair logout unpair servers server diag doctor nerd version help control

function __breezectl_first
    test (count (__breezectl_args)) -eq 0
end

# True when the command is one of the space-separated $cmds and $n words
# follow it so far.
function __breezectl_at --argument-names cmds n
    set -l a (__breezectl_args)
    contains -- "$a[1]" (string split ' ' -- $cmds); or return 1
    test (math (count $a) - 1) -eq $n
end

# Same, one level down: `timers off`, `servers use` ...
function __breezectl_sub_at --argument-names cmds subs n
    set -l a (__breezectl_args)
    contains -- "$a[1]" (string split ' ' -- $cmds); or return 1
    contains -- "$a[2]" (string split ' ' -- $subs); or return 1
    test (math (count $a) - 2) -eq $n
end

# True at slot $n after a unit's name: `breezectl NAME w1 ... |` with n-1
# words after the name, or the same after `control`.
function __breezectl_slot --argument-names n
    set -l a (__breezectl_args)
    if test "$a[1]" = control
        set -e a[1]
    else if contains -- "$a[1]" $__breezectl_commands
        return 1
    end
    set -q a[1]; or return 1
    test (count $a) -eq $n
end

complete -c breezectl -f

# Before the command.
complete -c breezectl -n __breezectl_first -l server -s s -x -a '(__breezectl_servers)' -d 'use this saved server'
complete -c breezectl -n __breezectl_first -a status -d 'how the units are'
complete -c breezectl -n __breezectl_first -a units -d 'the units and their ids'
complete -c breezectl -n __breezectl_first -a timers -d 'list, set or cancel timers'
complete -c breezectl -n __breezectl_first -a login -d 'pair this machine with a server'
complete -c breezectl -n __breezectl_first -a logout -d 'revoke and forget a saved server'
complete -c breezectl -n __breezectl_first -a servers -d 'list, choose, rename or remove saved servers'
complete -c breezectl -n __breezectl_first -a diag -d 'check the server and this machine'
complete -c breezectl -n __breezectl_first -a nerd -d 'diag, and a JSON report'
complete -c breezectl -n __breezectl_first -a version -d "this version, and the server's"
complete -c breezectl -n __breezectl_first -a help -d usage
complete -c breezectl -n __breezectl_first -a control -d 'control a unit whose name is also a command'
complete -c breezectl -n __breezectl_first -a '(__breezectl_units)' -d unit

# A unit's settings, in breeze-core control's order.
complete -c breezectl -n '__breezectl_slot 1' -a 'cool heat dry auto fan on off none' -d mode
complete -c breezectl -n '__breezectl_slot 2' -a none -d 'temperature: 16-30, half degrees'
complete -c breezectl -n '__breezectl_slot 3' -a 'both horizontal vertical off none' -d flaps
complete -c breezectl -n '__breezectl_slot 4' -a 'silent low medium high max auto none' -d 'fan speed'
complete -c breezectl -n '__breezectl_slot 5' -a 'turbo eco turbo+eco no-turbo no-eco none' -d extra
complete -c breezectl -n '__breezectl_slot 6' -a '15m 30m 45m 1h 2h' -d 'switch off after'
complete -c breezectl -n '__breezectl_at control 0' -a '(__breezectl_units)' -d unit

complete -c breezectl -n '__breezectl_at "status st" 0; or __breezectl_at "status st" 1; or __breezectl_at "status st" 2' -a '(__breezectl_units)' -d unit

complete -c breezectl -n '__breezectl_at "timers timer" 0' -a 'list off start cancel'
complete -c breezectl -n '__breezectl_sub_at "timers timer" "off start on cancel rm delete" 0' -a '(__breezectl_units)' -d unit
complete -c breezectl -n '__breezectl_sub_at "timers timer" "cancel rm delete" 0' -a all -d 'every timer'
complete -c breezectl -n '__breezectl_sub_at "timers timer" off 1' -a '15m 30m 45m 1h 2h' -d after
complete -c breezectl -n '__breezectl_sub_at "timers timer" "start on" 2' -a 'today tomorrow 2 3 4 5 6 7' -d day

complete -c breezectl -n '__breezectl_at "servers server" 0' -a 'list use rename remove'
complete -c breezectl -n '__breezectl_sub_at "servers server" "use rename remove rm forget" 0' -a '(__breezectl_servers)' -d server
complete -c breezectl -n '__breezectl_at "logout unpair" 0' -a '(__breezectl_servers)' -d server

complete -c breezectl -n '__fish_seen_subcommand_from login pair' -l name -x -d 'save the server under this name'
complete -c breezectl -n '__fish_seen_subcommand_from login pair' -l label -x -d 'name this device on the server'
complete -c breezectl -n '__fish_seen_subcommand_from login pair' -l ca -r -F -d "the server's CA certificate"
complete -c breezectl -n '__fish_seen_subcommand_from login pair' -l key-stdin -d 'read the API key from standard input'
complete -c breezectl -n '__fish_seen_subcommand_from login pair' -l yes -d 'ask nothing'
complete -c breezectl -n '__breezectl_at nerd 0' -F -d 'report file'
