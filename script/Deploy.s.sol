// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {MilestoneEscrow} from "../src/MilestoneEscrow.sol";

/// @notice Base Sepolia (chainId 84532) deployment. NOT executed as part of this project.
/// Usage:
///   export PRIVATE_KEY=0x...  BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
///   export ESCROW_OWNER=0x... FEE_RECIPIENT=0x... FEE_BPS=100
///   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify
contract Deploy is Script {
    function run() external returns (MilestoneEscrow esc) {
        require(block.chainid == 84532, "Deploy: not Base Sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("ESCROW_OWNER", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(0)));
        vm.startBroadcast(pk);
        esc = new MilestoneEscrow(owner, feeRecipient, feeBps);
        vm.stopBroadcast();
        console2.log("MilestoneEscrow:", address(esc));
    }
}
