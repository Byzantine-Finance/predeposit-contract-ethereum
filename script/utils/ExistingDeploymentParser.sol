// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ByzantineDeposit} from "../../src/ByzantineDeposit.sol";
import {PauserRegistry} from "../../src/permissions/PauserRegistry.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/Script.sol";
import "forge-std/Test.sol";

contract ExistingDeploymentParser is Script, Test {
    // Contracts
    PauserRegistry public pauserRegistry;
    ByzantineDeposit public deposit;

    // ByzantineDeposit contract owner
    address public owner;

    // Pausers
    address[] public pausers;
    // Unpauser
    address public unpauser;

    // Initial paused status
    uint256 public initialPausedStatus;

    // Lido contracts address
    address public stETH;
    address public wstETH;

    // Pause indices flags
    uint8 private constant PAUSED_DEPOSITS = 0;
    uint8 private constant PAUSED_VAULTS_MOVES = 1;

    /// @notice Parse initial deployment params from a JSON file
    function _parseInitialDeploymentParams(
        string memory initialDeploymentParamsPath
    ) internal virtual {
        // read and log the chainID
        uint256 currentChainId = block.chainid;
        emit log_named_uint("You are parsing on ChainID", currentChainId);

        // READ JSON CONFIG DATA
        string memory initialDeploymentData = vm.readFile(initialDeploymentParamsPath);

        // check that the chainID matches the one in the config
        uint256 configChainId = stdJson.readUint(initialDeploymentData, ".chainInfo.chainId");
        require(configChainId == currentChainId, "You are on the wrong chain for this config");

        // read PauserRegistry config
        pausers = stdJson.readAddressArray(initialDeploymentData, ".pauserRegistryConfig.pausers");
        unpauser = stdJson.readAddress(initialDeploymentData, ".pauserRegistryConfig.unpauser");

        // read ByzantineDeposit config
        owner = stdJson.readAddress(initialDeploymentData, ".byzantineDepositConfig.owner");
        initialPausedStatus = stdJson.readUint(initialDeploymentData, ".byzantineDepositConfig.initPausedStatus");
        stETH = stdJson.readAddress(initialDeploymentData, ".byzantineDepositConfig.stETH");
        wstETH = stdJson.readAddress(initialDeploymentData, ".byzantineDepositConfig.wstETH");

        logInitialDeploymentParams();
    }

    /// @notice Verify if contracts have been correctly deployed
    function _sanityChecks() internal view {
        // Verify pausers addresses
        for (uint256 i; i < pausers.length; i++) {
            require(pauserRegistry.isPauser(pausers[i]), "PauserRegistry.isPauser: pauser address not set");
        }
        // Verify unpauser address
        require(pauserRegistry.unpauser() == unpauser, "PauserRegistry.unpauser: unpauser address not set");

        // Verify PauserRegistry pointer
        require(deposit.pauserRegistry() == pauserRegistry, "ByzantineDeposit.pauserRegistry: PauserRegistry not set");
        // Verify initial paused status
        require(deposit.paused() == 1 << PAUSED_VAULTS_MOVES, "ByzantineDeposit.paused: initialPausedStatus not set");
        // Verify owner
        require(deposit.owner() == owner, "ByzantineDeposit.owner: owner not set");
        // Verify stETH address
        require(address(deposit.stETHToken()) == stETH, "ByzantineDeposit.stETHToken: stETH not set");
        // Verify wstETH address
        require(address(deposit.wstETH()) == wstETH, "ByzantineDeposit.wstETH: wstETH not set");

        // Verify deposit token
        require(
            deposit.isDepositToken(deposit.beaconChainETHToken()),
            "ByzantineDeposit.isDepositToken: beaconChainETHToken not whitelisted"
        );
        require(deposit.isDepositToken(IERC20(stETH)), "ByzantineDeposit.isDepositToken: stETH not whitelisted");
        require(deposit.isDepositToken(IERC20(wstETH)), "ByzantineDeposit.isDepositToken: wstETH not whitelisted");
    }

    function logInitialDeploymentParams() public {
        emit log_string("==== Parsed Initilize Params for Initial Deployment ====");

        emit log_named_array("PauserRegistry contract pausers", pausers);
        emit log_named_address("PauserRegistry contract unpauser", unpauser);

        emit log_named_address("ByzantineDeposit contract owner", owner);
        emit log_named_uint("ByzantineDeposit contract initialPausedStatus", initialPausedStatus);
        emit log_named_address("ByzantineDeposit contract stETH", stETH);
        emit log_named_address("ByzantineDeposit contract wstETH", wstETH);
    }

    /// @notice Log contract addresses and write to output json file
    function logAndOutputContractAddresses(
        string memory outputPath
    ) public {
        // WRITE JSON DATA
        string memory parent_object = "parent object";

        string memory deployed_addresses = "addresses";
        vm.serializeAddress(deployed_addresses, "pauserRegistry", address(pauserRegistry));
        string memory deployed_addresses_output =
            vm.serializeAddress(deployed_addresses, "byzantineDeposit", address(deposit));

        string memory parameters = "parameters";
        vm.serializeAddress(parameters, "byzantineDeposit owner", owner);
        string memory parameters_output = vm.serializeAddress(parameters, "unpauser", unpauser);

        string memory chain_info = "chainInfo";
        vm.serializeUint(chain_info, "deploymentBlock", block.number);
        string memory chain_info_output = vm.serializeUint(chain_info, "chainId", block.chainid);

        // serialize all the data
        vm.serializeString(parent_object, deployed_addresses, deployed_addresses_output);
        vm.serializeString(parent_object, parameters, parameters_output);
        string memory finalJson = vm.serializeString(parent_object, chain_info, chain_info_output);

        vm.writeJson(finalJson, outputPath);
    }
}
