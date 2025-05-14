// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Token.sol"; // 假设 DebugToken 合约在此路径

contract DeployTokens is Script {
    function run() public {
        // 开始广播交易
        vm.startBroadcast();

        // 部署三个 DebugToken 实例
        TestToken debugTokenA = new TestToken("DebugTokenA", "DTA");
        TestToken debugTokenB = new TestToken("DebugTokenB", "DTB");
        TestToken debugTokenC = new TestToken("DebugTokenC", "DTC");

        // 停止广播交易
        vm.stopBroadcast();
    }
}
