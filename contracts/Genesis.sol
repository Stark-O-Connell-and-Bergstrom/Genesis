pragma solidity ^0.7.1;

import './Ownable.sol';
import './GenesisLib.sol';

contract Genesis is Ownable {

    constructor(address defaultMetaDao_, bytes memory defaultProxyBytecode_, uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) {
        setUpgradeabilityProxyOwner(msg.sender);
        initialize(defaultMetaDao_, defaultProxyBytecode_, launchFee_, cancellationFee_, maxWhitelistSize_, genOwnerParticipation_);
    }

    function initialize(address defaultMetaDao_, bytes memory defaultProxyByteCode_, uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) public onlyProxyOwner {
        setConfig(launchFee_, cancellationFee_, maxWhitelistSize_, genOwnerParticipation_);
        setDefaultMetaDao(defaultMetaDao_);
        setDefaultProxyBytecode(defaultProxyByteCode_);
    }

    function setConfig(uint launchFee_, uint cancellationFee_, uint maxWhitelistSize_, bool genOwnerParticipation_) public onlyProxyOwner {
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.launchFee = launchFee_;
        s.cancellationFee = cancellationFee_;
        s.maxWhitelistSize = maxWhitelistSize_;
        s.genOwnerParticipation = genOwnerParticipation_;
    }

    function setDefaultMetaDao(address defaultMetaDao_) public onlyProxyOwner {
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.defaultContracts.metaDaoAddress = defaultMetaDao_;
    }

    function setDefaultProxyBytecode(bytes memory defaultProxyBytecode_) public onlyProxyOwner {
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.defaultContracts.proxyBytecode = defaultProxyBytecode_;
    }

    function setDisabled(bool disabled_) public onlyProxyOwner {
        GenesisLib.GenesisStorage storage s = GenesisLib.getStorage();
        s.disabled = disabled_;
    }

    function createProposal(uint requiredFunds, uint participationAmount, string memory title, address[] memory whitelist, address metaDaoAddress, bytes memory proxyBytecode, bytes memory proxyDiamondCut) public payable {
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

        if (metaDaoAddress != address(0) || proxyBytecode.length > 0 || proxyDiamondCut.length > 0) {
            GenesisLib.ProposalContracts storage pc = s.proposalContracts[s.proposalCount];
            pc.metaDaoAddress = metaDaoAddress;
            pc.proxyBytecode = proxyBytecode;
            pc.proxyDiamondCut = proxyDiamondCut;
        }

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
        GenesisLib.ProposalContracts storage pc = s.proposalContracts[id];

        require(proposal.id > 0, 'proposal not found');
        require(!proposal.cancelled, 'proposal is cancelled');
        require(!proposal.launched, 'already launched');
        proposal.launched = true;
        require(proposal.totalFunds >= proposal.requiredFunds, 'insufficient funds');

        uint participantCount = proposal.participantCount;
        address owner = proxyOwner();
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

        // deploy proxy, assign ownership to itself and set the dao logic contract
        bytes memory proxyBytecode = pc.proxyBytecode.length > 0 ? pc.proxyBytecode : s.defaultContracts.proxyBytecode;
        address metaDaoAddress = pc.metaDaoAddress != address(0) ? pc.metaDaoAddress : s.defaultContracts.metaDaoAddress;

        proposal.daoAddress = deployProxy(proxyBytecode, proposal.id);

        GenDaoInterface dao = GenDaoInterface(proposal.daoAddress);
        dao.initProxy(metaDaoAddress, proposal.daoAddress);
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

    function deployProxy(bytes memory proxyBytecode, uint salt) internal returns (address) {
        address addr;

        assembly {
            addr := create2(0, add(proxyBytecode, 0x20), mload(proxyBytecode), salt)
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

        address owner = proxyOwner();
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
}

interface GenDaoInterface {
    function initProxy(address defaultImpl, address owner) external;
    function initialize(address genesisAddress_, string memory title_, address[] memory members_) external;
}
