#!/bin/bash
set -e
cd "$(dirname "$0")" || exit

if [ -f server.pid ] && kill -0 "$(cat server.pid)" 2>/dev/null; then
    echo "Stopping existing server..."
    kill "$(cat server.pid)" 2>/dev/null || true
    rm -f server.pid
    sleep 1
fi

pkill -f "node server.js" 2>/dev/null || true

rm -rf ./logs ./server.pid ./server.log

echo "Monitor reset complete"