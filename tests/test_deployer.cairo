use openzeppelin_interfaces::deployments::{IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait};
use private_deployer::address::{UNIVERSAL_DEPLOYER, deployment_address};
use private_deployer::deployer::PrivateDeployer::errors;
use private_deployer::interfaces::{
    IPrivateDeployerDispatcher, IPrivateDeployerDispatcherTrait, IPrivateDeployerSafeDispatcher, IPrivateDeployerSafeDispatcherTrait,
};
use snforge_std::{ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyTrait, EventsFilterTrait, declare, get_class_hash, spy_events};
use starknet::ClassHash;
use crate::mocks::{
    IBorrowerDispatcher, IBorrowerDispatcherTrait, IFactoryDispatcher, IFactoryDispatcherTrait, IPoolDispatcher, IPoolDispatcherTrait, IReentersDispatcher,
    IReentersDispatcherTrait, ITargetDispatcher, ITargetDispatcherTrait,
};

pub fn class(name: ByteArray) -> ClassHash {
    *declare(name).unwrap().contract_class().class_hash
}

/// Deploys OpenZeppelin's UDC at the UDC's real address, then deploys the Private Deployer.
pub fn setup() -> IPrivateDeployerDispatcher {
    declare("UniversalDeployer").unwrap().contract_class().deploy_at(@array![], UNIVERSAL_DEPLOYER).unwrap();
    new_deployer()
}

pub fn new_deployer() -> IPrivateDeployerDispatcher {
    let (contract_address, _) = declare("PrivateDeployer").unwrap().contract_class().deploy(@array![]).unwrap();
    IPrivateDeployerDispatcher { contract_address }
}

fn safe(deployer: IPrivateDeployerDispatcher) -> IPrivateDeployerSafeDispatcher {
    IPrivateDeployerSafeDispatcher { contract_address: deployer.contract_address }
}

/// Builds the constructor calldata of the Target mock: `value`, then `extra` as a span.
pub fn target_calldata(value: felt252, extra: Span<felt252>) -> Array<felt252> {
    let mut calldata = array![value, extra.len().into()];
    calldata.append_span(extra);
    calldata
}

/// Returns the addresses the UDC reported in its `ContractDeployed` events. The address is the
/// first felt of the event's data.
pub fn announced(ref spy: EventSpy) -> Array<felt252> {
    let events = spy.get_events().emitted_by(UNIVERSAL_DEPLOYER);
    let mut addresses = array![];
    for (_, event) in events.events.span() {
        assert_eq!(*event.keys.at(0), selector!("ContractDeployed"));
        addresses.append(*event.data.at(0));
    }
    addresses
}

fn assert_refused<T, +Drop<T>>(result: Result<T, Array<felt252>>, reason: felt252) {
    match result {
        Result::Ok(_) => panic!("not refused"),
        Result::Err(data) => {
            let mut found = false;
            for felt in data.span() {
                found = found || *felt == reason;
            }
            assert!(found, "refused for another reason: {:?}", data);
        },
    }
}

#[test]
fn deploys_from_zero_where_an_account_deploys_itself() {
    let deployer = setup();
    let target = class("Target");
    let calldata = target_calldata(7, array![1, 2, 3].span());
    // A from-zero address does not depend on the deployer. It is the address a deploy-account
    // transaction gives for this class, salt and calldata.
    let expected = deployment_address(0.try_into().unwrap(), target, 0x1234, false, calldata.span());
    assert_eq!(deployer.deployment_address(target, 0x1234, false, calldata.span()), expected);

    let mut spy = spy_events();
    let deposits = deployer.privacy_invoke(target, 0x1234, false, calldata.span(), expected);

    assert_eq!(deposits.len(), 0);
    assert_eq!(get_class_hash(expected), target);
    let deployed = ITargetDispatcher { contract_address: expected };
    assert_eq!(deployed.value(), 7);
    assert_eq!(deployed.extra(), core::poseidon::poseidon_hash_span(array![1, 2, 3].span()));
    // As in any UDC deployment, the UDC is the constructor's caller.
    assert_eq!(deployed.constructed_by(), UNIVERSAL_DEPLOYER);
    assert_eq!(announced(ref spy), array![expected.into()]);
}

