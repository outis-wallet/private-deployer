use starknet::{ClassHash, ContractAddress};

/// One deposit that a `privacy_invoke` function asks the pool to credit to an open note. It has
/// the same layout as the pool's `privacy::objects::OpenNoteDeposit`.
///
/// The Private Deployer always returns an empty list of these.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct OpenNoteDeposit {
    pub note_id: felt252,
    pub token: ContractAddress,
    pub amount: u128,
}

#[starknet::interface]
pub trait IPrivateDeployer<T> {
    /// Deploys a contract through the Universal Deployer Contract (UDC).
    ///
    /// The first four arguments are the UDC's `deploy_contract` arguments, in the same order.
    /// `expected` is the address where the contract must end up.
    ///
    /// The privacy pool calls this function as the invoke of a private action. The transaction is
    /// then the pool's, and it does not name the sender. If the new contract needs funds, such as
    /// an account's STRK for fees, the same action withdraws them straight to `expected`. This
    /// contract never receives or holds tokens.
    ///
    /// The call fails in three cases:
    /// - `deployer/unexpected-address`: these arguments would not deploy to `expected`. Use
    ///   `deployment_address` to get the right address.
    /// - `deployer/already-deployed`: `expected` already has a contract. The UDC refuses this
    ///   case too. That contract's constructor ran in someone else's transaction.
    /// - The constructor fails.
    ///
    /// If the call succeeds, the constructor ran inside this call and the UDC called it. In a pool
    /// action the pool makes the withdrawals before the invoke, so the constructor ran after them.
    /// If the call fails, the whole action fails and its withdrawals are undone.
    ///
    /// Returns an empty list of deposits, so the pool screens nothing and credits nothing.
    fn privacy_invoke(
        ref self: T, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>, expected: ContractAddress,
    ) -> Span<OpenNoteDeposit>;

    /// Returns the address where `privacy_invoke` deploys these arguments. Pass it as `expected`.
    ///
    /// Call this on the deployed contract itself. If another contract runs this class as its own
    /// code with `library_call`, the answer is for that contract, not for this one.
    ///
    /// - If `not_from_zero` is false, this is the address the UDC gives any caller. It is also the
    ///   address an account gets when it deploys itself.
    /// - If `not_from_zero` is true, this is the address the UDC gives this contract as its
    ///   caller. It is the same for everyone who deploys through this contract, so no sender gets
    ///   an address of their own.
    fn deployment_address(self: @T, class_hash: ClassHash, salt: felt252, not_from_zero: bool, calldata: Span<felt252>) -> ContractAddress;

    /// Returns the address of the UDC that this contract deploys through.
    fn universal_deployer(self: @T) -> ContractAddress;
}
