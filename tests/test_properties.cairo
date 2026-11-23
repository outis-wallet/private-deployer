use openzeppelin_interfaces::deployments::{IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait};
use private_deployer::address::{UNIVERSAL_DEPLOYER, deployment_address};
use private_deployer::deployer::PrivateDeployer::errors;
use private_deployer::interfaces::{Deployment, IPrivateDeployerDispatcherTrait, IPrivateDeployerSafeDispatcher, IPrivateDeployerSafeDispatcherTrait};
use snforge_std::{get_class_hash, spy_events, start_cheat_caller_address, stop_cheat_caller_address};
use starknet::ContractAddress;
use crate::mocks::{ITargetDispatcher, ITargetDispatcherTrait};
use crate::test_deployer::{announced, class, setup, target_calldata};

/// Turns one fuzzed byte into a flag and into constructor calldata with 0 to 3 extra felts.
fn shape(shape: u8, a: felt252, b: felt252, c: felt252) -> (bool, Array<felt252>) {
    let all = array![a, b, c];
    (shape % 2 == 1, all.span().slice(0, ((shape / 2) % 4).into()).into())
}

/// The Private Deployer and the UDC both compute the address from the same arguments. This test
/// checks that they agree for any salt, flag and calldata, in a list of one to three deployments.
///
/// Each contract must end up at the address `deployment_address` returned. The test confirms this
/// from the UDC's events, which must come in the order of the list, and from the class that is at
/// each address afterwards. It also checks that a second call with the same list is refused.
///
/// It runs 256 rounds with the suite. For more, run
/// `snforge test test_properties --fuzzer-runs 20000`.
#[test]
#[fuzzer]
#[feature("safe_dispatcher")]
fn deploys_where_it_says(salt: felt252, value: felt252, shape_of: u8, a: felt252, b: felt252, c: felt252) {
    let deployer = setup();
    let target = class("Target");
    let (not_from_zero, extra) = shape(shape_of, a, b, c);
    let calldata = target_calldata(value, extra.span());
    // One to three deployments of the same calldata, at consecutive salts and alternating flags.
    let count: u32 = ((shape_of / 8) % 3 + 1).into();
    let mut list = array![];
    let mut addresses = array![];
    for at in 0..count {
        let salt = salt + at.into();
        let not_from_zero = not_from_zero ^ (at % 2 == 1);
        let expected = deployer.deployment_address(target, salt, not_from_zero, calldata.span());
        assert_eq!(get_class_hash(expected), 0.try_into().unwrap());
        list.append(Deployment { class_hash: target, salt, not_from_zero, calldata: calldata.span(), expected });
        addresses.append(expected.into());
    }

    let mut spy = spy_events();
    let deposits = deployer.privacy_invoke(list.span());

    assert_eq!(deposits.len(), 0);
    assert_eq!(announced(ref spy), addresses);
    for deployment in list.span() {
        let expected = *deployment.expected;
        assert_eq!(get_class_hash(expected), target);
        let deployed = ITargetDispatcher { contract_address: expected };
        assert_eq!(deployed.value(), value);
        assert_eq!(deployed.extra(), core::poseidon::poseidon_hash_span(extra.span()));
        assert_eq!(deployed.constructed_by(), UNIVERSAL_DEPLOYER);
    }

    // A second call with the same list must be refused, and nothing more is deployed. The spy
    // still holds the first call's events, so the count stays where it was.
    let safe = IPrivateDeployerSafeDispatcher { contract_address: deployer.contract_address };
    match safe.privacy_invoke(list.span()) {
        Result::Ok(_) => panic!("not refused"),
        Result::Err(data) => assert_eq!(*data.at(0), errors::ALREADY_DEPLOYED),
    }
    assert_eq!(announced(ref spy).len(), count);
}

