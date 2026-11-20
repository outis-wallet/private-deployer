// Writes vectors/addresses.json and vectors/addresses.txt. Both list known addresses where the UDC
// deploys a contract. The Cairo test (tests/test_vectors.cairo) reads the .txt file. The .json file
// is for wallets that compute the address themselves.
//
// There are two kinds of vector. Every address is computed here with starknet.js.
// - "live": the real UDC on Sepolia and on mainnet is also asked where it would deploy. Both must
//   give the address starknet.js computed. The question is a `starknet_call`, which sends nothing.
//   A simulated call always has caller 0, so live vectors have caller 0.
// - "computed": starknet.js only. These cover callers that a simulated call can't have.
//
// To run it (starknet.js 10.8.0 is the version the vectors were made with):
//
//   npm i --no-save starknet@10.8.0
//   SEPOLIA_RPC=… MAINNET_RPC=… node scripts/vectors.mjs
//
// Set STARKNET_JS to load another copy of starknet.js (see scripts/lib.mjs).
//
// Without the two node URLs, the script keeps the live vectors that are already in
// vectors/addresses.json, with the date they were asked, and checks them against starknet.js
// again. scripts/check-vectors.py checks that the two files match.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { OUTIS_ACCOUNT_CLASS, UDC_CLASS, UNIVERSAL_DEPLOYER, address, ask, hex, lines, root } from "./lib.mjs";

const OWNER = "0x02dc1ed6c4b1ed7c02d2b4e0e1f5c6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d";
/// The largest felt: 2^251 + 17 * 2^192.
const MAX_FELT = "0x0800000000000011000000000000000000000000000000000000000000000000";

const account = [hex(0), OWNER, hex(1)];
const live = [
    { class_hash: UDC_CLASS, salt: hex(0x1234), not_from_zero: false, calldata: [] },
    { class_hash: UDC_CLASS, salt: hex(0x1234), not_from_zero: true, calldata: [] },
    { class_hash: UDC_CLASS, salt: MAX_FELT, not_from_zero: true, calldata: [] },
    // An Outis account from zero at salt 0. This is the address the account gets when it deploys
    // itself.
    { class_hash: OUTIS_ACCOUNT_CLASS, salt: hex(0), not_from_zero: false, calldata: account },
    { class_hash: OUTIS_ACCOUNT_CLASS, salt: hex(0x6f757469732f6167656e74n), not_from_zero: false, calldata: account },
    { class_hash: OUTIS_ACCOUNT_CLASS, salt: hex(7), not_from_zero: true, calldata: account },
].map((vector) => ({ caller: hex(0), ...vector }));

/// Callers that a simulated call can't have. When a wallet checks its own code, the Private
/// Deployer's address is a caller like these.
const callers = [hex(1), "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7", "0x07fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeff"];
const computed = [
    // The UDC's own address: its class deployed from zero at salt 0. It can't be a live vector,
    // because the UDC is already deployed there and the chain refuses a second deployment.
    { caller: hex(0), class_hash: UDC_CLASS, salt: hex(0), not_from_zero: false, calldata: [] },
    // Four vectors for each caller. The first one uses the caller's position in the list as its
    // salt.
    ...callers.flatMap((caller, at) => [
        { caller, class_hash: UDC_CLASS, salt: hex(at), not_from_zero: true, calldata: [] },
        { caller, class_hash: OUTIS_ACCOUNT_CLASS, salt: hex(0x1234), not_from_zero: true, calldata: account },
        // From zero, the caller makes no difference. The address is the same as for caller 0.
        { caller, class_hash: OUTIS_ACCOUNT_CLASS, salt: hex(0), not_from_zero: false, calldata: account },
        { caller, class_hash: hex(0x1f), salt: MAX_FELT, not_from_zero: true, calldata: [MAX_FELT, hex(0), hex(2), hex(3), MAX_FELT] },
    ]),
];

const file = resolve(root, "vectors/addresses.json");
const rpcs = [process.env.SEPOLIA_RPC, process.env.MAINNET_RPC];
const kept = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { vectors: [] };
const keptLive = kept.vectors.filter((vector) => vector.source === "live");
for (const vector of keptLive) if (address(vector) !== vector.address) throw new Error(`starknet.js computes a different address for a live vector in the file: ${JSON.stringify(vector)}`);
/// Returns the live vector already in the file that has the same arguments, if there is one.
const keptFor = (vector) => keptLive.find((other) => ["caller", "class_hash", "salt", "not_from_zero"].every((key) => other[key] === vector[key]) && other.calldata.join() === vector.calldata.join());

let asked;
/// The date when both networks last answered all the live vectors.
let askedOn = kept.asked;
if (rpcs.every(Boolean)) {
    asked = [];
    let all = true;
    for (const vector of live) {
        const expected = address(vector);
        try {
            for (const rpc of rpcs) {
                const answered = await ask(rpc, vector);
                if (answered !== expected) throw new Error(`The UDC at ${rpc} answered ${answered}, but starknet.js computed ${expected}: ${JSON.stringify(vector)}`);
            }
        } catch (error) {
            // These arguments are public in this repository, so anyone can deploy one of them.
            // After that the chain refuses the simulated deployment. Keep the answer from before.
            if (!/already deployed/i.test(error.message) || !keptFor(vector)) throw error;
            console.warn(`This vector has been deployed since it was last asked, so the earlier answer is kept: ${expected}`);
            all = false;
        }
        asked.push({ source: "live", ...vector, address: expected });
    }
    if (all) askedOn = new Date().toISOString().slice(0, 10);
} else {
    console.warn("SEPOLIA_RPC and MAINNET_RPC are not both set. Keeping the live vectors already in the file.");
    asked = keptLive;
}
const vectors = [...asked, ...computed.map((vector) => ({ source: "computed", ...vector, address: address(vector) }))];

mkdirSync(resolve(root, "vectors"), { recursive: true });
const about =
    "Known addresses where the Universal Deployer Contract (at `universal_deployer`) deploys a contract when `caller` calls it. " +
    "`live` vectors were answered by the real UDC on Sepolia and mainnet on the date in `asked`, and also computed with starknet.js. " +
    "`computed` vectors come from starknet.js only. This file is written by scripts/vectors.mjs.";
writeFileSync(file, JSON.stringify({ about, universal_deployer: UNIVERSAL_DEPLOYER, asked: askedOn, vectors }, null, 2) + "\n");
writeFileSync(resolve(root, "vectors/addresses.txt"), lines(vectors));
console.log(`Wrote ${asked.length} live and ${computed.length} computed vectors.`);
