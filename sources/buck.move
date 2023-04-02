module bucket_protocol::buck {

    // Dependecies

    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, TreasuryCap};
    use sui::sui::SUI;
    use std::option::{Self, Option};

    use bucket_protocol::bottle::{Self, Bottle};
    use bucket_protocol::insertable_linked_table::{Self as ilt, LinkedTable};
    use bucket_protocol::mock_oracle::{PriceFeed, get_price};

    // Constant

    const MINIMAL_COLLATERAL_RATIO: u64 = 110; // 110%

    // Errors

    const ECollateralRatioTooLow: u64 = 0;

    const EBottleNotFound: u64 = 1;

    const ENotLiquidateable: u64 = 2;

    const ENotEnoughToRedeem: u64 = 3;

    const ERepayTooMuch: u64 = 4;

    // Types

    struct BUCK has drop {}

    struct Bucket has key {
        id: UID,
        sui_vault: Balance<SUI>,
        buck_treasury: TreasuryCap<BUCK>,
        bottle_table: LinkedTable<address, Bottle>,
    }

    // Init

    fun init(witness: BUCK, ctx: &mut TxContext) {
        let (buck_treasury, buck_metadata) = coin::create_currency(
            witness,
            8,
            b"BUCK",
            b"Bucket USD",
            b"stable coin minted by bucketprotocol.io",
            option::none(),
            ctx,
        );

        transfer::public_freeze_object(buck_metadata);
        transfer::share_object( Bucket {
            id: object::new(ctx),
            buck_treasury,
            sui_vault: balance::zero(),
            bottle_table: ilt::new(ctx),
        })
    }

    // Functions

    public fun borrow(
        bucket: &mut Bucket,
        oracle: &PriceFeed<SUI>,
        input_sui: Balance<SUI>,
        collateral_ratio: u64,
        prev_debtor: Option<address>,
        ctx: &TxContext,
    ): Balance<BUCK> {
        assert!(collateral_ratio > MINIMAL_COLLATERAL_RATIO, ECollateralRatioTooLow);
        let (price, denominator) = get_price(oracle);
        let sui_amount = balance::value(&input_sui);
        balance::join(&mut bucket.sui_vault, input_sui);

        let debtor = tx_context::sender(ctx);

        let minted_buck_amount = if (ilt::contains(&bucket.bottle_table, debtor)) {
            let bottle = ilt::remove(&mut bucket.bottle_table, debtor);
            let buck_amount = bottle::borrow_result(&mut bottle, price, denominator, collateral_ratio, sui_amount);
            bottle::insert_bottle(
                &mut bucket.bottle_table,
                debtor,
                bottle,
                prev_debtor
            );
            buck_amount
        } else {
            let buck_amount = sui_amount * price / denominator * 100 / collateral_ratio;
            bottle::insert_bottle(
                &mut bucket.bottle_table,
                debtor,
                bottle::new(sui_amount, buck_amount),
                prev_debtor,
            );
            buck_amount
        };

        coin::mint_balance(&mut bucket.buck_treasury, minted_buck_amount)
    }

    public fun repay(
        bucket: &mut Bucket,
        input_buck: Balance<BUCK>,
        ctx: &TxContext,
    ): Balance<SUI> {
        repay_internal(bucket, input_buck, tx_context::sender(ctx))
    }

    public fun redeem(
        bucket: &mut Bucket,
        oracle: &PriceFeed<SUI>,
        input_buck: Balance<BUCK>,
        ctx: &mut TxContext,
    ): Balance<SUI> {
        let (price, denominator) = get_price(oracle);
        let first_debtor = *ilt::front(&bucket.bottle_table);
        let output_sui = balance::zero<SUI>();
        redeem_internal(
            bucket,
            first_debtor,
            price,
            denominator,
            &mut input_buck,
            &mut output_sui,
            ctx,
        );
        balance::destroy_zero(input_buck);
        output_sui
    }

    public fun is_liquidateable(bucket: &Bucket, oracle: &PriceFeed<SUI>, debtor: address): bool {
        let (price, denominator) = get_price(oracle);
        assert!(ilt::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = ilt::borrow(&bucket.bottle_table, debtor);
        let bottle_sui_amount = bottle::get_sui_amount(bottle);
        let bottle_buck_amount= bottle::get_buck_amount(bottle);
        bottle_sui_amount * price / denominator <=
            bottle_buck_amount * MINIMAL_COLLATERAL_RATIO / 100
    }

    public fun liquidate(
        bucket: &mut Bucket,
        oracle: &PriceFeed<SUI>,
        input_buck: Balance<BUCK>,
        debtor: address,
    ): Balance<SUI> {
        assert!(is_liquidateable(bucket, oracle, debtor), ENotLiquidateable);
        repay_internal(bucket, input_buck, debtor)
    }

    public fun get_bottle_info(bucket: &Bucket, debtor: address): (u64, u64) {
        let bottle = ilt::borrow(&bucket.bottle_table, debtor);
        (bottle::get_sui_amount(bottle), bottle::get_buck_amount(bottle))
    }

    fun repay_internal(
        bucket: &mut Bucket,
        input_buck: Balance<BUCK>,
        debtor: address,
    ): Balance<SUI> {
        let repay_amount = balance::value(&input_buck);
        assert!(ilt::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = ilt::borrow_mut(&mut bucket.bottle_table, debtor);
        assert!(bottle::get_buck_amount(bottle) >= repay_amount, ERepayTooMuch);
        let (is_fully_repaid, return_sui_amount) = bottle::repay_result(bottle, repay_amount);
        balance::decrease_supply(coin::supply_mut(&mut bucket.buck_treasury), input_buck);
        if (is_fully_repaid) {
            bottle::destroy(ilt::remove(&mut bucket.bottle_table, debtor));
        };
        balance::split(&mut bucket.sui_vault, return_sui_amount)
    }

    fun redeem_internal(
        bucket: &mut Bucket,
        curr_debtor: Option<address>,
        price: u64,
        denominator: u64,
        input_buck: &mut Balance<BUCK>,
        output_sui: &mut Balance<SUI>,
        ctx: &mut TxContext,
    ) {
        assert!(option::is_some(&curr_debtor), ENotEnoughToRedeem);
        let curr_debtor = option::destroy_some(curr_debtor);
        let next_debtor = *ilt::next(&bucket.bottle_table, curr_debtor);

        let bottle = ilt::borrow_mut(&mut bucket.bottle_table, curr_debtor);
        let input_buck_amount = balance::value(input_buck);
        let (
            redeemed_buck_amount, redeemer_sui_amount, debtor_sui_amount, redemption_complete
        ) = bottle::redeem_result(bottle, price, denominator, input_buck_amount);

        // burn redeemed buck
        let redeemed_buck = balance::split(input_buck, redeemed_buck_amount);
        balance::decrease_supply(coin::supply_mut(&mut bucket.buck_treasury), redeemed_buck);

        // return debtor remain SUI
        let remain_sui = balance::split(&mut bucket.sui_vault, debtor_sui_amount);
        transfer::public_transfer(coin::from_balance(remain_sui, ctx), curr_debtor);

        // cumulate redeemer's SUI
        let redeemed_sui = balance::split(&mut bucket.sui_vault, redeemer_sui_amount);
        balance::join(output_sui, redeemed_sui);

        // if destroy bottle
        if (bottle::destroyable(bottle)) {
            bottle::destroy(ilt::remove(&mut bucket.bottle_table, curr_debtor));
        };

        // if not complete, keep recursive
        if (!redemption_complete) {
            redeem_internal(
                bucket,
                next_debtor,
                price,
                denominator,
                input_buck,
                output_sui,
                ctx,
            );
        };
    }
}
