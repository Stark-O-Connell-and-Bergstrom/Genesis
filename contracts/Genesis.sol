pragma solidity ^0.7.1;

import './utils/LibOwnership.sol';
import './GenesisLib.sol';
import "./utils/IERC173.sol";

contract Genesis is IERC173 {

    constructor(bytes memory diamondBytecode_, bytes memory diamondCut_, uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) {
        LibOwnership.setContractOwner(msg.sender);
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.launchFee = launchFee_;
        s.cancellationFee = cancellationFee_;
        s.maxWhitelistSize = maxWhitelistSize_;
        s.genOwnerParticipation = genOwnerParticipation_;
        s.diamondBytecode = diamondBytecode_;
        s.diamondCut = diamondCut_;
    }

    function setConfig(uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) public {
        LibOwnership.enforceIsContractOwner();
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.launchFee = launchFee_;
        s.cancellationFee = cancellationFee_;
        s.maxWhitelistSize = maxWhitelistSize_;
        s.genOwnerParticipation = genOwnerParticipation_;
    }

    function setDefaultDiamond(bytes memory diamondBytecode_, bytes memory diamondCut_) public {
        LibOwnership.enforceIsContractOwner();
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.diamondBytecode = diamondBytecode_;
        s.diamondCut = diamondCut_;
    }

    function setDisabled(bool disabled_) public {
        LibOwnership.enforceIsContractOwner();
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.disabled = disabled_;
    }

    function createProposal(uint requiredFunds, uint participationAmount, string memory title, address[] memory whitelist, bytes memory diamondBytecode, bytes memory diamondCut) public payable {
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        require(s.disabled == false, "genesis is disabled");
        bytes memory tempTitle = bytes(title);
        require(tempTitle.length > 0, "title cannot be empty");
        require(whitelist.length > 0, "whitelist cannot be empty");
        require(whitelist.length <= s.maxWhitelistSize, "whitelist exceeds max size");
        require(participationAmount * whitelist.length >= requiredFunds, "requiredFunds is greater then the sum of participationAmount for whitelisted accounts");

        s.proposalCount++;

        GenesisLib.Proposal storage p = s.proposals[s.proposalCount];
        p.id = s.proposalCount;
        p.creator = msg.sender;
        p.title = title;
        p.requiredFunds = requiredFunds;
        p.participationAmount = participationAmount;
        p.totalFunds = 0;
        p.diamondBytecode = diamondBytecode;
        p.diamondCut = diamondCut;

        for (uint i = 0; i < whitelist.length; i++) {
            p.whitelist[whitelist[i]] = true;
        }
    }

    function deposit(uint id) public payable {
        GenesisLib.Proposal storage proposal = GenesisLib.getProposal(id);

        require(proposal.id > 0, 'proposal not found');
        require(proposal.whitelist[msg.sender], 'sender is not whitelisted');
        require(msg.value == proposal.participationAmount, 'value must equal the participation amount');

        if (proposal.funds[msg.sender] == 0) {
            proposal.participantCount++;
            proposal.addresses.push(msg.sender);
        }

        proposal.funds[msg.sender] += msg.value;
        proposal.totalFunds += msg.value;
    }

    function launch(uint id) public {
        uint gasBefore = gasleft();

        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        GenesisLib.Proposal storage proposal = s.proposals[id];

        require(proposal.id > 0, 'proposal not found');
        require(!proposal.cancelled, 'proposal is cancelled');
        require(!proposal.launched, 'already launched');
        proposal.launched = true;
        require(proposal.totalFunds >= proposal.requiredFunds, 'insufficient funds');

        uint participantCount = proposal.participantCount;
        address owner = LibOwnership.contractOwner();
        if (owner != address(0) && s.genOwnerParticipation) {
            participantCount++;
        }

        address[] memory participants = new address[](participantCount);

        uint payerIndex = 0;
        // filter only participants that deposited funds
        for (uint i = 0; i < proposal.addresses.length; i++) {
            address addr = proposal.addresses[i];
            if (proposal.funds[addr] > 0) {
                participants[payerIndex] = addr;
                payerIndex++;
            }
        }
        if (owner != address(0) && s.genOwnerParticipation) {
            participants[payerIndex] = owner;
        }

        // deploy proxy, assign ownership to itself and init the dao
        proposal.daoAddress = deployProxy(proposal.id);

        GenDaoInterface dao = GenDaoInterface(proposal.daoAddress);
        dao.transferOwnership(proposal.daoAddress);
        dao.initialize(address(this), proposal.title, participants);

        if (owner != address(0) && s.launchFee > 0) {
            uint launchCost = proposal.totalFunds * s.launchFee / 100;
            proposal.totalFunds -= launchCost;
            transferTo(owner, launchCost);
        }

        // transfer collected funds to dao and refund sender for the gas
        uint gasCost = (gasBefore - gasleft() + 46004) * tx.gasprice;
        proposal.totalFunds -= gasCost;

        transferTo(proposal.daoAddress, proposal.totalFunds);

        msg.sender.transfer(gasCost);
    }

    function deployProxy(uint proposalId) internal returns (address) {
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        GenesisLib.Proposal storage p = s.proposals[proposalId];

        bytes memory diamondBytecode = p.diamondBytecode.length > 0 ? p.diamondBytecode : s.diamondBytecode;
        bytes memory diamondCut = p.diamondCut.length > 0 ? p.diamondCut : s.diamondCut;
        bytes memory bytecode = abi.encodePacked(diamondBytecode, diamondCut);

        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), proposalId)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        return addr;
    }

    function cancel(uint id) public {
        GenesisLib.Proposal storage proposal = GenesisLib.getProposal(id);

        require(proposal.id > 0, 'proposal not found');
        require(msg.sender == proposal.creator, 'only creator can cancel a proposal');
        require(!proposal.cancelled, 'already cancelled');
        require(!proposal.launched, 'already launched');

        proposal.cancelled = true;
    }

    function refund(uint id) public returns (bool) {
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        GenesisLib.Proposal storage proposal = s.proposals[id];

        require(proposal.id > 0, 'proposal not found');
        require(proposal.cancelled, 'not cancelled');

        uint amount = proposal.funds[msg.sender];
        require(amount > 0, 'no funds to refund');

        proposal.participantCount--;
        proposal.funds[msg.sender] = 0;
        proposal.totalFunds -= amount;

        uint refundRatio = 100;

        address owner = LibOwnership.contractOwner();
        if (owner != address(0) && s.cancellationFee > 0) {
            refundRatio -= s.cancellationFee;
            transferTo(owner, amount * s.cancellationFee / 100);
        }

        msg.sender.transfer(amount * refundRatio / 100);

        return true;
    }

    function transferTo(address to, uint value) internal {
        (bool success,) = to.call{value:value}(abi.encode());
        require(success);
    }

    function getProposal(uint id) public view returns (string memory, address, address, bool, bool, uint, uint, uint, uint) {
        GenesisLib.Proposal storage proposal = GenesisLib.getProposal(id);
        return (
            proposal.title,
            proposal.daoAddress,
            proposal.creator,
            proposal.launched,
            proposal.cancelled,
            proposal.requiredFunds,
            proposal.participationAmount,
            proposal.totalFunds,
            proposal.participantCount
        );
    }

    function transferOwnership(address _newOwner) external override {
        LibOwnership.enforceIsContractOwner();
        LibOwnership.setContractOwner(_newOwner);
    }

    function owner() external override view returns (address owner_) {
        owner_ = LibOwnership.contractOwner();
    }
}

interface GenDaoInterface {
    function transferOwnership(address _newOwner) external;
    function initialize(address genesisAddress_, string memory title_, address[] memory members_) external;
}
