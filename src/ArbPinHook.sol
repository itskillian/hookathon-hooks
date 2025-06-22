// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCurrencyMetadata} from "lib/v4-periphery/src/libraries/SafeCurrencyMetadata.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IV4Quoter} from "lib/v4-periphery/src/interfaces/IV4Quoter.sol";

contract ArbPinHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant PIPS_SCALE = 1e6;
    uint256 private constant ILLIQ_SCALE = 1e6;
    uint256 private constant FEE_DIVISOR = 1e38; // PIPS_SCALE * PRECISION^2 / 10000 for direct pips calculation

    event PoolConfigured(PoolId indexed poolId, bool useToken1AsQuote, PoolKey arbPoolKey);

    error MustUseDynamicFee();
    error Unauthorized();
    error InvalidTimeDecay();
    error InvalidFee();

    struct Inventory {
        uint256 token0;
        uint256 token1;
    }
    
    struct PoolData {
        // config
        uint24 minFee; // in pips
        int8 deltaDecimals; // = token0Decimals - token1Decimals
        bool isConfigured;
        bool useToken1AsQuote; // true for token1
        address poolCreator;
        // state
        uint256 lastTimeUpdate;
        uint256 totalVolume; // token1
        int256 netVolume; // token1
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96After;
        uint256 avgILLIQ; // token1
        uint256 tradeCount; // number of trades used in ILLIQ average
        Inventory inventory;
        uint256 tvl; // token 1
    }

    struct Quote {
        uint256 amountOut;
        uint256 gasEstimate;
    }

    // state variables
    IV4Quoter public immutable quoter;
    address public owner;
    bool private _executingArb;

    mapping(PoolId => PoolData) public poolData; // main poolId -> pool data
    mapping(PoolId => PoolKey) public arbPoolKey; // main poolId -> arb pool key
    mapping(PoolId => address) public poolCreator; // main poolId -> pool creator

    // constructor
    constructor(IPoolManager _poolManager, IV4Quoter _quoter) BaseHook(_poolManager) {
        owner = msg.sender;
        quoter = _quoter;
    }

    /*
    ------ MODIFIERS ------ 
    */

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyCreator(PoolId poolId) {
        if (poolCreator[poolId] != msg.sender) revert Unauthorized();
        _;
    }

    /*
    ------ CORE HOOK FUNCTIONS ------ 
    */

    // Check if the pool supports dynamic fees
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    // Initialize pool data
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        data.minFee = 500; // 0.05% in pips
        data.deltaDecimals = int8(SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(key.currency0)))
            - int8(SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(key.currency1)));
        data.poolCreator = msg.sender;

        return BaseHook.afterInitialize.selector;
    }

    // calc PIN, calc inventory exposure, calc dynamic fee for swap
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];
        require(data.isConfigured, "Pool not configured");

        // get price before swap
        (data.sqrtPriceX96Before, , , ) = poolManager.getSlot0(poolId);

        // return early if pool has no swaps yet
        if (data.totalVolume == 0 || data.tradeCount == 0) {
            console.log("First trade detected - using default fee");
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                data.minFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }
        
        uint256 nextTradeVolToken1 = getNextTradeVolumeToken1(params, data.sqrtPriceX96Before, data.deltaDecimals);

        int256 pin = calculatePIN(data.totalVolume, data.netVolume, params.zeroForOne, nextTradeVolToken1);

        uint256 expectedPriceImpact = estimatePriceImpactBeforeSwap(data, nextTradeVolToken1);

        uint256 relevantInventoryExposure = calculateInventoryExposure(data, params.zeroForOne);


        // Calculate fee based on PIN, expected price impact, and inventory exposure
        uint24 fee = calculateFee(abs(pin), data.minFee, expectedPriceImpact, relevantInventoryExposure);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

        function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];
        require(data.isConfigured, "Pool not configured");

        // ------ POOL DATA UPDATE ------

        // TODOfunction to update core pool data
        (data.sqrtPriceX96After, , , ) = poolManager.getSlot0(poolId);
		uint256 lastTradeVolume1 = uint256(abs(delta.amount1()));

        uint256 lastTradePriceImpact = calculatePriceImpactAfterSwap(data.sqrtPriceX96Before, data.sqrtPriceX96After);

        if (lastTradeVolume1 > 0) {
            updateILLIQ(data, lastTradePriceImpact, lastTradeVolume1);   
            
            data.totalVolume += lastTradeVolume1;
            data.netVolume -= int256(delta.amount1());

            data.inventory.token0 = uint256(int256(data.inventory.token0) - delta.amount0());
            data.inventory.token1 = uint256(int256(data.inventory.token1) - delta.amount1());
        }

        // ------ ARB LOGIC ------
        // BIG TODO
        if (msg.sender == address(quoter)) {
            return (BaseHook.afterSwap.selector, 0);
        }

        if (!_executingArb) {
            _executingArb = true;
            
            uint256 arbAmount = calcArbAmount(key, data.sqrtPriceX96After, data.sqrtPriceX96Before);
            
            detectAndExecuteArb(
                key,
                arbPoolKey[poolId], 
                arbAmount,
                swapParams.zeroForOne
            );
            
            _executingArb = false; // Reset flag after arb
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        data.inventory.token0 = data.inventory.token0 + abs(delta.amount0());
        data.inventory.token1 = data.inventory.token1 + abs(delta.amount1());

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];

        data.inventory.token0 = data.inventory.token0 - abs(delta.amount0());
        data.inventory.token1 = data.inventory.token1 - abs(delta.amount1());

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /*
    ------ HELPER FUNCTIONS ------ 
    */
    
    /**
     * @dev Get or estimate the next trade volume of token1
     * @param params swap params sent by user
     * @param sqrtPriceX96Before price before swap
     * @param deltaDecimals difference in decimals between token0 and token1
     * @return next trade volume of token1
     */
    function getNextTradeVolumeToken1(
        SwapParams calldata params,
        uint160 sqrtPriceX96Before,
        int8 deltaDecimals
    ) internal pure returns (uint256) {
        if (sqrtPriceX96Before == 0) return 0;
        
        uint256 absoluteAmount = abs(params.amountSpecified);

        if (params.zeroForOne) {
            if (params.amountSpecified > 0) {
                // Exact input token0 - convert to token1
                return convertToken0ToToken1(absoluteAmount, sqrtPriceX96Before, deltaDecimals);
            } else {
                return absoluteAmount;
            }
        } else {
            if (params.amountSpecified > 0) {
                return absoluteAmount;
            } else {
                // Exact output of token0 - convert to token1
                return convertToken0ToToken1(absoluteAmount, sqrtPriceX96Before, deltaDecimals);
            }
        }
    }

    function calculatePIN(
        uint256 totalVolume,
        int256 netVolume,
        bool zeroForOne,
        uint256 nextTradeVolToken1
    ) internal pure returns (int256 pin) {
        uint256 tempTotalVolume = totalVolume + nextTradeVolToken1;

        
        if (tempTotalVolume > 0) {
            int256 tempNetVolume = netVolume +
                (
                    zeroForOne
                        ? -int256(nextTradeVolToken1)
                        : int256(nextTradeVolToken1)
                );

            pin = tempNetVolume * int256(PRECISION) / int256(tempTotalVolume);
        } else {
            // NOTE #3
            pin = 0;
        }
    }

    /**
     * @dev Estimate the expected price impact of the next trade before swap
     * @param data pool data storage pointer
     * @param nextTradeVolToken1 next trade volume in token1 terms
     * @return expectedPriceImpact expected price impact of the next trade scaled by PIPS_SCALE (1e6)
     */
    function estimatePriceImpactBeforeSwap(
        PoolData storage data,
        uint256 nextTradeVolToken1
    ) internal view returns (uint256 expectedPriceImpact) {
        // TODO is this min fee alright?
        if (data.avgILLIQ == 0 || nextTradeVolToken1 == 0) {
            return data.minFee;
        }
        
        expectedPriceImpact = (data.avgILLIQ * nextTradeVolToken1) / (1e6 * PRECISION);
    }

    /**
     * @dev Calculate inventory exposure of both tokens in token1 terms, and update data.tvl
     */
    function calculateInventoryExposure(
        PoolData storage data,
        bool zeroForOne
    ) internal returns (uint256) {
        uint256 inventoryToken0InToken1Terms = convertToken0ToToken1(data.inventory.token0, data.sqrtPriceX96Before, data.deltaDecimals);
        uint256 inventoryToken1InToken1Terms = scaleDecimalsUp(data.inventory.token1, data.deltaDecimals, true);

        data.tvl = inventoryToken0InToken1Terms + inventoryToken1InToken1Terms;

        if (data.tvl > 0) {
            // Calculate only the exposure we need
            if (zeroForOne) {
                // pool receives token0, therefore return inverse of token0 exposure
                return (inventoryToken0InToken1Terms * PRECISION) / data.tvl;
            } else {
                // Return token1 exposure (LP will receive more token1)  
                return (inventoryToken1InToken1Terms * PRECISION) / data.tvl;
            }
        }

        return 0;
    }

    function calculateFee(
        uint256 pin,
        uint24 minFee,
        uint256 expectedPriceImpact,
        uint256 inventoryExposure
    ) internal pure returns (uint24) {
        if (pin == 0) return minFee;

        // Calculate fee increase directly in pips
        // expectedPriceImpact is scaled by PIPS_SCALE (1e6, represents percentage in pips)
        // inventoryExposure is scaled by PRECISION (1e18, represents percentage, multiplied by inventoryMultiplier for amplification)
        // pin is scaled by PRECISION (1e18, represents percentage)
        // FEE_DIVISOR = PIPS_SCALE * PRECISION^2 / 10000 to convert directly to pips (1% = 10000 pips)
		
		// expected IL = expected PI * inventory exposure
		// expected permanent loss = expected IL * PIN

        uint256 feeIncreasePips = (expectedPriceImpact *
            inventoryExposure *
            pin) / FEE_DIVISOR;

        console.log("---- Results of fee calculation ----");
        console.log("feeIncreasePips", feeIncreasePips);
        console.log("minFee", minFee);
        console.log("expectedPriceImpact", expectedPriceImpact);
        console.log("inventoryExposure", inventoryExposure);
        console.log("pin", pin);

        return uint24(minFee + feeIncreasePips);
    }

    function calculatePriceImpactAfterSwap(
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96After
    ) internal pure returns (uint256 priceImpactPips) {
        
        // technically this should never be 0
        if (sqrtPriceX96Before == 0) return 0;

        uint256 priceChange = sqrtPriceX96Before < sqrtPriceX96After
            ? sqrtPriceX96After - sqrtPriceX96Before
            : sqrtPriceX96Before - sqrtPriceX96After;

        // Return price impact as a percentage scaled by PIPS_SCALE (1e6)
        priceImpactPips = (priceChange * PIPS_SCALE) / sqrtPriceX96Before;
    }

    /**
     * @dev Updates the running average Illiquidity ratio based on the last trade
     * @param data pool data storage pointer
     * @param lastTradePriceImpact price impact of the last trade scaled by PIPS_SCALE
     * @param lastTradeVolume volume of the last trade in token1 terms
     */
    function updateILLIQ(
        PoolData storage data,
        uint256 lastTradePriceImpact,
        uint256 lastTradeVolume
    ) internal {
        // TODO #1
        if (lastTradeVolume > 0) {
            uint256 currentILLIQ = (lastTradePriceImpact * ILLIQ_SCALE) /
                lastTradeVolume;

            if (data.tradeCount == 0) {
                data.avgILLIQ = currentILLIQ;
            } else {
                data.avgILLIQ = (data.avgILLIQ * data.tradeCount + currentILLIQ) / (data.tradeCount + 1);
            }
            data.tradeCount += 1;
        } else {
            return;
        }
    }

    /*
    ------ INTERNAL HELPER FUNCTIONS ------
    */

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function normalizeInventoryDecimals(PoolData storage data) internal view returns (Inventory memory) {
        uint8 scalingFactor = uint8(abs(data.deltaDecimals));

        if (data.deltaDecimals < 0) { // token0: 6 - token1: 18 = -12, therefore token0 must be scaled up
            return Inventory({
                token0: data.inventory.token0 * (10 ** scalingFactor),
                token1: data.inventory.token1
            });
        } else if (data.deltaDecimals > 0) { // token0: 18 - token1: 6 = 12, therefore token1 must be scaled up
            return Inventory({
                token0: data.inventory.token0,
                token1: data.inventory.token1 * (10 ** scalingFactor)
            });
        } else {
            return Inventory({
                token0: data.inventory.token0,
                token1: data.inventory.token1
            });
        }
    }

    function convertToken0ToToken1(uint256 token0Amount, uint160 sqrtPriceX96, int8 deltaDecimals) internal pure returns (uint256) {
        require(sqrtPriceX96 > 0, "sqrtPriceX96 must be greater than 0");

        uint256 normalizedToken0Amount = scaleDecimalsUp(token0Amount, deltaDecimals, false);
        
        return FullMath.mulDiv(
            FullMath.mulDiv(
                normalizedToken0Amount, 
                sqrtPriceX96, 
                FixedPoint96.Q96
            ),
            sqrtPriceX96, 
            FixedPoint96.Q96
        );
    }

    /**
     * @dev Scale decimals up to the highest precision between token0 and token1
     * @param amount amount of the token
     * @param deltaDecimals difference in decimals between token0 and token1
     * @param isToken1 true if token1 is the base token, false if token0 is the base token
     * @return normalized amount
     */
    function scaleDecimalsUp(uint256 amount, int8 deltaDecimals, bool isToken1) internal pure returns (uint256) {
        if (deltaDecimals == 0) return amount;
        
        uint8 scalingFactor = uint8(abs(deltaDecimals));

        if (deltaDecimals < 0) {
            return isToken1 ? amount : amount * (10 ** scalingFactor);
        } else if (deltaDecimals > 0) {
            return isToken1 ? amount * (10 ** scalingFactor) : amount;
        }
    }

    /*
    ------ ARB HELPER FUNCTIONS ------ 
    */

    function detectAndExecuteArb(
        PoolKey memory key,
        PoolKey memory arbKey,
        uint256 amount,
        bool zeroForOne
    ) internal returns (uint256) {
        Quote memory hookPoolQuote;
        Quote memory arbPoolQuote;

        // quote hook pool (Pool A)
        IV4Quoter.QuoteExactSingleParams memory hookParams = IV4Quoter.QuoteExactSingleParams({
            poolKey: key,
            zeroForOne: !zeroForOne,
            exactAmount: uint128(amount),
            hookData: ""
        });
        (uint256 amountOut, uint256 gasEstimate) = quoter.quoteExactInputSingle(hookParams);
        
        hookPoolQuote = Quote({
            amountOut: amountOut,
            gasEstimate: gasEstimate
        });

        // quote arb pool (Pool B)
        IV4Quoter.QuoteExactSingleParams memory arbParams = IV4Quoter.QuoteExactSingleParams({
            poolKey: arbKey,
            zeroForOne: zeroForOne,
            exactAmount: uint128(hookPoolQuote.amountOut),
            hookData: ""
        });
        (uint256 arbAmountOut, uint256 arbGasEstimate) = quoter.quoteExactInputSingle(arbParams);

        // profit is calculated in token1 terms for zeroForOne = true
        // profit is calculated in token0 terms for zeroForOne = false
        // quote A input - quote B output = arb profit
        uint256 grossArbProfit = arbPoolQuote.amountOut - amount;
        uint256 gasCostWei = (arbPoolQuote.gasEstimate + hookPoolQuote.gasEstimate) * tx.gasprice;
        uint256 gasCostInProfitToken = getGasCostInQuoteToken(gasCostWei);

        uint256 netArbProfit = grossArbProfit - gasCostInProfitToken;
        if (netArbProfit > 0) {
            // TODO complete arb swap logic

            // set swap params A
            SwapParams memory swapAParams = SwapParams({
                zeroForOne: !zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: 0 // TODO
            });
            
            // swap A
            BalanceDelta swapDeltaA = poolManager.swap(key, swapAParams, "");

            // swap params B
            SwapParams memory swapBParams = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(zeroForOne ? swapDeltaA.amount0() : swapDeltaA.amount1()),
                sqrtPriceLimitX96: 0 // TODO
            });


            // swap B
            BalanceDelta swapDeltaB = poolManager.swap(arbKey, swapBParams, "");

            uint256 finalProfit = zeroForOne ?
                uint256(int256(swapDeltaB.amount1()) + int256(amount)) :
                uint256(int256(swapDeltaB.amount0()) + int256(amount));

            return finalProfit;
        }
        return 0;
    }

    function calcArbAmount(
        PoolKey memory key,
        uint160 currentPriceX96,
        uint160 targetPriceX96
    ) internal view returns (uint256) {
        // Use the actual AMM math to find exact amount needed
        uint128 liquidity = poolManager.getLiquidity(key.toId());

        // Calculate amount needed to reach target price based on trade direction
        uint256 exactAmount;
        if (currentPriceX96 > targetPriceX96) {
            exactAmount = SqrtPriceMath.getAmount1Delta(
                currentPriceX96,
                targetPriceX96,
                liquidity,
                true
            );
        } else {
            exactAmount = SqrtPriceMath.getAmount0Delta(
                currentPriceX96,
                targetPriceX96,
                liquidity,
                true
            );
        }
        return (exactAmount * 90) / 100;
    }

    function getGasCostInQuoteToken(uint256) public pure returns (uint256) {
        return 0; // TODO
    }

    /*
    ------ HOOK CONFIGURATION ------
    */

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /*
    ------ HOOK MANAGEMENT FUNCTIONS ------
    */

   /**
     * @dev Configures the pool's quote asset and arb pool
     * @param poolId main pool id
     * @param useToken1AsQuote Whether to use token1 as the quote asset
     * @param key main pool key
     * @param arbKey arb pool key
     */
    function configurePool(
        PoolId poolId, 
        bool useToken1AsQuote,
        PoolKey calldata key,
        PoolKey calldata arbKey
    ) external onlyCreator(poolId){
        PoolData storage data = poolData[poolId];
        require(!data.isConfigured, "Pool already configured");
        require(key.currency0 == arbKey.currency0 && key.currency1 == arbKey.currency1, "Arb pool must have same currency pair as the main pool");
    
        // set quote asset
        data.useToken1AsQuote = useToken1AsQuote;

        // set arb pool
        arbPoolKey[poolId] = arbKey;

        // set PIN bucket size
        data.isConfigured = true;
        emit PoolConfigured(poolId, useToken1AsQuote, arbKey);
    }

    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        owner = newOwner;
    }

    function transferPoolOwner(PoolId poolId, address newOwner) external onlyCreator(poolId) {
        poolCreator[poolId] = newOwner;
    }

    // Allows owner to update min fee
    function updateMinFee(PoolId poolId, uint24 newMinFee) external onlyOwner {
        PoolData storage data = poolData[poolId];
        if (newMinFee <= 0 || newMinFee >= LPFeeLibrary.MAX_LP_FEE - 1)
            revert InvalidFee();

        data.minFee = newMinFee;
    }
}
