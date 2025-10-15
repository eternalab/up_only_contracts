module up_only::UpOnly {

    use std::bcs;
    use std::option;
    use std::signer;
    use std::signer::address_of;
    use std::string::String;
    use std::vector;
    use endless_framework::account;
    use endless_framework::endless_coin;
    use endless_framework::event::emit;
    use endless_framework::fungible_asset;
    use endless_framework::fungible_asset::Metadata;
    use endless_framework::object;
    use endless_framework::primary_fungible_store;
    use endless_framework::timestamp::now_seconds;
    use endless_framework::transaction_context;
    use endless_std::math128;
    use endless_std::simple_map;
    use endless_std::simple_map::SimpleMap;
    // sliswap
    use sliswap::router::create_pool;
    use sliswap::liquidity_pool::liquidity_pool_address;

    // error constants
    const E_PARAMS_INVALID: u64 = 101;
    const E_ADMIN_REQUIRED: u64 = 102;
    const E_SUPER_ADMIN_REQUIRED: u64 = 103;
    const E_ALREADY_EXIST: u64 = 104;
    const E_TARGET_NOT_FOUND: u64 = 105;
    const E_BALANCE_INSUFFICIENT: u64 = 106;
    const E_AMOUNT_OVERFLOW: u64 = 107;

    const E_POOL_EXIST: u64 = 201;
    const E_POOL_GRADUATED: u64 = 202;
    const E_INVALID_EDS_AMOUNT: u64 = 203;
    const E_INVALID_COIN_AMOUNT: u64 = 204;
    const E_INSUFFICIENT_SLIPPAGE: u64 = 205;
    const E_UNKNOWN_COIN: u64 = 206;
    const E_POOL_NOT_GRADUATED: u64 = 207;

    // some consts
    const U128MAX: u256 = 340282366920938463463374607431768211455;
    // init coin mc 3.727K,granted mc: 44.09k
    // The overall internal growth multiplier is approximately 11.9x
    const DEFAULT_VIRTUAL_EDS_AMOUNT: u128 = 4100_00000000;
    const DEFAULT_VIRTUAL_COIN_AMOUNT: u128 = 109980000_00000000;
    // good k here make sure add pool mc  = granted mc
    const K: u256 = 4509180000000000000000000000;
    const SCALE: u256 = 1_000_000_000;
    // preset params
    const ADD_POOL_NEED_EDS: u128 = 10000_00000000;
    const ADD_POOL_NEED_COIN: u128 = 22000000_00000000;
    // create coin supply = 100M
    const DEFAULT_TOTAL_SUPPLY: u128 = 100_000_000;
    const DEFAULT_DECIMALS: u8 = 8;
    // 5 eds
    const DEFAULT_DEPLOY_FEE: u128 = 5_00000000;
    // granted fee: 3%
    const DEFAULT_GRANTED_FEE_RATIO: u128 = 30;
    // buy fee: 0.3%
    const DEFAULT_BUY_FEE_RATIO: u128 = 3;
    // sell fee: 0.3%
    const DEFAULT_SELL_FEE_RATIO: u128 = 3;
    // trade type
    const TRADE_BUY: u8 = 1;
    const TRADE_SELL: u8 = 2;

    struct Treasury has key {
        cap: account::SignerCapability,
    }

    struct InnerPool has key {
        cap: account::SignerCapability,
    }

    struct SuperAdminCapability has key {}

    struct Admins has key {
        list: vector<address>
    }

    #[event]
    struct CreateCoinEvent has store, drop {
        coin: address,
        creator: address,
        fee: u128,
        name: String,
        symbol: String,
        icon: String,
        official_link: String,
    }

    #[event]
    struct CoinGranted has store, drop {
        coin: address,
    }

    #[event]
    struct TradeRecord has store, drop {
        coin: address,
        address: address,
        trade_type: u8,
        in_amount: u128,
        out_amount: u128,
        fee: u128,
    }

    #[event]
    struct AddPool has store, drop {
        coin: address,
        pool_addr: address,
        name: String,
        symbol: String,
        icon: String,
        official_link: String,
    }

    struct MemeCoinMetadata has store, copy, drop {
        name: String,
        symbol: String,
        icon: String,
        official_link: String,
        creator: address,
    }

    // k = (virtualEds+realEds) * (virtualCoin+realCoin)
    struct VirtualPool has store, copy, drop {
        virtual_eds_reserve: u128,
        virtual_coin_reserve: u128,
        real_coin_balance: u128,
        real_eds_balance: u128,
        graduated: bool,
    }

    struct CoinInfo has store, copy, drop {
        contract: address,
        virtual_pool: VirtualPool,
        meta_data: MemeCoinMetadata,
        //default @0x0
        swap_pool_addr: address,
        created_at: u64,
    }


    struct UpOnlyManager has key {
        create_coin_fee: u128,
        // creator -> []tokenContract
        create_coin_records: SimpleMap<address, vector<address>>,
        // tokenContract -> coinInfo
        coin_maps: SimpleMap<address, CoinInfo>,
    }

    fun init_module(caller: &signer) {
        if (!exists<Treasury>(@up_only)) {
            let (_, resource_account_cap) = account::create_resource_account(
                caller,
                b"up_only::ResourcesAcc::Treasury"
            );
            move_to(caller, Treasury {
                cap: resource_account_cap,
            });
        };
        if (!exists<InnerPool>(@up_only)) {
            let (_, resource_account_cap) = account::create_resource_account(
                caller,
                b"up_only::ResourcesAcc::InnerPool"
            );
            move_to(caller, InnerPool {
                cap: resource_account_cap,
            });
        };
        let admins = Admins { list: vector::singleton<address>(signer::address_of(caller)) };
        //superadmin capanility
        move_to(caller, SuperAdminCapability {});
        // admin list
        move_to(caller, admins);
        let manager = UpOnlyManager {
            create_coin_fee: DEFAULT_DEPLOY_FEE,
            create_coin_records: simple_map::create(),
            coin_maps: simple_map::create(),
        };
        move_to(caller, manager);
    }


    public entry fun update_create_coin_fee(super_admin: &signer, amount: u128) acquires UpOnlyManager {
        require_super_admin(signer::address_of(super_admin));
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        assert!(manager.create_coin_fee != amount, E_PARAMS_INVALID);
        manager.create_coin_fee = amount
    }

    public entry fun withdraw_from_treasury(super_admin: &signer, amount: u128) acquires Treasury {
        require_super_admin(signer::address_of(super_admin));
        let treasury_bal = endless_coin::balance(treasury_address());
        assert!(treasury_bal >= amount, E_BALANCE_INSUFFICIENT);
        treasury_send_eds(amount)
    }


    /// add a admin
    /// super admin require
    public entry fun add_admin_addr(
        super_admin: &signer,
        admin: address
    ) acquires Admins {
        require_super_admin(signer::address_of(super_admin));
        let admin_capability = borrow_global_mut<Admins>(@up_only);
        let admin_list = &mut admin_capability.list;
        assert!(!vector::contains(admin_list, &admin), E_ALREADY_EXIST);
        vector::push_back(admin_list, admin)
    }

    /// revoke a admin
    /// super admin require
    public entry fun remove_admin_addr(
        super_admin: &signer,
        admin: address
    ) acquires Admins {
        require_super_admin(signer::address_of(super_admin));
        let admin_capability = borrow_global_mut<Admins>(@up_only);
        let admin_list = &mut admin_capability.list;
        let (exist, index) = vector::index_of(admin_list, &admin);
        assert!(exist, E_TARGET_NOT_FOUND);
        let remove_admin = vector::remove<address>(admin_list, index);
        assert!(remove_admin == admin, E_PARAMS_INVALID)
    }

    public entry fun create_token_with_init_buy(
        caller: &signer,
        name: String,
        symbol: String,
        icon: String,
        official_link: String,
        init_buy_amount: u128,
    ) acquires InnerPool, Treasury, UpOnlyManager {
        assert!(init_buy_amount > 0, E_PARAMS_INVALID);
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let caller_addr = signer::address_of(caller);
        pay_to_treasury(caller, manager.create_coin_fee);
        let coin_address = create_token_and_init_v_pool(manager, caller_addr, name, symbol, icon, official_link);
        emit(CreateCoinEvent {
            coin: coin_address,
            creator: caller_addr,
            fee: manager.create_coin_fee,
            name,
            symbol,
            icon,
            official_link,
        });
        buy_coin_by_eds(caller, coin_address, init_buy_amount, 0)
    }

    fun create_token_and_init_v_pool(
        manager: &mut UpOnlyManager,
        caller_addr: address,
        name: String,
        symbol: String,
        icon: String,
        official_link: String,
    ): address acquires InnerPool {
        // create token
        let coin_address = create_and_mint_and_destory_permissions(
            inner_pool_signer(),
            DEFAULT_TOTAL_SUPPLY * math128::pow(10, (DEFAULT_DECIMALS as u128)),
            name,
            symbol,
            DEFAULT_DECIMALS,
            icon,
            official_link
        );
        // add pool
        let vPool = VirtualPool {
            virtual_eds_reserve: DEFAULT_VIRTUAL_EDS_AMOUNT,
            virtual_coin_reserve: DEFAULT_VIRTUAL_COIN_AMOUNT,
            real_coin_balance: 0,
            real_eds_balance: 0,
            graduated: false,
        };
        let coin_maps = &mut manager.coin_maps;
        assert!(!simple_map::contains_key(coin_maps, &coin_address), E_ALREADY_EXIST);
        simple_map::add(coin_maps, coin_address, CoinInfo {
            contract: coin_address,
            virtual_pool: vPool,
            created_at: now_seconds(),
            swap_pool_addr: @0x0,
            meta_data: MemeCoinMetadata {
                name,
                symbol,
                icon,
                official_link,
                creator: caller_addr,
            },
        });
        let ccr = &mut manager.create_coin_records;
        if (simple_map::contains_key(ccr, &caller_addr)) {
            let addrs = simple_map::borrow_mut(ccr, &caller_addr);
            vector::push_back(addrs, coin_address);
        }else {
            simple_map::add(ccr, caller_addr, vector::singleton(coin_address))
        };
        coin_address
    }

    public entry fun create_token(
        caller: &signer,
        name: String,
        symbol: String,
        icon: String,
        official_link: String,
    ) acquires InnerPool, Treasury, UpOnlyManager {
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let caller_addr = signer::address_of(caller);
        pay_to_treasury(caller, manager.create_coin_fee);
        let coin_address = create_token_and_init_v_pool(manager, caller_addr, name, symbol, icon, official_link);
        emit(CreateCoinEvent {
            coin: coin_address,
            creator: caller_addr,
            fee: manager.create_coin_fee,
            name,
            symbol,
            icon,
            official_link,
        });
    }

    public entry fun buy_coin_by_eds(
        buyer: &signer,
        coin_address: address,
        eds_amount: u128,
        min_coin_amount: u128
    ) acquires UpOnlyManager, InnerPool, Treasury {
        assert!(eds_amount > 0, E_INVALID_EDS_AMOUNT);
        assert!(min_coin_amount >= 0, E_INVALID_COIN_AMOUNT);
        let buyer_addr = signer::address_of(buyer);
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let coin_maps = &mut manager.coin_maps;
        assert!(simple_map::contains_key(coin_maps, &coin_address), E_UNKNOWN_COIN);
        let coin_info = simple_map::borrow_mut(coin_maps, &coin_address);
        let pool = &mut coin_info.virtual_pool;
        assert!(!pool.graduated, E_POOL_GRADUATED);
        // cal fee first
        let (fee, remain) = calculate_fee_safe(eds_amount, DEFAULT_BUY_FEE_RATIO);
        let need_eds_amount: u128 = remain;
        // make sure not over max add pool need
        if (pool.real_eds_balance + remain >= ADD_POOL_NEED_EDS) {
            need_eds_amount = ADD_POOL_NEED_EDS - pool.real_eds_balance;
            emit(CoinGranted {
                coin: coin_address
            })
        };
        let out_coin_amount = cal_coin_amount_by_eds(*pool, need_eds_amount);
        assert!(out_coin_amount > 0, E_INVALID_COIN_AMOUNT);
        pool.real_eds_balance = pool.real_eds_balance + need_eds_amount;
        pool.real_coin_balance = pool.real_coin_balance + out_coin_amount;
        if (pool.real_eds_balance == ADD_POOL_NEED_EDS) {
            pool.graduated = true;
        };
        assert!(out_coin_amount >= min_coin_amount, E_INSUFFICIENT_SLIPPAGE);
        pay_to_treasury(buyer, fee);
        pay_to_inner_pool(buyer, need_eds_amount);
        inner_pool_send_coin(buyer_addr, coin_address, out_coin_amount);
        emit(TradeRecord {
            coin: coin_address,
            address: buyer_addr,
            trade_type: TRADE_BUY,
            in_amount: need_eds_amount,
            out_amount: out_coin_amount,
            fee,
        })
    }


    public entry fun sell_coin_to_eds(
        seller: &signer,
        coin_address: address,
        coin_amount: u128,
        min_eds_amount: u128
    ) acquires UpOnlyManager, InnerPool, Treasury {
        assert!(min_eds_amount >= 0, E_INVALID_EDS_AMOUNT);
        let seller_addr = signer::address_of(seller);
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let coin_maps = &mut manager.coin_maps;
        assert!(simple_map::contains_key(coin_maps, &coin_address), E_UNKNOWN_COIN);
        let coin_info = simple_map::borrow_mut(coin_maps, &coin_address);
        let pool = &mut coin_info.virtual_pool;
        assert!(!pool.graduated, E_POOL_GRADUATED);
        assert!(pool.real_eds_balance > 0, E_INVALID_COIN_AMOUNT);
        assert!(coin_amount > 0 && coin_amount <= pool.real_coin_balance, E_INVALID_COIN_AMOUNT);
        let out_eds_amount = cal_eds_amount_by_coin(*pool, coin_amount);
        assert!(out_eds_amount <= pool.real_eds_balance, E_INVALID_EDS_AMOUNT);
        pool.real_eds_balance = pool.real_eds_balance - out_eds_amount;
        pool.real_coin_balance = pool.real_coin_balance - coin_amount;
        assert!(out_eds_amount >= min_eds_amount, E_INSUFFICIENT_SLIPPAGE);
        send_to_inner_pool(seller, coin_address, coin_amount);
        let (fee, remain) = calculate_fee_safe(out_eds_amount, DEFAULT_SELL_FEE_RATIO);
        inner_pool_send_eds(treasury_address(), fee);
        inner_pool_send_eds(seller_addr, remain);
        emit(TradeRecord {
            coin: coin_address,
            address: seller_addr,
            trade_type: TRADE_SELL,
            in_amount: coin_amount,
            out_amount: out_eds_amount,
            fee,
        })
    }


    public entry fun granted_and_add_lp_to_sliswap(
        caller: &signer,
        coin: address
    ) acquires UpOnlyManager, Admins, InnerPool, Treasury {
        let caller_addr = signer::address_of(caller);
        require_admin(caller_addr);
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let coin_maps = &mut manager.coin_maps;
        assert!(simple_map::contains_key(coin_maps, &coin), E_TARGET_NOT_FOUND);
        let coin_info = simple_map::borrow_mut(coin_maps, &coin);
        assert!(coin_info.virtual_pool.graduated, E_POOL_NOT_GRADUATED);
        assert!(coin_info.virtual_pool.real_eds_balance == ADD_POOL_NEED_EDS, E_POOL_NOT_GRADUATED);
        assert!(
            (DEFAULT_TOTAL_SUPPLY * math128::pow(
                10,
                (DEFAULT_DECIMALS as u128)
            )) - coin_info.virtual_pool.real_coin_balance == ADD_POOL_NEED_COIN,
            E_POOL_NOT_GRADUATED
        );
        let (fee, remain) = calculate_fee_safe(
            coin_info.virtual_pool.real_eds_balance,
            DEFAULT_GRANTED_FEE_RATIO
        );
        // lp coin 0 - source coin
        let coin_0 = object::address_to_object<Metadata>(coin);
        // lp coin 1 - eds
        let coin_eds = endless_coin::get_metadata();
        let pool_addr = liquidity_pool_address(coin_0, coin_eds);
        pay_to_treasury(inner_pool_signer(), fee);
        create_pool(inner_pool_signer(),
            coin_0,
            coin_eds,
            ADD_POOL_NEED_COIN,
            remain,
        );
        coin_info.swap_pool_addr = pool_addr;
        emit(AddPool {
            coin,
            pool_addr,
            name: coin_info.meta_data.name,
            symbol: coin_info.meta_data.symbol,
            icon: coin_info.meta_data.icon,
            official_link: coin_info.meta_data.official_link,
        })
    }

    fun cal_coin_amount_by_eds(pool: VirtualPool, eds_amount: u128): u128 {
        if (pool.real_eds_balance + eds_amount == ADD_POOL_NEED_EDS) {
            DEFAULT_TOTAL_SUPPLY * math128::pow(
                10,
                (DEFAULT_DECIMALS as u128)
            ) - ADD_POOL_NEED_COIN - pool.real_coin_balance
        }else {
            let scale_k = K * SCALE;
            let cal_eds_count = pool.virtual_eds_reserve + pool.real_eds_balance + eds_amount;
            let temp = scale_k / (cal_eds_count as u256);
            let u256_cal_coin_count = temp / SCALE;
            pool.virtual_coin_reserve - pool.real_coin_balance - safe_u256_to_u128(u256_cal_coin_count)
        }
    }

    fun cal_eds_amount_by_coin(pool: VirtualPool, coin_amount: u128): u128 {
        let cal_coin_count = pool.virtual_coin_reserve - pool.real_coin_balance + coin_amount;
        let scale_k = K * SCALE;
        let temp = scale_k / (cal_coin_count as u256);
        let u256_cal_eds_count = temp / SCALE;
        pool.virtual_eds_reserve + pool.real_eds_balance - safe_u256_to_u128(u256_cal_eds_count)
    }

    fun send_to_inner_pool(sender: &signer, coin_addr: address, amount: u128) acquires InnerPool {
        assert!(amount > 0, E_INVALID_COIN_AMOUNT);
        let asset = object::address_to_object<Metadata>(coin_addr);
        let from_wallet = primary_fungible_store::primary_store(signer::address_of(sender), asset);
        let from_balance = primary_fungible_store::balance(signer::address_of(sender), asset);
        assert!(from_balance >= amount, E_BALANCE_INSUFFICIENT);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(inner_pool_address(), asset);
        fungible_asset::transfer(sender, from_wallet, to_wallet, amount)
    }

    fun inner_pool_send_coin(to: address, coin_addr: address, amount: u128) acquires InnerPool {
        assert!(amount > 0, E_INVALID_COIN_AMOUNT);
        let asset = object::address_to_object<Metadata>(coin_addr);
        let from_wallet = primary_fungible_store::primary_store(inner_pool_address(), asset);
        let from_balance = primary_fungible_store::balance(inner_pool_address(), asset);
        assert!(from_balance >= amount, E_BALANCE_INSUFFICIENT);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        fungible_asset::transfer(inner_pool_signer(), from_wallet, to_wallet, amount)
    }

    fun inner_pool_send_eds(to: address, amount: u128) acquires InnerPool {
        assert!(amount > 0, E_INVALID_EDS_AMOUNT);
        endless_coin::transfer(inner_pool_signer(), to, amount);
    }

    fun treasury_send_eds(amount: u128) acquires Treasury {
        assert!(amount > 0, E_INVALID_EDS_AMOUNT);
        endless_coin::transfer(treasury_signer(), @up_only, amount);
    }

    fun pay_to_treasury(caller: &signer, amount: u128) acquires Treasury {
        let eds_metadata = endless_coin::get_metadata();
        let amount_fa = primary_fungible_store::withdraw(caller, eds_metadata, amount);
        primary_fungible_store::deposit(treasury_address(), amount_fa);
    }

    fun pay_to_inner_pool(caller: &signer, amount: u128) acquires InnerPool {
        let eds_metadata = endless_coin::get_metadata();
        let amount_fa = primary_fungible_store::withdraw(caller, eds_metadata, amount);
        primary_fungible_store::deposit(inner_pool_address(), amount_fa);
    }

    public fun create_and_mint_and_destory_permissions(
        creator: &signer,
        max_supply: u128,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): address {
        let seeds = vector[];
        vector::append(&mut seeds, bcs::to_bytes(&name));
        vector::append(&mut seeds, bcs::to_bytes(&symbol));
        vector::append(&mut seeds, bcs::to_bytes(&transaction_context::generate_auid_address()));
        let creator_ref = object::create_named_object(creator, seeds);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &creator_ref,
            option::some(max_supply),
            name,
            symbol,
            decimals,
            icon_uri,
            project_uri
        );

        let mint_ref = fungible_asset::generate_mint_ref(&creator_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&creator_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&creator_ref);
        let fa = fungible_asset::mint(&mint_ref, max_supply);
        fungible_asset::destroy_mint_cap(mint_ref);
        fungible_asset::destroy_burn_cap(burn_ref);
        let asset = object::object_from_constructor_ref<Metadata>(&creator_ref);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(address_of(creator), asset);
        fungible_asset::deposit_with_ref(&transfer_ref, to_wallet, fa);
        // asset address
        object::create_object_address(&address_of(creator), seeds)
    }

    /// retrun (fee,remain)
    public fun calculate_fee_safe(ori_amount: u128, ratio: u128): (u128, u128) {
        if (ori_amount == 0 || ratio == 0) {
            return (0, ori_amount)
        };
        let thousand: u128 = 1000;
        let high_part = ori_amount / thousand;
        let low_part = ori_amount % thousand;
        let high_fee = high_part * ratio;
        let low_fee = (low_part * ratio) / thousand;
        let total_fee = high_fee + low_fee;
        let remaining = ori_amount - total_fee;

        (total_fee, remaining)
    }

    inline fun require_admin(account: address) acquires Admins {
        let admin_capability = borrow_global_mut<Admins>(@up_only);
        assert!(vector::contains(&mut admin_capability.list, &account), E_ADMIN_REQUIRED)
    }

    inline fun require_super_admin(account: address) {
        assert!(exists<SuperAdminCapability>(account), E_SUPER_ADMIN_REQUIRED);
    }

    inline fun treasury_address(): address acquires Treasury {
        let treasury = borrow_global<Treasury>(@up_only);
        account::get_signer_capability_address(&treasury.cap)
    }

    inline fun treasury_signer(): &signer acquires Treasury {
        let treasury = borrow_global<Treasury>(@up_only);
        &account::create_signer_with_capability(&treasury.cap)
    }

    inline fun inner_pool_address(): address acquires InnerPool {
        let deposit = borrow_global<InnerPool>(@up_only);
        account::get_signer_capability_address(&deposit.cap)
    }

    inline fun inner_pool_signer(): &signer acquires InnerPool {
        let deposit = borrow_global<InnerPool>(@up_only);
        &account::create_signer_with_capability(&deposit.cap)
    }

    inline fun safe_u256_to_u128(amount: u256): u128 {
        assert!(amount <= U128MAX, E_AMOUNT_OVERFLOW);
        (amount as u128)
    }

    #[view]
    public fun query_create_coins(addr: address): vector<CoinInfo> acquires UpOnlyManager {
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let r = manager.create_coin_records;
        let coin_maps = manager.coin_maps;
        if (simple_map::contains_key(&r, &addr)) {
            let coins = *simple_map::borrow(&r, &addr);
            let coinInfos = vector::empty<CoinInfo>();
            vector::for_each_ref(&coins, |addr|{
                let cInfo = *simple_map::borrow(&coin_maps, addr);
                vector::push_back(&mut coinInfos, cInfo)
            });
            coinInfos
        }else {
            vector::empty<CoinInfo>()
        }
    }

    #[view]
    public fun query_coin_info(coin_addr: address): CoinInfo acquires UpOnlyManager {
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let r = manager.coin_maps;
        *simple_map::borrow(&r, &coin_addr)
    }

    #[view]
    public fun buy_coin_with_eds_estimate(coin_addr: address, buy_eds_amount: u128): u128 acquires UpOnlyManager {
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let coin_maps = &mut manager.coin_maps;
        assert!(simple_map::contains_key(coin_maps, &coin_addr), E_UNKNOWN_COIN);
        let coin_info = simple_map::borrow(coin_maps, &coin_addr);
        let pool = coin_info.virtual_pool;
        assert!(!pool.graduated, E_POOL_GRADUATED);
        assert!(buy_eds_amount > 0, E_INVALID_EDS_AMOUNT);
        cal_coin_amount_by_eds(pool, buy_eds_amount)
    }

    #[view]
    public fun sell_coin_to_eds_estimate(coin_addr: address, sell_coin_amount: u128): u128 acquires UpOnlyManager {
        let manager = borrow_global_mut<UpOnlyManager>(@up_only);
        let coin_maps = &mut manager.coin_maps;
        assert!(simple_map::contains_key(coin_maps, &coin_addr), E_UNKNOWN_COIN);
        let coin_info = simple_map::borrow(coin_maps, &coin_addr);
        let pool = coin_info.virtual_pool;
        assert!(!pool.graduated, E_POOL_GRADUATED);
        assert!(pool.real_eds_balance > 0, E_INVALID_COIN_AMOUNT);
        assert!(sell_coin_amount > 0 && sell_coin_amount <= pool.real_coin_balance, E_INVALID_COIN_AMOUNT);
        cal_eds_amount_by_coin(pool, sell_coin_amount)
    }
}