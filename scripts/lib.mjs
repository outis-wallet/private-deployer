// Code shared by the scripts: loading starknet.js, the UDC's address, and the address computation
// as the UDC does it.
//
// The scripts need starknet.js. Install it here with `npm i --no-save starknet@10.8.0`, or set
// STARKNET_JS to the path of another copy.
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const { hash, ec, num } = process.env.STARKNET_JS ? createRequire(import.meta.url)(process.env.STARKNET_JS) : await import("starknet");

export const UNIVERSAL_DEPLOYER = "0x02ceed65a4bd731034c01113685c831b01c15d7d432f71afb1cf1634b53a2125";
/// Two classes that are declared on both networks. This one is the UDC's own class, which has no
/// constructor.
export const UDC_CLASS = "0x01b2df6d8861670d4a8ca4670433b2418d78169c2947f46dc614e69f333745c8";
/// The Outis account class, version 0.5.0. Its constructor calldata is
/// `[signer variant, owner key, guardian]`, where a guardian of 1 means none.
export const OUTIS_ACCOUNT_CLASS = "0x00eb49f5299d144f0b2e434e483758fb6d7d8241632534d86b098047fe4e2b42";

export const hex = (value) => "0x" + BigInt(value).toString(16).padStart(64, "0");

/// Reads the `not_from_zero` flag the way the contract and the UDC do.
///
/// The flag can be a boolean or a felt. A felt is true unless it is 0. A felt usually arrives as a
/// string, and JavaScript treats the string "0x0" as truthy, so it has to be converted first.
export function flagged(not_from_zero) {
    return typeof not_from_zero === "boolean" ? not_from_zero : BigInt(not_from_zero) !== 0n;
}

/// Returns the address where the UDC deploys, following the UDC's source.
///
/// From zero, the deployer is 0 and the salt is used as given. Otherwise the UDC is the deployer
/// and the salt is `pedersen(caller, salt)`.
export function address({ caller, class_hash, salt, not_from_zero, calldata }) {
    const unique = flagged(not_from_zero);
    const salted = unique ? ec.starkCurve.pedersen(BigInt(caller), BigInt(salt)) : salt;
    return hex(hash.calculateContractAddressFromHash(salted, class_hash, calldata, unique ? UNIVERSAL_DEPLOYER : 0));
}

/// Asks the real UDC, through the node at `rpc`, where it would deploy.
///
/// This uses `starknet_call`, which simulates the call and sends nothing. The caller of a simulated
/// call is always 0. `flag` sets the felt sent as `not_from_zero`. If it is not given, 0 or 1 is
/// sent.
export async function ask(rpc, { class_hash, salt, not_from_zero, calldata, flag }) {
    const body = {
        jsonrpc: "2.0",
        id: 1,
        method: "starknet_call",
        params: [
            {
                contract_address: UNIVERSAL_DEPLOYER,
                entry_point_selector: hash.getSelectorFromName("deploy_contract"),
                calldata: [class_hash, salt, flag ?? (flagged(not_from_zero) ? "0x1" : "0x0"), num.toHex(calldata.length), ...calldata],
            },
            "latest",
        ],
    };
    const answer = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }).then((r) => r.json());
    if (!answer.result) throw new Error(`${rpc}: ${JSON.stringify(answer.error)}`);
    return hex(answer.result[0]);
}

/// Formats vectors for the Cairo test, which reads them with snforge's `read_txt`: one felt per
/// line.
///
/// The first felt is the number of vectors. Each vector is the caller, the class hash, the salt,
/// the flag, the length of the calldata, the calldata, and the address. A boolean flag is written
/// as 0 or 1. A felt flag is written unchanged.
export function lines(vectors) {
    const flag = (value) => (typeof value === "boolean" ? (value ? 1 : 0) : value);
    const felts = [vectors.length, ...vectors.flatMap((v) => [v.caller, v.class_hash, v.salt, flag(v.not_from_zero), v.calldata.length, ...v.calldata, v.address])];
    return felts.map((felt) => num.toHex(felt)).join("\n") + "\n";
}
