// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
pragma abicoder v2;

import "./interfaces/IPoolManager.sol";
import "./interfaces/IPool.sol";
import "./Factory.sol";

contract PoolManager is Factory, IPoolManager {
    Pair[] public pairs;

    function getPairs() external view override returns (Pair[] memory) {
        return pairs;
    }

    function getAllPools()
        external
        view
        override
        returns (PoolInfo[] memory poolsInfo)
    {
        poolsInfo = new PoolInfo[](pairs.length);

        for (uint i = 0; i < pairs.length; i++) {
            address token0 = pairs[i].token0;
            address token1 = pairs[i].token1;
            address poolAddr = pools[token0][token1];

            if (poolAddr != address(0)) {
                IPool pool = IPool(poolAddr);
                poolsInfo[i] = PoolInfo({
                    pool: poolAddr,
                    token0: token0,
                    token1: token1,
                    fee: pool.fee(),
                    feeProtocol: 0,
                    tick: pool.tick(),
                    sqrtPriceX96: pool.sqrtPriceX96(),
                    liquidity: pool.liquidity()
                });
            }
        }
    }

    function createAndInitializePoolIfNecessary(
        CreateAndInitializeParams calldata params
    ) external payable override returns (address poolAddress) {
        poolAddress = this.getPool(params.token0, params.token1);

        if (poolAddress == address(0)) {
            // 创建池子（只传两个代币参数）
            poolAddress = this.createPool(
                params.token0,
                params.token1,
                params.tickSpacing
            );
        }

        IPool pool = IPool(poolAddress);

        if (pool.sqrtPriceX96() == 0) {
            pool.initialize(params.sqrtPriceX96);

            // 检查是否为新交易对
            bool isNewPair = true;
            for (uint i = 0; i < pairs.length; i++) {
                if (
                    (pairs[i].token0 == pool.token0() &&
                        pairs[i].token1 == pool.token1()) ||
                    (pairs[i].token0 == pool.token1() &&
                        pairs[i].token1 == pool.token0())
                ) {
                    isNewPair = false;
                    break;
                }
            }

            if (isNewPair) {
                pairs.push(
                    Pair({token0: pool.token0(), token1: pool.token1()})
                );
            }
        }
    }
}
