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
    use bucket_protocol::linked_table::{Self, LinkedTable};
    use bucket_protocol::mock_oracle::{PriceFeed, get_price};
    use bucket_protocol::well::{Self, Well};

    // Constant

    const MINIMAL_COLLATERAL_RATIO: u64 = 115; // 115%
    const FLASH_LOAN_FEE: u64 = 5; // 0.5%

    // Errors

    const ECollateralRatioTooLow: u64 = 0;
    const EBottleNotFound: u64 = 1;
    const ENotLiquidateable: u64 = 2;
    const ENotEnoughToRedeem: u64 = 3;
    const ERepayTooMuch: u64 = 4;
    const EFlashLoanError: u64 = 5;
    const EBottleAlreadyExists: u64 = 6;

    // Types

    struct BUCK has drop {}

    struct Bucket has key {
        id: UID,
        sui_vault: Balance<SUI>,
        buck_treasury: TreasuryCap<BUCK>,
        bottle_table: LinkedTable<address, Bottle>,
    }

    struct FlashLoanRecipit {
        amount: u64,
        fee: u64,
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
            bottle_table: linked_table::new(ctx),
        });
        well::create<BUCK>(ctx);
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

        let minted_buck_amount = if (linked_table::contains(&bucket.bottle_table, debtor)) {
            let bottle = linked_table::remove(&mut bucket.bottle_table, debtor);
            let buck_amount = bottle::borrow_result(&mut bottle, price, denominator, collateral_ratio, sui_amount);
            bottle::insert_bottle(
                &mut bucket.bottle_table,
                debtor,
                bottle,
                prev_debtor
            );
            buck_amount
        } else {
            let buck_amount = sui_amount * price * 100 / denominator / collateral_ratio;
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
        let first_debtor = *linked_table::front(&bucket.bottle_table);
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
        assert!(linked_table::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = linked_table::borrow(&bucket.bottle_table, debtor);
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
        let bottle = linked_table::borrow(&bucket.bottle_table, debtor);
        (bottle::get_sui_amount(bottle), bottle::get_buck_amount(bottle))
    }

    public fun get_total_nominal_collateral_ratio(bucket: &Bucket): (u64, u64) {
        (
            balance::value(&bucket.sui_vault),
            coin::total_supply(&bucket.buck_treasury),
        )
    }

    public fun flash_borrow(bucket: &mut Bucket, amount: u64): (Balance<SUI>, FlashLoanRecipit) {
        (
            balance::split(&mut bucket.sui_vault, amount),
            FlashLoanRecipit { amount, fee: amount * FLASH_LOAN_FEE / 1000 },
        )
    }

    public fun flash_repay(
        bucket: &mut Bucket,
        well: &mut Well<BUCK>,
        repaid_sui: Balance<SUI>,
        recipit: FlashLoanRecipit
    ) {
        let FlashLoanRecipit {amount, fee} = recipit;
        assert!(balance::value(&repaid_sui) == amount + fee, EFlashLoanError);
        let sui_to_bucket = balance::split(&mut repaid_sui, amount);
        balance::join(&mut bucket.sui_vault, sui_to_bucket);
        well::collect_sui(well,  repaid_sui);
    }

    fun repay_internal(
        bucket: &mut Bucket,
        input_buck: Balance<BUCK>,
        debtor: address,
    ): Balance<SUI> {
        let repay_amount = balance::value(&input_buck);
        assert!(linked_table::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = linked_table::borrow_mut(&mut bucket.bottle_table, debtor);
        assert!(bottle::get_buck_amount(bottle) >= repay_amount, ERepayTooMuch);
        let (is_fully_repaid, return_sui_amount) = bottle::repay_result(bottle, repay_amount);
        balance::decrease_supply(coin::supply_mut(&mut bucket.buck_treasury), input_buck);
        if (is_fully_repaid) {
            bottle::destroy(linked_table::remove(&mut bucket.bottle_table, debtor));
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
        let next_debtor = *linked_table::next(&bucket.bottle_table, debtor_opt);

        let bottle = linked_table::borrow_mut(&mut bucket.bottle_table, debtor_opt);
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
            bottle::destroy(linked_table::remove(&mut bucket.bottle_table, debtor_opt));
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
        assert!(!linked_table::contains(&bucket.bottle_table, debtor), EBottleAlreadyExists);

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

    fun find_valid_insertion(
        bucket: &Bucket,
        sui_amount: u64,
        buck_amount: u64,
    ): (Option<address>, Bottle) {
        let bottle = bottle::new(sui_amount, buck_amount);
        let bottle_table = &bucket.bottle_table;
        let curr_debtor_opt = *linked_table::front(&bucket.bottle_table);

        while (option::is_some(&curr_debtor_opt)) {
            let curr_debtor = *option::borrow(&curr_debtor_opt);
            let curr_bottle = linked_table::borrow(bottle_table, curr_debtor);
            if (bottle::cr_less_or_equal(&bottle, curr_bottle)) {
                return (option::none(), bottle)
            };
            let next_debtor_opt = linked_table::next(bottle_table, curr_debtor);
            if (option::is_none(next_debtor_opt)) break;
            let next_debtor = *option::borrow(next_debtor_opt);
            let next_bottle = linked_table::borrow(bottle_table, next_debtor);
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
            bottle_table: linked_table::new(ctx),
        }
    }

    #[test]
    fun test_borrow() {
        use sui::test_scenario;
        use sui::test_utils;
        use sui::test_random;
        use sui::address;
        use std::vector;
        use bucket_protocol::mock_oracle;

        let dev = @0xde1;
        let borrowers = vector<address>[];
        let borrower_count = 4;
        let idx = 1u8;
        while (idx <= borrower_count) {
            vector::push_back(&mut borrowers, address::from_u256((idx as u256) + 10));
            idx = idx + 1;
        };

        let scenario_val = test_scenario::begin(dev);
        let scenario = &mut scenario_val;
        {
            init(test_utils::create_one_time_witness<BUCK>(), test_scenario::ctx(scenario));
        };

        let (oracle, ocap) = mock_oracle::new_for_testing<SUI>(1000, 1000, test_scenario::ctx(scenario));

        let rang = test_random::new(b"bucket protocol");
        let rangr = &mut rang;
        idx = 0;
        while (idx < borrower_count) {
            let borrower = *vector::borrow(&borrowers, (idx as u64));
            test_scenario::next_tx(scenario, borrower);
            {
                let bucket = test_scenario::take_shared<Bucket>(scenario);

                let oracle_price = 500 + test_random::next_u64(rangr) % 2000;
                mock_oracle::update_price(&ocap, &mut oracle, oracle_price);

                let input_sui_amount = 1000000 * (test_random::next_u8(rangr) as u64) + test_random::next_u64(rangr) % 100000000;
                let input_sui = balance::create_for_testing<SUI>(input_sui_amount);

                let collateral_ratio = 110 + test_random::next_u64(rangr) % 2000;

                let buck_output = auto_insert_borrow(
                    &mut bucket,
                    &oracle,
                    input_sui,
                    collateral_ratio,
                    test_scenario::ctx(scenario)
                );
                bottle::print_bottle(linked_table::borrow(&bucket.bottle_table, borrower));
                let expected_buck_amount = input_sui_amount * oracle_price * 100 / 1000 / collateral_ratio;
                test_utils::assert_eq(balance::value(&buck_output), expected_buck_amount);
                test_utils::assert_eq(linked_table::length(&bucket.bottle_table), (idx as u64) + 1);
                balance::destroy_for_testing(buck_output);

                test_scenario::return_shared(bucket);
            };
            idx = idx + 1;
        };

        test_scenario::next_tx(scenario, dev);
        {
            let bucket = test_scenario::take_shared<Bucket>(scenario);
            bottle::print_bottle_table(&bucket.bottle_table);
            test_scenario::return_shared(bucket);
        };

        mock_oracle::destroy_for_testing(oracle, ocap);
        test_scenario::end(scenario_val);
    }
}


