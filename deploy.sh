#!/usr/bin/env bash
# Declares the Private Deployer and deploys it from an sncast account, then verifies the
# deployment by reading it back from the node.
#
# Usage: bash deploy.sh <sncast account name> <rpc url>
#
# The contract is deployed through the UDC, from zero with salt 0. It has no constructor
# arguments, so the same class lands at the same address on every network. The script prints the
# class hash, the address and the transaction hashes, to copy into README.md.
#
# The script is safe to run again. If the class is already declared, it is not declared again. If
# the contract is already deployed, it is not deployed again, and only the read-back runs. The
# contract can already be deployed because of an earlier run or because someone else deployed it:
# anyone can deploy a declared class from zero.
#
# The contract has no owner and no settings. The account only pays for the two transactions.
#
# Settings:
# - SNCAST: the sncast binary to use. Sepolia and mainnet need sncast 0.64 or later, because they
#   check a class's compiled hash in a way that older versions don't compute. The 0.52 that
#   .tool-versions pins for the tests is too old. Example:
#   SNCAST=~/.asdf/installs/starknet-foundry/0.64.0/bin/sncast. sncast builds the class itself.
# - ACCOUNTS_FILE: an sncast accounts file other than the default, for example a devnet's.
# - UNIVERSAL_DEPLOYER_CLASS: the class hash to expect at the UDC's address, for a devnet that has
#   its own UDC class.
set -euo pipefail

usage="usage: deploy.sh <sncast account name> <rpc url>"
account=${1:?$usage}
url=${2:?$usage}
cd "$(dirname "$0")"

universal_deployer=0x02ceed65a4bd731034c01113685c831b01c15d7d432f71afb1cf1634b53a2125
# The UDC's class hash on mainnet and Sepolia. UNIVERSAL_DEPLOYER_CLASS overrides it.
universal_deployer_class=${UNIVERSAL_DEPLOYER_CLASS:-0x01b2df6d8861670d4a8ca4670433b2418d78169c2947f46dc614e69f333745c8}
# The selector of `universal_deployer`: starknet_keccak("universal_deployer").
names_selector=0x273cd4c1d4be412a626d90573122ffb7f3239da39e2840b207ab4e95a36c663
sncast=${SNCAST:-sncast}
accounts=(${ACCOUNTS_FILE:+--accounts-file "$ACCOUNTS_FILE"})
run() { "$sncast" --account "$account" "${accounts[@]}" --wait --json "$@" --url "$url"; }
# Prints one field from sncast's JSON output. If several lines have the field, the last one is
# used. Fails if no line has it.
field() {
  python3 -c '
import json, sys
found = [json.loads(line)[sys.argv[1]] for line in sys.stdin if line.strip().startswith("{") and sys.argv[1] in json.loads(line)]
if not found: sys.exit("sncast\x27s output has no field named " + sys.argv[1])
print(found[-1])' "$1"
}
# Succeeds if two hex felts are equal. Leading zeros don't matter.
same() { python3 -c 'import sys; sys.exit(0 if int(sys.argv[1], 16) == int(sys.argv[2], 16) else 1)' "$1" "$2"; }
# Makes one JSON-RPC call to the node and prints the result, one felt per line. Fails unless the
# result has exactly `$3` felts.
ask() {
  curl -sS "$url" -H 'content-type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" | python3 -c '
import json, sys
answer = json.load(sys.stdin)
if "result" not in answer: sys.exit("the node returned an error: " + json.dumps(answer.get("error")))
result = answer["result"] if isinstance(answer["result"], list) else [answer["result"]]
if len(result) != int(sys.argv[1]): sys.exit("the node returned an unexpected result: " + json.dumps(answer["result"]))
print("\n".join(result))' "$3"
}

# Before sending anything, check that the real UDC is at the UDC's address on this network. The
# contract has that address fixed in its code and calls whatever is there.
there=$(ask starknet_getClassHashAt "[\"latest\",\"$universal_deployer\"]" 1)
same "$there" "$universal_deployer_class" || { echo "The class at the UDC's address is $there, but $universal_deployer_class was expected" >&2; exit 1; }

# Compute the class hash as sncast builds it here, and the address where the UDC deploys that
# class from zero with salt 0.
class=$("$sncast" --json utils class-hash --contract-name PrivateDeployer | field class_hash)
address=$("$sncast" --json utils contract-address --class-hash "$class" --salt 0x0 | field contract_address)
echo "PrivateDeployer class: $class"
echo "PrivateDeployer address: $address"

if same "$(ask starknet_getClassHashAt "[\"latest\",\"$address\"]" 1 2>/dev/null || echo 0x0)" 0x0; then
  if out=$(run declare --contract-name PrivateDeployer 2>&1); then
    same "$(printf '%s\n' "$out" | field class_hash)" "$class" || { echo "sncast declared a different class than the one built here: $out" >&2; exit 1; }
    echo "Declared in transaction $(printf '%s\n' "$out" | field transaction_hash)"
  elif grep -qi "already declared" <<<"$out"; then
    echo "The class is already declared."
  else
    printf '%s\n' "$out" >&2
    exit 1
  fi
  # Without --unique the deployment is from zero, so the address depends only on the class and
  # the salt.
  out=$(run deploy --class-hash "$class" --salt 0x0 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
  same "$(printf '%s\n' "$out" | field contract_address)" "$address" || { echo "The contract was deployed at a different address than $address: $out" >&2; exit 1; }
  echo "Deployed in transaction $(printf '%s\n' "$out" | field transaction_hash)"
else
  echo "The contract is already deployed."
fi

# Read the deployment back from the node. The class at the address must be the class built here,
# and the UDC address the contract reports must be the real one. Each value is compared as a
# whole felt.
there=$(ask starknet_getClassHashAt "[\"latest\",\"$address\"]" 1)
same "$there" "$class" || { echo "The class at $address is $there, but $class was expected" >&2; exit 1; }
named=$(ask starknet_call "[{\"contract_address\":\"$address\",\"entry_point_selector\":\"$names_selector\",\"calldata\":[]},\"latest\"]" 1)
same "$named" "$universal_deployer" || { echo "The contract reports $named as the UDC, but $universal_deployer was expected" >&2; exit 1; }
echo "Verified at $address: class $class, deploying through the UDC at $universal_deployer."
