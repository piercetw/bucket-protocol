module bucket_protocol::well {

    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::tx_context::TxContext;
    use sui::object::{Self, UID};
    use sui::transfer;

    friend bucket_protocol::buck;

    struct Well<phantom T> has store, key {
        id: UID,
        sui_pool: Balance<SUI>,
        buck_pool: Balance<T>,
    }

    public(friend) fun create<T>(ctx: &mut TxContext) {
        transfer::share_object( Well<T> {
            id: object::new(ctx),
            sui_pool: balance::zero(),
            buck_pool: balance::zero(),
        });
    }

    public(friend) fun collect_sui<T>(well: &mut Well<T>, input_sui: Balance<SUI>) {
        balance::join(&mut well.sui_pool, input_sui);
    }

    public(friend) fun collect_buck<T>(well: &mut Well<T>, input_buck: Balance<T>) {
        balance::join(&mut well.buck_pool, input_buck);
    }
}
