set auto-load safe-path /
set $_exitcode = -999
handle SIGPIPE nostop
define hook-stop
    if $_exitcode != -999
        quit
    end
end

