// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./interfaces/IFactory.sol";
import "./Pool.sol";

contract Factory is IFactory {
    mapping(address => mapping(address => address[])) public pools;

    Parameters public override parameters;

    function sortToken(
        address tokenA,
        address tokenB
    ) private pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint32 index
    ) external view override returns (address) {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "ZERO_ADDRESS");

        // Declare token0 and token1
        address token0;
        address token1;

        (token0, token1) = sortToken(tokenA, tokenB);

        return pools[tokenA][tokenB][index];
    }

    function createPool(
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee
    ) external override returns (address pool) {
        require(token0 != token1, "IDENTICAL_ADDRESSES");

        address tokenA;
        address tokenB;

        (tokenA, tokenB) = sortToken(token0, token1);
        // 获取当前 token0 token1 的所有 pool
        address[] memory existingPools = pools[tokenA][tokenB];
        // 然后判断是否已经存在 tickLower tickUpper fee 相同的 pool
        // 如果存在就直接返回
        for (uint256 i = 0; i < existingPools.length; i++) {
            IPool currentPool = IPool(existingPools[i]);

            if (
                currentPool.tickLower() == tickLower &&
                currentPool.tickUpper() == tickUpper &&
                currentPool.fee() == fee
            ) {
                return existingPools[i];
            }
        }

        // 如果不存在就创建一个新的 pool
        parameters = Parameters(
            address(this),
            tokenA,
            tokenB,
            tickLower,
            tickUpper,
            fee
        );

        bytes32 salt = keccak256(
            abi.encodePacked(tokenA, tokenB, tickLower, tickUpper, fee)
        );

        pool = address(new Pool{salt: salt}());
        // 然后记录到 pools 中
        pools[tokenA][tokenB].push(pool);
        delete parameters;

        emit PoolCreated(
            token0,
            token1,
            uint32(existingPools.length),
            tickLower,
            tickUpper,
            fee,
            pool
        );
    }
}
