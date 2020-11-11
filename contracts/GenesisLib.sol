pragma solidity ^0.7.1;

library GenesisLib {
    bytes32 constant GENESIS_STORAGE_POSITION = keccak256("diamond.standard.genesis.storage");

    struct Proposal {
        uint id;
        address creator;
        string title;
        uint requiredFunds;
        uint participationAmount;
        mapping(address => bool) whitelist;
        address[] addresses;
        mapping(address => uint) funds;
        uint participantCount;
        uint totalFunds;
        bool launched;
        bool cancelled;
        address daoAddress;
    }

    struct ProposalContracts {
        bytes proxyBytecode;
        bytes proxyDiamondCut;
    }

    struct GenesisStorage {
        ProposalContracts defaultContracts;
        uint launchFee;
        uint cancellationFee;
        uint maxWhitelistSize;
        bool genOwnerParticipation;
        bool disabled;
        uint proposalCount;
        mapping(uint => Proposal) proposals;
        mapping(uint => ProposalContracts) proposalContracts;
    }

    function getStorage() internal pure returns (GenesisStorage storage ds) {
        bytes32 position = GENESIS_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function getProposal(uint id) internal view returns (Proposal storage) {
        GenesisStorage storage ds = getStorage();
        return ds.proposals[id];
    }
}

