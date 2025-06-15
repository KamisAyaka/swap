// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./interfaces/IFactory.sol";
import "./Pool.sol";

contract Factory is IFactory {
    // 简化后的两层映射（token0 => token1 => pool）
    mapping(address => mapping(address => address)) public pools;

    Parameters public override parameters;

    function sortToken(
        address tokenA,
        address tokenB
    ) public pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function getPool(
        address tokenA,
        address tokenB
    ) external view override returns (address) {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "ZERO_ADDRESS");

        (address token0, address token1) = sortToken(tokenA, tokenB);
        return pools[token0][token1];
    }

    function createPool(
        address token0,
        address token1
    ) external override returns (address pool) {
        require(token0 != token1, "IDENTICAL_ADDRESSES");

        (address tokenA, address tokenB) = sortToken(token0, token1);
        // 检查池是否已存在
        if (pools[tokenA][tokenB] != address(0)) {
            return pools[tokenA][tokenB];
        }

        // 使用固定费率（不再存储 fee 到 Parameters）
        parameters = Parameters(address(this), token0, token1);

        bytes32 salt = keccak256(abi.encodePacked(tokenA, tokenB));
        pool = address(new Pool{salt: salt}());

        // 记录到 pools 中
        pools[tokenA][tokenB] = pool;

        // 清除临时存储的参数
        delete parameters;

        // 触发事件（不包含 fee）
        emit PoolCreated(token0, token1, pool);
    }
}