/// Checks the address function against the UDC when any caller calls the UDC directly. The address
/// the UDC returns must equal `deployment_address` for that caller. For a from-zero deployment the
/// caller must make no difference.
#[test]
#[fuzzer]
fn the_address_is_the_universal_deployers_for_any_caller(caller: felt252, salt: felt252, value: felt252, shape_of: u8, a: felt252, b: felt252, c: felt252) {
    setup();
    let target = class("Target");
    // Map the fuzzed value to a valid caller address from 1 to 2^251 - 257, the highest address.
    // Zero is left out because a zero caller means the test itself is the caller.
    let caller: u256 = caller.into() % 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeff + 1;
    let caller: felt252 = caller.try_into().unwrap();
    let caller: ContractAddress = caller.try_into().unwrap();
    let (not_from_zero, extra) = shape(shape_of, a, b, c);
    let calldata = target_calldata(value, extra.span());

    start_cheat_caller_address(UNIVERSAL_DEPLOYER, caller);
    let deployed = IUniversalDeployerDispatcher { contract_address: UNIVERSAL_DEPLOYER }.deploy_contract(target, salt, not_from_zero, calldata.span());
    stop_cheat_caller_address(UNIVERSAL_DEPLOYER);

    assert_eq!(deployed, deployment_address(caller, target, salt, not_from_zero, calldata.span()));
    if !not_from_zero {
        assert_eq!(deployed, deployment_address(0.try_into().unwrap(), target, salt, false, calldata.span()));
    }
}

/// Flips one bit of `value`. The bit is always below 250, so a class hash stays a valid class hash
/// and an address stays a valid address.
fn flipped(value: felt252, bit: u8) -> felt252 {
    let mut mask: u256 = 1;
    for _ in 0..(bit % 250) {
        mask *= 2;
    }
    let value: u256 = value.into();
    let changed = if (value / mask) % 2 == 1 {
        value - mask
    } else {
        value + mask
    };
    changed.try_into().unwrap()
}

/// The user approves an address, and that address must pin down every argument. This test computes
/// the address, then changes one argument slightly and makes the call.
///
/// The change is one flipped bit in the class hash, the salt, a calldata felt or the address
/// itself, or the opposite flag, or one extra calldata felt. The changed deployment is at a fuzzed
/// place in a list of three. The call must fail with the unexpected-address error.
///
/// When the changed deployment comes first, nothing may be deployed. When it comes later, the
/// deployments before it ran, and on chain the failure reverts them. The test runner keeps them,
/// so the test only checks that the changed deployment's address is still empty.
#[test]
#[fuzzer]
#[feature("safe_dispatcher")]
fn refuses_an_argument_changed_after_the_address(
    salt: felt252, value: felt252, shape_of: u8, a: felt252, b: felt252, c: felt252, change: u8, bit: u8, place: u8,
) {
    let deployer = setup();
    let target = class("Target");
    let (not_from_zero, extra) = shape(shape_of, a, b, c);
    let calldata = target_calldata(value, extra.span());
    let place: u32 = (place % 3).into();
    // The unchanged deployments use salts of their own, after the changed one's.
    let other = |at: u32| -> Deployment {
        let salt = salt + 1 + at.into();
        Deployment {
            class_hash: target,
            salt,
            not_from_zero,
            calldata: calldata.span(),
            expected: deployer.deployment_address(target, salt, not_from_zero, calldata.span()),
        }
    };
    let expected = deployer.deployment_address(target, salt, not_from_zero, calldata.span());

    let mut class_hash = target;
    let mut changed_salt = salt;
    let mut flag = not_from_zero;
    let mut changed_calldata = calldata.clone();
    let mut address = expected;
    match change % 6 {
        0 => class_hash = flipped(target.into(), bit).try_into().unwrap(),
        1 => changed_salt = flipped(salt, bit),
        2 => flag = !not_from_zero,
        3 => changed_calldata = target_calldata(flipped(value, bit), extra.span()),
        // One extra felt of calldata.
        4 => changed_calldata.append(a),
        _ => address = flipped(expected.into(), bit).try_into().unwrap(),
    }

    let changed = Deployment { class_hash, salt: changed_salt, not_from_zero: flag, calldata: changed_calldata.span(), expected: address };
    let mut list = array![];
    for at in 0..3_u32 {
        list.append(if at == place {
            changed
        } else {
            other(at)
        });
    }

    let mut spy = spy_events();
    let safe = IPrivateDeployerSafeDispatcher { contract_address: deployer.contract_address };
    match safe.privacy_invoke(list.span()) {
        Result::Ok(_) => panic!("not refused"),
        Result::Err(data) => assert_eq!(*data.at(0), errors::UNEXPECTED_ADDRESS),
    }
    if place == 0 {
        assert_eq!(announced(ref spy).len(), 0);
    }
    assert_eq!(get_class_hash(expected), 0.try_into().unwrap());
}
