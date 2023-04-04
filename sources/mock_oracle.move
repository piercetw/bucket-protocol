module bucket_protocol::mock_oracle {

    use sui::transfer;
    use sui::sui::SUI;
    use sui::object::UID;
    use sui::tx_context::TxContext;
    use sui::tx_context;
    use sui::object;

    struct FeederCap has key {
        id: UID,
    }

    struct PriceFeed<phantom T> has key {
        id: UID,
        price: u64,
        denominator: u64,
    }

    fun init(ctx: &mut TxContext) {
        transfer::transfer( FeederCap {
            id: object::new(ctx),
        }, tx_context::sender(ctx));

        transfer::share_object( PriceFeed<SUI> {
            id: object::new(ctx),
            price: 200000000,
            denominator: 100000000,
        });
    }

    public fun get_price<T>(price_feed: &PriceFeed<T>): (u64, u64) {
        (price_feed.price, price_feed.denominator)
    }

    public entry fun update_price<T>(
        _: &FeederCap,
        price_feed: &mut PriceFeed<T>,
        new_price: u64,
    ) {
        price_feed.price = new_price;
    }

    #[test_only]
    public fun new_for_testing<T>(price: u64, denominator: u64, ctx: &mut TxContext): (PriceFeed<T>, FeederCap) {
        (PriceFeed<T> {id: object::new(ctx), price, denominator}, FeederCap {id: object::new(ctx) })
    }

    #[test_only]
    public fun destroy_for_testing<T>(oracle: PriceFeed<T>, feeder_cap: FeederCap) {
        let PriceFeed {id, price: _, denominator: _ } = oracle;
        object::delete(id);
        let FeederCap { id} = feeder_cap;
        object::delete(id);
    }
}