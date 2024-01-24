// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IPair {
    function tokens() external view returns (address, address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint _reserve0, uint _reserve1, uint _blockTimestampLast);
    function getAmountOut(uint, address) external view returns (uint);
    function decimals() external view returns (uint8);
    function isStable() external view returns(bool);
}
