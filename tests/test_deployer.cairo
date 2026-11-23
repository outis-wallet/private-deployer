use openzeppelin_interfaces::deployments::{IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait};
use private_deployer::address::{UNIVERSAL_DEPLOYER, deployment_address};
use private_deployer::deployer::PrivateDeployer::errors;
use private_deployer::interfaces::{
    Deployment, IPrivateDeployerDispatcher, IPrivateDeployerDispatcherTrait, IPrivateDeployerSafeDispatcher, IPrivateDeployerSafeDispatcherTrait,
};
use snforge_std::{ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyTrait, EventsFilterTrait, declare, get_class_hash, spy_events};
use starknet::{ClassHash, ContractAddress};
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

/// A list with one deployment of these arguments.
pub fn one(class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>, expected: ContractAddress) -> Span<Deployment> {
    array![Deployment { class_hash, salt, not_from_zero, calldata, expected }].span()
}

/// A deployment of the Target mock at `salt`, with `value` as its constructor's value. Its
/// `expected` address is the one the Private Deployer gives for these arguments.
fn target_at(deployer: IPrivateDeployerDispatcher, salt: felt252, not_from_zero: bool, value: felt252) -> Deployment {
    let class_hash = class("Target");
    let calldata = target_calldata(value, array![].span()).span();
    Deployment { class_hash, salt, not_from_zero, calldata, expected: deployer.deployment_address(class_hash, salt, not_from_zero, calldata) }
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
    let deposits = deployer.privacy_invoke(one(target, 0x1234, false, calldata.span(), expected));

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
    deployer.privacy_invoke(one(target, 0x1234, true, calldata.span(), expected));

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

#[test]
fn deploys_a_list_in_its_order() {
    let deployer = setup();
    let target = class("Target");
    let no_constructor = class("Pool");
    let first = target_calldata(1, array![].span());
    let second = target_calldata(2, array![5, 6].span());
    let a = deployer.deployment_address(target, 1, false, first.span());
    let b = deployer.deployment_address(target, 1, true, second.span());
    let c = deployer.deployment_address(no_constructor, 7, false, array![].span());
    let list = array![
        Deployment { class_hash: target, salt: 1, not_from_zero: false, calldata: first.span(), expected: a },
        Deployment { class_hash: target, salt: 1, not_from_zero: true, calldata: second.span(), expected: b },
        Deployment { class_hash: no_constructor, salt: 7, not_from_zero: false, calldata: array![].span(), expected: c },
    ];

    let mut spy = spy_events();
    let deposits = deployer.privacy_invoke(list.span());

    assert_eq!(deposits.len(), 0);
    // One UDC event for each deployment, in the order of the list. These constructors deploy
    // nothing themselves, so there are no other events.
    assert_eq!(announced(ref spy), array![a.into(), b.into(), c.into()]);
    let a = ITargetDispatcher { contract_address: a };
    let b = ITargetDispatcher { contract_address: b };
    assert_eq!(a.value(), 1);
    assert_eq!(b.value(), 2);
    assert_eq!(b.extra(), core::poseidon::poseidon_hash_span(array![5, 6].span()));
    assert_eq!(a.constructed_by(), UNIVERSAL_DEPLOYER);
    assert_eq!(b.constructed_by(), UNIVERSAL_DEPLOYER);
    assert_eq!(get_class_hash(c), no_constructor);
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_an_empty_list() {
    let deployer = setup();
    let mut spy = spy_events();
    assert_refused(safe(deployer).privacy_invoke(array![].span()), errors::NO_DEPLOYMENTS);
    assert_eq!(announced(ref spy).len(), 0);
}

// In the list tests below, the whole call is refused when one deployment fails. On chain the
// transaction then reverts, and anything deployed before the failure is undone with it, but its
// gas is still charged. The test runner keeps the writes and the events of a failed call. That
// lets these tests count the UDC's events to see how far a refused call got: a wrong or taken
// address must be refused before any constructor runs, wherever it is in the list. Each round
// uses salts of its own.

#[test]
#[feature("safe_dispatcher")]
fn refuses_a_list_with_one_wrong_address() {
    let deployer = setup();
    for wrong in 0..3_u32 {
        let base: felt252 = (10 * wrong).into();
        let mut list = array![];
        for at in 0..3_u32 {
            let mut deployment = target_at(deployer, base + at.into(), at == 1, 7);
            if at == wrong {
                // The address of the same deployment at another salt.
                deployment.expected = target_at(deployer, base + 100, at == 1, 7).expected;
            }
            list.append(deployment);
        }
        let mut spy = spy_events();
        assert_refused(safe(deployer).privacy_invoke(list.span()), errors::UNEXPECTED_ADDRESS);
        assert_eq!(announced(ref spy).len(), 0);
    }
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_a_list_with_one_address_taken() {
    let deployer = setup();
    let universal_deployer = IUniversalDeployerDispatcher { contract_address: UNIVERSAL_DEPLOYER };
    for taken in 0..3_u32 {
        let base: felt252 = (10 * taken).into();
        let mut list = array![];
        for at in 0..3_u32 {
            list.append(target_at(deployer, base + at.into(), false, 7));
        }
        // A stranger deploys one of the addresses first, from zero through the UDC.
        let first = *list.at(taken);
        universal_deployer.deploy_contract(first.class_hash, first.salt, false, first.calldata);
        let mut spy = spy_events();
        assert_refused(safe(deployer).privacy_invoke(list.span()), errors::ALREADY_DEPLOYED);
        assert_eq!(announced(ref spy).len(), 0);
    }
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_the_same_deployment_twice_in_a_list() {
    let deployer = setup();
    for not_from_zero in array![false, true] {
        let twice = target_at(deployer, 1, not_from_zero, 7);
        assert_refused(safe(deployer).privacy_invoke(array![twice, twice].span()), errors::ALREADY_DEPLOYED);
    }
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_an_address_an_earlier_constructor_took() {
    // The first deployment's constructor deploys the second deployment's address, from zero
    // through the UDC, before the Private Deployer gets to it. The second deployment must be
    // refused. This is why the check for an existing contract is made just before each deployment
    // and not once for the whole list.
    let deployer = setup();
    let later = target_at(deployer, 2, false, 7);
    let mut squatter_calldata: Array<felt252> = array![later.class_hash.into(), later.salt];
    later.calldata.serialize(ref squatter_calldata);
    let squatter = class("Squatter");
    let first = Deployment {
        class_hash: squatter,
        salt: 1,
        not_from_zero: false,
        calldata: squatter_calldata.span(),
        expected: deployer.deployment_address(squatter, 1, false, squatter_calldata.span()),
    };
    assert_refused(safe(deployer).privacy_invoke(array![first, later].span()), errors::ALREADY_DEPLOYED);
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_a_later_not_from_zero_address_an_earlier_constructor_took() {
    // A not-from-zero address can only be reached through the Private Deployer. Here the first
    // deployment's constructor calls the Private Deployer itself, to deploy the second deployment's
    // address before the outer call gets to it.
    let deployer = setup();
    let later = target_at(deployer, 2, true, 7);
    let mut inner: Array<felt252> = array![1];
    inner.append_span(raw_of(later, 1).span());
    let mut calldata: Array<felt252> = array![deployer.contract_address.into()];
    inner.span().serialize(ref calldata);
    let reenters = class("ReentersWith");
    let first = Deployment {
        class_hash: reenters,
        salt: 1,
        not_from_zero: false,
        calldata: calldata.span(),
        expected: deployer.deployment_address(reenters, 1, false, calldata.span()),
    };
    assert_refused(safe(deployer).privacy_invoke(array![first, later].span()), errors::ALREADY_DEPLOYED);
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_a_later_address_an_earlier_constructor_deployed_itself() {
    // The first deployment's constructor deploys the second deployment's from-zero address with
    // `deploy_syscall`. That contract's constructor caller would be the first contract, not the
    // UDC, so the second deployment must be refused.
    let deployer = setup();
    let later = target_at(deployer, 2, false, 7);
    let mut calldata: Array<felt252> = array![later.class_hash.into(), later.salt];
    later.calldata.serialize(ref calldata);
    let itself = class("DeploysItself");
    let first = Deployment {
        class_hash: itself, salt: 1, not_from_zero: false, calldata: calldata.span(), expected: deployer.deployment_address(itself, 1, false, calldata.span()),
    };
    assert_refused(safe(deployer).privacy_invoke(array![first, later].span()), errors::ALREADY_DEPLOYED);
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
            deployer.privacy_invoke(one(no_constructor, salt, not_from_zero, array![].span(), bare));
            assert_eq!(get_class_hash(bare), no_constructor);

            let long = deployer.deployment_address(target, salt, not_from_zero, longest.span());
            deployer.privacy_invoke(one(target, salt, not_from_zero, longest.span(), long));
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
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, false, calldata.span(), not_from_zero)), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, true, calldata.span(), from_zero)), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(one(target, 2, false, calldata.span(), from_zero)), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, false, target_calldata(8, array![].span()).span(), from_zero)), errors::UNEXPECTED_ADDRESS);
    let anothers = deployment_address(UNIVERSAL_DEPLOYER, target, 1, true, calldata.span());
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, true, calldata.span(), anothers)), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, false, calldata.span(), 0.try_into().unwrap())), errors::UNEXPECTED_ADDRESS);

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
    deployer.privacy_invoke(one(target, 1, false, calldata.span(), there));
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, false, target_calldata(8, array![].span()).span(), there)), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, true, calldata.span(), there)), errors::UNEXPECTED_ADDRESS);
    assert_refused(safe(deployer).privacy_invoke(one(class("Refuses"), 1, false, array![].span(), there)), errors::UNEXPECTED_ADDRESS);
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
    assert_refused(safe(deployer).privacy_invoke(one(target, 1, false, calldata.span(), expected)), errors::ALREADY_DEPLOYED);
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

    assert_refused(safe(deployer).privacy_invoke(one(target, 1, false, calldata.span(), expected)), errors::ALREADY_DEPLOYED);
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
        deployer.privacy_invoke(one(target, 1, not_from_zero, calldata.span(), expected));
        assert_refused(safe(deployer).privacy_invoke(one(target, 1, not_from_zero, calldata.span(), expected)), errors::ALREADY_DEPLOYED);
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
        assert_refused(safe(deployer).privacy_invoke(one(target, 1, not_from_zero, calldata.span(), expected)), errors::UNEXPECTED_ADDRESS);
    }
}

