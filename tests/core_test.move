#[test_only]
module up_only::up_only_test {

    use std::option;
    use std::signer;
    use std::signer::address_of;
    use std::string;
    use endless_framework::account;
    use endless_framework::account::create_signer_for_test;
    use endless_framework::endless_coin;
    use endless_framework::fungible_asset;
    use endless_framework::fungible_asset::{Metadata, MintRef, generate_mint_ref};
    use endless_framework::object;
    use endless_framework::object::{ConstructorRef, Object};
    use endless_framework::primary_fungible_store::create_primary_store_enabled_fungible_asset;
    use endless_framework::primary_fungible_store::{mint };
    use endless_framework::transaction_context;
    use endless_std::debug::print;
    use endless_std::math128;
    use endless_std::math128::pow;
    use endless_std::string_utils;
    use up_only::UpOnly;

    const E_TEST_FAILD: u64 = 10001;

    fun create_test_token(creator: &signer): (ConstructorRef) {
        account::create_account_for_test(signer::address_of(creator));
        let creator_ref = object::create_named_object(creator, b"TEST");

        creator_ref
    }

    fun from_coin(amount: u128, token: Object<Metadata>): u128 {
        amount * math128::pow(10, (fungible_asset::decimals(token) as u128))
    }

    fun init_test_metadata(
        creator: &signer,
        decimals: u8,
        name: vector<u8>,
        symbol: vector<u8>,
    ): (Object<Metadata>, MintRef) {
        account::create_account_for_test(address_of(creator));
        let creator_ref = object::create_named_object(creator, symbol);
        create_primary_store_enabled_fungible_asset(
            &creator_ref,
            option::none() /* max supply */,
            string::utf8(name),
            string::utf8(symbol),
            decimals,
            string::utf8(b"http://www.example.com/favicon.ico"),
            string::utf8(b"http://www.example.com"),
        );
        let mint_ref = generate_mint_ref(&creator_ref);

        let asset_address = object::create_object_address(&address_of(creator), symbol);
        (object::address_to_object<Metadata>(asset_address), mint_ref)
    }

    fun create_base_coins(alice: &signer, bob: &signer): (Object<Metadata>, Object<Metadata>) {
        let fx = create_signer_for_test(@endless_framework);
        let (mint_ref_eds, _, _) = endless_coin::initialize_for_test(&fx);
        let (usdt, mint_ref_u) = init_test_metadata(
            alice,
            6,
            b"Test USD",
            b"USDT"
        );

        let eds = endless_coin::get_metadata();

        let alise_address = signer::address_of(alice);
        let bob_address = signer::address_of(bob);
        mint(&mint_ref_eds, alise_address, from_coin(1000000000000, eds));
        mint(&mint_ref_eds, bob_address, from_coin(1000000000000, eds));
        mint(&mint_ref_u, alise_address, from_coin(1000000000000, usdt));
        mint(&mint_ref_u, bob_address, from_coin(1000000000000, usdt));
        (usdt, eds)
    }

    #[test(alice = @0xabcd, bob= @0xacee)]
    fun test_create_coin(alice: &signer, bob: &signer) {
        let (usdt, eds) = create_base_coins(alice, bob);
        print(&string_utils::format2(&b"ETH {} USDT {}", object::object_address(&eds), object::object_address(&usdt)));
        let a = UpOnly::create_and_mint_and_destory_permissions(
            alice,
            100,
            string::utf8(b"aaaa"),
            string::utf8(b"c"),
            8,
            string::utf8(b"a"),
            string::utf8(b"a")
        );
        print(&string_utils::format2(&b"addr {} auid addr {}", a, transaction_context::generate_auid_address()));
    }

    #[test]
    fun test_calculate_fee_safe() {
        let (fee, remain) = UpOnly::calculate_fee_safe(100000000, 1);
        assert!(fee == 100000 && remain == 99900000, E_TEST_FAILD);
        let (fee, remain) = UpOnly::calculate_fee_safe(100000000, 30);
        assert!(fee == 3000000 && remain == 97000000, E_TEST_FAILD);
        let (fee, remain) = UpOnly::calculate_fee_safe(100000000, 33);
        print(&string_utils::format2(&b"fee {} remain {}", fee, remain));
    }

