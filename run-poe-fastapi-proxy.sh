#!/bin/bash

# Start Clash proxy
echo "Starting Clash proxy..."
sudo bash ~/clash-for-linux/start.sh

if [ $? -ne 0 ]; then
    echo "Error: Failed to start Clash!" >&2
    exit 1
fi

# Load Clash environment
echo "Loading Clash environment..."
source /etc/profile.d/clash.sh

if [ $? -ne 0 ]; then
    echo "Error: Failed to load Clash environment!" >&2
    exit 1
fi

# Enable proxy
echo "Enabling proxy..."
proxy_on

if [ $? -ne 0 ]; then
    echo "Error: Failed to enable proxy!" >&2
    exit 1
fi

# Activate Python environment
echo "Activating Python virtual environment..."
source ~/github/venvs/poe-openAi-fastApi-venv/bin/activate

if [ $? -ne 0 ]; then
    echo "Error: Failed to activate Python environment!" >&2
    exit 1
fi

# Run Poe API wrapper
echo "Starting Poe FAST-API wrapper..."
python ~/github/poe-openAi-fastApi/run.py

if [ $? -ne 0 ]; then
    echo "Error: Poe API wrapper failed!" >&2
    exit 1
fi

echo "All steps completed successfully!IP 192.168.120.117"
