#!/bin/bash
#
# Script to setup poetry environment
#

export PATH="$HOME/.local/bin:$PATH"
if ! command -v poetry &> /dev/null && [ ! -f "$HOME/.local/bin/poetry" ]; then
  echo "Installing poetry..."
  curl -sSL https://install.python-poetry.org | /usr/bin/python3 -
else
  echo "poetry already installed"
fi

