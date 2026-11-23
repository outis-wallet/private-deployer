use starknet::{ClassHash, ContractAddress};

#[starknet::interface]
pub trait ITarget<T> {
    fn value(self: @T) -> felt252;
    /// Returns `poseidon_hash_span` of the constructor's `extra` argument.
    fn extra(self: @T) -> felt252;
    /// Returns the address that called the constructor.
    fn constructed_by(self: @T) -> ContractAddress;
}

/// A contract for the tests to deploy. It stores its constructor arguments and the address that
/// called the constructor.
#[starknet::contract]
pub mod Target {
    use core::poseidon::poseidon_hash_span;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        value: felt252,
        extra: felt252,
        constructed_by: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, value: felt252, extra: Span<felt252>) {
        self.value.write(value);
        self.extra.write(poseidon_hash_span(extra));
        self.constructed_by.write(get_caller_address());
    }

    #[abi(embed_v0)]
    impl TargetImpl of super::ITarget<ContractState> {
        fn value(self: @ContractState) -> felt252 {
            self.value.read()
        }

        fn extra(self: @ContractState) -> felt252 {
            self.extra.read()
        }

        fn constructed_by(self: @ContractState) -> ContractAddress {
            self.constructed_by.read()
        }
    }
}

/// A contract whose constructor always fails.
#[starknet::contract]
pub mod Refuses {
    #[storage]
    struct Storage {}

    #[constructor]
    fn constructor(ref self: ContractState) {
        assert(false, 'target/refuses');
    }
}

#[starknet::interface]
pub trait IPool<T> {
    /// Calls `privacy_invoke` on `target` the way the pool does: by selector, with `calldata` passed
    /// as raw felts. Returns what the call returned, or `None` if the call failed.
    fn invoke(ref self: T, target: ContractAddress, calldata: Span<felt252>) -> Option<Span<felt252>>;
}

/// A stand-in for the pool. It only does the one thing these tests need: calling the target of an
/// invoke.
#[starknet::contract]
pub mod Pool {
    use starknet::ContractAddress;
    use starknet::syscalls::call_contract_syscall;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl PoolImpl of super::IPool<ContractState> {
        fn invoke(ref self: ContractState, target: ContractAddress, calldata: Span<felt252>) -> Option<Span<felt252>> {
            match call_contract_syscall(target, selector!("privacy_invoke"), calldata) {
                Result::Ok(returned) => Option::Some(returned),
                Result::Err(_) => Option::None,
            }
        }
    }
}

#[starknet::interface]
pub trait IFactory<T> {
    fn deploy(ref self: T, class_hash: ClassHash, salt: felt252, calldata: Span<felt252>) -> ContractAddress;
}

/// A third party's contract that deploys from zero by itself. The contract lands at the same
/// address as a from-zero UDC deployment, but this factory is the constructor's caller.
#[starknet::contract]
pub mod Factory {
    use starknet::syscalls::deploy_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl FactoryImpl of super::IFactory<ContractState> {
        fn deploy(ref self: ContractState, class_hash: ClassHash, salt: felt252, calldata: Span<felt252>) -> ContractAddress {
            let (address, _) = deploy_syscall(class_hash, salt, calldata, true).unwrap_syscall();
            address
        }
    }
}

/// A fake UDC that deploys to a different address, by using a different salt. A test places it at
/// the UDC's address to check what happens when the UDC and the Private Deployer disagree about
/// the address.
#[starknet::contract]
pub mod Elsewhere {
    use openzeppelin_interfaces::deployments::IUniversalDeployer;
    use starknet::syscalls::deploy_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl ElsewhereImpl of IUniversalDeployer<ContractState> {
        fn deploy_contract(ref self: ContractState, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>) -> ContractAddress {
            let (address, _) = deploy_syscall(class_hash, salt + 1, calldata, !not_from_zero).unwrap_syscall();
            address
        }
    }
}

#[starknet::interface]
pub trait IReenters<T> {
    /// Returns whether the constructor's call back to the Private Deployer was refused.
    fn refused(self: @T) -> bool;
}

/// A class whose constructor calls the Private Deployer and asks it to deploy the same contract
/// again, with the same arguments. It stores whether that call was refused.
#[starknet::contract]
pub mod Reenters {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::{call_contract_syscall, get_class_hash_at_syscall};
    use starknet::{ContractAddress, SyscallResultTrait, get_contract_address};

