module bucket_protocol::periphery {

    // Dependecies
    use std::vector;
    use std::option::Option;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::sui::SUI;
    use sui::pay;

    use bucket_protocol::buck::{Self, BUCK, Bucket};
    use bucket_protocol::mock_oracle::PriceFeed;
    use sui::balance;

    public entry fun borrow(
        bucket: &mut Bucket,
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

        let sender = tx_context::sender(ctx);
        let buck = buck::borrow(bucket, oracle, sui_input, collateral_ratio, prev_debtor, ctx);
        transfer::public_transfer(coin::from_balance(buck, ctx), sender);
        transfer::public_transfer(sui_coin, sender);
    }

    public entry fun repay(
        bucket: &mut Bucket,
        buck_coins: vector<Coin<BUCK>>,
        buck_amount: u64,
        ctx: &mut TxContext,
    ) {
        let buck_coin = vector::pop_back(&mut buck_coins);
        pay::join_vec(&mut buck_coin, buck_coins);

        let sender = tx_context::sender(ctx);

        let (_, bottle_buck_amount) = buck::get_bottle_info(bucket, sender);
        if (buck_amount > bottle_buck_amount) buck_amount = bottle_buck_amount;
        let buck_input = balance::split(coin::balance_mut(&mut buck_coin), buck_amount);

        let sui_output = buck::repay(bucket, buck_input, ctx);
        transfer::public_transfer(coin::from_balance(sui_output, ctx), sender);
        transfer::public_transfer(buck_coin, sender);
    }
}
