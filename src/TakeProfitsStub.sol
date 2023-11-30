// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {TakeProfitsHook} from "./TakeProfitsHook.sol";

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

contract TakeProfitsStub is TakeProfitsHook {
    constructor(
        IPoolManager _poolManager,
        TakeProfitsHook addressToEtch
    ) TakeProfitsHook(_poolManager, "") {}

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}