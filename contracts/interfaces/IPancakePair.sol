// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.5.0;

interface IPancakePair {
    function decimals() external pure returns (uint8);
    function token0() external view returns (address);
    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}
