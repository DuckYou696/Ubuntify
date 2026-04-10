#!/bin/bash
cd "$(dirname "$0")"
if [ -f server.pid ] && kill -0 $(cat server.pid) 2>/dev/null; then
    echo "Stopping existing server..."
    kill $(cat server.pid) 2>/dev/null
    rm -f server.pid
    sleep 1
fi[ -f server.pid ] && kill $(cat server.pid) 2>/dev/null && echo "Server stopped" && rm -f server.pid || echo "Server not running"
