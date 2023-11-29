// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for IPoolManager.PoolKey;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    // This is the LIMIT ORDER.... specify the pool, the tick where you trade, which asset, and the amount
    // Technically speaking, the limit orders are combined under AMOUNT. The ERC-1155 receipt is what gives you ownership over a part of that amount
    // zeroForOne is sell tokenZero for tokenOne
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public
        takeProfitPositions;

    // ERC-1155 State
    // stores whether a give tokenId (i.e. take profit order) exists
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    // stores how many swapped tokens are claimable for a give trade
    mapping(uint256 tokenId => claimable ) public tokenIdClaimable;
    // stores how many tokens need to be sold to execute the trade
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // stores the data for a given tokenId
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialized: false,
            afterInitialized: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // Hooks
    function afterInitialize(address, IPoolManager.Poolkey calldata key, uint160, int24 tick) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    // Note - With a limit order, we mint them an ERC-1155 token. it acts like a receipt of the order, that you can come claim later
    // ERC-1155 helpers
    function getTokenId(PoolId poolId, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(poolId, tick, zeroForOne)));
    }

    // Helper functions
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    // DK - I don't understand this function at all. Why do we calculate intervals then just reverse it? I tcould be because of the negative if statement
    // But I don't get that part either. He is saying when it is negative, you need to add another -1 value to the intervals. But why?
    function _getTickLower(int24 actualTick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;

        if (actualTick < 0 && (actualTick % tickSpacing) != 0) {
            intervals--;
        }

        return intervals * tickSpacing;
    }
}
