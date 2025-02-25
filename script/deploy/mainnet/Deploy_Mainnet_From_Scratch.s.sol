// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PauserRegistry} from "../../../src/permissions/PauserRegistry.sol";
import {ByzantineDeposit} from "../../../src/ByzantineDeposit.sol";
import {IPauserRegistry} from "../../../src/interfaces/IPauserRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IwstETH} from "../../../src/ByzantineDeposit.sol";

import {ExistingDeploymentParser} from "../../utils/ExistingDeploymentParser.sol";

/**
 * @notice Script used for the first deployment of Byzantine contracts to Mainnet (PauserRegistry and ByzantineDeposit)
 * forge script script/deploy/mainnet/Deploy_Mainnet_From_Scratch.s.sol --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify -vvvv
 */
contract Deploy_Mainnet_From_Scratch is ExistingDeploymentParser {
    function run() external {
        _parseInitialDeploymentParams("script/configs/mainnet/Deploy_from_scratch.mainnet.config.json");

        // START RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.startBroadcast();
        emit log_named_address("Deployer Address", msg.sender);
        _deployFromScratch();
        // STOP RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.stopBroadcast();

        // Sanity Checks
        _sanityChecks();

        logAndOutputContractAddresses("script/output/mainnet/Deploy_from_scratch.mainnet.config.json");
    }

    function _deployFromScratch() internal {
        // Deploy the PauserRegistry contract
        pauserRegistry = new PauserRegistry(pausers, unpauser);

        // Deploy the ByzantineDeposit contract
        deposit = new ByzantineDeposit(
            IPauserRegistry(address(pauserRegistry)), initialPausedStatus, owner, IERC20(stETH), IwstETH(wstETH)
        );
    }
}
