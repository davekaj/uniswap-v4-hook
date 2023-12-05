// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol"; // Represents the price quote when trying to do a swap
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    // This is the LIMIT ORDER.... specify the pool, the tick where you trade, which asset, and the amount
    // Technically speaking, the limit orders are combined under AMOUNT. The ERC-1155 receipt is what gives you ownership over a part of that amount
    // zeroForOne is sell tokenZero for tokenOne (making token1 more expensive)
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public
        takeProfitPositions;

    // ERC-1155 State
    // stores whether a give tokenID (i.e. take profit order) exists
    mapping(uint256 tokenID => bool exists) public tokenIdExists;
    // stores how many swapped tokens are claimable for a give trade
    mapping(uint256 tokenID => uint256 claimable) public tokenIdClaimable;
    // stores how many tokens need to be sold to execute the trade
    mapping(uint256 tokenID => uint256 supply) public tokenIdTotalSupply;
    // stores the data for a given tokenID
    mapping(uint256 tokenID => TokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // Hooks
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    // Why do the limit order in after swap? Because we can look at the new price and tick
    // We compare it to the last known tick that we have and check if price/tick when up or down
    // If up, the price of token0 has increased
    // THEN we search for any open orders on those ticks. If there are, we simply call fillOrder()
    // Note - orders can only happen at tick changes / intervals
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        int24 lastTickLower = tickLowerLasts[key.toId()]; // the last stored tick value IN THE HOOK
        // the current tick IN POOL MANAGER
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing); // the tick now

        bool swapZeroForOne = !params.zeroForOne;
        int256 swapAmountIn;

        // Tick has increased i.e. price of token 0 has increased
        if (lastTickLower < currentTickLower) {
            // Looping in case multiple ticks have passed
            for (int24 tick = lastTickLower; tick < currentTickLower;) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];
                if (swapAmountIn > 0) {
                    _fillOrder(key, tick, swapZeroForOne, swapAmountIn, hookData);
                }
                tick += key.tickSpacing;
            }

            // Tick has decreased i.e. price of token 0 has decreased
        } else if (lastTickLower > currentTickLower) {
            // if equal is ignored as nothing needs to be done
            for (int24 tick = lastTickLower; tick > currentTickLower;) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];
                if (swapAmountIn > 0) {
                    _fillOrder(key, tick, swapZeroForOne, swapAmountIn, hookData);
                }
                tick -= key.tickSpacing;
            }
        }
        tickLowerLasts[key.toId()] = currentTickLower;
        return TakeProfitsHook.afterSwap.selector;
    }

    // Core utilities
    function placeOrder(PoolKey calldata key, int24 tick, uint256 amountIn, bool zeroForOne) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(amountIn);
        uint256 tokenID = getTokenID(key, tickLower, zeroForOne);

        if (!tokenIdExists[tokenID]) {
            tokenIdExists[tokenID] = true;
            tokenIdData[tokenID] = TokenData(key, tickLower, zeroForOne);
        }

        _mint(msg.sender, tokenID, amountIn, ""); // erc-1155 always equal to exact token amount
        tokenIdTotalSupply[tokenID] += amountIn;

        address tokenToBeSoldContract = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(tokenToBeSoldContract).transferFrom(msg.sender, address(this), amountIn);
        return tickLower;
    }

    function cancelOrder(PoolKey calldata key, int24 tick, bool zeroForOne) external {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        uint256 tokenID = getTokenID(key, tickLower, zeroForOne);

        // balanceOf is coming from ERC-1155
        uint256 amountIn = balanceOf(msg.sender, tokenID);
        require(amountIn > 0, "TakeProfitsHook: No orders to cancel");

        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(amountIn);
        tokenIdTotalSupply[tokenID] -= amountIn;
        _burn(msg.sender, tokenID, amountIn);

        address tokensToBeSoldContract = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(tokensToBeSoldContract).transfer(msg.sender, amountIn);
    }

    // @dev Called on afterSwap()
    // Since there is a single contract that manages all the pools, we need to go get a LOCK on the pool manager in order to do that
    // Then give it a callback
    function _fillOrder(PoolKey calldata key, int24 tick, bool zeroForOne, int256 amountIn, bytes calldata hookData)
        internal
    {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta =
            abi.decode(poolManager.lock(abi.encodeCall(this.handleSwap, (key, swapParams, hookData))), (BalanceDelta));

        takeProfitPositions[key.toId()][tick][zeroForOne] -= amountIn;
        uint256 tokenID = getTokenID(key, tick, zeroForOne);
        uint256 amountOfTokensReceivedFromSwap =
            zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        tokenIdClaimable[tokenID] += amountOfTokensReceivedFromSwap;
    }

    function redeem(uint256 tokenID, uint256 amountIn, address destination) external {
        require(tokenIdClaimable[tokenID] > 0, "TakeProfitsHook - No tokens to redeem");

        uint256 balance = balanceOf(msg.sender, tokenID);
        require(balance >= amountIn, "TakeProfitsHook - Not enough ERC-1155 tokens to redeem requested amount");

        TokenData memory tokenData = tokenIdData[tokenID];
        address tokenToSend = tokenData.zeroForOne
            ? Currency.unwrap(tokenData.poolKey.currency1)
            : Currency.unwrap(tokenData.poolKey.currency0);

        // multiple people could have added tokens to the same order, so we need to calculate the amount to send
        // total supply = total amount of tokens that were part of the order to be sold
        // therefore, users's share = (amountIn / total supply)
        // therefore, amount to send to user = (users share * total claimable)
        // amountToSend = amountIn * (total claimable / total supply)
        // We use fixedpointmathlib.muldivdown to avoid rounding errors
        uint256 amountToSend = amountIn.mulDivDown(tokenIdClaimable[tokenID], tokenIdTotalSupply[tokenID]);

        tokenIdClaimable[tokenID] -= amountToSend;
        tokenIdTotalSupply[tokenID] -= amountIn;
        _burn(msg.sender, tokenID, amountIn);
        IERC20(tokenToSend).transfer(destination, amountToSend);
    }

    function handleSwap(PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        BalanceDelta delta = poolManager.swap(key, params, hookData);

        if (params.zeroForOne) {
            // DK - I believe we do 2 here, in case of slippage, sometimes you will get some of your tokens back
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint128(delta.amount0()));
                poolManager.settle(key.currency0);
            }
            if (delta.amount1() < 0) {
                poolManager.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        } else {
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint128(delta.amount1()));
                poolManager.settle(key.currency1);
            }
            if (delta.amount0() < 0) {
                poolManager.take(key.currency0, address(this), uint128(-delta.amount0()));
            }
        }

        return delta;
    }

    // Note - With a limit order, we mint them an ERC-1155 token. it acts like a receipt of the order, that you can come claim later
    // ERC-1155 helpers
    function getTokenID(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tick, zeroForOne)));
    }

    // Helper functions
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;

        // DK - Not exactly clear why this is needed, but I get in generally
        if (actualTick < 0 && (actualTick % tickSpacing) != 0) {
            intervals--;
        }

        return intervals * tickSpacing;
    }
}
