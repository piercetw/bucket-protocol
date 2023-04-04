module bucket_protocol::well {

    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;
    use sui::object::{Self, UID};
    use sui::transfer;

    friend bucket_protocol::buck;

    struct Well<phantom T> has store, key {
        id: UID,
        pool: Balance<T>,
    }

    public(friend) fun create<T>(ctx: &mut TxContext) {
        transfer::share_object( Well<T> {
            id: object::new(ctx),
            pool: balance::zero(),
        });
    }

    public(friend) fun collect_fee<T>(well: &mut Well<T>, input: Balance<T>) {
        balance::join(&mut well.pool, input);
    }

    #[test_only]
    public fun new<T>(ctx: &mut TxContext): Well<T> {
        Well { id: object::new(ctx), pool: balance::zero() }
    }
}
