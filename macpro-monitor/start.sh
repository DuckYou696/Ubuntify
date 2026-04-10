#!/bin/bash
cd "$(dirname "$0")"

# 1. Check if the process is running OR if old files exist
# We run pkill -0 and the file checks directly in the 'if'
if pkill -0 -f "node server.js" 2>/dev/null || [ -f server.pid ] || [ -d logs ]; then
    echo "THERE CAN BE ONLY ONE >:("
    echo "BEGONE FILTH"
    # No need for sudo here if reset.sh handles it internally
    ./reset.sh
fi

# 2. Start fresh
# Use 'disown' so the process doesn't die when you close the terminal
nohup node server.js > server.log 2>&1 &
echo $! > server.pid
disown 

sleep 2
echo "Server started (PID: $(cat server.pid))"
echo "http://${HOSTNAME}:8080"
open "http://localhost:8080"