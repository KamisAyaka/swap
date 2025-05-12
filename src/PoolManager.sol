// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
pragma abicoder v2;

import "./interfaces/IPoolManager.sol";
import "./interfaces/IPool.sol";
import "./Factory.sol";

contract PoolManager is Factory, IPoolManager {
    Pair[] public pairs;

    function getPairs() external view override returns (Pair[] memory) {
        // 返回有哪些交易对，DApp 和 getAllPools 会用到
        return pairs;
    }

    function getAllPools()
        external
        view
        override
        returns (PoolInfo[] memory poolsInfo)
    {
        // 遍历 pairs，获取当前所有的交易对的总长度
        uint32 length = 0;
        for (uint32 i = 0; i < pairs.length; i++) {
            length += uint32(pools[pairs[i].token0][pairs[i].token1].length);
        }
        poolsInfo = new PoolInfo[](length);
        // 获取每个 pool 的信息
        uint256 index = 0;
        for (uint32 i = 0; i < pairs.length; i++) {
            address[] memory addresses = pools[pairs[i].token0][
                pairs[i].token1
            ];
            for (uint32 j = 0; j < addresses.length; j++) {
                IPool pool = IPool(addresses[j]);
                poolsInfo[index] = PoolInfo({
                    pool: addresses[j],
                    token0: pool.token0(),
                    token1: pool.token1(),
                    index: j,
                    fee: pool.fee(),
                    feeProtocol: 0,
                    tickLower: pool.tickLower(),
                    tickUpper: pool.tickUpper(),
                    tick: pool.tick(),
                    sqrtPriceX96: pool.sqrtPriceX96(),
                    liquidity: pool.liquidity()
                });
                index++;
            }
        }
        // 返回
        return poolsInfo;
    }

    function createAndInitializePoolIfNecessary(
        CreateAndInitializeParams calldata params
    ) external payable override returns (address poolAddress) {
        //require(params.token0 < params.token1); ?? 需要这步吗？
        // 如果没有对应的 Pool 就创建一个 Pool
        poolAddress = this.createPool(
            params.token0,
            params.token1,
            params.tickLower,
            params.tickUpper,
            params.fee
        );
        // 创建成功后记录到 pairs 中
        IPool pool = IPool(poolAddress);

        uint256 index = pools[pool.token0()][pool.token1()].length;

        // 新创建的池子，没有初始化价格，需要初始化价格
        if (pool.sqrtPriceX96() == 0) {
            pool.initialize(params.sqrtPriceX96);

            if (index == 1) {
                // 如果是第一次添加该交易对，需要记录下来
                pairs.push(
                    Pair({token0: pool.token0(), token1: pool.token1()})
                );
            }
        }
    }
}
