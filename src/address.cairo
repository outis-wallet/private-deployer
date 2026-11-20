use openzeppelin_utils::deployments::{DeployerInfo, calculate_contract_address_from_udc};
use starknet::{ClassHash, ContractAddress};

/// The address of the Universal Deployer Contract (UDC). It is the same on mainnet and Sepolia.
///
/// On both networks the address holds class
/// `0x01b2df6d8861670d4a8ca4670433b2418d78169c2947f46dc614e69f333745c8` (checked 2026-11-20). That
/// class has two entry points, `deploy_contract` and `deployContract`, no constructor and no L1
/// handler. OpenZeppelin's source for it never replaces a class, so the contract at this address
/// can't change.
pub const UNIVERSAL_DEPLOYER: ContractAddress = 0x02ceed65a4bd731034c01113685c831b01c15d7d432f71afb1cf1634b53a2125.try_into().unwrap();

/// Returns the address where the UDC deploys a contract when `caller` calls it.
///
/// - If `not_from_zero` is false, the deployment is "from zero": the address does not depend on
///   who deploys. It is the same for every caller, and it is the address an account gets when it
///   deploys itself.
/// - If `not_from_zero` is true, the UDC is the deployer and the salt becomes
///   `pedersen(caller, salt)`. This is how the UDC itself computes it.
pub fn deployment_address(caller: ContractAddress, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>) -> ContractAddress {
    let deployer_info = if not_from_zero {
        Option::Some(DeployerInfo { caller_address: caller, udc_address: UNIVERSAL_DEPLOYER })
    } else {
        Option::None
    };
    calculate_contract_address_from_udc(salt, class_hash, calldata, deployer_info)
}
