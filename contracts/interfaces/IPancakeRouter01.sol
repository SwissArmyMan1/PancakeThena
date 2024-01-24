// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.2;

interface IPancakeRouter01 {

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

}