    const DEFAULT_VIRTUAL_EDS_AMOUNT: u128 = 4100_00000000;
    const DEFAULT_VIRTUAL_COIN_AMOUNT: u128 = 109980000_00000000;
    // good k here make sure add pool mc  = granted mc
    const K: u256 = 4509180000000000000000000000;
    const SCALE: u256 = 1_000_000_000;

    #[test]
    fun test_k_set() {
        let add_pool_eds: u128 = 10000_00000000;
        let add_pool_coin: u128 = 22000000_00000000;
        let supply: u128 = 100000000_00000000;
        let decimal: u128 = 8;
        // defaul 1ed = $1
        let k1 = DEFAULT_VIRTUAL_EDS_AMOUNT * DEFAULT_VIRTUAL_COIN_AMOUNT;
        let left: u128 = k1 / (DEFAULT_VIRTUAL_EDS_AMOUNT + add_pool_eds);
        print(&string_utils::format1(&b"left: {}", left / pow(10, decimal)));
        print(&string_utils::format1(&b"k: {}", k1));
        // init mc = virtual_eds_coin/virtual_coin * supply = 3727
        // grant mc = letf/(virtual_eds_coin+add_pool_eds) *supply = 44090
        // add pool mc = add_pool_eds * (1-fee) / add_pool_coin * supply = 44090
        print(&string_utils::format1(&b"sell coin: {}", DEFAULT_VIRTUAL_COIN_AMOUNT - left));
        print(&string_utils::format1(&b"add pool coin need: {}", k1 / (add_pool_eds - 300_00000000)));
    }

    #[test]
    fun test_sell_coin_to_eds_estimate() {
        let real_coin_balance = 7675463802822091;
        let real_eds_balance = 947150000000;
        let virtual_coin_reserve = 10998000000000000;
        let virtual_eds_reserve = 410000000000;
        let scale_k = K * SCALE;
        let coin_amount = 7675463802822090;
        let cal_coin_count = virtual_coin_reserve - real_coin_balance + coin_amount;
        let temp = scale_k / (cal_coin_count as u256);
        let u256_cal_eds_count = temp / SCALE;
        print(
            &string_utils::format1(
                &b"reveived coin: {}",
                virtual_eds_reserve + real_eds_balance - (u256_cal_eds_count as u128)
            )
        );
    }

    const ADD_POOL_NEED_EDS: u128 = 9700_00000000;
    const ADD_POOL_NEED_COIN: u128 = 22000000_00000000;
    #[test]
    fun test_init_buy_and_granted_sell() {
        let eds_amount = 10_00000000;
        let scale_k = K * SCALE;
        let cal_eds_count = DEFAULT_VIRTUAL_EDS_AMOUNT + 0 + eds_amount;
        let temp = scale_k / (cal_eds_count as u256);
        let u256_cal_coin_count = temp / SCALE;
        let r = DEFAULT_VIRTUAL_COIN_AMOUNT - 0 - (u256_cal_coin_count as u128);
        print(&string_utils::format1(&b"receive coin amount: {}", r));

        let add_pool_k = ADD_POOL_NEED_COIN * ADD_POOL_NEED_EDS;
        let scale_k2 = (add_pool_k as u256) * SCALE;
        let sell_coin:u128 = r;
        let temp2 = scale_k2 / ((sell_coin+ADD_POOL_NEED_COIN) as u256);
        let coin_amount = temp2 /SCALE;
        let get_eds = ADD_POOL_NEED_EDS - (coin_amount as u128);
        print(&string_utils::format1(&b"init pool buy eds amount:             {}", eds_amount));
        print(&string_utils::format1(&b"granted sell all coin get eds amount: {}", get_eds));
    }
}