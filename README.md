# Private Deployer Contract

The Private Deployer lets you deploy a contract on Starknet from the privacy pool (STRK20), so that
nothing on chain shows who paid for the deployment.

Starknet already has the
[Universal Deployer Contract](https://docs.openzeppelin.com/contracts-cairo/udc) (UDC), which
deploys any declared class for whoever calls it. The privacy pool can't call the UDC directly. In a
private action the pool can call one contract, and only that contract's `privacy_invoke` function.
The Private Deployer has a `privacy_invoke` function that forwards the call to the UDC.

The deployment is then made by the pool's transaction and paid for from the pool. That is all
"private" means here. The deployment itself is as public as any other.

Anyone can use it, for accounts and for any other contract. It has no owner, no storage and no
settings, and it can't be upgraded.

Don't send tokens to the Private Deployer itself. It has no function that moves tokens, so anything
sent to it is stuck.

## What it hides

It hides who paid for the deployment. It hides nothing else.

- **Public:** the class, the salt, the constructor calldata, the address, the time of the
  deployment, and every withdrawal the same action makes to that address, including the amounts.
- **Hidden:** which of the pool's users sent the action.

A few things can still point to you:

- An unusual amount or an unusual time narrows down who the sender could be.
- If a proving service proves the action for you, that service sees what it proves.

## Using it

> **Use at your own risk.**

A deployment is one private action with two parts, in this order:

1. **Withdrawals** to the new contract's address. Withdraw whatever the contract needs to hold. For
   an account, that is the STRK it will pay fees with. The pool can withdraw to an address that
   has no contract yet. Skip this part if the contract needs no funds.
2. **An invoke** of the Private Deployer, with the calldata described below.

Two rules of the pool matter here:

- **An action can't be an invoke alone.** The pool refuses it with `NO_REPLAY_PROTECTION`. The
  action must also do something the pool records once, such as spending a note. Paying a relayer
  spends a note, so a relayed action already qualifies. Registering a viewing key for the first
  time also qualifies, but it publishes the address of the account that registers.
- **An action can contain only one invoke.** The deployment uses it. If the new contract needs
  another call afterwards, that is a separate action. See "Which classes are safe" for why that
  matters.

### The call

```
privacy_invoke(class_hash, salt, not_from_zero, calldata, expected)
```

| Argument | Meaning |
|---|---|
| `class_hash` | The class to deploy. It must already be declared. |
| `salt` | The salt. |
| `not_from_zero` | `false` to deploy from zero, `true` otherwise. See "How it differs from the UDC". |
| `calldata` | The constructor calldata, as a span: its length, then its felts. |
| `expected` | The address where the contract must end up. |

The first four arguments are the UDC's `deploy_contract` arguments, in the same order. `expected`
is added.

### What the call does

- **It checks `expected` first.** If these arguments would not deploy to `expected`, the call fails
  with `deployer/unexpected-address`. A wallet shows the user an address and withdraws to it, and
  this check makes sure the contract is deployed at that same address. To get the address, call
  `deployment_address(class_hash, salt, not_from_zero, calldata)` on the Private Deployer.
- **It refuses an address that already has a contract.** The call fails with
  `deployer/already-deployed`. The UDC refuses this case too. A contract that is already there was
  constructed in someone else's transaction, before your withdrawals arrived.
- **If the constructor fails, the call fails.**
- **If the call fails, the whole action fails.** The withdrawals are undone and nothing leaves the
  pool.
- **If the call succeeds, the constructor ran inside your action.** The UDC called it, and it ran
  after the action's withdrawals, because the pool makes withdrawals before the invoke.
- **It returns no deposits.** The pool screens nothing and credits nothing.

An account deployed this way starts at nonce 0. An account that deploys itself starts at nonce 1,
because the deploy-account transaction uses nonce 0. A wallet should read the nonce from the chain
and not assume it.

Anyone can also call `privacy_invoke` directly, without the pool. That is an ordinary UDC
deployment with one extra step, and it hides nothing.

### If someone deploys the address first

The arguments of your action become public when it is sent. Whoever proves or relays the action
sees them even earlier. Anyone who knows the arguments can deploy the same address before you:

- For a from-zero address, they can use the UDC or a contract of their own.
- For a `not_from_zero` address, they can call the Private Deployer directly.

Your action is then refused and your funds stay in the pool. It costs the other party one
deployment. What it costs you depends on timing:

- If the address is taken before your transaction's fee is estimated, the estimate fails and
  nothing is sent.
- If their deployment lands between the estimate and the block, your transaction reverts. Whoever
  sent it, usually the relayer, pays its fee.

**Wallets should check that the address is free before proving.** The wallet's simulation and the
proof only assemble the action's steps. They never call the Private Deployer. So a taken address
does not show up in the simulation. It first shows up as `deployer/already-deployed` when the
transaction that carries the proof is estimated.

What to do after a refusal depends on the class:

- If the constructor uses only its calldata, as an account's does, the contract that is now at the
  address is the one you wanted. Send it its funds with a plain withdrawal.
- For any other class, deploy again with a different salt.

## Which classes are safe

Any declared class can be deployed. Whether it is safe to fund a class this way depends on the
class.

- **The constructor must finish the setup.** Some classes need a second call after deployment, such
  as `initialize` or a call that claims ownership. The address is public, and the pool gives your
  second call no priority, so anyone can make that call before you.
- **The constructor sees the relayer's transaction, not yours.** If a constructor reads the
  transaction's account, signature or nonce, it gets the relayer's. A class that takes its owner
  from the transaction makes the relayer the owner. Put the owner in the calldata instead.
- **A class can replace its own class.** The address only tells you which class was deployed, not
  what the contract is now.
- **Constructor calldata is limited to 294 felts.** The UDC emits an event that includes the
  calldata, and an event can hold 300 felts. The same limit applies when you use the UDC directly.
  `deployment_address` still returns an address for longer calldata, but the deployment fails.

## How it matches the UDC

- **Same address.** A from-zero deployment lands at the address the UDC gives anyone for that
  class, salt and calldata. It is also the address an account gets when it deploys itself.
- **Same constructor caller.** The constructor is called by the UDC.
- **Same refusal.** An address that already has a contract is refused.
- **Same event.** The UDC emits its own `ContractDeployed` event, so anything that reads UDC
  deployments also reads these. The event's `deployer` field is the Private Deployer. That means
  the deployment went through the Private Deployer. It does not prove the deployment was paid from
  the pool, because anyone can call the Private Deployer directly. The transaction shows which it
  was.
- **Same reading of the flag.** Any `not_from_zero` value other than 0 counts as true.

## How it differs from the UDC

- **`not_from_zero` does not give you an address of your own.** The UDC mixes its caller into the
  salt, so each caller gets its own addresses. Here the UDC's caller is always the Private
  Deployer, so the address is the same for every sender. An address that only one sender could
  deploy to would identify that sender. The flag still has one effect: a `not_from_zero` address
  can only be reached through the Private Deployer, while a from-zero address can be reached by
  any contract that deploys from zero.
- **The address is not returned.** The pool reads the return value of `privacy_invoke` as a list of
  deposits. So you pass the address in as `expected`, and you can read it from the UDC's event.
- **Deployment and a follow-up call can't share a transaction.** With the UDC, an account can
  deploy a contract and call it in the same transaction. Here the deployment is the action's only
  invoke.
- **It does not declare classes.** Declaring a class is a separate transaction, and it is public.

If another contract runs the Private Deployer's class as its own code with `library_call`, it
deploys as itself. Its `not_from_zero` addresses are its own, not the Private Deployer's.

## The UDC it uses

The Private Deployer calls the UDC at
`0x02ceed65a4bd731034c01113685c831b01c15d7d432f71afb1cf1634b53a2125`. This address is fixed in the
code, and `universal_deployer()` returns it.

On mainnet and Sepolia that address holds class
`0x01b2df6d8861670d4a8ca4670433b2418d78169c2947f46dc614e69f333745c8` (checked 2026-11-20). The class
has two entry points, `deploy_contract` and `deployContract`. It has no constructor and no L1
handler, and OpenZeppelin's source for it never replaces a class. So nothing can change the
contract at that address.

## For relayers

A relayer pays the fee of every action it sends that reverts. An action that uses the Private
Deployer can revert for reasons that are not the sender's fault:

- someone deployed the address first, or
- the constructor failed.

The constructor is code from the class, and it runs on calldata the sender chose. That calldata can
name other contracts for the constructor to call. So trusting the Private Deployer as an invoke
target means trusting every class and every calldata.

If your relayer keeps a list of trusted targets, don't add the Private Deployer's address to it.
Decide by the class being deployed and by what its constructor does with its calldata.

## Tests

The tests need Scarb 2.13.1 and Starknet Foundry 0.52.0, which `.tool-versions` pins. The contract
depends on OpenZeppelin's `openzeppelin_utils` and `openzeppelin_interfaces` 2.1.0.

```bash
scarb build
snforge test                                        # 25 tests
snforge test test_properties --fuzzer-runs 20000    # run the property tests for longer
snforge test --ignored                              # the fork test, which needs a Sepolia node
python3 scripts/check-vectors.py                    # check that the two vector files match
```

`scarb build` prints a warning that the Universal Deployer was not found. This is expected. The UDC
is a dev-dependency that is only built for the tests.

What each test file covers:

- **`tests/test_deployer.cairo`** tests each behaviour described above. It also covers the edge
  cases: salts at both ends of the range, the longest calldata, and an address that was deployed
  first in four different ways (through the UDC, by another contract from zero, by a direct call
  to the Private Deployer, and by the class's own constructor calling back). One test replaces the
  UDC with a contract that deploys to a different address. Other tests send the calldata as raw
  felts, the way the pool does, with extra felts at the end, with `expected` missing, and with a
  flag that is neither 0 nor 1.
- **`tests/test_properties.cairo`** has three property tests that run on random salts, flags and
  calldata, 256 rounds each by default:
  - The address the contract computes is where the UDC actually deploys, and a second call for the
    same address is refused.
  - The address function agrees with the UDC when the UDC is called directly by any caller.
  - If one argument is changed slightly after the address was computed, the call is refused.
- **`tests/test_vectors.cairo`** checks the address function against two files of known answers,
  described under "Vectors" and "Differential fuzz" below.
- **`tests/test_fork.cairo`** deploys through the real UDC on a fork of Sepolia. The other tests
  use OpenZeppelin's UDC source (`openzeppelin_presets` 3.0.0) placed at the UDC's address. That is
  the same code as the real UDC, but not the same compiled class. The fork's node is set in
  `Scarb.toml` under `SEPOLIA`.

One limit of the test runner affects some tests. When a call fails, the runner keeps the state
changes that call made. On chain they are reverted. So when a refusal happens after a deployment
(a constructor that fails, or a UDC that deploys elsewhere), the test checks the refusal and does
not check the address afterwards.

### Vectors

`vectors/addresses.json` is a list of known addresses. A wallet that computes the address itself
can check its code against this list. Each vector has the caller, the class, the salt, the flag,
the calldata and the resulting address. For a `not_from_zero` deployment through the Private
Deployer, the caller is the Private Deployer's address.

There are two kinds of vector:

- **`live`** vectors were answered by the real UDC on Sepolia and on mainnet, and also computed
  with starknet.js. The `asked` field in the file gives the date. If you run the script without
  nodes, it keeps these vectors and checks them against starknet.js only. A live vector is a
  simulated deployment with public arguments. If someone actually deploys one, the chain can no
  longer be asked about it, and the script keeps the answer it already has.
- **`computed`** vectors come from starknet.js 10.8.0 only.

If your wallet stores the flag as a felt, read it the way the contract does: every value except 0
is true. In JavaScript the string `"0x0"` is truthy, but as a flag it means false. The `flagged`
function in `scripts/lib.mjs` shows the correct reading.

`scripts/vectors.mjs` writes `addresses.json` and `addresses.txt`. The Cairo test reads the `.txt`
file. `scripts/check-vectors.py` checks that the two files match, and CI runs it.

```bash
npm i --no-save starknet@10.8.0
SEPOLIA_RPC=<url> MAINNET_RPC=<url> node scripts/vectors.mjs
```

### Differential fuzz

Three implementations compute the address from the same arguments: the Cairo in this repository,
starknet.js, and the UDC on chain. The differential fuzz checks that they always agree.

`scripts/fuzz.mjs` generates random arguments. For each set it also makes a copy with a few bits
changed in one argument. The flag is sometimes a boolean and sometimes a felt.

```bash
node scripts/fuzz.mjs                      # write vectors/fuzz.txt, the 256 inputs the suite checks
LIVE=2000 SEPOLIA_RPC=<url> MAINNET_RPC=<url> node scripts/fuzz.mjs    # compare with the chain
```

The header of the script explains how to run many more inputs against the Cairo in batches.

Results from 2026-11-20, with no disagreement:

- 61,440 generated inputs, starknet.js against the Cairo. In 20,480 of them the flag could also be
  a felt.
- 2,000 inputs, starknet.js against the UDC on both networks. A third of them used a flag that is
  neither 0 nor 1.

## Deploying

```bash
SNCAST=<sncast 0.64 or later> bash deploy.sh <sncast account name> <rpc url>
```

The script declares the class and deploys it through the UDC, from zero with salt 0. The contract
has no constructor arguments, so the same class lands at the same address on every network.

Before it sends anything, the script computes that address and checks that the real UDC is at the
UDC's address on the network. After deploying, it reads back from the node the class at the new
address and the UDC address the contract reports.

If the class is already deployed, the script sends nothing and only does the read-back. That can
happen after an earlier run, or because someone else deployed it. Anyone can deploy a declared
class from zero.

## Deployments

| Network | Address | Class |
|---|---|---|
| Sepolia | `0x05a3ab08e7bae6bf9c0e7cd72ff90e796ae022b505dec4ed1fb5d1b5c802914e` | `0x02b96c23a1fe79e18ce2569f2510d700246d04bf3942c4aa03d1bc61ae4a3dd0` |

It is not deployed on mainnet yet.

### Sepolia, 2026-11-20

Deployed with `deploy.sh` and sncast 0.64.0:

- Declared in `0x020cba9cea16e79e5df8099d136bbc71e5b69dc3477123063fc63022f58c0bcd`.
- Deployed in `0x043747d92790e9b80dde4d7f4f24611057ef2ca5ae4dd6dfaf09b5adce350e6a`.
- The script's read-back passed. A second run found the contract already deployed and sent
  nothing.

The same day, one private action was sent through Sepolia's pool
(`0x0254a6b2997ef52e9f830ce1f543f6b29768295e8d17e2267d672c552cfe0d91`) in transaction
`0x02a4ef030c950da86652c8ea4f952ca5a20a9de283368e223aa88197351ccd45`. A local prover proved it, and
the sending account submitted it itself. So the sender was not hidden. The goal was to test the
pool's call to the Private Deployer.

- The action withdrew 0.01 STRK to
  `0x015314253cb8537d5cfc9e841ef8f85cff899f6f9b2c497aa664be4e76a62789` and invoked the Private
  Deployer. The Private Deployer deployed an Outis account (class `0x00eb49f5…2b42`) at that
  address, from zero with salt 0. That is the address the wallet derives for the account's owner
  key.
- The UDC's event names the Private Deployer as the deployer.
- The new account had nonce 0 and held the 0.01 STRK. Its first transaction, signed with its own
  key, succeeded at nonce 0
  (`0x04e7a5b5bc99067ae64e72b0c76b1db640c42f9908a4b8d937ab3f0f21bfbb0e`).
- The same action, proven a second time, was refused with `deployer/already-deployed` when its fee
  was estimated. Nothing was sent.

## Licence

MIT. See [LICENSE](LICENSE).
