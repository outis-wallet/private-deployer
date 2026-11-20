// The differential fuzz of the address computation. Three implementations compute the address from
// the same arguments, and they must always agree: the Cairo in this repository, starknet.js, and
// the real UDC. This script has two modes.
//
// 1. starknet.js against the Cairo (`src/address.cairo`).
//
//    The script writes vectors/fuzz.txt. The file holds generated arguments, a copy of each with a
//    few bits changed in one argument, and the address starknet.js computes for each. The flag is
//    sometimes a boolean and sometimes a felt. As in the contract, any felt other than 0 is true.
//    tests/test_vectors.cairo reads the file and computes every address again.
//
//      node scripts/fuzz.mjs [rounds] [seed]
//
//    The defaults are 128 rounds (256 inputs) and seed 1. That is the file kept in the repository.
//
//    To run many more inputs, generate them in batches and test each batch. The last command
//    restores the file kept in the repository:
//
//      for seed in $(seq 2 41); do node scripts/fuzz.mjs 512 $seed && snforge test generated || break; done
//      node scripts/fuzz.mjs
//
// 2. starknet.js against the real UDC on Sepolia and mainnet.
//
//    With LIVE=<n>, the script asks the UDC on each network n times where it would deploy. The
//    question is a `starknet_call`, which sends nothing. The flag is sent as 0, as 1, and as other
//    felts. Nothing is written to disk.
//
//      LIVE=1000 SEPOLIA_RPC=… MAINNET_RPC=… node scripts/fuzz.mjs
//
// In both modes the script stops at the first disagreement and prints the arguments.
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { OUTIS_ACCOUNT_CLASS, address, ask, flagged, hex, lines, root } from "./lib.mjs";

/// The prime of the field, the upper bound of an address (2^251 - 256), and the upper bound of a
/// class hash (2^251).
const PRIME = 2n ** 251n + 17n * 2n ** 192n + 1n;
const ADDRESS_BOUND = 2n ** 251n - 256n;
const CLASS_BOUND = 2n ** 251n;

const rounds = Number(process.argv[2] ?? 128);
const seed = process.argv[3] ?? "1";
let drawn = 0;
/// Returns 256 pseudo-random bits, derived from the seed and from how many values were drawn
/// before. The same seed always produces the same file.
function draw() {
    return BigInt("0x" + createHash("sha256").update(`${seed}:${drawn++}`).digest("hex"));
}
const below = (bound) => draw() % bound;
/// Returns a value below `bound`. One time in four it is an edge case, such as the lowest or
/// highest value of the range or a 128-bit boundary. Otherwise it is random.
function felt(bound = PRIME) {
    const edges = [0n, 1n, 2n, bound - 1n, bound - 2n, 2n ** 128n - 1n, 2n ** 128n, 2n ** 250n, ADDRESS_BOUND - 1n, CLASS_BOUND - 1n].filter((edge) => edge < bound);
    return below(4n) === 0n ? edges[Number(below(BigInt(edges.length)))] : below(bound);
}
const calldataOf = (length) => Array.from({ length }, () => hex(felt()));

/// Returns a flag. Two times in three it is a boolean. Otherwise it is a felt as a string, the
/// way a wallet might store it: "0x0", "0x1", 2, the largest felt, or a random one. A felt flag is
/// true unless it is 0.
function flag() {
    if (below(3n) !== 0n) return below(2n) === 1n;
    return hex([0n, 1n, 2n, PRIME - 1n, below(PRIME)][Number(below(5n))]);
}

function generated() {
    return {
        caller: hex(felt(ADDRESS_BOUND)),
        class_hash: hex(felt(CLASS_BOUND)),
        salt: hex(felt()),
        not_from_zero: flag(),
        calldata: calldataOf(Number(below(7n))),
    };
}

/// Flips one to three bits of `value` and keeps the result below `bound`.
function flipped(value, bound) {
    let changed = BigInt(value);
    for (let flips = Number(below(3n)) + 1; flips > 0; flips--) changed ^= 1n << below(252n);
    return hex(changed % bound);
}

/// Returns a copy of `vector` with one argument changed slightly. The change is a few flipped bits
/// in a felt, a different flag, or calldata that is one felt longer or shorter.
function changed(vector) {
    const copy = { ...vector, calldata: [...vector.calldata] };
    switch (Number(below(6n))) {
        case 0:
            copy.caller = flipped(copy.caller, ADDRESS_BOUND);
            break;
        case 1:
            copy.class_hash = flipped(copy.class_hash, CLASS_BOUND);
            break;
        case 2:
            copy.salt = flipped(copy.salt, PRIME);
            break;
        case 3:
            // Switch the flag to the opposite meaning, written as a boolean or as a felt.
            copy.not_from_zero = below(2n) === 0n ? !flagged(copy.not_from_zero) : hex(flagged(copy.not_from_zero) ? 0n : 1n + below(PRIME - 1n));
            break;
        case 4:
            if (copy.calldata.length > 0) {
                const at = Number(below(BigInt(copy.calldata.length)));
                copy.calldata[at] = flipped(copy.calldata[at], PRIME);
                break;
            }
        // Empty calldata has no felt to change, so fall through and add one.
        default:
            if (copy.calldata.length > 0 && below(2n) === 0n) copy.calldata.pop();
            else copy.calldata.push(hex(felt()));
    }
    return copy;
}

if (process.env.LIVE) {
    const rpcs = [process.env.SEPOLIA_RPC, process.env.MAINNET_RPC];
    if (!rpcs.every(Boolean)) throw new Error("LIVE needs both SEPOLIA_RPC and MAINNET_RPC to be set");
    const asks = Number(process.env.LIVE);
    let flags = { zero: 0, one: 0, other: 0 };
    for (let at = 0; at < asks; at += 16) {
        await Promise.all(
            Array.from({ length: Math.min(16, asks - at) }, async () => {
                // An Outis account's constructor accepts any owner key except zero. The address is
                // free unless someone has deployed that exact account.
                const kind = Number(below(3n));
                const flag = [0n, 1n, 2n + below(PRIME - 2n)][kind];
                flags[["zero", "one", "other"][kind]]++;
                const vector = { caller: hex(0), class_hash: OUTIS_ACCOUNT_CLASS, salt: hex(felt()), not_from_zero: flag !== 0n, calldata: [hex(0), hex(1n + below(PRIME - 1n)), hex(1)] };
                const expected = address(vector);
                for (const rpc of rpcs) {
                    const answered = await ask(rpc, { ...vector, flag: hex(flag) });
                    if (answered !== expected) throw new Error(`The UDC at ${rpc} answered ${answered}, but starknet.js computed ${expected}: flag ${hex(flag)}, ${JSON.stringify(vector)}`);
                }
            }),
        );
    }
    console.log(`starknet.js and the UDC on both networks agree on ${asks} inputs (flag 0: ${flags.zero}, flag 1: ${flags.one}, another felt: ${flags.other}). Seed: ${seed}.`);
} else {
    const vectors = [];
    for (let round = 0; round < rounds; round++) {
        const vector = generated();
        for (const each of [vector, changed(vector)]) vectors.push({ ...each, address: address(each) });
    }
    writeFileSync(resolve(root, "vectors/fuzz.txt"), lines(vectors));
    console.log(`Wrote ${vectors.length} inputs to vectors/fuzz.txt (${rounds} rounds, seed ${seed}).`);
}
