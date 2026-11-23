/// The Private Deployer Contract lets the privacy pool deploy contracts through the Universal
/// Deployer Contract (UDC). One call deploys a list of contracts.
///
/// The pool can only call a contract's `privacy_invoke` function, so it can't call the UDC
/// directly. This contract receives the pool's call and forwards each deployment to the UDC. Each
/// result is an ordinary UDC deployment: the contract lands at the same address, the UDC calls its
/// constructor, and the UDC emits its `ContractDeployed` event with this contract as the
/// `deployer`.
///
/// "Private" only describes who paid. The pool hides the sender, but the deployment itself is
/// public.
///
/// - It has no storage, no owner and no settings, and it can't be upgraded.
/// - It never receives tokens and has no function that moves them. Anyone can call it. A call from
///   outside the pool is a UDC deployment with one extra step.
/// - It refuses an address that already has a contract, as the UDC does. So when a call succeeds,
///   every constructor ran inside that call.
/// - If one deployment in the list fails, the whole call fails. Every address in the list is
///   checked before anything is deployed, so a wrong or taken address costs no constructor.
/// - It returns no deposits, so the pool screens nothing.
#[starknet::contract]
pub mod PrivateDeployer {
    use openzeppelin_interfaces::deployments::{IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait};
    use starknet::syscalls::get_class_hash_at_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait, get_contract_address};
    use crate::address::{UNIVERSAL_DEPLOYER, deployment_address};
    use crate::interfaces::{Deployment, IPrivateDeployer, OpenNoteDeposit};

    pub mod errors {
        pub const UNEXPECTED_ADDRESS: felt252 = 'deployer/unexpected-address';
        pub const ALREADY_DEPLOYED: felt252 = 'deployer/already-deployed';
        pub const NO_DEPLOYMENTS: felt252 = 'deployer/no-deployments';
    }

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl PrivateDeployerImpl of IPrivateDeployer<ContractState> {
        fn privacy_invoke(ref self: ContractState, deployments: Span<Deployment>) -> Span<OpenNoteDeposit> {
            assert(deployments.len() != 0, errors::NO_DEPLOYMENTS);
            let universal_deployer = IUniversalDeployerDispatcher { contract_address: UNIVERSAL_DEPLOYER };
            // This contract is the UDC's caller for every deployment, so its address is read once.
            let this = get_contract_address();
            // First, every address, before anything is deployed. A list refused at a late entry
            // would otherwise run every constructor before it, and whoever sent the transaction
            // pays for that work even though it reverts. A stranger who takes the last address of
            // someone's list would set that cost with one deployment of their own.
            for deployment in deployments {
                let Deployment { class_hash, salt, not_from_zero, calldata, expected } = *deployment;
                // The caller was shown `expected`, so this deployment may land nowhere else.
                assert(deployment_address(this, class_hash, salt, not_from_zero, calldata) == expected, errors::UNEXPECTED_ADDRESS);
                // Refuse an address that already has a contract. That contract was constructed in
                // someone else's transaction, before this action's withdrawals arrived. The UDC
                // would also refuse it, but without a named error.
                assert(is_empty(expected), errors::ALREADY_DEPLOYED);
            }
            // Then deploy them in order.
            for deployment in deployments {
                let Deployment { class_hash, salt, not_from_zero, calldata, expected } = *deployment;
                // Check again just before each deployment. An earlier constructor in this list can
                // deploy anywhere, and so can the same deployment earlier in the list.
                assert(is_empty(expected), errors::ALREADY_DEPLOYED);
                let deployed = universal_deployer.deploy_contract(class_hash, salt, not_from_zero, calldata);
                // The UDC computes the address from the same arguments. Check that it agrees with
                // this contract's own computation.
                assert(deployed == expected, errors::UNEXPECTED_ADDRESS);
            }
            array![].span()
        }

        fn deployment_address(self: @ContractState, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>) -> ContractAddress {
            deployment_address(get_contract_address(), class_hash, salt, not_from_zero, calldata)
        }

        fn universal_deployer(self: @ContractState) -> ContractAddress {
            UNIVERSAL_DEPLOYER
        }
    }

    /// Whether no contract is at `address`.
    fn is_empty(address: ContractAddress) -> bool {
        let class_there: felt252 = get_class_hash_at_syscall(address).unwrap_syscall().into();
        class_there == 0
    }
}