#[test]
fn deploys_not_from_zero_as_the_universal_deployers_caller() {
    let deployer = setup();
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    let expected = deployer.deployment_address(target, 0x1234, true, calldata.span());
    assert_eq!(expected, deployment_address(deployer.contract_address, target, 0x1234, true, calldata.span()));
    assert_ne!(expected, deployer.deployment_address(target, 0x1234, false, calldata.span()));

    let mut spy = spy_events();
    deployer.privacy_invoke(target, 0x1234, true, calldata.span(), expected);

    assert_eq!(get_class_hash(expected), target);
    assert_eq!(ITargetDispatcher { contract_address: expected }.constructed_by(), UNIVERSAL_DEPLOYER);
    // Check every field of the UDC's event: the address, the deployer (the Private Deployer),
    // not_from_zero, the class, the calldata, and the salt as it was passed in.
    let events = spy.get_events().emitted_by(UNIVERSAL_DEPLOYER);
    assert_eq!(events.events.len(), 1);
    let (_, event) = events.events.at(0);
    assert_eq!(event.keys.span(), array![selector!("ContractDeployed")].span());
    assert_eq!(event.data.span(), array![expected.into(), deployer.contract_address.into(), 1, target.into(), 2, 7, 0, 0x1234].span());
}

/// The largest felt: 2^251 + 17 * 2^192.
const MAX_FELT: felt252 = 0x0800000000000011000000000000000000000000000000000000000000000000;

#[test]
fn deploys_at_the_ends() {
    let deployer = setup();
    let target = class("Target");
    // Two edge cases: a class with no constructor, and the longest calldata that fits. The UDC's
    // event has six fields of its own plus the calldata, and an event can hold 300 felts. So the
    // limit is 294 felts of calldata. Anything longer makes the event fail, and the deployment
    // fails with it.
    let no_constructor = class("Pool");
    let mut extra = array![];
    for felt in 0..292_u32 {
        extra.append(felt.into());
    }
    let longest = target_calldata(MAX_FELT, extra.span());
    assert_eq!(longest.len(), 294);
    for salt in array![0, 1, MAX_FELT] {
        for not_from_zero in array![false, true] {
            let mut spy = spy_events();
            let bare = deployer.deployment_address(no_constructor, salt, not_from_zero, array![].span());
            deployer.privacy_invoke(no_constructor, salt, not_from_zero, array![].span(), bare);
            assert_eq!(get_class_hash(bare), no_constructor);

            let long = deployer.deployment_address(target, salt, not_from_zero, longest.span());
            deployer.privacy_invoke(target, salt, not_from_zero, longest.span(), long);
            assert_eq!(get_class_hash(long), target);
            assert_eq!(ITargetDispatcher { contract_address: long }.value(), MAX_FELT);
            assert_eq!(announced(ref spy), array![bare.into(), long.into()]);
        }
    }
}

