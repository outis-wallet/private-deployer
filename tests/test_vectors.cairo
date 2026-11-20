use private_deployer::address::deployment_address;
use snforge_std::fs::{FileTrait, read_txt};

/// Reads a file of address vectors and checks each one against `deployment_address`.
///
/// The file has one felt per line. The first felt is the number of vectors. Each vector is the
/// caller, the class hash, the salt, the flag (a felt), the length of the calldata, the calldata,
/// and the expected address. The file must contain at least `least` vectors and nothing after
/// them.
fn agrees_with(path: ByteArray, least: u32) {
    let felts = read_txt(@FileTrait::new(path));
    let mut felts = felts.span();
    let count: u32 = (*felts.pop_front().unwrap()).try_into().unwrap();
    assert!(count >= least, "vectors are missing");
    let mut checked = 0;
    while checked != count {
        let caller = (*felts.pop_front().unwrap()).try_into().unwrap();
        let class_hash = (*felts.pop_front().unwrap()).try_into().unwrap();
        let salt = *felts.pop_front().unwrap();
        // Read the flag the way the contract does: any felt other than 0 is true.
        let not_from_zero = *felts.pop_front().unwrap() != 0;
        let length: u32 = (*felts.pop_front().unwrap()).try_into().unwrap();
        let calldata = felts.slice(0, length);
        felts = felts.slice(length, felts.len() - length);
        let address = *felts.pop_front().unwrap();
        assert_eq!(deployment_address(caller, class_hash, salt, not_from_zero, calldata).into(), address, "vector {}", checked);
        checked += 1;
    }
    assert_eq!(felts.len(), 0);
}

/// Checks `vectors/addresses.txt`, written by `scripts/vectors.mjs`. Some of its addresses were
/// answered by the real UDC on Sepolia and mainnet. The others were computed with starknet.js, for
/// callers that a simulated call can't have.
#[test]
fn agrees_with_the_universal_deployer_and_starknet_js() {
    agrees_with("vectors/addresses.txt", 19);
}

/// Checks `vectors/fuzz.txt`, written by `scripts/fuzz.mjs`. It holds generated arguments, a copy
/// of each with a few bits changed in one argument, and the address starknet.js computes for each.
/// The file in the repository has 256 inputs. The script explains how to run many more.
#[test]
fn agrees_with_starknet_js_on_generated_inputs() {
    agrees_with("vectors/fuzz.txt", 256);
}
