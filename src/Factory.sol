// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "./interfaces/IFactory.sol";
import "./Pool.sol";

contract Factory is IFactory {
    // 三层映射（token0 => token1 => paramsHash => pool）
    mapping(address => mapping(address => mapping(uint24 => address)))
        public pools;

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
        uint24 fee
    ) external view override returns (address) {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "ZERO_ADDRESS");

        (address token0, address token1) = sortToken(tokenA, tokenB);
        return pools[token0][token1][fee];
    }

    function createPool(
        address token0,
        address token1,
        uint24 fee
    ) external override returns (address pool) {
        require(token0 != token1, "IDENTICAL_ADDRESSES");
        require(fee > 0, "INVALID_FEE");

        (address tokenA, address tokenB) = sortToken(token0, token1);
        // 检查池是否已存在
        if (pools[tokenA][tokenB][fee] != address(0)) {
            return pools[tokenA][tokenB][fee];
        }

        parameters = Parameters(address(this), token0, token1, fee);

        bytes32 salt = keccak256(abi.encodePacked(tokenA, tokenB, fee));
        pool = address(new Pool{salt: salt}());
        // 记录到 pools 中
        pools[tokenA][tokenB][fee] = pool;
        // delete pool info
        delete parameters;

        emit PoolCreated(token0, token1, fee, pool);
    }
}
