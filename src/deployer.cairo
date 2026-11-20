/// The Private Deployer Contract lets the privacy pool deploy a contract through the Universal
/// Deployer Contract (UDC).
///
/// The pool can only call a contract's `privacy_invoke` function, so it can't call the UDC
/// directly. This contract receives the pool's call and forwards it to the UDC. The result is an
/// ordinary UDC deployment: the contract lands at the same address, the UDC calls its constructor,
/// and the UDC emits its `ContractDeployed` event with this contract as the `deployer`.
///
/// "Private" only describes who paid. The pool hides the sender, but the deployment itself is
/// public.
///
/// - It has no storage, no owner and no settings, and it can't be upgraded.
/// - It never receives tokens and has no function that moves them. Anyone can call it. A call from
///   outside the pool is a UDC deployment with one extra step.
/// - It refuses an address that already has a contract, as the UDC does. So when a call succeeds,
///   the constructor ran inside that call.
/// - It returns no deposits, so the pool screens nothing.
#[starknet::contract]
pub mod PrivateDeployer {
    use openzeppelin_interfaces::deployments::{IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait};
    use starknet::syscalls::get_class_hash_at_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait, get_contract_address};
    use crate::address::{UNIVERSAL_DEPLOYER, deployment_address};
    use crate::interfaces::{IPrivateDeployer, OpenNoteDeposit};

    pub mod errors {
        pub const UNEXPECTED_ADDRESS: felt252 = 'deployer/unexpected-address';
        pub const ALREADY_DEPLOYED: felt252 = 'deployer/already-deployed';
    }

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl PrivateDeployerImpl of IPrivateDeployer<ContractState> {
        fn privacy_invoke(
            ref self: ContractState, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>, expected: ContractAddress,
        ) -> Span<OpenNoteDeposit> {
            // Check the address first. The caller was shown `expected`, so nothing may be deployed
            // anywhere else.
            assert(self.deployment_address(class_hash, salt, not_from_zero, calldata) == expected, errors::UNEXPECTED_ADDRESS);
            // Refuse an address that already has a contract. That contract was constructed in
            // someone else's transaction, before this action's withdrawals arrived. The UDC would
            // also refuse it, but without a named error.
            let class_there: felt252 = get_class_hash_at_syscall(expected).unwrap_syscall().into();
            assert(class_there == 0, errors::ALREADY_DEPLOYED);
            let universal_deployer = IUniversalDeployerDispatcher { contract_address: UNIVERSAL_DEPLOYER };
            let deployed = universal_deployer.deploy_contract(class_hash, salt, not_from_zero, calldata);
            // The UDC computes the address from the same arguments. Check that it agrees with this
            // contract's own computation.
            assert(deployed == expected, errors::UNEXPECTED_ADDRESS);
            array![].span()
        }

        fn deployment_address(self: @ContractState, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>) -> ContractAddress {
            deployment_address(get_contract_address(), class_hash, salt, not_from_zero, calldata)
        }

        fn universal_deployer(self: @ContractState) -> ContractAddress {
            UNIVERSAL_DEPLOYER
        }
    }
}
