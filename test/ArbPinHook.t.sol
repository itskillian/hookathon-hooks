// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {console} from "forge-std/console.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Deploy} from "v4-periphery/test/shared/Deploy.sol";

import {ArbPinHook} from "../src/ArbPinHook.sol";

contract ArbPinHookTest is Test, Deployers {
    ArbPinHook public hook;
    PoolKey public arbKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        
        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO;
        Currency currency1 = deployMintAndApproveCurrency();

        // Give the test contract some ETH
        vm.deal(address(this), 1000 ether);

        // deploy hook address
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.AFTER_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            )
        );
        
        vm.txGasPrice(10 gwei);
        deployCodeTo("ArbPinHook.sol", abi.encode(manager), hookAddress);
        hook = ArbPinHook(hookAddress);

        // init pool with hook and dynamic fee
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );
        // add liquidity to hook pool - provide ETH as msg.value
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // init arb pool with no hook and static fee
        (arbKey, ) = initPool(
            currency0,
            currency1,
            IHooks(address(0)),
            3000, // 0.3% fee
            SQRT_PRICE_1_1
        );
        // add liquidity to arb pool - provide ETH as msg.value
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            arbKey,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Get the pool creator and use vm.prank to call configurePool
        address poolCreator = hook.poolCreator(key.toId());
        vm.prank(poolCreator);
        hook.configurePool(key.toId(), true, key, arbKey);
    }

    function testSimpleSwap() public {
        // set swap params
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Perform a simple swap - also provide ETH if selling ETH
        uint256 balanceToken1Before = currency1.balanceOfSelf();
        swapRouter.swap{value: 1 ether}(key, swapParams, testSettings, ZERO_BYTES);
        uint256 balanceToken1After = currency1.balanceOfSelf();
        uint256 outputFromSwap = balanceToken1After - balanceToken1Before;

        assertGt(balanceToken1After, balanceToken1Before);

        // assert prices of both pools
    }
}