#[test]
#[feature("safe_dispatcher")]
fn refuses_a_universal_deployer_that_deploys_the_second_elsewhere() {
    // The fake UDC answers correctly for the first deployment and wrongly for the second, so the
    // UDC's answer has to be checked for every deployment in the list.
    declare("ElsewhereSecond").unwrap().contract_class().deploy_at(@array![], UNIVERSAL_DEPLOYER).unwrap();
    let deployer = new_deployer();
    let no_constructor = class("Pool");
    let mut list = array![];
    for salt in array![1, 2] {
        let expected = deployer.deployment_address(no_constructor, salt, false, array![].span());
        list.append(Deployment { class_hash: no_constructor, salt, not_from_zero: false, calldata: array![].span(), expected });
    }
    assert_refused(safe(deployer).privacy_invoke(list.span()), errors::UNEXPECTED_ADDRESS);
}

#[test]
fn refuses_a_constructor_asking_for_its_own_deployment_again() {
    let deployer = setup();
    let reenters = class("Reenters");
    let mut spy = spy_events();
    for flag in array![0, 1] {
        let calldata = array![deployer.contract_address.into(), 1, flag];
        let expected = deployer.deployment_address(reenters, 1, flag == 1, calldata.span());
        deployer.privacy_invoke(one(reenters, 1, flag == 1, calldata.span(), expected));
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
    assert_refused(safe(deployer).privacy_invoke(one(refuses, 1, false, array![].span(), expected)), 'target/refuses');
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
    match safe(deployer).privacy_invoke(one(target, 1, false, calldata.span(), expected)) {
        Result::Ok(_) => panic!("not refused"),
        Result::Err(data) => assert!(*data.at(0) != errors::UNEXPECTED_ADDRESS, "refused for the address"),
    }
}

/// The raw felts of one deployment of a Target at `salt`, as the pool passes them: the class, the
/// salt, `flag`, the constructor calldata as a span, then the expected address for the flag that
/// `expected` names. If `expected` is `None`, the address is left out.
fn raw_entry(deployer: IPrivateDeployerDispatcher, salt: felt252, flag: felt252, expected: Option<bool>) -> Array<felt252> {
    let target = class("Target");
    let calldata = target_calldata(7, array![].span());
    let mut raw: Array<felt252> = array![target.into(), salt, flag];
    calldata.serialize(ref raw);
    if let Option::Some(not_from_zero) = expected {
        raw.append(deployer.deployment_address(target, salt, not_from_zero, calldata.span()).into());
    }
    raw
}

/// The raw felts of `deployment`, as the pool passes them, with `flag` in place of its
/// `not_from_zero`.
fn raw_of(deployment: Deployment, flag: felt252) -> Array<felt252> {
    let mut raw: Array<felt252> = array![deployment.class_hash.into(), deployment.salt, flag];
    deployment.calldata.serialize(ref raw);
    raw.append(deployment.expected.into());
    raw
}

/// Calls `privacy_invoke` the way the pool does, by selector with raw felts. Returns what the call
/// returned, or `None` if the call failed.
fn pool_calls(deployer: IPrivateDeployerDispatcher, raw: Span<felt252>) -> Option<Span<felt252>> {
    let (pool, _) = declare("Pool").unwrap().contract_class().deploy(@array![]).unwrap();
    IPoolDispatcher { contract_address: pool }.invoke(deployer.contract_address, raw)
}

/// Calls `privacy_invoke` the way the pool does, with a list of one deployment of a Target at salt
/// 1 (see `raw_entry`).
fn pool_invokes(flag: felt252, expected: Option<bool>) -> Option<Span<felt252>> {
    let deployer = setup();
    let mut raw: Array<felt252> = array![1];
    raw.append_span(raw_entry(deployer, 1, flag, expected).span());
    pool_calls(deployer, raw.span())
}

#[test]
fn the_pool_reads_no_deposits_from_a_list_of_two() {
    // One deployment from zero and one not. The return value is an empty span of deposits with
    // nothing after it, and both contracts are deployed.
    let deployer = setup();
    let first = target_at(deployer, 1, false, 7);
    let second = target_at(deployer, 2, true, 7);
    let mut raw: Array<felt252> = array![2];
    raw.append_span(raw_of(first, 0).span());
    raw.append_span(raw_of(second, 1).span());
    assert_eq!(pool_calls(deployer, raw.span()), Option::Some(array![0].span()));
    assert_eq!(get_class_hash(first.expected), first.class_hash);
    assert_eq!(get_class_hash(second.expected), second.class_hash);
}

#[test]
fn refuses_calldata_without_the_expected_address() {
    assert_eq!(pool_invokes(0, Option::None), Option::None);
}

#[test]
fn refuses_a_count_longer_than_the_list() {
    let deployer = setup();
    let mut raw: Array<felt252> = array![2];
    raw.append_span(raw_entry(deployer, 1, 0, Option::Some(false)).span());
    assert_eq!(pool_calls(deployer, raw.span()), Option::None);
}

#[test]
fn refuses_a_count_shorter_than_the_list() {
    // The second entry is left over after the list is read.
    let deployer = setup();
    let mut raw: Array<felt252> = array![1];
    raw.append_span(raw_entry(deployer, 1, 0, Option::Some(false)).span());
    raw.append_span(raw_entry(deployer, 2, 0, Option::Some(false)).span());
    assert_eq!(pool_calls(deployer, raw.span()), Option::None);
}

#[test]
fn refuses_felts_after_the_arguments() {
    let deployer = setup();
    let mut raw: Array<felt252> = array![1];
    raw.append_span(raw_entry(deployer, 1, 0, Option::Some(false)).span());
    raw.append(0);
    assert_eq!(pool_calls(deployer, raw.span()), Option::None);
}

#[test]
fn refuses_an_empty_list_from_the_pool() {
    let deployer = setup();
    assert_eq!(pool_calls(deployer, array![0].span()), Option::None);
}

// The UDC treats any flag other than 0 as not-from-zero. This was checked against the real UDC
// on both networks on 2026-11-20. In a list, the Private Deployer refuses any flag but 0 or 1, so
// that a list has one encoding (see `DeploymentSerde`).

#[test]
fn refuses_a_flag_that_is_neither_zero_nor_one() {
    // With the address for either reading of the flag.
    let deployer = setup();
    for flag in array![2, 0x6f75746973, MAX_FELT] {
        for not_from_zero in array![true, false] {
            let mut raw: Array<felt252> = array![1];
            raw.append_span(raw_entry(deployer, 1, flag, Option::Some(not_from_zero)).span());
            assert_eq!(pool_calls(deployer, raw.span()), Option::None);
        }
    }
}

#[test]
fn names_the_universal_deployer() {
    assert_eq!(setup().universal_deployer(), UNIVERSAL_DEPLOYER);
}

#[test]
fn refuses_a_flag_that_is_neither_zero_nor_one_anywhere_in_a_list() {
    // A flag of 2 in the second place refuses the whole list, and nothing is deployed.
    let deployer = setup();
    let first = target_at(deployer, 5, false, 7);
    let second = target_at(deployer, 6, true, 7);
    let mut raw: Array<felt252> = array![2];
    raw.append_span(raw_of(first, 0).span());
    raw.append_span(raw_of(second, 2).span());
    let mut spy = spy_events();
    assert_eq!(pool_calls(deployer, raw.span()), Option::None);
    assert_eq!(announced(ref spy).len(), 0);
    // The same list with a flag of 1 is the one encoding that deploys it.
    let mut raw: Array<felt252> = array![2];
    raw.append_span(raw_of(first, 0).span());
    raw.append_span(raw_of(second, 1).span());
    assert_eq!(pool_calls(deployer, raw.span()), Option::Some(array![0].span()));
    assert_eq!(get_class_hash(second.expected), second.class_hash);
}

#[test]
fn writes_a_list_back_as_the_felts_it_was_read_from() {
    // What a wallet shows is the list decoded; what the pool sends is the felts. Decoding and
    // encoding again must give the same felts, so that the two can't differ.
    let deployer = setup();
    let first = target_at(deployer, 1, false, 7);
    let second = target_at(deployer, 2, true, 8);
    let mut raw: Array<felt252> = array![2];
    raw.append_span(raw_of(first, 0).span());
    raw.append_span(raw_of(second, 1).span());
    let mut input = raw.span();
    let list: Span<Deployment> = Serde::deserialize(ref input).unwrap();
    assert!(input.is_empty());
    let mut again = array![];
    list.serialize(ref again);
    assert_eq!(again, raw);
}

#[test]
fn refuses_a_calldata_length_that_runs_into_the_next_deployment() {
    // The first deployment's calldata is [7, 0], length 2. A longer length swallows felts of the
    // next deployment, or runs past the end. Every one is refused.
    let deployer = setup();
    let first = target_at(deployer, 1, false, 7);
    let second = target_at(deployer, 2, false, 7);
    for claimed in array![3, 4, 8, 9, 10, 11, 1000, 0x100000000, MAX_FELT] {
        let mut raw: Array<felt252> = array![2, first.class_hash.into(), first.salt, 0, claimed, 7, 0, first.expected.into()];
        raw.append_span(raw_of(second, 0).span());
        assert_eq!(pool_calls(deployer, raw.span()), Option::None);
    }
    assert_eq!(get_class_hash(first.expected), 0.try_into().unwrap());
}

#[test]
fn refuses_huge_counts_and_the_one_per_call_layout() {
    let deployer = setup();
    let only = target_at(deployer, 1, false, 7);
    for count in array![0x100000000, 0x100000001, MAX_FELT] {
        let mut raw: Array<felt252> = array![count];
        raw.append_span(raw_of(only, 0).span());
        assert_eq!(pool_calls(deployer, raw.span()), Option::None);
    }
    // No felts at all.
    assert_eq!(pool_calls(deployer, array![].span()), Option::None);
    // The layout of the version that took one deployment per call, with no count.
    assert_eq!(pool_calls(deployer, raw_of(only, 0).span()), Option::None);
    assert_eq!(get_class_hash(only.expected), 0.try_into().unwrap());
}

#[test]
fn refuses_an_expected_address_out_of_range() {
    // 2^251 - 256 is the first felt that is not a contract address.
    let deployer = setup();
    let only = target_at(deployer, 1, false, 7);
    let raw = array![1, only.class_hash.into(), only.salt, 0, 2, 7, 0, 0x7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00];
    assert_eq!(pool_calls(deployer, raw.span()), Option::None);
}
