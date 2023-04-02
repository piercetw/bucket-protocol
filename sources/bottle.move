module bucket_protocol::bottle {

    use std::option::{Self, Option};
    use bucket_protocol::insertable_linked_table::{Self as ilt, LinkedTable};

    friend bucket_protocol::buck;

    const EUnsortedInsertion: u64 = 0;

    const ECannotReachCollateralRatio: u64 = 1;

    const ECannotRedeemFromBottle: u64 = 2;

    const EDestroyNonEmptyBottle: u64 = 3;


    struct Bottle has store {
        sui_amount: u64,
        buck_amount: u64,
    }

    public(friend) fun new(sui_amount: u64, buck_amount: u64): Bottle {
        Bottle { sui_amount, buck_amount}
    }

    public(friend) fun insert_bottle(
        bottle_table: &mut LinkedTable<address, Bottle>,
        debtor: address,
        bottle: Bottle,
        prev_debtor: Option<address>,
    ) {
        if (option::is_some(&prev_debtor)) {
            let prev_debtor = option::destroy_some(prev_debtor);
            let prev_bottle = ilt::borrow(bottle_table, prev_debtor);
            let next_debtor = *ilt::next(bottle_table, prev_debtor);
            if (option::is_some(&next_debtor)) {
                let next_debtor = option::destroy_some(next_debtor);
                let next_bottle = ilt::borrow(bottle_table, next_debtor);
                assert!(
                    cr_less(prev_bottle, &bottle) &&
                        cr_greater_or_equal(next_bottle, &bottle),
                    EUnsortedInsertion,
                );
                ilt::insert(bottle_table, prev_debtor, debtor, bottle);
            } else {
                assert!(
                    cr_less(prev_bottle, &bottle),
                    EUnsortedInsertion,
                );
                ilt::push_back(bottle_table, debtor, bottle);
            }
        } else {
            let next_debtor = *ilt::front(bottle_table);
            if (option::is_some(&next_debtor)) {
                let next_debtor = option::destroy_some(next_debtor);
                let next_bottle = ilt::borrow(bottle_table, next_debtor);
                assert!(
                    cr_greater_or_equal(next_bottle, &bottle),
                    EUnsortedInsertion,
                );
                ilt::push_front(bottle_table, debtor, bottle);
            } else {
                ilt::push_front(bottle_table, debtor, bottle);
            }
        }
    }

    public(friend) fun borrow_result(
        bottle: &mut Bottle,
        price: u64,
        denominator: u64,
        collateral_ratio: u64,
        sui_amount: u64,
    ): u64 {
        let sui_factor = (bottle.sui_amount + sui_amount) * price * 100;
        let buck_factor = collateral_ratio * denominator * bottle.buck_amount;
        assert!(sui_factor > buck_factor, ECannotReachCollateralRatio);

        let minted_buck_amount = (sui_factor - buck_factor) / collateral_ratio * denominator;
        bottle.sui_amount = bottle.sui_amount + sui_amount;
        bottle.buck_amount = bottle.buck_amount + minted_buck_amount;

        minted_buck_amount
    }

    public(friend) fun repay_result(bottle: &mut Bottle, repay_amount: u64): (bool, u64) {
        if (repay_amount >= bottle.buck_amount) {
            let return_sui_amount = bottle.sui_amount;
            bottle.sui_amount = 0;
            bottle.buck_amount = 0;
            // fully repaid
            (true, return_sui_amount)
        } else {
            let return_sui_amount = bottle.sui_amount * repay_amount / bottle.buck_amount;
            bottle.sui_amount = bottle.sui_amount - return_sui_amount;
            bottle.buck_amount = bottle.buck_amount - repay_amount;
            // not fully repaid
            (false, return_sui_amount)
        }
    }

    public(friend) fun redeem_result(
        bottle: &mut Bottle,
        price: u64,
        denominator: u64,
        buck_amount: u64,
    ): (u64, u64, u64, bool) {
        let redeemer_sui_amount = buck_amount * denominator / price;
        assert!(bottle.sui_amount >= redeemer_sui_amount, ECannotRedeemFromBottle);
        let debtor_sui_amount = bottle.sui_amount - redeemer_sui_amount;

        if (buck_amount >= bottle.buck_amount) {
            bottle.sui_amount = 0;
            bottle.buck_amount = 0;
            if (buck_amount == bottle.buck_amount)
                (buck_amount, redeemer_sui_amount, debtor_sui_amount, true)
            else
                (bottle.buck_amount, redeemer_sui_amount, debtor_sui_amount, false)
        } else {
            bottle.sui_amount = bottle.sui_amount - redeemer_sui_amount;
            bottle.buck_amount = bottle.buck_amount - buck_amount;
            (buck_amount, redeemer_sui_amount, 0, true)
        }
    }

    public(friend) fun destroyable(bottle: &Bottle): bool {
        bottle.sui_amount == 0 && bottle.buck_amount == 0
    }

    public(friend) fun destroy(bottle: Bottle) {
        let Bottle { sui_amount, buck_amount } = bottle;
        assert!(sui_amount == 0 && buck_amount == 0, EDestroyNonEmptyBottle);
    }

    public fun get_sui_amount(bottle: &Bottle): u64 {
        bottle.sui_amount
    }

    public fun get_buck_amount(bottle: &Bottle): u64 {
        bottle.buck_amount
    }

    fun cr_greater_or_equal(bottle_1: &Bottle, bottle_2: &Bottle): bool {
        (bottle_1.sui_amount as u256) * (bottle_2.buck_amount as u256) >=
            (bottle_2.sui_amount as u256) * (bottle_1.buck_amount as u256)
    }

    fun cr_less(bottle_1: &Bottle, bottle_2: &Bottle): bool {
        !cr_greater_or_equal(bottle_1, bottle_2)
    }
}
