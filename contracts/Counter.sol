// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

contract Counter {
    uint256 public x;

    event Increment(uint256 by);

    function inc() public {
        x++;
        emit Increment(1);
    }

    function incBy(uint256 by) public {
        x += by;
        emit Increment(by);
    }
}