#[test]
fn a_library_call_deploys_as_the_borrower() {
    // When another contract runs this class with `library_call`, that contract is the UDC's
    // caller. The view and the deployment agree with each other, and the address belongs to that
    // contract, not to the Private Deployer.
    let deployer = setup();
    let deployer_class = get_class_hash(deployer.contract_address);
    let (borrower, _) = declare("Borrower").unwrap().contract_class().deploy(@array![]).unwrap();
    let borrower = IBorrowerDispatcher { contract_address: borrower };
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    for not_from_zero in array![false, true] {
        let expected = borrower.address(deployer_class, target, 9, not_from_zero, calldata.span());
        assert_eq!(expected, deployment_address(borrower.contract_address, target, 9, not_from_zero, calldata.span()));
        let mut spy = spy_events();
        borrower.deploy(deployer_class, target, 9, not_from_zero, calldata.span(), expected);
        assert_eq!(get_class_hash(expected), target);
        let events = spy.get_events().emitted_by(UNIVERSAL_DEPLOYER);
        let (_, event) = events.events.at(0);
        assert_eq!(*event.data.at(1), borrower.contract_address.into());
        if not_from_zero {
            assert_ne!(expected, deployer.deployment_address(target, 9, true, calldata.span()));
        }
    }
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_an_address_that_isnt_where_it_deploys() {
    let deployer = setup();
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    let from_zero = deployer.deployment_address(target, 1, false, calldata.span());
    let not_from_zero = deployer.deployment_address(target, 1, true, calldata.span());
    let mut spy = spy_events();

    // Wrong values for `expected`: the address for the other flag (both ways), for another salt,
    // for other calldata, for another caller, and zero.
    assert_refused(safe(deployer).privacy_invoke(target, 1, false, calldata.span(), not_from_zero), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(target, 1, true, calldata.span(), from_zero), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(target, 2, false, calldata.span(), from_zero), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(target, 1, false, target_calldata(8, array![].span()).span(), from_zero), errors::UNEXPECTED_ADDRESS);
    let anothers = deployment_address(UNIVERSAL_DEPLOYER, target, 1, true, calldata.span());
    assert_refused(safe(deployer).privacy_invoke(target, 1, true, calldata.span(), anothers), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(target, 1, false, calldata.span(), 0.try_into().unwrap()), errors::UNEXPECTED_ADDRESS);

    assert_eq!(announced(ref spy).len(), 0);
    assert_eq!(get_class_hash(from_zero), 0.try_into().unwrap());
    assert_eq!(get_class_hash(not_from_zero), 0.try_into().unwrap());
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_an_address_deployed_with_other_arguments() {
    let deployer = setup();
    let target = class("Target");
    // The address has a contract, but these arguments don't deploy to it. `expected` is checked
    // before the check for an existing contract, so the error is about the address.
    let calldata = target_calldata(7, array![].span());
    let there = deployer.deployment_address(target, 1, false, calldata.span());
    deployer.privacy_invoke(target, 1, false, calldata.span(), there);
    assert_refused(safe(deployer).privacy_invoke(target, 1, false, target_calldata(8, array![].span()).span(), there), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(target, 1, true, calldata.span(), there), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(class("Refuses"), 1, false, array![].span(), there), errors::UNEXPECTED_ADDRESS);
}

// The tests below check that an address which already has a contract is refused, no matter who
// deployed it or how. That contract was constructed in someone else's transaction, not in this
// action. The refusal happens before the call writes anything, so the test runner's habit of
// keeping a failed call's writes does not affect these tests.

#[test]
#[feature("safe_dispatcher")]
fn refuses_an_address_deployed_first_through_the_universal_deployer() {
    let deployer = setup();
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    let expected = deployer.deployment_address(target, 1, false, calldata.span());
    // Anyone who knows the arguments can deploy from zero first, through the UDC.
    let first = IUniversalDeployerDispatcher { contract_address: UNIVERSAL_DEPLOYER }.deploy_contract(target, 1, false, calldata.span());
    assert_eq!(first, expected);

    let mut spy = spy_events();
    assert_refused(safe(deployer).privacy_invoke(target, 1, false, calldata.span(), expected), errors::ALREADY_DEPLOYED);
    assert_eq!(announced(ref spy).len(), 0);
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_an_address_another_contract_deployed_from_zero() {
    let deployer = setup();
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    let expected = deployer.deployment_address(target, 1, false, calldata.span());
    // A from-zero address does not depend on the deployer, so any contract can deploy to it. That
    // contract is then the constructor's caller, where the UDC would have been.
    let (factory, _) = declare("Factory").unwrap().contract_class().deploy(@array![]).unwrap();
    let first = IFactoryDispatcher { contract_address: factory }.deploy(target, 1, calldata.span());
    assert_eq!(first, expected);
    assert_eq!(ITargetDispatcher { contract_address: expected }.constructed_by(), factory);

    assert_refused(safe(deployer).privacy_invoke(target, 1, false, calldata.span(), expected), errors::ALREADY_DEPLOYED);
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_a_second_call() {
    let deployer = setup();
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    let mut spy = spy_events();
    // A not-from-zero address can only be reached through the Private Deployer, but anyone can
    // call the Private Deployer first.
    for not_from_zero in array![false, true] {
        let expected = deployer.deployment_address(target, 1, not_from_zero, calldata.span());
        deployer.privacy_invoke(target, 1, not_from_zero, calldata.span(), expected);
        assert_refused(safe(deployer).privacy_invoke(target, 1, not_from_zero, calldata.span(), expected), errors::ALREADY_DEPLOYED);
    }
    assert_eq!(announced(ref spy).len(), 2);
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_a_universal_deployer_that_deploys_elsewhere() {
    // The Private Deployer checks the address the UDC returns against its own computation. Here
    // a fake UDC makes the two disagree.
    declare("Elsewhere").unwrap().contract_class().deploy_at(@array![], UNIVERSAL_DEPLOYER).unwrap();
    let deployer = new_deployer();
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    for not_from_zero in array![false, true] {
        let expected = deployer.deployment_address(target, 1, not_from_zero, calldata.span());
        assert_refused(safe(deployer).privacy_invoke(target, 1, not_from_zero, calldata.span(), expected), errors::UNEXPECTED_ADDRESS);
    }
}

#[test]
fn refuses_a_constructor_asking_for_its_own_deployment_again() {
    let deployer = setup();
    let reenters = class("Reenters");
    let mut spy = spy_events();
    for flag in array![0, 1] {
        let calldata = array![deployer.contract_address.into(), 1, flag];
        let expected = deployer.deployment_address(reenters, 1, flag == 1, calldata.span());
        deployer.privacy_invoke(reenters, 1, flag == 1, calldata.span(), expected);
        // The contract's class is already at the address when its constructor runs, so the call
        // back is refused.
        assert!(IReentersDispatcher { contract_address: expected }.refused());
    }
    assert_eq!(announced(ref spy).len(), 2);
}

// In the tests below the call fails after a deployment has started. On chain the transaction
// reverts and the deployment is undone. The test runner keeps a failed call's writes, so these
// tests check the failure and do not look at the address afterwards.

#[test]
#[feature("safe_dispatcher")]
fn a_constructor_that_refuses_fails_the_call() {
    let deployer = setup();
    let refuses = class("Refuses");
    let expected = deployer.deployment_address(refuses, 1, false, array![].span());
    assert_refused(safe(deployer).privacy_invoke(refuses, 1, false, array![].span(), expected), 'target/refuses');
}

#[test]
#[feature("safe_dispatcher")]
fn calldata_the_constructor_cant_read_fails_the_call() {
    let deployer = setup();
    let target = class("Target");
    // The span claims a length of three felts, but only one follows.
    let calldata = array![7, 3, 1];
    let expected = deployer.deployment_address(target, 1, false, calldata.span());
    // The failure must come from the constructor, not from the Private Deployer. The address
    // was correct.
    match safe(deployer).privacy_invoke(target, 1, false, calldata.span(), expected) {
        Result::Ok(_) => panic!("not refused"),
        Result::Err(data) => assert!(*data.at(0) != errors::UNEXPECTED_ADDRESS, "refused for the address"),
    }
}

/// Calls `privacy_invoke` the way the pool does, with raw felts, to deploy a Target at salt 1.
///
/// The calldata is the class, the salt, `flag`, the constructor calldata as a span, then the
/// expected address (if `expected` is given, for the flag it names), then the felts in `after`.
/// Returns what the call returned, or `None` if the call failed.
fn pool_invokes(flag: felt252, expected: Option<bool>, after: Span<felt252>) -> Option<Span<felt252>> {
    let deployer = setup();
    let (pool, _) = declare("Pool").unwrap().contract_class().deploy(@array![]).unwrap();
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    let mut raw: Array<felt252> = array![target.into(), 1, flag];
    calldata.serialize(ref raw);
    if let Option::Some(not_from_zero) = expected {
        raw.append(deployer.deployment_address(target, 1, not_from_zero, calldata.span()).into());
    }
    raw.append_span(after);
    IPoolDispatcher { contract_address: pool }.invoke(deployer.contract_address, raw.span())
}

// For both flags, the return value is an empty span of deposits with nothing after it.

#[test]
fn the_pool_reads_no_deposits_from_zero() {
    assert_eq!(pool_invokes(0, Option::Some(false), array![].span()), Option::Some(array![0].span()));
}

#[test]
fn the_pool_reads_no_deposits_not_from_zero() {
    assert_eq!(pool_invokes(1, Option::Some(true), array![].span()), Option::Some(array![0].span()));
}

#[test]
fn refuses_felts_after_the_arguments() {
    assert_eq!(pool_invokes(0, Option::Some(false), array![0].span()), Option::None);
}

#[test]
fn refuses_calldata_without_the_expected_address() {
    assert_eq!(pool_invokes(0, Option::None, array![].span()), Option::None);
}

// The UDC treats any flag other than 0 as not-from-zero. This was checked against the real UDC
// on both networks on 2026-11-20. The Private Deployer reads the flag the same way, and
// `expected` still pins the deployment to one address.

#[test]
fn reads_any_flag_but_zero_as_not_from_zero() {
    assert_eq!(pool_invokes(2, Option::Some(true), array![].span()), Option::Some(array![0].span()));
}

#[test]
fn refuses_another_flag_with_the_from_zero_address() {
    assert_eq!(pool_invokes(2, Option::Some(false), array![].span()), Option::None);
}

#[test]
fn names_the_universal_deployer() {
    assert_eq!(setup().universal_deployer(), UNIVERSAL_DEPLOYER);
}
