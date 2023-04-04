module bucket_protocol::buck {

    // Dependecies

    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, TreasuryCap};
    use sui::sui::SUI;
    use sui::dynamic_object_field as dof;
    use std::option::{Self, Option};

    use bucket_protocol::bottle::{Self, Bottle};
    use bucket_protocol::linked_table::{Self, LinkedTable};
    use bucket_protocol::mock_oracle::{PriceFeed, get_price};
    use bucket_protocol::well::{Self, Well};

    // Constant

    const FLASH_LOAN_DIVISOR: u64 = 10000; // 0.01% fee

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

    struct BucketType<phantom T> has copy, drop, store {}

    struct Bucket<phantom T> has key, store {
        id: UID,
        vault: Balance<T>,
        minimal_collateral_ratio: u64,
        bottle_table: LinkedTable<address, Bottle>,
    }

    struct BucketProtocol has key {
        id: UID,
        buck_treasury: TreasuryCap<BUCK>,
    }

    struct FlashLoanRecipit<phantom T> {
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
        let id = object::new(ctx);
        // first list SUI bucket for sure
        dof::add(&mut id, BucketType<SUI> {}, Bucket<SUI> {
            id: object::new(ctx),
            vault: balance::zero(),
            minimal_collateral_ratio: 120,
            bottle_table: linked_table::new(ctx)
        });
        transfer::share_object( BucketProtocol {
            id,
            buck_treasury,
        });
        well::create<SUI>(ctx);
    }

    // Functions

    public fun borrow<T>(
        protocol: &mut BucketProtocol,
        oracle: &PriceFeed<T>,
        collateral_input: Balance<T>,
        collateral_ratio: u64,
        prev_debtor: Option<address>,
        ctx: &TxContext,
    ): Balance<BUCK> {
        let bucket = get_bucket_mut<T>(protocol);
        let minimal_collateral_ratio = bucket.minimal_collateral_ratio;
        assert!(collateral_ratio > minimal_collateral_ratio, ECollateralRatioTooLow);

        let (price, denominator) = get_price(oracle);
        let collateral_amount = balance::value(&collateral_input);
        balance::join(&mut bucket.vault, collateral_input);

        let debtor = tx_context::sender(ctx);

        let minted_buck_amount = if (linked_table::contains(&bucket.bottle_table, debtor)) {
            let bottle = linked_table::remove(&mut bucket.bottle_table, debtor);
            let buck_amount = bottle::borrow_result(&mut bottle, price, denominator, collateral_ratio, collateral_amount);
            bottle::insert_bottle(
                &mut bucket.bottle_table,
                debtor,
                bottle,
                prev_debtor
            );
            buck_amount
        } else {
            let buck_amount = collateral_amount * price * 100 / denominator / collateral_ratio;
            bottle::insert_bottle(
                &mut bucket.bottle_table,
                debtor,
                bottle::new(collateral_amount, buck_amount),
                prev_debtor,
            );
            buck_amount
        };

        coin::mint_balance(&mut protocol.buck_treasury, minted_buck_amount)
    }

    public fun repay<T>(
        protocol: &mut BucketProtocol,
        repayment: Balance<BUCK>,
        ctx: &TxContext,
    ): Balance<T> {
        let repayment_amount = balance::value(&repayment);
        balance::decrease_supply(coin::supply_mut(&mut protocol.buck_treasury), repayment);
        let bucket = get_bucket_mut<T>(protocol);
        repay_internal<T>(bucket, repayment_amount, tx_context::sender(ctx))
    }

    public fun redeem<T>(
        protocol: &mut BucketProtocol,
        oracle: &PriceFeed<T>,
        input_buck: Balance<BUCK>,
        ctx: &mut TxContext,
    ): Balance<T> {
        let bucket = get_bucket_mut<T>(protocol);
        let (price, denominator) = get_price(oracle);
        let first_debtor = *linked_table::front(&bucket.bottle_table);
        let output_asset = balance::zero<T>();
        redeem_internal<T>(
            protocol,
            first_debtor,
            price,
            denominator,
            &mut input_buck,
            &mut output_asset,
            ctx,
        );
        balance::destroy_zero(input_buck);
        output_asset
    }

    public fun is_liquidateable<T>(
        protocol: &BucketProtocol,
        oracle: &PriceFeed<T>,
        debtor: address
    ): bool {
        let bucket = get_bucket<T>(protocol);
        let (price, denominator) = get_price(oracle);
        assert!(linked_table::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = linked_table::borrow(&bucket.bottle_table, debtor);
        let bottle_asset_amount = bottle::get_collateral_amount(bottle);
        let bottle_buck_amount= bottle::get_buck_amount(bottle);
        bottle_asset_amount * price / denominator <=
            bottle_buck_amount * bucket.minimal_collateral_ratio / 100
    }

    public fun liquidate<T>(
        protocol: &mut BucketProtocol,
        oracle: &PriceFeed<T>,
        repayment: Balance<BUCK>,
        debtor: address,
    ): Balance<T> {
        assert!(is_liquidateable(protocol, oracle, debtor), ENotLiquidateable);
        let repayment_amount = balance::value(&repayment);
        balance::decrease_supply(coin::supply_mut(&mut protocol.buck_treasury), repayment);
        let bucket = get_bucket_mut<T>(protocol);
        repay_internal(bucket, repayment_amount, debtor)
    }

    public fun get_bottle_info<T>(protocol: &BucketProtocol, debtor: address): (u64, u64) {
        let bucket = get_bucket<T>(protocol);
        let bottle = linked_table::borrow(&bucket.bottle_table, debtor);
        (bottle::get_collateral_amount(bottle), bottle::get_buck_amount(bottle))
    }

    public fun get_total_nominal_collateral_ratio<T>(protocol: &BucketProtocol): (u64, u64) {
        let bucket = get_bucket<T>(protocol);
        (balance::value(&bucket.vault),
            coin::total_supply(&protocol.buck_treasury))
    }

    public fun flash_borrow<T>(protocol: &mut BucketProtocol, amount: u64): (Balance<T>, FlashLoanRecipit<T>) {
        let bucket = get_bucket_mut<T>(protocol);
        let fee = amount / FLASH_LOAN_DIVISOR;
        if (fee == 0) fee = 1;
        (balance::split(&mut bucket.vault, amount),
            FlashLoanRecipit { amount, fee })
    }

    public fun flash_repay<T>(
        protocol: &mut BucketProtocol,
        well: &mut Well<T>,
        repayment: Balance<T>,
        recipit: FlashLoanRecipit<T>
    ) {
        let bucket = get_bucket_mut<T>(protocol);
        let FlashLoanRecipit {amount, fee} = recipit;
        assert!(balance::value(&repayment) == amount + fee, EFlashLoanError);
        let fee = balance::split(&mut repayment, fee);
        balance::join(&mut bucket.vault, repayment);
        well::collect_fee(well, fee);
    }

    fun repay_internal<T>(
        bucket: &mut Bucket<T>,
        repayment_amount: u64,
        debtor: address,
    ): Balance<T> {
        assert!(linked_table::contains(&bucket.bottle_table, debtor), EBottleNotFound);
        let bottle = linked_table::borrow_mut(&mut bucket.bottle_table, debtor);
        assert!(bottle::get_buck_amount(bottle) >= repayment_amount, ERepayTooMuch);
        let (is_fully_repaid, return_amount) = bottle::repay_result(bottle, repayment_amount);
        if (is_fully_repaid) {
            bottle::destroy(linked_table::remove(&mut bucket.bottle_table, debtor));
        };
        balance::split(&mut bucket.vault, return_amount)
    }

    fun redeem_internal<T>(
        protocol: &mut BucketProtocol,
        debtor_opt: Option<address>,
        price: u64,
        denominator: u64,
        input_buck: &mut Balance<BUCK>,
        output_asset: &mut Balance<T>,
        ctx: &mut TxContext,
    ) {
        assert!(option::is_some(&debtor_opt), ENotEnoughToRedeem);
        let bucket = get_bucket_mut<T>(protocol);
        let debtor_opt = option::destroy_some(debtor_opt);
        let next_debtor = *linked_table::next(&bucket.bottle_table, debtor_opt);

        let bottle = linked_table::borrow_mut(&mut bucket.bottle_table, debtor_opt);
        let input_buck_amount = balance::value(input_buck);
        let (
            redeemed_buck_amount, redeemer_amount, debtor_amount, redemption_complete
        ) = bottle::redeem_result(bottle, price, denominator, input_buck_amount);

        // return debtor remain collateral
        let remain_collateral = balance::split(&mut bucket.vault, debtor_amount);
        transfer::public_transfer(coin::from_balance(remain_collateral, ctx), debtor_opt);

        // cumulate redeemer's collateral
        let redeemed_collateral = balance::split(&mut bucket.vault, redeemer_amount);
        balance::join(output_asset, redeemed_collateral);

        // if destroy bottle
        if (bottle::destroyable(bottle)) {
            bottle::destroy(linked_table::remove(&mut bucket.bottle_table, debtor_opt));
        };

        // burn redeemed buck
        let redeemed_buck = balance::split(input_buck, redeemed_buck_amount);
        balance::decrease_supply(coin::supply_mut(&mut protocol.buck_treasury), redeemed_buck);

        // if not complete, keep recursive
        if (!redemption_complete) {
            redeem_internal(
                protocol,
                next_debtor,
                price,
                denominator,
                input_buck,
                output_asset,
                ctx,
            );
        };
    }

    // for testing or when small size of bottle table, O(n) time complexity
    public fun auto_insert_borrow<T>(
        protocol: &mut BucketProtocol,
        oracle: &PriceFeed<T>,
        collateral_input: Balance<T>,
        collateral_ratio: u64,
        ctx: &TxContext,
    ): Balance<BUCK> {
        let bucket = get_bucket_mut<T>(protocol);
        assert!(collateral_ratio > (bucket.minimal_collateral_ratio as u64), ECollateralRatioTooLow);
        let debtor = tx_context::sender(ctx);
        assert!(!linked_table::contains(&bucket.bottle_table, debtor), EBottleAlreadyExists);

        let (price, denominator) = get_price(oracle);
        let collateral_amount = balance::value(&collateral_input);
        balance::join(&mut bucket.vault, collateral_input);

        let buck_amount = collateral_amount * price * 100 / denominator / collateral_ratio;
        let (prev_debtor, bottle) = find_valid_insertion(bucket, collateral_amount, buck_amount);

        std::debug::print(&prev_debtor);

        bottle::insert_bottle(
            &mut bucket.bottle_table,
            debtor,
            bottle,
            prev_debtor
        );

        balance::increase_supply(coin::supply_mut(&mut protocol.buck_treasury), buck_amount)
    }

    fun find_valid_insertion<T>(
        bucket: &Bucket<T>,
        collateral_amount: u64,
        buck_amount: u64,
    ): (Option<address>, Bottle) {
        let bottle = bottle::new(collateral_amount, buck_amount);
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

    fun get_bucket<T>(protocol: &BucketProtocol): &Bucket<T> {
        dof::borrow<BucketType<T>, Bucket<T>>(&protocol.id, BucketType<T> {})
    }

    fun get_bucket_mut<T>(protocol: &mut BucketProtocol): &mut Bucket<T> {
        dof::borrow_mut<BucketType<T>, Bucket<T>>(&mut protocol.id, BucketType<T> {})
    }

    #[test_only]
    public fun new_for_testing<T>(witness: BUCK, ctx: &mut TxContext): (BucketProtocol, Well<T>) {
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
        let id = object::new(ctx);
        dof::add(&mut id, BucketType<SUI> {}, Bucket<SUI> {
            id: object::new(ctx),
            vault: balance::zero(),
            minimal_collateral_ratio: 120,
            bottle_table: linked_table::new(ctx)
        });
        (BucketProtocol { id, buck_treasury }, well::new(ctx))
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
        let borrower_count = 10;
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

        let seed = b"bucket protocol";
        vector::push_back(&mut seed, borrower_count);
        let rang = test_random::new(seed);
        let rangr = &mut rang;
        idx = 0;
        while (idx < borrower_count) {
            let borrower = *vector::borrow(&borrowers, (idx as u64));
            test_scenario::next_tx(scenario, borrower);
            {
                let protocol = test_scenario::take_shared<BucketProtocol>(scenario);

                let oracle_price = 500 + test_random::next_u64(rangr) % 2000;
                mock_oracle::update_price(&ocap, &mut oracle, oracle_price);

                let input_sui_amount = 1000000 * (test_random::next_u8(rangr) as u64) + test_random::next_u64(rangr) % 100000000;
                let input_sui = balance::create_for_testing<SUI>(input_sui_amount);

                let collateral_ratio = 110 + test_random::next_u64(rangr) % 2000;

                let buck_output = auto_insert_borrow(
                    &mut protocol,
                    &oracle,
                    input_sui,
                    collateral_ratio,
                    test_scenario::ctx(scenario)
                );
                bottle::print_bottle(linked_table::borrow(&get_bucket<SUI>(&protocol).bottle_table, borrower));
                let expected_buck_amount = input_sui_amount * oracle_price * 100 / 1000 / collateral_ratio;
                test_utils::assert_eq(balance::value(&buck_output), expected_buck_amount);
                test_utils::assert_eq(linked_table::length(&get_bucket<SUI>(&protocol).bottle_table), (idx as u64) + 1);
                balance::destroy_for_testing(buck_output);

                test_scenario::return_shared(protocol);
            };
            idx = idx + 1;
        };

        test_scenario::next_tx(scenario, dev);
        {
            let protocol = test_scenario::take_shared<BucketProtocol>(scenario);
            test_utils::print(b"---------- Bottle Table Result ----------");
            bottle::print_bottle_table(&get_bucket<SUI>(&protocol).bottle_table);
            test_scenario::return_shared(protocol);
        };

        mock_oracle::destroy_for_testing(oracle, ocap);
        test_scenario::end(scenario_val);
    }
}


