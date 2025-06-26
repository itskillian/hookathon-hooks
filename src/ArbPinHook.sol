// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
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
import {SafeCurrencyMetadata} from "v4-periphery/src/libraries/SafeCurrencyMetadata.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {QuoterRevertPrice} from "./QuoterRevertPrice.sol";
import {Locker} from "v4-periphery/src/libraries/Locker.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract ArbPinHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using QuoterRevertPrice for *;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant PIPS_SCALE = 1e6;
    uint256 private constant ILLIQ_SCALE = 1e18;
    uint256 private constant FEE_DIVISOR = 1e38;
    uint256 private constant ARB_QUOTE_COUNT = 3;

    event PoolConfigured(PoolId indexed poolId, bool useToken1AsQuote, PoolKey arbPoolKey);

    error MustUseDynamicFee();
    error Unauthorized();
    error InvalidTimeDecay();
    error InvalidFee();
    error NegativeArbProfit(uint256 inputAmount, uint256 outputAmount);
    error NotSelf();

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
        uint256 avgIlliq; // token1
        uint256 lastIlliq; // token1
        uint256 lastIlliqArb; // token1 (arb pool)
        uint256 swapCount; // number of swaps used in ILLIQ average
        Inventory inventory;
        uint256 tvl; // token 1
    }

    struct Quote {
        uint256 amountOut;
        uint256 gasEstimate;
        uint160 finalSqrtPriceX96;
    }

    struct ArbQuoteResult {
        uint256 inputAmount;
        bool arbZeroForOne;
        uint256 grossProfit;
        uint160 finalSqrtPriceX96;
        uint160 finalSqrtPriceX96Arb;
        uint256 gasEstimate;
    }

    // state variables
    address public owner;
    bool private _executingArb;
    uint160 private _tempSqrtPriceX96;

    mapping(PoolId => PoolData) public poolData; // main poolId -> pool data
    mapping(PoolId => PoolKey) public arbPoolKey; // main poolId -> arb pool key
    mapping(PoolId => address) public poolCreator; // main poolId -> pool creator

    // constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
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

    modifier setMsgSender() {
        Locker.set(msg.sender);
        _; // execute the function
        Locker.set(address(0)); // reset the locker
    }

    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
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
        if (data.totalVolume == 0 || data.swapCount == 0) {
            console.log("First swap detected - using default fee");
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                data.minFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }
        
        uint256 nextSwapVolToken1 = estimateNextSwapVolume(params, data.sqrtPriceX96Before, data.deltaDecimals);

        int256 pin = calculatePIN(data.totalVolume, data.netVolume, params.zeroForOne, nextSwapVolToken1);

        uint256 expectedPriceImpact = estimatePriceImpactBeforeSwap(data.lastIlliq, nextSwapVolToken1);

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

        // update pool state
		uint256 lastSwapAmount1 = uint256(abs(delta.amount1()));
        (data.sqrtPriceX96After, , , ) = poolManager.getSlot0(poolId);
        data.totalVolume += lastSwapAmount1;
        data.netVolume -= int256(delta.amount1());
        data.inventory.token0 = uint256(int256(data.inventory.token0) - delta.amount0());
        data.inventory.token1 = uint256(int256(data.inventory.token1) - delta.amount1());

        // calc price impact and illiq of last swap
        uint256 lastSwapPriceImpact = calculatePriceImpact(data.sqrtPriceX96Before, data.sqrtPriceX96After);

        uint256 lastSwapIlliq = calculateIlliq(lastSwapPriceImpact, lastSwapAmount1);

        // update illiq average and swap count
        data.avgIlliq = calculateAvgIlliq(lastSwapIlliq, data.avgIlliq, data.swapCount);
        data.swapCount += 1;

        // ------ ARB LOGIC ------
        // if (msg.sender == address(quoter)) { // fix this because we dont use the quoter anymore
        //     return (BaseHook.afterSwap.selector, 0);
        // }

        {
            (uint160 sqrtPriceX96Arb, , , ) = poolManager.getSlot0(arbPoolKey[poolId].toId());

            if (!_executingArb) {
                console.log("beginning arb logic");
                _executingArb = true;
                uint256 netArbProfit;
                
                // calc arb opportunity
                ArbQuoteResult memory arbQuoteResult = detectArb(data.sqrtPriceX96After, sqrtPriceX96Arb, lastSwapIlliq, data.lastIlliqArb, key);
                
                // calc arb profit
                if (arbQuoteResult.grossProfit > 0) {
                    // we have an arb
                    netArbProfit = calculateArbNetProfit(arbQuoteResult.grossProfit, arbQuoteResult.gasEstimate, arbQuoteResult.finalSqrtPriceX96, arbQuoteResult.arbZeroForOne, data.deltaDecimals);
                }
                
                // calc
                (uint256 priceDeltaChangePips, bool improved) = calculatePoolPriceDelta(data.sqrtPriceX96After, arbQuoteResult.finalSqrtPriceX96, sqrtPriceX96Arb, arbQuoteResult.finalSqrtPriceX96Arb);

                // caveman calc final price midpoint (not for production) to use for swap limit
                uint160 finalPriceMidpoint = (arbQuoteResult.finalSqrtPriceX96 + arbQuoteResult.finalSqrtPriceX96Arb) / 2;

                // caveman check to see if we improved the pool state (not for production)
                if (!improved || netArbProfit <= 0) {                    
                    return (BaseHook.afterSwap.selector, 0);
                } else if (netArbProfit > 0) {
                    (uint256 profitToken0, uint256 profitToken1) = executeArb(key, arbPoolKey[poolId], arbQuoteResult.inputAmount, arbQuoteResult.arbZeroForOne, finalPriceMidpoint);
                }

                _executingArb = false; // Reset flag after arb
            }
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
    ---------- HELPER FUNCTIONS ----------
    */
    
    /**
     * @dev all variables are in token1 terms to stay consistent with price
     * illiq is scaled by (1e6)
     */
    function calculateIlliq(
        uint256 priceImpactPips,
        uint256 volume
    ) internal pure returns (uint256) {
        return (priceImpactPips * ILLIQ_SCALE) / volume;
    }

    /**
     * @dev all variables are in token1 terms to stay consistent with price
     * illiq is scaled by (1e6)
     */
    function calculateAvgIlliq(
        uint256 lastIlliq,
        uint256 avgIlliq,
        uint256 swapCount
    ) internal pure returns (uint256) {
        return (avgIlliq * swapCount + lastIlliq) / (swapCount + 1);
    }
    
    /*
    ---------- PIN FUNCTIONS ----------
    */

    /**
     * @notice simple estimate of the next swap volume in token1 terms
     * @dev used in _beforeSwap to calculate PIN
     */
    function estimateNextSwapVolume(
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

    // TODO
    function calculatePIN(
        uint256 totalVolume,
        int256 netVolume,
        bool zeroForOne,
        uint256 nextSwapVolToken1
    ) internal pure returns (int256 pin) {
        uint256 tempTotalVolume = totalVolume + nextSwapVolToken1;

        
        if (tempTotalVolume > 0) {
            int256 tempNetVolume = netVolume +
                (
                    zeroForOne
                        ? -int256(nextSwapVolToken1)
                        : int256(nextSwapVolToken1)
                );

            pin = tempNetVolume * int256(PRECISION) / int256(tempTotalVolume);
        } else {
            // NOTE #3
            pin = 0;
        }
    }

    /**
     * @dev Estimate the expected price impact of the next swap before swap
     * @param lastIlliq last swap illiq
     * @param nextSwapVolToken1 next swap volume in token1 terms
     * @return expectedPriceImpact expected price impact of the next swap scaled by PIPS_SCALE (1e6)
     */
    function estimatePriceImpactBeforeSwap(
        uint256 lastIlliq,
        uint256 nextSwapVolToken1
    ) internal pure returns (uint256 expectedPriceImpact) {
        // check for previous swap data
        if (lastIlliq == 0 || nextSwapVolToken1 == 0) {
            return 0;
        }

        expectedPriceImpact = (lastIlliq * nextSwapVolToken1) / (1e6 * PRECISION);
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
    
    /**
     * @dev Calculate the price impact of the last swap
     * @param sqrtPriceX96Before price before swap
     * @param sqrtPriceX96After price after swap
     * @return priceImpactPips price impact of the last swap scaled by PIPS_SCALE (1e6)
     */
    function calculatePriceImpact(
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

    /*
        ---------- ARB HELPER FUNCTIONS ----------
    */

    /// @notice determines direction, arb input amount and opportunity of arbitrage
    /// uses illiq to calculate input amount needed to bring both pools to equal price or as close as possible
    function detectArb(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceX96Arb,
        uint256 tempIlliq,
        uint256 tempIlliqArb,
        PoolKey calldata key
    ) internal returns (ArbQuoteResult memory bestArbQuoteResult) {
        PoolId poolId = key.toId();
        
        // direction of 1st arb swap in our pool
        bestArbQuoteResult.arbZeroForOne = sqrtPriceX96 > sqrtPriceX96Arb;

        // loop ARB_QUOTE_COUNT times
        for (uint256 i = 0; i < ARB_QUOTE_COUNT; i++) {
            {
                // estimate input amount for hook pool arb swap
                uint256 arbInputAmount = estimateArbInput(sqrtPriceX96, sqrtPriceX96Arb, tempIlliq, tempIlliqArb, bestArbQuoteResult.arbZeroForOne);

                IV4Quoter.QuoteExactSingleParams memory quoteParams = IV4Quoter.QuoteExactSingleParams({
                    poolKey: key,
                    zeroForOne: bestArbQuoteResult.arbZeroForOne,
                    exactAmount: uint128(arbInputAmount),
                    hookData: ""
                });
                // quote hook pool
                Quote memory quoteA = this.quoteExactInputSingleReturnPrice(quoteParams);

                IV4Quoter.QuoteExactSingleParams memory arbQuoteParams = IV4Quoter.QuoteExactSingleParams({
                    poolKey: arbPoolKey[poolId],
                    zeroForOne: !bestArbQuoteResult.arbZeroForOne,
                    exactAmount: uint128(quoteA.amountOut),
                    hookData: ""
                });
                // quote arb pool
                Quote memory quoteB = this.quoteExactInputSingleReturnPrice(arbQuoteParams);

                // check profitability
                if (quoteB.amountOut > arbInputAmount) {
                    // we have an arb
                    uint256 tempGrossProfit = quoteB.amountOut - arbInputAmount;
                    if (tempGrossProfit > bestArbQuoteResult.grossProfit) {
                        bestArbQuoteResult.grossProfit = tempGrossProfit;
                        bestArbQuoteResult.inputAmount = arbInputAmount;
                        bestArbQuoteResult.finalSqrtPriceX96 = quoteA.finalSqrtPriceX96;
                        bestArbQuoteResult.finalSqrtPriceX96Arb = quoteB.finalSqrtPriceX96;
                        bestArbQuoteResult.gasEstimate = quoteA.gasEstimate + quoteB.gasEstimate;
                    }
                }

                // note 5

                // update illiq values using token1 values
                tempIlliq = calculateIlliq(
                    calculatePriceImpact(sqrtPriceX96, quoteA.finalSqrtPriceX96),
                    bestArbQuoteResult.arbZeroForOne ? quoteA.amountOut : arbInputAmount
                );

                tempIlliqArb = calculateIlliq(
                    calculatePriceImpact(sqrtPriceX96Arb, quoteB.finalSqrtPriceX96),
                    bestArbQuoteResult.arbZeroForOne ? quoteB.amountOut : quoteA.amountOut
                );
                // go loop again
            }
        }

        return ArbQuoteResult({
            inputAmount: bestArbQuoteResult.inputAmount,
            arbZeroForOne: bestArbQuoteResult.arbZeroForOne,
            grossProfit: bestArbQuoteResult.grossProfit,
            finalSqrtPriceX96: bestArbQuoteResult.finalSqrtPriceX96,
            finalSqrtPriceX96Arb: bestArbQuoteResult.finalSqrtPriceX96Arb,
            gasEstimate: bestArbQuoteResult.gasEstimate
        });
    }

    /// @dev Estimate the input amount for the first arb swap in the hook pool, so that the hook pool and arb pool prices are equal
    function estimateArbInput(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceX96Arb,
        uint256 lastIlliq,
        uint256 lastIlliqArb,
        bool arbZeroForOne
    ) internal pure returns (uint256 arbInputAmount) {
        if (sqrtPriceX96 == 0 || sqrtPriceX96Arb == 0) {
            return 0;
        } else if (lastIlliq > 0 && lastIlliqArb == 0) {
            lastIlliqArb = lastIlliq;
        } else if (lastIlliq == 0) {
            console.log("lastIlliq is 0, returning 0");
            return 0;
        }

        // convert all to int256
        int256 sqrtPriceX96Int = int256(uint256(sqrtPriceX96));
        int256 sqrtPriceX96ArbInt = int256(uint256(sqrtPriceX96Arb));
        int256 lastIlliqInt = int256(lastIlliq);
        int256 lastIlliqArbInt = int256(lastIlliqArb);


        int256 a;
        int256 b;
        int256 c;

        // fix this, overflow hell
        if (arbZeroForOne) { // 'selling' token0 pushes price down in pool a
            a = sqrtPriceX96Int * sqrtPriceX96Int * sqrtPriceX96ArbInt * lastIlliqInt * lastIlliqArbInt;
            b = -(sqrtPriceX96Int * sqrtPriceX96ArbInt * lastIlliqArbInt + sqrtPriceX96Int * sqrtPriceX96Int * lastIlliqInt);
            c = sqrtPriceX96Int - sqrtPriceX96ArbInt;
        } else {
            a = sqrtPriceX96Int * sqrtPriceX96Int * lastIlliqInt * lastIlliqInt;
            b = 2 * sqrtPriceX96Int * sqrtPriceX96Int * lastIlliqInt + sqrtPriceX96ArbInt * sqrtPriceX96ArbInt * lastIlliqArbInt - sqrtPriceX96Int * sqrtPriceX96ArbInt * lastIlliqInt;
            c = sqrtPriceX96Int * sqrtPriceX96Int - sqrtPriceX96Int * sqrtPriceX96ArbInt;
        }

        arbInputAmount = uint256((-b + int256(Math.sqrt(uint256(b*b - 4*a*c)))) / (2*a));
    }

    function quoteExactInputSingleReturnPrice(IV4Quoter.QuoteExactSingleParams memory quoteParams) external setMsgSender returns (Quote memory quote) {
        uint256 gasBefore = gasleft();
        try this._quoteExactInputSingleReturnPrice(quoteParams) {}
        catch (bytes memory reason) {
            quote.gasEstimate = gasBefore - gasleft();
            // Extract the quote from QuoteSwap error, or throw if the quote failed
            (quote.amountOut, quote.finalSqrtPriceX96) = reason.parseQuoteAmountAndPrice();
        }
    }
    
    function _quoteExactInputSingleReturnPrice(IV4Quoter.QuoteExactSingleParams calldata quoteParams) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta = poolManager.swap(
            quoteParams.poolKey,
            SwapParams({
                zeroForOne: quoteParams.zeroForOne,
                amountSpecified: int256(uint256(quoteParams.exactAmount)),
                sqrtPriceLimitX96: quoteParams.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            quoteParams.hookData
        );

        // might not be needed due to arbitrage
        // int128 amountSpecifiedActual = (zeroForOne == (amountSpecified < 0)) ? swapDelta.amount0() : swapDelta.amount1();
        // if (amountSpecifiedActual != amountSpecified) {
        //     revert NotEnoughLiquidity(poolKey.toId());
        // }

        (uint160 finalSqrtPriceX96, , , ) = poolManager.getSlot0(quoteParams.poolKey.toId());
        // backup solution if revert doesnt work, check both
        _tempSqrtPriceX96 = finalSqrtPriceX96;
        
        // the output delta of a swap is positive
        uint256 amountOut = quoteParams.zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
        QuoterRevertPrice.revertQuoteWithPrice(amountOut, finalSqrtPriceX96);
    }

    function calculateArbNetProfit(uint256 grossProfit, uint256 totalGasEstimate, uint160 finalSqrtPriceX96, bool arbZeroForOne, int8 deltaDecimals) internal view returns (uint256) {
        // gas calcs
        uint256 gasCostEth = (totalGasEstimate) * tx.gasprice / 1e18;

        uint256 gasCostToken1 = convertToken0ToToken1(gasCostEth, finalSqrtPriceX96, deltaDecimals);

        uint256 gasCostInProfitToken = !arbZeroForOne ? gasCostToken1 : gasCostEth;
        if (grossProfit >= gasCostInProfitToken) {
            return grossProfit - gasCostInProfitToken;
        } else {
            return 0;
        }
    }

    function calculatePoolPriceDelta(
        uint160 sqrtPriceX96,
        uint160 finalSqrtPriceX96,
        uint160 sqrtPriceX96Arb,
        uint160 finalSqrtPriceX96Arb
    ) internal pure returns (uint256, bool) {
        // before arb delta
        uint256 originalDelta = (sqrtPriceX96 > sqrtPriceX96Arb) ?
            sqrtPriceX96 - sqrtPriceX96Arb :
            sqrtPriceX96Arb - sqrtPriceX96;
        uint256 originalDeltaPips = (originalDelta * 1e4) / sqrtPriceX96;

        // after arb delta
        uint256 newDelta = (finalSqrtPriceX96 > finalSqrtPriceX96Arb) ?
            finalSqrtPriceX96 - finalSqrtPriceX96Arb :
            finalSqrtPriceX96Arb - finalSqrtPriceX96;
        uint256 newDeltaPips = (newDelta * 1e4) / finalSqrtPriceX96;
        
        // calc change in price delta in pips
        bool improved = newDeltaPips < originalDeltaPips;
        uint256 priceDeltaChangePips = improved ? 
            originalDeltaPips - newDeltaPips :
            newDeltaPips - originalDeltaPips; 

        return (priceDeltaChangePips, improved);
    }

    function executeArb(
        PoolKey calldata key,
        PoolKey storage arbKey,
        uint256 inputAmount,
        bool arbZeroForOne,
        uint160 finalPriceMidpoint
    ) internal returns (uint256, uint256) {
        // set swap params A (exact input)
        SwapParams memory swapAParams = SwapParams({
            zeroForOne: arbZeroForOne,
            amountSpecified: int256(inputAmount), // positive for exact input
            sqrtPriceLimitX96: arbZeroForOne ? 
                uint160(Math.max(finalPriceMidpoint, TickMath.MIN_SQRT_PRICE + 1)) :
                uint160(Math.min(finalPriceMidpoint, TickMath.MAX_SQRT_PRICE - 1))
        });
        
        // swap A
        BalanceDelta swapDeltaA = poolManager.swap(key, swapAParams, "");
        
        // Get the output amount from swap A (this becomes input for swap B)
        int256 swapBInputAmount = arbZeroForOne ?
            int256(abs(swapDeltaA.amount1())) : // amount1 is negative output
            int256(abs(swapDeltaA.amount0())); // amount0 is negative output

        // swap params B (exact input with the output from swap A)
        SwapParams memory swapBParams = SwapParams({
            zeroForOne: !arbZeroForOne,
            amountSpecified: swapBInputAmount, // positive for exact input
            sqrtPriceLimitX96: !arbZeroForOne ? 
                uint160(Math.min(finalPriceMidpoint, TickMath.MAX_SQRT_PRICE - 1)) :
                uint160(Math.max(finalPriceMidpoint, TickMath.MIN_SQRT_PRICE + 1))
        });
        
        // swap B
        BalanceDelta swapDeltaB = poolManager.swap(arbKey, swapBParams, "");
        
        int256 netDelta0 = swapDeltaA.amount0() + swapDeltaB.amount0();
        int256 netDelta1 = swapDeltaA.amount1() + swapDeltaB.amount1();
        uint256 profitToken0;
        uint256 profitToken1;
        
        if (netDelta0 < 0) {
            _settle(key.currency0, uint256(-netDelta0));
        } else if (netDelta0 > 0) {
            profitToken0 = uint256(netDelta0);
            poolManager.take(key.currency0, address(this), uint256(profitToken0));
        }
        if (netDelta1 < 0) {
            _settle(key.currency1, uint256(-netDelta1));
        } else if (netDelta1 > 0) {
            profitToken1 = uint256(netDelta1);
            poolManager.take(key.currency1, address(this), uint256(profitToken1));
        }

        // Profit = what we got back - what we put in
        if (profitToken0 > 0 || profitToken1 > 0) {
            return (profitToken0, profitToken1);
        } else {
            return (0, 0);
        }
    }

    function _settle(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(address(this), address(poolManager), amount);
            poolManager.settle();
        }
    }
}
