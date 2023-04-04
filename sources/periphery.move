module bucket_protocol::periphery {

    // Dependecies

    use std::vector;
    use std::option::Option;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::sui::SUI;
    use sui::pay;
    use sui::balance;

    use bucket_protocol::buck::{Self, BUCK, BucketProtocol};
    use bucket_protocol::mock_oracle::PriceFeed;

    public entry fun borrow<T>(
        protocol: &mut BucketProtocol,
        oracle: &PriceFeed<SUI>,
        sui_coins: vector<Coin<SUI>>,
        sui_amount: u64,
        collateral_ratio: u64,
        prev_debtor: Option<address>,
        ctx: &mut TxContext
    ) {
        let sui_coin = vector::pop_back(&mut sui_coins);
        pay::join_vec(&mut sui_coin, sui_coins);
        let sui_input = balance::split(coin::balance_mut(&mut sui_coin), sui_amount);

        let borrower = tx_context::sender(ctx);
        let buck = buck::borrow(protocol, oracle, sui_input, collateral_ratio, prev_debtor, ctx);
        transfer::public_transfer(coin::from_balance(buck, ctx), borrower);
        transfer::public_transfer(sui_coin, borrower);
    }

    public entry fun repay<T>(
        protocol: &mut BucketProtocol,
        buck_coins: vector<Coin<BUCK>>,
        buck_amount: u64,
        ctx: &mut TxContext,
    ) {
        let buck_coin = vector::pop_back(&mut buck_coins);
        pay::join_vec(&mut buck_coin, buck_coins);

        let debtor = tx_context::sender(ctx);

        let (_, bottle_buck_amount) = buck::get_bottle_info<T>(protocol, debtor);
        if (buck_amount > bottle_buck_amount) buck_amount = bottle_buck_amount;
        let buck_input = balance::split(coin::balance_mut(&mut buck_coin), buck_amount);

        let sui_output = buck::repay<T>(protocol, buck_input, ctx);
        transfer::public_transfer(coin::from_balance(sui_output, ctx), debtor);
        transfer::public_transfer(buck_coin, debtor);
    }

    public entry fun auto_insert_borrow(
        protocol: &mut BucketProtocol,
        oracle: &PriceFeed<SUI>,
        sui_coins: vector<Coin<SUI>>,
        sui_amount: u64,
        collateral_ratio: u64,
        ctx: &mut TxContext,
    ) {
        let sui_coin = vector::pop_back(&mut sui_coins);
        pay::join_vec(&mut sui_coin, sui_coins);
        let sui_input = balance::split(coin::balance_mut(&mut sui_coin), sui_amount);

        let borrower = tx_context::sender(ctx);

        let buck = buck::auto_insert_borrow(
            protocol, oracle, sui_input, collateral_ratio, ctx
        );
        transfer::public_transfer(coin::from_balance(buck, ctx), borrower);
        transfer::public_transfer(sui_coin, borrower);
    }

    #[test_only]
    use bucket_protocol::well::{Well};

    #[test]
    fun test_auto_insert_borrow(): (BucketProtocol, Well<SUI>) {
        use sui::test_scenario;
        use sui::test_utils;
        use bucket_protocol::mock_oracle;
        use std::debug;

        let dev = @0xde1;
        let borrower = @0x111;

        let scenario_val = test_scenario::begin(dev);
        let scenario = &mut scenario_val;

        let (protocol, well) = buck::new_for_testing(test_utils::create_one_time_witness<BUCK>(), test_scenario::ctx(scenario));
        let (oracle, ocap) = mock_oracle::new_for_testing<SUI>(2000, 1000, test_scenario::ctx(scenario));

        test_scenario::next_tx(scenario, borrower);
        {
            let sui_input = balance::create_for_testing<SUI>(2000000);
            let sui_input = vector[coin::from_balance(sui_input, test_scenario::ctx(scenario))];
            auto_insert_borrow(&mut protocol, &oracle, sui_input, 1000000, 125, test_scenario::ctx(scenario));
            debug::print(&test_scenario::ids_for_sender<Coin<SUI>>(scenario));
        };

        test_scenario::next_tx(scenario, borrower);
        {
            let sui_output = test_scenario::take_from_sender<Coin<SUI>>(scenario);
            let buck_output = test_scenario::take_from_sender<Coin<BUCK>>(scenario);
            debug::print(&sui_output);
            debug::print(&buck_output);
            test_scenario::return_to_sender(scenario, sui_output);
            test_scenario::return_to_sender(scenario, buck_output);
        };

        mock_oracle::destroy_for_testing(oracle, ocap);
        test_scenario::end(scenario_val);
        (protocol, well)
    }
}
