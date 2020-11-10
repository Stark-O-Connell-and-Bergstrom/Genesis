pragma solidity ^0.7.1;

contract Ownable {

    bytes32 internal constant proxyOwnerPosition = keccak256("composability.proxy.owner");

    event ProxyOwnershipTransferred(address previousOwner, address newOwner);

    modifier onlyProxyOwner() {
        require(msg.sender == proxyOwner(), "not owner");
        _;
    }

    function proxyOwner() public view returns (address owner) {
        bytes32 position = proxyOwnerPosition;
        assembly {
            owner := sload(position)
        }
    }

    function setUpgradeabilityProxyOwner(address newProxyOwner) internal {
        bytes32 position = proxyOwnerPosition;
        assembly {
            sstore(position, newProxyOwner)
        }
    }

    function transferProxyOwnership(address newOwner) public onlyProxyOwner {
        require(newOwner != address(0));
        emit ProxyOwnershipTransferred(proxyOwner(), newOwner);
        setUpgradeabilityProxyOwner(newOwner);
    }
}
