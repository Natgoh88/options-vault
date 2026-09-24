#!/usr/bin/env bash
# Runs the keeper's due actions from your own wallet, for demos without a Chainlink Automation
# upkeep. Requires `keeper.setForwarder(<your address>)` to have been called by the deployer.
#
#   ACCOUNT=deployer ./script/keeper-once.sh            # do everything currently due
#   ACCOUNT=deployer ./script/keeper-once.sh --loop     # poll every 60s until Ctrl-C
#
# Signs with an encrypted Foundry keystore (`cast wallet import`); no private key in the
# environment. Reads the keeper address from deployments/<chainId>.json.
set -euo pipefail

RPC="${RPC:-arbitrum_sepolia}"
ACCOUNT="${ACCOUNT:?set ACCOUNT to your keystore name}"
DEPLOY="${DEPLOY:-deployments/421614.json}"
KEEPER="$(python -c "import json;print(json.load(open('$DEPLOY'))['keeper'])")"

once() {
  for _ in 1 2 3 4 5 6 7 8; do
    out="$(cast call "$KEEPER" "checkUpkeep(bytes)(bool,bytes)" 0x --rpc-url "$RPC")"
    need="$(echo "$out" | sed -n 1p)"
    data="$(echo "$out" | sed -n 2p)"
    if [ "$need" != "true" ]; then
      echo "nothing due"
      return
    fi
    echo "performing upkeep"
    cast send "$KEEPER" "performUpkeep(bytes)" "$data" --rpc-url "$RPC" --account "$ACCOUNT"
  done
}

if [ "${1:-}" = "--loop" ]; then
  while true; do once; sleep 60; done
else
  once
fi
