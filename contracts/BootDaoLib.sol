pragma solidity ^0.7.1;
pragma experimental ABIEncoderV2;

library BootDaoLib {
    bytes32 constant DAO_STORAGE_POSITION = keccak256("diamond.standard.dao.storage");

    // @notice Ballot receipt record for a voter
    struct Receipt {
        // @notice Whether or not a vote has been cast
        bool hasVoted;

        // @notice Whether or not the voter supports the proposal
        bool support;

        // @notice The number of votes the voter had, which were cast
        uint votes;
    }

    struct Proposal {
        // @notice Unique id for looking up a proposal
        uint id;

        string description;

        // @notice Creator of the proposal
        address proposer;

        // @notice the ordered list of target addresses for calls to be made
        address[] targets;

        // @notice The ordered list of values (i.e. msg.value) to be passed to the calls to be made
        uint[] values;

        // @notice The ordered list of function signatures to be called
        string[] signatures;

        // @notice The ordered list of calldata to be passed to each call
        bytes[] calldatas;

        // @notice The block at which voting begins: holders must delegate their votes prior to this block
        uint startBlock;

        // @notice The block at which voting ends: votes must be cast prior to this block
        uint endBlock;

        // @notice The timestamp that the proposal will be available for execution, set once the vote succeeds
        uint unlockTime;

        // @notice Current number of votes in favor of this proposal
        uint forVotes;

        // @notice Current number of votes in opposition to this proposal
        uint againstVotes;

        // @notice Flag marking whether the proposal has been canceled
        bool canceled;

        // @notice Flag marking whether the proposal has been executed
        bool executed;

        // @notice Receipts of ballots for the entire set of voters
        mapping(address => Receipt) receipts;
    }

    struct DaoStorage {
        string title;
        address[] members;
        address genesisAddress;
        uint proposalCount;
        mapping(uint => Proposal) proposals;
        mapping(address => uint) balances;
    }

    function daoStorage() internal pure returns (DaoStorage storage ds) {
        bytes32 position = DAO_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function getProposal(uint id) internal view returns (Proposal storage) {
        DaoStorage storage ds = daoStorage();
        return ds.proposals[id];
    }
}