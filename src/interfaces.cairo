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

/// One contract for `privacy_invoke` to deploy.
///
/// The first four fields are the UDC's `deploy_contract` arguments, in the same order. `expected`
/// is the address where the contract must end up.
///
/// As felts, `not_from_zero` must be 0 or 1. See `DeploymentSerde`.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Deployment {
    pub class_hash: ClassHash,
    pub salt: felt252,
    pub not_from_zero: bool,
    pub calldata: Span<felt252>,
    pub expected: ContractAddress,
}

/// Reads and writes a `Deployment` as felts: its fields in order, with the calldata as its length
/// and then its felts.
///
/// The flag has to be 0 or 1, and any other felt fails the read. The UDC reads any felt other than
/// 0 as true, so with the default reading one deployment would have many encodings. They all deploy
/// to the same address and give the same UDC event, but the felts in the pool's invoke are public.
/// A dApp that built the list could then put a felt of its choosing in the flag, and use it to tie
/// separate actions together, while a wallet that shows the decoded list would show nothing
/// different. With this reading a list has exactly one encoding.
pub impl DeploymentSerde of Serde<Deployment> {
    fn serialize(self: @Deployment, ref output: Array<felt252>) {
        self.class_hash.serialize(ref output);
        self.salt.serialize(ref output);
        self.not_from_zero.serialize(ref output);
        self.calldata.serialize(ref output);
        self.expected.serialize(ref output);
    }

    fn deserialize(ref serialized: Span<felt252>) -> Option<Deployment> {
        let class_hash = Serde::deserialize(ref serialized)?;
        let salt = Serde::deserialize(ref serialized)?;
        let flag: felt252 = Serde::deserialize(ref serialized)?;
        let not_from_zero = if flag == 0 {
            false
        } else if flag == 1 {
            true
        } else {
            return Option::None;
        };
        let calldata = Serde::deserialize(ref serialized)?;
        let expected = Serde::deserialize(ref serialized)?;
        Option::Some(Deployment { class_hash, salt, not_from_zero, calldata, expected })
    }
}

#[starknet::interface]
pub trait IPrivateDeployer<T> {
    /// Deploys each contract in `deployments` through the Universal Deployer Contract (UDC), in
    /// the order of the list.
    ///
    /// The privacy pool calls this function as the invoke of a private action. The transaction is
    /// then the pool's, and it does not name the sender. If a new contract needs funds, such as an
    /// account's STRK for fees, the same action withdraws them straight to its `expected` address.
    /// This contract never receives or holds tokens.
    ///
    /// The pool takes its fee once per transaction, so a list deploys several contracts for one
    /// pool fee. Everything deployed in one call is publicly tied together, because it is one
    /// transaction.
    ///
    /// The call fails if any deployment in the list fails, and then nothing in the list is
    /// deployed. Every address is checked before anything is deployed, so the first two refusals
    /// below cost no constructor, unless an earlier constructor in the list took the address.
    /// - `deployer/unexpected-address`: a deployment's arguments would not deploy to its
    ///   `expected` address. Use `deployment_address` to get the right address.
    /// - `deployer/already-deployed`: a deployment's `expected` address already has a contract.
    ///   The UDC refuses this case too. That contract was constructed before this deployment: in
    ///   someone else's transaction, by an earlier constructor of the same list, or by the same
    ///   deployment earlier in the list.
    /// - A constructor fails, or the UDC refuses for its own reasons (a class that isn't declared,
    ///   or constructor calldata over 294 felts, which the UDC's event can't hold).
    ///
    /// The call also fails with `deployer/no-deployments` if the list is empty.
    ///
    /// If the call succeeds, each constructor ran inside this call and the UDC called it. In a pool
    /// action the pool makes the withdrawals before the invoke, so the constructors ran after them.
    /// If the call fails, the whole action fails and its withdrawals are undone.
    ///
    /// Returns an empty list of deposits, so the pool screens nothing and credits nothing.
    fn privacy_invoke(ref self: T, deployments: Span<Deployment>) -> Span<OpenNoteDeposit>;

    /// Returns the address where `privacy_invoke` deploys these arguments. Pass it as the
    /// deployment's `expected`.
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
