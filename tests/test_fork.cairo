use private_deployer::address::UNIVERSAL_DEPLOYER;
use private_deployer::deployer::PrivateDeployer::errors;
use private_deployer::interfaces::{Deployment, IPrivateDeployerDispatcherTrait, IPrivateDeployerSafeDispatcher, IPrivateDeployerSafeDispatcherTrait};
use snforge_std::{get_class_hash, spy_events};
use crate::mocks::{ITargetDispatcher, ITargetDispatcherTrait};
use crate::test_deployer::{announced, class, new_deployer, one, target_calldata};

/// The class hash of the UDC on mainnet and Sepolia.
const UNIVERSAL_DEPLOYER_CLASS: felt252 = 0x01b2df6d8861670d4a8ca4670433b2418d78169c2947f46dc614e69f333745c8;

/// Deploys through the real UDC on a fork of Sepolia. The other tests use OpenZeppelin's source
/// placed at the UDC's address.
///
/// This test needs a Sepolia node, set in `Scarb.toml` under `SEPOLIA`. It is ignored by default
/// and only runs with `snforge test --ignored`.
#[test]
#[ignore]
#[fork("SEPOLIA")]
#[feature("safe_dispatcher")]
fn deploys_through_the_chains_universal_deployer() {
    assert_eq!(get_class_hash(UNIVERSAL_DEPLOYER), UNIVERSAL_DEPLOYER_CLASS.try_into().unwrap());
    let deployer = new_deployer();
    let target = class("Target");
    let calldata = target_calldata(7, array![1, 2].span());
    let mut spy = spy_events();
    for not_from_zero in array![false, true] {
        let expected = deployer.deployment_address(target, 'outis/deployer/fork', not_from_zero, calldata.span());
        deployer.privacy_invoke(one(target, 'outis/deployer/fork', not_from_zero, calldata.span(), expected));
        assert_eq!(get_class_hash(expected), target);
        let deployed = ITargetDispatcher { contract_address: expected };
        assert_eq!(deployed.value(), 7);
        assert_eq!(deployed.constructed_by(), UNIVERSAL_DEPLOYER);
        // A second call is refused, as it would be if someone else had deployed the address first.
        let safe = IPrivateDeployerSafeDispatcher { contract_address: deployer.contract_address };
        match safe.privacy_invoke(one(target, 'outis/deployer/fork', not_from_zero, calldata.span(), expected)) {
            Result::Ok(_) => panic!("not refused"),
            Result::Err(data) => assert_eq!(*data.at(0), errors::ALREADY_DEPLOYED),
        }
    }

    // A list of two, one from zero and one not, deployed by one call.
    let first = deployer.deployment_address(target, 'outis/deployer/fork/list', false, calldata.span());
    let second = deployer.deployment_address(target, 'outis/deployer/fork/list', true, calldata.span());
    let list = array![
        Deployment { class_hash: target, salt: 'outis/deployer/fork/list', not_from_zero: false, calldata: calldata.span(), expected: first },
        Deployment { class_hash: target, salt: 'outis/deployer/fork/list', not_from_zero: true, calldata: calldata.span(), expected: second },
    ];
    deployer.privacy_invoke(list.span());
    assert_eq!(get_class_hash(first), target);
    assert_eq!(get_class_hash(second), target);
    assert_eq!(announced(ref spy).len(), 4);
}
