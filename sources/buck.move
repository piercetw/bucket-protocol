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
    use bucket_protocol::insertable_linked_table::{Self as table, LinkedTable};
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
            bottle_table: table::new(ctx),
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

        let minted_buck_amount = if (table::contains(&bucket.bottle_table, debtor)) {
            let bottle = table::remove(&mut bucket.bottle_table, debtor);
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
        let first_debtor = *table::front(&bucket.bottle_table);
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
        assert!(table::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = table::borrow(&bucket.bottle_table, debtor);
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
        let bottle = table::borrow(&bucket.bottle_table, debtor);
        (bottle::get_sui_amount(bottle), bottle::get_buck_amount(bottle))
    }

    public fun get_total_nominal_collateral_ratio(bucket: &Bucket): (u64, u64) {
        (
            balance::value(&bucket.sui_vault),
            coin::total_supply(&bucket.buck_treasury),
        )
    }

    fun repay_internal(
        bucket: &mut Bucket,
        input_buck: Balance<BUCK>,
        debtor: address,
    ): Balance<SUI> {
        let repay_amount = balance::value(&input_buck);
        assert!(table::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = table::borrow_mut(&mut bucket.bottle_table, debtor);
        assert!(bottle::get_buck_amount(bottle) >= repay_amount, ERepayTooMuch);
        let (is_fully_repaid, return_sui_amount) = bottle::repay_result(bottle, repay_amount);
        balance::decrease_supply(coin::supply_mut(&mut bucket.buck_treasury), input_buck);
        if (is_fully_repaid) {
            bottle::destroy(table::remove(&mut bucket.bottle_table, debtor));
        };
        balance::split(&mut bucket.sui_vault, return_sui_amount)
    }

    fun redeem_internal(
        bucket: &mut Bucket,
        debtor_opt: Option<address>,
        price: u64,
        denominator: u64,
        input_buck: &mut Balance<BUCK>,
        output_sui: &mut Balance<SUI>,
        ctx: &mut TxContext,
    ) {
        assert!(option::is_some(&debtor_opt), ENotEnoughToRedeem);
        let debtor_opt = option::destroy_some(debtor_opt);
        let next_debtor = *table::next(&bucket.bottle_table, debtor_opt);

        let bottle = table::borrow_mut(&mut bucket.bottle_table, debtor_opt);
        let input_buck_amount = balance::value(input_buck);
        let (
            redeemed_buck_amount, redeemer_sui_amount, debtor_sui_amount, redemption_complete
        ) = bottle::redeem_result(bottle, price, denominator, input_buck_amount);

        // burn redeemed buck
        let redeemed_buck = balance::split(input_buck, redeemed_buck_amount);
        balance::decrease_supply(coin::supply_mut(&mut bucket.buck_treasury), redeemed_buck);

        // return debtor remain SUI
        let remain_sui = balance::split(&mut bucket.sui_vault, debtor_sui_amount);
        transfer::public_transfer(coin::from_balance(remain_sui, ctx), debtor_opt);

        // cumulate redeemer's SUI
        let redeemed_sui = balance::split(&mut bucket.sui_vault, redeemer_sui_amount);
        balance::join(output_sui, redeemed_sui);

        // if destroy bottle
        if (bottle::destroyable(bottle)) {
            bottle::destroy(table::remove(&mut bucket.bottle_table, debtor_opt));
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

    // for testing or when small size of bottle table, O(n) time complexity
    public fun auto_insert_borrow(
        bucket: &mut Bucket,
        oracle: &PriceFeed<SUI>,
        input_sui: Balance<SUI>,
        collateral_ratio: u64,
        ctx: &TxContext,
    ): Balance<BUCK> {
        assert!(collateral_ratio > MINIMAL_COLLATERAL_RATIO, ECollateralRatioTooLow);
        let debtor = tx_context::sender(ctx);
        // TODO: custom error
        assert!(!table::contains(&bucket.bottle_table, debtor), 500);

        let (price, denominator) = get_price(oracle);
        let sui_amount = balance::value(&input_sui);
        balance::join(&mut bucket.sui_vault, input_sui);

        let buck_amount = sui_amount * price / denominator * 100 / collateral_ratio;
        let (prev_debtor, bottle) = find_valid_insertion(bucket, sui_amount, buck_amount);

        std::debug::print(&prev_debtor);

        bottle::insert_bottle(
            &mut bucket.bottle_table,
            debtor,
            bottle,
            prev_debtor
        );

        balance::increase_supply(coin::supply_mut(&mut bucket.buck_treasury), buck_amount)
    }

    // TODO: use more efficient algorithm
    fun find_valid_insertion(
        bucket: &Bucket,
        sui_amount: u64,
        buck_amount: u64,
    ): (Option<address>, Bottle) {
        let bottle = bottle::new(sui_amount, buck_amount);
        let bottle_table = &bucket.bottle_table;
        let curr_debtor_opt = *table::front(&bucket.bottle_table);

        while (option::is_some(&curr_debtor_opt)) {
            let curr_debtor = *option::borrow(&curr_debtor_opt);
            let curr_bottle = table::borrow(bottle_table, curr_debtor);
            if (bottle::cr_less_or_equal(&bottle, curr_bottle)) {
                return (option::none(), bottle)
            };
            let next_debtor_opt = table::next(bottle_table, curr_debtor);
            if (option::is_none(next_debtor_opt)) break;
            let next_debtor = *option::borrow(next_debtor_opt);
            let next_bottle = table::borrow(bottle_table, next_debtor);
            if (bottle::cr_greater(&bottle, curr_bottle) &&
                bottle::cr_less_or_equal(&bottle, next_bottle)
            ) {
                break
            };
            curr_debtor_opt = *next_debtor_opt;
        };
        (curr_debtor_opt, bottle)
    }

    #[test_only]
    public fun new_for_testing(witness: BUCK, ctx: &mut TxContext): Bucket {
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
        Bucket {
            id: object::new(ctx),
            buck_treasury,
            sui_vault: balance::zero(),
            bottle_table: table::new(ctx),
        }
    }

    #[test]
    fun test_borrow() {
        use sui::test_scenario;
        use sui::test_utils;
        use bucket_protocol::mock_oracle;
        use std::debug;

        let dev = @0xde1;
        let borrower_1 = @0x111;
        let borrower_2 = @0x222;
        let borrower_3 = @0x333;
        let borrower_4 = @0x444;

        let scenario_val = test_scenario::begin(dev);
        let scenario = &mut scenario_val;
        {
            init(test_utils::create_one_time_witness<BUCK>(), test_scenario::ctx(scenario));
        };

        let (oracle, ocap) = mock_oracle::new_for_testing<SUI>(2000, 1000, test_scenario::ctx(scenario));

        test_scenario::next_tx(scenario, borrower_1);
        {
            let bucket = test_scenario::take_shared<Bucket>(scenario);

            let input_sui = balance::create_for_testing<SUI>(1000000);
            let buck_output = auto_insert_borrow(&mut bucket, &oracle, input_sui, 125, test_scenario::ctx(scenario));
            debug::print(&buck_output);
            debug::print(&bucket.bottle_table);
            test_utils::assert_eq(balance::value(&buck_output), 1000000*2/125*100);
            test_utils::assert_eq(table::length(&bucket.bottle_table), 1);
            balance::destroy_for_testing(buck_output);

            test_scenario::return_shared(bucket);
        };

        test_scenario::next_tx(scenario, borrower_2);
        {
            let bucket = test_scenario::take_shared<Bucket>(scenario);
            mock_oracle::update_price(&ocap, &mut oracle, 3000);

            let input_sui = balance::create_for_testing<SUI>(2000);
            let buck_output = auto_insert_borrow(&mut bucket, &oracle, input_sui, 150, test_scenario::ctx(scenario));
            debug::print(&buck_output);
            test_utils::assert_eq(balance::value(&buck_output), 2000*100*3/150);
            test_utils::assert_eq(table::length(&bucket.bottle_table), 2);
            balance::destroy_for_testing(buck_output);

            debug::print(&bucket);
            let (sui_total, buck_total) = get_total_nominal_collateral_ratio(&bucket);
            test_utils::assert_eq(sui_total, 1002000);
            test_utils::assert_eq(buck_total, 1604000);

            test_scenario::return_shared(bucket);
        };

        test_scenario::next_tx(scenario, borrower_3);
        {
            let bucket = test_scenario::take_shared<Bucket>(scenario);
            mock_oracle::update_price(&ocap, &mut oracle, 2500);

            let input_sui = balance::create_for_testing<SUI>(30000);
            let buck_output = auto_insert_borrow(&mut bucket, &oracle, input_sui, 1000, test_scenario::ctx(scenario));
            debug::print(&buck_output);
            // bottle::print_bottle_table(&bucket.bottle_table);

            balance::destroy_for_testing(buck_output);
            test_scenario::return_shared(bucket);
        };

        test_scenario::next_tx(scenario, borrower_4);
        {
            let bucket = test_scenario::take_shared<Bucket>(scenario);
            mock_oracle::update_price(&ocap, &mut oracle, 1600);

            let input_sui = balance::create_for_testing<SUI>(700000);
            let buck_output = auto_insert_borrow(&mut bucket, &oracle, input_sui, 200, test_scenario::ctx(scenario));
            debug::print(&buck_output);
            bottle::print_bottle_table(&bucket.bottle_table);

            balance::destroy_for_testing(buck_output);
            test_scenario::return_shared(bucket);
        };

        mock_oracle::destroy_for_testing(oracle, ocap);
        test_scenario::end(scenario_val);
    }
}