    #[storage]
    struct Storage {
        refused: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, deployer: ContractAddress, salt: felt252, not_from_zero: felt252) {
        let this = get_contract_address();
        let class_hash = get_class_hash_at_syscall(this).unwrap_syscall();
        // The arguments of privacy_invoke: a list of one deployment, with the fields class_hash,
        // salt, not_from_zero, calldata and expected. The calldata is this constructor's own
        // calldata.
        let again = array![1, class_hash.into(), salt, not_from_zero, 3, deployer.into(), salt, not_from_zero, this.into()];
        self.refused.write(call_contract_syscall(deployer, selector!("privacy_invoke"), again.span()).is_err());
    }

    #[abi(embed_v0)]
    impl ReentersImpl of super::IReenters<ContractState> {
        fn refused(self: @ContractState) -> bool {
            self.refused.read()
        }
    }
}

#[starknet::interface]
pub trait IBorrower<T> {
    fn deploy(
        ref self: T, deployer_class: ClassHash, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>, expected: ContractAddress,
    );
    fn address(self: @T, deployer_class: ClassHash, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>) -> ContractAddress;
}

/// A contract that runs the Private Deployer's class as its own code, with `library_call`.
#[starknet::contract]
pub mod Borrower {
    use private_deployer::interfaces::{Deployment, IPrivateDeployerDispatcherTrait, IPrivateDeployerLibraryDispatcher};
    use starknet::{ClassHash, ContractAddress};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl BorrowerImpl of super::IBorrower<ContractState> {
        fn deploy(
            ref self: ContractState,
            deployer_class: ClassHash,
            class_hash: ClassHash,
            salt: felt252,
            not_from_zero: bool,
            calldata: Span<felt252>,
            expected: ContractAddress,
        ) {
            let deployments = array![Deployment { class_hash, salt, not_from_zero, calldata, expected }];
            IPrivateDeployerLibraryDispatcher { class_hash: deployer_class }.privacy_invoke(deployments.span());
        }

        fn address(
            self: @ContractState, deployer_class: ClassHash, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>,
        ) -> ContractAddress {
            IPrivateDeployerLibraryDispatcher { class_hash: deployer_class }.deployment_address(class_hash, salt, not_from_zero, calldata)
        }
    }
}

/// A class whose constructor deploys another contract from zero through the UDC, with the class,
/// salt and calldata it is given. A test puts it in a list before that other contract, so that the
/// address is already taken when the Private Deployer gets to it.
#[starknet::contract]
pub mod Squatter {
    use openzeppelin_interfaces::deployments::{IUniversalDeployerDispatcher, IUniversalDeployerDispatcherTrait};
    use private_deployer::address::UNIVERSAL_DEPLOYER;
    use starknet::ClassHash;

    #[storage]
    struct Storage {}

    #[constructor]
    // The parameters aren't named `class_hash` or `calldata`, which snforge's generated deployment
    // helper already uses.
    fn constructor(ref self: ContractState, of_class: ClassHash, salt: felt252, args: Span<felt252>) {
        IUniversalDeployerDispatcher { contract_address: UNIVERSAL_DEPLOYER }.deploy_contract(of_class, salt, false, args);
    }
}

/// A class whose constructor calls the Private Deployer with the raw calldata it is given, and
/// fails if that call fails.
#[starknet::contract]
pub mod ReentersWith {
    use starknet::syscalls::call_contract_syscall;
    use starknet::{ContractAddress, SyscallResultTrait};

    #[storage]
    struct Storage {}

    #[constructor]
    fn constructor(ref self: ContractState, deployer: ContractAddress, raw: Span<felt252>) {
        call_contract_syscall(deployer, selector!("privacy_invoke"), raw).unwrap_syscall();
    }
}

/// A class whose constructor deploys another contract from zero itself, with `deploy_syscall`, so
/// that it, and not the UDC, is that contract's constructor's caller.
#[starknet::contract]
pub mod DeploysItself {
    use starknet::syscalls::deploy_syscall;
    use starknet::{ClassHash, SyscallResultTrait};

    #[storage]
    struct Storage {}

    #[constructor]
    fn constructor(ref self: ContractState, of_class: ClassHash, salt: felt252, args: Span<felt252>) {
        deploy_syscall(of_class, salt, args, true).unwrap_syscall();
    }
}

/// A fake UDC that deploys where the real one does, but answers a different address when the salt
/// is 2. A test places it at the UDC's address to check that the answer is checked for every
/// deployment in a list, not only the first.
#[starknet::contract]
pub mod ElsewhereSecond {
    use openzeppelin_interfaces::deployments::IUniversalDeployer;
    use starknet::syscalls::deploy_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl ElsewhereSecondImpl of IUniversalDeployer<ContractState> {
        fn deploy_contract(ref self: ContractState, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>) -> ContractAddress {
            let (address, _) = deploy_syscall(class_hash, salt, calldata, !not_from_zero).unwrap_syscall();
            if salt == 2 {
                1.try_into().unwrap()
            } else {
                address
            }
        }
    }
}
