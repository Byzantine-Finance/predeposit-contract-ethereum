// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC7535} from "./ERC7535.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC7535Mock is ERC7535 {
    constructor(
        string memory _name,
        string memory _symbol
    ) ERC7535() ERC20(_name, _symbol) {}
}
