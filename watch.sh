#!/bin/bash

# Exit on error
set -e

# Create a virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    uv venv
fi

# Activate the virtual environment and run the rest of the script
source .venv/bin/activate

# Install dependencies using uv
echo "Installing dependencies with uv..."
uv pip install watchdog

# Run the watch script
python3 watch.py