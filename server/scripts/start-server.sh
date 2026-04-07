#!/bin/zsh
set -euo pipefail

cd /Users/davejaga/Desktop/startups/ounje/server
source /Users/davejaga/Desktop/startups/ounje/server/.env

export PATH="/Users/davejaga/.nvm/versions/node/v24.14.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
exec /Users/davejaga/.nvm/versions/node/v24.14.0/bin/node /Users/davejaga/Desktop/startups/ounje/server/server.js
