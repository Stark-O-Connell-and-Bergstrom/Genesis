// SPDX-License-Identifier: MIT
pragma solidity ^0.7.1;
pragma experimental ABIEncoderV2;

library LibOwnership {
    bytes32 constant OWNER_STORAGE_POSITION = keccak256("diamond.standard.ownership.storage");

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function contractOwner() internal view returns (address owner_) {
        bytes32 position = OWNER_STORAGE_POSITION;
        assembly {
            owner_ := sload(position)
        }
    }

    function setContractOwner(address _newOwner) internal {
        address previousOwner = contractOwner();
        bytes32 position = OWNER_STORAGE_POSITION;
        assembly {
            sstore(position, _newOwner)
        }
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function enforceIsContractOwner() internal view {
        require(msg.sender == contractOwner(), "LibOwnership: Must be contract owner");
    }

    modifier onlyOwner {
        require(msg.sender == contractOwner(), "LibOwnership: Must be contract owner");
        _;
    }
}
