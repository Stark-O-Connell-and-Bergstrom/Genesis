pragma solidity ^0.7.1;
pragma experimental ABIEncoderV2;

import "./BootDaoLib.sol";

contract BootDao {

    /// @notice The number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    function quorumVotes(address[] memory members_) public pure returns (uint) {
        return members_.length * 10 / 2 + 1;
        // x10 multiplier to avoid fractions
    }

    // @notice The maximum number of actions that can be included in a proposal
    function proposalMaxOperations() public pure returns (uint) {return 10;} // 10 actions

    // @notice The delay before voting on a proposal may take place, once proposed
    function votingDelay() public pure returns (uint) {return 1;} // 1 block

    // @notice The duration of voting on a proposal, in blocks
    function votingPeriod() public pure returns (uint) {return 5760;} // ~1 day in blocks (assuming 15s blocks)

    function lockPeriod() public pure returns (uint) {return 10;} // 10 seconds

    // @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    // @notice An event emitted when a new proposal is created
    event ProposalCreated(uint id, address proposer, address[] targets, uint[] values, string[] signatures, bytes[] calldatas, uint startBlock, uint endBlock, string description);

    // @notice An event emitted when a vote has been cast on a proposal
    event VoteCast(address voter, uint proposalId, bool support, uint votes);

    // @notice An event emitted when a proposal has been canceled
    event ProposalCanceled(uint id);

    // @notice An event emitted when a proposal has been locked before execution
    event ProposalExecutionLocked(uint id, uint unlockTime);

    // @notice An event emitted when a proposal has been executed
    event ProposalExecuted(uint id);

    event TransactionExecuted(address indexed target, uint value, string signature, bytes data, uint eta);

    constructor() {}

    function initialize(address genesisAddress_, string memory title_, address[] memory members_) public {
        require(members_.length > 0, "BootDao::initialize: member list is empty");

        BootDaoLib.DaoStorage storage ds = BootDaoLib.daoStorage();
        require(ds.members.length == 0, "BootDao::initialize: already initialized");

        ds.genesisAddress = genesisAddress_;
        ds.title = title_;
        ds.members = members_;

        for (uint i = 0; i < members_.length; i++) {
            ds.balances[members_[i]] = 1;
        }
    }

    receive() external payable {}

    function propose(address[] memory targets, uint[] memory values, string[] memory signatures, bytes[] memory calldatas, string memory description) public returns (uint) {
        require(targets.length == values.length && targets.length == signatures.length && targets.length == calldatas.length, "BootDao::propose: proposal function information arity mismatch");
        require(targets.length != 0, "BootDao::propose: must provide actions");
        require(targets.length <= proposalMaxOperations(), "BootDao::propose: too many actions");

        uint startBlock = add256(block.number, votingDelay());
        uint endBlock = add256(startBlock, votingPeriod());

        BootDaoLib.DaoStorage storage ds = BootDaoLib.daoStorage();

        ds.proposalCount++;

        BootDaoLib.Proposal storage newProposal = ds.proposals[ds.proposalCount];
        newProposal.id = ds.proposalCount;
        newProposal.description = description;
        newProposal.proposer = msg.sender;
        newProposal.unlockTime = 0;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.canceled = false;
        newProposal.executed = false;
        ds.proposals[ds.proposalCount];

        emit ProposalCreated(newProposal.id, msg.sender, targets, values, signatures, calldatas, startBlock, endBlock, description);
        return newProposal.id;
    }

    function lockExecution(uint proposalId) internal {
        BootDaoLib.Proposal storage proposal = BootDaoLib.getProposal(proposalId);

        uint unlockTime = add256(block.timestamp, lockPeriod());
        proposal.unlockTime = unlockTime;

        emit ProposalExecutionLocked(proposalId, unlockTime);
    }

    function execute(uint proposalId) public payable {
        uint gasBefore = gasleft();
        require(state(proposalId) == ProposalState.Succeeded, "BootDao::execute: proposal can only be executed if it has succeeded");

        BootDaoLib.Proposal storage proposal = BootDaoLib.getProposal(proposalId);
        proposal.executed = true;
        for (uint i = 0; i < proposal.targets.length; i++) {
            executeTransaction(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], proposal.unlockTime);
        }

        emit ProposalExecuted(proposalId);

        // refund executor for the gas
        uint gasCost = (gasBefore - gasleft()) * tx.gasprice;
        msg.sender.transfer(gasCost);
    }

    function executeTransaction(address target, uint value, string memory signature, bytes memory data, uint unlockTime) internal returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value : value}(callData);
        require(success, "BootDao::executeTransaction: Transaction execution reverted.");

        emit TransactionExecuted(target, value, signature, data, unlockTime);

        return returnData;
    }

    function cancel(uint proposalId) public {
        BootDaoLib.DaoStorage storage ds = BootDaoLib.daoStorage();
        require(ds.balances[msg.sender] > 0, "BootDao::cancel: sender is not a member");
        ProposalState state = state(proposalId);
        require(state != ProposalState.Executed, "BootDao::cancel: cannot cancel executed proposal");
        require(state != ProposalState.Canceled, "BootDao::cancel: cannot cancel already cancelled proposal");

        BootDaoLib.Proposal storage proposal = ds.proposals[proposalId];
        proposal.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    function getActions(uint proposalId) public view returns (address[] memory targets, uint[] memory values, string[] memory signatures, bytes[] memory calldatas) {
        BootDaoLib.Proposal storage p = BootDaoLib.getProposal(proposalId);
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    function getReceipt(uint proposalId, address voter) public view returns (BootDaoLib.Receipt memory) {
        BootDaoLib.Proposal storage p = BootDaoLib.getProposal(proposalId);
        return p.receipts[voter];
    }

    function castVote(uint proposalId, bool support) public {
        BootDaoLib.DaoStorage storage ds = BootDaoLib.daoStorage();
        require(ds.balances[msg.sender] > 0, "BootDao::castVote: sender is not a member");
        require(state(proposalId) == ProposalState.Active, "BootDao::castVote: voting is closed");
        BootDaoLib.Proposal storage proposal = ds.proposals[proposalId];
        BootDaoLib.Receipt storage receipt = proposal.receipts[msg.sender];

        // will always be 1 until DAO decides otherwise
        uint votes = ds.balances[msg.sender];

        // sub prior vote if voted
        if (receipt.hasVoted) {
            if (receipt.support) {
                proposal.forVotes = sub256(proposal.forVotes, votes);
            } else {
                proposal.againstVotes = sub256(proposal.againstVotes, votes);
            }
        }

        if (support) {
            proposal.forVotes = add256(proposal.forVotes, votes);
        } else {
            proposal.againstVotes = add256(proposal.againstVotes, votes);
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        uint qv = quorumVotes(ds.members);
        if (proposal.unlockTime == 0 && (proposal.forVotes * 10 >= qv || proposal.againstVotes * 10 >= qv)) {
            lockExecution(proposalId);
        }

        emit VoteCast(msg.sender, proposalId, support, votes);
    }

    function state(uint proposalId) public view returns (ProposalState) {
        BootDaoLib.DaoStorage storage ds = BootDaoLib.daoStorage();
        require(ds.proposalCount >= proposalId && proposalId > 0, "BootDao::state: invalid proposal id");
        BootDaoLib.Proposal storage proposal = ds.proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (proposal.unlockTime == 0 && block.number >= proposal.endBlock) {
            return ProposalState.Expired;
        } else if (proposal.unlockTime > 0 && block.timestamp >= proposal.unlockTime) {
            uint qv = quorumVotes(ds.members);
            if (proposal.forVotes * 10 >= qv) {
                return ProposalState.Succeeded;
            }
            return ProposalState.Defeated;
        }
        return ProposalState.Active;
    }

    function add256(uint256 a, uint256 b) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, "addition overflow");
        return c;
    }

    function sub256(uint256 a, uint256 b) internal pure returns (uint) {
        require(b <= a, "subtraction underflow");
        return a - b;
    }

    function getProposal(uint id) public view returns (uint, uint, string memory, address, uint, uint, uint, uint, uint, bool, bool) {
        BootDaoLib.DaoStorage storage ds = BootDaoLib.daoStorage();
        BootDaoLib.Proposal storage proposal = ds.proposals[id];
        ProposalState proposalState = state(id);
        return (
            uint(proposalState),
            ds.members.length,
            proposal.description,
            proposal.proposer,
            proposal.startBlock,
            proposal.endBlock,
            proposal.unlockTime,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.executed,
            proposal.canceled
        );
    }

    function getInfo() public view returns (string memory, uint, address) {
        BootDaoLib.DaoStorage storage ds = BootDaoLib.daoStorage();
        return (
            ds.title,
            ds.members.length,
            ds.genesisAddress
        );
    }
}
