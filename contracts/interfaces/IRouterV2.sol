// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IRouterV2 {
    // Definition of the route structure as used in the contract
    struct route {
        address from;
        address to;
        bool stable;
    }

    // **** ADD LIQUIDITY ****
    
    // **** REMOVE LIQUIDITY ****
    
    // **** SWAP ****
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    
    // **** SWAP (supporting fee-on-transfer tokens) ****
}
